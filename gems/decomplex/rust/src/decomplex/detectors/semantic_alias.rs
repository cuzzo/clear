use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<SemanticAliasReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> SemanticAliasReport {
    let mut preds = Vec::new();
    let mut uses = Vec::new();
    for document in documents {
        let dialect = crate::decomplex::dialect::dialect_for_document(document);
        for predicate in &document.predicate_aliases {
            if !semantic_predicate_definition(&predicate.name, &predicate.body) {
                continue;
            }
            preds.push(Pred {
                name: predicate.name.clone(),
                canon: canon(&predicate.body, &*dialect),
                file: predicate.file.clone(),
                line: predicate.line,
                span: predicate.span,
            });
        }
        uses.extend(document.comparison_uses.iter().map(|comparison| Use {
            canon: canon(&comparison.raw, &*dialect),
            file: comparison.file.clone(),
            defn: comparison.function.clone(),
            line: comparison.line,
            raw: comparison.raw.clone(),
            span: comparison.span,
        }));
    }
    Report::new(preds, uses).findings()
}

fn canon(text: &str, dialect: &dyn crate::decomplex::dialect::Dialect) -> String {
    let (t, _) = canon_polarity(text);
    dialect.canonicalize_predicate(&t)
}

fn canon_polarity(text: &str) -> (String, bool) {
    let trimmed = text.trim();
    if let Some(rest) = trimmed.strip_prefix('!') {
        (
            rest.trim_start_matches('(')
                .trim_end_matches(')')
                .trim()
                .to_string(),
            true,
        )
    } else {
        (trimmed.to_string(), false)
    }
}

fn semantic_predicate_definition(name: &str, body: &str) -> bool {
    name.ends_with('?')
        || body.contains("==")
        || body.contains("!=")
        || body.contains("&&")
        || body.contains("||")
        || body.contains(" and ")
        || body.contains(" or ")
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
        let mut keys = Vec::new();
        let mut by_canon: BTreeMap<String, Vec<&Pred>> = BTreeMap::new();
        for p in &self.preds {
            if !by_canon.contains_key(&p.canon) {
                keys.push(p.canon.clone());
            }
            by_canon.entry(p.canon.clone()).or_default().push(p);
        }

        let mut out = Vec::new();
        for c in keys {
            let ps = by_canon.remove(&c).unwrap();
            let mut names = Vec::new();
            for p in &ps {
                if !names.contains(&p.name) {
                    names.push(p.name.clone());
                }
            }
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
                if ps.is_empty() {
                    continue;
                }
                if ps.iter().any(|p| p.name == u.defn) {
                    continue;
                }

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
