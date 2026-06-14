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
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CoverageIngestStats {
    pub files: usize,
    pub units: usize,
    pub events: usize,
    pub skipped_files: usize,
}

pub fn ingest_coverage_json(
    storage: &Storage,
    input: &str,
    format: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
) -> Result<CoverageIngestStats> {
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in lineage metadata");
    }

    let value: Value = serde_json::from_str(input).context("parse coverage JSON")?;
    let records = parse_coverage_records(&value, format)?;
    let timestamp = timestamp
        .or(storage.commit_timestamp(commit_hash)?)
        .unwrap_or_default();
    let mut stats = CoverageIngestStats {
        files: records.len(),
        ..CoverageIngestStats::default()
    };

    for record in records {
        let unit_ids = storage.unit_ids_for_current_path(&record.path)?;
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
    }

    Ok(stats)
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
    })
}

fn metric_value(node: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| node.get(*key).and_then(Value::as_f64))
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
            ingest_coverage_json(&storage, &payload.to_string(), "codecov", "abc", None).unwrap();

        assert_eq!(stats.files, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.events, 1);
        assert_eq!(storage.count_rows("quality_events").unwrap(), 1);
    }
}
