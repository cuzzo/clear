use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PredicateAliasReport> {
    let mut preds = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut p = PredicateAlias::new(file.to_string_lossy().to_string(), lines);
        p.walk(&root);
        preds.extend(p.preds);
    }
    Ok(Report::new(preds).findings())
}

struct PredicateAlias {
    file: String,
    lines: Vec<String>,
    preds: Vec<Pred>,
}

impl PredicateAlias {
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
        let name = match node.children.get(0) {
            Some(Child::Symbol(s)) => s.clone(),
            _ => return,
        };
        let scope = node.children.get(1).and_then(ast::node);
        let Some(scope) = scope else { return };
        if scope.r#type != "SCOPE" {
            return;
        };

        let body = scope.children.get(2).and_then(ast::node);
        let Some(body) = body else { return };
        if body.r#type == "BLOCK" {
            return;
        };

        let txt = ast::slice(body, &self.lines);
        if txt.is_empty() || txt.len() > 200 {
            return;
        };

        self.preds.push(Pred {
            name: name.clone(),
            body: txt,
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

struct Report {
    preds: Vec<Pred>,
}

impl Report {
    fn new(preds: Vec<Pred>) -> Self {
        Self { preds }
    }

    fn findings(&self) -> PredicateAliasReport {
        PredicateAliasReport {
            alias_clusters: self.alias_clusters(),
        }
    }

    fn alias_clusters(&self) -> Vec<AliasCluster> {
        let mut keys = Vec::new();
        let mut by_body: BTreeMap<String, Vec<&Pred>> = BTreeMap::new();
        for p in &self.preds {
            if !by_body.contains_key(&p.body) {
                keys.push(p.body.clone());
            }
            by_body.entry(p.body.clone()).or_default().push(p);
        }

        let mut out = Vec::new();
        for body in keys {
            let ps = by_body.remove(&body).unwrap();
            let mut names_set = BTreeSet::new();
            for p in &ps {
                names_set.insert(p.name.clone());
            }
            let names: Vec<_> = names_set.into_iter().collect();
            if names.len() < 2 {
                continue;
            }

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for p in &ps {
                let loc = format!("{}:{}:{}", p.file, p.name, p.line);
                sites.push(loc.clone());
                spans.insert(loc, p.span);
            }

            out.push(AliasCluster {
                body,
                names,
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| b.names.len().cmp(&a.names.len()));
        out
    }
}
