//! Emitting the runtime SCIP index for a collect, and attesting what it covers.
//!
//! The overlay itself is `runtime-scip`; this decides what it should be run
//! over and records what the answer was derived from. Both are questions about
//! a directory of artifacts, not about any interpreter.

use anyhow::{Context, Result};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

pub const SCHEMA_VERSION: i64 = 1;
pub const TOOL_NAME: &str = "nil-kill-runtime";
pub const TOOL_VERSION: &str = "2";
pub const AUTHORITY: &str = "runtime-modeled-world";

fn authority_argument() -> String {
    format!("--fact-mine-index-authority={AUTHORITY}")
}

/// An index over nothing, so a collect that observed nothing still writes a
/// well-formed answer rather than no answer.
pub fn empty_index(root: &Path) -> Value {
    json!({
        "metadata": {
            "version": 0,
            "toolInfo": {"name": TOOL_NAME, "version": TOOL_VERSION, "arguments": [authority_argument()]},
            "projectRoot": project_root_uri(root),
            "textDocumentEncoding": 1,
        },
        "documents": [],
        "externalSymbols": [],
        "_runtimeEvidence": {
            "schema": "factmine.runtime.v1",
            "observedCallSites": 0,
            "inferredCallSites": 0,
            "typedReceivers": 0,
            "emittedOccurrences": 0,
        },
    })
}

fn project_root_uri(root: &Path) -> String {
    let mut encoded = String::from("file://");
    for byte in root.to_string_lossy().bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn under_root(path: &Path, root: &Path) -> bool {
    path.starts_with(root) && path != root
}

/// A runtime call can cross from the selected product source into a sibling
/// workspace implementation. Its declaration identity is already attested by
/// the event, but FactMine cannot emit a definition occurrence unless that file
/// is in the source set. Only workspace-owned files under this root qualify:
/// dependency implementations stay external.
fn workspace_callee_source(event: &Value, root: &Path) -> Option<PathBuf> {
    let callee = event.get("callee")?;
    if callee["package_manager"].as_str() != Some("workspace") {
        return None;
    }
    let path = callee["path"].as_str().filter(|path| !path.is_empty())?;
    let absolute = root.join(path);
    (under_root(&absolute, root) && absolute.is_file()).then_some(absolute)
}

fn evidence_workspace_sources(evidence: &Value, root: &Path) -> Vec<PathBuf> {
    evidence["anchors"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|anchor| anchor["executions"].as_array().cloned().unwrap_or_default())
        .filter_map(|bucket| {
            let target = bucket.get("target")?;
            if target["source_role"].as_str() != Some("PRODUCTION")
                || target["package_manager"].as_str() != Some("workspace")
            {
                return None;
            }
            let relative = target["definition"]["relative_path"]
                .as_str()
                .filter(|path| !path.is_empty())?;
            let absolute = root.join(relative);
            (under_root(&absolute, root) && absolute.is_file()).then_some(absolute)
        })
        .collect()
}

/// The files the overlay should run over.
pub fn runtime_sources(
    files: &[PathBuf],
    events: &[Value],
    evidence: &Value,
    plan: &Value,
    root: &Path,
) -> Vec<PathBuf> {
    let mut sources: Vec<PathBuf> =
        files.iter().map(|path| root.join(path)).collect();
    let documents = plan["documents"].as_array().cloned().unwrap_or_default();
    if sources.is_empty() {
        sources.extend(
            events
                .iter()
                .filter_map(|event| event["callsite"]["path"].as_str())
                .map(|path| root.join(path)),
        );
        sources.extend(
            documents
                .iter()
                .filter_map(|document| document["relative_path"].as_str())
                .map(|path| root.join(path)),
        );
    }
    sources.extend(events.iter().filter_map(|event| workspace_callee_source(event, root)));
    sources.extend(evidence_workspace_sources(evidence, root));

    // Only files a traced language could have produced.
    let mut extensions = BTreeSet::new();
    for language in events
        .iter()
        .filter_map(|event| event["language"].as_str())
        .chain(documents.iter().filter_map(|document| document["language"].as_str()))
    {
        if language == "ruby" {
            extensions.insert("rb");
        }
    }
    let mut selected = sources
        .into_iter()
        .filter(|path| path.is_file())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extensions.contains(extension))
        })
        .collect::<Vec<_>>();
    selected.sort();
    selected.dedup();
    selected
}

/// What the index covers and what it was derived from, so a later reader can
/// tell whether it still applies.
pub fn attestation(
    events: &[Value],
    documents: usize,
    invalid_events: usize,
    inferred_events: i64,
    excluded_events: usize,
    evidence_runs: &[String],
    evidence_environment: &BTreeMap<String, String>,
    environment: &BTreeMap<String, String>,
    runtime_claims: &BTreeMap<String, String>,
) -> Value {
    let mut runs = evidence_runs
        .iter()
        .filter(|id| !id.is_empty())
        .cloned()
        .collect::<Vec<_>>();
    runs.sort();
    runs.dedup();

    let mut claims: BTreeMap<String, String> = BTreeMap::new();
    claims.insert("runtime_scip.authority".into(), AUTHORITY.into());
    claims.insert(
        "runtime_scip.closure_assumption".into(),
        "observed call targets exhaust the attested workload and runtime environment".into(),
    );
    claims.insert("runtime_scip.producer".into(), format!("{TOOL_NAME}@{TOOL_VERSION}"));
    claims.insert("runtime_scip.event_schema".into(), SCHEMA_VERSION.to_string());
    claims.insert("runtime_scip.event_count".into(), events.len().to_string());
    claims.insert("runtime_scip.document_count".into(), documents.to_string());
    claims.insert("runtime_scip.invalid_event_count".into(), invalid_events.to_string());
    claims.insert(
        "runtime_scip.excluded_nonproduction_event_count".into(),
        excluded_events.to_string(),
    );
    claims.insert("runtime_scip.inferred_event_count".into(), inferred_events.to_string());
    claims.insert(
        "runtime_scip.inference".into(),
        "FactMine normalized CFG/DFG overlaid with observed runtime value domains".into(),
    );
    claims.insert("runtime_scip.run_ids_sha256".into(), digest(&runs.join("\n")));
    claims.extend(evidence_environment.clone());
    claims.extend(runtime_claims.clone());
    claims.extend(environment.clone());

    json!({
        "schema": "fact-mine.semantic-environment.v1",
        "claims": claims.into_iter().map(|(key, value)| (key, json!(value))).collect::<Map<_, _>>(),
    })
}

fn digest(value: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("sha256:{:x}", Sha256::digest(value.as_bytes()))
}

/// Everything a collect's SCIP stage produces.
pub struct Emitted {
    pub index: Value,
    pub attestation: Value,
    pub events: usize,
    pub invalid_events: usize,
    pub inferred_events: i64,
    pub documents: usize,
    pub occurrences: usize,
    /// Anchors whose executions carried an observed value, as against a target.
    pub observations: usize,
}

pub fn emit(
    root: &Path,
    runtime_dir: &Path,
    evidence_path: &Path,
    plan: &Value,
    files: &[PathBuf],
    environment: &BTreeMap<String, String>,
    overlay: impl FnOnce(&Path, &[PathBuf]) -> Result<Value>,
) -> Result<Emitted> {
    let rows = crate::trace_document::read_shard(runtime_dir);
    let raw = crate::runtime_protocol::read_json(evidence_path)
        .with_context(|| format!("unreadable evidence {}", evidence_path.display()))?;
    let evidence: Value = serde_json::from_str(&raw)?;

    let sources = runtime_sources(files, &rows.calls, &evidence, plan, root);
    let index =
        if sources.is_empty() { empty_index(root) } else { overlay(evidence_path, &sources)? };

    let documents = index["documents"].as_array().cloned().unwrap_or_default();
    let inferred_events = index["_runtimeEvidence"]["inferredCallSites"].as_i64().unwrap_or(0);

    let runs = evidence["runs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|run| run["id"].as_str().map(str::to_string))
        .collect::<Vec<_>>();
    let evidence_environment = evidence["environment"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|claim| {
            Some((claim["key"].as_str()?.to_string(), claim["value"].as_str()?.to_string()))
        })
        .collect::<BTreeMap<_, _>>();

    // The claims the traced runtime made about itself, from the document that
    // made them, so the attestation says what observed rather than what emitted.
    let (runtime, _) = crate::trace_document::runtime_of(runtime_dir)?;
    let runtime_claims = crate::trace_document::environment_claims(&runtime, root)
        .into_iter()
        .collect::<BTreeMap<_, _>>();

    let counted = |field: &str| {
        evidence["anchors"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|anchor| {
                anchor["executions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|bucket| bucket.get(field).is_some_and(|value| !value.is_null()))
            })
            .count()
    };
    Ok(Emitted {
        observations: counted("value"),
        occurrences: documents
            .iter()
            .map(|document| document["occurrences"].as_array().map_or(0, Vec::len))
            .sum(),
        documents: documents.len(),
        attestation: attestation(
            &rows.calls,
            documents.len(),
            rows.invalid_calls,
            inferred_events,
            0,
            &runs,
            &evidence_environment,
            environment,
            &runtime_claims,
        ),
        index,
        events: rows.calls.len(),
        invalid_events: rows.invalid_calls,
        inferred_events,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(callee_path: &str, package_manager: &str) -> Value {
        json!({
            "language": "ruby",
            "callsite": {"path": "worker.rb", "line": 3},
            "callee": {"path": callee_path, "package_manager": package_manager},
        })
    }

    /// A call can cross from the selected source into a sibling workspace file.
    /// That declaration has to be in the source set or FactMine cannot emit a
    /// definition for it -- but a dependency's implementation stays external.
    #[test]
    fn trusted_workspace_declarations_are_included_and_dependencies_are_not() {
        let root = tempfile::tempdir().expect("tempdir");
        let root_path = root.path();
        let write = |relative: &str| {
            let path = root_path.join(relative);
            std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
            std::fs::write(&path, "# source\n").expect("write");
            path
        };
        let source = write("worker.rb");
        let workspace = write("tools/workspace_helper.rb");
        let dependency = write("vendor/dependency.rb");

        let selected = runtime_sources(
            &[source.clone()],
            &[
                event("tools/workspace_helper.rb", "workspace"),
                event("vendor/dependency.rb", "rubygems"),
            ],
            &json!({}),
            &json!({}),
            root_path,
        );

        // Sorted, so the set is stable whatever order the events arrived in.
        assert_eq!(selected, vec![workspace, source]);
        assert!(!selected.contains(&dependency));
    }

    /// Only files a traced language could have produced.
    #[test]
    fn a_file_no_traced_language_owns_is_left_out() {
        let root = tempfile::tempdir().expect("tempdir");
        let readme = root.path().join("README.md");
        std::fs::write(&readme, "# not source\n").expect("write");

        assert!(runtime_sources(
            &[readme],
            &[event("worker.rb", "workspace")],
            &json!({}),
            &json!({}),
            root.path()
        )
        .is_empty());
    }
}
