use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StateBranchDensityRow {
    pub at: String,
    pub file: String,
    pub method: String,
    pub decisions: usize,
    pub state_refs: Vec<String>,
    pub predicate: String,
    pub score: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Debug, Clone)]
struct Decision {
    file: String,
    defn: String,
    line: usize,
    span: Span,
    predicate: String,
    state_refs: Vec<String>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<StateBranchDensityRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<StateBranchDensityRow> {
    let all_decisions = documents
        .iter()
        .flat_map(decisions_from_mined_facts)
        .collect::<Vec<_>>();
    Report::new(all_decisions).findings()
}

fn decisions_from_mined_facts(document: &Document) -> Vec<Decision> {
    filter_wrapper_decisions(
        document
            .branch_decisions
            .iter()
            .map(|decision| Decision {
                file: decision.file.clone(),
                defn: decision.function.clone(),
                line: decision.line,
                span: decision.span,
                predicate: decision.predicate.clone(),
                state_refs: decision.state_refs.clone(),
            })
            .collect(),
    )
}

fn filter_wrapper_decisions(decisions: Vec<Decision>) -> Vec<Decision> {
    decisions
        .iter()
        .filter(|decision| {
            !(wrapper_predicate(&decision.predicate) && nested_state_decision(decision, &decisions))
        })
        .cloned()
        .collect()
}

fn wrapper_predicate(predicate: &str) -> bool {
    ["if", "unless", "while", "until"].iter().any(|prefix| {
        predicate == *prefix
            || predicate
                .strip_prefix(prefix)
                .map(|rest| rest.starts_with(char::is_whitespace))
                .unwrap_or(false)
    })
}

fn nested_state_decision(decision: &Decision, decisions: &[Decision]) -> bool {
    decisions.iter().any(|candidate| {
        !std::ptr::eq(candidate, decision)
            && candidate.defn == decision.defn
            && span_encloses(decision.span, candidate.span)
            && candidate
                .state_refs
                .iter()
                .all(|state_ref| decision.state_refs.contains(state_ref))
    })
}

fn span_encloses(outer: Span, inner: Span) -> bool {
    let starts_before_or_at = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]);
    let ends_after_or_at = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]);
    starts_before_or_at && ends_after_or_at
}

struct Report {
    decisions: Vec<Decision>,
}

impl Report {
    fn new(decisions: Vec<Decision>) -> Self {
        Self { decisions }
    }

    fn findings(&self) -> Vec<StateBranchDensityRow> {
        let mut groups: BTreeMap<(String, String), Vec<Decision>> = BTreeMap::new();
        for d in &self.decisions {
            groups
                .entry((d.file.clone(), d.defn.clone()))
                .or_default()
                .push(d.clone());
        }

        let mut rows = Vec::new();
        for ((file, defn), ds) in groups {
            let mut refs = BTreeSet::new();
            for d in &ds {
                for r in &d.state_refs {
                    refs.insert(r.clone());
                }
            }
            let refs: Vec<_> = refs.into_iter().collect();
            let score = ds.len() * refs.len().max(1);

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for d in &ds {
                let loc = format!("{}:{}:{}", d.file, d.defn, d.line);
                sites.push(loc.clone());
                spans.insert(loc, d.span);
            }

            rows.push(StateBranchDensityRow {
                at: format!("{}:{}:{}", file, defn, ds.first().unwrap().line),
                file,
                method: defn,
                decisions: ds.len(),
                state_refs: refs,
                predicate: ds.first().unwrap().predicate.clone(),
                score,
                sites,
                spans,
            });
        }

        rows.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| b.decisions.cmp(&a.decisions))
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.method.cmp(&b.method))
        });
        rows
    }
}
