use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
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
const PREDICATE_NODES: &[&str] = &["IF", "WHILE", "UNTIL"];

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<ResultReport> {
    let mut findings = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut scanner = OversizedPredicate::new(file.to_string_lossy().to_string(), lines, LIMIT);
        scanner.walk(&root, &Vec::new());
        findings.extend(scanner.findings);
    }
    Ok(ResultReport { findings })
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

        let atoms = self.condition_atoms(cond);
        if atoms.len() <= self.limit {
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

        let atoms_text: Vec<String> = atoms.into_iter().map(|a| ast::slice(a, &self.lines)).collect();

        self.findings.push(OversizedPredicateRow {
            at,
            count: atoms_text.len(),
            predicate: ast::slice(cond, &self.lines),
            atoms: atoms_text,
            spans,
        });
    }

    fn condition_atoms<'a>(&self, node: &'a Node) -> Vec<&'a Node> {
        match node.r#type.as_str() {
            "AND" | "OR" => node
                .children
                .iter()
                .filter_map(ast::node)
                .flat_map(|child| self.condition_atoms(child))
                .collect(),
            "NOT" => {
                if let Some(child) = node.children.get(0).and_then(ast::node) {
                    self.condition_atoms(child)
                } else {
                    vec![node]
                }
            }
            _ => vec![node],
        }
    }

    fn predicate_helper(&self, name: &str) -> bool {
        name.ends_with('?')
    }
}
