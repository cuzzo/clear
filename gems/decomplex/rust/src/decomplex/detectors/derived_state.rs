use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DerivedStateRow {
    pub file: String,
    pub defn: String,
    pub derived: String,
    pub source: String,
    pub derived_at: usize,
    pub source_reassigned_at: usize,
    pub gap: isize,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Asgn {
    name: String,
    deps: Vec<String>,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<Vec<DerivedStateRow>> {
    let mut out = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let detector = DerivedState::new(file.to_string_lossy().to_string(), lines);
        detector.each_method(&root, &mut |file, defn, stmts| {
            out.extend(analyze(file, defn, stmts));
        });
    }
    out.sort_by(|a, b| b.gap.cmp(&a.gap));
    Ok(out)
}

struct DerivedState {
    file: String,
    #[allow(dead_code)]
    lines: Vec<String>,
}

impl DerivedState {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines }
    }

    fn each_method(&self, node: &Node, blk: &mut dyn FnMut(&str, &str, &[&Node])) {
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                blk(&self.file, name, &ast::body_stmts(node));
            }
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.each_method(child, blk);
        }
    }
}

const BRANCH_RHS: &[&str] = &[
    "IF", "CASE", "CASE2", "CASE3", "AND", "OR", "WHILE", "UNTIL", "RESCUE", "ENSURE",
];

fn lasgns<'a>(stmts: &'a [&'a Node]) -> Vec<&'a Node> {
    let mut acc = Vec::new();
    for s in stmts {
        walk_lasgns(s, &mut acc);
    }
    acc
}

fn walk_lasgns<'a>(n: &'a Node, acc: &mut Vec<&'a Node>) {
    if n.r#type == "LASGN" {
        acc.push(n);
        if let Some(val) = n.children.get(1).and_then(ast::node) {
            if BRANCH_RHS.contains(&val.r#type.as_str()) {
                // branch-local RHS: do not flatten its inner assignments
            } else {
                for child in n.children.iter().filter_map(ast::node) {
                    walk_lasgns(child, acc);
                }
            }
        }
    } else {
        for child in n.children.iter().filter_map(ast::node) {
            walk_lasgns(child, acc);
        }
    }
}

fn lvars(node: &Node, acc: &mut Vec<String>) {
    if node.r#type == "LVAR" {
        if let Some(Child::String(name)) = node.children.first() {
            acc.push(name.clone());
        }
    }
    for child in node.children.iter().filter_map(ast::node) {
        lvars(child, acc);
    }
}

fn analyze(file: &str, defn: &str, stmts: &[&Node]) -> Vec<DerivedStateRow> {
    let asgns: Vec<_> = lasgns(stmts)
        .iter()
        .map(|n| {
            let mut deps = Vec::new();
            if let Some(val) = n.children.get(1).and_then(ast::node) {
                lvars(val, &mut deps);
            }
            let mut deps: Vec<_> = deps.into_iter().collect::<BTreeSet<_>>().into_iter().collect();
            deps.sort();
            Asgn {
                name: match n.children.first().unwrap() {
                    Child::String(s) => s.clone(),
                    _ => panic!("LASGN without name"),
                },
                deps,
                line: n.first_lineno,
                span: [n.first_lineno, n.first_column, n.last_lineno, n.last_column],
            }
        })
        .collect();

    let mut out = Vec::new();
    for (i, b) in asgns.iter().enumerate() {
        if b.deps.is_empty() {
            continue;
        }

        for a in &b.deps {
            if a == &b.name {
                continue;
            }

            // a reassigned strictly after b's definition?
            let reasn = asgns.iter().skip(i + 1).find(|x| &x.name == a);
            let Some(reasn) = reasn else { continue };

            // b recomputed at or after a's reassignment?
            let recomputed = asgns.iter().skip(i + 1).any(|x| &x.name == &b.name && x.line >= reasn.line);
            if recomputed {
                continue;
            }

            let loc = format!("{}:{}:{}", file, defn, b.line);
            let mut spans = BTreeMap::new();
            spans.insert(loc.clone(), b.span);

            out.push(DerivedStateRow {
                file: file.to_string(),
                defn: defn.to_string(),
                derived: b.name.clone(),
                source: a.clone(),
                derived_at: b.line,
                source_reassigned_at: reasn.line,
                gap: (reasn.line as isize) - (b.line as isize),
                at: loc,
                spans,
            });
        }
    }
    out
}
