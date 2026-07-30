//! Join a runtime trace against a trace plan.
//!
//! A collector observes a run; it does not decide which planned anchor an
//! observation satisfies. That decision is this module's, so there is one
//! implementation of it rather than one per collector language. The input is
//! the language-neutral trace artifact a collector writes: normalized
//! observations and call rows, plus the execution tallies that separate "never
//! executed" from "executed but its value was not captured".

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use crate::runtime_protocol::{self, AnchorKind, TracePlan};

pub const TRACE_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
pub struct Trace {
    pub trace_version: u32,
    #[serde(default)]
    pub trace_plan_digest: String,
    #[serde(default)]
    pub run_ids: Vec<String>,
    #[serde(default)]
    pub observations: Vec<Observation>,
    #[serde(default)]
    pub calls: Vec<CallEntry>,
    #[serde(default)]
    pub executed_callsites: Vec<ExecutedCallsite>,
    #[serde(default)]
    pub exact_anchor_executions: Vec<ExactAnchorExecution>,
    #[serde(default)]
    pub function_entries: Vec<FunctionEntry>,
    #[serde(default)]
    pub coverage: Vec<CoverageRow>,
}

#[derive(Debug, Deserialize)]
pub struct Observation {
    pub kind: String,
    #[serde(default)]
    pub scope: Scope,
    #[serde(default)]
    pub slot: String,
    #[serde(default)]
    pub domain: serde_json::Value,
    #[serde(default = "one")]
    pub count: i64,
}

#[derive(Debug, Default, Deserialize)]
pub struct Scope {
    #[serde(default)]
    pub language: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub line: i64,
}

#[derive(Debug, Deserialize)]
pub struct CallEntry {
    pub event: serde_json::Value,
    pub row: CallRow,
}

#[derive(Debug, Deserialize)]
pub struct CallRow {
    pub callsite: Callsite,
    #[serde(default)]
    pub receiver_domain: serde_json::Value,
    #[serde(default)]
    pub result_domain: serde_json::Value,
    #[serde(default)]
    pub result_truths: Vec<serde_json::Value>,
    #[serde(default)]
    pub target: serde_json::Value,
    #[serde(default)]
    pub receiver_source_role: Option<String>,
    #[serde(default = "one")]
    pub count: i64,
}

#[derive(Debug, Deserialize)]
pub struct Callsite {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub line: i64,
    #[serde(default)]
    pub selector: String,
    #[serde(default)]
    pub anchor_symbol: String,
}

#[derive(Debug, Deserialize)]
pub struct ExecutedCallsite {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub line: i64,
    #[serde(default)]
    pub selector: String,
}

#[derive(Debug, Deserialize)]
pub struct ExactAnchorExecution {
    pub symbol: String,
    #[serde(default = "one")]
    pub count: i64,
}

#[derive(Debug, Deserialize)]
pub struct FunctionEntry {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub line: i64,
}

#[derive(Debug, Deserialize)]
pub struct CoverageRow {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub lines: Vec<i64>,
}

fn one() -> i64 {
    1
}

/// A collector writes the plan inside an envelope alongside its own metadata,
/// so accept either the envelope or the bare plan.
pub fn read_plan(path: &Path) -> Result<TracePlan> {
    let raw = runtime_protocol::read_json(path)
        .with_context(|| format!("unreadable trace plan {}", path.display()))?;
    let value: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("invalid trace plan {}", path.display()))?;
    let inner = value
        .get("runtime_evidence")
        .cloned()
        .unwrap_or(value);
    runtime_protocol::parse_trace_plan_json(&serde_json::to_string(&inner)?)
        .with_context(|| format!("invalid trace plan {}", path.display()))
}

pub fn read_trace(path: &Path) -> Result<Trace> {
    let raw = runtime_protocol::read_json(path)
        .with_context(|| format!("unreadable runtime trace {}", path.display()))?;
    let trace: Trace = serde_json::from_str(&raw)
        .with_context(|| format!("invalid runtime trace {}", path.display()))?;
    if trace.trace_version != TRACE_VERSION {
        bail!(
            "unsupported runtime trace version {} (expected {})",
            trace.trace_version,
            TRACE_VERSION
        );
    }
    Ok(trace)
}

/// A path as the plan names it: relative to the analyzed root, forward slashes.
fn canonical_path(root: &Path, path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    let candidate = Path::new(path);
    let absolute = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    match absolute.strip_prefix(root) {
        Ok(relative) => relative.to_string_lossy().replace('\\', "/"),
        Err(_) => path.replace('\\', "/"),
    }
}

fn line_in_range(range: &runtime_protocol::SourceRange, one_based: i64) -> bool {
    let line = one_based - 1;
    i64::from(range.start_line) <= line && line <= i64::from(range.end_line)
}

fn anchor_kind(anchor: &runtime_protocol::SourceAnchor) -> AnchorKind {
    anchor.kind.enum_value_or_default()
}

fn is_call_anchor(kind: AnchorKind) -> bool {
    !matches!(
        kind,
        AnchorKind::FUNCTION_ENTRY
            | AnchorKind::FUNCTION_RETURN
            | AnchorKind::STATE_READ
            | AnchorKind::STATE_WRITE
    )
}

/// The observation kind a non-call anchor is satisfied by.
fn observation_kind(kind: AnchorKind) -> Option<&'static str> {
    match kind {
        AnchorKind::FUNCTION_ENTRY => Some("parameter"),
        AnchorKind::FUNCTION_RETURN => Some("return"),
        AnchorKind::STATE_READ | AnchorKind::STATE_WRITE => Some("state"),
        _ => None,
    }
}

pub struct Join<'a> {
    root: &'a Path,
    trace: &'a Trace,
    observations_by_kind_path: HashMap<(String, String), Vec<usize>>,
    calls_by_path_selector: HashMap<(String, String), Vec<usize>>,
    executed_by_path_selector: HashMap<(String, String), Vec<i64>>,
    exact_symbols: HashSet<String>,
    exact_counts: HashMap<String, i64>,
    entries_by_path: HashMap<String, Vec<i64>>,
    covered_by_path: HashMap<String, HashSet<i64>>,
}

impl<'a> Join<'a> {
    pub fn new(root: &'a Path, trace: &'a Trace) -> Self {
        let mut observations_by_kind_path: HashMap<(String, String), Vec<usize>> = HashMap::new();
        for (index, row) in trace.observations.iter().enumerate() {
            observations_by_kind_path
                .entry((row.kind.clone(), canonical_path(root, &row.scope.path)))
                .or_default()
                .push(index);
        }
        let mut calls_by_path_selector: HashMap<(String, String), Vec<usize>> = HashMap::new();
        for (index, entry) in trace.calls.iter().enumerate() {
            calls_by_path_selector
                .entry((
                    canonical_path(root, &entry.row.callsite.path),
                    entry.row.callsite.selector.clone(),
                ))
                .or_default()
                .push(index);
        }
        let mut executed_by_path_selector: HashMap<(String, String), Vec<i64>> = HashMap::new();
        for row in &trace.executed_callsites {
            executed_by_path_selector
                .entry((canonical_path(root, &row.path), row.selector.clone()))
                .or_default()
                .push(row.line);
        }
        let mut exact_symbols = HashSet::new();
        let mut exact_counts: HashMap<String, i64> = HashMap::new();
        for row in &trace.exact_anchor_executions {
            exact_symbols.insert(row.symbol.clone());
            *exact_counts.entry(row.symbol.clone()).or_insert(0) += row.count.max(0);
        }
        let mut entries_by_path: HashMap<String, Vec<i64>> = HashMap::new();
        for row in &trace.function_entries {
            entries_by_path
                .entry(canonical_path(root, &row.path))
                .or_default()
                .push(row.line);
        }
        let mut covered_by_path: HashMap<String, HashSet<i64>> = HashMap::new();
        for row in &trace.coverage {
            covered_by_path
                .entry(canonical_path(root, &row.path))
                .or_default()
                .extend(row.lines.iter().copied());
        }
        Self {
            root,
            trace,
            observations_by_kind_path,
            calls_by_path_selector,
            executed_by_path_selector,
            exact_symbols,
            exact_counts,
            entries_by_path,
            covered_by_path,
        }
    }

    /// Observations at one normalized storage boundary. More than one row there
    /// is additive runs, not ambiguous source identity, so this never reports
    /// ambiguity.
    fn matching_observations(
        &self,
        anchor: &runtime_protocol::SourceAnchor,
        kind: &str,
    ) -> Vec<usize> {
        let range = anchor.range.as_ref();
        self.observations_by_kind_path
            .get(&(kind.to_string(), anchor.relative_path.clone()))
            .map(|rows| {
                rows.iter()
                    .copied()
                    .filter(|index| {
                        let row = &self.trace.observations[*index];
                        range.is_some_and(|r| line_in_range(r, row.scope.line))
                            && (!matches!(kind, "parameter" | "state")
                                || row.slot == anchor.display_name)
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Exact anchor identity dominates the collector's informational source
    /// line: a multiline call may be reported at its receiver line while the
    /// plan anchors the selector line, and the exact binding already proved
    /// which planned anchor ran. Without one, never guess between two identical
    /// selectors on the same line.
    fn matching_calls(&self, anchor: &runtime_protocol::SourceAnchor) -> (Vec<usize>, bool) {
        let key = (anchor.relative_path.clone(), anchor.display_name.clone());
        let candidates = match self.calls_by_path_selector.get(&key) {
            Some(rows) => rows,
            None => return (Vec::new(), false),
        };
        let exact: Vec<usize> = candidates
            .iter()
            .copied()
            .filter(|index| self.trace.calls[*index].row.callsite.anchor_symbol == anchor.symbol)
            .collect();
        if !exact.is_empty() {
            return (exact, false);
        }
        let range = anchor.range.as_ref();
        let loose: Vec<usize> = candidates
            .iter()
            .copied()
            .filter(|index| {
                let callsite = &self.trace.calls[*index].row.callsite;
                callsite.anchor_symbol.is_empty()
                    && range.is_some_and(|r| line_in_range(r, callsite.line))
            })
            .collect();
        (loose, false)
    }

    /// Whether the anchor ran at all, which is what separates "no execution in
    /// the modeled runs" from "executed but the collector captured no value".
    fn anchor_executed(
        &self,
        anchor: &runtime_protocol::SourceAnchor,
        has_execution_range: bool,
    ) -> bool {
        let range = anchor.range.as_ref();
        if is_call_anchor(anchor_kind(anchor)) {
            if has_execution_range {
                return self.exact_symbols.contains(&anchor.symbol);
            }
            let observed = self
                .executed_by_path_selector
                .get(&(anchor.relative_path.clone(), anchor.display_name.clone()))
                .is_some_and(|lines| {
                    lines
                        .iter()
                        .any(|line| range.is_some_and(|r| line_in_range(r, *line)))
                });
            if observed {
                return true;
            }
            // Line coverage is a raw execution fact. It cannot prove which
            // same-line call ran, so it is used only to fail closed.
            return self
                .covered_by_path
                .get(&anchor.relative_path)
                .is_some_and(|lines| {
                    lines
                        .iter()
                        .any(|line| range.is_some_and(|r| line_in_range(r, *line)))
                });
        }
        if anchor_kind(anchor) == AnchorKind::FUNCTION_RETURN {
            // A return anchor is reached only on a normal return, and a
            // conforming collector reports every returned value including null
            // and false. No matching observation therefore means this boundary
            // did not execute -- every invocation raised, say -- rather than
            // that it executed uncaptured.
            return false;
        }
        self.entries_by_path
            .get(&anchor.relative_path)
            .is_some_and(|lines| {
                lines
                    .iter()
                    .any(|line| range.is_some_and(|r| line_in_range(r, *line)))
            })
    }

    pub fn exact_count(&self, symbol: &str) -> i64 {
        self.exact_counts.get(symbol).copied().unwrap_or(0)
    }

    pub fn root(&self) -> &Path {
        self.root
    }
}

/// A domain carries a value only when it names at least one type; a collector
/// that saw nothing contributes no alternative and so no bucket field.
fn has_types(domain: &serde_json::Value) -> bool {
    domain
        .get("types")
        .and_then(|types| types.as_array())
        .is_some_and(|types| {
            types
                .iter()
                .any(|entry| entry.as_str().is_some_and(|name| !name.is_empty()))
        })
}

/// The bucket fields one match would produce. A call whose receiver has no
/// observed type produces no bucket at all, exactly as the value case does.
fn bucket_fields(trace: &Trace, index: usize, is_call: bool) -> Option<Vec<&'static str>> {
    if !is_call {
        let row = &trace.observations[index];
        return has_types(&row.domain).then(|| vec!["value"]);
    }
    let row = &trace.calls[index].row;
    if !has_types(&row.receiver_domain) {
        return None;
    }
    let mut fields = vec!["receiver", "target"];
    if has_types(&row.result_domain) {
        fields.push("result");
    }
    let mut truths: Vec<&serde_json::Value> = Vec::new();
    for truth in &row.result_truths {
        if !truths.contains(&truth) {
            truths.push(truth);
        }
    }
    if truths.len() == 1 {
        fields.push("boolean_result");
    }
    Some(fields)
}

/// Which requested evidence kind each execution-bucket field satisfies.
pub fn evidence_field(kind: &str) -> Option<&'static str> {
    Some(match kind {
        "PARAMETER_VALUE" | "RETURN_VALUE" | "STATE_VALUE" => "value",
        "RECEIVER_VALUE" | "COLLECTION_VALUE" => "receiver",
        "CALL_TARGET" => "target",
        "RESULT_VALUE" => "result",
        "BOOLEAN_RESULT" => "boolean_result",
        _ => return None,
    })
}

/// Anchor-by-anchor capture status, in the plan's request order.
pub fn anchor_statuses(
    root: &Path,
    plan: &TracePlan,
    trace: &Trace,
) -> Result<Vec<(String, String, Vec<String>, i64)>> {
    let join = Join::new(root, trace);
    let mut out = Vec::with_capacity(plan.requests.len());
    for request in &plan.requests {
        let anchor = request
            .anchor
            .as_ref()
            .context("trace plan request has no anchor")?;
        let (matches, ambiguous) = match observation_kind(anchor_kind(anchor)) {
            Some(kind) => (join.matching_observations(anchor, kind), false),
            None => join.matching_calls(anchor),
        };
        let requested: Vec<String> = request
            .required
            .iter()
            .map(|kind| format!("{:?}", kind.enum_value_or_default()))
            .collect();
        let is_call = observation_kind(anchor_kind(anchor)).is_none();
        // A match that yields no bucket is not an execution: the collector saw
        // the call but captured nothing about it.
        let buckets: Vec<Vec<&'static str>> = if ambiguous {
            Vec::new()
        } else {
            matches
                .iter()
                .filter_map(|index| bucket_fields(trace, *index, is_call))
                .collect()
        };
        let kept: Vec<usize> = if ambiguous {
            Vec::new()
        } else {
            matches
                .iter()
                .copied()
                .filter(|index| bucket_fields(trace, *index, is_call).is_some())
                .collect()
        };
        let executed_without_capture =
            buckets.is_empty() && join.anchor_executed(anchor, request.execution_range.is_some());
        let complete_kinds: Vec<String> = if ambiguous || executed_without_capture {
            Vec::new()
        } else if buckets.is_empty() {
            // No execution in a modeled run is a complete (empty) observation
            // for every requested field.
            requested.clone()
        } else {
            requested
                .iter()
                .filter(|kind| {
                    evidence_field(kind).is_some_and(|field| {
                        buckets.iter().all(|fields| fields.contains(&field))
                    })
                })
                .cloned()
                .collect()
        };
        let status = if ambiguous {
            "PARTIAL"
        } else if buckets.is_empty() {
            if executed_without_capture {
                "NOT_INSTRUMENTED"
            } else {
                "NOT_EXECUTED"
            }
        } else if complete_kinds.len() != requested.len() {
            "PARTIAL"
        } else {
            "COMPLETE_FOR_RUNS"
        };
        let mut observed: i64 = kept
            .iter()
            .map(|index| {
                if is_call {
                    trace.calls[*index].row.count.max(1)
                } else {
                    trace.observations[*index].count.max(1)
                }
            })
            .sum();
        // Identity-only collection may retain one representative bucket while
        // the exact marker counted every execution. With one bucket there is no
        // distribution ambiguity, so its exact multiplicity is restored.
        let exact = join.exact_count(&anchor.symbol);
        if kept.len() == 1 && exact > observed {
            observed = exact;
        }
        out.push((
            anchor.symbol.clone(),
            status.to_string(),
            requested,
            observed,
        ));
    }
    Ok(out)
}

/// A stable summary of what the trace covers, keyed by capture status.
pub fn summarize(root: &Path, plan: &TracePlan, trace: &Trace) -> Result<BTreeMap<String, usize>> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for (_symbol, status, _requested, _observed) in anchor_statuses(root, plan, trace)? {
        *counts.entry(status).or_insert(0) += 1;
    }
    Ok(counts)
}
