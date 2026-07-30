//! Language-neutral ingestion of complexity summaries keyed by compiler symbol.
//!
//! A producer may analyze excluded/generated source or dependency source once,
//! then publish exact-symbol summaries. Consumers join only on the compiler
//! identity already attached to a call; no owner/name reconstruction occurs.

use crate::profile::{summarize_call_resolution, ProfileOutput};
use anyhow::{bail, Context, Result};
use flate2::read::GzDecoder;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::Path;

const SCHEMA_V1: &str = "fact-mine.external-complexity-summary.v1";
const SCHEMA_V2: &str = "fact-mine.external-complexity-summary.v2";
const SCHEMA_V3: &str = "fact-mine.external-complexity-summary.v3";
const ENVIRONMENT_SCHEMA_V1: &str = "fact-mine.semantic-environment.v1";
include!(concat!(env!("OUT_DIR"), "/bundled_complexity_summaries.rs"));

#[derive(Debug, Deserialize)]
struct SummaryFile {
    schema: String,
    #[serde(default)]
    producer: Option<SummaryProducer>,
    #[serde(default)]
    source: Option<SummarySource>,
    #[serde(default)]
    compatibility: Option<SummaryCompatibility>,
    #[serde(default)]
    symbols: BTreeMap<String, ComplexitySummary>,
}

#[derive(Debug, Deserialize)]
struct SummaryCompatibility {
    #[serde(default)]
    claims: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct SemanticEnvironmentFile {
    schema: String,
    #[serde(default)]
    claims: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct SummaryProducer {
    name: String,
    version: String,
}

#[derive(Debug, Deserialize)]
struct SummarySource {
    profile_sha256: String,
    method_count: usize,
    complete_symbol_count: usize,
    #[serde(default)]
    indexer: Option<String>,
    #[serde(default)]
    consumer_indexers: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct ComplexitySummary {
    time: String,
    space: String,
    #[serde(default = "default_provenance")]
    provenance: String,
    #[serde(default = "default_bound_quality")]
    bound_quality: String,
    #[serde(default)]
    candidates: Vec<String>,
    #[serde(default)]
    assumptions: Vec<String>,
}

fn default_provenance() -> String {
    "external_complexity_summary".to_string()
}

fn default_bound_quality() -> String {
    "upper_bound_exact_symbol".to_string()
}

pub fn apply_file(output: &mut ProfileOutput, path: &Path) -> Result<usize> {
    let summary = read_file(path)?;
    require_compatible(output, &summary)
        .with_context(|| format!("incompatible complexity summary {}", path.display()))?;
    apply_summary(output, &summary)
}

pub fn apply_files(output: &mut ProfileOutput, paths: &[impl AsRef<Path>]) -> Result<usize> {
    let mut summaries = Vec::with_capacity(paths.len());
    let mut costs_by_symbol: BTreeMap<String, (String, String, String)> = BTreeMap::new();
    for path in paths {
        let path = path.as_ref();
        let summary = read_file(path)?;
        require_compatible(output, &summary)
            .with_context(|| format!("incompatible complexity summary {}", path.display()))?;
        for (symbol, cost) in &summary.symbols {
            if let Some((time, space, first_path)) = costs_by_symbol.get(symbol) {
                if time != &cost.time || space != &cost.space {
                    bail!(
                        "conflicting complexity summaries for {symbol}: {} has {time}/{space}, {} has {}/{}",
                        first_path,
                        path.display(),
                        cost.time,
                        cost.space
                    );
                }
            } else {
                costs_by_symbol.insert(
                    symbol.clone(),
                    (
                        cost.time.clone(),
                        cost.space.clone(),
                        path.display().to_string(),
                    ),
                );
            }
        }
        summaries.push(summary);
    }
    let mut applied = 0;
    for summary in &summaries {
        applied += apply_summary(output, summary)?;
    }
    Ok(applied)
}

/// Apply reviewed, version-pinned summaries shipped with FactMine. Symbols
/// include the package version, so a bundle cannot match another toolchain or
/// dependency release accidentally.
pub fn apply_bundled(output: &mut ProfileOutput) -> Result<usize> {
    let mut applied = 0;
    for (name, bytes) in BUNDLED_SUMMARIES {
        let source =
            decode(Path::new(name), bytes).with_context(|| format!("failed to decode {name}"))?;
        let summary: SummaryFile = serde_json::from_str(&source)
            .with_context(|| format!("failed to parse bundled complexity summary {name}"))?;
        validate(&summary)
            .with_context(|| format!("failed to validate bundled complexity summary {name}"))?;
        let producer_indexer = summary
            .source
            .as_ref()
            .and_then(|source| source.indexer.as_deref())
            .with_context(|| {
                format!(
                    "bundled complexity summary {name} must declare its exact compatible indexer"
                )
            })?;
        let source = summary.source.as_ref().expect("validated summary source");
        if !has_compatible_indexer(output, source, producer_indexer) {
            continue;
        }
        if !is_compatible(output, &summary) {
            continue;
        }
        applied += apply_summary(output, &summary)?;
    }
    Ok(applied)
}

fn has_compatible_indexer(
    output: &ProfileOutput,
    source: &SummarySource,
    producer_indexer: &str,
) -> bool {
    output.semantic_indexes.iter().any(|index| {
        let identity = format!("{}@{}", index.tool, index.version);
        if source.consumer_indexers.is_empty() {
            identity == producer_indexer
        } else {
            source
                .consumer_indexers
                .iter()
                .any(|required| required == &identity)
        }
    })
}

fn read_file(path: &Path) -> Result<SummaryFile> {
    let bytes = fs::read(path)
        .with_context(|| format!("failed to read complexity summary {}", path.display()))?;
    let source = decode(path, &bytes)
        .with_context(|| format!("failed to decode complexity summary {}", path.display()))?;
    let summary: SummaryFile = serde_json::from_str(&source)
        .with_context(|| format!("failed to parse complexity summary {}", path.display()))?;
    validate(&summary)
        .with_context(|| format!("failed to validate complexity summary {}", path.display()))?;
    Ok(summary)
}

fn decode(path: &Path, bytes: &[u8]) -> Result<String> {
    let compressed = bytes.starts_with(&[0x1f, 0x8b])
        || path.extension().and_then(|extension| extension.to_str()) == Some("gz");
    let mut decoded = Vec::new();
    if compressed {
        GzDecoder::new(bytes).read_to_end(&mut decoded)?;
    } else {
        decoded.extend_from_slice(bytes);
    }
    String::from_utf8(decoded).context("complexity summary is not UTF-8 JSON")
}

pub fn apply_json(output: &mut ProfileOutput, source: &str) -> Result<usize> {
    let summary: SummaryFile = serde_json::from_str(source)?;
    validate(&summary)?;
    require_compatible(output, &summary)?;
    apply_summary(output, &summary)
}

/// Attach semantic-environment sidecars to a profile. Claims are opaque to the
/// shared analyzer and merge only when identical.
pub fn apply_environment_files(
    output: &mut ProfileOutput,
    paths: &[impl AsRef<Path>],
) -> Result<usize> {
    let mut applied = 0;
    for path in paths {
        let path = path.as_ref();
        let bytes = fs::read(path)
            .with_context(|| format!("failed to read semantic environment {}", path.display()))?;
        let source = decode(path, &bytes)
            .with_context(|| format!("failed to decode semantic environment {}", path.display()))?;
        let environment: SemanticEnvironmentFile = serde_json::from_str(&source)
            .with_context(|| format!("failed to parse semantic environment {}", path.display()))?;
        validate_environment(&environment)
            .with_context(|| format!("invalid semantic environment {}", path.display()))?;
        for (key, value) in environment.claims {
            if let Some(existing) = output.semantic_environment.get(&key) {
                if existing != &value {
                    bail!(
                        "conflicting semantic environment claim {key}: {existing:?} versus {value:?} from {}",
                        path.display()
                    );
                }
                continue;
            }
            output.semantic_environment.insert(key, value);
            applied += 1;
        }
    }
    Ok(applied)
}

fn validate_environment(environment: &SemanticEnvironmentFile) -> Result<()> {
    if environment.schema != ENVIRONMENT_SCHEMA_V1 {
        bail!(
            "unsupported semantic environment schema {}; expected {ENVIRONMENT_SCHEMA_V1}",
            environment.schema
        );
    }
    if environment.claims.is_empty() {
        bail!("semantic environment must contain at least one claim");
    }
    for (key, value) in &environment.claims {
        if key.trim().is_empty() || value.trim().is_empty() {
            bail!("semantic environment claim keys and values must be non-empty");
        }
    }
    Ok(())
}

fn is_compatible(output: &ProfileOutput, summary: &SummaryFile) -> bool {
    summary
        .compatibility
        .as_ref()
        .map(|compatibility| {
            compatibility
                .claims
                .iter()
                .all(|(key, value)| output.semantic_environment.get(key) == Some(value))
        })
        .unwrap_or(true)
}

fn require_compatible(output: &ProfileOutput, summary: &SummaryFile) -> Result<()> {
    let Some(compatibility) = summary.compatibility.as_ref() else {
        return Ok(());
    };
    let mismatches = compatibility
        .claims
        .iter()
        .filter_map(|(key, required)| {
            let actual = output.semantic_environment.get(key);
            (actual != Some(required)).then(|| {
                format!(
                    "{key} requires {required:?}, profile has {}",
                    actual.map_or("<missing>".to_string(), |value| format!("{value:?}"))
                )
            })
        })
        .collect::<Vec<_>>();
    if !mismatches.is_empty() {
        bail!(
            "semantic environment does not satisfy summary compatibility: {}",
            mismatches.join("; ")
        );
    }
    Ok(())
}

fn apply_summary(output: &mut ProfileOutput, summary: &SummaryFile) -> Result<usize> {
    // A complete result is authoritative regardless of where it came from. Audit
    // every overlap before mutating the profile so a generated/manual
    // disagreement fails atomically instead of being hidden by application
    // order. Incomplete results are deliberately replaceable by a complete
    // generated result.
    for call in &output.calls {
        if call.target.is_some() || has_open_candidate_set(call) {
            continue;
        }
        let Some(symbol) = call.semantic_symbol.as_deref() else {
            continue;
        };
        let Some(cost) = summary.symbols.get(symbol) else {
            continue;
        };
        let (Some(existing_time), Some(existing_space)) = (
            call.known_time_complexity.as_deref(),
            call.known_space_complexity.as_deref(),
        ) else {
            continue;
        };
        if existing_time != cost.time || existing_space != cost.space {
            bail!(
                "complete complexity conflict for {symbol}: existing {} has {existing_time}/{existing_space}, generated {} has {}/{}; fix the source analysis or fallback model instead of overriding either complete result",
                call.complexity_provenance.as_deref().unwrap_or("unknown provenance"),
                cost.provenance,
                cost.time,
                cost.space
            );
        }
    }

    let mut applied = 0;
    for call in &mut output.calls {
        if call.target.is_some() || has_open_candidate_set(call) {
            continue;
        }
        let Some(symbol) = call.semantic_symbol.as_deref() else {
            continue;
        };
        let Some(cost) = summary.symbols.get(symbol) else {
            continue;
        };
        call.known_time_complexity = Some(cost.time.clone());
        call.known_space_complexity = Some(cost.space.clone());
        call.complexity_provenance = Some(cost.provenance.clone());
        call.complexity_bound_quality = Some(cost.bound_quality.clone());
        call.complexity_candidates = cost.candidates.clone();
        call.complexity_assumptions = cost.assumptions.clone();
        call.complexity_missing_kind = None;
        call.unresolved_reason = None;
        call.resolution_missing_proof = None;
        call.empty_domain_cause = None;
        applied += 1;
    }
    if applied > 0 {
        let raw_parser_call_sites = output.call_resolution_coverage.raw_parser_call_sites;
        let raw_calls_not_normalized = output.call_resolution_coverage.raw_calls_not_normalized;
        let raw_calls_not_normalized_inside_function = output
            .call_resolution_coverage
            .raw_calls_not_normalized_inside_function;
        let source_export_eligible_methods_overlapping_raw_call_loss = output
            .call_resolution_coverage
            .source_export_eligible_methods_overlapping_raw_call_loss;
        let raw_calls_not_normalized_outside_function = output
            .call_resolution_coverage
            .raw_calls_not_normalized_outside_function;
        let raw_calls_not_normalized_by_kind = output
            .call_resolution_coverage
            .raw_calls_not_normalized_by_kind
            .clone();
        let raw_call_normalization_gap_samples = output
            .call_resolution_coverage
            .raw_call_normalization_gap_samples
            .clone();
        let normalized_calls_without_raw_span = output
            .call_resolution_coverage
            .normalized_calls_without_raw_span;
        output.call_resolution_coverage =
            summarize_call_resolution(&output.owners, &output.methods, &output.calls);
        output.call_resolution_coverage.raw_parser_call_sites = raw_parser_call_sites;
        output.call_resolution_coverage.raw_calls_not_normalized = raw_calls_not_normalized;
        output
            .call_resolution_coverage
            .raw_calls_not_normalized_inside_function = raw_calls_not_normalized_inside_function;
        output
            .call_resolution_coverage
            .source_export_eligible_methods_overlapping_raw_call_loss =
            source_export_eligible_methods_overlapping_raw_call_loss;
        output
            .call_resolution_coverage
            .raw_calls_not_normalized_outside_function = raw_calls_not_normalized_outside_function;
        output
            .call_resolution_coverage
            .raw_calls_not_normalized_by_kind = raw_calls_not_normalized_by_kind;
        output
            .call_resolution_coverage
            .raw_call_normalization_gap_samples = raw_call_normalization_gap_samples;
        output
            .call_resolution_coverage
            .normalized_calls_without_raw_span = normalized_calls_without_raw_span;
        crate::scip::apply_resolved_call_costs_to_contexts(output);
    }
    Ok(applied)
}

fn has_open_candidate_set(call: &crate::profile::CallRecord) -> bool {
    !call.consumer_closed_candidate_set
        && (call.candidate_reason.is_some() || !call.candidate_targets.is_empty())
}

fn validate(summary: &SummaryFile) -> Result<()> {
    match summary.schema.as_str() {
        SCHEMA_V1 => {}
        SCHEMA_V2 | SCHEMA_V3 => {
            let producer = summary
                .producer
                .as_ref()
                .context("versioned complexity summary is missing producer metadata")?;
            if producer.name.trim().is_empty() || producer.version.trim().is_empty() {
                bail!("versioned complexity summary producer name and version must be non-empty");
            }
            let source = summary
                .source
                .as_ref()
                .context("versioned complexity summary is missing source metadata")?;
            let digest = source
                .profile_sha256
                .strip_prefix("sha256:")
                .unwrap_or_default();
            if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                bail!("versioned complexity summary source.profile_sha256 must be a SHA-256 digest");
            }
            if source.complete_symbol_count != summary.symbols.len() {
                bail!(
                    "versioned complexity summary declares {} complete symbols but contains {}",
                    source.complete_symbol_count,
                    summary.symbols.len()
                );
            }
            if source.complete_symbol_count > 0 && source.method_count == 0 {
                bail!(
                    "versioned complexity summary with exported symbols must analyze at least one method"
                );
            }
            if source
                .consumer_indexers
                .iter()
                .any(|indexer| indexer.trim().is_empty() || !indexer.contains('@'))
            {
                bail!(
                    "versioned complexity summary consumer indexers must use non-empty tool@version identities"
                );
            }
            if summary.schema == SCHEMA_V3 {
                let compatibility = summary
                    .compatibility
                    .as_ref()
                    .context("v3 complexity summary is missing compatibility metadata")?;
                for (key, value) in &compatibility.claims {
                    if key.trim().is_empty() || value.trim().is_empty() {
                        bail!("v3 compatibility claim keys and values must be non-empty");
                    }
                }
            }
        }
        other => bail!(
            "unsupported complexity summary schema {other}; expected {SCHEMA_V1}, {SCHEMA_V2}, or {SCHEMA_V3}"
        ),
    }
    for (symbol, cost) in &summary.symbols {
        if symbol.trim().is_empty() {
            bail!("complexity summary contains an empty compiler symbol");
        }
        if cost.time.trim().is_empty() || cost.space.trim().is_empty() {
            bail!("complexity summary for {symbol} must contain non-empty time and space bounds");
        }
        if cost.provenance.trim().is_empty() || cost.bound_quality.trim().is_empty() {
            bail!(
                "complexity summary for {symbol} must contain non-empty provenance and bound quality"
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::{CallRecord, ProfileOutput, SemanticIndex};
    use flate2::write::GzEncoder;
    use flate2::Compression;
    use std::io::Write;

    fn call(symbol: Option<&str>) -> CallRecord {
        CallRecord {
            id: "call:1".into(),
            source: "fn:source".into(),
            target: None,
            semantic_symbol: symbol.map(str::to_string),
            external_symbol_scope: None,
            complexity_missing_kind: None,
            target_provenance: Some("scip".into()),
            candidate_targets: Vec::new(),
            candidate_reason: None,
            consumer_closed_candidate_set: false,
            kind: "external_call".into(),
            owner: "Demo".into(),
            function: "run".into(),
            receiver: "dependency".into(),
            receiver_kind: "value".into(),
            receiver_binding_kind: "local".into(),
            symbol_namespace: None,
            lexical_symbol: None,
            lexical_symbol_origin: None,
            receiver_call_span: None,
            selector_span: None,
            execution_span: None,
            receiver_definition_call_spans: Vec::new(),
            receiver_definition_sequence_projection: None,
            receiver_symbol: None,
            receiver_type: None,
            receiver_type_origin: None,
            receiver_symbol_origin: None,
            implicit_receiver: false,
            state_receiver: false,
            callback_receiver: false,
            preprocessor_callable: false,
            dispatch_boundary: None,
            constructor_target: None,
            known_time_complexity: None,
            known_space_complexity: None,
            complexity_provenance: None,
            complexity_bound_quality: None,
            complexity_candidates: Vec::new(),
            complexity_assumptions: Vec::new(),
            message: "read".into(),
            argument_count: 0,
            arguments: Vec::new(),
            path: "Demo.java".into(),
            line: 1,
            span: [1, 0, 1, 10],
            conditional: false,
            confidence: "high".into(),
            unresolved_reason: Some("scip_external_symbol_unmodeled".into()),
            resolution_missing_proof: Some(
                "dependency_or_stdlib_symbol_known_cost_unavailable".into(),
            ),
            empty_domain_cause: Some("external_declaration".into()),
            runtime_evidence_observed: false,
        }
    }

    #[test]
    fn joins_only_exact_compiler_symbols() {
        let symbol = "scip-java maven maven/acme/demo 1 acme/Demo#read().";
        let mut output = ProfileOutput {
            calls: vec![call(Some(symbol)), call(Some("other")), call(None)],
            ..ProfileOutput::default()
        };
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {"time": "O(N)", "space": "O(1)"}
            }
        });
        assert_eq!(apply_json(&mut output, &json.to_string()).unwrap(), 1);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(N)")
        );
        assert_eq!(output.calls[0].target_provenance.as_deref(), Some("scip"));
        assert_eq!(output.calls[1].known_time_complexity, None);
        assert_eq!(output.calls[2].known_time_complexity, None);
    }

    #[test]
    fn does_not_close_an_observed_open_candidate_set() {
        let symbol = "nil-kill-runtime ruby ruby 3.2.3 String#upcase().";
        let mut observed = call(Some(symbol));
        observed.target_provenance = Some("runtime_scip_observed".into());
        observed.candidate_targets = vec!["fn:observed".into()];
        observed.candidate_reason = Some("runtime_observed_candidate_set".into());
        observed.consumer_closed_candidate_set = false;
        let mut output = ProfileOutput {
            calls: vec![observed],
            ..ProfileOutput::default()
        };
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {"time": "O(1)", "space": "O(1)"}
            }
        });

        assert_eq!(apply_json(&mut output, &json.to_string()).unwrap(), 0);
        assert_eq!(output.calls[0].known_time_complexity, None);
        assert_eq!(
            output.calls[0].unresolved_reason.as_deref(),
            Some("scip_external_symbol_unmodeled")
        );
    }

    #[test]
    fn refreshes_call_coverage_after_enrichment() {
        let symbol = "scip-java maven maven/acme/demo 1 acme/Demo#read().";
        let mut output = ProfileOutput::default();
        output.methods.push(crate::profile::MethodRecord {
            id: "fn:source".into(),
            semantic_symbol: None,
            owner_id: "owner:demo".into(),
            key: vec!["Demo".into(), "run".into(), "instance".into()],
            owner: "Demo".into(),
            symbol_owner: None,
            lexical_symbol: None,
            name: "run".into(),
            dispatch_name: "run".into(),
            kind: "instance".into(),
            path: "Demo.java".into(),
            line: 1,
            span: Some([1, 0, 1, 10]),
            language: "java".into(),
            signature: "void run()".into(),
            visibility: "public".into(),
            local_complexity: 0.0,
            complexity_signals: BTreeMap::new(),
            params: Vec::new(),
            callback_params: Vec::new(),
            source_export_eligible: true,
            generated_declaration: false,
            raw_source: "void run() {}".into(),
            normalized_source: "void run() {}".into(),
            untraceable_params: Vec::new(),
            source: serde_json::Value::Null,
        });
        output.calls = vec![call(Some(symbol))];
        output.complexity_facts.push(
            serde_json::from_value(serde_json::json!({
                "path": "Demo.java",
                "owner": "Demo",
                "function": "run",
                "line": 1,
                "span": [1, 0, 1, 10],
                "parameters": [],
                "collection_parameters": [],
                "iterations": [],
                "recursion": {
                    "calls": 0,
                    "shrinking_calls": 0,
                    "halving_calls": 0,
                    "loop_contained_shrinking_calls": 0,
                    "unknown_progress_calls": 0
                },
                "allocations": [],
                "call_contexts": [{
                    "line": 1,
                    "span": [1, 0, 1, 10],
                    "message": "read",
                    "execution_multiplicity": "O(1)",
                    "power": 0,
                    "parameter_arguments": [],
                    "argument_cardinality_relation": "same",
                    "evidence_gap": "unmodeled_typed_operation"
                }]
            }))
            .unwrap(),
        );
        output.call_resolution_coverage.unresolved_call_sites = 1;
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {"time": "O(N)", "space": "O(1)"}
            }
        });

        apply_json(&mut output, &json.to_string()).unwrap();

        assert_eq!(output.call_resolution_coverage.eligible_call_sites, 1);
        assert_eq!(
            output
                .call_resolution_coverage
                .modeled_without_project_target,
            1
        );
        assert_eq!(output.call_resolution_coverage.unresolved_call_sites, 0);
        assert_eq!(
            output.call_resolution_coverage.accounted_call_percent,
            100.0
        );
        assert_eq!(
            output.complexity_facts[0].call_contexts[0]
                .known_time_complexity
                .as_deref(),
            Some("O(N)")
        );
        assert_eq!(
            output.complexity_facts[0].call_contexts[0].evidence_gap,
            None
        );
    }

    #[test]
    fn validates_v2_provenance_envelope() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let mut output = ProfileOutput {
            calls: vec![call(Some(symbol))],
            ..ProfileOutput::default()
        };
        let valid = serde_json::json!({
            "schema": SCHEMA_V2,
            "producer": {"name": "espalier", "version": "0.1.0"},
            "source": {
                "profile_sha256": format!("sha256:{}", "a".repeat(64)),
                "method_count": 1,
                "complete_symbol_count": 1
            },
            "symbols": {
                symbol: {"time": "O(N)", "space": "O(1)"}
            }
        });
        assert_eq!(apply_json(&mut output, &valid.to_string()).unwrap(), 1);

        let mut invalid = valid;
        invalid["source"]["complete_symbol_count"] = serde_json::json!(2);
        assert!(
            apply_json(&mut ProfileOutput::default(), &invalid.to_string())
                .unwrap_err()
                .to_string()
                .contains("declares 2 complete symbols but contains 1")
        );
    }

    #[test]
    fn bundled_summary_may_name_a_distinct_consumer_indexer() {
        let summary: SummaryFile = serde_json::from_value(serde_json::json!({
            "schema": SCHEMA_V3,
            "producer": {"name": "espalier", "version": "0.1.0"},
            "source": {
                "profile_sha256": format!("sha256:{}", "a".repeat(64)),
                "method_count": 1,
                "complete_symbol_count": 1,
                "indexer": "scip-clang@0.4.0",
                "consumer_indexers": ["scip-php@0.4.7"]
            },
            "compatibility": {"claims": {}},
            "symbols": {
                "scip-php composer php 8.4.21 strlen().": {
                    "time": "O(N)",
                    "space": "O(1)"
                }
            }
        }))
        .unwrap();
        validate(&summary).unwrap();
        let producer = ProfileOutput {
            semantic_indexes: vec![SemanticIndex {
                tool: "scip-clang".into(),
                version: "0.4.0".into(),
            }],
            ..ProfileOutput::default()
        };
        let consumer = ProfileOutput {
            semantic_indexes: vec![SemanticIndex {
                tool: "scip-php".into(),
                version: "0.4.7".into(),
            }],
            ..ProfileOutput::default()
        };
        let source = summary.source.as_ref().unwrap();
        assert!(!has_compatible_indexer(
            &producer,
            source,
            "scip-clang@0.4.0"
        ));
        assert!(has_compatible_indexer(
            &consumer,
            source,
            "scip-clang@0.4.0"
        ));
        assert_eq!(source.consumer_indexers, ["scip-php@0.4.7"]);
    }

    #[test]
    fn v3_summary_requires_exact_semantic_environment_claims() {
        let symbol = "cxx . . std/vector#size().";
        let summary = serde_json::json!({
            "schema": SCHEMA_V3,
            "producer": {"name": "espalier", "version": "0.1.0"},
            "source": {
                "profile_sha256": format!("sha256:{}", "a".repeat(64)),
                "method_count": 1,
                "complete_symbol_count": 1
            },
            "compatibility": {
                "claims": {
                    "cpp.stdlib": "libstdc++",
                    "cpp.stdlib.sha256": "sha256:toolchain"
                }
            },
            "symbols": {
                symbol: {"time": "O(1)", "space": "O(1)"}
            }
        });
        let mut exact = ProfileOutput {
            calls: vec![call(Some(symbol))],
            semantic_environment: BTreeMap::from([
                ("cpp.stdlib".into(), "libstdc++".into()),
                ("cpp.stdlib.sha256".into(), "sha256:toolchain".into()),
            ]),
            ..ProfileOutput::default()
        };
        assert_eq!(apply_json(&mut exact, &summary.to_string()).unwrap(), 1);

        let error = apply_json(&mut ProfileOutput::default(), &summary.to_string()).unwrap_err();
        assert!(error.to_string().contains("cpp.stdlib"));
        assert!(error.to_string().contains("<missing>"));
    }

    #[test]
    fn semantic_environment_sidecars_merge_identical_claims_and_reject_conflicts() {
        let first = tempfile::NamedTempFile::new().unwrap();
        let second = tempfile::NamedTempFile::new().unwrap();
        fs::write(
            first.path(),
            serde_json::json!({
                "schema": ENVIRONMENT_SCHEMA_V1,
                "claims": {"runtime": "ruby-3.2.3", "target": "x86_64-linux"}
            })
            .to_string(),
        )
        .unwrap();
        fs::write(
            second.path(),
            serde_json::json!({
                "schema": ENVIRONMENT_SCHEMA_V1,
                "claims": {"runtime": "ruby-3.2.3", "abi": "gnu"}
            })
            .to_string(),
        )
        .unwrap();
        let mut output = ProfileOutput::default();
        assert_eq!(
            apply_environment_files(&mut output, &[first.path(), second.path()]).unwrap(),
            3
        );
        assert_eq!(output.semantic_environment["abi"], "gnu");

        fs::write(
            second.path(),
            serde_json::json!({
                "schema": ENVIRONMENT_SCHEMA_V1,
                "claims": {"runtime": "ruby-3.3.0"}
            })
            .to_string(),
        )
        .unwrap();
        assert!(apply_environment_files(&mut output, &[second.path()])
            .unwrap_err()
            .to_string()
            .contains("conflicting semantic environment claim runtime"));
    }

    #[test]
    fn reads_gzip_semantic_environment_by_content() {
        let json = serde_json::json!({
            "schema": ENVIRONMENT_SCHEMA_V1,
            "claims": {"runtime": "ruby-3.2.3"}
        });
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(json.to_string().as_bytes()).unwrap();
        let compressed = encoder.finish().unwrap();
        let file = tempfile::NamedTempFile::new().unwrap();
        fs::write(file.path(), compressed).unwrap();
        let mut output = ProfileOutput::default();

        assert_eq!(
            apply_environment_files(&mut output, &[file.path()]).unwrap(),
            1
        );
        assert_eq!(output.semantic_environment["runtime"], "ruby-3.2.3");
    }

    #[test]
    fn reads_gzip_summary_by_content() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {"time": "O(N)", "space": "O(1)"}
            }
        });
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(json.to_string().as_bytes()).unwrap();
        let compressed = encoder.finish().unwrap();
        let file = tempfile::NamedTempFile::new().unwrap();
        fs::write(file.path(), compressed).unwrap();
        let mut output = ProfileOutput {
            calls: vec![call(Some(symbol))],
            ..ProfileOutput::default()
        };

        assert_eq!(apply_file(&mut output, file.path()).unwrap(), 1);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(N)")
        );
    }

    #[test]
    fn complete_generated_result_replaces_incomplete_existing_result() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let mut partial = call(Some(symbol));
        partial.known_time_complexity = Some("O(1)".into());
        partial.complexity_provenance = Some("incomplete_fallback".into());
        let mut output = ProfileOutput {
            calls: vec![partial],
            ..ProfileOutput::default()
        };
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {
                    "time": "O(N)",
                    "space": "O(1)",
                    "provenance": "analyzed_source_summary"
                }
            }
        });

        assert_eq!(apply_json(&mut output, &json.to_string()).unwrap(), 1);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(N)")
        );
        assert_eq!(
            output.calls[0].known_space_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[0].complexity_provenance.as_deref(),
            Some("analyzed_source_summary")
        );
    }

    #[test]
    fn equal_complete_generated_result_becomes_canonical() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let mut fallback = call(Some(symbol));
        fallback.known_time_complexity = Some("O(N)".into());
        fallback.known_space_complexity = Some("O(1)".into());
        fallback.complexity_provenance = Some("manual_fallback".into());
        let mut output = ProfileOutput {
            calls: vec![fallback],
            ..ProfileOutput::default()
        };
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                symbol: {
                    "time": "O(N)",
                    "space": "O(1)",
                    "provenance": "analyzed_source_summary"
                }
            }
        });

        assert_eq!(apply_json(&mut output, &json.to_string()).unwrap(), 1);
        assert_eq!(
            output.calls[0].complexity_provenance.as_deref(),
            Some("analyzed_source_summary")
        );
    }

    #[test]
    fn rejects_complete_generated_manual_conflict_without_mutating_output() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let mut fallback = call(Some(symbol));
        fallback.known_time_complexity = Some("O(1)".into());
        fallback.known_space_complexity = Some("O(1)".into());
        fallback.complexity_provenance = Some("manual_fallback".into());
        let untouched = call(Some("scip-go gomod stdlib v1 bytes#Clone()."));
        let mut output = ProfileOutput {
            calls: vec![untouched, fallback],
            ..ProfileOutput::default()
        };
        let json = serde_json::json!({
            "schema": SCHEMA_V1,
            "symbols": {
                "scip-go gomod stdlib v1 bytes#Clone().": {
                    "time": "O(N)",
                    "space": "O(N)"
                },
                symbol: {
                    "time": "O(N)",
                    "space": "O(1)",
                    "provenance": "analyzed_source_summary"
                }
            }
        });

        let error = apply_json(&mut output, &json.to_string()).unwrap_err();
        assert!(error.to_string().contains("complete complexity conflict"));
        assert!(error.to_string().contains(symbol));
        assert_eq!(output.calls[0].known_time_complexity, None);
        assert_eq!(
            output.calls[1].known_time_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[1].complexity_provenance.as_deref(),
            Some("manual_fallback")
        );
    }

    #[test]
    fn rejects_conflicting_files_before_applying_either() {
        let symbol = "scip-go gomod stdlib v1 strings#IndexByte().";
        let file_a = tempfile::NamedTempFile::new().unwrap();
        let file_b = tempfile::NamedTempFile::new().unwrap();
        for (file, time) in [(&file_a, "O(N)"), (&file_b, "O(1)")] {
            fs::write(
                file.path(),
                serde_json::json!({
                    "schema": SCHEMA_V1,
                    "symbols": {
                        symbol: {"time": time, "space": "O(1)"}
                    }
                })
                .to_string(),
            )
            .unwrap();
        }
        let mut output = ProfileOutput {
            calls: vec![call(Some(symbol))],
            ..ProfileOutput::default()
        };

        let error = apply_files(&mut output, &[file_a.path(), file_b.path()]).unwrap_err();
        assert!(error
            .to_string()
            .contains("conflicting complexity summaries"));
        assert_eq!(output.calls[0].known_time_complexity, None);
    }

    #[test]
    fn every_bundled_summary_applies_only_with_its_declared_indexer() {
        assert!(!BUNDLED_SUMMARIES.is_empty());
        for (name, bytes) in BUNDLED_SUMMARIES {
            let source = decode(Path::new(name), bytes).unwrap();
            let summary: SummaryFile = serde_json::from_str(&source).unwrap();
            validate(&summary).unwrap();
            let symbol = summary.symbols.keys().next().unwrap();
            let source = summary.source.as_ref().unwrap();
            let indexer = source
                .consumer_indexers
                .first()
                .map(String::as_str)
                .or(source.indexer.as_deref())
                .unwrap();
            let (tool, version) = indexer.split_once('@').unwrap();
            let semantic_environment = summary
                .compatibility
                .as_ref()
                .map(|compatibility| compatibility.claims.clone())
                .unwrap_or_default();
            let mut exact = ProfileOutput {
                calls: vec![call(Some(symbol))],
                semantic_indexes: vec![SemanticIndex {
                    tool: tool.into(),
                    version: version.into(),
                }],
                semantic_environment: semantic_environment.clone(),
                ..ProfileOutput::default()
            };
            assert!(
                apply_bundled(&mut exact).unwrap() > 0,
                "{name} did not apply with {indexer}"
            );
            assert_eq!(
                exact.calls[0].complexity_provenance.as_deref(),
                Some("analyzed_source_summary")
            );

            let mut wrong_indexer = ProfileOutput {
                calls: vec![call(Some(symbol))],
                semantic_indexes: vec![SemanticIndex {
                    tool: tool.into(),
                    version: format!("{version}-incompatible"),
                }],
                semantic_environment,
                ..ProfileOutput::default()
            };
            assert_eq!(apply_bundled(&mut wrong_indexer).unwrap(), 0);
            assert_eq!(wrong_indexer.calls[0].known_time_complexity, None);
        }
    }
}
