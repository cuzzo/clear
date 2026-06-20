use crate::decomplex::ast::Span;
use crate::decomplex::detectors::local_flow::{self, MethodSummary, Statement};
use crate::decomplex::syntax::{self, Document, Language};
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
    statement_index: usize,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<DerivedStateRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<DerivedStateRow> {
    let mut out = local_flow::scan_documents(documents)
        .iter()
        .flat_map(|method| analyze_method(method))
        .collect::<Vec<_>>();
    out.sort_by(|a, b| b.gap.cmp(&a.gap));
    out
}

fn analyze_method(method: &MethodSummary) -> Vec<DerivedStateRow> {
    analyze(&method.file, &method.name, &assignments(method))
}

fn assignments(method: &MethodSummary) -> Vec<Asgn> {
    method
        .statements
        .iter()
        .flat_map(|statement| {
            statement
                .writes
                .iter()
                .map(|name| Asgn {
                    name: name.clone(),
                    deps: dependencies_for(statement, name),
                    line: statement.line,
                    span: statement.span,
                    statement_index: statement.index,
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn dependencies_for(statement: &Statement, name: &str) -> Vec<String> {
    let mut deps: Vec<_> = statement
        .dependencies
        .iter()
        .filter_map(|(left, right)| {
            if left == name {
                Some(right.clone())
            } else {
                None
            }
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    deps.sort();
    deps
}

fn analyze(file: &str, defn: &str, asgns: &[Asgn]) -> Vec<DerivedStateRow> {
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
            let reasn = asgns
                .iter()
                .skip(i + 1)
                .find(|x| &x.name == a && x.statement_index > b.statement_index);
            let Some(reasn) = reasn else { continue };

            // b recomputed at or after a's reassignment?
            let recomputed = asgns
                .iter()
                .skip(i + 1)
                .any(|x| &x.name == &b.name && x.statement_index >= reasn.statement_index);
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
