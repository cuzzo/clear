use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, Document, Language, PredicateAlias};
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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PredicateAliasReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> PredicateAliasReport {
    let predicates = documents
        .iter()
        .flat_map(|document| document.predicate_aliases.clone())
        .collect::<Vec<_>>();
    PredicateAliasReport {
        alias_clusters: alias_clusters(&predicates),
    }
}

fn alias_clusters(predicates: &[PredicateAlias]) -> Vec<AliasCluster> {
    let mut by_body: Vec<(&str, Vec<&PredicateAlias>)> = Vec::new();
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

#[cfg(test)]
mod tests {
    use super::*;

    fn pred(name: &str, body: &str, line: usize) -> PredicateAlias {
        PredicateAlias {
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
