use crate::storage::Storage;
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};

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

    let tx = storage.connection().unchecked_transaction()?;
    tx.execute(
        "DELETE FROM architecture_artifacts WHERE analyzer = ?1 AND commit_hash = ?2",
        params![analyzer, commit],
    )?;
    tx.execute(
        r#"INSERT INTO architecture_artifacts
           (analyzer, analyzer_version, schema_version, commit_hash, root, complete, generated_at, payload_json)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)"#,
        params![analyzer, analyzer_version, schema_version, commit, root, complete as i64, generated_at, payload],
    )?;
    let artifact_id = tx.last_insert_rowid();
    let mut stats = ArchitectureIngestStats {
        artifacts: 1,
        ..ArchitectureIngestStats::default()
    };

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
        if logical_unit_id.is_some() {
            stats.reconciled_units += 1;
        }
        let metadata = node.get("metadata").cloned().unwrap_or_else(|| json!({}));
        let confidence = metadata
            .get("confidence")
            .and_then(Value::as_str)
            .unwrap_or("high");
        tx.execute(
            r#"INSERT INTO architecture_nodes
               (artifact_id, analyzer_node_id, logical_unit_id, owner_node_id, kind, name, owner,
                language, path, start_line, start_column, end_line, end_column, confidence, metadata_json)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)"#,
            params![
                artifact_id, id, logical_unit_id, optional_text(node, "owner_id"), kind, name,
                optional_text(node, "owner"), optional_text(node, "language"), path, start_line,
                integer(node, "start_column"), integer(node, "end_line"), integer(node, "end_column"),
                confidence, metadata.to_string()
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
        tx.execute(
            r#"INSERT INTO architecture_edges
               (artifact_id, edge_id, source_node_id, target_node_id, kind, conditional, weight, confidence, metadata_json)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"#,
            params![
                artifact_id, edge_id, text(edge, "source"), text(edge, "target"), text(edge, "kind"),
                boolean(edge, "conditional") as i64, integer(edge, "weight").max(1),
                optional_text(edge, "confidence").unwrap_or_else(|| "high".into()),
                edge.get("metadata").cloned().unwrap_or_else(|| json!({})).to_string()
            ],
        )?;
        stats.edges += 1;
        for span in edge
            .get("spans")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            tx.execute(
                r#"INSERT INTO architecture_edge_spans
                   (artifact_id, edge_id, path, start_line, start_column, end_line, end_column)
                   VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"#,
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
        tx.execute(
            r#"INSERT INTO architecture_pressure
               (artifact_id, node_id, score, band, collaboration, state, implementation, operational, explanation_json)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"#,
            params![artifact_id, text(pressure, "node_id"), number(pressure, "score"), text(pressure, "band"),
                number(&components, "collaboration"), number(&components, "state"),
                number(&components, "implementation"), number(&components, "operational"),
                pressure.get("explanation").cloned().unwrap_or_else(|| json!({})).to_string()],
        )?;
    }
    tx.commit()?;
    Ok(stats)
}

fn reconcile_logical_unit(
    tx: &rusqlite::Transaction<'_>,
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
    let mut stmt = tx.prepare(
        r#"WITH latest_events AS (
             SELECT e.* FROM events e
             WHERE e.id = (SELECT x.id FROM events x WHERE x.unit_id=e.unit_id ORDER BY x.timestamp DESC, x.id DESC LIMIT 1)
           )
           SELECT u.id
           FROM logical_units u LEFT JOIN latest_events e ON e.unit_id=u.id
           WHERE COALESCE(e.path, u.original_path)=?1
             AND (u.name=?2 OR u.name LIKE ?3)
             AND u.type IN (?4, ?5)
           ORDER BY ABS(COALESCE(e.start_line, u.start_line, 1)-?6), u.id
           LIMIT 1"#,
    )?;
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
    let mut stmt = storage.connection().prepare(
        r#"SELECT analyzer_node_id, kind, name, owner, path, start_line, metadata_json
           FROM architecture_nodes
           WHERE artifact_id=?1 AND lower(name) LIKE ?2 AND (?3 IS NULL OR owner_node_id=?3)
           ORDER BY CASE kind WHEN 'owner' THEN 0 WHEN 'function' THEN 1 ELSE 2 END, name LIMIT 100"#,
    )?;
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
        .query_row(
            "SELECT id FROM architecture_artifacts ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .context("no architecture artifact has been ingested")
}

fn artifact_health(storage: &Storage, artifact_id: i64) -> Result<Value> {
    storage.connection().query_row(
        "SELECT analyzer, analyzer_version, schema_version, commit_hash, complete, generated_at FROM architecture_artifacts WHERE id=?1",
        params![artifact_id],
        |row| Ok(json!({"id": artifact_id, "analyzer": row.get::<_, String>(0)?, "analyzer_version": row.get::<_, String>(1)?,
            "schema_version": row.get::<_, i64>(2)?, "commit": row.get::<_, String>(3)?, "complete": row.get::<_, i64>(4)? != 0,
            "generated_at": row.get::<_, String>(5)?})),
    ).map_err(Into::into)
}

fn load_node(storage: &Storage, artifact_id: i64, id: &str) -> Result<Option<Value>> {
    storage.connection().query_row(
        r#"SELECT analyzer_node_id, logical_unit_id, owner_node_id, kind, name, owner, language, path,
                  start_line, start_column, end_line, end_column, confidence, metadata_json
           FROM architecture_nodes WHERE artifact_id=?1 AND analyzer_node_id=?2"#,
        params![artifact_id, id], node_from_row,
    ).optional().map_err(Into::into)
}

fn load_nodes_for_owner(storage: &Storage, artifact_id: i64, owner_id: &str) -> Result<Vec<Value>> {
    let mut stmt = storage.connection().prepare(
        r#"SELECT n.analyzer_node_id, n.logical_unit_id, n.owner_node_id, n.kind, n.name, n.owner, n.language, n.path,
                  n.start_line, n.start_column, n.end_line, n.end_column, n.confidence, n.metadata_json,
                  p.score, p.band, p.explanation_json,
                  (SELECT COUNT(*) FROM architecture_edges e WHERE e.artifact_id=n.artifact_id AND e.target_node_id=n.analyzer_node_id) AS incoming,
                  (SELECT COUNT(*) FROM architecture_edges e WHERE e.artifact_id=n.artifact_id AND e.source_node_id=n.analyzer_node_id) AS outgoing,
                  (SELECT COUNT(*) FROM unit_hazards h WHERE h.unit_id=n.logical_unit_id AND h.is_active=1) AS hazards,
                  (SELECT COUNT(*) FROM events e WHERE e.unit_id=n.logical_unit_id AND e.event_type='CHANGE') AS changes,
                  (SELECT COUNT(*) FROM events e WHERE e.unit_id=n.logical_unit_id AND e.event_type='FIX') AS fixes,
                  COALESCE(u.current_distinct_tests, 0), COALESCE(u.current_line_cov, 0), COALESCE(u.current_mutant_cov, 0)
           FROM architecture_nodes n LEFT JOIN architecture_pressure p ON p.artifact_id=n.artifact_id AND p.node_id=n.analyzer_node_id
           LEFT JOIN logical_units u ON u.id=n.logical_unit_id
           WHERE n.artifact_id=?1 AND n.owner_node_id=?2
           ORDER BY COALESCE(p.score, 0) DESC, n.kind, n.name"#,
    )?;
    let rows = stmt.query_map(params![artifact_id, owner_id], |row| {
        let mut value = node_from_row(row)?;
        value["pressure"] = json!({"score": row.get::<_, Option<f64>>(14)?.unwrap_or(0.0), "band": row.get::<_, Option<String>>(15)?.unwrap_or_else(|| "ordinary".into()), "explanation": parse_json(row.get::<_, Option<String>>(16)?.unwrap_or_else(|| "{}".into()))});
        value["incoming"] = json!(row.get::<_, i64>(17)?);
        value["outgoing"] = json!(row.get::<_, i64>(18)?);
        value["lineage"] = json!({"hazards": row.get::<_, i64>(19)?, "changes": row.get::<_, i64>(20)?,
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
    let mut stmt = storage.connection().prepare(
        r#"SELECT e.edge_id, e.source_node_id, e.target_node_id, e.kind, e.conditional, e.weight, e.confidence, e.metadata_json,
                  COALESCE((SELECT json_group_array(json_object('path',s.path,'start_line',s.start_line,'start_column',s.start_column,'end_line',s.end_line,'end_column',s.end_column)) FROM architecture_edge_spans s WHERE s.artifact_id=e.artifact_id AND s.edge_id=e.edge_id), '[]')
           FROM architecture_edges e WHERE e.artifact_id=?1 AND (e.source_node_id=?2 OR e.target_node_id=?2)
           ORDER BY e.kind, e.source_node_id, e.target_node_id"#,
    )?;
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
    fn ingests_and_queries_focused_architecture() {
        let storage = Storage::open_memory().unwrap();
        let payload = json!({
            "schema_version": 1,
            "kind": "espalier.architecture.v1",
            "analyzer": {"name": "espalier", "version": "test"},
            "generated_at": "2026-07-11T00:00:00Z",
            "corpus": {"commit": "abc", "root": ".", "complete": true},
            "nodes": [
                {"id":"owner:1","kind":"owner","name":"Demo","owner":"Demo","path":"demo.rb","start_line":1,"start_column":0,"end_line":8,"end_column":3,"metadata":{"confidence":"high"}},
                {"id":"fn:1","kind":"function","name":"run","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":2,"start_column":0,"end_line":5,"end_column":3,"metadata":{"confidence":"high"}},
                {"id":"state:1","kind":"state","name":"@value","owner":"Demo","owner_id":"owner:1","path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8,"metadata":{"confidence":"high"}}
            ],
            "edges": [{"id":"edge:1","source":"fn:1","target":"state:1","kind":"writes","conditional":false,"weight":1,"confidence":"high","metadata":{},"spans":[{"path":"demo.rb","start_line":3,"start_column":2,"end_line":3,"end_column":8}]}],
            "pressure": [{"node_id":"fn:1","score":60.0,"band":"orange","components":{"collaboration":0.2,"state":0.8,"implementation":0.0,"operational":0.0},"explanation":{"state_writes":1}}]
        }).to_string();
        let stats = ingest_architecture_json(&storage, &payload).unwrap();
        assert_eq!(stats.nodes, 3);
        assert_eq!(stats.edges, 1);
        let inventory = owner_inventory(&storage, "owner:1").unwrap();
        assert_eq!(inventory["members"].as_array().unwrap().len(), 2);
        assert_eq!(inventory["members"][0]["pressure"]["band"], "orange");
        let access = state_access(&storage, "state:1").unwrap();
        assert_eq!(access["total_relationships"], 1);
    }
}
