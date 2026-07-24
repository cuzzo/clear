use crate::extract::{BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, HazardEvent, LogicalUnit};
use crate::storage::Storage;
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

const DELETE_SNAPSHOT_SQL: &str = include_str!("../../sql/architecture/delete_snapshot.sql");
const INSERT_ARTIFACT_SQL: &str = include_str!("../../sql/architecture/insert_artifact.sql");
const INSERT_NODE_SQL: &str = include_str!("../../sql/architecture/insert_node.sql");
const INSERT_EDGE_SQL: &str = include_str!("../../sql/architecture/insert_edge.sql");
const INSERT_EDGE_SPAN_SQL: &str = include_str!("../../sql/architecture/insert_edge_span.sql");
const INSERT_PRESSURE_SQL: &str = include_str!("../../sql/architecture/insert_pressure.sql");

/// One-shot: current (latest-event) location per unit, into an indexed temp
/// table, so per-node reconciliation is an indexed probe rather than a repeated
/// full latest-event join.
// Refresh contents in place (DELETE + INSERT), never DROP: a cached reconcile
// statement from a prior ingest on the same connection still references this
// table, and DROP would fail with "database table is locked".
const BUILD_RECONCILE_TEMP_SQL: &str = "\
CREATE TEMP TABLE IF NOT EXISTS arch_reconcile (
  unit_id TEXT, path TEXT, start_line INTEGER, name TEXT, type TEXT
);
CREATE INDEX IF NOT EXISTS arch_reconcile_idx ON arch_reconcile(path, type, name);
DELETE FROM arch_reconcile;
INSERT INTO arch_reconcile
SELECT u.id,
       COALESCE(le.path, u.original_path),
       COALESCE(le.start_line, u.start_line, 1),
       u.name,
       u.type
FROM logical_units u
LEFT JOIN (
  SELECT e.unit_id AS unit_id, e.path AS path, e.start_line AS start_line
  FROM events e
  WHERE e.id = (
    SELECT x.id FROM events x WHERE x.unit_id = e.unit_id
    ORDER BY x.timestamp DESC, x.id DESC LIMIT 1
  )
) le ON le.unit_id = u.id;";

/// Per-node reconcile against the materialized temp table (params identical to
/// the original `reconcile_logical_unit.sql`).
const RECONCILE_TEMP_SQL: &str = "\
SELECT unit_id FROM arch_reconcile
WHERE path = ?1 AND (name = ?2 OR name LIKE ?3) AND type IN (?4, ?5)
ORDER BY ABS(start_line - ?6), unit_id
LIMIT 1;";
const SEARCH_SQL: &str = include_str!("../../sql/architecture/search.sql");
const LATEST_ARTIFACT_SQL: &str = include_str!("../../sql/architecture/latest_artifact.sql");
const ARTIFACT_HEALTH_SQL: &str = include_str!("../../sql/architecture/artifact_health.sql");
const LOAD_NODE_SQL: &str = include_str!("../../sql/architecture/load_node.sql");
const OWNER_INVENTORY_SQL: &str = include_str!("../../sql/architecture/owner_inventory.sql");
const LOAD_EDGES_SQL: &str = include_str!("../../sql/architecture/load_edges.sql");

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ArchitectureIngestStats {
    pub artifacts: usize,
    pub nodes: usize,
    pub edges: usize,
    pub spans: usize,
    pub reconciled_units: usize,
}

pub fn ingest_architecture_json(
    storage: &Storage,
    payload: &str,
) -> Result<ArchitectureIngestStats> {
    let document: Value = serde_json::from_str(payload).context("parse architecture artifact")?;
    if document.get("kind").and_then(Value::as_str) != Some("espalier.architecture.v1") {
        bail!("unsupported architecture artifact kind");
    }
    let schema_version = document
        .get("schema_version")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if schema_version != 1 {
        bail!("unsupported architecture schema version {schema_version}");
    }
    let analyzer = document
        .pointer("/analyzer/name")
        .and_then(Value::as_str)
        .unwrap_or("espalier");
    let analyzer_version = document
        .pointer("/analyzer/version")
        .and_then(Value::as_str)
        .unwrap_or("");
    let commit = document
        .pointer("/corpus/commit")
        .and_then(Value::as_str)
        .unwrap_or("");
    let root = document
        .pointer("/corpus/root")
        .and_then(Value::as_str)
        .unwrap_or("");
    let complete = document
        .pointer("/corpus/complete")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let generated_at = document
        .get("generated_at")
        .and_then(Value::as_str)
        .unwrap_or("");

    // Nest safely inside the sync ingest's outer transaction; own one only when
    // called standalone (`ingest-architecture`).
    let owns_transaction = !storage.transaction_active();
    if owns_transaction {
        storage.begin_transaction()?;
    }
    let result = (|| -> Result<ArchitectureIngestStats> {
    let tx = storage.connection();
    tx.execute(DELETE_SNAPSHOT_SQL, params![analyzer, commit])?;
    tx.execute(
        INSERT_ARTIFACT_SQL,
        params![
            analyzer,
            analyzer_version,
            schema_version,
            commit,
            root,
            complete as i64,
            generated_at,
            // The full graph is decomposed into the nodes/edges/spans tables and
            // this column is never read back (the gzipped run-store artifact is
            // the durable copy), so storing it would only bloat the DB.
            ""
        ],
    )?;
    let artifact_id = tx.last_insert_rowid();
    let mut stats = ArchitectureIngestStats {
        artifacts: 1,
        ..ArchitectureIngestStats::default()
    };

    // Reconciling each architecture node to its logical unit needs each unit's
    // *current* path/start-line (from its latest event). Computing that latest-
    // event join per node re-scans the events table ~N times (60s for a real
    // graph). Materialize it once into an indexed temp table; the per-node
    // lookup is then a single indexed probe.
    tx.execute_batch(BUILD_RECONCILE_TEMP_SQL)?;

    for node in document
        .get("nodes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let id = text(node, "id");
        let kind = text(node, "kind");
        let name = text(node, "name");
        let path = optional_text(node, "path");
        let start_line = integer(node, "start_line").max(0);
        let logical_unit_id = if kind == "external" {
            None
        } else {
            reconcile_logical_unit(&tx, path.as_deref(), &name, &kind, start_line)?
        };
        if let Some(unit_id) = &logical_unit_id {
            stats.reconciled_units += 1;
            apply_node_big_o(&tx, node, unit_id)?;
        }
        let metadata = node.get("metadata").cloned().unwrap_or_else(|| json!({}));
        let confidence = metadata
            .get("confidence")
            .and_then(Value::as_str)
            .unwrap_or("high");
        tx.prepare_cached(INSERT_NODE_SQL)?.execute(
            params![
                artifact_id,
                id,
                logical_unit_id,
                optional_text(node, "owner_id"),
                kind,
                name,
                optional_text(node, "owner"),
                optional_text(node, "language"),
                path,
                start_line,
                integer(node, "start_column"),
                integer(node, "end_line"),
                integer(node, "end_column"),
                confidence,
                metadata.to_string()
            ],
        )?;
        stats.nodes += 1;
    }

    for edge in document
        .get("edges")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let edge_id = text(edge, "id");
        tx.prepare_cached(INSERT_EDGE_SQL)?.execute(
            params![
                artifact_id,
                edge_id,
                text(edge, "source"),
                text(edge, "target"),
                text(edge, "kind"),
                boolean(edge, "conditional") as i64,
                integer(edge, "weight").max(1),
                optional_text(edge, "confidence").unwrap_or_else(|| "high".into()),
                edge.get("metadata")
                    .cloned()
                    .unwrap_or_else(|| json!({}))
                    .to_string()
            ],
        )?;
        stats.edges += 1;
        for span in edge
            .get("spans")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            tx.prepare_cached(INSERT_EDGE_SPAN_SQL)?.execute(
                params![
                    artifact_id,
                    edge_id,
                    text(span, "path"),
                    integer(span, "start_line"),
                    integer(span, "start_column"),
                    integer(span, "end_line"),
                    integer(span, "end_column")
                ],
            )?;
            stats.spans += 1;
        }
    }

    for pressure in document
        .get("pressure")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let components = pressure
            .get("components")
            .cloned()
            .unwrap_or_else(|| json!({}));
        tx.prepare_cached(INSERT_PRESSURE_SQL)?.execute(
            params![
                artifact_id,
                text(pressure, "node_id"),
                number(pressure, "score"),
                text(pressure, "band"),
                number(&components, "collaboration"),
                number(&components, "state"),
                number(&components, "implementation"),
                number(&components, "operational"),
                pressure
                    .get("explanation")
                    .cloned()
                    .unwrap_or_else(|| json!({}))
                    .to_string()
            ],
        )?;
    }
    let mut file_cache: HashMap<String, (BlobFile, Vec<LogicalUnit>)> = HashMap::new();
    let extractor = HeuristicExtractor::default();
    let repo_path = Path::new(&root);
    let timestamp = storage
        .commit_timestamp(commit)
        .ok()
        .flatten()
        .unwrap_or_else(crate::hazard::now_timestamp);

    let mut deactivated_languages = std::collections::HashSet::new();
    let mut corpus_languages_set = std::collections::HashSet::new();

    if complete {
        if let Some(langs) = document
            .pointer("/corpus/languages")
            .and_then(Value::as_array)
        {
            for lang_val in langs {
                if let Some(lang_str) = lang_val.as_str() {
                    if !lang_str.is_empty() {
                        corpus_languages_set.insert(lang_str.to_string());
                    }
                }
            }
        }
    }

    if complete && !corpus_languages_set.is_empty() {
        for lang in &corpus_languages_set {
            if deactivated_languages.insert(lang.clone()) {
                storage.deactivate_active_hazards(lang)?;
            }
        }
    }

    for hazard in document
        .get("hazards")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let path = text(hazard, "path");
        let line = integer(hazard, "line") as u32;

        let hazard_type = text(hazard, "hazard_type");
        let source = text(hazard, "source");

        let provider = {
            let p = text(hazard, "provider");
            if p.is_empty() {
                let ext = Path::new(&path)
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("");
                match ext {
                    "rs" => "rust",
                    "go" => "go",
                    "zig" => "zig",
                    "rb" => "ruby",
                    "py" => "python",
                    "js" => "javascript",
                    "ts" => "typescript",
                    "lua" => "lua",
                    "java" => "java",
                    "php" => "php",
                    "kt" => "kotlin",
                    "swift" => "swift",
                    "c" => "c",
                    "cpp" => "cpp",
                    "cs" => "csharp",
                    _ => "",
                }
                .to_string()
            } else {
                p
            }
        };

        if complete
            && corpus_languages_set.is_empty()
            && !provider.is_empty()
            && deactivated_languages.insert(provider.clone())
        {
            storage.deactivate_active_hazards(&provider)?;
        }

        let required_evidence = {
            let req = text(hazard, "required_evidence");
            if req.is_empty() {
                "unknown".to_string()
            } else {
                req
            }
        };

        if !file_cache.contains_key(&path) {
            if let Ok(contents) = fs::read_to_string(repo_path.join(&path)) {
                let blob = BlobFile {
                    path: path.clone(),
                    contents,
                };
                let units = extractor.extract_units(&blob);
                file_cache.insert(path.clone(), (blob, units));
            }
        }

        let mut symbol = None;
        let mut resolved_id = path.clone();

        if let Some((blob, units)) = file_cache.get(&path) {
            let unit = crate::hazard::unit_for_site(blob, units, line);
            resolved_id = storage
                .resolve_unit_id(&unit.id, &unit.path, &unit.name)?
                .unwrap_or_else(|| unit.id.clone());
            symbol = Some(unit.name.clone());
            if resolved_id == unit.id {
                storage.upsert_logical_unit(&unit, timestamp)?;
            }
        }

        storage.insert_hazard_event(&HazardEvent {
            unit_id: resolved_id,
            language: provider.clone(),
            hazard_type,
            required_evidence,
            path: path.clone(),
            line,
            symbol,
            source: source.clone(),
            detected_at_hash: commit.to_string(),
            is_active: true,
            payload_json: json!({
                "provider": provider,
                "source": source,
                "timestamp": timestamp
            })
            .to_string(),
        })?;
    }

        Ok(stats)
    })();
    match result {
        Ok(stats) => {
            if owns_transaction {
                storage.commit_transaction()?;
            }
            Ok(stats)
        }
        Err(error) => {
            if owns_transaction {
                let _ = storage.rollback_transaction();
            }
            Err(error)
        }
    }
}

/// Store a function node's Big-O time/space complexity on its logical unit.
/// espalier emits `big_o_time`/`big_o_space` (the O(...) strings) plus
/// `time_complete`/`space_complete` bools. Status maps to: complete when the
/// bound is proven complete, partial when a bound is known but not complete,
/// unknown when absent. Nodes without any Big-O are left untouched.
fn apply_node_big_o(tx: &rusqlite::Connection, node: &Value, unit_id: &str) -> Result<()> {
    let time = optional_text(node, "big_o_time");
    let space = optional_text(node, "big_o_space");
    if time.is_none() && space.is_none() {
        return Ok(());
    }
    // The analyzer may return "unknown" as the bound itself (couldn't determine
    // one); treat that - and an absent bound - as unknown, a proven bound as
    // complete, and a known-but-unproven bound as partial.
    let status = |val: &Option<String>, complete_key: &str| -> &'static str {
        match val.as_deref() {
            None | Some("") | Some("unknown") | Some("Unknown") => "unknown",
            Some(_) if node.get(complete_key).and_then(Value::as_bool).unwrap_or(false) => {
                "complete"
            }
            Some(_) => "partial",
        }
    };
    tx.execute(
        "UPDATE logical_units SET big_o_time = ?2, big_o_time_status = ?3, \
         big_o_space = ?4, big_o_space_status = ?5 WHERE id = ?1",
        params![
            unit_id,
            time.clone().unwrap_or_default(),
            status(&time, "time_complete"),
            space.clone().unwrap_or_default(),
            status(&space, "space_complete"),
        ],
    )?;
    Ok(())
}

fn reconcile_logical_unit(
    tx: &rusqlite::Connection,
    path: Option<&str>,
    name: &str,
    kind: &str,
    start_line: i64,
) -> Result<Option<String>> {
    let Some(path) = path else { return Ok(None) };
    let unit_kind = if kind == "owner" {
        vec!["class", "module"]
    } else {
        vec![kind]
    };
    // Cached probe against the materialized temp table (built once per ingest).
    let mut stmt = tx.prepare_cached(RECONCILE_TEMP_SQL)?;
    let suffix = format!("%{name}");
    Ok(stmt
        .query_row(
            params![
                path,
                name,
                suffix,
                unit_kind[0],
                unit_kind.get(1).copied().unwrap_or(&unit_kind[0]),
                start_line
            ],
            |row| row.get(0),
        )
        .optional()?)
}

pub fn owner_inventory(storage: &Storage, owner_id: &str) -> Result<Value> {
    let artifact_id = latest_artifact_id(storage)?;
    let owner =
        load_node(storage, artifact_id, owner_id)?.context("architecture owner not found")?;
    let members = load_nodes_for_owner(storage, artifact_id, owner_id)?;
    Ok(json!({
        "artifact": artifact_health(storage, artifact_id)?,
        "owner": owner,
        "members": members
    }))
}

pub fn node_neighborhood(storage: &Storage, node_id: &str, limit: usize) -> Result<Value> {
    let artifact_id = latest_artifact_id(storage)?;
    let selected =
        load_node(storage, artifact_id, node_id)?.context("architecture node not found")?;
    let edges = load_edges(storage, artifact_id, node_id)?;
    let mut ids = edges
        .iter()
        .flat_map(|edge| {
            [
                edge.get("source").and_then(Value::as_str),
                edge.get("target").and_then(Value::as_str),
            ]
        })
        .flatten()
        .map(str::to_string)
        .collect::<Vec<_>>();
    ids.sort();
    ids.dedup();
    ids.retain(|id| id != node_id);
    let visible_ids = ids
        .iter()
        .take(limit.saturating_sub(1))
        .cloned()
        .collect::<Vec<_>>();
    let mut nodes = vec![selected.clone()];
    for id in &visible_ids {
        if let Some(node) = load_node(storage, artifact_id, id)? {
            nodes.push(node);
        }
    }
    let visible = visible_ids
        .iter()
        .chain(std::iter::once(&node_id.to_string()))
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    let mut visible_edges = edges
        .iter()
        .filter(|edge| {
            visible.contains(edge["source"].as_str().unwrap_or_default())
                && visible.contains(edge["target"].as_str().unwrap_or_default())
        })
        .cloned()
        .collect::<Vec<_>>();
    let omitted_edges = edges
        .iter()
        .filter(|edge| {
            !visible.contains(edge["source"].as_str().unwrap_or_default())
                || !visible.contains(edge["target"].as_str().unwrap_or_default())
        })
        .cloned()
        .collect::<Vec<_>>();
    if !omitted_edges.is_empty() {
        let aggregate_id = format!("aggregate:{node_id}");
        nodes.push(json!({"id": aggregate_id, "kind": "aggregate", "name": format!("+{} relationships", omitted_edges.len()),
            "confidence": "partial", "metadata": {"omitted": omitted_edges.len()}}));
        visible_edges.push(json!({"id": format!("edge:{aggregate_id}"), "source": node_id, "target": aggregate_id,
            "kind": "aggregate", "conditional": false, "weight": omitted_edges.len(), "confidence": "partial", "spans": []}));
    }
    Ok(json!({
        "artifact": artifact_health(storage, artifact_id)?,
        "selected": selected,
        "nodes": nodes,
        "edges": visible_edges,
        "total_relationships": edges.len(),
        "omitted_relationships": omitted_edges
    }))
}

pub fn state_access(storage: &Storage, state_id: &str) -> Result<Value> {
    node_neighborhood(storage, state_id, 100)
}

pub fn architecture_search(
    storage: &Storage,
    owner_id: Option<&str>,
    query: &str,
) -> Result<Value> {
    let artifact_id = latest_artifact_id(storage)?;
    let pattern = format!("%{}%", query.to_ascii_lowercase());
    let mut stmt = storage.connection().prepare(SEARCH_SQL)?;
    let rows = stmt.query_map(params![artifact_id, pattern, owner_id], |row| {
        Ok(json!({"id": row.get::<_, String>(0)?, "kind": row.get::<_, String>(1)?, "name": row.get::<_, String>(2)?,
            "owner": row.get::<_, Option<String>>(3)?, "path": row.get::<_, Option<String>>(4)?, "start_line": row.get::<_, i64>(5)?,
            "metadata": parse_json(row.get::<_, String>(6)?)}))
    })?;
    Ok(json!({"results": rows.collect::<std::result::Result<Vec<_>, _>>()?}))
}

fn latest_artifact_id(storage: &Storage) -> Result<i64> {
    storage
        .connection()
        .query_row(LATEST_ARTIFACT_SQL, [], |row| row.get(0))
        .context("no architecture artifact has been ingested")
}

/// What an architecture fact site represents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactKind {
    /// A resolved call/collaboration (`Owner#name`), attributed to a unit.
    Call,
    /// A state read/write (`read:field` / `write:field`), attributed to a unit.
    State,
    /// A source import/require (the module string), attributed to a file.
    Import,
}

/// A single call, state-access, or import site from the architecture graph,
/// tagged with the source location where it occurs. The diff service intersects
/// these with a diff's added lines to surface *new* facts per unit or file.
#[derive(Debug, Clone)]
pub struct ArchitectureFactSite {
    pub path: String,
    pub line: u32,
    /// `Owner#name` for a call, `read:field`/`write:field` for state, or the
    /// module string for an import.
    pub label: String,
    pub kind: FactKind,
}

/// Every call and state-access site from the architecture graph ingested for
/// `commit_hash`. Returns an empty vec when no graph was ingested for it.
pub fn architecture_fact_sites_for_commit(
    storage: &Storage,
    commit_hash: &str,
) -> Result<Vec<ArchitectureFactSite>> {
    let Some(artifact_id) = artifact_id_for_commit(storage, commit_hash)? else {
        return Ok(Vec::new());
    };
    // node id -> (name, owner)
    let mut nodes = HashMap::<String, (String, Option<String>)>::new();
    {
        let mut stmt = storage.connection().prepare(
            "SELECT analyzer_node_id, name, owner FROM architecture_nodes WHERE artifact_id = ?1",
        )?;
        let rows = stmt.query_map(params![artifact_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                (row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?),
            ))
        })?;
        for row in rows {
            let (id, value) = row?;
            nodes.insert(id, value);
        }
    }
    let mut sites = Vec::new();
    let mut stmt = storage.connection().prepare(
        "SELECT e.source_node_id, e.target_node_id, e.kind, s.path, s.start_line \
         FROM architecture_edges e \
         JOIN architecture_edge_spans s \
           ON s.artifact_id = e.artifact_id AND s.edge_id = e.edge_id \
         WHERE e.artifact_id = ?1",
    )?;
    let rows = stmt.query_map(params![artifact_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })?;
    for row in rows {
        let (source, target, kind, path, line) = row?;
        let line = line.max(0) as u32;
        match kind.as_str() {
            // `writes` is fn -> state; the state field is the edge target.
            "writes" => {
                if let Some((name, _)) = nodes.get(&target) {
                    sites.push(ArchitectureFactSite {
                        path,
                        line,
                        label: format!("write:{name}"),
                        kind: FactKind::State,
                    });
                }
            }
            // `reads` is deliberately reversed: state -> fn, so the field is the source.
            "reads" => {
                if let Some((name, _)) = nodes.get(&source) {
                    sites.push(ArchitectureFactSite {
                        path,
                        line,
                        label: format!("read:{name}"),
                        kind: FactKind::State,
                    });
                }
            }
            // An import/require: the module string is the target external node's name.
            "imports" => {
                if let Some((name, _)) = nodes.get(&target) {
                    sites.push(ArchitectureFactSite {
                        path,
                        line,
                        label: name.clone(),
                        kind: FactKind::Import,
                    });
                }
            }
            // Only calls that resolve to a real unit in the corpus become
            // dependencies. `external_call` (stdlib/builtins) and
            // `unresolved_call` (method on an untyped local) are dropped: they
            // are bare, unqualified names (`append`, `len`, `filepath`, a local
            // variable) rather than a `Owner#name` collaboration.
            "calls" | "internal_call" | "resolved_call" | "delegation" => {
                if let Some((name, owner)) = nodes.get(&target) {
                    let label = match owner {
                        Some(owner) if !owner.is_empty() => format!("{owner}#{name}"),
                        _ => name.clone(),
                    };
                    sites.push(ArchitectureFactSite {
                        path,
                        line,
                        label,
                        kind: FactKind::Call,
                    });
                }
            }
            _ => {}
        }
    }
    Ok(sites)
}

fn artifact_id_for_commit(storage: &Storage, commit_hash: &str) -> Result<Option<i64>> {
    storage
        .connection()
        .query_row(
            "SELECT id FROM architecture_artifacts WHERE commit_hash = ?1 ORDER BY id DESC LIMIT 1",
            params![commit_hash],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
}

fn artifact_health(storage: &Storage, artifact_id: i64) -> Result<Value> {
    storage.connection().query_row(
        ARTIFACT_HEALTH_SQL,
        params![artifact_id],
        |row| Ok(json!({"id": artifact_id, "analyzer": row.get::<_, String>(0)?, "analyzer_version": row.get::<_, String>(1)?,
            "schema_version": row.get::<_, i64>(2)?, "commit": row.get::<_, String>(3)?, "complete": row.get::<_, i64>(4)? != 0,
            "generated_at": row.get::<_, String>(5)?})),
    ).map_err(Into::into)
}

fn load_node(storage: &Storage, artifact_id: i64, id: &str) -> Result<Option<Value>> {
    storage
        .connection()
        .query_row(LOAD_NODE_SQL, params![artifact_id, id], node_from_row)
        .optional()
        .map_err(Into::into)
}

fn load_nodes_for_owner(storage: &Storage, artifact_id: i64, owner_id: &str) -> Result<Vec<Value>> {
    let mut stmt = storage.connection().prepare(OWNER_INVENTORY_SQL)?;
    let rows = stmt.query_map(params![artifact_id, owner_id], |row| {
        let mut value = node_from_row(row)?;
        value["pressure"] = json!({"score": row.get::<_, Option<f64>>(14)?.unwrap_or(0.0), "band": row.get::<_, Option<String>>(15)?.unwrap_or_else(|| "ordinary".into()), "explanation": parse_json(row.get::<_, Option<String>>(16)?.unwrap_or_else(|| "{}".into()))});
        value["incoming"] = json!(row.get::<_, i64>(17)?);
        value["outgoing"] = json!(row.get::<_, i64>(18)?);
        value["gigasail"] = json!({"hazards": row.get::<_, i64>(19)?, "changes": row.get::<_, i64>(20)?,
            "fixes": row.get::<_, i64>(21)?, "distinct_tests": row.get::<_, i64>(22)?,
            "line_coverage": row.get::<_, f64>(23)?, "mutant_coverage": row.get::<_, f64>(24)?});
        Ok(value)
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

fn node_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(
        json!({"id": row.get::<_, String>(0)?, "logical_unit_id": row.get::<_, Option<String>>(1)?, "owner_id": row.get::<_, Option<String>>(2)?,
        "kind": row.get::<_, String>(3)?, "name": row.get::<_, String>(4)?, "owner": row.get::<_, Option<String>>(5)?,
        "language": row.get::<_, Option<String>>(6)?, "path": row.get::<_, Option<String>>(7)?, "start_line": row.get::<_, i64>(8)?,
        "start_column": row.get::<_, i64>(9)?, "end_line": row.get::<_, i64>(10)?, "end_column": row.get::<_, i64>(11)?,
        "confidence": row.get::<_, String>(12)?, "metadata": parse_json(row.get::<_, String>(13)?)}),
    )
}

fn load_edges(storage: &Storage, artifact_id: i64, node_id: &str) -> Result<Vec<Value>> {
    let mut stmt = storage.connection().prepare(LOAD_EDGES_SQL)?;
    let rows = stmt.query_map(params![artifact_id, node_id], |row| Ok(json!({"id": row.get::<_, String>(0)?, "source": row.get::<_, String>(1)?,
        "target": row.get::<_, String>(2)?, "kind": row.get::<_, String>(3)?, "conditional": row.get::<_, i64>(4)? != 0,
        "weight": row.get::<_, i64>(5)?, "confidence": row.get::<_, String>(6)?, "metadata": parse_json(row.get::<_, String>(7)?),
        "spans": parse_json(row.get::<_, String>(8)?)})))?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}
fn optional_text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}
fn integer(value: &Value, key: &str) -> i64 {
    value.get(key).and_then(Value::as_i64).unwrap_or(0)
}
fn number(value: &Value, key: &str) -> f64 {
    value.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}
fn boolean(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}
fn parse_json(text: String) -> Value {
    serde_json::from_str(&text).unwrap_or_else(|_| json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standalone_architecture_sql_prepares_against_the_real_schema() {
        let storage = Storage::open_memory().unwrap();
        for sql in [
            DELETE_SNAPSHOT_SQL,
            INSERT_ARTIFACT_SQL,
            INSERT_NODE_SQL,
            INSERT_EDGE_SQL,
            INSERT_EDGE_SPAN_SQL,
            INSERT_PRESSURE_SQL,
            SEARCH_SQL,
            LATEST_ARTIFACT_SQL,
            ARTIFACT_HEALTH_SQL,
            LOAD_NODE_SQL,
            OWNER_INVENTORY_SQL,
            LOAD_EDGES_SQL,
        ] {
            storage
                .connection()
                .prepare(sql)
                .unwrap_or_else(|error| panic!("standalone SQL failed to prepare: {error}\n{sql}"));
        }
    }

    #[test]
    fn arch_ingest_stores_node_big_o_on_the_reconciled_unit() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            crate::model::UnitKind::Function,
            "demo.rb",
            0,
            2,
            5,
            "def run",
            "def run\n@v=1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        let payload = json!({
            "schema_version": 1, "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "t"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "abc", "root": ".", "complete": true, "languages": ["ruby"]},
            "nodes": [{
                "id": "fn:1", "kind": "function", "name": "run", "path": "demo.rb",
                "start_line": 2, "end_line": 5,
                "big_o_time": "O(n log n)", "time_complete": true,
                "big_o_space": "O(n)", "space_complete": false,
                "metadata": {"confidence": "high"}
            }],
            "edges": [], "pressure": [], "hazards": []
        })
        .to_string();
        ingest_architecture_json(&storage, &payload).unwrap();
        // time is proven complete, space is a known-but-partial bound.
        assert_eq!(
            storage.logical_unit_big_o(&unit.id).unwrap(),
            (
                "O(n log n)".to_string(),
                "complete".to_string(),
                "O(n)".to_string(),
                "partial".to_string()
            )
        );
        // A unit whose node carries no Big-O stays unknown.
        let plain = LogicalUnit::new(
            "plain",
            crate::model::UnitKind::Function,
            "demo.rb",
            1,
            10,
            12,
            "def plain",
            "def plain\n1\nend",
        );
        storage.upsert_logical_unit(&plain, 10).unwrap();
        assert_eq!(storage.logical_unit_big_o(&plain.id).unwrap().1, "unknown");

        // An "unknown" bound string (analyzer couldn't determine one) is unknown,
        // not "partial".
        let loopy = LogicalUnit::new(
            "loopy",
            crate::model::UnitKind::Function,
            "demo.rb",
            2,
            20,
            25,
            "def loopy",
            "def loopy\nx\nend",
        );
        storage.upsert_logical_unit(&loopy, 10).unwrap();
        let payload2 = json!({
            "schema_version": 1, "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "t"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "abc", "root": ".", "complete": true, "languages": ["ruby"]},
            "nodes": [{
                "id": "fn:2", "kind": "function", "name": "loopy", "path": "demo.rb",
                "start_line": 20, "end_line": 25,
                "big_o_time": "unknown", "time_complete": false,
                "metadata": {"confidence": "high"}
            }],
            "edges": [], "pressure": [], "hazards": []
        })
        .to_string();
        ingest_architecture_json(&storage, &payload2).unwrap();
        assert_eq!(storage.logical_unit_big_o(&loopy.id).unwrap().1, "unknown");
    }

    #[test]
    fn fact_sites_classify_calls_and_state_by_span() {
        let storage = Storage::open_memory().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let payload = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "deadbeef", "root": dir.path().to_str().unwrap(), "complete": true, "languages": ["ruby"]},
            "nodes": [
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"start_column":0,"end_line":9,"end_column":3,"metadata":{}},
                {"id":"fn:run","kind":"function","name":"run","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":2,"start_column":0,"end_line":6,"end_column":3,"metadata":{}},
                {"id":"fn:help","kind":"function","name":"help","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":7,"start_column":0,"end_line":8,"end_column":3,"metadata":{}},
                {"id":"state:v","kind":"state","name":"@value","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8,"metadata":{}},
                {"id":"external:import:s","kind":"external","name":"strings","owner":null,"language":"ruby","path":null,"start_line":0,"start_column":0,"end_line":0,"end_column":0,"metadata":{"import":true}}
            ],
            "edges": [
                {"id":"e:import","source":"file:demo.rb","target":"external:import:s","kind":"imports","conditional":false,"weight":1,"confidence":"high","metadata":{"module":"strings"},"spans":[{"path":"demo.rb","start_line":1,"start_column":0,"end_line":1,"end_column":0}]},
                {"id":"e:call","source":"fn:run","target":"fn:help","kind":"calls","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":4,"start_column":4,"end_line":4,"end_column":10}]},
                {"id":"e:write","source":"fn:run","target":"state:v","kind":"writes","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8}]},
                {"id":"e:read","source":"state:v","target":"fn:help","kind":"reads","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":7,"start_column":2,"end_line":7,"end_column":8}]},
                {"id":"e:ext","source":"fn:run","target":"external:puts","kind":"external_call","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":5,"start_column":4,"end_line":5,"end_column":8}]}
            ],
            "pressure": [],
            "hazards": []
        }).to_string();
        ingest_architecture_json(&storage, &payload).unwrap();

        let sites = architecture_fact_sites_for_commit(&storage, "deadbeef").unwrap();
        // The call resolves to `Owner#name`; the external call is dropped.
        let call = sites
            .iter()
            .find(|s| s.kind == FactKind::Call && s.line == 4)
            .unwrap();
        assert_eq!(call.label, "Demo#help");
        assert!(sites.iter().all(|s| s.label != "puts"), "external calls dropped");
        // Write names the state target; read names the state source (reversed).
        let write = sites
            .iter()
            .find(|s| s.kind == FactKind::State && s.line == 3)
            .unwrap();
        assert_eq!(write.label, "write:@value");
        let read = sites
            .iter()
            .find(|s| s.kind == FactKind::State && s.line == 7)
            .unwrap();
        assert_eq!(read.label, "read:@value");
        // The import target names the module and is tagged as an import.
        let import = sites
            .iter()
            .find(|s| s.kind == FactKind::Import)
            .unwrap();
        assert_eq!(import.label, "strings");
        assert_eq!(import.line, 1);

        // An unknown commit yields nothing rather than erroring.
        assert!(architecture_fact_sites_for_commit(&storage, "cafe").unwrap().is_empty());
    }

    #[test]
    fn ingests_and_queries_focused_architecture() {
        let storage = Storage::open_memory().unwrap();

        let dir = tempfile::tempdir().unwrap();
        let demo_path = dir.path().join("demo.rb");
        fs::write(
            &demo_path,
            "class Demo\n  def run\n    @value = 1\n  end\nend\n",
        )
        .unwrap();

        let payload = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "abc", "root": dir.path().to_str().unwrap(), "complete": true, "languages": ["ruby"]},
            "nodes": [
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"start_column":0,"end_line":8,"end_column":3,"metadata":{"confidence":"high"}},
                {"id":"fn:1","kind":"function","name":"run","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":2,"start_column":0,"end_line":5,"end_column":3,"metadata":{"confidence":"high"}},
                {"id":"state:1","kind":"state","name":"@value","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8,"metadata":{"confidence":"high"}}
            ],
            "edges": [{"id":"edge:1","source":"fn:1","target":"state:1","kind":"writes","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8}]}],
            "pressure": [{"node_id":"fn:1","score":60.0,"band":"orange","components":{"collaboration":0.2,"state":0.8,"implementation":0.0,"operational":0.0},"explanation":{"state_writes":1}}],
            "hazards": [
                {
                    "path": "demo.rb",
                    "line": 3,
                    "hazard_type": "ruby_metaprogramming",
                    "required_evidence": "nil-kill",
                    "source": "send(:run)"
                }
            ]
        }).to_string();
        let stats = ingest_architecture_json(&storage, &payload).unwrap();
        assert_eq!(stats.nodes, 3);
        assert_eq!(stats.edges, 1);
        let inventory = owner_inventory(&storage, "owner:1").unwrap();
        assert_eq!(inventory["members"].as_array().unwrap().len(), 2);
        assert_eq!(inventory["members"][0]["pressure"]["band"], "orange");
        let access = state_access(&storage, "state:1").unwrap();
        assert_eq!(access["total_relationships"], 1);

        // Verify the hazard was ingested
        assert_eq!(storage.count_rows("unit_hazards").unwrap(), 1);

        // Verify correct provider and required_evidence are stored
        let mut stmt = storage
            .connection()
            .prepare("SELECT language, required_evidence, is_active FROM unit_hazards")
            .unwrap();
        let mut rows = stmt.query(params![]).unwrap();
        let row = rows.next().unwrap().unwrap();
        let language: String = row.get(0).unwrap();
        let req_ev: String = row.get(1).unwrap();
        let is_active: i32 = row.get(2).unwrap();
        assert_eq!(language, "ruby");
        assert_eq!(req_ev, "nil-kill");
        assert_eq!(is_active, 1);

        // 1. Verify reimport with zero hazards in a complete scan deactivates old hazards
        let payload_empty_hazards = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "def", "root": dir.path().to_str().unwrap(), "complete": true, "languages": ["ruby"]},
            "nodes": [
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"language":"ruby"},
            ],
            "edges": [],
            "pressure": [],
            "hazards": []
        }).to_string();

        ingest_architecture_json(&storage, &payload_empty_hazards).unwrap();
        // Since it was complete scan and contained language: ruby in nodes, old ruby hazard is deactivated!
        let is_active_after_empty: i32 = storage
            .connection()
            .query_row(
                "SELECT is_active FROM unit_hazards WHERE language = 'ruby'",
                params![],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(is_active_after_empty, 0);

        // 2. Verify replacement rather than duplication (we insert a new hazard, it is active, old remains inactive)
        let payload_new_hazard = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "ghi", "root": dir.path().to_str().unwrap(), "complete": true, "languages": ["ruby"]},
            "nodes": [
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"language":"ruby"},
            ],
            "edges": [],
            "pressure": [],
            "hazards": [
                {
                    "path": "demo.rb",
                    "line": 4,
                    "hazard_type": "ruby_metaprogramming",
                    "source": "eval('x = 2')",
                    "provider": "ruby",
                    "required_evidence": "nil-kill"
                }
            ]
        }).to_string();

        ingest_architecture_json(&storage, &payload_new_hazard).unwrap();
        let active_count: i32 = storage
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM unit_hazards WHERE language = 'ruby' AND is_active = 1",
                params![],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(active_count, 1); // Only the new one is active!

        let total_count: i32 = storage
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM unit_hazards WHERE language = 'ruby'",
                params![],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(total_count, 2); // 2 rows exist total (old deactivated one and new active one)

        // 3. Verify rollback on insertion failure
        let payload_broken = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "broken", "root": dir.path().to_str().unwrap(), "complete": true, "languages": ["ruby"]},
            "nodes": [
                // Duplicate IDs to trigger constraint violation
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"language":"ruby"},
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"language":"ruby"}
            ],
            "edges": [],
            "pressure": [],
            "hazards": []
        }).to_string();

        assert!(ingest_architecture_json(&storage, &payload_broken).is_err());
        // Verify no changes committed - active count is still 1!
        let active_count_after_fail: i32 = storage
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM unit_hazards WHERE language = 'ruby' AND is_active = 1",
                params![],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(active_count_after_fail, 1);
    }
}
