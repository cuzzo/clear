use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ImplicitControlFlowReport {
    pub ordered_protocols: Vec<ProtocolFinding>,
    pub order_drift: Vec<ProtocolFinding>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ProtocolFinding {
    pub kind: String,
    pub protocol: Vec<String>,
    pub dependency: Vec<String>,
    pub states: Vec<String>,
    pub support: usize,
    pub confidence: f64,
    pub at: String,
    pub observed: Vec<String>,
    pub missing: Vec<String>,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct MethodEffect {
    owner: String,
    name: String,
    reads: Vec<String>,
    writes: Vec<String>,
}

#[derive(Clone, Debug)]
struct Call {
    mid: String,
    line: usize,
    span: Span,
    reads: Vec<String>,
    writes: Vec<String>,
}

#[derive(Clone, Debug)]
struct MethodSequence {
    file: String,
    owner: String,
    defn: String,
    line: usize,
    calls: Vec<Call>,
}

const OPTIONAL_DIAGNOSTIC_MIDS: &[&str] =
    &["error!", "fixable!", "read_interpolated_string", "warn!"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<ImplicitControlFlowReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> ImplicitControlFlowReport {
    let effect_index = EffectIndex::build_documents(documents);
    let mut sequences = Vec::new();
    for document in documents {
        sequences.extend(sequences_for_document(document, &effect_index));
    }

    let report = Report::new(sequences);
    ImplicitControlFlowReport {
        ordered_protocols: report.ordered_protocols(1),
        order_drift: report.drift(4, 0.75),
    }
}

fn sequences_for_document(document: &Document, effect_index: &EffectIndex) -> Vec<MethodSequence> {
    document
        .protocol_call_paths
        .iter()
        .filter_map(|path| {
            let calls = path
                .calls
                .iter()
                .map(|call| {
                    let effect = effect_index.effect_for(&path.owner, &call.mid);
                    Call {
                        mid: call.mid.clone(),
                        line: call.line,
                        span: call.span,
                        reads: effect.map(|e| e.reads.clone()).unwrap_or_default(),
                        writes: effect.map(|e| e.writes.clone()).unwrap_or_default(),
                    }
                })
                .collect::<Vec<_>>();

            if calls
                .iter()
                .filter(|call| !call.reads.is_empty() || !call.writes.is_empty())
                .count()
                < 2
            {
                return None;
            }

            Some(MethodSequence {
                file: path.file.clone(),
                owner: path.owner.clone(),
                defn: path.name.clone(),
                line: path.line,
                calls,
            })
        })
        .collect()
}

struct EffectIndex {
    by_owner_name: BTreeMap<(String, String), MethodEffect>,
    by_name: BTreeMap<String, Vec<MethodEffect>>,
}

impl EffectIndex {
    fn build_documents(documents: &[Document]) -> Self {
        let mut effects = Vec::new();
        for document in documents {
            for effect in &document.protocol_method_effects {
                effects.push(MethodEffect {
                    owner: effect.owner.clone(),
                    name: effect.name.clone(),
                    reads: effect.reads.clone(),
                    writes: effect.writes.clone(),
                });
            }
        }
        Self::from_effects(effects)
    }

    fn from_effects(effects: Vec<MethodEffect>) -> Self {
        let mut by_owner_name = BTreeMap::new();
        let mut by_name = BTreeMap::new();
        for e in effects {
            by_owner_name.insert((e.owner.clone(), e.name.clone()), e.clone());
            by_name
                .entry(e.name.clone())
                .or_insert_with(Vec::new)
                .push(e);
        }
        Self {
            by_owner_name,
            by_name,
        }
    }

    fn effect_for(&self, owner: &str, name: &str) -> Option<&MethodEffect> {
        if let Some(e) = self
            .by_owner_name
            .get(&(owner.to_string(), name.to_string()))
        {
            return Some(e);
        }
        let candidates = self.by_name.get(name)?;
        let stateful: Vec<_> = candidates
            .iter()
            .filter(|e| !e.reads.is_empty() || !e.writes.is_empty())
            .collect();
        if stateful.len() == 1 {
            Some(stateful[0])
        } else {
            None
        }
    }
}

struct Report {
    sequences: Vec<MethodSequence>,
    site_call_sets: BTreeMap<(String, String, String, usize), BTreeMap<String, bool>>,
}

impl Report {
    fn new(sequences: Vec<MethodSequence>) -> Self {
        let mut site_call_sets = BTreeMap::new();
        for seq in &sequences {
            let mut calls = BTreeMap::new();
            for c in seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
            {
                calls.insert(c.mid.clone(), true);
            }
            site_call_sets.insert(
                (
                    seq.file.clone(),
                    seq.owner.clone(),
                    seq.defn.clone(),
                    seq.line,
                ),
                calls,
            );
        }
        Self {
            sequences,
            site_call_sets,
        }
    }

    fn ordered_protocols(&self, min_support: usize) -> Vec<ProtocolFinding> {
        let mut counts: BTreeMap<
            (String, String, String, String),
            BTreeMap<(String, String, String, usize), ProtocolFinding>,
        > = BTreeMap::new();
        for seq in &self.sequences {
            let state_calls: Vec<_> = seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
                .collect();
            let collapsed = self.collapse_consecutive(&state_calls);
            for i in 0..collapsed.len().saturating_sub(1) {
                let left = collapsed[i];
                let right = collapsed[i + 1];
                let edge = self.dependency_edge(left, right);
                let Some(edge) = edge else { continue };
                if self.diagnostic_protocol(&[left.mid.clone(), right.mid.clone()]) {
                    continue;
                };

                let key = (
                    left.mid.clone(),
                    right.mid.clone(),
                    edge.0.join("|"),
                    edge.1.join("|"),
                );
                let site_key = (
                    seq.file.clone(),
                    seq.owner.clone(),
                    seq.defn.clone(),
                    seq.line,
                );
                counts.entry(key).or_default().insert(
                    site_key,
                    ProtocolFinding {
                        kind: "protocol_pressure".to_string(),
                        protocol: vec![left.mid.clone(), right.mid.clone()],
                        dependency: edge.0,
                        states: edge.1,
                        support: 0,
                        confidence: 1.0,
                        at: format!("{}:{}:{}", seq.file, seq.defn, seq.line),
                        observed: vec![left.mid.clone(), right.mid.clone()],
                        missing: Vec::new(),
                        sites: Vec::new(),
                        spans: {
                            let mut s = BTreeMap::new();
                            s.insert(format!("{}:{}:{}", seq.file, seq.defn, seq.line), left.span);
                            s
                        },
                    },
                );
            }
        }

        let mut out = Vec::new();
        for (_, sites) in counts {
            if sites.len() < min_support {
                continue;
            }
            let mut first = sites.values().next().unwrap().clone();
            first.support = sites.len();
            first.sites = sites
                .keys()
                .map(|k| format!("{}:{}:{}", k.0, k.2, k.3))
                .collect();
            out.push(first);
        }
        out.sort_by(|a, b| {
            b.support
                .cmp(&a.support)
                .then_with(|| self.dependency_rank(a).cmp(&self.dependency_rank(b)))
                .then_with(|| a.protocol.join("\0").cmp(&b.protocol.join("\0")))
        });
        out
    }

    fn drift(&self, min_support: usize, min_confidence: f64) -> Vec<ProtocolFinding> {
        let protocols = self.ordered_protocols(min_support);
        let mut protocol_index: BTreeMap<String, Vec<ProtocolFinding>> = BTreeMap::new();
        for p in protocols {
            let mut pair = p.protocol.clone();
            pair.sort();
            protocol_index.entry(pair.join("\0")).or_default().push(p);
        }

        let mut out = Vec::new();
        for seq in &self.sequences {
            let state_calls: Vec<_> = seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
                .collect();
            let collapsed = self.collapse_consecutive(&state_calls);
            let mids: Vec<_> = collapsed.iter().map(|c| c.mid.clone()).collect();
            let positions = self.first_positions(&mids);

            for protocol_row in self.candidate_protocols(
                &positions.keys().cloned().collect::<Vec<_>>(),
                &protocol_index,
            ) {
                let present: Vec<_> = protocol_row
                    .protocol
                    .iter()
                    .filter(|m| positions.contains_key(*m))
                    .cloned()
                    .collect();
                if present.len() < 2 {
                    continue;
                }
                if self.ordered_subsequence(&mids, &protocol_row.protocol) {
                    continue;
                }

                let confidence =
                    (protocol_row.support as f64) / (self.denominator_for(&present) as f64);
                if confidence < min_confidence {
                    continue;
                }

                out.push(self.finding(seq, &protocol_row, &present, &positions, confidence));
            }
        }

        let mut deduped = Vec::new();
        let mut seen = BTreeSet::new();
        for row in out {
            let key = (
                row.kind.clone(),
                row.at.clone(),
                row.protocol.clone(),
                row.observed.clone(),
                row.states.clone(),
            );
            if seen.insert(key) {
                deduped.push(row);
            }
        }
        deduped.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap()
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.at.cmp(&b.at))
        });
        deduped
    }

    fn dependency_rank(&self, row: &ProtocolFinding) -> usize {
        if row.dependency.iter().any(|d| d == "write_read") {
            0
        } else if row.dependency.iter().any(|d| d == "write_write") {
            1
        } else {
            2
        }
    }

    fn collapse_consecutive<'a>(&self, calls: &'a [&'a Call]) -> Vec<&'a Call> {
        let mut out = Vec::new();
        let mut last = None;
        for c in calls {
            if last.map(|l| l == &c.mid).unwrap_or(false) {
                continue;
            }
            last = Some(&c.mid);
            out.push(*c);
        }
        out
    }

    fn dependency_edge(&self, left: &Call, right: &Call) -> Option<(Vec<String>, Vec<String>)> {
        let lw: BTreeSet<_> = left.writes.iter().collect();
        let lr: BTreeSet<_> = left.reads.iter().collect();
        let rw: BTreeSet<_> = right.writes.iter().collect();
        let rr: BTreeSet<_> = right.reads.iter().collect();

        let mut kinds = Vec::new();
        let mut states = BTreeSet::new();

        let wr: Vec<_> = lw.intersection(&rr).collect();
        if !wr.is_empty() {
            kinds.push("write_read".to_string());
            for s in wr {
                states.insert((*s).clone());
            }
        }
        let ww: Vec<_> = lw.intersection(&rw).collect();
        if !ww.is_empty() {
            kinds.push("write_write".to_string());
            for s in ww {
                states.insert((*s).clone());
            }
        }
        let rw_int: Vec<_> = lr.intersection(&rw).collect();
        if !rw_int.is_empty() {
            kinds.push("read_write".to_string());
            for s in rw_int {
                states.insert((*s).clone());
            }
        }

        if kinds.is_empty() {
            return None;
        }
        kinds.sort();
        let mut states_v: Vec<_> = states.into_iter().collect();
        states_v.sort();
        Some((kinds, states_v))
    }

    fn diagnostic_protocol(&self, protocol: &[String]) -> bool {
        protocol.iter().any(|m| {
            OPTIONAL_DIAGNOSTIC_MIDS.contains(&m.as_str())
                || OPTIONAL_DIAGNOSTIC_MIDS.contains(&format!("{m}!").as_str())
        })
    }

    fn candidate_protocols(
        &self,
        mids: &[String],
        protocol_index: &BTreeMap<String, Vec<ProtocolFinding>>,
    ) -> Vec<ProtocolFinding> {
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        for i in 0..mids.len() {
            for j in i + 1..mids.len() {
                let mut pair = vec![mids[i].clone(), mids[j].clone()];
                pair.sort();
                if let Some(ps) = protocol_index.get(&pair.join("\0")) {
                    for p in ps {
                        let key = (p.protocol.clone(), p.dependency.clone(), p.states.clone());
                        if seen.insert(key) {
                            out.push(p.clone());
                        }
                    }
                }
            }
        }
        out
    }

    fn first_positions(&self, mids: &[String]) -> BTreeMap<String, usize> {
        let mut out = BTreeMap::new();
        for (i, m) in mids.iter().enumerate() {
            out.entry(m.clone()).or_insert(i);
        }
        out
    }

    fn ordered_subsequence(&self, mids: &[String], protocol: &[String]) -> bool {
        let mut idx = 0;
        for m in mids {
            if m == &protocol[idx] {
                idx += 1;
            }
            if idx == protocol.len() {
                return true;
            }
        }
        false
    }

    fn denominator_for(&self, present: &[String]) -> usize {
        self.site_call_sets
            .values()
            .filter(|mids| present.iter().all(|m| mids.contains_key(m)))
            .count()
            .max(1)
    }

    fn finding(
        &self,
        seq: &MethodSequence,
        protocol_row: &ProtocolFinding,
        present: &[String],
        positions: &BTreeMap<String, usize>,
        confidence: f64,
    ) -> ProtocolFinding {
        let anchor_mid = present
            .iter()
            .min_by_key(|m| positions.get(*m).unwrap())
            .unwrap();
        let anchor = seq.calls.iter().find(|c| &c.mid == anchor_mid).unwrap();
        let loc = format!("{}:{}:{}", seq.file, seq.defn, anchor.line);
        let mut observed = present.to_vec();
        observed.sort_by_key(|m| positions.get(m).unwrap());

        let mut spans = BTreeMap::new();
        spans.insert(loc.clone(), anchor.span);

        ProtocolFinding {
            kind: "order_drift".to_string(),
            protocol: protocol_row.protocol.clone(),
            observed,
            missing: Vec::new(),
            dependency: protocol_row.dependency.clone(),
            states: protocol_row.states.clone(),
            support: protocol_row.support,
            confidence: (confidence * 100.0).round() / 100.0,
            at: loc,
            sites: protocol_row.sites.clone(),
            spans,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_implicit_control_flow_gaps() {
        // 1. Test effect_for logic (lines 161-166, 168)
        // Set up method effects:
        // - "foo" has a single stateful candidate under ClassB (should be resolved by effect_for for any owner)
        // - "bar" has multiple stateful candidates (under ClassB and ClassC) -> should return None
        let doc_effects: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "protocol_method_effects": [
                {
                    "file": "foo.rb", "owner": "ClassB", "name": "foo", "line": 1,
                    "reads": ["state_x"], "writes": []
                },
                {
                    "file": "foo.rb", "owner": "ClassB", "name": "bar", "line": 2,
                    "reads": ["state_y"], "writes": []
                },
                {
                    "file": "foo.rb", "owner": "ClassC", "name": "bar", "line": 3,
                    "reads": ["state_z"], "writes": []
                }
            ],
            "protocol_call_paths": [
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "test_method", "line": 10,
                    "calls": [
                        { "mid": "foo", "file": "foo.rb", "owner": "ClassA", "defn": "test_method", "line": 11, "span": [11, 1, 11, 10] },
                        { "mid": "bar", "file": "foo.rb", "owner": "ClassA", "defn": "test_method", "line": 12, "span": [12, 1, 12, 10] }
                    ]
                }
            ]
        })).unwrap();

        // This document has only one resolved stateful call ("foo"), so count < 2 -> should return empty
        let report = scan_documents(&[doc_effects]);
        assert!(report.ordered_protocols.is_empty());

        // 2. Test dependencies, collapse_consecutive, diagnostic_protocol, drift (lines 224, 315, 324, 346-351, 358-359, 361, 370, 396-399)
        // Setup sequences to build:
        // - protocol A: write_read ("a" writes, "b" reads) -> score 0
        // - protocol B: write_write ("c" writes, "d" writes) -> score 1
        // - protocol C: read_write ("e" reads, "f" writes) -> score 2
        // We will call these enough times to pass support >= 4.
        let doc_main: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "protocol_method_effects": [
                { "file": "foo.rb", "owner": "ClassA", "name": "a", "line": 1, "reads": [], "writes": ["state_1"] },
                { "file": "foo.rb", "owner": "ClassA", "name": "b", "line": 2, "reads": ["state_1"], "writes": [] },
                { "file": "foo.rb", "owner": "ClassA", "name": "c", "line": 3, "reads": [], "writes": ["state_2"] },
                { "file": "foo.rb", "owner": "ClassA", "name": "d", "line": 4, "reads": [], "writes": ["state_2"] },
                { "file": "foo.rb", "owner": "ClassA", "name": "e", "line": 5, "reads": ["state_3"], "writes": [] },
                { "file": "foo.rb", "owner": "ClassA", "name": "f", "line": 6, "reads": [], "writes": ["state_3"] },
                { "file": "foo.rb", "owner": "ClassA", "name": "read_interpolated_string", "line": 7, "reads": ["state_4"], "writes": [] }
            ],
            "protocol_call_paths": [
                // 4 sequences for a -> b
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "u1", "line": 10,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "u1", "line": 11, "span": [11, 1, 11, 5] },
                        // consecutive duplicate to test collapse_consecutive (line 370)
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "u1", "line": 11, "span": [11, 1, 11, 5] },
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "u1", "line": 12, "span": [12, 1, 12, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "u2", "line": 20,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "u2", "line": 21, "span": [21, 1, 21, 5] },
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "u2", "line": 22, "span": [22, 1, 22, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "u3", "line": 30,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "u3", "line": 31, "span": [31, 1, 31, 5] },
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "u3", "line": 32, "span": [32, 1, 32, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "u4", "line": 40,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "u4", "line": 41, "span": [41, 1, 41, 5] },
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "u4", "line": 42, "span": [42, 1, 42, 5] }
                    ]
                },

                // 4 sequences for c -> d to test write_write dependency rank (lines 358-359, 396-399)
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "uc1", "line": 50,
                    "calls": [
                        { "mid": "c", "file": "foo.rb", "owner": "ClassA", "defn": "uc1", "line": 51, "span": [51, 1, 51, 5] },
                        { "mid": "d", "file": "foo.rb", "owner": "ClassA", "defn": "uc1", "line": 52, "span": [52, 1, 52, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "uc2", "line": 60,
                    "calls": [
                        { "mid": "c", "file": "foo.rb", "owner": "ClassA", "defn": "uc2", "line": 61, "span": [61, 1, 61, 5] },
                        { "mid": "d", "file": "foo.rb", "owner": "ClassA", "defn": "uc2", "line": 62, "span": [62, 1, 62, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "uc3", "line": 70,
                    "calls": [
                        { "mid": "c", "file": "foo.rb", "owner": "ClassA", "defn": "uc3", "line": 71, "span": [71, 1, 71, 5] },
                        { "mid": "d", "file": "foo.rb", "owner": "ClassA", "defn": "uc3", "line": 72, "span": [72, 1, 72, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "uc4", "line": 80,
                    "calls": [
                        { "mid": "c", "file": "foo.rb", "owner": "ClassA", "defn": "uc4", "line": 81, "span": [81, 1, 81, 5] },
                        { "mid": "d", "file": "foo.rb", "owner": "ClassA", "defn": "uc4", "line": 82, "span": [82, 1, 82, 5] }
                    ]
                },

                // 4 sequences for e -> f to test other dependency rank (line 361)
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ue1", "line": 90,
                    "calls": [
                        { "mid": "e", "file": "foo.rb", "owner": "ClassA", "defn": "ue1", "line": 91, "span": [91, 1, 91, 5] },
                        { "mid": "f", "file": "foo.rb", "owner": "ClassA", "defn": "ue1", "line": 92, "span": [92, 1, 92, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ue2", "line": 100,
                    "calls": [
                        { "mid": "e", "file": "foo.rb", "owner": "ClassA", "defn": "ue2", "line": 101, "span": [101, 1, 101, 5] },
                        { "mid": "f", "file": "foo.rb", "owner": "ClassA", "defn": "ue2", "line": 102, "span": [102, 1, 102, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ue3", "line": 110,
                    "calls": [
                        { "mid": "e", "file": "foo.rb", "owner": "ClassA", "defn": "ue3", "line": 111, "span": [111, 1, 111, 5] },
                        { "mid": "f", "file": "foo.rb", "owner": "ClassA", "defn": "ue3", "line": 112, "span": [112, 1, 112, 5] }
                    ]
                },
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ue4", "line": 120,
                    "calls": [
                        { "mid": "e", "file": "foo.rb", "owner": "ClassA", "defn": "ue4", "line": 121, "span": [121, 1, 121, 5] },
                        { "mid": "f", "file": "foo.rb", "owner": "ClassA", "defn": "ue4", "line": 122, "span": [122, 1, 122, 5] }
                    ]
                },

                // Test diagnostic_protocol skip (line 224) via "read_interpolated_string"
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ud1", "line": 130,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "ud1", "line": 131, "span": [131, 1, 131, 5] },
                        { "mid": "read_interpolated_string", "file": "foo.rb", "owner": "ClassA", "defn": "ud1", "line": 132, "span": [132, 1, 132, 5] }
                    ]
                },

                // Sequence with drift for a -> b (b -> a) with confidence = 1.0 (since denominator for ["a", "b"] is 5, support is 4, drift support is 1. confidence = 4/5 = 0.8 >= 0.75)
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "udrift1", "line": 140,
                    "calls": [
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "udrift1", "line": 141, "span": [141, 1, 141, 5] },
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "udrift1", "line": 142, "span": [142, 1, 142, 5] }
                    ]
                },

                // Sequence with present.len() < 2 (line 315) -> has only "b"
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "udrift_short", "line": 150,
                    "calls": [
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "udrift_short", "line": 151, "span": [151, 1, 151, 5] }
                    ]
                },

                // Sequences to test low confidence drift check (line 324)
                // We add another 3 sequences with "a" and "b" to increase denominator to 8.
                // Then confidence for b -> a is 4 / 8 = 0.5 < 0.75, which skips it!
                // To achieve this, let's keep this test simple and not add it, or verify both high and low confidence.
                // Actually, just having udrift1 is enough to cover >= 0.75.
                // To trigger < 0.75, let's add some more matching sequences:
                {
                    "file": "foo.rb", "owner": "ClassA", "name": "ulow_conf1", "line": 160,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "ClassA", "defn": "ulow_conf1", "line": 161, "span": [161, 1, 161, 5] },
                        { "mid": "b", "file": "foo.rb", "owner": "ClassA", "defn": "ulow_conf1", "line": 162, "span": [162, 1, 162, 5] }
                    ]
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc_main]);
        // ordered protocols:
        // a -> b (support = 5, write_read)
        // c -> d (support = 4, write_write)
        // e -> f (support = 4, read_write)
        // plus b -> a (support = 1, read_write)
        assert_eq!(report.ordered_protocols.len(), 4);
        assert_eq!(report.ordered_protocols[0].protocol, vec!["a", "b"]);
        assert_eq!(report.ordered_protocols[0].dependency, vec!["write_read"]);

        assert_eq!(report.ordered_protocols[1].protocol, vec!["c", "d"]);
        assert_eq!(report.ordered_protocols[1].dependency, vec!["write_write"]);

        assert_eq!(report.ordered_protocols[2].protocol, vec!["e", "f"]);
        assert_eq!(report.ordered_protocols[2].dependency, vec!["read_write"]);

        // drift check:
        // udrift1 has "b" then "a" -> confidence is 4 / 6 = 0.67 < 0.75, so it is skipped.
        // Wait, if confidence is 0.67, it is skipped.
        // What if we want it to NOT be skipped?
        // If we remove the "ulow_conf1" sequence, denominator is 5, confidence is 4/5 = 0.8 >= 0.75.
        // Then we get a drift result!
        // Let's check: report.order_drift.is_empty() because confidence = 0.67 < 0.75.
        assert_eq!(report.order_drift.len(), 1);
        assert_eq!(report.order_drift[0].protocol, vec!["a", "b"]);
        assert_eq!(report.order_drift[0].observed, vec!["b", "a"]);
    }
}
