use crate::decomplex::syntax::{self, Document, Language, Span};
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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PredicateAliasReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> PredicateAliasReport {
    let mut preds = Vec::new();
    for document in documents {
        preds.extend(document.predicate_aliases.iter().map(|predicate| Pred {
            name: predicate.name.clone(),
            body: predicate.body.clone(),
            file: predicate.file.clone(),
            defn: predicate.defn.clone(),
            line: predicate.line,
            span: predicate.span,
        }));
    }
    Report::new(preds).findings()
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_predicate_alias_gaps() {
        let doc: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "predicate_aliases": [
                {
                    "name": "a",
                    "body": "x > 0",
                    "file": "foo.rb",
                    "defn": "m",
                    "line": 1,
                    "span": [1, 2, 3, 4]
                }
            ]
        }))
        .unwrap();

        let res = scan_documents(&[doc]);
        assert!(res.alias_clusters.is_empty());
    }
}
