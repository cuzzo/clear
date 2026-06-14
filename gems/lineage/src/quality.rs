use crate::model::{QualityEvent, QualityMetric};
use crate::storage::Storage;
use anyhow::{Context, Result};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct CoverageRecord {
    pub path: String,
    pub line_coverage: Option<f64>,
    pub integration_coverage: Option<f64>,
    pub mutant_coverage: Option<f64>,
    pub hard_gated: Option<bool>,
    pub line_hits: Vec<CoverageLineHit>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoverageLineHit {
    pub line: u32,
    pub hits: u32,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CoverageIngestStats {
    pub files: usize,
    pub units: usize,
    pub events: usize,
    pub line_events: usize,
    pub skipped_files: usize,
}

pub fn ingest_coverage_json(
    storage: &Storage,
    input: &str,
    format: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
    replace: bool,
) -> Result<CoverageIngestStats> {
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in lineage metadata");
    }

    let records = parse_coverage_input(input, format)?;
    let timestamp = timestamp
        .or(storage.commit_timestamp(commit_hash)?)
        .unwrap_or_default();
    let mut stats = CoverageIngestStats {
        files: records.len(),
        ..CoverageIngestStats::default()
    };

    storage.begin_transaction()?;
    if replace {
        storage.delete_coverage_for_commit(commit_hash)?;
    }
    let result = ingest_records(storage, records, commit_hash, timestamp, &mut stats);
    match result {
        Ok(()) => {
            storage.commit_transaction()?;
            Ok(stats)
        }
        Err(error) => {
            let _ = storage.rollback_transaction();
            Err(error)
        }
    }
}

fn ingest_records(
    storage: &Storage,
    records: Vec<CoverageRecord>,
    commit_hash: &str,
    timestamp: i64,
    stats: &mut CoverageIngestStats,
) -> Result<()> {
    for record in records {
        let Some(path) = storage.resolve_current_path(&record.path)? else {
            stats.skipped_files += 1;
            continue;
        };
        let unit_ids = storage.unit_ids_for_current_path(&path)?;
        if unit_ids.is_empty() {
            stats.skipped_files += 1;
            continue;
        }
        for unit_id in unit_ids {
            stats.units += 1;
            stats.events += record_metric(
                storage,
                &unit_id,
                commit_hash,
                timestamp,
                QualityMetric::LineCoverage,
                record.line_coverage,
            )?;
            stats.events += record_metric(
                storage,
                &unit_id,
                commit_hash,
                timestamp,
                QualityMetric::IntegrationCoverage,
                record.integration_coverage,
            )?;
            stats.events += record_metric(
                storage,
                &unit_id,
                commit_hash,
                timestamp,
                QualityMetric::MutantCoverage,
                record.mutant_coverage,
            )?;
            stats.events += record_metric(
                storage,
                &unit_id,
                commit_hash,
                timestamp,
                QualityMetric::GateStatus,
                record.hard_gated.map(|value| if value { 1.0 } else { 0.0 }),
            )?;
        }
        for hit in &record.line_hits {
            stats.line_events += usize::from(storage.record_coverage_line(
                commit_hash,
                timestamp,
                &path,
                hit.line,
                hit.hits,
            )?);
        }
    }

    Ok(())
}

pub fn parse_coverage_input(input: &str, format: &str) -> Result<Vec<CoverageRecord>> {
    if format == "cobertura" {
        return parse_cobertura_records(input);
    }

    let value: Value = serde_json::from_str(input).context("parse coverage JSON")?;
    parse_coverage_records(&value, format)
}

pub fn parse_coverage_records(value: &Value, format: &str) -> Result<Vec<CoverageRecord>> {
    match format {
        "codecov" => Ok(parse_codecov_records(value)),
        "boobytrap" | "generic" => Ok(parse_generic_records(value)),
        other => anyhow::bail!("unsupported coverage format {other:?}"),
    }
}

fn parse_codecov_records(value: &Value) -> Vec<CoverageRecord> {
    let mut records = Vec::new();
    if let Some(files) = value.get("files").and_then(Value::as_array) {
        for file in files {
            if let Some(record) = record_from_codecov_node(file) {
                records.push(record);
            }
        }
    }
    if let Some(nodes) = value.as_array() {
        collect_codecov_tree(nodes, &mut records);
    }
    records
}

fn collect_codecov_tree(nodes: &[Value], records: &mut Vec<CoverageRecord>) {
    for node in nodes {
        if let Some(record) = record_from_codecov_node(node) {
            records.push(record);
        }
        if let Some(children) = node.get("children").and_then(Value::as_array) {
            collect_codecov_tree(children, records);
        }
    }
}

fn record_from_codecov_node(node: &Value) -> Option<CoverageRecord> {
    let path = node
        .get("full_path")
        .or_else(|| node.get("name"))
        .or_else(|| node.get("path"))
        .and_then(Value::as_str)?
        .trim_start_matches("./")
        .to_string();
    let line_coverage = node
        .get("totals")
        .and_then(|totals| totals.get("coverage"))
        .and_then(Value::as_f64)
        .or_else(|| node.get("coverage").and_then(Value::as_f64));

    Some(CoverageRecord {
        path,
        line_coverage,
        integration_coverage: None,
        mutant_coverage: None,
        hard_gated: None,
        line_hits: Vec::new(),
    })
}

fn parse_generic_records(value: &Value) -> Vec<CoverageRecord> {
    let rows = value
        .as_array()
        .or_else(|| value.get("files").and_then(Value::as_array))
        .into_iter()
        .flatten();
    rows.filter_map(record_from_generic_node).collect()
}

fn record_from_generic_node(node: &Value) -> Option<CoverageRecord> {
    let path = node
        .get("path")
        .or_else(|| node.get("name"))
        .or_else(|| node.get("filename"))
        .and_then(Value::as_str)?
        .trim_start_matches("./")
        .to_string();

    Some(CoverageRecord {
        path,
        line_coverage: metric_value(node, &["line_coverage", "coverage"]),
        integration_coverage: metric_value(node, &["integration_coverage"]),
        mutant_coverage: metric_value(node, &["mutant_coverage", "mutant_kill_rate"]),
        hard_gated: node
            .get("hard_gated")
            .or_else(|| node.get("is_hard_gated"))
            .and_then(Value::as_bool),
        line_hits: line_hits_from_generic_node(node),
    })
}

fn metric_value(node: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| node.get(*key).and_then(Value::as_f64))
}

fn line_hits_from_generic_node(node: &Value) -> Vec<CoverageLineHit> {
    let Some(lines) = node
        .get("line_hits")
        .or_else(|| node.get("lines"))
        .or_else(|| node.get("covered_lines"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };

    lines
        .iter()
        .filter_map(|line| {
            if let Some(number) = line.as_u64() {
                return u32::try_from(number)
                    .ok()
                    .map(|line| CoverageLineHit { line, hits: 1 });
            }

            let line_no = line
                .get("line")
                .or_else(|| line.get("number"))
                .or_else(|| line.get("line_number"))
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())?;
            let hits = line
                .get("hits")
                .or_else(|| line.get("count"))
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
                .unwrap_or(1);
            Some(CoverageLineHit {
                line: line_no,
                hits,
            })
        })
        .collect()
}

fn parse_cobertura_records(input: &str) -> Result<Vec<CoverageRecord>> {
    let document = roxmltree::Document::parse_with_options(
        input,
        roxmltree::ParsingOptions {
            allow_dtd: true,
            ..roxmltree::ParsingOptions::default()
        },
    )
    .context("parse Cobertura XML")?;
    let mut records = Vec::new();

    for class in document.descendants().filter(|node| node.has_tag_name("class")) {
        let Some(path) = class.attribute("filename").map(normalize_path) else {
            continue;
        };
        if path.is_empty() {
            continue;
        }

        let line_hits = class
            .descendants()
            .filter(|node| node.has_tag_name("line"))
            .filter_map(|line| {
                let line_no = line.attribute("number")?.parse::<u32>().ok()?;
                let hits = line.attribute("hits").unwrap_or("0").parse::<u32>().ok()?;
                Some(CoverageLineHit {
                    line: line_no,
                    hits,
                })
            })
            .collect::<Vec<_>>();
        let line_coverage = if line_hits.is_empty() {
            class
                .attribute("line-rate")
                .and_then(|value| value.parse::<f64>().ok())
                .map(|value| value * 100.0)
        } else {
            let covered = line_hits.iter().filter(|hit| hit.hits > 0).count();
            Some((covered as f64) * 100.0 / (line_hits.len() as f64))
        };

        records.push(CoverageRecord {
            path,
            line_coverage,
            integration_coverage: None,
            mutant_coverage: None,
            hard_gated: None,
            line_hits,
        });
    }

    Ok(records)
}

fn normalize_path(path: &str) -> String {
    path.trim_start_matches("./").to_string()
}

fn record_metric(
    storage: &Storage,
    unit_id: &str,
    commit_hash: &str,
    timestamp: i64,
    metric_type: QualityMetric,
    value: Option<f64>,
) -> Result<usize> {
    let Some(new_value) = value else {
        return Ok(0);
    };
    let recorded = storage.record_quality_metric(&QualityEvent {
        unit_id: unit_id.to_string(),
        commit_hash: commit_hash.to_string(),
        timestamp,
        metric_type,
        old_value: None,
        new_value,
    })?;
    Ok(usize::from(recorded))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CommitMetadata, LogicalUnit, UnitKind};
    use serde_json::json;

    #[test]
    fn parses_codecov_totals_files() {
        let value = json!({
          "files": [
            {
              "name": "src/ast/type.rb",
              "totals": { "coverage": 99.78, "lines": 1880 }
            }
          ]
        });

        let records = parse_coverage_records(&value, "codecov").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].path, "src/ast/type.rb");
        assert_eq!(records[0].line_coverage, Some(99.78));
    }

    #[test]
    fn parses_codecov_report_tree() {
        let value = json!([
          {
            "name": "src",
            "full_path": "src",
            "coverage": 99.3,
            "children": [
              {
                "name": "type.rb",
                "full_path": "src/ast/type.rb",
                "coverage": 99.78
              }
            ]
          }
        ]);

        let records = parse_coverage_records(&value, "codecov").unwrap();

        assert!(records
            .iter()
            .any(|record| record.path == "src/ast/type.rb"
                && record.line_coverage == Some(99.78)));
    }

    #[test]
    fn parses_generic_line_hits() {
        let value = json!({
          "files": [{
            "path": "src/demo.rb",
            "coverage": 66.6,
            "line_hits": [
              { "line": 1, "hits": 2 },
              { "line": 2, "hits": 0 }
            ]
          }]
        });

        let records = parse_coverage_records(&value, "generic").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].line_hits[0], CoverageLineHit { line: 1, hits: 2 });
        assert_eq!(records[0].line_hits[1], CoverageLineHit { line: 2, hits: 0 });
    }

    #[test]
    fn parses_cobertura_line_hits() {
        let payload = r#"
          <!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">
          <coverage>
            <packages><package><classes>
              <class filename="src/demo.rb" line-rate="0.5">
                <lines>
                  <line number="1" hits="3"/>
                  <line number="2" hits="0"/>
                </lines>
              </class>
            </classes></package></packages>
          </coverage>
        "#;

        let records = parse_coverage_input(payload, "cobertura").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].path, "src/demo.rb");
        assert_eq!(records[0].line_coverage, Some(50.0));
        assert_eq!(records[0].line_hits[0], CoverageLineHit { line: 1, hits: 3 });
        assert_eq!(records[0].line_hits[1], CoverageLineHit { line: 2, hits: 0 });
    }

    #[test]
    fn ingests_codecov_file_coverage_into_matching_units() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let payload = json!({
          "files": [{
            "name": "src/demo.rb",
            "totals": { "coverage": 88.5 }
          }]
        });

        let stats =
            ingest_coverage_json(&storage, &payload.to_string(), "codecov", "abc", None, false)
                .unwrap();

        assert_eq!(stats.files, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.events, 1);
        assert_eq!(storage.count_rows("quality_events").unwrap(), 1);
    }

    #[test]
    fn ingests_cobertura_line_hits() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let payload = r#"
          <coverage>
            <packages><package><classes>
              <class filename="demo.rb">
                <lines>
                  <line number="1" hits="1"/>
                  <line number="2" hits="0"/>
                </lines>
              </class>
            </classes></package></packages>
          </coverage>
        "#;

        let stats = ingest_coverage_json(&storage, payload, "cobertura", "abc", None, false).unwrap();

        assert_eq!(stats.files, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.events, 1);
        assert_eq!(stats.line_events, 2);
        assert_eq!(storage.count_rows("coverage_line_events").unwrap(), 2);
        let stored_path: String = storage
            .connection()
            .query_row("SELECT path FROM coverage_line_events LIMIT 1", [], |row| row.get(0))
            .unwrap();
        assert_eq!(stored_path, "src/demo.rb");
    }

    #[test]
    fn coverage_ingest_is_idempotent_and_replace_removes_stale_rows() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let first = json!({
          "files": [{
            "path": "src/demo.rb",
            "coverage": 50.0,
            "line_hits": [
              { "line": 1, "hits": 1 },
              { "line": 2, "hits": 0 }
            ]
          }]
        });

        let stats =
            ingest_coverage_json(&storage, &first.to_string(), "generic", "abc", None, false)
                .unwrap();
        assert_eq!(stats.events, 1);
        assert_eq!(stats.line_events, 2);

        let stats =
            ingest_coverage_json(&storage, &first.to_string(), "generic", "abc", None, false)
                .unwrap();
        assert_eq!(stats.events, 0);
        assert_eq!(stats.line_events, 0);
        assert_eq!(storage.count_rows("quality_events").unwrap(), 1);
        assert_eq!(storage.count_rows("coverage_line_events").unwrap(), 2);

        let lower_partial = json!({
          "files": [{
            "path": "src/demo.rb",
            "coverage": 25.0,
            "line_hits": [{ "line": 1, "hits": 0 }]
          }]
        });
        let stats = ingest_coverage_json(
            &storage,
            &lower_partial.to_string(),
            "generic",
            "abc",
            None,
            false,
        )
        .unwrap();
        assert_eq!(stats.events, 0);
        assert_eq!(stats.line_events, 0);

        let replacement = json!({
          "files": [{
            "path": "src/demo.rb",
            "coverage": 100.0,
            "line_hits": [{ "line": 1, "hits": 3 }]
          }]
        });
        let stats = ingest_coverage_json(
            &storage,
            &replacement.to_string(),
            "generic",
            "abc",
            None,
            true,
        )
        .unwrap();

        assert_eq!(stats.events, 1);
        assert_eq!(stats.line_events, 1);
        assert_eq!(storage.count_rows("quality_events").unwrap(), 1);
        assert_eq!(storage.count_rows("coverage_line_events").unwrap(), 1);
        let current: f64 = storage
            .connection()
            .query_row(
                "SELECT current_line_cov FROM logical_units WHERE id = ?1",
                [&unit.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(current, 100.0);
    }
}
