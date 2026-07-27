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

#[derive(Debug, Deserialize)]
struct SummaryFile {
    schema: String,
    #[serde(default)]
    producer: Option<SummaryProducer>,
    #[serde(default)]
    source: Option<SummarySource>,
    #[serde(default)]
    symbols: BTreeMap<String, ComplexitySummary>,
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
    apply_summary(output, &summary)
}

pub fn apply_files(output: &mut ProfileOutput, paths: &[impl AsRef<Path>]) -> Result<usize> {
    let mut summaries = Vec::with_capacity(paths.len());
    let mut costs_by_symbol: BTreeMap<String, (String, String, String)> = BTreeMap::new();
    for path in paths {
        let path = path.as_ref();
        let summary = read_file(path)?;
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
    apply_summary(output, &summary)
}

fn apply_summary(output: &mut ProfileOutput, summary: &SummaryFile) -> Result<usize> {
    let mut applied = 0;
    for call in &mut output.calls {
        if call.target.is_some()
            || call.known_time_complexity.is_some()
            || call.known_space_complexity.is_some()
        {
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
    }
    Ok(applied)
}

fn validate(summary: &SummaryFile) -> Result<()> {
    match summary.schema.as_str() {
        SCHEMA_V1 => {}
        SCHEMA_V2 => {
            let producer = summary
                .producer
                .as_ref()
                .context("v2 complexity summary is missing producer metadata")?;
            if producer.name.trim().is_empty() || producer.version.trim().is_empty() {
                bail!("v2 complexity summary producer name and version must be non-empty");
            }
            let source = summary
                .source
                .as_ref()
                .context("v2 complexity summary is missing source metadata")?;
            let digest = source
                .profile_sha256
                .strip_prefix("sha256:")
                .unwrap_or_default();
            if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                bail!("v2 complexity summary source.profile_sha256 must be a SHA-256 digest");
            }
            if source.complete_symbol_count != summary.symbols.len() {
                bail!(
                    "v2 complexity summary declares {} complete symbols but contains {}",
                    source.complete_symbol_count,
                    summary.symbols.len()
                );
            }
            if source.complete_symbol_count > 0 && source.method_count == 0 {
                bail!(
                    "v2 complexity summary with exported symbols must analyze at least one method"
                );
            }
        }
        other => bail!(
            "unsupported complexity summary schema {other}; expected {SCHEMA_V1} or {SCHEMA_V2}"
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
    use crate::profile::{CallRecord, ProfileOutput};
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
            receiver_definition_call_spans: Vec::new(),
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
            raw_source: "void run() {}".into(),
            normalized_source: "void run() {}".into(),
            untraceable_params: Vec::new(),
            source: serde_json::Value::Null,
        });
        output.calls = vec![call(Some(symbol))];
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
}
