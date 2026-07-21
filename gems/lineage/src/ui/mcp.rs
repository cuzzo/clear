//! MCP server: exposes `lineage.db` (and, for a bounded set of static
//! facts, live disk content) to LLM coding agents over the Model Context
//! Protocol. Five workflow-shaped tools, not one per table - see
//! `docs/agents/mcp.md` for the rationale, plus the uncommitted-changes and
//! DB-less designs this module implements.
//!
//! Ported from the Ruby MVP (`tools/mcp_server.rb`, retired by this port) so
//! the tool layer runs in-process against `Storage` directly instead of
//! re-reading `.sql` files as text from Ruby: query logic is the *same*
//! reused `.sql` files and typed `Storage` methods the UI/LSP already use,
//! not a reimplementation.

use crate::extract::{BoundaryExtractor, HeuristicExtractor, SourceFilter};
use crate::hazard::{
    scan_c_sites, scan_cpp_sites, scan_csharp_sites, scan_go_sites, scan_rust_sites,
    scan_zig_sites, HazardSite,
};
use crate::model::BlobFile;
use crate::storage::Storage;
use anyhow::{Context, Result};
use rmcp::model::{
    CallToolRequestParams, CallToolResult, ContentBlock, Implementation, InitializeResult,
    ListToolsResult, PaginatedRequestParams, ServerCapabilities, Tool,
};
use rmcp::service::{RequestContext, RoleServer};
use rmcp::{ErrorData as McpError, ServerHandler, ServiceExt};
use rusqlite::types::ValueRef;
use rusqlite::{params_from_iter, Row};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Serve `lineage_*` tools over stdio JSON-RPC, newline-delimited (per the
/// MCP spec - unlike LSP, there is no Content-Length framing here). `db` is
/// optional: omitting it runs in
/// DB-less mode (see `docs/agents/mcp.md`), where only the tools/fields
/// derivable from live disk content are available.
pub async fn serve_mcp(db: Option<PathBuf>, repo: PathBuf) -> Result<()> {
    let storage = match db {
        Some(path) => {
            if !path.is_file() {
                anyhow::bail!(
                    "lineage database not found: {} (run `lineage init`/`lineage build` first, or omit --db for DB-less mode)",
                    path.display()
                );
            }
            Some(Storage::open(&path).with_context(|| format!("opening {}", path.display()))?)
        }
        None => None,
    };
    let handler = LineageMcp {
        storage: Mutex::new(storage),
        repo,
    };
    let transport = rmcp::transport::stdio();
    let service = handler.serve(transport).await?;
    service.waiting().await?;
    Ok(())
}

struct LineageMcp {
    storage: Mutex<Option<Storage>>,
    repo: PathBuf,
}

fn tool_defs() -> Vec<Tool> {
    let obj = |v: Value| -> std::sync::Arc<Map<String, Value>> {
        std::sync::Arc::new(v.as_object().cloned().unwrap_or_default())
    };
    vec![
        Tool::new(
            "lineage_file_risk",
            "Coverage, mutation coverage, and open-hazard counts for a file or a directory \
             prefix. Call before editing unfamiliar code to learn whether it is well-verified. \
             Requires a lineage.db.",
            obj(json!({
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Repo-relative file path or directory prefix"}},
                "required": ["path"]
            })),
        ),
        Tool::new(
            "lineage_unit_context",
            "Full context for the function/unit containing a specific line: risk, test \
             coverage, mutation status, open hazards, runtime hotness, and static findings in \
             its range. The richest tool - call before modifying a specific function. Works \
             without a lineage.db (structure + live hazard scan only, no history/coverage). If \
             the file has uncommitted or added-but-not-committed changes, hazards are \
             live-rescanned from disk for languages Lineage scans in-process (rust/go/zig/c/\
             cpp/csharp) rather than served stale from the database.",
            obj(json!({
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Repo-relative file path"},
                    "line": {"type": "integer", "description": "1-indexed line number within the file"}
                },
                "required": ["path", "line"]
            })),
        ),
        Tool::new(
            "lineage_verification_gaps",
            "Open hazards lacking evidence, dead/dark branch arms, and zero-kill (weak) tests \
             in a file or directory. Call before trusting a coverage percentage at face value. \
             Without a lineage.db, only a live hazard scan is available (no evidence join, no \
             dark-arm/weak-test data).",
            obj(json!({
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Repo-relative file path or directory prefix"}},
                "required": ["path"]
            })),
        ),
        Tool::new(
            "lineage_change_history",
            "Recent commit-level events (changes/moves/fixes) and production crash occurrences \
             for a file. Call before a risky refactor to see how fragile the area has been. \
             Requires a lineage.db.",
            obj(json!({
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Repo-relative file path"},
                    "limit": {"type": "integer", "description": "Max rows per category (default 20)"}
                },
                "required": ["path"]
            })),
        ),
        Tool::new(
            "lineage_find_definition",
            "Resolve a symbol name to its definition location(s) by rename-stable logical-unit \
             identity, not text search. Requires a lineage.db.",
            obj(json!({
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Bare or qualified symbol name"},
                    "path": {"type": "string", "description": "Calling file, for future proximity ranking (currently unused)"},
                    "commit": {"type": "string", "description": "Commit hash to resolve against (defaults to latest)"}
                },
                "required": ["name"]
            })),
        ),
    ]
}

impl ServerHandler for LineageMcp {
    fn get_info(&self) -> rmcp::model::ServerInfo {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("lineage-mcp", env!("CARGO_PKG_VERSION")))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult::with_all_items(tool_defs()))
    }

    fn get_tool(&self, name: &str) -> Option<Tool> {
        tool_defs().into_iter().find(|t| t.name == name)
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, McpError> {
        let args = request.arguments.unwrap_or_default();
        let storage = self.storage.lock().unwrap();
        let tool_name = request.name.as_ref();
        if tool_defs().iter().all(|t| t.name != tool_name) {
            return Err(McpError::invalid_params(format!("unknown tool: {tool_name}"), None));
        }
        let dispatch = || -> Result<Value, String> {
            match tool_name {
                "lineage_file_risk" => {
                    file_risk(require_db(&storage, "lineage_file_risk")?, arg_str(&args, "path")?)
                }
                "lineage_unit_context" => unit_context(
                    storage.as_ref(),
                    &self.repo,
                    arg_str(&args, "path")?,
                    arg_u32(&args, "line")?,
                ),
                "lineage_verification_gaps" => {
                    verification_gaps(storage.as_ref(), &self.repo, arg_str(&args, "path")?)
                }
                "lineage_change_history" => change_history(
                    require_db(&storage, "lineage_change_history")?,
                    arg_str(&args, "path")?,
                    arg_u32_opt(&args, "limit").unwrap_or(20),
                ),
                "lineage_find_definition" => find_definition(
                    require_db(&storage, "lineage_find_definition")?,
                    arg_str(&args, "name")?,
                    args.get("path").and_then(Value::as_str),
                    args.get("commit").and_then(Value::as_str),
                ),
                other => Err(format!("unknown tool: {other}")),
            }
        };
        match dispatch() {
            Ok(value) => Ok(CallToolResult::success(vec![ContentBlock::text(
                serde_json::to_string_pretty(&value).unwrap_or_default(),
            )])),
            Err(message) => Ok(CallToolResult::error(vec![ContentBlock::text(message)])),
        }
    }
}

// ---------------------------------------------------------------------------
// Argument helpers - tool errors surface as CallToolResult::error (caller-
// visible), never McpError, except for a genuinely unroutable request name.
// ---------------------------------------------------------------------------

fn arg_str<'a>(args: &'a Map<String, Value>, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing required string argument: {key}"))
}

fn arg_u32(args: &Map<String, Value>, key: &str) -> Result<u32, String> {
    args.get(key)
        .and_then(Value::as_u64)
        .map(|v| v as u32)
        .ok_or_else(|| format!("missing required integer argument: {key}"))
}

fn arg_u32_opt(args: &Map<String, Value>, key: &str) -> Option<u32> {
    args.get(key).and_then(Value::as_u64).map(|v| v as u32)
}

fn require_db<'a>(storage: &'a Option<Storage>, tool: &str) -> Result<&'a Storage, String> {
    storage
        .as_ref()
        .ok_or_else(|| format!("{tool} requires a lineage.db; server was started without --db"))
}

// ---------------------------------------------------------------------------
// Generic row -> JSON conversion, mirroring Ruby's `results_as_hash = true`:
// each query names its own SELECT column order once, no per-query structs.
// ---------------------------------------------------------------------------

fn column_value(row: &Row, idx: usize) -> rusqlite::Result<Value> {
    Ok(match row.get_ref(idx)? {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(i) => json!(i),
        ValueRef::Real(f) => json!(f),
        ValueRef::Text(t) => json!(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Blob(_) => Value::Null,
    })
}

fn row_to_object(row: &Row, names: &[&str]) -> rusqlite::Result<Map<String, Value>> {
    let mut map = Map::new();
    for (idx, name) in names.iter().enumerate() {
        map.insert((*name).to_string(), column_value(row, idx)?);
    }
    Ok(map)
}

fn query_rows(
    storage: &Storage,
    sql: &str,
    params: &[&str],
    names: &[&str],
) -> Result<Vec<Map<String, Value>>, String> {
    let conn = storage.connection();
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params_from_iter(params.iter()), |row| row_to_object(row, names))
        .map_err(|e| e.to_string())?;
    rows.collect::<rusqlite::Result<Vec<_>>>().map_err(|e| e.to_string())
}

/// Try an exact-path match; if empty, retry as a `path%` prefix (directory
/// scope). Mirrors the Ruby MVP's `resolve_path_or_prefix`.
fn resolve_path_or_prefix(
    storage: &Storage,
    sql_exact: &str,
    sql_prefix: &str,
    path: &str,
    names: &[&str],
) -> Result<(Vec<Map<String, Value>>, String), String> {
    let exact = query_rows(storage, sql_exact, &[path], names)?;
    if !exact.is_empty() {
        return Ok((exact, path.to_string()));
    }
    let prefix_arg = format!("{path}%");
    let rows = query_rows(storage, sql_prefix, &[&prefix_arg], names)?;
    Ok((rows, format!("{path}*")))
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

fn file_risk(storage: &Storage, path: &str) -> Result<Value, String> {
    const BASE_SQL: &str = "
        SELECT COALESCE(le.path, u.original_path) AS current_path,
               COUNT(DISTINCT u.id) AS units,
               ROUND(AVG(u.current_line_cov), 1) AS avg_line_coverage,
               ROUND(AVG(u.current_mutant_cov), 1) AS avg_mutant_coverage,
               SUM(u.current_distinct_tests) AS total_distinct_tests,
               SUM(CASE WHEN u.is_hard_gated = 1 THEN 1 ELSE 0 END) AS hard_gated_units
        FROM logical_units u
        LEFT JOIN (
          SELECT unit_id, path,
                 ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY timestamp DESC, id DESC) AS rank
          FROM events
        ) le ON le.unit_id = u.id AND le.rank = 1
        WHERE COALESCE(le.path, u.original_path) = ?1
        GROUP BY current_path";
    const PREFIX_SQL: &str = "
        SELECT COALESCE(le.path, u.original_path) AS current_path,
               COUNT(DISTINCT u.id) AS units,
               ROUND(AVG(u.current_line_cov), 1) AS avg_line_coverage,
               ROUND(AVG(u.current_mutant_cov), 1) AS avg_mutant_coverage,
               SUM(u.current_distinct_tests) AS total_distinct_tests,
               SUM(CASE WHEN u.is_hard_gated = 1 THEN 1 ELSE 0 END) AS hard_gated_units
        FROM logical_units u
        LEFT JOIN (
          SELECT unit_id, path,
                 ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY timestamp DESC, id DESC) AS rank
          FROM events
        ) le ON le.unit_id = u.id AND le.rank = 1
        WHERE COALESCE(le.path, u.original_path) LIKE ?1
        GROUP BY current_path";
    let names = [
        "current_path",
        "units",
        "avg_line_coverage",
        "avg_mutant_coverage",
        "total_distinct_tests",
        "hard_gated_units",
    ];
    let (rows, matched) = resolve_path_or_prefix(storage, BASE_SQL, PREFIX_SQL, path, &names)?;
    if rows.is_empty() {
        return Err(format!("no tracked units under {path:?} (run `lineage build` first?)"));
    }

    let is_prefix = matched.ends_with('*');
    let hazard_sql = if is_prefix {
        "SELECT path, COUNT(*) AS hazards FROM unit_hazards WHERE is_active = 1 AND path LIKE ?1 GROUP BY path"
    } else {
        "SELECT path, COUNT(*) AS hazards FROM unit_hazards WHERE is_active = 1 AND path = ?1 GROUP BY path"
    };
    let hazard_arg = if is_prefix { format!("{path}%") } else { path.to_string() };
    let hazard_rows = query_rows(storage, hazard_sql, &[&hazard_arg], &["path", "hazards"])?;
    let hazards_by_path: std::collections::HashMap<String, Value> = hazard_rows
        .into_iter()
        .filter_map(|mut row| {
            let key = row.remove("path")?.as_str()?.to_string();
            Some((key, row.remove("hazards").unwrap_or(json!(0))))
        })
        .collect();

    let files: Vec<Value> = rows
        .into_iter()
        .map(|mut row| {
            let path = row.get("current_path").and_then(Value::as_str).unwrap_or_default();
            let hazards = hazards_by_path.get(path).cloned().unwrap_or(json!(0));
            row.insert("open_hazards".to_string(), hazards);
            Value::Object(row)
        })
        .collect();

    Ok(json!({"scope": matched, "files": files}))
}

fn verification_gaps(storage: Option<&Storage>, repo: &Path, path: &str) -> Result<Value, String> {
    let Some(storage) = storage else {
        return Ok(live_verification_gaps(repo, path));
    };

    let is_prefix = query_rows(storage, "SELECT 1 AS x FROM unit_hazards WHERE path = ?1 LIMIT 1", &[path], &["x"])?.is_empty()
        && query_rows(storage, "SELECT 1 AS x FROM current_sarif_findings WHERE path = ?1 LIMIT 1", &[path], &["x"])?.is_empty();
    let arg = if is_prefix { format!("{path}%") } else { path.to_string() };
    let op = if is_prefix { "LIKE" } else { "=" };
    let hazard_sql = format!(
        "SELECT path, line, hazard_type, required_evidence, symbol, source AS snippet \
         FROM unit_hazards WHERE is_active = 1 AND path {op} ?1"
    );
    let finding_sql = format!(
        "SELECT path, start_line, rule_id, message FROM current_sarif_findings \
         WHERE (is_dark_arm = 1 OR rule_id LIKE 'test-miser.%') AND path {op} ?1"
    );
    let open_hazards = query_rows(
        storage,
        &hazard_sql,
        &[&arg],
        &["path", "line", "hazard_type", "required_evidence", "symbol", "snippet"],
    )?;
    let dark_arms = query_rows(storage, &finding_sql, &[&arg], &["path", "start_line", "rule_id", "message"])?;

    let mut out = json!({
        "scope": if is_prefix { format!("{path}*") } else { path.to_string() },
        "open_hazards": open_hazards,
        "dark_arms_and_weak_tests": dark_arms,
    });
    if is_prefix {
        out["note"] = json!(
            "directory scope: raw active-hazard count, not the verified/unverified evidence join a single-file lookup gets"
        );
    }
    Ok(out)
}

fn change_history(storage: &Storage, path: &str, limit: u32) -> Result<Value, String> {
    let limit_str = limit.to_string();
    let events = query_rows(
        storage,
        "SELECT commit_hash, event_type, timestamp, semantic_change, lines_added, lines_removed \
         FROM events WHERE path = ?1 ORDER BY timestamp DESC LIMIT ?2",
        &[path, &limit_str],
        &["commit_hash", "event_type", "timestamp", "semantic_change", "lines_added", "lines_removed"],
    )?;
    let crashes = query_rows(
        storage,
        "SELECT commit_hash, timestamp, error_class, is_verified FROM crash_events \
         WHERE path = ?1 ORDER BY timestamp DESC LIMIT ?2",
        &[path, &limit_str],
        &["commit_hash", "timestamp", "error_class", "is_verified"],
    )?;
    Ok(json!({"events": events, "crashes": crashes}))
}

fn find_definition(
    storage: &Storage,
    name: &str,
    path: Option<&str>,
    commit: Option<&str>,
) -> Result<Value, String> {
    let rows = storage.find_definitions(name, commit, path).map_err(|e| e.to_string())?;
    let definitions: Vec<Value> = rows
        .into_iter()
        .take(100)
        .map(|(path, line)| json!({"path": path, "line": line}))
        .collect();
    Ok(json!({"definitions": definitions}))
}

fn unit_context(storage: Option<&Storage>, repo: &Path, path: &str, line: u32) -> Result<Value, String> {
    let Some(storage) = storage else {
        return Ok(live_unit_context(repo, path, line));
    };

    let spans = storage.current_unit_spans_for_path(path).map_err(|e| e.to_string())?;
    let containing = spans
        .iter()
        .filter(|s| line >= s.start_line && line <= s.end_line)
        .min_by_key(|s| s.end_line - s.start_line)
        .ok_or_else(|| format!("no tracked unit contains {path}:{line}"))?;

    let unit_rows = query_rows(
        storage,
        "SELECT id, name, type, original_path, start_line, current_line_cov, current_mutant_cov, \
         current_distinct_tests, current_test_types, current_mutant_verified_tests, \
         current_mutant_killed_tests, is_hard_gated FROM logical_units WHERE id = ?1",
        &[containing.id.as_str()],
        &[
            "id", "name", "type", "original_path", "start_line", "current_line_cov",
            "current_mutant_cov", "current_distinct_tests", "current_test_types",
            "current_mutant_verified_tests", "current_mutant_killed_tests", "is_hard_gated",
        ],
    )?;
    let unit = unit_rows.into_iter().next().ok_or_else(|| format!("unit {} vanished", containing.id))?;

    let event_rows = query_rows(
        storage,
        "SELECT event_type, COUNT(*) AS count FROM events WHERE unit_id = ?1 GROUP BY event_type",
        &[containing.id.as_str()],
        &["event_type", "count"],
    )?;
    let event_counts: Map<String, Value> = event_rows
        .into_iter()
        .filter_map(|mut r| {
            let key = r.remove("event_type")?.as_str()?.to_string();
            Some((key, r.remove("count").unwrap_or(json!(0))))
        })
        .collect();

    let hazard_rows = query_rows(
        storage,
        include_str!("../../sql/ui/runtime/apply_hazards.sql"),
        &[path],
        &["line", "hazard_type", "required_evidence", "source", "evidence_present", "verified"],
    )?;
    let hazards: Vec<Value> = hazard_rows
        .into_iter()
        .filter(|r| {
            let l = r.get("line").and_then(Value::as_u64).unwrap_or(0) as u32;
            l >= containing.start_line && l <= containing.end_line
        })
        .map(|mut r| {
            let mut out = Map::new();
            out.insert("line".to_string(), r.remove("line").unwrap_or(Value::Null));
            out.insert("hazard_type".to_string(), r.remove("hazard_type").unwrap_or(Value::Null));
            out.insert("required_evidence".to_string(), r.remove("required_evidence").unwrap_or(Value::Null));
            out.insert("verified".to_string(), r.remove("verified").unwrap_or(Value::Null));
            out.insert("snippet".to_string(), r.remove("source").unwrap_or(Value::Null));
            Value::Object(out)
        })
        .collect();

    let hotness_rows = query_rows(
        storage,
        include_str!("../../sql/ui/runtime/apply_hotness.sql"),
        &[path],
        &["function", "line", "flat_share", "cum_share", "tier", "source"],
    )?;
    let hotness: Vec<Value> = hotness_rows
        .into_iter()
        .filter(|r| {
            r.get("line")
                .and_then(Value::as_u64)
                .map(|l| l as u32 >= containing.start_line && l as u32 <= containing.end_line)
                .unwrap_or(false)
        })
        .map(|r| json!({"line": r["line"], "tier": r["tier"], "cum_share": r["cum_share"], "source": r["source"]}))
        .collect();

    let findings: Vec<Value> = storage
        .sarif_findings_for_path(path)
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter(|f| f.start_line >= containing.start_line && f.start_line <= containing.end_line)
        .map(|f| {
            json!({
                "rule_id": f.rule_id, "level": f.level, "message": f.message,
                "start_line": f.start_line, "source": f.source, "is_dark_arm": f.is_dark_arm,
            })
        })
        .collect();

    let mut out = json!({
        "unit": unit,
        "span": [containing.start_line, containing.end_line],
        "event_counts": event_counts,
        "hazards": hazards,
        "hotness": hotness,
        "findings": findings,
    });

    // Uncommitted/added-but-not-committed changes: if the file has a dirty
    // working-tree status, the DB's hazard rows may be stale (computed at
    // the last commit's content, not what's on disk now). For languages
    // Lineage already scans in-process (rust/go/zig/c/cpp/csharp), rescan
    // live disk content directly - no subprocess, no DB write - and report
    // it as a distinct `live_hazards` field rather than silently merging it
    // into (possibly stale) `hazards`. See docs/agents/mcp.md.
    if let Some(status) = git_dirty_status(repo, path) {
        if let Some(live) = live_rescan_hazards(repo, path, containing.start_line, containing.end_line) {
            out["dirty"] = json!(status);
            out["live_hazards"] = json!(live);
            out["note"] = json!(
                "path has uncommitted changes; `hazards` may be stale (last-known-commit data), \
                 `live_hazards` was just rescanned from disk"
            );
        } else {
            out["dirty"] = json!(status);
            out["note"] = json!(
                "path has uncommitted changes; `hazards` may be stale (last-known-commit data). \
                 No in-process live scanner for this file's language, so no live_hazards."
            );
        }
    }

    Ok(out)
}

// ---------------------------------------------------------------------------
// Uncommitted-changes support: git2 working-tree status (not GitProvider,
// which is intentionally committed-history-only), plus live in-process
// rescanning reusing hazard.rs's own scan_*_sites functions - the same code
// `lineage ingest-hazards` uses, just pointed at disk instead of a git blob.
// ---------------------------------------------------------------------------

/// Returns a short status label if `path` has uncommitted or
/// added-but-not-committed changes, `None` if clean or not in a git repo.
fn git_dirty_status(repo: &Path, path: &str) -> Option<&'static str> {
    let git_repo = git2::Repository::open(repo).ok()?;
    let status = git_repo.status_file(Path::new(path)).ok()?;
    if status.intersects(git2::Status::WT_NEW | git2::Status::INDEX_NEW) {
        Some("added-not-committed")
    } else if status.intersects(
        git2::Status::WT_MODIFIED
            | git2::Status::INDEX_MODIFIED
            | git2::Status::WT_TYPECHANGE
            | git2::Status::INDEX_TYPECHANGE,
    ) {
        Some("uncommitted-changes")
    } else {
        None
    }
}

fn hazard_scan_fn(path: &str) -> Option<fn(&str, &str) -> Vec<HazardSite>> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".rs") {
        Some(scan_rust_sites)
    } else if lower.ends_with(".go") {
        Some(scan_go_sites)
    } else if lower.ends_with(".zig") {
        Some(scan_zig_sites)
    } else if lower.ends_with(".c") || lower.ends_with(".h") {
        Some(scan_c_sites)
    } else if [".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"].iter().any(|s| lower.ends_with(s)) {
        Some(scan_cpp_sites)
    } else if lower.ends_with(".cs") {
        Some(scan_csharp_sites)
    } else {
        None
    }
}

fn live_rescan_hazards(repo: &Path, path: &str, start_line: u32, end_line: u32) -> Option<Vec<Value>> {
    let scan = hazard_scan_fn(path)?;
    let contents = fs::read_to_string(repo.join(path)).ok()?;
    Some(
        scan(path, &contents)
            .into_iter()
            .filter(|site| site.line >= start_line && site.line <= end_line)
            .map(|site| {
                json!({
                    "line": site.line,
                    "hazard_type": site.hazard_type,
                    "required_evidence": site.required_evidence,
                    "snippet": site.source,
                })
            })
            .collect(),
    )
}

/// `unit_context` with no `lineage.db` at all: structure comes from the
/// same git-decoupled `HeuristicExtractor` the UI already runs against live
/// disk content (`source_symbols_from_current_file`); hazards come from the
/// same live in-process rescan used for the dirty-file case above. No
/// history, coverage, mutation, or hotness data exists without a database.
fn live_unit_context(repo: &Path, path: &str, line: u32) -> Value {
    let full_path = repo.join(path);
    let contents = match fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("cannot read {path}: {e}")}),
    };
    let extractor = HeuristicExtractor::new(SourceFilter::code_defaults());
    let blob = BlobFile { path: path.to_string(), contents: contents.clone() };
    let containing = extractor
        .extract_units(&blob)
        .into_iter()
        .filter(|u| line >= u.start_line && line <= u.end_line)
        .min_by_key(|u| u.end_line - u.start_line);
    let Some(unit) = containing else {
        return json!({"error": format!("no unit contains {path}:{line} (heuristic extraction, no DB)")});
    };
    let live_hazards = hazard_scan_fn(path).map(|scan| {
        scan(path, &contents)
            .into_iter()
            .filter(|site| site.line >= unit.start_line && site.line <= unit.end_line)
            .map(|site| {
                json!({
                    "line": site.line, "hazard_type": site.hazard_type,
                    "required_evidence": site.required_evidence, "snippet": site.source,
                })
            })
            .collect::<Vec<_>>()
    });
    json!({
        "unit": {"name": unit.name, "type": unit.kind.as_str(), "original_path": unit.path, "start_line": unit.start_line},
        "span": [unit.start_line, unit.end_line],
        "live_hazards": live_hazards,
        "note": "no lineage.db: structure via live heuristic extraction, hazards via live in-process \
                 rescan (rust/go/zig/c/cpp/csharp only). No history, coverage, mutation, or hotness \
                 data available without a database.",
    })
}

fn live_verification_gaps(repo: &Path, path: &str) -> Value {
    let full_path = repo.join(path);
    let contents = match fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("cannot read {path}: {e}")}),
    };
    let Some(scan) = hazard_scan_fn(path) else {
        return json!({
            "scope": path,
            "open_hazards": [],
            "note": "no lineage.db and no in-process hazard scanner for this file's language \
                     (rust/go/zig/c/cpp/csharp only)",
        });
    };
    let open_hazards: Vec<Value> = scan(path, &contents)
        .into_iter()
        .map(|site| {
            json!({
                "path": site.path, "line": site.line, "hazard_type": site.hazard_type,
                "required_evidence": site.required_evidence, "snippet": site.source,
            })
        })
        .collect();
    json!({
        "scope": path,
        "open_hazards": open_hazards,
        "note": "no lineage.db: live in-process rescan only, no evidence join, no dark-arm/weak-test data",
    })
}
