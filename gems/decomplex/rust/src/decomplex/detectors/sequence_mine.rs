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
    pub has: String,
    pub missing: String,
    pub support: usize,
    pub confidence: f64,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Site {
    calls: Vec<String>,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<BrokenProtocolReport> {
    let mut sites = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut sm = SequenceMine::new(file.to_string_lossy().to_string(), lines);
        sm.walk(&root, &Vec::new());
        sites.extend(sm.sites);
    }
    Ok(Report::new(sites).findings())
}

struct SequenceMine {
    file: String,
    lines: Vec<String>,
    sites: Vec<Site>,
}

impl SequenceMine {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            sites: Vec::new(),
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

        if node.r#type == "BLOCK" {
            let calls = self.collect_calls(node);
            if calls.len() >= 2 {
                self.sites.push(Site {
                    calls,
                    file: self.file.clone(),
                    defn: next_defstack.last().cloned().unwrap_or_else(|| "(top-level)".to_string()),
                    line: node.first_lineno,
                    span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
                });
            }
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn collect_calls(&self, block_node: &Node) -> Vec<String> {
        let mut calls = Vec::new();
        for stmt in block_node.children.iter().filter_map(ast::node) {
            if let Some(mid) = self.call_mid(stmt) {
                calls.push(mid);
            }
        }
        calls
    }

    fn call_mid(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" | "ATTRASGN" => ast::child_to_string(node.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }
}

struct Report {
    sites: Vec<Site>,
    counts: BTreeMap<String, usize>,
    co_counts: BTreeMap<(String, String), usize>,
}

impl Report {
    fn new(sites: Vec<Site>) -> Self {
        let mut counts = BTreeMap::new();
        let mut co_counts = BTreeMap::new();

        for s in &sites {
            let unique_calls: BTreeSet<_> = s.calls.iter().cloned().collect();
            let unique_calls: Vec<_> = unique_calls.into_iter().collect();

            for c in &unique_calls {
                *counts.entry(c.clone()).or_insert(0) += 1;
            }

            for i in 0..unique_calls.len() {
                for j in i + 1..unique_calls.len() {
                    let mut pair = vec![unique_calls[i].clone(), unique_calls[j].clone()];
                    pair.sort();
                    *co_counts.entry((pair[0].clone(), pair[1].clone())).or_insert(0) += 1;
                }
            }
        }

        Self {
            sites,
            counts,
            co_counts,
        }
    }

    fn findings(&self) -> BrokenProtocolReport {
        BrokenProtocolReport {
            broken: self.broken_protocols(4, 0.75),
        }
    }

    fn broken_protocols(&self, min_support: usize, min_confidence: f64) -> Vec<BrokenProtocol> {
        let mut rules = Vec::new();
        for ((a, b), &co_count) in &self.co_counts {
            let count_a = *self.counts.get(a).unwrap_or(&0);
            let count_b = *self.counts.get(b).unwrap_or(&0);

            let conf_a = co_count as f64 / count_a as f64;
            let conf_b = co_count as f64 / count_b as f64;

            if conf_a >= min_confidence && co_count >= min_support && count_a > co_count {
                rules.push((a.clone(), b.clone(), co_count, conf_a));
            }
            if conf_b >= min_confidence && co_count >= min_support && count_b > co_count {
                rules.push((b.clone(), a.clone(), co_count, conf_b));
            }
        }

        let mut out = Vec::new();
        let mut seen = BTreeSet::new();

        for s in &self.sites {
            let unique_calls: BTreeSet<_> = s.calls.iter().cloned().collect();

            for (has, missing, sup, conf) in &rules {
                if unique_calls.contains(has) && !unique_calls.contains(missing) {
                    let at = format!("{}:{}:{}", s.file, s.defn, s.line);
                    
                    let key = (has.clone(), missing.clone(), at.clone());
                    if seen.insert(key) {
                        let mut spans = BTreeMap::new();
                        spans.insert(at.clone(), s.span);

                        out.push(BrokenProtocol {
                            has: has.clone(),
                            missing: missing.clone(),
                            support: *sup,
                            confidence: (conf * 100.0).round() / 100.0,
                            at,
                            spans,
                        });
                    }
                }
            }
        }

        out.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap().then_with(|| b.support.cmp(&a.support)).then_with(|| a.at.cmp(&b.at)));
        out
    }
}
