use crate::diff::EvidenceScopeFingerprint;
use crate::model::{QualityEvent, QualityMetric};
use crate::storage::{CoverageLineBulk, EvidenceArtifactScope, Storage};
use anyhow::{Context, Result};
use serde_json::{json, Value};

const DEFAULT_COVERAGE_SOURCE: &str = "coverage";
const RELATIVE_ROOTS: &[&str] = &[
    "compiler/",
    "src/",
    "gems/",
    "tools/",
    "transpile-tests/",
    "zig/",
    "examples/",
    "benchmarks/",
    "spec/",
];

#[derive(Debug, Clone, PartialEq)]
pub struct CoverageRecord {
    pub path: String,
    pub line_coverage: Option<f64>,
    pub integration_coverage: Option<f64>,
    pub mutant_coverage: Option<f64>,
    pub hard_gated: Option<bool>,
    pub line_hits: Vec<CoverageLineHit>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CoverageLineHit {
    pub line: u32,
    pub hits: u32,
    pub is_partial: bool,
    pub coverage_percent: Option<f64>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CoverageIngestStats {
    pub files: usize,
    pub units: usize,
    pub events: usize,
    pub line_events: usize,
    pub skipped_files: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverageIngestOptions {
    pub line_source: String,
    pub evidence_scope: Option<EvidenceScopeFingerprint>,
    pub complete: bool,
}

impl Default for CoverageIngestOptions {
    fn default() -> Self {
        Self {
            line_source: DEFAULT_COVERAGE_SOURCE.to_string(),
            evidence_scope: None,
            complete: false,
        }
    }
}

pub fn ingest_coverage_json(
    storage: &Storage,
    input: &str,
    format: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
    replace: bool,
) -> Result<CoverageIngestStats> {
    ingest_coverage_json_with_options(
        storage,
        input,
        format,
        commit_hash,
        timestamp,
        replace,
        &CoverageIngestOptions::default(),
    )
}

pub fn ingest_coverage_json_with_options(
    storage: &Storage,
    input: &str,
    format: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
    replace: bool,
    options: &CoverageIngestOptions,
) -> Result<CoverageIngestStats> {
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in gigasail metadata");
    }

    let records = parse_coverage_input(input, format)?;
    let timestamp = timestamp
        .or(storage.commit_timestamp(commit_hash)?)
        .unwrap_or_default();
    let mut stats = CoverageIngestStats {
        files: records.len(),
        ..CoverageIngestStats::default()
    };

    let owns_transaction = !storage.transaction_active();
    if owns_transaction {
        storage.begin_transaction()?;
    }
    if replace {
        if options.line_source == DEFAULT_COVERAGE_SOURCE {
            storage.delete_coverage_for_commit(commit_hash)?;
        } else {
            storage.delete_coverage_lines_for_commit_source(commit_hash, &options.line_source)?;
        }
    }
    let result = ingest_records(
        storage,
        records,
        commit_hash,
        timestamp,
        &mut stats,
        options,
    );
    match result {
        Ok(()) => {
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

fn ingest_records(
    storage: &Storage,
    records: Vec<CoverageRecord>,
    commit_hash: &str,
    timestamp: i64,
    stats: &mut CoverageIngestStats,
    options: &CoverageIngestOptions,
) -> Result<()> {
    let mut bulk_lines = Vec::new();
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
            bulk_lines.push(CoverageLineBulk {
                commit_hash: commit_hash.to_string(),
                timestamp,
                path: path.clone(),
                line: hit.line,
                hits: hit.hits,
                is_partial: hit.is_partial,
                coverage_percent: hit.coverage_percent,
                source: options.line_source.clone(),
            });
        }
    }
    stats.line_events += storage.record_coverage_lines_bulk(&bulk_lines)?;
    if let Some(scope) = &options.evidence_scope {
        if scope.revision != commit_hash {
            anyhow::bail!("coverage evidence scope revision must match commit");
        }
        storage.record_evidence_artifact_scope(&EvidenceArtifactScope {
            family: "coverage".into(),
            source: options.line_source.clone(),
            scope: scope.clone(),
            complete: options.complete,
            expected_lines: bulk_lines
                .iter()
                .map(|line| (line.path.clone(), line.line))
                .collect(),
        })?;
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
        "sqlcov" | "sql-cov" => Ok(parse_sqlcov_records(value)),
        "simplecov" => Ok(parse_simplecov_records(value)),
        other => anyhow::bail!("unsupported coverage format {other:?}"),
    }
}

fn parse_sqlcov_records(value: &Value) -> Vec<CoverageRecord> {
    let Some(path) = value.get("file_path").and_then(Value::as_str) else {
        return Vec::new();
    };
    let mut lines = std::collections::BTreeMap::<u32, CoverageLineHit>::new();
    for statement in value
        .get("statements")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(start) = statement
            .get("start_line")
            .and_then(Value::as_u64)
            .and_then(|line| u32::try_from(line).ok())
        else {
            continue;
        };
        let end = statement
            .get("end_line")
            .and_then(Value::as_u64)
            .and_then(|line| u32::try_from(line).ok())
            .unwrap_or(start)
            .max(start);
        let hits = statement
            .get("hit_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let hits = u32::try_from(hits).unwrap_or(u32::MAX);
        for line in start..=end {
            lines.insert(
                line,
                CoverageLineHit {
                    line,
                    hits,
                    is_partial: false,
                    coverage_percent: Some(if hits > 0 { 100.0 } else { 0.0 }),
                },
            );
        }
    }
    let metrics = value
        .get("metrics")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|metric| metric.get("measurable").and_then(Value::as_bool) != Some(false));
    let mut covered_branches = 0_u64;
    let mut total_branches = 0_u64;
    let mut branches_by_line = std::collections::BTreeMap::<u32, (u64, u64)>::new();
    for metric in metrics {
        let Some(line) = metric
            .pointer("/span/start_line")
            .and_then(Value::as_u64)
            .and_then(|line| u32::try_from(line).ok())
        else {
            continue;
        };
        let nullable = metric
            .pointer("/span/nullable")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let counts = [
            metric
                .get("hit_true_count")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            metric
                .get("hit_false_count")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            metric
                .get("hit_unknown_count")
                .and_then(Value::as_u64)
                .unwrap_or(0),
        ];
        let branch_count = if nullable { 3 } else { 2 };
        let covered = counts
            .iter()
            .take(branch_count)
            .filter(|count| **count > 0)
            .count() as u64;
        covered_branches += covered;
        total_branches += branch_count as u64;
        let branch_totals = branches_by_line.entry(line).or_default();
        branch_totals.0 += covered;
        branch_totals.1 += branch_count as u64;
        let entry = lines.entry(line).or_insert(CoverageLineHit {
            line,
            hits: 0,
            is_partial: false,
            coverage_percent: Some(0.0),
        });
        entry.is_partial |= covered < branch_count as u64;
    }
    for (line, (covered, total)) in branches_by_line {
        if let Some(entry) = lines.get_mut(&line) {
            entry.coverage_percent = (total > 0).then_some(covered as f64 * 100.0 / total as f64);
        }
    }
    if lines.is_empty() {
        return Vec::new();
    }
    let line_coverage = lines
        .values()
        .map(|line| {
            line.coverage_percent
                .unwrap_or(if line.hits > 0 { 100.0 } else { 0.0 })
        })
        .sum::<f64>()
        / lines.len() as f64;
    vec![CoverageRecord {
        path: normalize_path(path),
        line_coverage: Some(line_coverage),
        integration_coverage: (total_branches > 0)
            .then_some(covered_branches as f64 * 100.0 / total_branches as f64),
        mutant_coverage: None,
        hard_gated: None,
        line_hits: lines.into_values().collect(),
    }]
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
        .and_then(finite_json_f64)
        .or_else(|| node.get("coverage").and_then(finite_json_f64));

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

fn parse_simplecov_records(value: &Value) -> Vec<CoverageRecord> {
    let mut by_path = std::collections::BTreeMap::<String, Vec<Option<u32>>>::new();
    let Some(resultsets) = value.as_object() else {
        return Vec::new();
    };

    for resultset in resultsets.values() {
        let Some(coverage) = resultset.get("coverage").and_then(Value::as_object) else {
            continue;
        };
        for (raw_path, file_coverage) in coverage {
            let Some(lines) = simplecov_lines(file_coverage) else {
                continue;
            };
            let path = normalize_path(raw_path);
            let entry = by_path.entry(path).or_default();
            if entry.len() < lines.len() {
                entry.resize(lines.len(), None);
            }
            for (index, hits) in lines.into_iter().enumerate() {
                let Some(hits) = hits else {
                    continue;
                };
                let current = entry[index].unwrap_or(0);
                entry[index] = Some(current.max(hits));
            }
        }
    }

    by_path
        .into_iter()
        .filter_map(|(path, lines)| {
            let line_hits = lines
                .iter()
                .enumerate()
                .filter_map(|(index, hits)| {
                    hits.map(|hits| CoverageLineHit {
                        line: (index + 1) as u32,
                        hits,
                        is_partial: false,
                        coverage_percent: None,
                    })
                })
                .collect::<Vec<_>>();
            if line_hits.is_empty() {
                return None;
            }
            let covered = line_hits.iter().filter(|hit| hit.hits > 0).count();
            let line_coverage = Some((covered as f64) * 100.0 / (line_hits.len() as f64));
            Some(CoverageRecord {
                path,
                line_coverage,
                integration_coverage: None,
                mutant_coverage: None,
                hard_gated: None,
                line_hits,
            })
        })
        .collect()
}

fn simplecov_lines(file_coverage: &Value) -> Option<Vec<Option<u32>>> {
    if let Some(lines) = file_coverage.get("lines").and_then(Value::as_array) {
        return Some(
            lines
                .iter()
                .map(|line| line.as_u64().and_then(|value| u32::try_from(value).ok()))
                .collect(),
        );
    }
    file_coverage.as_array().map(|lines| {
        lines
            .iter()
            .map(|line| line.as_u64().and_then(|value| u32::try_from(value).ok()))
            .collect()
    })
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
    keys.iter()
        .find_map(|key| node.get(*key).and_then(finite_json_f64))
}

fn finite_json_f64(value: &Value) -> Option<f64> {
    value.as_f64().filter(|number| number.is_finite())
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
                return u32::try_from(number).ok().map(|line| CoverageLineHit {
                    line,
                    hits: 1,
                    is_partial: false,
                    coverage_percent: None,
                });
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
                is_partial: false,
                coverage_percent: None,
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

    let mut sources = Vec::new();
    for source in document
        .descendants()
        .filter(|node| node.has_tag_name("source"))
    {
        if let Some(text) = source.text() {
            let t = text.trim();
            if !t.is_empty() {
                sources.push(t);
            }
        }
    }

    for class in document
        .descendants()
        .filter(|node| node.has_tag_name("class"))
    {
        let Some(raw_filename) = class.attribute("filename") else {
            continue;
        };
        let path = if let Some(source) = sources.first() {
            let resolved = if raw_filename.starts_with('/') {
                raw_filename.to_string()
            } else if source.ends_with('/') {
                format!("{}{}", source, raw_filename)
            } else {
                format!("{}/{}", source, raw_filename)
            };
            normalize_path(&resolved)
        } else {
            normalize_path(raw_filename)
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
                let is_partial = if line.attribute("branch").unwrap_or("false") == "true" {
                    if let Some(cc) = line.attribute("condition-coverage") {
                        !cc.starts_with("100%")
                    } else {
                        false
                    }
                } else {
                    false
                };
                Some(CoverageLineHit {
                    line: line_no,
                    hits,
                    is_partial,
                    coverage_percent: None,
                })
            })
            .collect::<Vec<_>>();
        let line_coverage = if line_hits.is_empty() {
            class
                .attribute("line-rate")
                .and_then(|value| value.parse::<f64>().ok())
                .filter(|value| value.is_finite())
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
    let trimmed = path.trim_start_matches("./");
    let mut best_match: Option<(usize, &str)> = None;

    for root in RELATIVE_ROOTS {
        if trimmed.starts_with(root) {
            best_match = Some((0, root));
            break;
        }
        let marker = format!("/{root}");
        if let Some(index) = trimmed.find(&marker) {
            let actual_idx = index + 1;
            if best_match.is_none_or(|(best_idx, _)| actual_idx < best_idx) {
                best_match = Some((actual_idx, root));
            }
        }
    }

    if let Some((idx, _)) = best_match {
        trimmed[idx..].to_string()
    } else {
        trimmed.trim_start_matches('/').to_string()
    }
}

pub fn coverage_records_to_test_exposure_json(
    records: &[CoverageRecord],
    test_type: &str,
    test_id: &str,
    producer: &str,
    mutation_status: Option<&str>,
    mutation_kind: Option<&str>,
) -> String {
    let hits = records
        .iter()
        .flat_map(|record| {
            record
                .line_hits
                .iter()
                .filter(|hit| hit.hits > 0)
                .map(move |hit| {
                    let mut payload = json!({
                        "file": record.path,
                        "line": hit.line,
                        "test_id": test_id,
                        "test_type": test_type,
                        "coverage_hits": hit.hits,
                    });
                    if let Some(status) = mutation_status {
                        payload["mutation_status"] = json!(status);
                    }
                    if let Some(kind) = mutation_kind {
                        payload["mutation_kind"] = json!(kind);
                    }
                    payload
                })
        })
        .collect::<Vec<_>>();
    json!({
        "schema": "test-exposure/v1",
        "producer": producer,
        "note": "Suite-level exposure synthesized from aggregate coverage; test_id names the coverage source, not an individual test case.",
        "hits": hits,
    })
    .to_string()
}

pub fn resolve_coverage_record_paths(
    storage: &Storage,
    records: &[CoverageRecord],
) -> Result<Vec<CoverageRecord>> {
    let mut resolved = Vec::new();
    for record in records {
        let Some(path) = storage.resolve_current_path(&record.path)? else {
            continue;
        };
        let mut record = record.clone();
        record.path = path;
        resolved.push(record);
    }
    Ok(resolved)
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
    if !new_value.is_finite() {
        return Ok(0);
    }
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

    #[test]
    fn parses_sqlcov_branch_states_as_partial_line_coverage() {
        let payload = serde_json::json!({
            "format": "sql-cov/v1", "file_path": "gems/gigasail/sql/demo.sql",
            "statements": [{ "start_line": 2, "end_line": 3, "hit_count": 1 }],
            "metrics": [{
                "measurable": true, "span": { "start_line": 2, "nullable": true },
                "hit_true_count": 3, "hit_false_count": 1, "hit_unknown_count": 0
            }, {
                "measurable": false, "span": { "start_line": 3, "nullable": true },
                "hit_true_count": 0, "hit_false_count": 0, "hit_unknown_count": 0
            }]
        });
        let records = parse_coverage_records(&payload, "sqlcov").unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].path, "gems/gigasail/sql/demo.sql");
        assert!((records[0].line_coverage.unwrap() - 250.0 / 3.0).abs() < 0.000_001);
        assert_eq!(records[0].integration_coverage, Some(200.0 / 3.0));
        assert_eq!(
            records[0].line_hits,
            vec![
                CoverageLineHit {
                    line: 2,
                    hits: 1,
                    is_partial: true,
                    coverage_percent: Some(200.0 / 3.0)
                },
                CoverageLineHit {
                    line: 3,
                    hits: 1,
                    is_partial: false,
                    coverage_percent: Some(100.0)
                },
            ]
        );
    }
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
            .any(|record| record.path == "src/ast/type.rb" && record.line_coverage == Some(99.78)));
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
        assert_eq!(
            records[0].line_hits[0],
            CoverageLineHit {
                line: 1,
                hits: 2,
                is_partial: false,
                coverage_percent: None
            }
        );
        assert_eq!(
            records[0].line_hits[1],
            CoverageLineHit {
                line: 2,
                hits: 0,
                is_partial: false,
                coverage_percent: None
            }
        );
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
        assert_eq!(
            records[0].line_hits[0],
            CoverageLineHit {
                line: 1,
                hits: 3,
                is_partial: false,
                coverage_percent: None
            }
        );
        assert_eq!(
            records[0].line_hits[1],
            CoverageLineHit {
                line: 2,
                hits: 0,
                is_partial: false,
                coverage_percent: None
            }
        );
    }

    #[test]
    fn ignores_non_finite_cobertura_line_rate() {
        let payload = r#"
          <!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">
          <coverage>
            <packages><package><classes>
              <class filename="src/generated.go" line-rate="NaN">
                <lines></lines>
              </class>
            </classes></package></packages>
          </coverage>
        "#;

        let records = parse_coverage_input(payload, "cobertura").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].path, "src/generated.go");
        assert_eq!(records[0].line_coverage, None);
        assert!(records[0].line_hits.is_empty());
    }

    #[test]
    fn parses_simplecov_resultset_line_hits() {
        let value = json!({
          "RSpec": {
            "coverage": {
              "/repo/src/demo.rb": {
                "lines": [null, 2, 0, null, 1],
                "branches": {}
              }
            },
            "timestamp": 10
          },
          "transpile-tests": {
            "coverage": {
              "/repo/src/demo.rb": {
                "lines": [null, 0, 3, null, null],
                "branches": {}
              }
            },
            "timestamp": 11
          }
        });

        let records = parse_coverage_records(&value, "simplecov").unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].path, "src/demo.rb");
        assert_eq!(
            records[0].line_hits,
            vec![
                CoverageLineHit {
                    line: 2,
                    hits: 2,
                    is_partial: false,
                    coverage_percent: None
                },
                CoverageLineHit {
                    line: 3,
                    hits: 3,
                    is_partial: false,
                    coverage_percent: None
                },
                CoverageLineHit {
                    line: 5,
                    hits: 1,
                    is_partial: false,
                    coverage_percent: None
                },
            ]
        );
        assert_eq!(records[0].line_coverage, Some(100.0));
    }

    #[test]
    fn builds_suite_level_test_exposure_from_covered_lines() {
        let records = vec![CoverageRecord {
            path: "src/demo.rb".to_string(),
            line_coverage: Some(50.0),
            integration_coverage: None,
            mutant_coverage: None,
            hard_gated: None,
            line_hits: vec![
                CoverageLineHit {
                    line: 1,
                    hits: 2,
                    is_partial: false,
                    coverage_percent: None,
                },
                CoverageLineHit {
                    line: 2,
                    hits: 0,
                    is_partial: false,
                    coverage_percent: None,
                },
            ],
        }];

        let payload = coverage_records_to_test_exposure_json(
            &records,
            "unit",
            "coverage:unit:coverage/.resultset.json",
            "test",
            Some("killed"),
            Some("stochastic"),
        );
        let value: Value = serde_json::from_str(&payload).unwrap();
        let hits = value.get("hits").and_then(Value::as_array).unwrap();

        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].get("file").and_then(Value::as_str),
            Some("src/demo.rb")
        );
        assert_eq!(hits[0].get("line").and_then(Value::as_u64), Some(1));
        assert_eq!(
            hits[0].get("test_type").and_then(Value::as_str),
            Some("unit")
        );
        assert_eq!(
            hits[0].get("mutation_status").and_then(Value::as_str),
            Some("killed")
        );
        assert_eq!(
            hits[0].get("mutation_kind").and_then(Value::as_str),
            Some("stochastic")
        );
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

        let stats = ingest_coverage_json(
            &storage,
            &payload.to_string(),
            "codecov",
            "abc",
            None,
            false,
        )
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

        let stats =
            ingest_coverage_json(&storage, payload, "cobertura", "abc", None, false).unwrap();

        assert_eq!(stats.files, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.events, 1);
        assert_eq!(stats.line_events, 2);
        assert_eq!(storage.count_rows("coverage_line_events").unwrap(), 2);
        let stored_path: String = storage
            .connection()
            .query_row("SELECT path FROM coverage_line_events LIMIT 1", [], |row| {
                row.get(0)
            })
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

    #[test]
    fn typed_coverage_ingest_uses_source_specific_line_events() {
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
            "path": "src/demo.rb",
            "coverage": 50.0,
            "line_hits": [{ "line": 1, "hits": 1 }]
          }]
        });

        let options = CoverageIngestOptions {
            line_source: "coverage:unit".to_string(),
            evidence_scope: None,
            complete: false,
        };
        let stats = ingest_coverage_json_with_options(
            &storage,
            &payload.to_string(),
            "generic",
            "abc",
            None,
            false,
            &options,
        )
        .unwrap();

        assert_eq!(stats.line_events, 1);
        let source: String = storage
            .connection()
            .query_row(
                "SELECT source FROM coverage_line_events LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(source, "coverage:unit");
    }

    #[test]
    fn test_quality_ingest_edge_cases() {
        let storage = Storage::open_memory().unwrap();
        let payload_generic = json!({
            "files": [{
                "path": "src/demo.rb",
                "coverage": 50.0,
                "is_hard_gated": true,
                "line_hits": [3, 4]
            }]
        });

        let err = ingest_coverage_json(
            &storage,
            &payload_generic.to_string(),
            "generic",
            "nonexistent",
            None,
            false,
        );
        assert!(err.is_err());

        let err_format = ingest_coverage_json(&storage, "{}", "bad_format", "abc", None, false);
        assert!(err_format.is_err());

        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();

        let stats_skipped = ingest_coverage_json(
            &storage,
            &payload_generic.to_string(),
            "generic",
            "abc",
            None,
            false,
        )
        .unwrap();
        assert_eq!(stats_skipped.skipped_files, 1);

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

        let options = CoverageIngestOptions {
            line_source: "custom_source".to_string(),
            evidence_scope: None,
            complete: false,
        };
        let stats = ingest_coverage_json_with_options(
            &storage,
            &payload_generic.to_string(),
            "generic",
            "abc",
            None,
            true,
            &options,
        )
        .unwrap();
        assert_eq!(stats.files, 1);
        assert_eq!(stats.line_events, 2);

        let xml_payload = r#"
          <coverage>
            <sources>
              <source>/app/</source>
            </sources>
            <packages><package><classes>
              <class filename="src/demo.rb" line-rate="1.0">
                <lines>
                  <line number="1" hits="5"/>
                </lines>
              </class>
            </classes></package></packages>
          </coverage>
        "#;
        let stats_xml =
            ingest_coverage_json(&storage, xml_payload, "cobertura", "abc", None, false).unwrap();
        assert_eq!(stats_xml.files, 1);
        assert_eq!(stats_xml.line_events, 1);
    }
}
