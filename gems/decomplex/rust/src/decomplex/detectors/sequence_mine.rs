use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
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
    let mut calls = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut sm = SequenceMine::new(file.to_string_lossy().to_string(), lines);
        sm.walk(&root, &Vec::new());
        calls.extend(sm.calls);
    }
    Ok(Report::new(calls).findings())
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

struct SequenceMine {
    file: String,
    #[allow(dead_code)]
    lines: Vec<String>,
    calls: Vec<Call>,
}

impl SequenceMine {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            calls: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        if matches!(node.r#type.as_str(), "CALL" | "FCALL" | "VCALL") {
            if let Some(mid) = self.call_mid(node) {
                if self.protocol_event(node, &mid) {
                    self.calls.push(Call {
                        mid,
                        file: self.file.clone(),
                        defn: next_defstack
                            .last()
                            .cloned()
                            .unwrap_or_else(|| "(top-level)".to_string()),
                        line: node.first_lineno,
                        span: [
                            node.first_lineno,
                            node.first_column,
                            node.last_lineno,
                            node.last_column,
                        ],
                    });
                }
            }
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn protocol_event(&self, node: &Node, mid: &str) -> bool {
        !ignored_mid(mid) && !self.passive_reader_call(node, mid)
    }

    fn passive_reader_call(&self, node: &Node, mid: &str) -> bool {
        if zero_arg_action_name(mid) {
            return false;
        }

        match node.r#type.as_str() {
            "CALL" => no_args(node.children.get(2)),
            "VCALL" => true,
            "FCALL" => no_args(node.children.get(1)),
            _ => false,
        }
    }

    fn call_mid(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "CALL" => ast::child_to_string(node.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }
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
                let Some(has_call) = calls.iter().find(|call| call.mid == has) else {
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

fn no_args(child: Option<&Child>) -> bool {
    child.is_none() || matches!(child, Some(Child::Nil))
}

fn unique_mids(calls: &[Call]) -> Vec<String> {
    let set: BTreeSet<_> = calls.iter().map(|call| call.mid.clone()).collect();
    set.into_iter().collect()
}
