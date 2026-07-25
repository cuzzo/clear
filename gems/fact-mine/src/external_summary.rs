//! Language-neutral ingestion of complexity summaries keyed by compiler symbol.
//!
//! A producer may analyze excluded/generated source or dependency source once,
//! then publish exact-symbol summaries. Consumers join only on the compiler
//! identity already attached to a call; no owner/name reconstruction occurs.

use crate::profile::{summarize_call_resolution, ProfileOutput};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

const SCHEMA: &str = "fact-mine.external-complexity-summary.v1";

#[derive(Debug, Deserialize)]
struct SummaryFile {
    schema: String,
    #[serde(default)]
    symbols: BTreeMap<String, ComplexitySummary>,
}

#[derive(Debug, Deserialize)]
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
    let source = fs::read_to_string(path)
        .with_context(|| format!("failed to read complexity summary {}", path.display()))?;
    apply_json(output, &source)
        .with_context(|| format!("failed to apply complexity summary {}", path.display()))
}

pub fn apply_json(output: &mut ProfileOutput, source: &str) -> Result<usize> {
    let summary: SummaryFile = serde_json::from_str(source)?;
    if summary.schema != SCHEMA {
        bail!(
            "unsupported complexity summary schema {}; expected {SCHEMA}",
            summary.schema
        );
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::{CallRecord, ProfileOutput};

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
            "schema": SCHEMA,
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
            "schema": SCHEMA,
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
}
