use anyhow::{bail, Context, Result};
use decomplex_rust::decomplex::detectors::{
    co_update, decision_pressure, derived_state, false_simplicity, fat_union, flay_similarity,
    function_lcom, implicit_control_flow, inconsistent_rename_clone, local_flow, locality_drag,
    miner, operational_discontinuity, oversized_predicate, path_condition, predicate_alias,
    redundant_nil_guard, semantic_alias, sequence_mine, state_branch_density, state_mesh,
    structural_topology, superfluous_state, temporal_ordering_pressure,
    weighted_inlined_cognitive_complexity,
};
use decomplex_rust::decomplex::report::Report;
use decomplex_rust::decomplex::syntax::{Document, Language, LocalComplexityScore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn shared_examples_match_oracles() -> Result<()> {
    let examples_root = examples_root();
    let oracle_dir = examples_root.join("oracles");
    let mut failures = Vec::new();

    for fixture in fixture_paths(&examples_root)? {
        let detector = file_stem(&fixture)?;
        let oracle_path = oracle_dir.join(format!("{detector}.json"));
        if !oracle_path.is_file() {
            failures.push(format!(
                "{}: missing oracle {}",
                fixture.display(),
                oracle_path.display()
            ));
            continue;
        }

        let oracle: Value = serde_json::from_str(&fs::read_to_string(&oracle_path)?)?;
        let expected = oracle
            .get("expected")
            .cloned()
            .with_context(|| format!("{} missing expected", oracle_path.display()))?;
        let detector_name = oracle
            .get("detector")
            .and_then(Value::as_str)
            .with_context(|| format!("{} missing detector", oracle_path.display()))?;
        let options = oracle.get("options").cloned().unwrap_or_else(|| json!({}));
        let language = language_for_fixture(&fixture)?;
        if matches!(language, Language::Swift) {
            continue;
        }
        let actual = run_detector(detector_name, &[fixture.clone()], language, &options)
            .with_context(|| format!("{} {}", detector_name, fixture.display()))?;
        let projected = project_detector_output(&detector, actual);
        let expected_normalized = normalize_paths(&expected);
        let projected_normalized = normalize_paths(&projected);

        if std::env::var("UPDATE_ORACLES").is_ok() {
            let mut oracle: Value = serde_json::from_str(&fs::read_to_string(&oracle_path)?)?;
            oracle["expected"] = projected_normalized;
            fs::write(&oracle_path, serde_json::to_string_pretty(&oracle)?)?;
        } else if projected_normalized != expected_normalized {
            failures.push(format!(
                "{} {}\nexpected: {}\nactual:   {}",
                detector_name,
                fixture.display(),
                expected_normalized,
                projected_normalized
            ));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!("shared example oracle failures:\n{}", failures.join("\n\n"))
    }
}

#[test]
fn shared_detector_fact_examples_match_exact_oracles() -> Result<()> {
    let examples_root = examples_root();
    let mut failures = Vec::new();

    for fixture in detector_fact_fixture_paths(&examples_root)? {
        let fixture_value: Value = serde_json::from_str(&fs::read_to_string(&fixture)?)?;
        let detector = fixture_value
            .get("detector")
            .and_then(Value::as_str)
            .with_context(|| format!("{} missing detector", fixture.display()))?;
        let expected = fixture_value
            .get("expected")
            .cloned()
            .with_context(|| format!("{} missing expected", fixture.display()))?;
        let input = detector_fact_input(&fixture_value)
            .with_context(|| format!("{} input", fixture.display()))?;
        let actual = run_detector_on_fact_input(detector, &input, &fixture_value)
            .with_context(|| format!("{} {}", detector, fixture.display()))?;

        if std::env::var("UPDATE_ORACLES").is_ok() {
            let mut fixture_val: Value = serde_json::from_str(&fs::read_to_string(&fixture)?)?;
            fixture_val["expected"] = actual;
            fs::write(&fixture, serde_json::to_string_pretty(&fixture_val)?)?;
        } else if actual != expected {
            failures.push(format!(
                "{} {}\nexpected: {}\nactual:   {}",
                detector,
                fixture.display(),
                expected,
                actual
            ));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "shared detector fact oracle failures:\n{}",
            failures.join("\n\n")
        )
    }
}

#[test]
fn shared_local_flow_consumer_fact_examples_match_exact_oracles() -> Result<()> {
    let examples_root = examples_root();
    let mut failures = Vec::new();

    for fixture in local_flow_fact_fixture_paths(&examples_root)? {
        let mut fixture_value: Value = serde_json::from_str(&fs::read_to_string(&fixture)?)?;
        let input = detector_fact_input(&fixture_value)
            .with_context(|| format!("{} input", fixture.display()))?;

        let mut actuals = std::collections::BTreeMap::new();
        if let Some(expected_by_detector) = fixture_value.get("expected").and_then(Value::as_object) {
            for detector in expected_by_detector.keys() {
                let actual = run_detector_on_fact_input(detector, &input, &fixture_value)
                    .with_context(|| format!("{} {}", detector, fixture.display()))?;
                actuals.insert(detector.clone(), actual);
            }
        }

        if std::env::var("UPDATE_ORACLES").is_ok() {
            if let Some(expected_by_detector) = fixture_value.get_mut("expected").and_then(Value::as_object_mut) {
                for (detector, actual) in actuals {
                    expected_by_detector.insert(detector, actual);
                }
            }
            fs::write(&fixture, serde_json::to_string_pretty(&fixture_value)?)?;
        } else {
            if let Some(expected_by_detector) = fixture_value.get("expected").and_then(Value::as_object) {
                for (detector, expected) in expected_by_detector {
                    let actual = actuals.get(detector).unwrap();
                    if *actual != *expected {
                        failures.push(format!(
                            "{} {}\nexpected: {}\nactual:   {}",
                            detector,
                            fixture.display(),
                            expected,
                            actual
                        ));
                    }
                }
            }
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "shared local-flow consumer fact oracle failures:\n{}",
            failures.join("\n\n")
        )
    }
}

#[test]
fn shared_report_fact_examples_match_postprocess_oracles() -> Result<()> {
    let examples_root = examples_root();
    let mut failures = Vec::new();

    for fixture in report_fact_fixture_paths(&examples_root)? {
        let fixture_value: Value = serde_json::from_str(&fs::read_to_string(&fixture)?)?;
        let facts = fixture_value
            .get("input")
            .with_context(|| format!("{} missing input", fixture.display()))?;
        let expected = fixture_value
            .get("expected")
            .cloned()
            .with_context(|| format!("{} missing expected", fixture.display()))?;
        let expected_markdown = fs::read_to_string(fixture.with_extension("md"))
            .with_context(|| format!("{} missing markdown oracle", fixture.display()))?
            .trim_end()
            .to_string();
        let report = Report::from_facts(facts)
            .with_context(|| format!("failed to build report from {}", fixture.display()))?;
        let actual = project_report(&report);

        if std::env::var("UPDATE_ORACLES").is_ok() {
            let mut fixture_val: Value = serde_json::from_str(&fs::read_to_string(&fixture)?)?;
            fixture_val["expected"] = actual;
            fs::write(&fixture, serde_json::to_string_pretty(&fixture_val)?)?;
            let markdown = report.to_markdown().trim_end().to_string();
            fs::write(fixture.with_extension("md"), &markdown)?;
        } else {
            if actual != expected {
                failures.push(format!(
                    "{}\nexpected: {}\nactual:   {}",
                    fixture.display(),
                    expected,
                    actual
                ));
            }
            let markdown = report.to_markdown().trim_end().to_string();
            if markdown != expected_markdown {
                failures.push(format!(
                    "{} markdown\nexpected: {}\nactual:   {}",
                    fixture.display(),
                    expected_markdown,
                    markdown
                ));
            }
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "shared report fact oracle failures:\n{}",
            failures.join("\n\n")
        )
    }
}

fn examples_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("examples")
}

fn fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for language_dir in fs::read_dir(examples_root)? {
        let language_dir = language_dir?.path();
        if !language_dir.is_dir()
            || language_dir.file_name().and_then(|name| name.to_str()) == Some("oracles")
        {
            continue;
        }
        for entry in fs::read_dir(&language_dir)? {
            let path = entry?.path();
            if path.is_file() && language_for_fixture(&path).is_ok() {
                paths.push(path);
            }
        }
    }
    paths.sort();
    Ok(paths)
}

fn report_fact_fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let report_root = examples_root.join("facts").join("report");
    let mut paths = Vec::new();
    for entry in fs::read_dir(&report_root)? {
        let path = entry?.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("json") {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn detector_fact_fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let detector_root = examples_root.join("facts").join("detectors");
    let mut paths = Vec::new();
    for entry in fs::read_dir(&detector_root)? {
        let path = entry?.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("json") {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn local_flow_fact_fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let root = examples_root.join("facts").join("local-flow");
    let mut paths = Vec::new();
    for entry in fs::read_dir(&root)? {
        let path = entry?.path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("json") {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

#[derive(Deserialize)]
struct DetectorFactInput {
    documents: Vec<Document>,
    local_methods: Vec<local_flow::MethodSummary>,
}

fn detector_fact_input(fixture: &Value) -> Result<DetectorFactInput> {
    let input = fixture
        .get("input")
        .cloned()
        .with_context(|| "detector fact fixture missing input")?;
    let documents = serde_json::from_value::<DetectorFactDocuments>(input.clone())?.documents;
    let mut local_methods = Vec::new();

    if let Some(methods) = input.get("local_methods") {
        local_methods.extend(serde_json::from_value::<Vec<local_flow::MethodSummary>>(
            methods.clone(),
        )?);
    }
    for document in input
        .get("documents")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(methods) = document.get("local_methods") {
            local_methods.extend(serde_json::from_value::<Vec<local_flow::MethodSummary>>(
                methods.clone(),
            )?);
        }
    }

    Ok(DetectorFactInput {
        documents,
        local_methods,
    })
}

#[derive(Deserialize)]
struct DetectorFactDocuments {
    documents: Vec<Document>,
}

fn file_stem(path: &Path) -> Result<String> {
    path.file_stem()
        .and_then(|stem| stem.to_str())
        .map(str::to_string)
        .with_context(|| format!("missing file stem for {}", path.display()))
}

fn language_for_fixture(path: &Path) -> Result<Language> {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .with_context(|| format!("missing extension for {}", path.display()))?;
    Language::for_extension(extension)
        .with_context(|| format!("unsupported fixture extension: {}", path.display()))
}

fn run_detector(
    detector: &str,
    files: &[PathBuf],
    language: Language,
    options: &Value,
) -> Result<Value> {
    match detector {
        "co-update" => value(co_update::scan_files(files, language)?),
        "decision-pressure" => value(decision_pressure::scan_files(files, language)?),
        "predicate-alias" | "predicate-aliases" => {
            value(predicate_alias::scan_files(files, language)?)
        }
        "miner" | "decision-miner" => value(miner::scan_files(files, language)?),
        "semantic-alias" | "semantic-aliases" => {
            value(semantic_alias::scan_files(files, language)?)
        }
        "flay-similarity" | "structural-similarity" => {
            let mass = option_usize(options, "mass", 32)?;
            let fuzzy = option_usize(options, "fuzzy", 1)?;
            Ok(json!({ "findings": flay_similarity::scan_files(files, language, mass, fuzzy)? }))
        }
        "temporal-ordering-pressure" => {
            value(temporal_ordering_pressure::scan_files(files, language)?)
        }
        "state-branch-density" => value(state_branch_density::scan_files(files, language)?),
        "redundant-nil-guard" => value(redundant_nil_guard::scan_files(files, language)?),
        "state-mesh" | "state-heatmap" => value(state_mesh::scan_files(files, language)?),
        "inconsistent-rename-clone" => {
            value(inconsistent_rename_clone::scan_files(files, language)?)
        }
        "derived-state" => value(derived_state::scan_files(files, language)?),
        "superfluous-state" => value(superfluous_state::scan_files(files, language)?),
        "implicit-control-flow" | "ordered-protocol-mine" => {
            value(implicit_control_flow::scan_files(files, language)?)
        }
        "weighted-inlined-complexity" => value(weighted_inlined_cognitive_complexity::scan_files(
            files, language,
        )?),
        "locality-drag" => value(locality_drag::scan_files(files, language)?),
        "operational-discontinuity" => {
            value(operational_discontinuity::scan_files(files, language)?)
        }
        "oversized-predicate" => value(oversized_predicate::scan_files(files, language)?),
        "path-condition" => value(path_condition::scan_files(files, language)?),
        "sequence-mine" | "broken-protocol" => value(sequence_mine::scan_files(files, language)?),
        "function-lcom" => value(function_lcom::scan_files(files, language)?),
        "false-simplicity" => value(false_simplicity::scan_files(files, language)?),
        "fat-union" => value(fat_union::scan_files(files, language)?),
        "local-flow" => value(local_flow::scan_files(files, language)?),
        "structural-topology" => value(structural_topology::scan_files(files, language)?),
        _ => bail!("unsupported detector: {detector}"),
    }
}

fn run_detector_on_fact_input(
    detector: &str,
    input: &DetectorFactInput,
    fixture: &Value,
) -> Result<Value> {
    let documents = input.documents.as_slice();
    match detector {
        "co-update" => value(co_update::scan_documents(documents)),
        "decision-pressure" => {
            if input.local_methods.is_empty() {
                value(decision_pressure::scan_documents(documents))
            } else {
                value(decision_pressure::scan_documents_with_summaries(
                    documents,
                    &input.local_methods,
                ))
            }
        }
        "predicate-alias" | "predicate-aliases" => {
            value(predicate_alias::scan_documents(documents))
        }
        "miner" | "decision-miner" => value(miner::scan_documents(documents)),
        "semantic-alias" | "semantic-aliases" => value(semantic_alias::scan_documents(documents)),
        "flay-similarity" | "structural-similarity" => {
            let options = fixture.get("options").cloned().unwrap_or_else(|| json!({}));
            let mass = option_usize(&options, "mass", 32)?;
            let fuzzy = option_usize(&options, "fuzzy", 1)?;
            value(json!({ "findings": flay_similarity::scan_documents(documents, mass, fuzzy) }))
        }
        "temporal-ordering-pressure" => {
            value(temporal_ordering_pressure::scan_documents(documents))
        }
        "state-branch-density" => value(state_branch_density::scan_documents(documents)),
        "redundant-nil-guard" => value(redundant_nil_guard::scan_documents(documents)),
        "state-mesh" | "state-heatmap" => value(state_mesh::scan_documents(documents)),
        "inconsistent-rename-clone" => value(inconsistent_rename_clone::scan_documents(documents)),
        "derived-state" => {
            if input.local_methods.is_empty() {
                value(derived_state::scan_documents(documents))
            } else {
                value(derived_state::scan_summaries(&input.local_methods))
            }
        }
        "implicit-control-flow" | "ordered-protocol-mine" => {
            value(implicit_control_flow::scan_documents(documents))
        }
        "weighted-inlined-complexity" => {
            if input.local_methods.is_empty() {
                value(weighted_inlined_cognitive_complexity::scan_documents(
                    documents,
                ))
            } else {
                value(
                    weighted_inlined_cognitive_complexity::scan_documents_with_summaries(
                        documents,
                        &input.local_methods,
                    ),
                )
            }
        }
        "locality-drag" => {
            if input.local_methods.is_empty() {
                value(locality_drag::scan_documents(documents))
            } else {
                let scores = complexity_scores(documents);
                value(locality_drag::scan_summaries_with_scores(
                    &input.local_methods,
                    &scores,
                ))
            }
        }
        "operational-discontinuity" => {
            if input.local_methods.is_empty() {
                value(operational_discontinuity::scan_documents(documents))
            } else {
                value(operational_discontinuity::scan_summaries(
                    &input.local_methods,
                ))
            }
        }
        "oversized-predicate" => value(oversized_predicate::scan_documents(documents)),
        "path-condition" => {
            let report = path_condition::scan_documents(documents);
            value(json!({ "neglected": report.neglected }))
        }
        "sequence-mine" | "broken-protocol" => value(sequence_mine::scan_documents(documents)),
        "function-lcom" => {
            if input.local_methods.is_empty() {
                value(function_lcom::scan_documents(documents))
            } else {
                value(function_lcom::scan_summaries(&input.local_methods))
            }
        }
        "false-simplicity" => value(false_simplicity::scan_documents(documents)),
        "fat-union" => value(fat_union::scan_documents(documents)),
        "local-flow" => value(local_flow::scan_documents(documents)),
        "structural-topology" => value(structural_topology::scan_documents(documents)),
        _ => bail!("unsupported detector: {detector}"),
    }
}

fn complexity_scores(
    documents: &[Document],
) -> std::collections::BTreeMap<(String, String), LocalComplexityScore> {
    documents
        .iter()
        .flat_map(|document| {
            document
                .local_complexity_scores
                .iter()
                .map(|(id, score)| ((document.file.clone(), id.clone()), score.clone()))
        })
        .collect()
}

fn project_report(report: &Report) -> Value {
    json!({
        "convergence": report.convergence_value(),
        "root_clusters": report.root_clusters_value(),
        "sarif": compact_sarif(&report.to_sarif_value(false, false, Some(8))),
    })
}

fn compact_sarif(sarif: &Value) -> Value {
    let run = field(sarif, "runs")
        .as_array()
        .and_then(|runs| runs.first())
        .unwrap_or(&Value::Null);
    let results = array(field(run, "results"));
    json!({
        "rule_count": array(field(field(field(run, "tool"), "driver"), "rules")).len(),
        "result_count": results.len(),
        "rule_ids": results.iter().map(|result| field(result, "ruleId").clone()).collect::<Vec<_>>(),
        "messages": results.iter().map(|result| field(field(result, "message"), "text").clone()).collect::<Vec<_>>(),
        "locations": results.iter().map(|result| {
            let location = field(
                array(field(result, "locations")).first().unwrap_or(&Value::Null),
                "physicalLocation",
            );
            json!({
                "uri": field(field(location, "artifactLocation"), "uri").clone(),
                "startLine": field(field(location, "region"), "startLine").clone(),
            })
        }).collect::<Vec<_>>(),
    })
}

fn value<T: Serialize>(value: T) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}

fn option_usize(options: &Value, key: &str, default: usize) -> Result<usize> {
    match options.get(key) {
        Some(value) => value
            .as_u64()
            .map(|value| value as usize)
            .with_context(|| format!("option {key} must be an integer")),
        None => Ok(default),
    }
}

fn project_detector_output(detector: &str, output: Value) -> Value {
    match detector {
        "co-update" => json!({
            "co_written_pairs": rows(field(&output, "co_written_pairs"), &["pair", "support"]),
            "neglected_updates": rows(field(&output, "neglected_updates"), &["pair", "support", "has", "missing"]),
        }),
        "decision-pressure" => rows(&output, &["contract", "decisions", "essential", "methods"]),
        "predicate-alias" => json!({
            "alias_clusters": array(field(&output, "alias_clusters")).iter().map(|row| {
                json!({ "name_count": array(field(row, "names")).len() })
            }).collect::<Vec<_>>()
        }),
        "miner" => json!({
            "missing_abstractions": array(field(&output, "missing_abstractions")).iter().map(|row| {
                pick(row, &["kind", "members", "support", "scatter"])
            }).collect::<Vec<_>>(),
            "neglected_conditions": rows(field(&output, "neglected_conditions"), &["pattern", "support", "missing"]),
        }),
        "semantic-alias" => json!({
            "alias_clusters": array(field(&output, "alias_clusters")).iter().map(|row| {
                json!({
                    "canon": canonical_predicate(field(row, "canon")),
                    "name_count": array(field(row, "names")).len(),
                })
            }).collect::<Vec<_>>(),
            "reification_miss_count": array(field(&output, "reification_misses")).len(),
        }),
        "flay-similarity" => Value::Array(
            array(field(&output, "findings"))
                .iter()
                .map(|row| {
                    let mut projected = object(pick(row, &["clone_type", "node"]));
                    projected.insert(
                        "site_count".to_string(),
                        json!(array(field(row, "sites")).len()),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "temporal-ordering-pressure" => Value::Array(
            array(&output)
                .iter()
                .map(|row| {
                    let mut projected = object(pick(
                        row,
                        &[
                            "owner",
                            "public_methods",
                            "state_methods",
                            "writers",
                            "orderings",
                        ],
                    ));
                    projected.insert(
                        "state_fields".to_string(),
                        json!(canonical_state_refs(field(row, "state_fields"))),
                    );
                    projected.insert(
                        "shared_fields".to_string(),
                        json!(canonical_state_refs(field(row, "shared_fields"))),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "state-branch-density" => Value::Array(
            array(&output)
                .iter()
                .map(|row| {
                    let mut projected = object(pick(row, &["decisions"]));
                    projected.insert(
                        "method".to_string(),
                        json!(canonical_method_name(field(row, "method"))),
                    );
                    projected.insert(
                        "state_refs".to_string(),
                        json!(canonical_state_refs(field(row, "state_refs"))),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "redundant-nil-guard" => rows(&output, &["local"]),
        "state-mesh" => project_state_mesh(&output),
        "inconsistent-rename-clone" => Value::Array(
            array(&output)
                .iter()
                .map(|row| {
                    let mut projected = object(pick(row, &["ref_name"]));
                    projected.insert(
                        "divergent_count".to_string(),
                        json!(array(field(row, "divergent")).len()),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "derived-state" => canonicalize_derived_state_refs(&rows(&output, &["derived", "source"])),
        "superfluous-state" => rows(&output, &["field", "score", "classification", "writer_method_count", "reader_method_count", "ctorset"]),
        "implicit-control-flow" => json!({
            "ordered_protocols": project_protocols(field(&output, "ordered_protocols")),
            "order_drift": project_protocols(field(&output, "order_drift")),
        }),
        "weighted-inlined-complexity" => Value::Array(
            array(&output)
                .iter()
                .map(|row| {
                    let mut projected = object(pick(row, &["method", "depth"]));
                    projected.insert(
                        "callee_count".to_string(),
                        json!(array(field(row, "single_caller_callees")).len()),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "locality-drag" => rows(&output, &["variable"]),
        "operational-discontinuity" => rows(&output, &["resets", "confidence"]),
        "oversized-predicate" => Value::Array(
            array(field(&output, "findings"))
                .iter()
                .map(|row| {
                    let mut projected = object(pick(row, &["count"]));
                    projected.insert(
                        "atom_count".to_string(),
                        json!(array(field(row, "atoms")).len()),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "path-condition" => Value::Array(
            array(field(&output, "neglected"))
                .iter()
                .map(|row| {
                    json!({
                        "pattern": canonical_predicate_atoms(field(row, "pattern")),
                        "support": field(row, "support").clone(),
                        "missing": canonical_predicate(field(row, "missing")),
                        "action": canonical_action(field(row, "action")),
                    })
                })
                .collect(),
        ),
        "sequence-mine" => rows(
            field(&output, "broken"),
            &["pair", "support", "has", "missing"],
        ),
        "function-lcom" => rows(
            &output,
            &[
                "mode",
                "components",
                "locals",
                "statements",
                "terminal_join",
            ],
        ),
        "false-simplicity" => rows(&output, &["kind"]),
        "fat-union" => Value::Array(
            array(field(&output, "fat_unions"))
                .iter()
                .map(|row| {
                    let mut projected = object(pick(
                        row,
                        &["common", "variant", "degenerate", "support", "scatter"],
                    ));
                    projected.insert(
                        "variant_set".to_string(),
                        json!(canonical_variants(field(row, "variant_set"))),
                    );
                    Value::Object(projected)
                })
                .collect(),
        ),
        "local-flow" => project_local_flow(&output),
        "structural-topology" => json!({
            "method_count": array(field(&output, "methods")).len(),
            "edges": rows(field(&output, "edges"), &["caller_name", "callee_name", "type"]),
        }),
        _ => scrub_locations(&output),
    }
}

fn project_local_flow(output: &Value) -> Value {
    Value::Array(
        array(output)
            .iter()
            .map(|method| {
                json!({
                    "method": field(method, "name").clone(),
                    "statements": array(field(method, "statements")).iter().map(|statement| {
                        json!({
                            "reads": sorted_array(field(statement, "reads")),
                            "writes": sorted_array(field(statement, "writes")),
                            "dependencies": field(statement, "dependencies").clone(),
                            "co_uses": canonical_co_uses(field(statement, "co_uses")),
                        })
                    }).collect::<Vec<_>>(),
                    "boundaries": array(field(method, "boundaries")).iter().map(|boundary| {
                        pick(boundary, &["before_index", "after_index", "kind"])
                    }).collect::<Vec<_>>(),
                })
            })
            .collect(),
    )
}

fn project_state_mesh(output: &Value) -> Value {
    let state_mesh = field(output, "state_mesh");
    let fields = field(output, "fields");
    let field_names = fields
        .as_object()
        .map(|object| {
            canonical_state_refs(&Value::Array(
                object.keys().cloned().map(Value::String).collect(),
            ))
        })
        .unwrap_or_default();
    json!({
        "state_mesh": pick(
            state_mesh,
            &["total_fields", "total_writes", "total_reads", "total_re_derivations"],
        ),
        "field_names": field_names,
    })
}

fn project_protocols(rows_value: &Value) -> Value {
    Value::Array(
        array(rows_value)
            .iter()
            .map(|row| {
                let mut projected = object(pick(
                    row,
                    &["protocol", "dependency", "support", "observed", "missing"],
                ));
                projected.insert(
                    "states".to_string(),
                    json!(canonical_state_refs(field(row, "states"))),
                );
                Value::Object(projected)
            })
            .collect(),
    )
}

fn canonical_co_uses(value: &Value) -> Value {
    let mut pairs = array(value)
        .iter()
        .map(|pair| {
            let mut items = array(pair)
                .iter()
                .map(|item| item.as_str().unwrap_or_default().to_string())
                .collect::<Vec<_>>();
            items.sort();
            json!(items)
        })
        .collect::<Vec<_>>();
    pairs.sort_by_key(|item| item.to_string());
    Value::Array(pairs)
}

fn rows(value: &Value, keys: &[&str]) -> Value {
    Value::Array(array(value).iter().map(|row| pick(row, keys)).collect())
}

fn pick(row: &Value, keys: &[&str]) -> Value {
    let mut out = Map::new();
    if let Some(object) = row.as_object() {
        for key in keys {
            if let Some(value) = object.get(*key) {
                out.insert((*key).to_string(), canonical_value(value));
            }
        }
    }
    Value::Object(out)
}

fn canonical_value(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut out = Map::new();
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            for key in keys {
                out.insert(key.clone(), canonical_value(&object[key]));
            }
            Value::Object(out)
        }
        Value::Array(values) => Value::Array(values.iter().map(canonical_value).collect()),
        _ => value.clone(),
    }
}

fn normalize_paths(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                let mut v_norm = normalize_paths(v);
                if k == "ref_at" || k == "at" || k == "file" || k == "path" || k == "uri" {
                    if let Value::String(s) = &v_norm {
                        if let Some(idx) = s.find("gems/decomplex/examples/") {
                            v_norm = Value::String(s[idx..].to_string());
                        } else if let Some(idx) = s.find("gems/fact-mine/examples/") {
                            v_norm = Value::String(s[idx..].to_string());
                        }
                    }
                }
                out.insert(k.clone(), v_norm);
            }
            Value::Object(out)
        }
        Value::Array(arr) => {
            Value::Array(arr.iter().map(normalize_paths).collect())
        }
        _ => value.clone(),
    }
}

fn scrub_locations(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut out = Map::new();
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            for key in keys {
                if LOCATION_KEYS.contains(&key.as_str()) {
                    continue;
                }
                out.insert(key.clone(), scrub_locations(&object[key]));
            }
            Value::Object(out)
        }
        Value::Array(values) => Value::Array(values.iter().map(scrub_locations).collect()),
        _ => value.clone(),
    }
}

const LOCATION_KEYS: &[&str] = &[
    "at",
    "boundaries",
    "boundary_crossings",
    "component_lines",
    "defn",
    "examples",
    "file",
    "gap_lines",
    "line",
    "locations",
    "predicate",
    "raw",
    "reason",
    "sites",
    "span",
    "spans",
    "source",
];

fn canonical_variants(value: &Value) -> Vec<String> {
    let mut values = array(value)
        .iter()
        .map(|item| item.as_str().unwrap_or("").replace(':', "."))
        .map(|text| collapse_dots(&text.replace('_', ".")))
        .collect::<Vec<_>>();
    values.sort();
    values
}

fn canonical_state_refs(value: &Value) -> Vec<String> {
    let mut values = BTreeSet::new();
    for item in array(value) {
        let mut text = value_text(item);
        for prefix in &["$this->", "this->", "self->", "this.", "self.", "@"] {
            if let Some(stripped) = text.strip_prefix(prefix) {
                text = stripped.to_string();
                break;
            }
        }
        values.insert(text);
    }
    values.into_iter().collect()
}

fn canonical_method_name(value: &Value) -> String {
    value_text(value)
        .rsplit(['.', ':', '#'])
        .next()
        .unwrap_or("")
        .to_string()
}

fn canonical_predicate_atoms(value: &Value) -> Vec<String> {
    let mut atoms = array(value)
        .iter()
        .map(canonical_predicate)
        .collect::<Vec<_>>();
    atoms.sort();
    atoms
}

fn canonical_predicate(value: &Value) -> String {
    let mut text = value_text(value)
        .trim()
        .trim_end_matches(';')
        .trim()
        .to_string();
    text = replace_symbol_literals(&text);
    text = strip_noarg_suffix(&text);
    text
}

fn canonical_action(value: &Value) -> String {
    canonical_predicate(value)
}

fn replace_symbol_literals(text: &str) -> String {
    let mut out = String::new();
    let chars = text.chars().collect::<Vec<_>>();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == ':' && i + 1 < chars.len() && ident_start(chars[i + 1]) {
            i += 1;
            let start = i;
            while i < chars.len() && ident_continue(chars[i]) {
                i += 1;
            }
            out.push_str(&chars[start..i].iter().collect::<String>().to_uppercase());
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

fn strip_noarg_suffix(text: &str) -> String {
    let mut out = String::new();
    let chars = text.chars().collect::<Vec<_>>();
    let mut i = 0;
    while i < chars.len() {
        if ident_start(chars[i]) {
            let start = i;
            i += 1;
            while i < chars.len() && (ident_continue(chars[i]) || chars[i] == '.') {
                i += 1;
            }
            if i < chars.len() && chars[i] == '?' {
                out.push_str(&chars[start..i].iter().collect::<String>());
                i += 1;
            } else if i + 1 < chars.len() && chars[i] == '(' && chars[i + 1] == ')' {
                out.push_str(&chars[start..i].iter().collect::<String>());
                i += 2;
            } else {
                out.push_str(&chars[start..i].iter().collect::<String>());
            }
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

fn ident_start(ch: char) -> bool {
    ch == '_' || ch.is_ascii_alphabetic()
}

fn ident_continue(ch: char) -> bool {
    ch == '_' || ch.is_ascii_alphanumeric()
}

fn collapse_dots(text: &str) -> String {
    let mut out = String::new();
    let mut previous_dot = false;
    for ch in text.chars() {
        if ch == '.' {
            if !previous_dot {
                out.push(ch);
            }
            previous_dot = true;
        } else {
            out.push(ch);
            previous_dot = false;
        }
    }
    out
}

fn sorted_array(value: &Value) -> Value {
    let mut values = array(value).iter().map(canonical_value).collect::<Vec<_>>();
    values.sort_by_key(|value| value.to_string());
    Value::Array(values)
}

fn object(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value
        .as_object()
        .and_then(|object| object.get(key))
        .unwrap_or(&Value::Null)
}

fn array(value: &Value) -> &[Value] {
    value.as_array().map(Vec::as_slice).unwrap_or(&[])
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        _ => value.to_string(),
    }
}

fn canonicalize_derived_state_refs(val: &Value) -> Value {
    match val {
        Value::Array(arr) => {
            Value::Array(arr.iter().map(|item| {
                match item {
                    Value::Object(obj) => {
                        let mut new_obj = Map::new();
                        for (k, v) in obj {
                            if k == "derived" || k == "source" {
                                if let Value::String(s) = v {
                                    let mut text = s.clone();
                                    for prefix in &["$this->", "this->", "self->", "this.", "self.", "@"] {
                                        if let Some(stripped) = text.strip_prefix(prefix) {
                                            text = stripped.to_string();
                                            break;
                                        }
                                    }
                                    new_obj.insert(k.clone(), Value::String(format!("self.{}", text)));
                                } else {
                                    new_obj.insert(k.clone(), v.clone());
                                }
                            } else {
                                new_obj.insert(k.clone(), v.clone());
                            }
                        }
                        Value::Object(new_obj)
                    }
                    _ => item.clone(),
                }
            }).collect())
        }
        _ => val.clone(),
    }
}
