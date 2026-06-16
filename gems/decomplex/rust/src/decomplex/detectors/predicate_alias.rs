use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PredicateAliasReport {
    pub alias_clusters: Vec<AliasCluster>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct AliasCluster {
    pub body: String,
    pub names: Vec<String>,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Pred {
    name: String,
    body: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct Scanner {
    file: String,
    lines: Vec<String>,
    preds: Vec<Pred>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PredicateAliasReport> {
    let _ = language;
    let mut preds = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut scanner = Scanner::new(file.to_string_lossy().to_string(), lines);
        scanner.walk(&root);
        preds.extend(scanner.preds);
    }
    Ok(PredicateAliasReport {
        alias_clusters: alias_clusters(&preds),
    })
}

impl Scanner {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            preds: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node) {
        if node.r#type == "DEFN" {
            self.record_def(node);
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child);
        }
    }

    fn record_def(&mut self, node: &Node) {
        let Some(name) = child_to_string(node.children.first()) else {
            return;
        };
        let Some(scope) = node.children.get(1).and_then(ast::node) else {
            return;
        };
        if scope.r#type != "SCOPE" {
            return;
        }
        let Some(body) = scope.children.get(2).and_then(ast::node) else {
            return;
        };
        if body.r#type == "BLOCK" {
            return;
        }

        let text = ast::slice(body, &self.lines);
        if text.is_empty() || text.len() > 200 {
            return;
        }
        self.preds.push(Pred {
            name: name.clone(),
            body: text,
            file: self.file.clone(),
            defn: name,
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

fn alias_clusters(predicates: &[Pred]) -> Vec<AliasCluster> {
    let mut by_body: Vec<(&str, Vec<&Pred>)> = Vec::new();
    for predicate in predicates {
        if let Some((_, rows)) = by_body.iter_mut().find(|(body, _)| *body == predicate.body.as_str()) {
            rows.push(predicate);
        } else {
            by_body.push((predicate.body.as_str(), vec![predicate]));
        }
    }
    let mut out = by_body
        .into_iter()
        .filter_map(|(body, rows)| {
            let mut names = Vec::new();
            for predicate in &rows {
                if !names.contains(&predicate.name) {
                    names.push(predicate.name.clone());
                }
            }
            if names.len() < 2 {
                return None;
            }
            let sites = rows
                .iter()
                .map(|predicate| format!("{}:{}:{}", predicate.file, predicate.name, predicate.line))
                .collect::<Vec<_>>();
            let spans = rows
                .iter()
                .map(|predicate| {
                    (
                        format!("{}:{}:{}", predicate.file, predicate.name, predicate.line),
                        predicate.span,
                    )
                })
                .collect::<BTreeMap<_, _>>();
            Some(AliasCluster {
                body: body.to_string(),
                names,
                sites,
                spans,
            })
        })
        .collect::<Vec<_>>();
    out.sort_by(|left, right| right.names.len().cmp(&left.names.len()));
    out
}

fn child_to_string(child: Option<&Child>) -> Option<String> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pred(name: &str, body: &str, line: usize) -> Pred {
        Pred {
            name: name.to_string(),
            body: body.to_string(),
            file: "a.rb".to_string(),
            defn: name.to_string(),
            line,
            span: [line, 0, line, 1],
        }
    }

    #[test]
    fn clusters_distinct_names_with_same_body() {
        let clusters = alias_clusters(&[
            pred("heap?", "node.storage == :heap", 1),
            pred("owned?", "node.storage == :heap", 2),
            pred("other?", "node.storage == :frame", 3),
        ]);
        assert_eq!(clusters.len(), 1);
        assert_eq!(clusters[0].body, "node.storage == :heap");
        assert_eq!(clusters[0].names, vec!["heap?".to_string(), "owned?".to_string()]);
    }
}
