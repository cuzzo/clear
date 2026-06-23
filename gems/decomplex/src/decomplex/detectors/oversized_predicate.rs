use crate::decomplex::syntax::{self, Document, Language, Span};
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_oversized_predicate_gaps() {
        let doc: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "decision_sites": [
                // 1. Function ends with '?' -> None
                {
                    "kind": "if", "members": [], "file": "a.rb", "function": "is_ok?", "line": 1, "span": [1,2,3,4],
                    "predicate": "a && b && c && d", "enclosing_span": [1,2,3,4]
                },
                // 2. Predicate size <= 3 -> None
                {
                    "kind": "if", "members": [], "file": "a.rb", "function": "foo", "line": 2, "span": [1,2,3,4],
                    "predicate": "a && b && c", "enclosing_span": [1,2,3,4]
                },
                // 3. Normal oversized predicate -> Some
                {
                    "kind": "if", "members": [], "file": "a.rb", "function": "foo", "line": 3, "span": [1,2,3,4],
                    "predicate": "a && b && c && d", "enclosing_span": [1,2,3,4]
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc]);
        assert_eq!(report.findings.len(), 1);
        assert_eq!(report.findings[0].count, 4);
    }
}
