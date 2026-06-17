use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FatUnionReport {
    pub fat_unions: Vec<FatUnionRow>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FatUnionRow {
    pub name: String,
    pub common: Vec<String>,
    pub variant_set: Vec<String>,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Read {
    name: String,
    span: Span,
}

#[derive(Clone, Debug)]
struct VariantReads {
    reads: Vec<Read>,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<FatUnionReport> {
    let mut out = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut detector = FatUnion::new(file.to_string_lossy().to_string(), lines);
        detector.walk(&root, &Vec::new());
        out.extend(detector.findings());
    }
    out.sort_by(|a, b| b.common.len().cmp(&a.common.len()).then_with(|| a.at.cmp(&b.at)));
    Ok(FatUnionReport { fat_unions: out })
}

struct FatUnion {
    file: String,
    lines: Vec<String>,
    reports: Vec<FatUnionRow>,
}

impl FatUnion {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines, reports: Vec::new() }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        if matches!(node.r#type.as_str(), "CASE" | "CASE2") {
            self.analyze_case(node, &next_defstack);
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn analyze_case(&mut self, node: &Node, defstack: &[String]) {
        let (cond, first_when) = if node.r#type == "CASE2" {
            (None, node.children.get(0).and_then(ast::node))
        } else {
            (node.children.get(0).and_then(ast::node), node.children.get(1).and_then(ast::node))
        };

        let mut variants = BTreeMap::new();
        let mut current_when = first_when;
        while let Some(when_node) = current_when {
            if when_node.r#type != "WHEN" { break; }
            if let Some(pat) = when_node.children.get(0).and_then(ast::node) {
                if let Some(variant_name) = self.variant_name(pat) {
                    let reads = self.collect_reads(when_node.children.get(1).and_then(ast::node).unwrap_or(when_node));
                    variants.insert(variant_name, VariantReads { reads });
                }
            }
            current_when = when_node.children.get(2).and_then(ast::node);
        }

        if variants.len() < 2 { return; }

        let mut common = None;
        for v in variants.values() {
            let names: BTreeSet<_> = v.reads.iter().map(|r| r.name.clone()).collect();
            match common {
                None => common = Some(names),
                Some(ref mut c) => {
                    *c = c.intersection(&names).cloned().collect();
                }
            }
        }

        let common = common.unwrap_or_default();
        if common.is_empty() { return; }

        let subject_name = self.subject_name(cond);
        let defn = defstack.last().map(|s| s.as_str()).unwrap_or("<top>");
        let at = format!("{}:{}:{}", self.file, defn, node.first_lineno);
        
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), [node.first_lineno, node.first_column, node.last_lineno, node.last_column]);

        let mut variant_set: Vec<_> = variants.keys().cloned().collect();
        variant_set.sort();
        let mut common_vec: Vec<_> = common.into_iter().collect();
        common_vec.sort();

        self.reports.push(FatUnionRow {
            name: subject_name,
            common: common_vec,
            variant_set,
            at,
            spans,
        });
    }

    fn variant_name(&self, node: &Node) -> Option<String> {
        let n = if node.r#type == "LIST" { node.children.iter().filter_map(ast::node).next()? } else { node };
        match n.r#type.as_str() {
            "CONSTANT" | "SCOPE_RESOLUTION" => Some(ast::slice(n, &self.lines)),
            _ => None
        }
    }

    fn collect_reads(&self, node: &Node) -> Vec<Read> {
        let mut out = Vec::new();
        self.walk_reads(node, &mut out);
        out
    }

    fn walk_reads(&self, node: &Node, out: &mut Vec<Read>) {
        if matches!(node.r#type.as_str(), "CALL" | "OPCALL") {
            if let Some(Child::Symbol(mid)) = node.children.get(1) {
                out.push(Read {
                    name: mid.clone(),
                    span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
                });
            }
        } else if matches!(node.r#type.as_str(), "FCALL" | "VCALL") {
            if let Some(Child::Symbol(mid)) = node.children.get(0) {
                out.push(Read {
                    name: mid.clone(),
                    span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
                });
            }
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.walk_reads(child, out);
        }
    }

    fn subject_name(&self, cond: Option<&Node>) -> String {
        cond.map(|c| ast::slice(c, &self.lines)).unwrap_or_else(|| "implicit".to_string())
    }

    fn findings(&self) -> Vec<FatUnionRow> {
        self.reports.clone()
    }
}
