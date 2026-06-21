use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, CallSite, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BrokenProtocolReport {
    pub broken: Vec<BrokenProtocol>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BrokenProtocol {
    pub pair: Vec<String>,
    pub support: usize,
    pub confidence: f64,
    pub has: String,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Call {
    mid: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<BrokenProtocolReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> BrokenProtocolReport {
    let mut calls = Vec::new();
    for document in documents {
        for call in &document.call_sites {
            let mid = call.message.to_string();
            for nested_mid in nested_protocol_events(call, document) {
                calls.push(Call {
                    mid: nested_mid,
                    file: call.file.clone(),
                    defn: call.function.clone(),
                    line: call.line,
                    span: call.span,
                });
            }

            if protocol_event(call, &mid) {
                calls.push(Call {
                    mid,
                    file: call.file.clone(),
                    defn: call.function.clone(),
                    line: call.line,
                    span: call.span,
                });
            }
        }
    }
    Report::new(calls).findings()
}

const DECLARATIVE_MIDS: &[&str] = &[
    "abstract!",
    "alias_method",
    "any",
    "attr_accessor",
    "attr_reader",
    "attr_writer",
    "bind",
    "cast",
    "checked",
    "enum",
    "extend",
    "final",
    "include",
    "interface!",
    "let",
    "must",
    "must_because",
    "nilable",
    "override",
    "overridable",
    "params",
    "prepend",
    "private",
    "private_class_method",
    "public",
    "require",
    "require_relative",
    "requires_ancestor",
    "sealed!",
    "sig",
    "type_member",
    "type_template",
    "untyped",
    "unsafe",
    "void",
];
const TEST_DSL_MIDS: &[&str] = &[
    "a_kind_of",
    "after",
    "around",
    "before",
    "be",
    "be_a",
    "be_an",
    "be_empty",
    "be_falsey",
    "be_nil",
    "be_truthy",
    "change",
    "contain_exactly",
    "context",
    "describe",
    "eq",
    "eql",
    "equal",
    "expect",
    "have_attributes",
    "have_key",
    "have_received",
    "it",
    "match",
    "not_to",
    "raise_error",
    "receive",
    "subject",
    "to",
];
const ZERO_ARG_ACTION_MIDS: &[&str] = &[
    "acquire",
    "begin",
    "close",
    "commit",
    "connect",
    "deinit",
    "disconnect",
    "drain",
    "finish",
    "flush",
    "lock",
    "open",
    "release",
    "rollback",
    "start",
    "stop",
    "unlock",
    "wait",
];
const ZERO_ARG_ACTION_PREFIXES: &[&str] = &[
    "analyze",
    "append",
    "apply",
    "build",
    "call",
    "check",
    "classify",
    "collect",
    "compile",
    "compute",
    "consume",
    "create",
    "declare",
    "emit",
    "enforce",
    "finalize",
    "find",
    "flush",
    "handle",
    "initialize",
    "lower",
    "mark",
    "normalize",
    "parse",
    "perform",
    "process",
    "push",
    "record",
    "register",
    "render",
    "resolve",
    "rewrite",
    "run",
    "scan",
    "set",
    "stamp",
    "sync",
    "transform",
    "validate",
    "verify",
    "visit",
    "walk",
    "warn",
    "write",
];

fn protocol_event(call: &CallSite, mid: &str) -> bool {
    !ignored_mid(mid) && !passive_reader_call(call, mid)
}

fn passive_reader_call(call: &CallSite, mid: &str) -> bool {
    if zero_arg_action_name(mid) {
        return false;
    }

    call.arguments.is_empty()
}

fn nested_protocol_events(call: &CallSite, document: &Document) -> Vec<String> {
    if !ignored_mid(&call.message) {
        return Vec::new();
    }

    let mut candidates = call.arguments.clone();
    candidates.extend(
        source_text(&document.lines, call.span)
            .split(|ch: char| !(ch == '_' || ch == '!' || ch == '?' || ch.is_ascii_alphanumeric()))
            .filter_map(protocol_word),
    );
    let mut out = Vec::new();
    for candidate in candidates {
        if !out.contains(&candidate) && !ignored_mid(&candidate) && zero_arg_action_name(&candidate)
        {
            out.push(candidate);
        }
    }
    out
}

fn protocol_word(text: &str) -> Option<String> {
    let word = text.trim();
    if word.is_empty() {
        return None;
    }
    let mut chars = word.chars();
    let first = chars.next()?;
    if !(first == '_' || first.is_ascii_lowercase()) {
        return None;
    }
    if !chars.all(|ch| ch == '_' || ch == '!' || ch == '?' || ch.is_ascii_alphanumeric()) {
        return None;
    }
    Some(word.to_string())
}

fn source_text(lines: &[String], span: Span) -> String {
    let [first_line, first_column, last_line, last_column] = span;
    if first_line == 0 || last_line == 0 {
        return String::new();
    }
    if first_line == last_line {
        return lines
            .get(first_line - 1)
            .and_then(|line| line.get(first_column..last_column))
            .unwrap_or("")
            .to_string();
    }

    let mut parts = Vec::new();
    parts.push(
        lines
            .get(first_line - 1)
            .and_then(|line| line.get(first_column..))
            .unwrap_or("")
            .to_string(),
    );
    for line_index in first_line..last_line.saturating_sub(1) {
        if let Some(line) = lines.get(line_index) {
            parts.push(line.clone());
        }
    }
    parts.push(
        lines
            .get(last_line - 1)
            .and_then(|line| line.get(..last_column))
            .unwrap_or("")
            .to_string(),
    );
    parts.join("")
}

struct PairSupport {
    pair: Vec<String>,
    support: usize,
    sites: Vec<(String, String)>,
}

struct Report {
    by_unit: Vec<((String, String), Vec<Call>)>,
    support: BTreeMap<String, usize>,
}

impl Report {
    fn new(calls: Vec<Call>) -> Self {
        let mut by_unit: Vec<((String, String), Vec<Call>)> = Vec::new();
        for call in calls {
            let key = (call.file.clone(), call.defn.clone());
            if let Some((_, unit_calls)) = by_unit.iter_mut().find(|(existing, _)| existing == &key)
            {
                unit_calls.push(call);
            } else {
                by_unit.push((key, vec![call]));
            }
        }

        let mut support = BTreeMap::new();
        for (_, calls) in &by_unit {
            for mid in unique_mids(calls) {
                *support.entry(mid).or_insert(0) += 1;
            }
        }

        Self { by_unit, support }
    }

    fn findings(&self) -> BrokenProtocolReport {
        BrokenProtocolReport {
            broken: self.broken_protocol(4, 0.75),
        }
    }

    fn broken_protocol(&self, min_support: usize, min_confidence: f64) -> Vec<BrokenProtocol> {
        let pairs = self.co_called_pairs(min_support);
        let mut out = Vec::new();
        for ((file, defn), calls) in &self.by_unit {
            let mids = unique_mids(calls);
            for pair in &pairs {
                let (has, missing) =
                    if mids.contains(&pair.pair[0]) && !mids.contains(&pair.pair[1]) {
                        (pair.pair[0].clone(), pair.pair[1].clone())
                    } else if mids.contains(&pair.pair[1]) && !mids.contains(&pair.pair[0]) {
                        (pair.pair[1].clone(), pair.pair[0].clone())
                    } else {
                        continue;
                    };
                let denominator = *self.support.get(&has).unwrap_or(&0);
                if denominator == 0 {
                    continue;
                }
                let confidence = pair.support as f64 / denominator as f64;
                if confidence < min_confidence {
                    continue;
                }
                let Some(has_call) =
                    calls
                        .iter()
                        .filter(|call| call.mid == has)
                        .min_by(|left, right| {
                            left.line
                                .cmp(&right.line)
                                .then_with(|| left.span.cmp(&right.span))
                                .then_with(|| left.mid.cmp(&right.mid))
                        })
                else {
                    continue;
                };
                let loc = format!("{}:{}:{}", file, defn, has_call.line);
                let mut spans = BTreeMap::new();
                spans.insert(loc.clone(), has_call.span);
                out.push(BrokenProtocol {
                    pair: pair.pair.clone(),
                    support: pair.support,
                    confidence: (confidence * 100.0).round() / 100.0,
                    has,
                    missing,
                    at: loc,
                    spans,
                });
            }
        }
        out.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap()
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.at.cmp(&b.at))
        });
        out
    }

    fn co_called_pairs(&self, min_support: usize) -> Vec<PairSupport> {
        let mut counts: Vec<PairSupport> = Vec::new();
        for (unit, calls) in &self.by_unit {
            let mids = unique_mids(calls);
            for i in 0..mids.len() {
                for j in i + 1..mids.len() {
                    let pair = vec![mids[i].clone(), mids[j].clone()];
                    if let Some(existing) = counts.iter_mut().find(|row| row.pair == pair) {
                        existing.support += 1;
                        existing.sites.push(unit.clone());
                    } else {
                        counts.push(PairSupport {
                            pair,
                            support: 1,
                            sites: vec![unit.clone()],
                        });
                    }
                }
            }
        }
        let mut out: Vec<_> = counts
            .into_iter()
            .filter(|row| row.support >= min_support)
            .collect();
        out.sort_by(|a, b| b.support.cmp(&a.support));
        out
    }
}

fn ignored_mid(mid: &str) -> bool {
    DECLARATIVE_MIDS.contains(&mid) || TEST_DSL_MIDS.contains(&mid)
}

fn zero_arg_action_name(mid: &str) -> bool {
    ZERO_ARG_ACTION_MIDS.contains(&mid)
        || mid.ends_with('!')
        || ZERO_ARG_ACTION_PREFIXES
            .iter()
            .any(|prefix| mid == *prefix || mid.starts_with(&format!("{prefix}_")))
}

fn unique_mids(calls: &[Call]) -> Vec<String> {
    let set: BTreeSet<_> = calls.iter().map(|call| call.mid.clone()).collect();
    set.into_iter().collect()
}
