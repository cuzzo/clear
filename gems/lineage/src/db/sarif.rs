use crate::model::{short_hash, SarifArtifact, SarifFinding};
use crate::storage::{CurrentUnitSpan, Storage};
use anyhow::{Context, Result};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SarifIngestStats {
    pub artifacts: usize,
    pub findings: usize,
    pub skipped_files: usize,
    pub skipped_results: usize,
}

pub fn ingest_sarif_paths(
    storage: &Storage,
    repo: impl AsRef<Path>,
    inputs: &[PathBuf],
    source: &str,
    commit: &str,
    timestamp: Option<i64>,
    replace: bool,
) -> Result<SarifIngestStats> {
    let repo = repo.as_ref();
    let timestamp = timestamp
        .or_else(|| storage.commit_timestamp(commit).ok().flatten())
        .unwrap_or_else(unix_now);
    let files = collect_input_files(inputs)?;
    let unit_index = CurrentUnitIndex::load(storage)?;
    let mut stats = SarifIngestStats::default();

    storage.begin_transaction()?;
    let result = (|| {
        if replace {
            storage.delete_sarif_for_commit_source(commit, source)?;
        }
        for file in files {
            let payload = fs::read_to_string(&file)
                .with_context(|| format!("read SARIF artifact {}", file.display()))?;
            let value = match serde_json::from_str::<Value>(&payload) {
                Ok(value) => value,
                Err(_) => {
                    stats.skipped_files += 1;
                    continue;
                }
            };
            if !is_sarif_document(&value) {
                stats.skipped_files += 1;
                continue;
            }
            ingest_sarif_document(
                storage,
                repo,
                &file,
                &payload,
                &value,
                &unit_index,
                source,
                commit,
                timestamp,
                &mut stats,
            )?;
        }
        storage.prune_stale_sarif_data()?;
        storage.refresh_current_sarif_findings_view()?;
        Ok(())
    })();
    match result {
        Ok(()) => {
            storage.commit_transaction()?;
            Ok(stats)
        }
        Err(error) => {
            storage.rollback_transaction()?;
            Err(error)
        }
    }
}

fn collect_input_files(inputs: &[PathBuf]) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for input in inputs {
        collect_input_file(input, &mut files)?;
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn collect_input_file(input: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    if input.is_dir() {
        for entry in fs::read_dir(input).with_context(|| format!("read {}", input.display()))? {
            collect_input_file(&entry?.path(), files)?;
        }
        return Ok(());
    }
    if !input.is_file() {
        return Ok(());
    }
    let extension = input
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if matches!(extension.as_str(), "sarif" | "json") {
        files.push(input.to_path_buf());
    }
    Ok(())
}

fn is_sarif_document(value: &Value) -> bool {
    value.get("version").and_then(Value::as_str) == Some("2.1.0")
        && value.get("runs").and_then(Value::as_array).is_some()
}

#[allow(clippy::too_many_arguments)]
fn ingest_sarif_document(
    storage: &Storage,
    repo: &Path,
    artifact_path: &Path,
    payload: &str,
    value: &Value,
    unit_index: &CurrentUnitIndex,
    source: &str,
    commit: &str,
    timestamp: i64,
    stats: &mut SarifIngestStats,
) -> Result<()> {
    let sha = sha256(payload);
    let artifact_rel = path_to_repo_string(repo, artifact_path);
    let runs = value
        .get("runs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for (run_index, run) in runs.iter().enumerate() {
        let tool_name = run
            .pointer("/tool/driver/name")
            .and_then(Value::as_str)
            .unwrap_or("SARIF")
            .to_string();
        let run_format = run
            .pointer("/properties/format")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let artifact = SarifArtifact {
            source: source.to_string(),
            tool_name: tool_name.clone(),
            run_format: run_format.clone(),
            artifact_path: format!("{artifact_rel}#run{run_index}"),
            artifact_sha256: sha.clone(),
            commit_hash: commit.to_string(),
            timestamp,
            payload_json: payload.to_string(),
        };
        let artifact_id = storage.insert_sarif_artifact(&artifact)?;
        stats.artifacts += 1;

        let results = run
            .get("results")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for result in results {
            let normalized = normalize_result_locations(
                unit_index,
                repo,
                source,
                commit,
                timestamp,
                artifact_id,
                &tool_name,
                &run_format,
                &result,
            )?;
            if normalized.is_empty() {
                stats.skipped_results += 1;
                continue;
            }
            for finding in normalized {
                if storage.insert_sarif_finding(&finding)? {
                    stats.findings += 1;
                }
            }
        }
    }
    Ok(())
}

#[derive(Debug, Default)]
struct CurrentUnitIndex {
    by_path: HashMap<String, Vec<CurrentUnitSpan>>,
}

impl CurrentUnitIndex {
    fn load(storage: &Storage) -> Result<Self> {
        let mut by_path = HashMap::<String, Vec<CurrentUnitSpan>>::new();
        for span in storage.current_unit_spans()? {
            by_path.entry(span.path.clone()).or_default().push(span);
        }
        for spans in by_path.values_mut() {
            spans.sort_by_key(|span| {
                (
                    span.start_line,
                    span.end_line.saturating_sub(span.start_line),
                    span.id.clone(),
                )
            });
        }
        Ok(Self { by_path })
    }

    fn unit_id_for_path_line(&self, path: &str, line: u32) -> Option<String> {
        self.by_path.get(path).and_then(|spans| {
            spans
                .iter()
                .filter(|span| line >= span.start_line && line <= span.end_line)
                .min_by_key(|span| (span.end_line.saturating_sub(span.start_line), span.id.as_str()))
                .map(|span| span.id.clone())
        })
    }
}

#[allow(clippy::too_many_arguments)]
fn normalize_result_locations(
    unit_index: &CurrentUnitIndex,
    repo: &Path,
    source: &str,
    commit: &str,
    timestamp: i64,
    artifact_id: i64,
    tool_name: &str,
    run_format: &str,
    result: &Value,
) -> Result<Vec<SarifFinding>> {
    let rule_id = result
        .get("ruleId")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let level = result
        .get("level")
        .and_then(Value::as_str)
        .unwrap_or("warning")
        .to_string();
    let message = result_message(result).unwrap_or_else(|| rule_id.clone());
    let properties = result.get("properties").cloned().unwrap_or(Value::Null);
    let properties_json = serde_json::to_string(&properties)?;
    let raw_json = serde_json::to_string(result)?;
    let category = category_for_result(result, &properties, &rule_id);
    let is_dark_arm = is_dark_arm_result(result, &properties, &rule_id, &message, &category);
    let fingerprint = partial_fingerprint(result)
        .unwrap_or_else(|| short_hash(&format!("{rule_id}\0{message}\0{properties_json}")));
    let locations = result
        .get("locations")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut findings = Vec::new();
    for location in locations {
        let physical = location.get("physicalLocation").unwrap_or(&location);
        let Some(path) = physical
            .get("artifactLocation")
            .and_then(|artifact| artifact.get("uri"))
            .and_then(Value::as_str)
            .map(|uri| normalize_artifact_uri(repo, uri))
            .filter(|path| !path.is_empty())
        else {
            continue;
        };
        let null_region = Value::Null;
        let region = physical.get("region").unwrap_or(&null_region);
        let start_line = u32_field(region, "startLine").unwrap_or(1);
        let start_column = u32_field(region, "startColumn");
        let end_line = u32_field(region, "endLine");
        let end_column = u32_field(region, "endColumn");
        let unit_id = unit_index.unit_id_for_path_line(&path, start_line);
        let finding_key = finding_key(
            source,
            commit,
            tool_name,
            &rule_id,
            &path,
            start_line,
            start_column,
            end_line,
            end_column,
            &fingerprint,
            &message,
        );
        findings.push(SarifFinding {
            artifact_id,
            finding_key,
            source: source.to_string(),
            tool_name: tool_name.to_string(),
            run_format: run_format.to_string(),
            commit_hash: commit.to_string(),
            timestamp,
            rule_id: rule_id.clone(),
            level: level.clone(),
            message: message.clone(),
            path,
            start_line,
            start_column,
            end_line,
            end_column,
            category: category.clone(),
            is_dark_arm,
            unit_id,
            fingerprint: fingerprint.clone(),
            properties_json: properties_json.clone(),
            raw_json: raw_json.clone(),
        });
    }
    Ok(findings)
}

#[allow(clippy::too_many_arguments)]
fn finding_key(
    source: &str,
    commit: &str,
    tool_name: &str,
    rule_id: &str,
    path: &str,
    start_line: u32,
    start_column: Option<u32>,
    end_line: Option<u32>,
    end_column: Option<u32>,
    fingerprint: &str,
    message: &str,
) -> String {
    short_hash(&format!(
        "{source}\0{commit}\0{tool_name}\0{rule_id}\0{path}\0{start_line}\0{:?}\0{:?}\0{:?}\0{fingerprint}\0{message}",
        start_column, end_line, end_column
    ))
}

fn result_message(result: &Value) -> Option<String> {
    result
        .get("message")
        .and_then(|message| {
            message
                .get("text")
                .or_else(|| message.get("markdown"))
                .and_then(Value::as_str)
        })
        .map(str::to_string)
}

fn category_for_result(result: &Value, properties: &Value, rule_id: &str) -> String {
    for key in ["category", "arm_category", "kind", "type"] {
        if let Some(value) = properties.get(key).and_then(Value::as_str) {
            return value.to_string();
        }
    }
    result
        .get("ruleId")
        .and_then(Value::as_str)
        .unwrap_or(rule_id)
        .to_string()
}

fn is_dark_arm_result(
    result: &Value,
    properties: &Value,
    rule_id: &str,
    message: &str,
    category: &str,
) -> bool {
    if result_is_explicitly_dead(result, properties, rule_id, category) {
        return false;
    }
    if properties
        .get("dark_arm")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return true;
    }
    let haystack = format!(
        "{} {} {}",
        rule_id,
        message,
        result
            .get("ruleId")
            .and_then(Value::as_str)
            .unwrap_or(category)
    )
    .to_ascii_lowercase();
    haystack.contains("dark-arm") || haystack.contains("dark arm")
}

fn result_is_explicitly_dead(
    result: &Value,
    properties: &Value,
    rule_id: &str,
    category: &str,
) -> bool {
    let property_is_dead = ["category", "arm_category", "kind", "type", "status", "classification"]
        .iter()
        .filter_map(|key| properties.get(key).and_then(Value::as_str))
        .any(|value| value.eq_ignore_ascii_case("dead"));
    if property_is_dead || category.eq_ignore_ascii_case("dead") {
        return true;
    }

    [
        rule_id,
        result.get("ruleId").and_then(Value::as_str).unwrap_or(""),
    ]
    .iter()
    .any(|value| {
        value
            .split(|character: char| !character.is_ascii_alphanumeric())
            .any(|segment| segment.eq_ignore_ascii_case("dead"))
    })
}

fn partial_fingerprint(result: &Value) -> Option<String> {
    let fingerprints = result.get("partialFingerprints")?.as_object()?;
    let mut parts = fingerprints
        .iter()
        .filter_map(|(key, value)| value.as_str().map(|value| format!("{key}={value}")))
        .collect::<Vec<_>>();
    parts.sort();
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

fn u32_field(value: &Value, key: &str) -> Option<u32> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|number| u32::try_from(number).ok())
}

fn normalize_artifact_uri(repo: &Path, uri: &str) -> String {
    let mut path = uri.trim().trim_start_matches("./").replace('\\', "/");
    if let Some(stripped) = path.strip_prefix("file://") {
        path = stripped.to_string();
    }
    if path.starts_with('/') {
        path = path_to_repo_string(repo, Path::new(&path));
    }
    path.trim_start_matches("./").to_string()
}

fn path_to_repo_string(repo: &Path, path: &Path) -> String {
    let full = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let root = repo.canonicalize().unwrap_or_else(|_| repo.to_path_buf());
    full.strip_prefix(&root)
        .unwrap_or(&full)
        .to_string_lossy()
        .replace('\\', "/")
}

fn sha256(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    hex::encode(digest)
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{LogicalUnit, UnitKind};
    use tempfile::tempdir;

    #[test]
    fn ingests_test_miser_findings_for_unindexed_test_files() {
        let dir = tempdir().unwrap();
        let storage = Storage::open_memory().unwrap();
        let sarif = dir.path().join("test-miser.sarif");
        fs::write(&sarif, r#"{
          "version":"2.1.0",
          "runs":[{
            "tool":{"driver":{"name":"Test Miser"}},
            "properties":{"format":"test-miser.report.sarif.v1"},
            "results":[{
              "ruleId":"test-miser.zero-kill",
              "message":{"text":"ExampleTest#test_empty kills no mutants"},
              "locations":[{"physicalLocation":{
                "artifactLocation":{"uri":"test/example_test.rb"},
                "region":{"startLine":12}
              }}],
              "properties":{"category":"weak-test","kind":"zero-kill","testName":"ExampleTest#test_empty"}
            }]
          }]
        }"#).unwrap();

        let stats = ingest_sarif_paths(
            &storage,
            dir.path(),
            &[sarif],
            "test-miser",
            "abc",
            Some(20),
            true,
        ).unwrap();
        let finding = storage.sarif_findings_for_path("test/example_test.rb").unwrap();

        assert_eq!(stats.findings, 1);
        assert_eq!(finding[0].run_format, "test-miser.report.sarif.v1");
        assert_eq!(finding[0].unit_id, None);
        assert!(finding[0].properties_json.contains("ExampleTest#test_empty"));
    }

    #[test]
    fn dead_classification_is_exact_and_does_not_match_deadline() {
        let deadline = serde_json::json!({"ruleId": "slopcop.dark-arm"});
        assert!(is_dark_arm_result(
            &deadline,
            &serde_json::json!({}),
            "slopcop.dark-arm",
            "dark arm can miss a deadline",
            "dark-arm",
        ));

        let dead = serde_json::json!({"ruleId": "slopcop.dark-arm.dead"});
        assert!(!is_dark_arm_result(
            &dead,
            &serde_json::json!({"dark_arm": true, "kind": "dead"}),
            "slopcop.dark-arm.dead",
            "dark arm",
            "dead",
        ));
    }

    #[test]
    fn ingests_sarif_findings_and_replaces_idempotently() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  else\nend\n").unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\nelse\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_event(&crate::model::Event {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                event_type: crate::model::EventType::Change,
                path: "src/demo.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 3,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();
        let sarif = dir.path().join("report.sarif");
        fs::write(
            &sarif,
            r#"{
              "version":"2.1.0",
              "runs":[{
                "tool":{"driver":{"name":"SlopCop","rules":[]}},
                "results":[{
                  "ruleId":"slopcop.dark-arm.genuine",
                  "level":"warning",
                  "message":{"text":"dark arm: genuine"},
                  "locations":[{
                    "physicalLocation":{
                      "artifactLocation":{"uri":"src/demo.rb"},
                      "region":{"startLine":2,"startColumn":3,"endLine":2,"endColumn":7}
                    }
                  }],
                  "properties":{"dark_arm":true,"category":"genuine"}
                }],
                "properties":{"format":"slopcop.report.sarif.v1"}
              }]
            }"#,
        )
        .unwrap();

        let stats = ingest_sarif_paths(
            &storage,
            dir.path(),
            std::slice::from_ref(&sarif),
            "slopcop",
            "abc",
            Some(20),
            true,
        )
        .unwrap();
        assert_eq!(stats.artifacts, 1);
        assert_eq!(stats.findings, 1);
        assert_eq!(storage.count_rows("sarif_findings").unwrap(), 1);
        assert_eq!(
            storage
                .sarif_findings_for_path("src/demo.rb")
                .unwrap()
                .first()
                .unwrap()
                .unit_id,
            Some(unit.id)
        );

        let stats = ingest_sarif_paths(&storage, dir.path(), &[sarif], "slopcop", "abc", Some(20), true)
            .unwrap();
        assert_eq!(stats.findings, 1);
        assert_eq!(storage.count_rows("sarif_findings").unwrap(), 1);
    }

    #[test]
    fn current_snapshot_and_lifecycle_ignore_stale_findings() {
        let dir = tempdir().unwrap();
        let storage = Storage::open_memory().unwrap();
        let sarif = dir.path().join("report.sarif");
        let result = |rule: &str, message: &str| {
            serde_json::json!({
                "ruleId": rule,
                "level": "warning",
                "message": {"text": message},
                "locations": [{"physicalLocation": {
                    "artifactLocation": {"uri": "src/demo.rb"},
                    "region": {"startLine": 2}
                }}],
                "partialFingerprints": {"stable": message}
            })
        };
        let document = |results: Vec<Value>| {
            serde_json::json!({
                "version": "2.1.0",
                "runs": [{
                    "tool": {"driver": {"name": "Decomplex"}},
                    "results": results,
                    "properties": {"format": "decomplex.report.sarif.v1"}
                }]
            })
        };

        fs::write(
            &sarif,
            serde_json::to_vec(&document(vec![
                result("decomplex.old", "resolved"),
                result("decomplex.same", "persisted"),
                serde_json::json!({
                    "ruleId": "decomplex.other",
                    "level": "warning",
                    "message": {"text": "other file retained"},
                    "locations": [{"physicalLocation": {
                        "artifactLocation": {"uri": "src/other.rb"},
                        "region": {"startLine": 1}
                    }}],
                    "partialFingerprints": {"stable": "other file retained"}
                }),
            ]))
            .unwrap(),
        )
        .unwrap();
        ingest_sarif_paths(
            &storage,
            dir.path(),
            std::slice::from_ref(&sarif),
            "decomplex",
            "old",
            Some(10),
            false,
        )
        .unwrap();

        fs::write(
            &sarif,
            serde_json::to_vec(&document(vec![
                result("decomplex.same", "persisted"),
                result("decomplex.new", "new"),
            ]))
            .unwrap(),
        )
        .unwrap();
        ingest_sarif_paths(
            &storage,
            dir.path(),
            &[sarif],
            "decomplex",
            "new",
            Some(20),
            false,
        )
        .unwrap();

        assert_eq!(storage.count_rows("sarif_findings").unwrap(), 5);
        let current = storage.sarif_findings_for_path("src/demo.rb").unwrap();
        assert_eq!(current.len(), 2);
        assert!(current.iter().all(|finding| finding.commit_hash == "new"));
        let retained = storage.sarif_findings_for_path("src/other.rb").unwrap();
        assert_eq!(retained.len(), 1);
        assert_eq!(retained[0].commit_hash, "old");
        assert_eq!(
            storage.sarif_finding_counts_by_file().unwrap()["src/demo.rb"],
            2
        );
        assert_eq!(
            storage.sarif_lifecycle_summary().unwrap(),
            crate::storage::SarifLifecycleSummary {
                new_findings: 2,
                resolved_findings: 1,
                persisted_findings: 1,
            }
        );
    }

    #[test]
    fn ingests_sql_cov_complexity_contract_without_sql_analysis() {
        let dir = tempdir().unwrap();
        let storage = Storage::open_memory().unwrap();
        let sarif = dir.path().join("query-plan.sarif");
        let document = serde_json::json!({
            "version": "2.1.0",
            "runs": [{
                "tool": {"driver": {"name": "SQL-COV"}},
                "properties": {"format": "sql-cov.plan.sarif.v1"},
                "results": [{
                    "ruleId": "complexity.observation",
                    "level": "note",
                    "message": {"text": "orders.list has estimated runtime O(N * M) and auxiliary space O(N)"},
                    "locations": [{"physicalLocation": {
                        "artifactLocation": {"uri": "queries/orders.sql"},
                        "region": {"startLine": 1, "startColumn": 1}
                    }}],
                    "partialFingerprints": {"queryId": "orders.list"},
                    "properties": {"category": "complexity", "complexity": {
                        "subject_kind": "query", "subject_name": "orders.list",
                        "time": "O(N * M)", "auxiliary_space": "O(N)",
                        "dynamic": true, "basis": "postgres-explain"
                    }}
                }]
            }]
        });
        fs::write(&sarif, serde_json::to_vec(&document).unwrap()).unwrap();

        let stats = ingest_sarif_paths(&storage, dir.path(), &[sarif], "sql-cov", "abc", Some(20), true).unwrap();
        assert_eq!(stats.findings, 1);
        let findings = storage.sarif_findings_for_path("queries/orders.sql").unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].tool_name, "SQL-COV");
        assert_eq!(findings[0].run_format, "sql-cov.plan.sarif.v1");
        let properties: Value = serde_json::from_str(&findings[0].properties_json).unwrap();
        assert_eq!(properties["complexity"]["time"], "O(N * M)");
        assert_eq!(properties["complexity"]["basis"], "postgres-explain");
    }

    #[test]
    fn test_sarif_ingest_edge_cases() {
        let dir = tempdir().unwrap();
        let storage = Storage::open_memory().unwrap();

        let u1 = LogicalUnit::new(
            "U1".to_string(),
            UnitKind::Function,
            "src/demo.rb".to_string(),
            1,
            5,
            10,
            "def foo".to_string(),
            "",
        );
        let u2 = LogicalUnit::new(
            "U2".to_string(),
            UnitKind::Function,
            "src/demo.rb".to_string(),
            1,
            1,
            4,
            "def bar".to_string(),
            "",
        );
        storage.upsert_logical_unit(&u1, 10).unwrap();
        storage.upsert_logical_unit(&u2, 10).unwrap();

        let sub = dir.path().join("sub");
        fs::create_dir(&sub).unwrap();

        let sarif1 = sub.join("report1.sarif");
        fs::write(&sarif1, "{}").unwrap();
        let json1 = sub.join("report2.json");
        fs::write(&json1, "{}").unwrap();
        let txt1 = sub.join("report3.txt");
        fs::write(&txt1, "{}").unwrap();

        let bad_path = dir.path().join("does_not_exist");

        let stats = ingest_sarif_paths(
            &storage,
            dir.path(),
            &[sub.clone(), bad_path],
            "test_source",
            "abc",
            None,
            false,
        ).unwrap();

        assert_eq!(stats.skipped_files, 2);

        let invalid_json = sub.join("invalid.json");
        fs::write(&invalid_json, "invalid JSON content").unwrap();
        let stats2 = ingest_sarif_paths(
            &storage,
            dir.path(),
            &[invalid_json],
            "test_source",
            "abc",
            None,
            false,
        ).unwrap();
        assert_eq!(stats2.skipped_files, 1);

        let rule_json = dir.path().join("rule_test.sarif");
        fs::write(
            &rule_json,
            r#"{
              "version":"2.1.0",
              "runs":[{
                "tool":{"driver":{"name":"SlopCop"}},
                "results":[{
                  "ruleId":"rules.test",
                  "level":"warning",
                  "message":{"text":"test message"},
                  "locations":[{
                    "physicalLocation":{
                      "artifactLocation":{"uri":"file:///app/src/demo.rb"}
                    }
                  }],
                  "properties":{"arm_category":"arm_type","dark_arm":false},
                  "partialFingerprints":{"key1":"val1"}
                }, {
                  "ruleId":"rules.dark_arm",
                  "level":"error",
                  "locations":[{
                    "physicalLocation":{
                      "artifactLocation":{"uri":"src/demo.rb"}
                    }
                  }],
                  "properties":{"kind":"safety"}
                }]
              }]
            }"#,
        ).unwrap();

        let stats3 = ingest_sarif_paths(
            &storage,
            dir.path(),
            &[rule_json],
            "test_source",
            "abc",
            None,
            false,
        ).unwrap();

        assert_eq!(stats3.artifacts, 1);
        assert_eq!(stats3.findings, 2);

        let dead_json = dir.path().join("dead_test.sarif");
        fs::write(
            &dead_json,
            r#"{
              "version":"2.1.0",
              "runs":[{
                "tool":{"driver":{"name":"SlopCop"}},
                "results":[{
                  "ruleId":"slopcop.dark-arm.dead",
                  "level":"warning",
                  "message":{"text":"dark arm: dead"},
                  "locations":[{
                    "physicalLocation":{
                      "artifactLocation":{"uri":"src/demo.rb"}
                    }
                  }],
                  "properties":{"kind":"dead"}
                }]
              }]
            }"#,
        ).unwrap();

        let stats4 = ingest_sarif_paths(
            &storage,
            dir.path(),
            &[dead_json],
            "test_source",
            "abc",
            None,
            false,
        ).unwrap();

        assert_eq!(stats4.findings, 1);
        let findings = storage.sarif_findings_for_path("src/demo.rb").unwrap();
        let dead_finding = findings.iter().find(|f| f.rule_id == "slopcop.dark-arm.dead").unwrap();
        assert!(!dead_finding.is_dark_arm);
    }
}
