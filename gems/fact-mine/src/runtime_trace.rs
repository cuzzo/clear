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
/// Works on protocol messages rather than JSON. The shards arrive as messages
/// and the result leaves as one, so nothing is encoded, parsed and re-encoded
/// in between -- that round trip was three passes over tens of megabytes and
/// most of what the join cost.
///
/// A shard contributes what it observed, so shards legitimately cover different
/// anchors and a symbol is merged from the shards that saw it. The rules are the
/// collector's, ported rather than reinvented: the worst status wins, run ids
/// union, execution counts add, and a kind is complete only if every
/// contributing shard found it complete.
pub fn merge_evidence(
    documents: &[runtime_protocol::RuntimeEvidence],
) -> Result<runtime_protocol::RuntimeEvidence> {
    use runtime_protocol::{AnchorEvidence, CaptureSummary, CaptureStatus};

    let first = documents.first().context("no evidence to merge")?;
    let mut order: Vec<String> = Vec::new();
    let mut by_symbol: BTreeMap<String, Vec<&AnchorEvidence>> = BTreeMap::new();
    for document in documents {
        let mut seen: HashSet<&str> = HashSet::new();
        for anchor in &document.anchors {
            if !seen.insert(anchor.anchor_symbol.as_str()) {
                bail!("runtime evidence shard contains duplicate anchors");
            }
            let entry = by_symbol.entry(anchor.anchor_symbol.clone()).or_default();
            if entry.is_empty() {
                order.push(anchor.anchor_symbol.clone());
            }
            entry.push(anchor);
        }
    }

    let mut anchors = Vec::with_capacity(by_symbol.len());
    for (symbol, rows) in &by_symbol {
        let digests: BTreeSet<&[u8]> = rows
            .iter()
            .map(|row| row.anchor_semantic_digest.as_slice())
            .collect();
        if digests.len() > 1 {
            bail!("conflicting semantic digest for {symbol}");
        }
        let executions: Vec<&runtime_protocol::ExecutionBucket> =
            rows.iter().flat_map(|row| row.executions.iter()).collect();
        let captures: Vec<&CaptureSummary> =
            rows.iter().filter_map(|row| row.capture.as_ref()).collect();

        let mut run_ids: Vec<String> = captures
            .iter()
            .flat_map(|capture| capture.run_ids.iter().cloned())
            .collect();
        run_ids.sort();
        run_ids.dedup();

        // A kind is complete only where every contributing shard found it so.
        let mut complete: Option<BTreeSet<i32>> = None;
        for capture in &captures {
            let kinds: BTreeSet<i32> = capture
                .complete_kinds
                .iter()
                .map(|kind| kind.value())
                .collect();
            complete = Some(match complete {
                None => kinds,
                Some(existing) => existing.intersection(&kinds).copied().collect(),
            });
        }

        let status = merged_status(&captures, &executions);
        let merged_executions = merge_buckets(&executions);
        let mut capture = CaptureSummary::new();
        capture.status = protobuf::EnumOrUnknown::new(status);
        capture.run_ids = run_ids;
        capture.observed_executions = merged_executions.iter().map(|b| b.count).sum();
        capture.dropped_executions = captures.iter().map(|c| c.dropped_executions).sum();
        capture.reason = merged_reason(&captures, status);
        // Sorted by name, not by enum value: the order is what a reader compares
        // against, and the collector has always sorted these alphabetically.
        let mut kinds: Vec<protobuf::EnumOrUnknown<runtime_protocol::EvidenceKind>> = complete
            .unwrap_or_default()
            .into_iter()
            .map(protobuf::EnumOrUnknown::from_i32)
            .collect();
        kinds.sort_by_key(|kind| format!("{:?}", kind.enum_value_or_default()));
        capture.complete_kinds = kinds;

        let mut anchor = AnchorEvidence::new();
        anchor.anchor_symbol = symbol.clone();
        anchor.anchor_semantic_digest = rows[0].anchor_semantic_digest.clone();
        anchor.capture = protobuf::MessageField::some(capture);
        anchor.executions = merged_executions;
        anchors.push(anchor);
    }

    let mut runs: Vec<runtime_protocol::Run> = documents
        .iter()
        .flat_map(|d| d.runs.iter().cloned())
        .collect();
    runs.sort_by(|a, b| a.id.cmp(&b.id));
    runs.dedup_by(|a, b| a.id == b.id);

    let mut environment: BTreeMap<String, String> = BTreeMap::new();
    for document in documents {
        for claim in &document.environment {
            if let Some(existing) = environment.get(&claim.key) {
                if *existing != claim.value {
                    bail!("conflicting runtime environment claim {}", claim.key);
                }
            }
            environment.insert(claim.key.clone(), claim.value.clone());
        }
    }

    let mut merged = runtime_protocol::RuntimeEvidence::new();
    merged.protocol_version = runtime_protocol::PROTOCOL_VERSION;
    merged.producer = first.producer.clone();
    merged.authority = first.authority;
    merged.trace_plan_digest = first.trace_plan_digest.clone();
    merged.environment = environment
        .into_iter()
        .map(|(key, value)| {
            let mut claim = runtime_protocol::EnvironmentClaim::new();
            claim.key = key;
            claim.value = value;
            claim
        })
        .collect();
    merged.runs = runs;
    merged.anchors = anchors;
    Ok(merged)
}

/// The worst outcome any shard saw is the outcome for the whole.
fn merged_status(
    captures: &[&runtime_protocol::CaptureSummary],
    executions: &[&runtime_protocol::ExecutionBucket],
) -> runtime_protocol::CaptureStatus {
    use runtime_protocol::CaptureStatus as S;
    let statuses: Vec<S> = captures
        .iter()
        .map(|capture| capture.status.enum_value_or_default())
        .collect();
    if statuses.contains(&S::FAILED_CAPTURE) {
        return S::FAILED_CAPTURE;
    }
    if statuses.contains(&S::STALE) {
        return S::STALE;
    }
    if statuses
        .iter()
        .any(|s| matches!(s, S::PARTIAL | S::NOT_INSTRUMENTED | S::UNSUPPORTED))
    {
        return S::PARTIAL;
    }
    if executions.is_empty() {
        return S::NOT_EXECUTED;
    }
    S::COMPLETE_FOR_RUNS
}

/// Only the shards that fell short explain why the whole did.
fn merged_reason(
    captures: &[&runtime_protocol::CaptureSummary],
    status: runtime_protocol::CaptureStatus,
) -> String {
    use runtime_protocol::CaptureStatus as S;
    if status == S::COMPLETE_FOR_RUNS {
        return String::new();
    }
    let short: Vec<&&runtime_protocol::CaptureSummary> = captures
        .iter()
        .filter(|c| {
            !matches!(
                c.status.enum_value_or_default(),
                S::COMPLETE_FOR_RUNS | S::NOT_EXECUTED
            )
        })
        .collect();
    let source: Vec<&&runtime_protocol::CaptureSummary> = if short.is_empty() {
        captures.iter().collect()
    } else {
        short
    };
    let reasons: BTreeSet<&str> = source
        .iter()
        .map(|c| c.reason.as_str())
        .filter(|r| !r.is_empty())
        .collect();
    reasons.into_iter().collect::<Vec<_>>().join("; ")
}

/// Buckets differing only in count are one observation seen repeatedly.
/// Messages compare structurally, so nothing has to be serialised to group them.
fn merge_buckets(
    rows: &[&runtime_protocol::ExecutionBucket],
) -> Vec<runtime_protocol::ExecutionBucket> {
    let mut merged: Vec<runtime_protocol::ExecutionBucket> = Vec::new();
    for row in rows {
        let matched = merged.iter_mut().find(|kept| {
            let mut a = (*kept).clone();
            let mut b = (*row).clone();
            a.count = 0;
            b.count = 0;
            a == b
        });
        match matched {
            Some(existing) => existing.count += row.count.max(1),
            None => {
                let mut bucket = (*row).clone();
                bucket.count = bucket.count.max(1);
                merged.push(bucket);
            }
        }
    }
    // Deterministic order, and the same one the collector produced: a reader
    // that takes the first bucket as representative must get the same one every
    // run and from either implementation.
    merged.sort_by_cached_key(|bucket| {
        // The same rendering the collector sorted by, so both orderings agree.
        runtime_protocol::to_json_with_defaults(bucket).unwrap_or_default()
    });
    merged
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


#[cfg(test)]
mod tests {
    use super::*;
    use protobuf::MessageField;

    fn range(start: u32, end: u32) -> runtime_protocol::SourceRange {
        let mut r = runtime_protocol::SourceRange::new();
        r.start_line = start;
        r.end_line = end;
        r
    }

    fn anchor(
        symbol: &str,
        path: &str,
        name: &str,
        kind: AnchorKind,
        lines: (u32, u32),
    ) -> runtime_protocol::SourceAnchor {
        let mut a = runtime_protocol::SourceAnchor::new();
        a.symbol = symbol.to_string();
        a.relative_path = path.to_string();
        a.display_name = name.to_string();
        a.kind = protobuf::EnumOrUnknown::new(kind);
        a.semantic_digest = vec![1, 2, 3];
        a.enclosing_symbol = format!("enclosing/{symbol}");
        a.range = MessageField::some(range(lines.0, lines.1));
        a
    }

    fn request(
        anchor: runtime_protocol::SourceAnchor,
        required: &[runtime_protocol::EvidenceKind],
    ) -> runtime_protocol::EvidenceRequest {
        let mut r = runtime_protocol::EvidenceRequest::new();
        r.anchor = MessageField::some(anchor);
        r.required = required
            .iter()
            .map(|kind| protobuf::EnumOrUnknown::new(*kind))
            .collect();
        r
    }

    fn plan_of(requests: Vec<runtime_protocol::EvidenceRequest>) -> TracePlan {
        let mut plan = TracePlan::new();
        plan.requests = requests;
        plan
    }

    fn trace_of(json: serde_json::Value) -> Trace {
        serde_json::from_value(json).expect("trace fixture")
    }

    fn value_bucket(kind: &str) -> serde_json::Value {
        serde_json::json!({
            "count": 1,
            "value": { "alternatives": [{ "value": { "type_symbol": kind }, "count": 1 }] },
            "provenance": { "run_id": "", "provider": "p", "provider_version": "1" }
        })
    }

    fn call_bucket(with_result: bool) -> serde_json::Value {
        let mut bucket = serde_json::json!({
            "count": 2,
            "receiver": { "alternatives": [{ "value": { "type_symbol": "String" }, "count": 1 }] },
            "target": { "symbol": "T" },
            "provenance": { "run_id": "r1", "provider": "p", "provider_version": "1" }
        });
        if with_result {
            bucket["result"] = serde_json::json!({ "alternatives": [] });
        }
        bucket
    }

    // --- path and range -----------------------------------------------------

    #[test]
    fn canonical_path_is_relative_to_the_analyzed_root() {
        let root = Path::new("/repo");
        assert_eq!(canonical_path(root, "/repo/lib/a.rb"), "lib/a.rb");
        assert_eq!(canonical_path(root, "lib/a.rb"), "lib/a.rb");
        assert_eq!(canonical_path(root, ""), "");
    }

    #[test]
    fn a_path_outside_the_root_keeps_its_own_identity() {
        assert_eq!(canonical_path(Path::new("/repo"), "/other/x.rb"), "/other/x.rb");
    }

    #[test]
    fn a_range_is_matched_against_one_based_lines() {
        // The plan is zero-based; collectors report the line a human would.
        let r = range(4, 6);
        assert!(!line_in_range(&r, 4));
        assert!(line_in_range(&r, 5));
        assert!(line_in_range(&r, 7));
        assert!(!line_in_range(&r, 8));
    }

    #[test]
    fn only_boundary_anchors_are_satisfied_by_observations() {
        assert_eq!(observation_kind(AnchorKind::FUNCTION_ENTRY), Some("parameter"));
        assert_eq!(observation_kind(AnchorKind::FUNCTION_RETURN), Some("return"));
        assert_eq!(observation_kind(AnchorKind::STATE_WRITE), Some("state"));
        assert_eq!(observation_kind(AnchorKind::CALL_SELECTOR), None);
        assert!(is_call_anchor(AnchorKind::CALL_SELECTOR));
        assert!(!is_call_anchor(AnchorKind::FUNCTION_ENTRY));
    }

    // --- what a match contributes -------------------------------------------

    #[test]
    fn a_domain_with_no_named_type_contributes_nothing() {
        assert!(!has_types(&serde_json::json!({ "types": [] })));
        assert!(!has_types(&serde_json::json!({ "types": [""] })));
        assert!(!has_types(&serde_json::json!({})));
        assert!(has_types(&serde_json::json!({ "types": ["String"] })));
    }

    #[test]
    fn bucket_fields_are_reported_by_presence_not_by_nulls() {
        let bucket = serde_json::json!({ "receiver": {}, "result": serde_json::Value::Null });
        assert!(bucket_has(&bucket, "receiver"));
        assert!(!bucket_has(&bucket, "result"));
        assert!(!bucket_has(&bucket, "target"));
    }

    #[test]
    fn every_requested_kind_maps_to_the_field_that_satisfies_it() {
        assert_eq!(evidence_field("PARAMETER_VALUE"), Some("value"));
        assert_eq!(evidence_field("RETURN_VALUE"), Some("value"));
        assert_eq!(evidence_field("STATE_VALUE"), Some("value"));
        assert_eq!(evidence_field("RECEIVER_VALUE"), Some("receiver"));
        assert_eq!(evidence_field("COLLECTION_VALUE"), Some("receiver"));
        assert_eq!(evidence_field("CALL_TARGET"), Some("target"));
        assert_eq!(evidence_field("RESULT_VALUE"), Some("result"));
        assert_eq!(evidence_field("BOOLEAN_RESULT"), Some("boolean_result"));
        assert_eq!(evidence_field("NOT_A_KIND"), None);
    }

    // --- matching -----------------------------------------------------------

    #[test]
    fn a_parameter_anchor_matches_only_its_own_slot() {
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "observations": [
                { "kind": "parameter", "slot": "value", "count": 1,
                  "scope": { "path": "lib/a.rb", "line": 5 },
                  "domain": { "types": ["String"] }, "bucket": value_bucket("String") },
                { "kind": "parameter", "slot": "other", "count": 1,
                  "scope": { "path": "lib/a.rb", "line": 5 },
                  "domain": { "types": ["Integer"] }, "bucket": value_bucket("Integer") }
            ]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (4, 4));
        assert_eq!(join.matching_observations(&a, "parameter"), vec![0]);
    }

    #[test]
    fn exact_anchor_identity_beats_the_collectors_reported_line() {
        // A multiline call may be reported at its receiver line while the plan
        // anchors the selector line. The exact binding already proved which
        // planned anchor ran, so it wins.
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "calls": [
                { "row": { "callsite": { "path": "lib/a.rb", "line": 99, "selector": "map",
                                          "anchor_symbol": "s" }, "count": 1 },
                  "bucket": call_bucket(false) },
                { "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                          "anchor_symbol": "" }, "count": 1 },
                  "bucket": call_bucket(false) }
            ]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4));
        let (matched, ambiguous) = join.matching_calls(&a);
        assert_eq!(matched, vec![0], "the exactly-bound call, not the line match");
        assert!(!ambiguous);
    }

    #[test]
    fn without_an_exact_binding_only_unbound_calls_on_the_line_match() {
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "calls": [
                { "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                          "anchor_symbol": "someone-elses" }, "count": 1 },
                  "bucket": call_bucket(false) },
                { "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                          "anchor_symbol": "" }, "count": 1 },
                  "bucket": call_bucket(false) }
            ]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4));
        assert_eq!(join.matching_calls(&a).0, vec![1]);
    }

    // --- executed vs captured ----------------------------------------------

    #[test]
    fn a_return_anchor_with_no_observation_did_not_execute() {
        // A conforming collector reports every returned value, including null
        // and false, so absence means the boundary was never reached -- not
        // that it ran uncaptured.
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "function_entries": [{ "path": "lib/a.rb", "line": 5 }]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "return", AnchorKind::FUNCTION_RETURN, (4, 4));
        assert!(!join.anchor_executed(&a, false));
    }

    #[test]
    fn an_entry_anchor_whose_function_ran_is_executed() {
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "function_entries": [{ "path": "lib/a.rb", "line": 5 }]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (4, 4));
        assert!(join.anchor_executed(&a, false));
    }

    #[test]
    fn an_exact_execution_range_is_proven_by_the_marker_alone() {
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "exact_anchor_executions": [{ "symbol": "s", "count": 3 }],
            "executed_callsites": [{ "path": "lib/a.rb", "line": 5, "selector": "map" }]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4));
        assert!(join.anchor_executed(&a, true));
        assert_eq!(join.exact_count("s"), 3);
        let other = anchor("t", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4));
        assert!(!join.anchor_executed(&other, true), "a different marker is not this one");
        assert!(join.anchor_executed(&other, false), "but the callsite did run");
    }

    #[test]
    fn coverage_alone_only_fails_closed() {
        // Line coverage cannot prove which same-line call ran, so it may say
        // "executed but uncaptured" and never "this anchor ran".
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "coverage": [{ "path": "lib/a.rb", "lines": [5] }]
        }));
        let plan = plan_of(vec![]);
        let join = Join::new(Path::new("/repo"), &plan, &trace);
        let a = anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4));
        assert!(join.anchor_executed(&a, false));
    }

    // --- whole-anchor outcomes ---------------------------------------------

    fn statuses(plan: &TracePlan, trace: &Trace) -> Vec<(String, String, i64)> {
        let join = Join::new(Path::new("/repo"), plan, trace);
        let runs = vec!["run-1".to_string()];
        plan.requests
            .iter()
            .map(|request| {
                let a = request.anchor.as_ref().unwrap();
                let row = join.evaluate(request, a, &runs).unwrap();
                (
                    a.symbol.clone(),
                    row["capture"]["status"].as_str().unwrap().to_string(),
                    row["capture"]["observed_executions"].as_i64().unwrap(),
                )
            })
            .collect()
    }

    #[test]
    fn an_anchor_nothing_ran_is_not_executed_and_complete_for_every_kind() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (4, 4)),
            &[runtime_protocol::EvidenceKind::PARAMETER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        assert_eq!(statuses(&plan, &trace), vec![("s".into(), "NOT_EXECUTED".into(), 0)]);
    }

    #[test]
    fn an_anchor_that_ran_without_a_captured_value_is_not_instrumented() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (4, 4)),
            &[runtime_protocol::EvidenceKind::PARAMETER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "function_entries": [{ "path": "lib/a.rb", "line": 5 }]
        }));
        assert_eq!(statuses(&plan, &trace)[0].1, "NOT_INSTRUMENTED");
    }

    #[test]
    fn a_kind_no_bucket_carries_makes_the_capture_partial() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4)),
            &[
                runtime_protocol::EvidenceKind::RECEIVER_VALUE,
                runtime_protocol::EvidenceKind::RESULT_VALUE,
            ],
        )]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "calls": [{ "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                                "anchor_symbol": "" }, "count": 2 },
                        "bucket": call_bucket(false) }]
        }));
        let rows = statuses(&plan, &trace);
        assert_eq!(rows[0].1, "PARTIAL", "no result was captured");
        assert_eq!(rows[0].2, 2);
    }

    #[test]
    fn a_capture_carrying_every_requested_kind_is_complete() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4)),
            &[runtime_protocol::EvidenceKind::RECEIVER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "calls": [{ "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                                "anchor_symbol": "" }, "count": 2 },
                        "bucket": call_bucket(true) }]
        }));
        assert_eq!(statuses(&plan, &trace)[0], ("s".into(), "COMPLETE_FOR_RUNS".into(), 2));
    }

    #[test]
    fn a_match_that_captured_nothing_is_not_an_execution() {
        // The collector saw the call but recorded no value for it, so there is
        // no bucket and the anchor must not read as executed-and-captured.
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4)),
            &[runtime_protocol::EvidenceKind::RECEIVER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "calls": [{ "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                                "anchor_symbol": "" }, "count": 2 } }]
        }));
        assert_eq!(statuses(&plan, &trace)[0].1, "NOT_EXECUTED");
    }

    #[test]
    fn one_representative_bucket_regains_the_markers_exact_count() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4)),
            &[runtime_protocol::EvidenceKind::RECEIVER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "exact_anchor_executions": [{ "symbol": "s", "count": 9 }],
            "calls": [{ "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                                "anchor_symbol": "" }, "count": 2 },
                        "bucket": call_bucket(true) }]
        }));
        assert_eq!(statuses(&plan, &trace)[0].2, 9);
    }

    // --- emission -----------------------------------------------------------

    #[test]
    fn an_entry_absence_would_already_imply_is_left_out() {
        let vacuous = serde_json::json!({
            "capture": { "status": "NOT_EXECUTED" }, "executions": []
        });
        let ran = serde_json::json!({
            "capture": { "status": "COMPLETE_FOR_RUNS" }, "executions": [{ "count": 1 }]
        });
        let uncaptured = serde_json::json!({
            "capture": { "status": "NOT_INSTRUMENTED" }, "executions": []
        });
        assert!(is_vacuous(&vacuous));
        assert!(!is_vacuous(&ran));
        assert!(!is_vacuous(&uncaptured), "NOT_INSTRUMENTED is not implied by absence");
    }

    #[test]
    fn bytes_are_encoded_as_standard_base64() {
        assert_eq!(base64_standard(b""), "");
        assert_eq!(base64_standard(b"f"), "Zg==");
        assert_eq!(base64_standard(b"fo"), "Zm8=");
        assert_eq!(base64_standard(b"foo"), "Zm9v");
        assert_eq!(base64_standard(b"foob"), "Zm9vYg==");
        assert_eq!(base64_standard(&[251, 255, 190]), "+/++");
    }

    // --- merging ------------------------------------------------------------

    /// Build a real protocol message so the merge is tested through the same
    /// parse the pipeline uses, not a hand-rolled struct.
    fn evidence_doc(anchors: serde_json::Value, extra: serde_json::Value) -> runtime_protocol::RuntimeEvidence {
        let mut doc = serde_json::json!({
            "protocol_version": 1,
            "producer": { "name": "nil-kill", "version": "1" },
            "authority": "MODELED_RUNS",
            "trace_plan_digest": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "environment": [],
            "runs": [{ "id": "r1", "status": "SUCCEEDED" }],
            "anchors": anchors,
            "correlations": []
        });
        for (key, value) in extra.as_object().cloned().unwrap_or_default() {
            doc[key] = value;
        }
        runtime_protocol::parse_runtime_evidence_json(&doc.to_string()).expect("evidence fixture")
    }

    fn anchor_row(symbol: &str, status: &str, kinds: &[&str], counts: &[(u64, &str)]) -> serde_json::Value {
        anchor_row_for("r1", symbol, status, kinds, counts)
    }

    fn anchor_row_for(run: &str, symbol: &str, status: &str, kinds: &[&str], counts: &[(u64, &str)]) -> serde_json::Value {
        serde_json::json!({
            "anchor_symbol": symbol,
            "anchor_semantic_digest": "AQID",
            "capture": {
                "status": status,
                "run_ids": [run],
                "observed_executions": "0",
                "dropped_executions": "0",
                "complete_kinds": kinds
            },
            "executions": counts.iter().map(|(count, receiver)| serde_json::json!({
                "count": count.to_string(),
                "receiver": { "alternatives": [{ "value": { "type_symbol": receiver }, "count": "1" }] }
            })).collect::<Vec<_>>()
        })
    }

    #[test]
    fn buckets_differing_only_in_count_are_one_observation() {
        let doc = evidence_doc(
            serde_json::json!([anchor_row("a", "COMPLETE_FOR_RUNS", &[], &[(2, "R"), (3, "R"), (1, "S")])]),
            serde_json::json!({}),
        );
        let merged = merge_evidence(&[doc]).expect("merge");
        let executions = &merged.anchors[0].executions;
        assert_eq!(executions.len(), 2, "identical buckets fuse, distinct ones do not");
        assert_eq!(executions.iter().map(|b| b.count).sum::<u64>(), 6);
    }

    #[test]
    fn the_worst_status_any_shard_saw_wins() {
        let cases = [
            (["COMPLETE_FOR_RUNS", "COMPLETE_FOR_RUNS"], "COMPLETE_FOR_RUNS"),
            (["COMPLETE_FOR_RUNS", "PARTIAL"], "PARTIAL"),
            (["COMPLETE_FOR_RUNS", "NOT_INSTRUMENTED"], "PARTIAL"),
            (["PARTIAL", "STALE"], "STALE"),
            (["STALE", "FAILED_CAPTURE"], "FAILED_CAPTURE"),
        ];
        for (statuses, expected) in cases {
            let docs: Vec<_> = statuses
                .iter()
                .map(|status| {
                    evidence_doc(
                        serde_json::json!([anchor_row("a", status, &["RECEIVER_VALUE"], &[(1, "R")])]),
                        serde_json::json!({}),
                    )
                })
                .collect();
            let merged = merge_evidence(&docs).expect("merge");
            assert_eq!(
                format!("{:?}", merged.anchors[0].capture.status.enum_value_or_default()),
                expected,
                "{statuses:?}"
            );
        }
    }

    #[test]
    fn an_anchor_no_shard_executed_is_not_executed() {
        let doc = evidence_doc(
            serde_json::json!([anchor_row("a", "COMPLETE_FOR_RUNS", &[], &[])]),
            serde_json::json!({}),
        );
        let merged = merge_evidence(&[doc]).expect("merge");
        assert_eq!(
            format!("{:?}", merged.anchors[0].capture.status.enum_value_or_default()),
            "NOT_EXECUTED"
        );
    }

    #[test]
    fn merging_unions_anchors_sums_counts_and_intersects_complete_kinds() {
        let left = evidence_doc(
            serde_json::json!([anchor_row(
                "a", "COMPLETE_FOR_RUNS", &["RECEIVER_VALUE", "CALL_TARGET"], &[(2, "R")]
            )]),
            serde_json::json!({
                "runs": [{ "id": "r1", "status": "SUCCEEDED" }],
                "environment": [{ "key": "ruby", "value": "3.2.3" }]
            }),
        );
        let right = evidence_doc(
            serde_json::json!([
                anchor_row_for("r2", "a", "PARTIAL", &["RECEIVER_VALUE"], &[(3, "R")]),
                anchor_row_for("r2", "b", "COMPLETE_FOR_RUNS", &[], &[(1, "S")])
            ]),
            serde_json::json!({
                "runs": [{ "id": "r2", "status": "SUCCEEDED" }],
                "environment": [{ "key": "ruby", "value": "3.2.3" }]
            }),
        );

        let merged = merge_evidence(&[left, right]).expect("merge");
        assert_eq!(merged.anchors.len(), 2, "a shard contributes what it observed");

        let a = merged
            .anchors
            .iter()
            .find(|x| x.anchor_symbol == "a")
            .expect("anchor a");
        assert_eq!(
            format!("{:?}", a.capture.status.enum_value_or_default()),
            "PARTIAL"
        );
        assert_eq!(a.capture.observed_executions, 5, "counts add");
        assert_eq!(a.capture.run_ids, vec!["r1".to_string(), "r2".to_string()]);
        assert_eq!(
            a.capture
                .complete_kinds
                .iter()
                .map(|k| format!("{:?}", k.enum_value_or_default()))
                .collect::<Vec<_>>(),
            vec!["RECEIVER_VALUE"],
            "a kind is complete only where every shard found it so"
        );
        assert_eq!(a.executions.len(), 1, "identical buckets fuse across shards");
        assert_eq!(merged.environment.len(), 1);
        assert_eq!(merged.runs.len(), 2);
    }

    #[test]
    fn merging_rejects_a_shard_that_repeats_an_anchor() {
        let doc = evidence_doc(
            serde_json::json!([
                anchor_row("a", "COMPLETE_FOR_RUNS", &[], &[(1, "R")]),
                anchor_row("a", "COMPLETE_FOR_RUNS", &[], &[(1, "R")])
            ]),
            serde_json::json!({}),
        );
        assert!(merge_evidence(&[doc]).is_err());
    }

    #[test]
    fn merging_rejects_conflicting_environment_claims() {
        let doc = |version: &str| {
            evidence_doc(
                serde_json::json!([]),
                serde_json::json!({ "environment": [{ "key": "ruby", "value": version }] }),
            )
        };
        assert!(merge_evidence(&[doc("3.2.3"), doc("3.3.0")]).is_err());
    }

    // --- target resolution --------------------------------------------------

    fn bucket_with_definition(path: &str, line: i64) -> serde_json::Value {
        serde_json::json!({
            "count": 1,
            "target": { "symbol": "observed-symbol", "source_role": "PRODUCTION" },
            "target_definition": { "path": path, "line": line }
        })
    }

    fn join_with_plan<'a>(
        plan: &'a TracePlan,
        trace: &'a Trace,
    ) -> Join<'a> {
        Join::new(Path::new("/repo"), plan, trace)
    }

    #[test]
    fn a_declaration_matching_one_planned_function_takes_that_functions_identity() {
        let plan = plan_of(vec![request(
            anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (9, 11)),
            &[runtime_protocol::EvidenceKind::PARAMETER_VALUE],
        )]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = bucket_with_definition("/repo/lib/a.rb", 10);
        join.resolve_target(&mut bucket);

        assert_eq!(bucket["target"]["symbol"], "enclosing/s");
        assert_eq!(bucket["target"]["definition"]["anchor_symbol"], "s");
        assert_eq!(bucket["target"]["definition"]["relative_path"], "lib/a.rb");
        assert!(bucket.get("target_definition").is_none(), "the locator is consumed");
    }

    #[test]
    fn two_planned_functions_at_one_declaration_is_not_a_resolution() {
        // Two distinct enclosing symbols covering the same line means the
        // declaration does not name one of them, so the raw locator is kept
        // for the consumer to bind from source itself.
        let plan = plan_of(vec![
            request(
                anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (9, 11)),
                &[runtime_protocol::EvidenceKind::PARAMETER_VALUE],
            ),
            request(
                anchor("t", "lib/a.rb", "other", AnchorKind::FUNCTION_ENTRY, (9, 11)),
                &[runtime_protocol::EvidenceKind::PARAMETER_VALUE],
            ),
        ]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = bucket_with_definition("/repo/lib/a.rb", 10);
        join.resolve_target(&mut bucket);

        assert_eq!(bucket["target"]["symbol"], "observed-symbol", "kept as observed");
        assert_eq!(bucket["target"]["definition"]["anchor_symbol"], "");
        assert_eq!(bucket["target"]["definition"]["range"]["start_line"], 9);
    }

    #[test]
    fn the_same_function_entered_and_returned_is_still_one_candidate() {
        // FUNCTION_ENTRY and FUNCTION_RETURN of one method share an enclosing
        // symbol, so they must not read as an ambiguous pair.
        let mut entry = anchor("s", "lib/a.rb", "value", AnchorKind::FUNCTION_ENTRY, (9, 11));
        let mut ret = anchor("r", "lib/a.rb", "return", AnchorKind::FUNCTION_RETURN, (9, 11));
        entry.enclosing_symbol = "same/method".to_string();
        ret.enclosing_symbol = "same/method".to_string();
        let plan = plan_of(vec![
            request(entry, &[runtime_protocol::EvidenceKind::PARAMETER_VALUE]),
            request(ret, &[runtime_protocol::EvidenceKind::RETURN_VALUE]),
        ]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = bucket_with_definition("/repo/lib/a.rb", 10);
        join.resolve_target(&mut bucket);
        assert_eq!(bucket["target"]["symbol"], "same/method");
    }

    #[test]
    fn a_declaration_outside_the_plan_keeps_its_observed_locator() {
        let plan = plan_of(vec![]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = bucket_with_definition("/repo/vendor/dep.rb", 7);
        join.resolve_target(&mut bucket);
        assert_eq!(bucket["target"]["definition"]["relative_path"], "vendor/dep.rb");
        assert_eq!(bucket["target"]["definition"]["range"]["start_line"], 6);
    }

    #[test]
    fn a_bucket_with_no_declaration_is_left_alone() {
        let plan = plan_of(vec![]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = serde_json::json!({ "count": 1, "target": { "symbol": "x" } });
        join.resolve_target(&mut bucket);
        assert_eq!(bucket["target"]["symbol"], "x");
        assert!(bucket["target"].get("definition").is_none());
    }

    #[test]
    fn a_declaration_without_a_usable_line_is_not_invented() {
        let plan = plan_of(vec![]);
        let trace = trace_of(serde_json::json!({ "trace_version": 1 }));
        let join = join_with_plan(&plan, &trace);

        let mut bucket = bucket_with_definition("/repo/lib/a.rb", 0);
        join.resolve_target(&mut bucket);
        assert!(bucket["target"].get("definition").is_none());
    }

    // --- documents in and out -----------------------------------------------

    #[test]
    fn a_trace_of_another_version_is_refused() {
        let dir = std::env::temp_dir().join(format!("nk-trace-version-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp");
        let path = dir.join("trace.json");
        std::fs::write(&path, serde_json::json!({ "trace_version": 99 }).to_string()).expect("write");
        let error = read_trace(&path).expect_err("refused");
        assert!(error.to_string().contains("unsupported runtime trace version"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_document_is_gzipped_when_its_name_says_so_and_round_trips() {
        let dir = std::env::temp_dir().join(format!("nk-write-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp");

        let gz = dir.join("doc.json.gz");
        write_json(&gz, "{\"a\":1}").expect("gz write");
        let bytes = std::fs::read(&gz).expect("read");
        assert_eq!(&bytes[..2], &[0x1f, 0x8b], "gzip magic");
        assert_eq!(runtime_protocol::read_json(&gz).expect("read back"), "{\"a\":1}");

        let plain = dir.join("doc.json");
        write_json(&plain, "{\"a\":1}").expect("plain write");
        assert_eq!(std::fs::read_to_string(&plain).expect("read"), "{\"a\":1}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_plan_is_accepted_inside_its_envelope_or_bare() {
        let dir = std::env::temp_dir().join(format!("nk-plan-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp");
        let bare = runtime_protocol::to_json(&plan_of(vec![])).expect("plan json");

        let wrapped = dir.join("wrapped.json");
        std::fs::write(
            &wrapped,
            serde_json::json!({
                "version": 1,
                "runtime_evidence": serde_json::from_str::<serde_json::Value>(&bare).unwrap()
            })
            .to_string(),
        )
        .expect("write");
        let flat = dir.join("flat.json");
        std::fs::write(&flat, &bare).expect("write");

        // Both forms reach the same validation, which is what unwrapping means.
        // A plan still inside its envelope used to fail on the envelope's own
        // fields ("Unknown field name: version") before ever being read.
        let from_envelope = format!("{:?}", read_plan(&wrapped));
        let from_bare = format!("{:?}", read_plan(&flat));
        let cause = "trace plan protocol_version must be 1";
        assert!(from_bare.contains(cause), "{from_bare}");
        assert!(from_envelope.contains(cause), "{from_envelope}");
        assert!(!from_envelope.contains("Unknown field name"), "{from_envelope}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_emitted_document_omits_only_what_absence_already_says() {
        let plan = plan_of(vec![
            request(
                anchor("ran", "lib/a.rb", "map", AnchorKind::CALL_SELECTOR, (4, 4)),
                &[runtime_protocol::EvidenceKind::RECEIVER_VALUE],
            ),
            request(
                anchor("idle", "lib/a.rb", "each", AnchorKind::CALL_SELECTOR, (4, 4)),
                &[runtime_protocol::EvidenceKind::RECEIVER_VALUE],
            ),
        ]);
        let trace = trace_of(serde_json::json!({
            "trace_version": 1,
            "run_ids": ["r1"],
            "environment": [],
            "trace_plan_digest": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "calls": [{ "row": { "callsite": { "path": "lib/a.rb", "line": 5, "selector": "map",
                                                "anchor_symbol": "" }, "count": 1 },
                        "bucket": call_bucket(true) }]
        }));
        let document = build_evidence(Path::new("/repo"), &plan, &trace).expect("evidence");
        let parsed: serde_json::Value = serde_json::from_str(&document).expect("json");
        let symbols: Vec<&str> = parsed["anchors"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a["anchor_symbol"].as_str().unwrap())
            .collect();
        assert_eq!(symbols, vec!["ran"], "the idle anchor is implied by its absence");
        assert_eq!(parsed["runs"][0]["id"], "r1");
    }
}
