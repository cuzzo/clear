use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SemanticAliasReport {
    pub alias_clusters: Vec<SemanticAliasCluster>,
    pub reification_misses: Vec<ReificationMiss>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SemanticAliasCluster {
    pub canon: String,
    pub names: Vec<String>,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ReificationMiss {
    pub predicate: String,
    pub canon: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
    pub raw: String,
}

#[derive(Clone, Debug)]
struct Pred {
    name: String,
    canon: String,
    file: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct Use {
    canon: String,
    file: String,
    defn: String,
    line: usize,
    raw: String,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<SemanticAliasReport> {
    let mut preds = Vec::new();
    let mut uses = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut scanner = SemanticAlias::new(file.to_string_lossy().to_string(), lines);
        scanner.walk(&root, &Vec::new());
        preds.extend(scanner.preds);
        uses.extend(scanner.uses);
    }
    Ok(Report::new(preds, uses).findings())
}

struct SemanticAlias {
    file: String,
    lines: Vec<String>,
    preds: Vec<Pred>,
    uses: Vec<Use>,
}

impl SemanticAlias {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            preds: Vec::new(),
            uses: Vec::new(),
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

        if node.r#type == "DEFN" {
            self.record_pred(node);
        }

        if matches!(node.r#type.as_str(), "CALL" | "OPCALL") && self.comparison(node) {
            let c = self.canon(&ast::slice(node, &self.lines));
            self.uses.push(Use {
                canon: c,
                file: self.file.clone(),
                defn: next_defstack.last().cloned().unwrap_or_else(|| "(top-level)".to_string()),
                line: node.first_lineno,
                raw: ast::slice(node, &self.lines),
                span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
            });
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn canon(&self, text: &str) -> String {
        let (mut t, _) = ast::canon_polarity(text);
        t = t.strip_prefix("self.").unwrap_or(&t).to_string();
        t = t.strip_prefix('@').unwrap_or(&t).to_string();
        
        // Ruby: t = t.sub(/\A[A-Za-z_]\w*(?:\([^)]*\))?\.(?=[A-Za-z_]\w*\s*(==|!=|\.))/, "")
        let re = regex::Regex::new(r"^[A-Za-z_]\w*(?:\([^)]*\))?\.(?P<rest>[A-Za-z_]\w*\s*(?:==|!=|\.))").unwrap();
        t = re.replace(&t, "$rest").to_string();

        t.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn comparison(&self, node: &Node) -> bool {
        let mid = node.children.get(1);
        match mid {
            Some(Child::Symbol(s)) => matches!(s.as_str(), "==" | "!=" | "nil?"),
            _ => false
        }
    }

    fn record_pred(&mut self, node: &Node) {
        if let Some(Child::Symbol(name)) = node.children.first() {
            if !name.ends_with('?') { return; }

            let stmts = ast::body_stmts(node);
            if stmts.len() != 1 { return; }

            self.preds.push(Pred {
                name: name.clone(),
                canon: self.canon(&ast::slice(stmts[0], &self.lines)),
                file: self.file.clone(),
                line: node.first_lineno,
                span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
            });
        }
    }
}

struct Report {
    preds: Vec<Pred>,
    uses: Vec<Use>,
}

impl Report {
    fn new(preds: Vec<Pred>, uses: Vec<Use>) -> Self {
        Self { preds, uses }
    }

    fn findings(&self) -> SemanticAliasReport {
        SemanticAliasReport {
            alias_clusters: self.alias_clusters(),
            reification_misses: self.reification_misses(),
        }
    }

    fn alias_clusters(&self) -> Vec<SemanticAliasCluster> {
        let mut by_canon: BTreeMap<String, Vec<&Pred>> = BTreeMap::new();
        for p in &self.preds {
            by_canon.entry(p.canon.clone()).or_default().push(p);
        }

        let mut out = Vec::new();
        for (c, ps) in by_canon {
            let mut names_set = BTreeSet::new();
            for p in &ps { names_set.insert(p.name.clone()); }
            let names: Vec<_> = names_set.into_iter().collect();
            if names.len() < 2 { continue; }

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for p in &ps {
                let loc = format!("{}:{}:{}", p.file, p.name, p.line);
                sites.push(loc.clone());
                spans.insert(loc, p.span);
            }

            out.push(SemanticAliasCluster {
                canon: c,
                names,
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| b.names.len().cmp(&a.names.len()));
        out
    }

    fn reification_misses(&self) -> Vec<ReificationMiss> {
        let mut by_canon: BTreeMap<String, Vec<&Pred>> = BTreeMap::new();
        for p in &self.preds {
            by_canon.entry(p.canon.clone()).or_default().push(p);
        }

        let mut out = Vec::new();
        for u in &self.uses {
            if let Some(ps) = by_canon.get(&u.canon) {
                if ps.is_empty() { continue; }
                if u.defn.ends_with('?') && ps.iter().any(|p| p.name == u.defn) { continue; }

                let loc = format!("{}:{}:{}", u.file, u.defn, u.line);
                let mut spans = BTreeMap::new();
                spans.insert(loc.clone(), u.span);

                out.push(ReificationMiss {
                    predicate: ps[0].name.clone(),
                    canon: u.canon.clone(),
                    at: loc,
                    spans,
                    raw: u.raw.clone(),
                });
            }
        }
        out.sort_by(|a, b| a.predicate.cmp(&b.predicate));
        out
    }
}
