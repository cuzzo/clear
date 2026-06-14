use crate::extract::BoundaryExtractor;
use crate::model::{BlobFile, LogicalUnit, QualityEvent, QualityMetric, TestExposureEvent};
use crate::stack_trace::LanguageNormalizer;
use crate::storage::Storage;
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct MutantFact {
    pub file: String,
    pub method: String,
    pub kill_rate: Option<f64>,
    pub gate_status: Option<String>,
    pub mutations: Option<u32>,
    pub killed: Option<u32>,
    pub alive: Option<u32>,
    pub selected_tests: Option<u32>,
    pub payload_json: String,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct MutantIngestStats {
    pub facts: usize,
    pub units: usize,
    pub quality_events: usize,
    pub exposure_events: usize,
    pub skipped_files: usize,
    pub skipped_facts: usize,
}

pub fn ingest_mutant_facts_json<P, E>(
    storage: &Storage,
    normalizer: &dyn LanguageNormalizer,
    vcs: &P,
    extractor: &E,
    input: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
    test_type: &str,
) -> Result<MutantIngestStats>
where
    P: VcsProvider,
    E: BoundaryExtractor,
{
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in lineage metadata");
    }

    let facts = parse_mutant_facts(input)?;
    let timestamp = timestamp
        .or(storage.commit_timestamp(commit_hash)?)
        .unwrap_or_default();
    let test_type = normalize_test_type(test_type);
    let mut stats = MutantIngestStats {
        facts: facts.len(),
        ..MutantIngestStats::default()
    };
    let mut files = HashMap::<String, Option<BlobFile>>::new();
    let mut units = HashMap::<String, Vec<LogicalUnit>>::new();

    storage.begin_transaction()?;
    let result = (|| -> Result<MutantIngestStats> {
        for fact in facts {
            let normalized_path = normalizer.normalize_path(&fact.file);
            let Some(path) = storage.resolve_current_path(&normalized_path)? else {
                stats.skipped_files += 1;
                continue;
            };
            if !files.contains_key(&path) {
                files.insert(path.clone(), file_at_commit(vcs, commit_hash, &path)?);
            }
            let Some(file) = files.get(&path).and_then(Option::as_ref) else {
                stats.skipped_files += 1;
                continue;
            };
            if !units.contains_key(&path) {
                units.insert(path.clone(), extractor.extract_units(file));
            }
            let matched_units = matching_units(units.get(&path).map(Vec::as_slice).unwrap_or(&[]), &fact);
            if matched_units.is_empty() {
                stats.skipped_facts += 1;
                continue;
            }
            for unit in matched_units {
                let Some(unit_id) = storage.resolve_unit_id(&unit.id, &path, &unit.name)? else {
                    stats.skipped_facts += 1;
                    continue;
                };
                stats.units += 1;
                if let Some(kill_rate) = fact.kill_rate.filter(|_| fact.mutations.unwrap_or(0) > 0) {
                    if storage.record_quality_metric(&QualityEvent {
                        unit_id: unit_id.clone(),
                        commit_hash: commit_hash.to_string(),
                        timestamp,
                        metric_type: QualityMetric::MutantCoverage,
                        old_value: None,
                        new_value: kill_rate,
                    })? {
                        stats.quality_events += 1;
                    }
                }
                if let Some(status) = mutation_status(&fact) {
                    for line in unit.start_line..=unit.end_line {
                        if storage.insert_test_exposure_event(&TestExposureEvent {
                            unit_id: unit_id.clone(),
                            commit_hash: commit_hash.to_string(),
                            timestamp,
                            path: path.clone(),
                            function: Some(unit.name.clone()),
                            line: Some(line),
                            branch_id: None,
                            test_id: mutant_test_id(&fact),
                            test_type: test_type.clone(),
                            mutation_status: Some(status.to_string()),
                            is_mutation_verified: true,
                            is_mutation_killed: status == "killed",
                            is_verified: true,
                            payload_json: fact.payload_json.clone(),
                        })? {
                            stats.exposure_events += 1;
                        }
                    }
                }
            }
        }
        Ok(stats)
    })();

    match result {
        Ok(stats) => {
            storage.commit_transaction()?;
            Ok(stats)
        }
        Err(error) => {
            let _ = storage.rollback_transaction();
            Err(error)
        }
    }
}

pub fn parse_mutant_facts(input: &str) -> Result<Vec<MutantFact>> {
    let value: Value = serde_json::from_str(input).context("parse mutant facts JSON")?;
    let subjects = value
        .get("subjects")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("mutant facts JSON contained no subjects"))?;
    Ok(subjects.iter().filter_map(mutant_fact).collect())
}

fn mutant_fact(subject: &Value) -> Option<MutantFact> {
    let file = string_at(subject, &["file", "path", "filename"])?.to_string();
    let method = string_at(subject, &["method", "subject", "expression"])?.to_string();
    if file.is_empty() || method.is_empty() {
        return None;
    }
    Some(MutantFact {
        file,
        method,
        kill_rate: number_at(subject, &["kill_rate", "coverage"]),
        gate_status: string_at(subject, &["gate_status", "gate"]).map(str::to_string),
        mutations: u32_at(subject, &["mutations"]),
        killed: u32_at(subject, &["killed", "kills"]),
        alive: u32_at(subject, &["alive", "survived"]),
        selected_tests: u32_at(subject, &["selected_tests"]),
        payload_json: serde_json::to_string(subject).unwrap_or_else(|_| "{}".to_string()),
    })
}

fn matching_units<'a>(units: &'a [LogicalUnit], fact: &MutantFact) -> Vec<&'a LogicalUnit> {
    if wildcard_method(&fact.method) {
        return units
            .iter()
            .filter(|unit| unit.kind.as_str() == "function")
            .collect();
    }

    let aliases = method_aliases(&fact.method);
    units
        .iter()
        .filter(|unit| aliases.iter().any(|alias| alias == &unit.name))
        .collect()
}

fn wildcard_method(method: &str) -> bool {
    method.trim_end().ends_with('*')
}

fn method_aliases(method: &str) -> Vec<String> {
    let raw = method.trim().trim_end_matches('*');
    let mut aliases = vec![raw.to_string()];
    for separator in ["#", ".", "::"] {
        if let Some(name) = raw.rsplit(separator).next() {
            aliases.push(name.to_string());
            aliases.push(format!("self.{name}"));
        }
    }
    aliases.sort();
    aliases.dedup();
    aliases.retain(|value| !value.is_empty());
    aliases
}

fn mutation_status(fact: &MutantFact) -> Option<&'static str> {
    let mutations = fact.mutations.unwrap_or(0);
    if mutations == 0 {
        return None;
    }
    if fact.killed.unwrap_or(0) > 0 {
        Some("killed")
    } else if fact.alive.unwrap_or(0) > 0 {
        Some("survived")
    } else {
        Some("verified")
    }
}

fn mutant_test_id(fact: &MutantFact) -> String {
    format!("mutant:ruby:{}", fact.method.replace(char::is_whitespace, ""))
}

fn normalize_test_type(test_type: &str) -> String {
    let normalized = test_type.trim();
    if normalized.is_empty() {
        "unit".to_string()
    } else {
        normalized.to_string()
    }
}

fn file_at_commit<P: VcsProvider>(
    vcs: &P,
    commit_hash: &str,
    path: &str,
) -> Result<Option<BlobFile>> {
    let target = path.to_string();
    let files = vcs.files_at_commit(commit_hash, &|candidate| candidate == target)?;
    Ok(files.into_iter().next())
}

fn string_at<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn number_at(value: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| {
        value.get(*key).and_then(|raw| {
            raw.as_f64().or_else(|| raw.as_str().and_then(|text| {
                text.trim_end_matches('%').parse::<f64>().ok()
            }))
        })
    })
}

fn u32_at(value: &Value, keys: &[&str]) -> Option<u32> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_u64))
        .and_then(|value| u32::try_from(value).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extract::HeuristicExtractor;
    use crate::model::{BlobFile, CommitMetadata};
    use crate::stack_trace::RepoPathNormalizer;
    use crate::storage::Storage;
    use serde_json::json;

    struct MemoryProvider {
        files: Vec<BlobFile>,
    }

    impl VcsProvider for MemoryProvider {
        fn list_commits(&self) -> Result<Vec<CommitMetadata>> {
            Ok(vec![CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            }])
        }

        fn files_at_commit(
            &self,
            commit_hash: &str,
            path_filter: &dyn Fn(&str) -> bool,
        ) -> Result<Vec<BlobFile>> {
            if commit_hash != "abc" {
                return Ok(Vec::new());
            }
            Ok(self
                .files
                .iter()
                .filter(|file| path_filter(&file.path))
                .cloned()
                .collect())
        }
    }

    #[test]
    fn parses_mutant_facts() {
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/demo.rb",
                "method": "Worker#run",
                "kill_rate": 95.5,
                "mutations": 10,
                "killed": 9,
                "alive": 1
            }]
        });

        let facts = parse_mutant_facts(&payload.to_string()).unwrap();

        assert_eq!(facts.len(), 1);
        assert_eq!(facts[0].file, "src/demo.rb");
        assert_eq!(facts[0].method, "Worker#run");
        assert_eq!(facts[0].kill_rate, Some(95.5));
        assert_eq!(mutation_status(&facts[0]), Some("killed"));
    }

    #[test]
    fn ingests_mutant_facts_as_quality_and_line_exposure() {
        let storage = Storage::open_memory().unwrap();
        let file = BlobFile {
            path: "src/demo.rb".into(),
            contents: "class Worker\n  def run\n    1\n  end\nend\n".into(),
        };
        let extractor = HeuristicExtractor::default();
        for unit in extractor.extract_units(&file) {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider { files: vec![file] };
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/demo.rb",
                "method": "Worker#run",
                "kill_rate": 90.0,
                "gate_status": "hard",
                "mutations": 10,
                "killed": 10,
                "alive": 0,
                "selected_tests": 3
            }]
        });

        let stats = ingest_mutant_facts_json(
            &storage,
            &RepoPathNormalizer::new("."),
            &provider,
            &extractor,
            &payload.to_string(),
            "abc",
            None,
            "unit",
        )
        .unwrap();

        assert_eq!(stats.facts, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.quality_events, 1);
        assert_eq!(stats.exposure_events, 4);
        let killed: i64 = storage
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM test_exposure_events WHERE is_mutation_killed = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(killed, 4);
    }
}
