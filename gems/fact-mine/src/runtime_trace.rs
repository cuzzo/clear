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
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
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
    #[serde(default)]
    pub environment: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct Observation {
    pub kind: String,
    /// The protocol value this observation contributes, already encoded by the
    /// collector because minting it needs that language's type-symbol rules.
    #[serde(default)]
    pub bucket: Option<serde_json::Value>,
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
    pub row: CallRow,
    #[serde(default)]
    pub bucket: Option<serde_json::Value>,
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
    // Function boundaries indexed by file. Resolving a target used to scan
    // every request, which is quadratic in the plan and was most of the join.
    function_anchors_by_path: HashMap<String, Vec<&'a runtime_protocol::SourceAnchor>>,
}

impl<'a> Join<'a> {
    pub fn new(root: &'a Path, plan: &'a TracePlan, trace: &'a Trace) -> Self {
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
        let mut function_anchors_by_path: HashMap<String, Vec<&runtime_protocol::SourceAnchor>> =
            HashMap::new();
        for request in &plan.requests {
            let Some(anchor) = request.anchor.as_ref() else {
                continue;
            };
            if matches!(
                anchor.kind.enum_value_or_default(),
                AnchorKind::FUNCTION_ENTRY | AnchorKind::FUNCTION_RETURN
            ) {
                function_anchors_by_path
                    .entry(anchor.relative_path.clone())
                    .or_default()
                    .push(anchor);
            }
        }
        Self {
            root,
            trace,
            function_anchors_by_path,
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

/// The bucket a match contributes, or nothing when the collector observed no
/// value for it -- which is not an execution, it is a call whose value was not
/// captured.
fn bucket_of(trace: &Trace, index: usize, is_call: bool) -> Option<&serde_json::Value> {
    if is_call {
        trace.calls[index].bucket.as_ref()
    } else {
        trace.observations[index].bucket.as_ref()
    }
}

fn bucket_has(bucket: &serde_json::Value, field: &str) -> bool {
    bucket.get(field).is_some_and(|value| !value.is_null())
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

impl Join<'_> {
    /// One anchor's evidence: which observations satisfy it, whether they
    /// covered everything the request asked for, and how many executions they
    /// account for.
    pub fn evaluate(
        &self,
        request: &runtime_protocol::EvidenceRequest,
        anchor: &runtime_protocol::SourceAnchor,
        run_ids: &[String],
    ) -> Result<serde_json::Value> {
        let trace = self.trace;
        let (matches, ambiguous) = match observation_kind(anchor_kind(anchor)) {
            Some(kind) => (self.matching_observations(anchor, kind), false),
            None => self.matching_calls(anchor),
        };
        let is_call = observation_kind(anchor_kind(anchor)).is_none();
        let requested: Vec<String> = request
            .required
            .iter()
            .map(|kind| format!("{:?}", kind.enum_value_or_default()))
            .collect();

        // A match that yields no bucket is not an execution: the collector saw
        // the call but captured nothing about it.
        let kept: Vec<serde_json::Value> = if ambiguous {
            Vec::new()
        } else {
            matches
                .iter()
                .filter_map(|index| bucket_of(trace, *index, is_call).cloned())
                .map(|mut bucket| {
                    self.resolve_target(&mut bucket);
                    bucket
                })
                .collect()
        };
        let kept: Vec<&serde_json::Value> = kept.iter().collect();
        let mut buckets = merge_identical_buckets(&kept, run_ids);

        let executed_without_capture = buckets.is_empty()
            && self.anchor_executed(anchor, request.execution_range.is_some());
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
                    evidence_field(kind)
                        .is_some_and(|field| buckets.iter().all(|b| bucket_has(b, field)))
                })
                .cloned()
                .collect()
        };
        let (status, reason) = if ambiguous {
            (
                "PARTIAL",
                Some("observed execution is preserved in a candidate correlation group"),
            )
        } else if buckets.is_empty() {
            if executed_without_capture {
                (
                    "NOT_INSTRUMENTED",
                    Some("anchor executed but the provider did not capture its requested value"),
                )
            } else {
                ("NOT_EXECUTED", Some("no matching execution in the modeled runs"))
            }
        } else if complete_kinds.len() != requested.len() {
            (
                "PARTIAL",
                Some("provider did not capture every value requested at this anchor"),
            )
        } else {
            ("COMPLETE_FOR_RUNS", None)
        };

        let mut observed: i64 = buckets
            .iter()
            .map(|b| b.get("count").and_then(|c| c.as_i64()).unwrap_or(1).max(1))
            .sum();
        // Identity-only collection may retain one representative bucket while
        // the exact marker counted every execution. With one bucket there is no
        // distribution ambiguity, so its exact multiplicity is restored.
        let exact = self.exact_count(&anchor.symbol);
        if buckets.len() == 1 && exact > observed {
            observed = exact;
            if let Some(object) = buckets[0].as_object_mut() {
                object.insert("count".into(), serde_json::json!(exact));
            }
        }

        let mut capture = serde_json::Map::new();
        capture.insert("status".into(), serde_json::json!(status));
        capture.insert("run_ids".into(), serde_json::json!(run_ids));
        capture.insert("observed_executions".into(), serde_json::json!(observed));
        capture.insert("dropped_executions".into(), serde_json::json!(0));
        if let Some(reason) = reason {
            capture.insert("reason".into(), serde_json::json!(reason));
        }
        capture.insert("complete_kinds".into(), serde_json::json!(complete_kinds));

        Ok(serde_json::json!({
            "anchor_symbol": anchor.symbol,
            "anchor_semantic_digest": base64_standard(&anchor.semantic_digest),
            "capture": capture,
            "executions": buckets,
        }))
    }
}

/// ProtoJSON encodes `bytes` as standard base64. Written out rather than taken
/// as a dependency: it is fifteen lines and the alphabet is fixed by the spec.
impl Join<'_> {
    /// A collector reports where a callee was declared; the plan says which
    /// function that is. Exactly one planned boundary at that declaration names
    /// it -- more than one is not a resolution -- and otherwise the raw locator
    /// is preserved so the consumer can bind it from source itself.
    fn resolve_target(&self, bucket: &mut serde_json::Value) {
        let Some(definition) = bucket.get("target_definition").cloned() else {
            return;
        };
        if let Some(object) = bucket.as_object_mut() {
            object.remove("target_definition");
        }
        if definition.is_null() {
            return;
        }
        let path = definition
            .get("path")
            .and_then(|p| p.as_str())
            .map(|p| canonical_path(self.root, p))
            .unwrap_or_default();
        let line = definition.get("line").and_then(|l| l.as_i64()).unwrap_or(0);

        let mut seen: Vec<&str> = Vec::new();
        let mut candidates: Vec<&runtime_protocol::SourceAnchor> = Vec::new();
        for anchor in self.function_anchors_by_path.get(&path).into_iter().flatten() {
            if !anchor.range.as_ref().is_some_and(|r| line_in_range(r, line)) {
                continue;
            }
            if seen.contains(&anchor.enclosing_symbol.as_str()) {
                continue;
            }
            seen.push(&anchor.enclosing_symbol);
            candidates.push(anchor);
        }

        let Some(target) = bucket.get_mut("target").and_then(|t| t.as_object_mut()) else {
            return;
        };
        if candidates.len() != 1 {
            if line <= 0 || path.is_empty() {
                return;
            }
            let symbol = target
                .get("symbol")
                .and_then(|s| s.as_str())
                .unwrap_or_default()
                .to_string();
            target.insert(
                "definition".into(),
                serde_json::json!({
                    "symbol": symbol,
                    "anchor_symbol": "",
                    "relative_path": path,
                    "range": {
                        "start_line": line - 1, "start_character": 0,
                        "end_line": line - 1, "end_character": 0,
                    },
                }),
            );
            return;
        }
        let anchor = candidates[0];
        let range = anchor.range.as_ref();
        target.insert(
            "symbol".into(),
            serde_json::json!(anchor.enclosing_symbol),
        );
        target.insert(
            "definition".into(),
            serde_json::json!({
                "symbol": anchor.enclosing_symbol,
                "anchor_symbol": anchor.symbol,
                "relative_path": anchor.relative_path,
                "range": {
                    "start_line": range.map_or(0, |r| r.start_line),
                    "start_character": range.map_or(0, |r| r.start_character),
                    "end_line": range.map_or(0, |r| r.end_line),
                    "end_character": range.map_or(0, |r| r.end_character),
                },
            }),
        );
    }
}

fn base64_standard(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(triple >> 18) as usize & 63] as char);
        out.push(ALPHABET[(triple >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[triple as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Buckets that differ only in how many executions they account for are one
/// observation seen repeatedly, not several.
fn merge_identical_buckets(
    buckets: &[&serde_json::Value],
    run_ids: &[String],
) -> Vec<serde_json::Value> {
    let mut order: Vec<String> = Vec::new();
    let mut merged: HashMap<String, serde_json::Value> = HashMap::new();
    for bucket in buckets {
        let mut owned = (*bucket).clone();
        if let Some(object) = owned.as_object_mut() {
            // A bucket with no run of its own belongs to the run being reported.
            let empty = object
                .get("provenance")
                .and_then(|p| p.get("run_id"))
                .and_then(|id| id.as_str())
                .is_none_or(|id| id.is_empty());
            if empty {
                if let Some(provenance) = object.get_mut("provenance").and_then(|p| p.as_object_mut())
                {
                    provenance.insert(
                        "run_id".into(),
                        serde_json::json!(run_ids.first().cloned().unwrap_or_default()),
                    );
                }
            }
        }
        let mut key_value = owned.clone();
        if let Some(object) = key_value.as_object_mut() {
            object.remove("count");
        }
        let key = serde_json::to_string(&key_value).unwrap_or_default();
        match merged.get_mut(&key) {
            Some(existing) => {
                let add = owned.get("count").and_then(|c| c.as_i64()).unwrap_or(1);
                let total = existing.get("count").and_then(|c| c.as_i64()).unwrap_or(1) + add;
                if let Some(object) = existing.as_object_mut() {
                    object.insert("count".into(), serde_json::json!(total));
                }
            }
            None => {
                order.push(key.clone());
                merged.insert(key, owned);
            }
        }
    }
    order
        .into_iter()
        .filter_map(|key| merged.remove(&key))
        .collect()
}

/// The evidence a trace supports, in the plan's request order.
///
/// Built as ProtoJSON and then round-tripped through the protocol message, so
/// the result is canonical by construction rather than by matching a producer's
/// formatting.
pub fn build_evidence(root: &Path, plan: &TracePlan, trace: &Trace) -> Result<String> {
    let join = Join::new(root, plan, trace);
    let mut run_ids: Vec<String> = trace
        .run_ids
        .iter()
        .filter(|id| !id.is_empty())
        .cloned()
        .collect();
    run_ids.sort();
    run_ids.dedup();
    if run_ids.is_empty() {
        run_ids.push("unidentified-run".to_string());
    }

    let mut anchors = Vec::with_capacity(plan.requests.len());
    for request in &plan.requests {
        let anchor = request
            .anchor
            .as_ref()
            .context("trace plan request has no anchor")?;
        let outcome = join.evaluate(request, anchor, &run_ids)?;
        // An anchor nothing was observed for is left out: absence already says
        // "not executed in these runs", and saying it explicitly for every
        // planned anchor is what made this document scale with the plan instead
        // of with the run.
        if !is_vacuous(&outcome) {
            anchors.push(outcome);
        }
    }

    let evidence = serde_json::json!({
        "protocol_version": 1,
        "producer": { "name": "nil-kill", "version": "1", "arguments": ["collect", "runtime-evidence"] },
        "authority": "MODELED_RUNS",
        "trace_plan_digest": trace.trace_plan_digest,
        "environment": trace.environment,
        "runs": run_ids.iter().map(|id| serde_json::json!({ "id": id, "status": "SUCCEEDED" }))
            .collect::<Vec<_>>(),
        "anchors": anchors,
        "correlations": Vec::<serde_json::Value>::new(),
    });
    let canonical = runtime_protocol::parse_runtime_evidence_json(&serde_json::to_string(&evidence)?)
        .context("joined evidence is not canonical ProtoJSON")?;
    runtime_protocol::to_json_with_defaults(&canonical)
}

/// True when an entry carries nothing a consumer could not infer from its
/// absence: no executions, and the status that absence itself means.
fn is_vacuous(anchor: &serde_json::Value) -> bool {
    let empty = anchor
        .get("executions")
        .and_then(|e| e.as_array())
        .is_none_or(|e| e.is_empty());
    let status = anchor
        .get("capture")
        .and_then(|c| c.get("status"))
        .and_then(|s| s.as_str())
        .unwrap_or_default();
    empty && status == "NOT_EXECUTED"
}


/// Combine the evidence of several shards into one document.
///
/// A shard contributes what it observed, so shards legitimately cover different
/// anchors and a symbol is merged from the shards that saw it. The rules are the
/// collector's, ported rather than reinvented: the worst status wins, run ids
/// union, execution counts add, and a kind is complete only if every
/// contributing shard found it complete.
pub fn merge_evidence(documents: &[serde_json::Value]) -> Result<serde_json::Value> {
    let mut by_symbol: BTreeMap<String, Vec<&serde_json::Value>> = BTreeMap::new();
    for document in documents {
        let anchors = document
            .get("anchors")
            .and_then(|a| a.as_array())
            .map(|a| a.as_slice())
            .unwrap_or(&[]);
        let mut seen: HashSet<&str> = HashSet::new();
        for anchor in anchors {
            let symbol = anchor
                .get("anchor_symbol")
                .and_then(|s| s.as_str())
                .context("merged anchor has no symbol")?;
            if !seen.insert(symbol) {
                bail!("runtime evidence shard contains duplicate anchors");
            }
            by_symbol.entry(symbol.to_string()).or_default().push(anchor);
        }
    }

    let mut anchors = Vec::with_capacity(by_symbol.len());
    for (symbol, rows) in &by_symbol {
        let digests: BTreeSet<&str> = rows
            .iter()
            .filter_map(|row| row.get("anchor_semantic_digest").and_then(|d| d.as_str()))
            .collect();
        if digests.len() > 1 {
            bail!("conflicting semantic digest for {symbol}");
        }
        let executions: Vec<&serde_json::Value> = rows
            .iter()
            .filter_map(|row| row.get("executions").and_then(|e| e.as_array()))
            .flatten()
            .collect();
        let captures: Vec<&serde_json::Value> =
            rows.iter().filter_map(|row| row.get("capture")).collect();

        let status = merged_status(&captures, &executions);
        let mut run_ids: Vec<String> = captures
            .iter()
            .filter_map(|c| c.get("run_ids").and_then(|r| r.as_array()))
            .flatten()
            .filter_map(|id| id.as_str().map(str::to_string))
            .collect();
        run_ids.sort();
        run_ids.dedup();

        let observed: i64 = executions
            .iter()
            .map(|b| bucket_count(b))
            .sum();
        let dropped: i64 = captures
            .iter()
            .map(|c| {
                c.get("dropped_executions")
                    .map(json_i64)
                    .unwrap_or(0)
            })
            .sum();

        // A kind is complete only where every contributing shard found it so.
        let mut complete: Option<BTreeSet<String>> = None;
        for capture in &captures {
            let kinds: BTreeSet<String> = capture
                .get("complete_kinds")
                .and_then(|k| k.as_array())
                .map(|k| {
                    k.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            complete = Some(match complete {
                None => kinds,
                Some(existing) => existing.intersection(&kinds).cloned().collect(),
            });
        }
        let complete_kinds: Vec<String> = complete.unwrap_or_default().into_iter().collect();

        let mut capture = serde_json::Map::new();
        capture.insert("status".into(), serde_json::json!(status));
        capture.insert("run_ids".into(), serde_json::json!(run_ids));
        capture.insert("observed_executions".into(), serde_json::json!(observed));
        capture.insert("dropped_executions".into(), serde_json::json!(dropped));
        let reason = merged_reason(&captures, status);
        if !reason.is_empty() {
            capture.insert("reason".into(), serde_json::json!(reason));
        }
        capture.insert("complete_kinds".into(), serde_json::json!(complete_kinds));

        anchors.push(serde_json::json!({
            "anchor_symbol": symbol,
            "anchor_semantic_digest": digests.iter().next().copied().unwrap_or_default(),
            "capture": capture,
            "executions": merge_buckets(&executions),
        }));
    }

    let first = documents.first().context("no evidence to merge")?;
    let mut runs: Vec<serde_json::Value> = documents
        .iter()
        .filter_map(|d| d.get("runs").and_then(|r| r.as_array()))
        .flatten()
        .cloned()
        .collect();
    runs.sort_by_key(|run| {
        run.get("id")
            .and_then(|id| id.as_str())
            .unwrap_or_default()
            .to_string()
    });
    runs.dedup_by_key(|run| {
        run.get("id")
            .and_then(|id| id.as_str())
            .unwrap_or_default()
            .to_string()
    });

    let mut environment: BTreeMap<String, String> = BTreeMap::new();
    for document in documents {
        for claim in document
            .get("environment")
            .and_then(|e| e.as_array())
            .map(|e| e.as_slice())
            .unwrap_or(&[])
        {
            let key = claim.get("key").and_then(|k| k.as_str()).unwrap_or_default();
            let value = claim
                .get("value")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            if let Some(existing) = environment.get(key) {
                if existing != value {
                    bail!("conflicting runtime environment claim {key}");
                }
            }
            environment.insert(key.to_string(), value.to_string());
        }
    }

    Ok(serde_json::json!({
        "protocol_version": 1,
        "producer": first.get("producer").cloned().unwrap_or(serde_json::json!({})),
        "authority": "MODELED_RUNS",
        "trace_plan_digest": first.get("trace_plan_digest").cloned().unwrap_or(serde_json::json!("")),
        "environment": environment.into_iter()
            .map(|(key, value)| serde_json::json!({ "key": key, "value": value }))
            .collect::<Vec<_>>(),
        "runs": runs,
        "anchors": anchors,
        "correlations": Vec::<serde_json::Value>::new(),
    }))
}

fn json_i64(value: &serde_json::Value) -> i64 {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0)
}

fn bucket_count(bucket: &serde_json::Value) -> i64 {
    bucket.get("count").map(json_i64).unwrap_or(1)
}

/// The worst outcome any shard saw is the outcome for the whole.
fn merged_status(captures: &[&serde_json::Value], executions: &[&serde_json::Value]) -> &'static str {
    let statuses: Vec<&str> = captures
        .iter()
        .filter_map(|c| c.get("status").and_then(|s| s.as_str()))
        .collect();
    if statuses.contains(&"FAILED_CAPTURE") {
        return "FAILED_CAPTURE";
    }
    if statuses.contains(&"STALE") {
        return "STALE";
    }
    if statuses
        .iter()
        .any(|s| matches!(*s, "PARTIAL" | "NOT_INSTRUMENTED" | "UNSUPPORTED"))
    {
        return "PARTIAL";
    }
    if executions.is_empty() {
        return "NOT_EXECUTED";
    }
    "COMPLETE_FOR_RUNS"
}

fn merged_reason(captures: &[&serde_json::Value], status: &str) -> String {
    if status == "COMPLETE_FOR_RUNS" {
        return String::new();
    }
    let interesting: Vec<&&serde_json::Value> = captures
        .iter()
        .filter(|c| {
            !matches!(
                c.get("status").and_then(|s| s.as_str()).unwrap_or_default(),
                "COMPLETE_FOR_RUNS" | "NOT_EXECUTED"
            )
        })
        .collect();
    let source: Vec<&&serde_json::Value> = if interesting.is_empty() {
        captures.iter().collect()
    } else {
        interesting
    };
    let reasons: BTreeSet<&str> = source
        .iter()
        .filter_map(|c| c.get("reason").and_then(|r| r.as_str()))
        .filter(|r| !r.is_empty())
        .collect();
    reasons.into_iter().collect::<Vec<_>>().join("; ")
}

/// Buckets differing only in count are one observation seen repeatedly.
fn merge_buckets(rows: &[&serde_json::Value]) -> Vec<serde_json::Value> {
    let mut merged: BTreeMap<String, serde_json::Value> = BTreeMap::new();
    for row in rows {
        let mut key_value = (*row).clone();
        if let Some(object) = key_value.as_object_mut() {
            object.remove("count");
        }
        let key = serde_json::to_string(&key_value).unwrap_or_default();
        match merged.get_mut(&key) {
            Some(existing) => {
                let total = bucket_count(existing) + bucket_count(row);
                if let Some(object) = existing.as_object_mut() {
                    object.insert("count".into(), serde_json::json!(total));
                }
            }
            None => {
                merged.insert(key, (*row).clone());
            }
        }
    }
    let mut out: Vec<serde_json::Value> = merged.into_values().collect();
    out.sort_by_key(|row| serde_json::to_string(row).unwrap_or_default());
    out
}

/// Write a document where the collector expects it, gzipped when named so.
pub fn write_json(path: &Path, contents: &str) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    if path.extension().is_some_and(|ext| ext == "gz") {
        let file = std::fs::File::create(path)
            .with_context(|| format!("failed to write {}", path.display()))?;
        let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        encoder.write_all(contents.as_bytes())?;
        encoder.finish()?;
    } else {
        std::fs::write(path, contents)
            .with_context(|| format!("failed to write {}", path.display()))?;
    }
    Ok(())
}

/// A stable summary of what the trace covers, keyed by capture status.
pub fn summarize(root: &Path, plan: &TracePlan, trace: &Trace) -> Result<BTreeMap<String, usize>> {
    let join = Join::new(root, plan, trace);
    let run_ids = vec!["summary".to_string()];
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for request in &plan.requests {
        let anchor = request
            .anchor
            .as_ref()
            .context("trace plan request has no anchor")?;
        let row = join.evaluate(request, anchor, &run_ids)?;
        let status = row
            .get("capture")
            .and_then(|capture| capture.get("status"))
            .and_then(|status| status.as_str())
            .unwrap_or("UNKNOWN")
            .to_string();
        *counts.entry(status).or_insert(0) += 1;
    }
    Ok(counts)
}
