use crate::decomplex::ast::Span;
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
pub fn scan_files(files: &[PathBuf], language: Language) -> Result<ResultReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> ResultReport {
    let mut findings = Vec::new();
    for document in documents {
        let scanner = OversizedPredicate::new(LIMIT);
        for site in &document.decision_sites {
            if let Some(finding) = scanner.finding_for_site(site) {
                findings.push(finding);
            }
        }
    }
    ResultReport { findings }
}

struct OversizedPredicate {
    limit: usize,
}

impl OversizedPredicate {
    fn new(limit: usize) -> Self {
        Self { limit }
    }

    fn finding_for_site(
        &self,
        site: &crate::decomplex::syntax::DecisionSite,
    ) -> Option<OversizedPredicateRow> {
        if self.predicate_helper(&site.function) {
            return None;
        }
        let atoms_text = self.condition_atoms(&site.predicate);
        if atoms_text.len() <= self.limit {
            return None;
        }

        let at = format!("{}:{}:{}", site.file, site.function, site.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), site.enclosing_span);

        Some(OversizedPredicateRow {
            at,
            count: atoms_text.len(),
            predicate: site.predicate.clone(),
            atoms: atoms_text,
            spans,
        })
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
