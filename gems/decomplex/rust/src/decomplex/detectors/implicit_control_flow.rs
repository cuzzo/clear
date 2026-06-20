use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, Document, Language};
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
    file: String,
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
        .function_defs
        .iter()
        .filter_map(|function_def| {
            let defn = protocol_method_name(&function_def.name);
            let calls = document
                .call_sites
                .iter()
                .filter(|call| {
                    call.owner == function_def.owner
                        && call.function == function_def.name
                        && call.receiver == "self"
                })
                .map(|call| {
                    let mid = protocol_method_name(&call.message);
                    let effect = effect_index.effect_for(&function_def.owner, &mid);
                    Call {
                        mid,
                        file: call.file.clone(),
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
                file: function_def.file.clone(),
                owner: function_def.owner.clone(),
                defn,
                line: function_def.line,
                calls,
            })
        })
        .collect()
}

fn protocol_method_name(name: &str) -> String {
    name.split(['.', ':'])
        .filter(|part| !part.is_empty())
        .last()
        .unwrap_or(name)
        .to_string()
}

fn normalize_protocol_state(name: &str) -> String {
    name.trim_start_matches('@')
        .trim_end_matches('=')
        .to_string()
}

struct EffectIndex {
    by_owner_name: BTreeMap<(String, String), MethodEffect>,
    by_name: BTreeMap<String, Vec<MethodEffect>>,
}

impl EffectIndex {
    fn build_documents(documents: &[Document]) -> Self {
        let mut effects = Vec::new();
        for document in documents {
            for function_def in &document.function_defs {
                let mut reads = document
                    .state_reads
                    .iter()
                    .filter(|read| {
                        read.owner == function_def.owner && read.function == function_def.name
                    })
                    .map(|read| normalize_protocol_state(&read.field))
                    .collect::<Vec<_>>();
                reads.sort();
                reads.dedup();

                let mut writes = document
                    .state_writes
                    .iter()
                    .filter(|write| {
                        write.owner == function_def.owner && write.function == function_def.name
                    })
                    .map(|write| normalize_protocol_state(&write.field))
                    .collect::<Vec<_>>();
                writes.sort();
                writes.dedup();

                effects.push(MethodEffect {
                    owner: function_def.owner.clone(),
                    name: protocol_method_name(&function_def.name),
                    reads,
                    writes,
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
        protocol
            .iter()
            .any(|m| OPTIONAL_DIAGNOSTIC_MIDS.contains(&m.as_str()))
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
