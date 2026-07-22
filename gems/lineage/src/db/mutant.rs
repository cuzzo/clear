use crate::diff::EvidenceScopeFingerprint;
use crate::extract::BoundaryExtractor;
use crate::model::{BlobFile, LogicalUnit, QualityEvent, QualityMetric, TestExposureEvent};
use crate::stack_trace::LanguageNormalizer;
use crate::storage::{EvidenceArtifactScope, Storage};
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::{BTreeSet, HashMap, HashSet};

#[derive(Debug, Clone, PartialEq)]
pub struct MutantFact {
    pub file: String,
    pub method: String,
    pub source: String,
    pub language: String,
    pub mutation_kind: String,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MutantIngestOptions {
    /// Stable corpus fingerprint. Empty identifies legacy, unscoped facts.
    pub mutation_corpus: String,
    pub evidence_scope: Option<EvidenceScopeFingerprint>,
    pub complete: bool,
}

impl Default for MutantIngestOptions {
    fn default() -> Self {
        Self {
            mutation_corpus: String::new(),
            evidence_scope: None,
            complete: false,
        }
    }
}

#[allow(clippy::too_many_arguments)]
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
    ingest_mutant_facts_json_with_options(
        storage,
        normalizer,
        vcs,
        extractor,
        input,
        commit_hash,
        timestamp,
        test_type,
        &MutantIngestOptions::default(),
    )
}

#[allow(clippy::too_many_arguments)]
pub fn ingest_mutant_facts_json_with_options<P, E>(
    storage: &Storage,
    normalizer: &dyn LanguageNormalizer,
    vcs: &P,
    extractor: &E,
    input: &str,
    commit_hash: &str,
    timestamp: Option<i64>,
    test_type: &str,
    options: &MutantIngestOptions,
) -> Result<MutantIngestStats>
where
    P: VcsProvider,
    E: BoundaryExtractor,
{
    if !storage.commit_exists(commit_hash)? {
        anyhow::bail!("commit {commit_hash} is not present in lineage metadata");
    }
    if let Some(scope) = &options.evidence_scope {
        if scope.revision != commit_hash {
            anyhow::bail!("mutation evidence scope revision must match commit {commit_hash}");
        }
        if options.mutation_corpus.trim().is_empty() || options.mutation_corpus == "unknown" {
            anyhow::bail!("scoped mutation evidence requires a stable mutation corpus fingerprint");
        }
        if scope.mutant_corpus != options.mutation_corpus {
            anyhow::bail!("mutation corpus must match the evidence scope fingerprint");
        }
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
    let mut expected_lines = BTreeSet::new();
    let mut all_units_loaded = false;

    let owns_transaction = !storage.transaction_active();
    if owns_transaction {
        storage.begin_transaction()?;
    }
    let result = (|| -> Result<MutantIngestStats> {
        for fact in facts {
            let normalized_path = normalizer.normalize_path(&fact.file);
            let path = storage.resolve_current_path(&normalized_path)?;
            if let Some(path) = path.as_ref() {
                if !files.contains_key(path) {
                    files.insert(path.clone(), file_at_commit(vcs, commit_hash, path)?);
                }
                if let Some(file) = files.get(path).and_then(Option::as_ref) {
                    if !units.contains_key(path) {
                        units.insert(path.clone(), extractor.extract_units(file));
                    }
                }
            }

            let mut matched_units = path
                .as_ref()
                .and_then(|path| {
                    units
                        .get(path)
                        .map(|path_units| matching_unit_entries(path, path_units, &fact))
                })
                .unwrap_or_default();
            if matched_units.is_empty() {
                if !all_units_loaded {
                    load_supported_units(vcs, extractor, commit_hash, &mut files, &mut units)?;
                    all_units_loaded = true;
                }
                matched_units = fallback_matching_unit_entries(&units, &fact);
            }
            if matched_units.is_empty() {
                if path.is_some() {
                    stats.skipped_facts += 1;
                } else {
                    stats.skipped_files += 1;
                }
                continue;
            }
            for unit_match in matched_units {
                let path = &unit_match.path;
                let unit = &unit_match.unit;
                let Some(unit_id) = storage.resolve_unit_id(&unit.id, path, &unit.name)? else {
                    stats.skipped_facts += 1;
                    continue;
                };
                stats.units += 1;
                if let Some(kill_rate) = fact.kill_rate.filter(|_| fact.mutations.unwrap_or(0) > 0)
                {
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
                            mutation_kind: Some(fact.mutation_kind.clone()),
                            mutation_corpus: options.mutation_corpus.clone(),
                            is_mutation_verified: true,
                            is_mutation_killed: status == "killed",
                            is_verified: true,
                            payload_json: fact.payload_json.clone(),
                        })? {
                            stats.exposure_events += 1;
                        }
                        expected_lines.insert((path.clone(), line));
                    }
                }
            }
        }
        if let Some(scope) = &options.evidence_scope {
            storage.record_evidence_artifact_scope(&EvidenceArtifactScope {
                family: "mutation".into(),
                source: options.mutation_corpus.clone(),
                scope: scope.clone(),
                complete: options.complete,
                expected_lines,
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

pub fn parse_mutant_facts(input: &str) -> Result<Vec<MutantFact>> {
    let value: Value = serde_json::from_str(input).context("parse mutant facts JSON")?;
    let source = string_at(&value, &["source"])
        .unwrap_or("unknown")
        .to_string();
    let language = string_at(&value, &["language"])
        .unwrap_or("ruby")
        .to_string();
    let mutation_kind = normalized_mutation_kind(string_at(
        &value,
        &[
            "mutation_kind",
            "mutation_type",
            "mutant_kind",
            "mutant_type",
        ],
    ));
    let subjects = value
        .get("subjects")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow::anyhow!("mutant facts JSON contained no subjects"))?;
    Ok(subjects
        .iter()
        .filter_map(|subject| mutant_fact(subject, &source, &language, &mutation_kind))
        .collect())
}

fn mutant_fact(
    subject: &Value,
    default_source: &str,
    default_language: &str,
    default_mutation_kind: &str,
) -> Option<MutantFact> {
    let file = string_at(subject, &["file", "path", "filename"])?.to_string();
    let method = string_at(subject, &["method", "subject", "expression"])?.to_string();
    if file.is_empty() || method.is_empty() {
        return None;
    }
    Some(MutantFact {
        file,
        method,
        source: string_at(subject, &["source"])
            .unwrap_or(default_source)
            .to_string(),
        language: string_at(subject, &["language"])
            .unwrap_or(default_language)
            .to_string(),
        mutation_kind: normalized_mutation_kind(
            string_at(
                subject,
                &[
                    "mutation_kind",
                    "mutation_type",
                    "mutant_kind",
                    "mutant_type",
                ],
            )
            .or(Some(default_mutation_kind)),
        ),
        kill_rate: number_at(subject, &["kill_rate", "coverage"]),
        gate_status: string_at(subject, &["gate_status", "gate"]).map(str::to_string),
        mutations: u32_at(subject, &["mutations"]),
        killed: u32_at(subject, &["killed", "kills"]),
        alive: u32_at(subject, &["alive", "survived"]),
        selected_tests: u32_at(subject, &["selected_tests"]),
        payload_json: serde_json::to_string(subject).unwrap_or_else(|_| "{}".to_string()),
    })
}

#[derive(Debug, Clone)]
struct UnitMatch {
    path: String,
    unit: LogicalUnit,
}

fn matching_unit_entries(path: &str, units: &[LogicalUnit], fact: &MutantFact) -> Vec<UnitMatch> {
    matching_units(units, fact)
        .into_iter()
        .cloned()
        .map(|unit| UnitMatch {
            path: path.to_string(),
            unit,
        })
        .collect()
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
        .filter(|unit| unit_matches_aliases(unit, &aliases))
        .collect()
}

fn fallback_matching_unit_entries(
    units_by_path: &HashMap<String, Vec<LogicalUnit>>,
    fact: &MutantFact,
) -> Vec<UnitMatch> {
    let Some(owner) = method_owner(&fact.method) else {
        return Vec::new();
    };
    let owner_aliases = owner_aliases(&owner);
    let mut matched = Vec::new();
    let mut seen = HashSet::<String>::new();
    for (path, units) in units_by_path {
        if !units.iter().any(|unit| {
            matches!(unit.kind.as_str(), "class" | "module")
                && owner_aliases
                    .iter()
                    .any(|alias| owner_alias_matches(alias, &unit.name))
        }) {
            continue;
        }

        let path_matches = if wildcard_method(&fact.method) {
            units
                .iter()
                .filter(|unit| unit.kind.as_str() == "function")
                .collect::<Vec<_>>()
        } else {
            let aliases = method_aliases(&fact.method);
            units
                .iter()
                .filter(|unit| unit_matches_aliases(unit, &aliases))
                .collect::<Vec<_>>()
        };
        for unit in path_matches {
            if seen.insert(unit.id.clone()) {
                matched.push(UnitMatch {
                    path: path.clone(),
                    unit: unit.clone(),
                });
            }
        }
    }
    if matched.is_empty() && !wildcard_method(&fact.method) {
        matched = fallback_owner_mentioned_function_entries(units_by_path, fact, &owner);
    }
    if matched.is_empty() && !wildcard_method(&fact.method) {
        matched = fallback_unique_source_function_entry(units_by_path, fact);
    }
    matched
}

fn fallback_owner_mentioned_function_entries(
    units_by_path: &HashMap<String, Vec<LogicalUnit>>,
    fact: &MutantFact,
    owner: &str,
) -> Vec<UnitMatch> {
    let aliases = method_aliases(&fact.method);
    let owner_needles = owner_text_needles(owner);
    let mut matched = Vec::new();
    let mut seen = HashSet::<String>::new();
    for (path, units) in units_by_path {
        if !(path.starts_with("src/") || path.starts_with("tools/")) {
            continue;
        }
        for unit in units {
            if unit.kind.as_str() != "function" || !unit_matches_aliases(unit, &aliases) {
                continue;
            }
            if !owner_needles.iter().any(|needle| {
                unit.signature.contains(needle) || unit.normalized_source.contains(needle)
            }) {
                continue;
            }
            if seen.insert(unit.id.clone()) {
                matched.push(UnitMatch {
                    path: path.clone(),
                    unit: unit.clone(),
                });
            }
        }
    }
    matched
}

fn fallback_unique_source_function_entry(
    units_by_path: &HashMap<String, Vec<LogicalUnit>>,
    fact: &MutantFact,
) -> Vec<UnitMatch> {
    let aliases = method_aliases(&fact.method);
    let mut candidates = Vec::new();
    for (path, units) in units_by_path {
        if !(path.starts_with("src/") || path.starts_with("tools/")) {
            continue;
        }
        for unit in units {
            if unit.kind.as_str() == "function" && unit_matches_aliases(unit, &aliases) {
                candidates.push(UnitMatch {
                    path: path.clone(),
                    unit: unit.clone(),
                });
            }
        }
    }
    if candidates.len() == 1 {
        candidates
    } else {
        Vec::new()
    }
}

fn wildcard_method(method: &str) -> bool {
    method.trim_end().ends_with('*')
}

fn method_owner(method: &str) -> Option<String> {
    let raw = method.trim().trim_end_matches('*');
    for separator in ["#", "."] {
        if let Some((owner, _name)) = raw.rsplit_once(separator) {
            if !owner.trim().is_empty() {
                return Some(owner.trim().to_string());
            }
        }
    }
    raw.split("::")
        .next()
        .filter(|owner| !owner.trim().is_empty())
        .map(|owner| owner.trim().to_string())
}

fn owner_aliases(owner: &str) -> Vec<String> {
    let mut aliases = vec![owner.to_string()];
    if let Some(name) = owner.rsplit("::").next() {
        aliases.push(name.to_string());
    }
    aliases.sort();
    aliases.dedup();
    aliases
}

fn owner_alias_matches(owner_alias: &str, unit_name: &str) -> bool {
    unit_name == owner_alias
        || (unit_name.starts_with(owner_alias)
            && unit_name
                .get(owner_alias.len()..)
                .and_then(|suffix| suffix.chars().next())
                .map(|ch| ch.is_ascii_uppercase())
                .unwrap_or(false))
}

fn owner_text_needles(owner: &str) -> Vec<String> {
    let mut needles = vec![owner.to_string()];
    if let Some(name) = owner.rsplit("::").next() {
        needles.push(name.to_string());
    }
    needles.sort();
    needles.dedup();
    needles.retain(|value| !value.is_empty());
    needles
}

fn unit_matches_aliases(unit: &LogicalUnit, aliases: &[String]) -> bool {
    aliases.iter().any(|alias| {
        unit.name == *alias
            || (!alias.contains('.')
                && !alias.contains('#')
                && unit.name.ends_with(&format!(".{alias}")))
    })
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
        let gate = fact.gate_status.as_deref().unwrap_or_default().trim();
        let verified_gate = matches!(
            gate.to_ascii_lowercase().as_str(),
            "hard" | "hard-gated" | "advisory" | "verified"
        );
        let complete = fact.kill_rate.unwrap_or(100.0) >= 100.0
            && fact.killed.unwrap_or(0) == 0
            && fact.alive.unwrap_or(0) == 0;
        return (verified_gate && complete).then_some("verified");
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
    format!(
        "mutant:{}:{}:{}",
        test_id_component(&fact.language),
        test_id_component(&fact.source),
        test_id_component(&fact.method)
    )
}

fn normalize_test_type(test_type: &str) -> String {
    let normalized = test_type.trim();
    if normalized.is_empty() {
        "unit".to_string()
    } else {
        normalized.to_string()
    }
}

fn normalized_mutation_kind(kind: Option<&str>) -> String {
    match kind
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "contract" | "contracts" | "invariant" | "invariants" | "property" | "properties"
        | "property-based" | "fuzz" | "fuzzer" | "fuzzing" => "invariant".to_string(),
        "stochastic" | "random" | "mutation" | "mutant" | "ruby-mutant" | "ruby_mutant"
        | "cargo-mutant" | "cargo-mutants" | "cargo_mutant" | "cargo_mutants" => {
            "stochastic".to_string()
        }
        "" => "stochastic".to_string(),
        other => other.to_string(),
    }
}

fn test_id_component(value: &str) -> String {
    let mut out = value
        .chars()
        .map(|ch| if ch.is_whitespace() { '_' } else { ch })
        .collect::<String>();
    out.retain(|ch| ch != ':');
    if out.is_empty() {
        "unknown".to_string()
    } else {
        out
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

fn load_supported_units<P, E>(
    vcs: &P,
    extractor: &E,
    commit_hash: &str,
    files: &mut HashMap<String, Option<BlobFile>>,
    units: &mut HashMap<String, Vec<LogicalUnit>>,
) -> Result<()>
where
    P: VcsProvider,
    E: BoundaryExtractor,
{
    for file in vcs.files_at_commit(commit_hash, &|candidate| extractor.supports_path(candidate))? {
        let path = file.path.clone();
        units
            .entry(path.clone())
            .or_insert_with(|| extractor.extract_units(&file));
        files.entry(path).or_insert(Some(file));
    }
    Ok(())
}

fn string_at<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn number_at(value: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|key| {
        value.get(*key).and_then(|raw| {
            raw.as_f64().or_else(|| {
                raw.as_str()
                    .and_then(|text| text.trim_end_matches('%').parse::<f64>().ok())
            })
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
            "source": "gems/lineage/tools/mutant-converters/ruby_mutant.rb",
            "language": "ruby",
            "mutation_kind": "ruby-mutant",
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
        assert_eq!(
            facts[0].source,
            "gems/lineage/tools/mutant-converters/ruby_mutant.rb"
        );
        assert_eq!(facts[0].language, "ruby");
        assert_eq!(facts[0].mutation_kind, "stochastic");
        assert_eq!(facts[0].kill_rate, Some(95.5));
        assert_eq!(mutation_status(&facts[0]), Some("killed"));
    }

    #[test]
    fn parses_zig_mutant_facts_with_invariant_metadata() {
        let payload = json!({
            "schema": "mutant-facts/v1",
            "source": "gems/zig-mutants",
            "language": "zig",
            "mutation_kind": "invariant",
            "subjects": [{
                "file": "zig/runtime/fsm.zig",
                "method": "poll",
                "kill_rate": 100.0,
                "mutations": 2,
                "killed": 2,
                "alive": 0
            }]
        });

        let facts = parse_mutant_facts(&payload.to_string()).unwrap();

        assert_eq!(facts.len(), 1);
        assert_eq!(facts[0].language, "zig");
        assert_eq!(facts[0].source, "gems/zig-mutants");
        assert_eq!(facts[0].mutation_kind, "invariant");
        assert_eq!(
            mutant_test_id(&facts[0]),
            "mutant:zig:gems/zig-mutants:poll"
        );
    }

    #[test]
    fn zero_mutation_hard_gates_are_mutant_verified_without_kills() {
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/demo.rb",
                "method": "Worker#run",
                "kill_rate": 100.0,
                "gate_status": "hard",
                "mutations": 0,
                "killed": 0,
                "alive": 0
            }]
        });

        let facts = parse_mutant_facts(&payload.to_string()).unwrap();

        assert_eq!(mutation_status(&facts[0]), Some("verified"));
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

        let scope = EvidenceScopeFingerprint {
            revision: "abc".into(),
            selection: "production".into(),
            mutant_corpus: "mutants-v1".into(),
            test_set: "suite-v1".into(),
        };
        let stats = ingest_mutant_facts_json_with_options(
            &storage,
            &RepoPathNormalizer::new("."),
            &provider,
            &extractor,
            &payload.to_string(),
            "abc",
            None,
            "unit",
            &MutantIngestOptions {
                mutation_corpus: "mutants-v1".into(),
                evidence_scope: Some(scope.clone()),
                complete: true,
            },
        )
        .unwrap();

        assert_eq!(stats.facts, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.quality_events, 1);
        assert_eq!(stats.exposure_events, 3);
        let killed: i64 = storage
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM test_exposure_events WHERE is_mutation_killed = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(killed, 3);
        let artifact = storage
            .scoped_mutation_artifact(&scope, &["src/demo.rb".into()])
            .unwrap()
            .unwrap();
        assert!(artifact.complete);
        assert_eq!(artifact.observations.len(), 3);
    }

    #[test]
    fn rejects_scoped_mutants_without_a_matching_immutable_corpus_scope() {
        let storage = Storage::open_memory().unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider { files: Vec::new() };
        let scope = EvidenceScopeFingerprint {
            revision: "different".into(),
            selection: "production".into(),
            mutant_corpus: "mutants-v1".into(),
            test_set: "suite-v1".into(),
        };

        let error = ingest_mutant_facts_json_with_options(
            &storage,
            &RepoPathNormalizer::new("."),
            &provider,
            &HeuristicExtractor::default(),
            "{\"subjects\":[]}",
            "abc",
            None,
            "unit",
            &MutantIngestOptions {
                mutation_corpus: "mutants-v1".into(),
                evidence_scope: Some(scope),
                complete: true,
            },
        )
        .unwrap_err();

        assert!(error
            .to_string()
            .contains("scope revision must match commit"));
    }

    #[test]
    fn ingests_zig_mutant_facts_as_invariant_exposure() {
        let storage = Storage::open_memory().unwrap();
        let file = BlobFile {
            path: "zig/runtime/demo.zig".into(),
            contents: "pub fn poll() bool {\n    return true;\n}\n".into(),
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
            "source": "gems/zig-mutants",
            "language": "zig",
            "mutation_kind": "invariant",
            "subjects": [{
                "file": "zig/runtime/demo.zig",
                "method": "poll",
                "kill_rate": 100.0,
                "mutations": 1,
                "killed": 1,
                "alive": 0
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
            "zig-mutants",
        )
        .unwrap();

        assert_eq!(stats.facts, 1);
        assert_eq!(stats.units, 1);
        assert_eq!(stats.quality_events, 1);
        assert_eq!(stats.exposure_events, 3);
        let row: (String, String) = storage
            .connection()
            .query_row(
                "SELECT test_id, mutation_kind FROM test_exposure_events WHERE is_mutation_killed = 1 LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(row.0, "mutant:zig:gems/zig-mutants:poll");
        assert_eq!(row.1, "invariant");
    }

    #[test]
    fn falls_back_to_owner_file_when_mutant_fact_reports_loader_file() {
        let storage = Storage::open_memory().unwrap();
        let loader = BlobFile {
            path: "src/loader.rb".into(),
            contents: "require_relative 'worker'\n".into(),
        };
        let worker = BlobFile {
            path: "src/worker.rb".into(),
            contents: "class Worker\n  def run\n    1\n  end\nend\n".into(),
        };
        let extractor = HeuristicExtractor::default();
        for unit in extractor.extract_units(&worker) {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider {
            files: vec![loader, worker],
        };
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/loader.rb",
                "method": "Worker#run",
                "kill_rate": 100.0,
                "gate_status": "hard",
                "mutations": 2,
                "killed": 2,
                "alive": 0,
                "selected_tests": 1
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
        assert_eq!(stats.skipped_files, 0);
        assert_eq!(stats.skipped_facts, 0);
        let path: String = storage
            .connection()
            .query_row(
                "SELECT path FROM test_exposure_events WHERE mutation_status = 'killed' LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(path, "src/worker.rb");
    }

    #[test]
    fn fallback_matches_owner_prefixed_mixin_modules() {
        let storage = Storage::open_memory().unwrap();
        let loader = BlobFile {
            path: "src/loader.rb".into(),
            contents: "require_relative 'worker_helpers'\n".into(),
        };
        let worker = BlobFile {
            path: "src/worker_helpers.rb".into(),
            contents: "module WorkerHelpers\n  def run\n    1\n  end\nend\n".into(),
        };
        let extractor = HeuristicExtractor::default();
        for unit in extractor.extract_units(&worker) {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider {
            files: vec![loader, worker],
        };
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/loader.rb",
                "method": "Worker#run",
                "kill_rate": 100.0,
                "gate_status": "hard",
                "mutations": 2,
                "killed": 2,
                "alive": 0,
                "selected_tests": 1
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

        assert_eq!(stats.units, 1);
        assert_eq!(stats.skipped_facts, 0);
    }

    #[test]
    fn fallback_matches_mixin_methods_that_bind_to_owner() {
        let storage = Storage::open_memory().unwrap();
        let loader = BlobFile {
            path: "src/loader.rb".into(),
            contents: "require_relative 'worker_mixin'\n".into(),
        };
        let worker = BlobFile {
            path: "src/worker_mixin.rb".into(),
            contents:
                "module HelperMixin\n  def run\n    T.bind(self, Worker) rescue nil\n    1\n  end\nend\n"
                    .into(),
        };
        let extractor = HeuristicExtractor::default();
        for unit in extractor.extract_units(&worker) {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider {
            files: vec![loader, worker],
        };
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/loader.rb",
                "method": "Worker#run",
                "kill_rate": 100.0,
                "gate_status": "hard",
                "mutations": 2,
                "killed": 2,
                "alive": 0,
                "selected_tests": 1
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

        assert_eq!(stats.units, 1);
        assert_eq!(stats.skipped_facts, 0);
    }

    #[test]
    fn fallback_matches_unique_source_function_without_owner_marker() {
        let storage = Storage::open_memory().unwrap();
        let loader = BlobFile {
            path: "src/loader.rb".into(),
            contents: "require_relative 'worker_mixin'\n".into(),
        };
        let worker = BlobFile {
            path: "src/worker_mixin.rb".into(),
            contents: "module HelperMixin\n  def run\n    1\n  end\nend\n".into(),
        };
        let extractor = HeuristicExtractor::default();
        for unit in extractor.extract_units(&worker) {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let provider = MemoryProvider {
            files: vec![loader, worker],
        };
        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/loader.rb",
                "method": "Worker#run",
                "kill_rate": 100.0,
                "gate_status": "hard",
                "mutations": 2,
                "killed": 2,
                "alive": 0,
                "selected_tests": 1
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

        assert_eq!(stats.units, 1);
        assert_eq!(stats.skipped_facts, 0);
    }

    #[test]
    fn test_mutant_ingest_edge_cases() {
        let storage = Storage::open_memory().unwrap();
        let extractor = HeuristicExtractor::default();
        let normalizer = RepoPathNormalizer::new(".");

        let provider = MemoryProvider {
            files: vec![BlobFile {
                path: "src/loader.rb".to_string(),
                contents: "class Loader\n  def run\n  end\nend".to_string(),
            }],
        };

        let err = ingest_mutant_facts_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            "{}",
            "nonexistent_commit",
            None,
            "unit",
        );
        assert!(err.is_err());

        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        let loader_file = BlobFile {
            path: "src/loader.rb".to_string(),
            contents: "class Loader\n  def run\n  end\nend".to_string(),
        };
        let units = extractor.extract_units(&loader_file);
        for unit in units {
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }

        let payload = json!({
            "schema": "mutant-facts/v1",
            "subjects": [{
                "file": "src/loader.rb",
                "method": "Loader#*",
                "kill_rate": 0.0,
                "mutations": 1,
                "killed": 0,
                "alive": 1,
            }, {
                "file": "src/loader.rb",
                "method": "Loader#run",
                "kill_rate": 0.0,
                "mutations": 1,
                "killed": 0,
                "alive": 0,
            }, {
                "file": "src/loader.rb",
                "method": "run",
                "kill_rate": 0.0,
                "mutations": 0,
                "gate_status": "none",
            }]
        });

        let stats = ingest_mutant_facts_json(
            &storage,
            &normalizer,
            &provider,
            &extractor,
            &payload.to_string(),
            "abc",
            None,
            "unit",
        )
        .unwrap();

        assert_eq!(stats.facts, 3);
        assert_eq!(stats.units, 3);
    }
}
