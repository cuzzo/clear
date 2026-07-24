//! MCP server: exposes `gigasail.db` (and, for a bounded set of static
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

use crate::diff_service::{build_structured_diff, DiffRequest};
use crate::extract::{BoundaryExtractor, HeuristicExtractor, SourceFilter};
use crate::git::GitProvider;
use crate::hazard::{
    scan_c_sites, scan_cpp_sites, scan_csharp_sites, scan_go_sites, scan_rust_sites,
    scan_zig_sites, HazardSite,
};
use crate::model::BlobFile;
use crate::pipeline::load_config;
use crate::review::ReviewMode;
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

/// Serve `giga_*` tools over stdio JSON-RPC, newline-delimited (per the
/// MCP spec - unlike LSP, there is no Content-Length framing here). `db` is
/// optional: omitting it runs in
/// DB-less mode (see `docs/agents/mcp.md`), where only the tools/fields
/// derivable from live disk content are available.
pub async fn serve_mcp(db: Option<PathBuf>, repo: PathBuf) -> Result<()> {
    // The `.giga/` directory holding the coordination lock, alongside the DB.
    let giga_dir = db.as_ref().and_then(|path| path.parent()).map(Path::to_path_buf);
    let storage = match db {
        Some(path) => {
            if !path.is_file() {
                anyhow::bail!(
                    "gigasail database not found: {} (run `gigasail init`/`gigasail build` first, or omit --db for DB-less mode)",
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
        giga_dir,
    };
    let transport = rmcp::transport::stdio();
    let service = handler.serve(transport).await?;
    service.waiting().await?;
    Ok(())
}

struct LineageMcp {
    storage: Mutex<Option<Storage>>,
    repo: PathBuf,
    giga_dir: Option<PathBuf>,
}

impl LineageMcp {
    /// Block while a `giga watch` is analysing the repo's current HEAD, so a
    /// tool call reads a fully ingested database rather than a half-written one.
    /// Runs the blocking poll off the async executor. Best-effort: no-op when
    /// there is no DB directory or HEAD cannot be resolved.
    async fn wait_for_head_analysis(&self) {
        let Some(dir) = self.giga_dir.clone() else {
            return;
        };
        let repo = self.repo.clone();
        let _ = tokio::task::spawn_blocking(move || {
            if let Ok(provider) = crate::git::GitProvider::open(&repo) {
                if let Ok(commit) = provider.resolve_commit("HEAD") {
                    let _ = giga_core::lock::wait_while_locked_for(
                        &dir,
                        &commit,
                        std::time::Duration::from_secs(600),
                        std::time::Duration::from_millis(250),
                        |_| {},
                    );
                }
            }
        })
        .await;
    }
}

fn tool_defs() -> Vec<Tool> {
    let obj = |v: Value| -> std::sync::Arc<Map<String, Value>> {
        std::sync::Arc::new(v.as_object().cloned().unwrap_or_default())
    };
    vec![
        Tool::new(
            "giga_file_risk",
            "Coverage, mutation coverage, and open-hazard counts for a file or a directory \
             prefix. Call before editing unfamiliar code to learn whether it is well-verified. \
             Requires a gigasail.db.",
            obj(json!({
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Repo-relative file path or directory prefix"}},
                "required": ["path"]
            })),
        ),
        Tool::new(
            "giga_unit_context",
            "Full context for the function/unit containing a specific line: risk, test \
             coverage, mutation status, open hazards, runtime hotness, and static findings in \
             its range. The richest tool - call before modifying a specific function. Works \
             without a gigasail.db (structure + live hazard scan only, no history/coverage). If \
             the file has uncommitted or added-but-not-committed changes, hazards are \
             live-rescanned from disk for languages Gigasail scans in-process (rust/go/zig/c/\
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
            "giga_verification_gaps",
            "Open hazards lacking evidence, dead/dark branch arms, and zero-kill (weak) tests \
             in a file or directory. Call before trusting a coverage percentage at face value. \
             Without a gigasail.db, only a live hazard scan is available (no evidence join, no \
             dark-arm/weak-test data).",
            obj(json!({
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Repo-relative file path or directory prefix"}},
                "required": ["path"]
            })),
        ),
        Tool::new(
            "giga_change_history",
            "Recent commit-level events (changes/moves/fixes) and production crash occurrences \
             for a file. Call before a risky refactor to see how fragile the area has been. \
             Requires a gigasail.db.",
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
            "giga_find_definition",
            "Resolve a symbol name to its definition location(s) by rename-stable logical-unit \
             identity, not text search. Requires a gigasail.db.",
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
        Tool::new(
            "giga_precommit",
            "Review the change you just made (default HEAD~1..HEAD): a pass/needs_review/critical \
             verdict plus the gates it triggered and the ranked new findings by tier, with each \
             finding's coverage posture. Call before declaring work done - a `critical` verdict \
             blocks. Returns a compact verdict, not raw test output. Requires a gigasail.db.",
            obj(json!({
                "type": "object",
                "properties": {
                    "base": {"type": "string", "description": "Base revision (default: HEAD's first parent)"},
                    "head": {"type": "string", "description": "Head revision (default: HEAD)"}
                }
            })),
        ),
        Tool::new(
            "giga_premerge",
            "Review everything a branch introduces before merging: the same verdict as \
             giga_precommit but over merge-base(head, target)..head, i.e. the whole branch. Call \
             before a merge/PR. Requires a gigasail.db.",
            obj(json!({
                "type": "object",
                "properties": {
                    "target": {"type": "string", "description": "Branch being merged into (default: master)"},
                    "head": {"type": "string", "description": "Branch tip to review (default: HEAD)"}
                }
            })),
        ),
    ]
}

impl ServerHandler for LineageMcp {
    fn get_info(&self) -> rmcp::model::ServerInfo {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new(
                "gigasail-mcp",
                env!("CARGO_PKG_VERSION"),
            ))
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
        // Wait out any in-flight analysis of HEAD before reading, so tool
        // results reflect a complete database.
        self.wait_for_head_analysis().await;
        let args = request.arguments.unwrap_or_default();
        let storage = self.storage.lock().unwrap();
        let tool_name = request.name.as_ref();
        if tool_defs().iter().all(|t| t.name != tool_name) {
            return Err(McpError::invalid_params(
                format!("unknown tool: {tool_name}"),
                None,
            ));
        }
        let dispatch = || -> Result<Value, String> {
            match tool_name {
                "giga_file_risk" => file_risk(
                    require_db(&storage, "giga_file_risk")?,
                    arg_str(&args, "path")?,
                ),
                "giga_unit_context" => unit_context(
                    storage.as_ref(),
                    &self.repo,
                    arg_str(&args, "path")?,
                    arg_u32(&args, "line")?,
                ),
                "giga_verification_gaps" => {
                    verification_gaps(storage.as_ref(), &self.repo, arg_str(&args, "path")?)
                }
                "giga_change_history" => change_history(
                    require_db(&storage, "giga_change_history")?,
                    arg_str(&args, "path")?,
                    arg_u32_opt(&args, "limit").unwrap_or(20),
                ),
                "giga_find_definition" => find_definition(
                    require_db(&storage, "giga_find_definition")?,
                    arg_str(&args, "name")?,
                    args.get("path").and_then(Value::as_str),
                    args.get("commit").and_then(Value::as_str),
                ),
                "giga_precommit" => review(
                    require_db(&storage, "giga_precommit")?,
                    &self.repo,
                    ReviewMode::Precommit,
                    args.get("base").and_then(Value::as_str),
                    args.get("head").and_then(Value::as_str),
                    None,
                ),
                "giga_premerge" => review(
                    require_db(&storage, "giga_premerge")?,
                    &self.repo,
                    ReviewMode::Premerge,
                    None,
                    args.get("head").and_then(Value::as_str),
                    Some(args.get("target").and_then(Value::as_str).unwrap_or("master")),
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

/// `giga_precommit` / `giga_premerge`: build the review DiffPlan and run the
/// shared evaluator over the repo's `review:` config. Returns the compact
/// verdict report (verdict + gates + ranked findings), never raw test output.
fn review(
    storage: &Storage,
    repo: &Path,
    mode: ReviewMode,
    base: Option<&str>,
    head: Option<&str>,
    target: Option<&str>,
) -> Result<Value, String> {
    let provider = GitProvider::open(repo).map_err(|e| e.to_string())?;
    // Resolve the range: pre-merge diffs merge-base(head, target)..head; pre-commit
    // uses the given base or falls back to HEAD's first parent (base = None).
    let (base_revision, head_revision) = if let Some(target) = target {
        let head_ref = head.unwrap_or("HEAD");
        let mb = provider
            .merge_base(head_ref, target)
            .map_err(|e| e.to_string())?;
        (Some(mb), Some(head_ref.to_string()))
    } else {
        (
            base.map(str::to_string),
            Some(head.unwrap_or("HEAD").to_string()),
        )
    };
    let request = DiffRequest {
        base_revision,
        head_revision,
        coverage_source: None,
        sarif_source: None,
        selection: None,
        mutant_corpus: None,
        test_set: None,
    };
    let plan =
        build_structured_diff(&provider, Some(storage), &request).map_err(|e| e.to_string())?;
    // Missing giga.yml → default review policy (gate only on uncovered T1).
    let config = load_config(repo).map(|c| c.review).unwrap_or_default();
    let report = crate::review::evaluate(&plan, &config, mode);
    serde_json::to_value(report).map_err(|e| e.to_string())
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
        .ok_or_else(|| format!("{tool} requires a gigasail.db; server was started without --db"))
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
        .query_map(params_from_iter(params.iter()), |row| {
            row_to_object(row, names)
        })
        .map_err(|e| e.to_string())?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())
}

/// Joins `path` onto `repo` and verifies the result cannot escape `repo` -
/// an absolute `path` (`Path::join` discards the base entirely for those)
/// or a `../` traversal would otherwise let a caller read arbitrary host
/// files through an MCP tool that is only ever supposed to expose one
/// repository's own tracked content. Both sides are canonicalized so a
/// symlink inside `repo` pointing back within it still resolves, and the
/// comparison isn't fooled by non-canonical `.`/`..` segments; the target
/// must already exist on disk (every caller here only ever reads a file
/// that should be present, so this is not an added restriction in
/// practice).
fn resolve_repo_relative_path(repo: &Path, path: &str) -> Option<PathBuf> {
    if Path::new(path).is_absolute() {
        return None;
    }
    let repo_root = repo.canonicalize().ok()?;
    let joined = repo_root.join(path).canonicalize().ok()?;
    joined.starts_with(&repo_root).then_some(joined)
}

/// Escapes SQL LIKE metacharacters (`%`, `_`, and the escape character
/// itself) in a caller-supplied path before it becomes a LIKE pattern.
/// Every LIKE clause built from `path` pairs this with `ESCAPE '\'` -
/// without it, a path containing `%` or `_` (a real, if unusual, path
/// component - or an adversarial one) would have those characters
/// reinterpreted as wildcards instead of matched literally, silently
/// broadening the query beyond the directory scope the caller asked for.
fn escape_like_pattern(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// Try an exact-path match; if empty, retry as a `path%` prefix (directory
/// scope). Mirrors the Ruby MVP's `resolve_path_or_prefix`. `sql_prefix`
/// must end its LIKE clause with `ESCAPE '\'` to match `prefix_arg`'s
/// escaping.
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
    let prefix_arg = format!("{}%", escape_like_pattern(path));
    let rows = query_rows(storage, sql_prefix, &[&prefix_arg], names)?;
    Ok((rows, format!("{path}*")))
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

// Weights each unit's contribution to avg_line_coverage/avg_mutant_coverage
// by its current line count (end_line - start_line + 1), not a flat 1-per-
// unit average - otherwise a 3-line getter and a 200-line function count
// equally, and a file dominated by many tiny well-tested units plus one
// large undertested one reports a misleadingly healthy average. Line span
// per unit uses the same first-commit fallback chain as
// current_unit_spans_for_path.sql (a unit's creating commit has no
// `events` row yet, so it degrades to logical_units.start_line as a
// single-line span until a real change/move/fix event exists). Units with
// NULL current_line_cov/current_mutant_cov are excluded from both the
// numerator and denominator of their respective average, not treated as
// zero - "never measured" must not silently drag the average down as if
// it were "measured and uncovered".
/// `clause` is the full `current_path` predicate, e.g. `"= ?1"` or
/// `"LIKE ?1 ESCAPE '\\'"` - the LIKE variant must carry its own ESCAPE
/// clause so `resolve_path_or_prefix`'s escaped prefix argument is
/// interpreted correctly.
fn file_risk_sql(clause: &str) -> String {
    format!(
        "WITH latest_events AS (
           SELECT * FROM (
             SELECT e.*,
                    ROW_NUMBER() OVER (PARTITION BY e.unit_id ORDER BY e.timestamp DESC, e.id DESC) AS rank
             FROM events e
           ) WHERE rank = 1
         ),
         current_units AS (
           SELECT u.id,
                  COALESCE(le.path, u.original_path) AS current_path,
                  COALESCE(le.start_line, u.start_line, 1) AS start_line,
                  COALESCE(le.end_line, le.start_line, u.start_line, 1) AS end_line,
                  u.current_line_cov, u.current_mutant_cov,
                  u.current_distinct_tests, u.is_hard_gated
           FROM logical_units u
           LEFT JOIN latest_events le ON le.unit_id = u.id
         )
         SELECT current_path,
                COUNT(*) AS units,
                ROUND(
                  SUM(CASE WHEN current_line_cov IS NOT NULL THEN current_line_cov * (end_line - start_line + 1) ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN current_line_cov IS NOT NULL THEN (end_line - start_line + 1) ELSE 0 END), 0),
                1) AS avg_line_coverage,
                ROUND(
                  SUM(CASE WHEN current_mutant_cov IS NOT NULL THEN current_mutant_cov * (end_line - start_line + 1) ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN current_mutant_cov IS NOT NULL THEN (end_line - start_line + 1) ELSE 0 END), 0),
                1) AS avg_mutant_coverage,
                SUM(current_distinct_tests) AS total_distinct_tests,
                SUM(CASE WHEN is_hard_gated = 1 THEN 1 ELSE 0 END) AS hard_gated_units
         FROM current_units
         WHERE current_path {clause}
         GROUP BY current_path"
    )
}

fn file_risk(storage: &Storage, path: &str) -> Result<Value, String> {
    let names = [
        "current_path",
        "units",
        "avg_line_coverage",
        "avg_mutant_coverage",
        "total_distinct_tests",
        "hard_gated_units",
    ];
    let (rows, matched) = resolve_path_or_prefix(
        storage,
        &file_risk_sql("= ?1"),
        &file_risk_sql("LIKE ?1 ESCAPE '\\'"),
        path,
        &names,
    )?;
    if rows.is_empty() {
        return Err(format!(
            "no tracked units under {path:?} (run `gigasail build` first?)"
        ));
    }

    let is_prefix = matched.ends_with('*');
    let hazard_sql = if is_prefix {
        "SELECT path, COUNT(*) AS hazards FROM unit_hazards WHERE is_active = 1 AND path LIKE ?1 ESCAPE '\\' GROUP BY path"
    } else {
        "SELECT path, COUNT(*) AS hazards FROM unit_hazards WHERE is_active = 1 AND path = ?1 GROUP BY path"
    };
    let hazard_arg = if is_prefix {
        format!("{}%", escape_like_pattern(path))
    } else {
        path.to_string()
    };
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
            let path = row
                .get("current_path")
                .and_then(Value::as_str)
                .unwrap_or_default();
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

    let is_prefix = query_rows(
        storage,
        "SELECT 1 AS x FROM unit_hazards WHERE path = ?1 LIMIT 1",
        &[path],
        &["x"],
    )?
    .is_empty()
        && query_rows(
            storage,
            "SELECT 1 AS x FROM current_sarif_findings WHERE path = ?1 LIMIT 1",
            &[path],
            &["x"],
        )?
        .is_empty();
    let arg = if is_prefix {
        format!("{}%", escape_like_pattern(path))
    } else {
        path.to_string()
    };
    let op = if is_prefix {
        "LIKE ?1 ESCAPE '\\'"
    } else {
        "= ?1"
    };
    let hazard_sql = format!(
        "SELECT path, line, hazard_type, required_evidence, symbol, source AS snippet \
         FROM unit_hazards WHERE is_active = 1 AND path {op}"
    );
    let finding_sql = format!(
        "SELECT path, start_line, rule_id, message FROM current_sarif_findings \
         WHERE (is_dark_arm = 1 OR rule_id LIKE 'test-miser.%') AND path {op}"
    );
    let open_hazards = query_rows(
        storage,
        &hazard_sql,
        &[&arg],
        &[
            "path",
            "line",
            "hazard_type",
            "required_evidence",
            "symbol",
            "snippet",
        ],
    )?;
    let dark_arms = query_rows(
        storage,
        &finding_sql,
        &[&arg],
        &["path", "start_line", "rule_id", "message"],
    )?;

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
        &[
            "commit_hash",
            "event_type",
            "timestamp",
            "semantic_change",
            "lines_added",
            "lines_removed",
        ],
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
    let rows = storage
        .find_definitions(name, commit, path)
        .map_err(|e| e.to_string())?;
    let definitions: Vec<Value> = rows
        .into_iter()
        .take(100)
        .map(|(path, line)| json!({"path": path, "line": line}))
        .collect();
    Ok(json!({"definitions": definitions}))
}

fn unit_context(
    storage: Option<&Storage>,
    repo: &Path,
    path: &str,
    line: u32,
) -> Result<Value, String> {
    let Some(storage) = storage else {
        return Ok(live_unit_context(repo, path, line));
    };

    let spans = storage
        .current_unit_spans_for_path(path)
        .map_err(|e| e.to_string())?;
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
            "id",
            "name",
            "type",
            "original_path",
            "start_line",
            "current_line_cov",
            "current_mutant_cov",
            "current_distinct_tests",
            "current_test_types",
            "current_mutant_verified_tests",
            "current_mutant_killed_tests",
            "is_hard_gated",
        ],
    )?;
    let unit = unit_rows
        .into_iter()
        .next()
        .ok_or_else(|| format!("unit {} vanished", containing.id))?;

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
        giga_core::storage::APPLY_HAZARDS_SQL,
        &[path],
        &[
            "line",
            "hazard_type",
            "required_evidence",
            "source",
            "evidence_present",
            "verified",
        ],
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
            out.insert(
                "hazard_type".to_string(),
                r.remove("hazard_type").unwrap_or(Value::Null),
            );
            out.insert(
                "required_evidence".to_string(),
                r.remove("required_evidence").unwrap_or(Value::Null),
            );
            out.insert(
                "verified".to_string(),
                r.remove("verified").unwrap_or(Value::Null),
            );
            out.insert(
                "snippet".to_string(),
                r.remove("source").unwrap_or(Value::Null),
            );
            Value::Object(out)
        })
        .collect();

    let hotness_rows = query_rows(
        storage,
        giga_core::storage::APPLY_HOTNESS_SQL,
        &[path],
        &[
            "function",
            "line",
            "flat_share",
            "cum_share",
            "tier",
            "source",
        ],
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
    // Gigasail already scans in-process (rust/go/zig/c/cpp/csharp), rescan
    // live disk content directly - no subprocess, no DB write - and report
    // it as a distinct `live_hazards` field rather than silently merging it
    // into (possibly stale) `hazards`. See docs/agents/mcp.md.
    if let Some(status) = git_dirty_status(repo, path) {
        if let Some(live) =
            live_rescan_hazards(repo, path, containing.start_line, containing.end_line)
        {
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
// `gigasail ingest-hazards` uses, just pointed at disk instead of a git blob.
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
    } else if [".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"]
        .iter()
        .any(|s| lower.ends_with(s))
    {
        Some(scan_cpp_sites)
    } else if lower.ends_with(".cs") {
        Some(scan_csharp_sites)
    } else {
        None
    }
}

fn live_rescan_hazards(
    repo: &Path,
    path: &str,
    start_line: u32,
    end_line: u32,
) -> Option<Vec<Value>> {
    let scan = hazard_scan_fn(path)?;
    let contents = fs::read_to_string(resolve_repo_relative_path(repo, path)?).ok()?;
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

/// `unit_context` with no `gigasail.db` at all: structure comes from the
/// same git-decoupled `HeuristicExtractor` the UI already runs against live
/// disk content (`source_symbols_from_current_file`); hazards come from the
/// same live in-process rescan used for the dirty-file case above. No
/// history, coverage, mutation, or hotness data exists without a database.
fn live_unit_context(repo: &Path, path: &str, line: u32) -> Value {
    let Some(full_path) = resolve_repo_relative_path(repo, path) else {
        return json!({"error": format!("cannot read {path}: outside the repository or does not exist")});
    };
    let contents = match fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("cannot read {path}: {e}")}),
    };
    let extractor = HeuristicExtractor::new(SourceFilter::code_defaults());
    let blob = BlobFile {
        path: path.to_string(),
        contents: contents.clone(),
    };
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
        "note": "no gigasail.db: structure via live heuristic extraction, hazards via live in-process \
                 rescan (rust/go/zig/c/cpp/csharp only). No history, coverage, mutation, or hotness \
                 data available without a database.",
    })
}

fn live_verification_gaps(repo: &Path, path: &str) -> Value {
    let Some(full_path) = resolve_repo_relative_path(repo, path) else {
        return json!({"error": format!("cannot read {path}: outside the repository or does not exist")});
    };
    let contents = match fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("cannot read {path}: {e}")}),
    };
    let Some(scan) = hazard_scan_fn(path) else {
        return json!({
            "scope": path,
            "open_hazards": [],
            "note": "no gigasail.db and no in-process hazard scanner for this file's language \
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
        "note": "no gigasail.db: live in-process rescan only, no evidence join, no dark-arm/weak-test data",
    })
}

// ---------------------------------------------------------------------------
// Uncommitted-changes tests. Integration-style, not mocked: real temp git
// repositories driven through the real `git` CLI, real source files on disk
// in the languages hazard.rs actually scans, and golden expected output -
// mirroring the fixture-building convention already used by
// test/mcp_server_test.rb and test/lsp_integration_test.rb, just in-process
// so `cargo llvm-cov` can measure it directly instead of needing a spawned
// binary.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Event, EventType, LogicalUnit, UnitKind};
    use std::process::Command;
    use tempfile::TempDir;

    fn git(repo: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(repo)
            .status()
            .expect("git spawn failed");
        assert!(status.success(), "git {args:?} failed in {repo:?}");
    }

    fn init_repo() -> TempDir {
        let dir = TempDir::new().unwrap();
        git(dir.path(), &["init", "-q"]);
        git(dir.path(), &["config", "user.email", "t@t"]);
        git(dir.path(), &["config", "user.name", "t"]);
        dir
    }

    fn write(dir: &Path, rel: &str, contents: &str) {
        let full = dir.join(rel);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(full, contents).unwrap();
    }

    fn commit(dir: &Path, message: &str) {
        git(dir, &["add", "-A"]);
        git(dir, &["commit", "-q", "-m", message]);
    }

    // --- git_dirty_status ---------------------------------------------

    #[test]
    fn git_dirty_status_is_none_outside_a_git_repo() {
        let dir = TempDir::new().unwrap();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        assert_eq!(git_dirty_status(dir.path(), "src/lib.rs"), None);
    }

    #[test]
    fn git_dirty_status_is_none_for_a_clean_tracked_file() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        commit(dir.path(), "init");
        assert_eq!(git_dirty_status(dir.path(), "src/lib.rs"), None);
    }

    #[test]
    fn git_dirty_status_detects_an_untracked_added_file() {
        let dir = init_repo();
        write(dir.path(), "README.md", "seed commit\n");
        commit(dir.path(), "init");
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        // Never `git add`ed: untracked.
        assert_eq!(
            git_dirty_status(dir.path(), "src/lib.rs"),
            Some("added-not-committed")
        );
    }

    #[test]
    fn git_dirty_status_detects_a_staged_added_file() {
        let dir = init_repo();
        write(dir.path(), "README.md", "seed commit\n");
        commit(dir.path(), "init");
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        git(dir.path(), &["add", "src/lib.rs"]);
        assert_eq!(
            git_dirty_status(dir.path(), "src/lib.rs"),
            Some("added-not-committed")
        );
    }

    #[test]
    fn git_dirty_status_detects_an_unstaged_modification() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        commit(dir.path(), "init");
        write(dir.path(), "src/lib.rs", "fn f() { 1 }\n");
        assert_eq!(
            git_dirty_status(dir.path(), "src/lib.rs"),
            Some("uncommitted-changes")
        );
    }

    #[test]
    fn git_dirty_status_detects_a_staged_modification() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        commit(dir.path(), "init");
        write(dir.path(), "src/lib.rs", "fn f() { 1 }\n");
        git(dir.path(), &["add", "src/lib.rs"]);
        assert_eq!(
            git_dirty_status(dir.path(), "src/lib.rs"),
            Some("uncommitted-changes")
        );
    }

    #[test]
    fn git_dirty_status_is_none_for_a_path_git2_cannot_status() {
        // status_file expects a single tracked-file-shaped path, not a
        // directory prefix; git2 errors rather than returning a status,
        // which exercises the `.ok()?` failure arm on the status_file call
        // itself (distinct from the earlier Repository::open failure arm).
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        commit(dir.path(), "init");
        assert_eq!(git_dirty_status(dir.path(), "src"), None);
    }

    // --- hazard_scan_fn --------------------------------------------------

    // Behavioral, not identity, comparison: `fn` pointer equality is not a
    // reliable way to prove "the right scanner was picked" (the compiler
    // may merge or duplicate identical-codegen functions), so each case
    // instead runs the dispatched scanner against a real per-language
    // hazard-triggering snippet and checks the specific hazard type that
    // comes back - proving both correct routing and a working scanner.
    #[test]
    fn hazard_scan_fn_dispatches_every_supported_extension() {
        let cases: &[(&str, &str, &str)] = &[
            ("src/lib.rs", "pub fn f() {\n    unsafe { std::ptr::null::<i32>(); }\n}\n", "rust_unsafe_block"),
            ("src/LIB.RS", "pub fn f() {\n    unsafe { std::ptr::null::<i32>(); }\n}\n", "rust_unsafe_block"),
            ("main.go", "package demo\n\nfunc run() {\n    ch <- 1\n}\n", "go_concurrency_channel"),
            (
                "runtime/lib.zig",
                "// HAMMER-WAIT-LOOP-BEGIN\nwhile (true) {}\n// HAMMER-WAIT-LOOP-END\n",
                "zig_wait_loop",
            ),
            ("core.c", "void run(void) {\n    pthread_mutex_lock(&lock);\n}\n", "c_tsan_concurrency"),
            ("core.h", "void run(void) {\n    pthread_mutex_lock(&lock);\n}\n", "c_tsan_concurrency"),
            ("core.cc", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            ("core.cpp", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            ("core.cxx", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            ("core.hh", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            ("core.hpp", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            ("core.hxx", "void run() {\n    std::atomic<int> ready;\n}\n", "cpp_tsan_concurrency"),
            (
                "Program.cs",
                "public class Worker {\n    public void Run() {\n        Task.Run(() => {});\n    }\n}\n",
                "csharp_concurrency",
            ),
        ];
        for (path, source, expected_hazard) in cases {
            let scan =
                hazard_scan_fn(path).unwrap_or_else(|| panic!("expected a scanner for {path}"));
            let sites = scan(path, source);
            assert!(
                sites.iter().any(|s| s.hazard_type == *expected_hazard),
                "expected {expected_hazard} for {path}, got {sites:?}"
            );
        }

        assert!(hazard_scan_fn("script.rb").is_none());
        assert!(hazard_scan_fn("no_extension_at_all").is_none());
    }

    // --- live_rescan_hazards ----------------------------------------------

    #[test]
    fn live_rescan_hazards_finds_and_line_filters_a_real_unsafe_block() {
        let dir = init_repo();
        write(
            dir.path(),
            "src/lib.rs",
            "pub fn a() -> i32 {\n    let p = &1 as *const i32;\n    unsafe { *p }\n}\n\npub fn b() -> i32 {\n    let p = &2 as *const i32;\n    unsafe { *p }\n}\n",
        );
        // Uncommitted: irrelevant to this function directly (it doesn't
        // check git status itself), but matches how it's actually called -
        // only after git_dirty_status has already said "dirty".
        let all = live_rescan_hazards(dir.path(), "src/lib.rs", 1, 100).unwrap();
        assert_eq!(
            all.len(),
            2,
            "expected one unsafe block per function, got {all:?}"
        );

        let scoped = live_rescan_hazards(dir.path(), "src/lib.rs", 1, 4).unwrap();
        assert_eq!(
            scoped.len(),
            1,
            "line-range filter must exclude b()'s hazard: {scoped:?}"
        );
        assert_eq!(scoped[0]["hazard_type"], "rust_unsafe_block");
        assert_eq!(scoped[0]["line"], 3);
        assert_eq!(scoped[0]["snippet"], "unsafe { *p }");
    }

    #[test]
    fn live_rescan_hazards_is_none_for_an_unsupported_language() {
        let dir = init_repo();
        write(dir.path(), "src/worker.rb", "def run\n  1\nend\n");
        assert_eq!(
            live_rescan_hazards(dir.path(), "src/worker.rb", 1, 10),
            None
        );
    }

    #[test]
    fn live_rescan_hazards_is_none_when_the_file_does_not_exist_on_disk() {
        let dir = init_repo();
        assert_eq!(
            live_rescan_hazards(dir.path(), "src/missing.rs", 1, 10),
            None
        );
    }

    // --- path containment (resolve_repo_relative_path) -----------------

    // Real bug: `repo.join(path)` was fed straight to `fs::read_to_string`
    // with no containment check. `Path::join` discards the base entirely
    // when the joined-on path is absolute, and never resolves `../`
    // segments itself - so an MCP tool meant to expose only one
    // repository's own tracked content could be made to read (and
    // hazard-scan) arbitrary files elsewhere on the host.
    #[test]
    fn resolve_repo_relative_path_rejects_absolute_paths() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        assert_eq!(resolve_repo_relative_path(dir.path(), "/etc/passwd"), None);
    }

    #[test]
    fn resolve_repo_relative_path_rejects_parent_directory_traversal() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        // A file that genuinely exists one level above the repo root -
        // proving this fails because of containment, not a missing file.
        let outside = dir.path().parent().unwrap().join("outside-secret.txt");
        fs::write(&outside, "outside\n").unwrap();
        assert_eq!(
            resolve_repo_relative_path(dir.path(), "../outside-secret.txt"),
            None
        );
        let _ = fs::remove_file(&outside);
    }

    #[test]
    fn resolve_repo_relative_path_accepts_a_real_file_inside_the_repo() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        let resolved = resolve_repo_relative_path(dir.path(), "src/lib.rs").unwrap();
        assert_eq!(fs::read_to_string(resolved).unwrap(), "fn f() {}\n");
    }

    #[test]
    fn live_rescan_hazards_does_not_escape_the_repo_via_traversal() {
        let dir = init_repo();
        write(dir.path(), "src/lib.rs", "fn f() {}\n");
        let outside = dir.path().parent().unwrap().join("outside.rs");
        fs::write(
            &outside,
            "fn g() { let p = &0 as *const i32; unsafe { *p }; }\n",
        )
        .unwrap();
        assert_eq!(
            live_rescan_hazards(dir.path(), "../outside.rs", 1, 10),
            None
        );
        let _ = fs::remove_file(&outside);
    }

    // --- unit_context's dirty-file wiring ----------------------------------

    // logical_units has no end_line column - upsert_logical_unit only ever
    // persists start_line (see storage.rs), so a unit's true multi-line
    // extent only exists once a real `events` row records one (the same
    // first-commit gap current_unit_spans_for_path.sql falls back around
    // elsewhere in this codebase). A bare upsert_logical_unit alone would
    // degrade every span to a single line, which is untestable for
    // dirty-file line-range filtering - so this seeds a real CHANGE event
    // too, mirroring what a second real commit would produce.
    fn seed_unit(storage: &Storage, path: &str, start_line: u32, end_line: u32) {
        let unit = LogicalUnit::new(
            "risky",
            UnitKind::Function,
            path,
            1,
            start_line,
            end_line,
            "pub fn risky",
            "pub fn risky() {}",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "abc123".to_string(),
                event_type: EventType::Change,
                path: path.to_string(),
                name: unit.name.clone(),
                start_line,
                end_line,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 1,
                timestamp: 20,
            })
            .unwrap();
    }

    #[test]
    fn unit_context_flags_dirty_and_live_rescans_for_a_supported_language() {
        let dir = init_repo();
        write(
            dir.path(),
            "src/lib.rs",
            "pub fn risky() -> i32 {\n    0\n}\n",
        );
        commit(dir.path(), "init");
        write(
            dir.path(),
            "src/lib.rs",
            "pub fn risky() -> i32 {\n    let p = &0 as *const i32;\n    unsafe { *p }\n}\n",
        );

        let storage = Storage::open_memory().unwrap();
        seed_unit(&storage, "src/lib.rs", 1, 4);

        let context = unit_context(Some(&storage), dir.path(), "src/lib.rs", 2).unwrap();
        assert_eq!(context["dirty"], "uncommitted-changes");
        let live = context["live_hazards"].as_array().unwrap();
        assert_eq!(live.len(), 1);
        assert_eq!(live[0]["hazard_type"], "rust_unsafe_block");
        assert!(context["note"].as_str().unwrap().contains("may be stale"));
    }

    #[test]
    fn unit_context_flags_dirty_without_live_hazards_for_an_unsupported_language() {
        let dir = init_repo();
        write(dir.path(), "src/worker.rb", "def run\n  1\nend\n");
        commit(dir.path(), "init");
        write(dir.path(), "src/worker.rb", "def run\n  2\nend\n");

        let storage = Storage::open_memory().unwrap();
        seed_unit(&storage, "src/worker.rb", 1, 3);

        let context = unit_context(Some(&storage), dir.path(), "src/worker.rb", 2).unwrap();
        assert_eq!(context["dirty"], "uncommitted-changes");
        assert!(context.get("live_hazards").is_none());
        assert!(context["note"]
            .as_str()
            .unwrap()
            .contains("No in-process live scanner"));
    }

    #[test]
    fn unit_context_has_no_dirty_field_for_a_clean_file() {
        let dir = init_repo();
        write(
            dir.path(),
            "src/lib.rs",
            "pub fn risky() -> i32 {\n    0\n}\n",
        );
        commit(dir.path(), "init");

        let storage = Storage::open_memory().unwrap();
        seed_unit(&storage, "src/lib.rs", 1, 3);

        let context = unit_context(Some(&storage), dir.path(), "src/lib.rs", 2).unwrap();
        assert!(context.get("dirty").is_none());
        assert!(context.get("live_hazards").is_none());
    }

    // --- LIKE wildcard escaping ---------------------------------------

    #[test]
    fn escape_like_pattern_neutralizes_percent_underscore_and_backslash() {
        assert_eq!(escape_like_pattern("plain/path.rs"), "plain/path.rs");
        assert_eq!(escape_like_pattern("100%_done.rs"), "100\\%\\_done.rs");
        assert_eq!(escape_like_pattern("back\\slash.rs"), "back\\\\slash.rs");
    }

    // Real bug: `format!("{path}%")` fed a caller-supplied path straight
    // into a LIKE pattern with no escaping. A path containing a literal
    // `%` or `_` had that character reinterpreted as a wildcard instead of
    // matched literally, so a directory-scope query could silently widen
    // to match unrelated paths that merely "look similar" under wildcard
    // rules - here, a query for the literal prefix "src%unusual" must
    // match only the unit whose real path starts with exactly that string,
    // not a same-length sibling whose middle three characters differ (which
    // an unescaped `%` would treat as "any characters").
    #[test]
    fn file_risk_prefix_scope_treats_percent_in_path_literally_not_as_a_wildcard() {
        let storage = Storage::open_memory().unwrap();
        seed_unit(&storage, "src%unusual/mod.rs", 1, 3);
        seed_unit(&storage, "srcXXXunusual/mod.rs", 1, 3);

        let result = file_risk(&storage, "src%unusual").unwrap();
        let files = result["files"].as_array().unwrap();
        let paths: Vec<&str> = files
            .iter()
            .filter_map(|f| f["current_path"].as_str())
            .collect();
        assert_eq!(paths, vec!["src%unusual/mod.rs"]);
    }
}
