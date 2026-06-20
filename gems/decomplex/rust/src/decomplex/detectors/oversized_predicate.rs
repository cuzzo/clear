use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct OversizedPredicateRow {
    pub at: String,
    pub count: usize,
    pub predicate: String,
    pub atoms: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ResultReport {
    pub findings: Vec<OversizedPredicateRow>,
}

const LIMIT: usize = 3;
const PREDICATE_NODES: &[&str] = &["IF", "UNLESS", "WHILE", "UNTIL"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<ResultReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> ResultReport {
    let mut findings = Vec::new();
    for document in documents {
        let mut scanner =
            OversizedPredicate::new(document.file.clone(), document.lines.clone(), LIMIT);
        scanner.walk(&document.normalized_root, &Vec::new());
        findings.extend(scanner.findings);
    }
    ResultReport { findings }
}

struct OversizedPredicate {
    file: String,
    lines: Vec<String>,
    limit: usize,
    findings: Vec<OversizedPredicateRow>,
}

impl OversizedPredicate {
    fn new(file: String, lines: Vec<String>, limit: usize) -> Self {
        Self {
            file,
            lines,
            limit,
            findings: Vec::new(),
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

        self.record_predicate(node, &next_defstack);

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn record_predicate(&mut self, node: &Node, defstack: &[String]) {
        if !PREDICATE_NODES.contains(&node.r#type.as_str()) {
            return;
        }

        let defn = defstack.last().map(|s| s.as_str()).unwrap_or("<top>");
        if self.predicate_helper(defn) {
            return;
        }

        let cond = node.children.get(0).and_then(ast::node);
        let Some(cond) = cond else { return };

        let predicate = ast::slice(cond, &self.lines);
        let atoms_text = self.condition_atoms(&predicate);
        if atoms_text.len() <= self.limit {
            return;
        }

        let at = format!("{}:{}:{}", self.file, defn, node.first_lineno);
        let mut spans = BTreeMap::new();
        spans.insert(
            at.clone(),
            [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        );

        self.findings.push(OversizedPredicateRow {
            at,
            count: atoms_text.len(),
            predicate,
            atoms: atoms_text,
            spans,
        });
    }

    fn condition_atoms(&self, predicate: &str) -> Vec<String> {
        predicate
            .split("&&")
            .flat_map(|part| part.split("||"))
            .flat_map(|part| part.split(" and "))
            .flat_map(|part| part.split(" or "))
            .map(|atom| atom.replace(['(', ')'], "").trim().to_string())
            .filter(|atom| !atom.is_empty())
            .collect()
    }

    fn predicate_helper(&self, name: &str) -> bool {
        name.ends_with('?')
    }
}
