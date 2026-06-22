use crate::decomplex::ast::Span;
use crate::decomplex::detectors::local_flow::{self, MethodSummary};
use crate::decomplex::syntax::{self, CallSite, Document, Language};
use anyhow::Result;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::OnceLock;

const TRANSIENT_NOARG_MIDS: &[&str] = &["pop", "shift"];

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DecisionPressureRow {
    pub contract: String,
    pub decisions: usize,
    pub essential: usize,
    pub methods: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Hit {
    contract: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<DecisionPressureRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<DecisionPressureRow> {
    let summaries = local_flow::scan_documents(documents);
    scan_documents_with_summaries(documents, &summaries)
}

pub fn scan_documents_with_summaries(
    documents: &[Document],
    methods: &[MethodSummary],
) -> Vec<DecisionPressureRow> {
    let mut guard = Vec::new();
    let mut dispatch = Vec::new();
    let assignment_maps = build_assignment_maps(&methods);

    for document in documents {
        let eliminable_guard_calls = eliminable_guard_call_keys(document);
        for call in &document.call_sites {
            if call.receiver.is_empty() {
                continue;
            }
            let empty = BTreeMap::new();
            let assignment_map = assignment_maps
                .get(&(call.file.clone(), call.function.clone()))
                .unwrap_or(&empty);
            if essential_dispatch(call) && !eliminable_guard_calls.contains(&call_key(call)) {
                if let Some(contract) = contract_of(&call.receiver, assignment_map, 0) {
                    dispatch.push(hit(contract, call));
                }
            }
        }

        for effect in &document.semantic_effect_sites {
            if effect.kind != "eliminable_guard" {
                continue;
            }
            let empty = BTreeMap::new();
            let assignment_map = assignment_maps
                .get(&(effect.file.clone(), effect.function.clone()))
                .unwrap_or(&empty);
            if let Some(contract) = contract_of(&effect.detail, assignment_map, 0) {
                guard.push(Hit {
                    contract,
                    file: effect.file.clone(),
                    defn: effect.function.clone(),
                    line: effect.line,
                    span: effect.span,
                });
            }
        }
    }

    let mut seen = BTreeSet::new();
    guard.retain(|hit| {
        seen.insert((
            hit.contract.clone(),
            hit.file.clone(),
            hit.defn.clone(),
            hit.line,
        ))
    });

    Report::new(guard, dispatch).ranked()
}

fn eliminable_guard_call_keys(document: &Document) -> BTreeSet<(String, String, usize, Span)> {
    document
        .semantic_effect_sites
        .iter()
        .filter(|effect| effect.kind == "eliminable_guard")
        .map(|effect| {
            (
                effect.file.clone(),
                effect.function.clone(),
                effect.line,
                effect.span,
            )
        })
        .collect()
}

fn call_key(call: &CallSite) -> (String, String, usize, Span) {
    (
        call.file.clone(),
        call.function.clone(),
        call.line,
        call.span,
    )
}

fn essential_dispatch(call: &CallSite) -> bool {
    call.message.ends_with('?')
}

fn hit(contract: String, call: &CallSite) -> Hit {
    Hit {
        contract,
        file: call.file.clone(),
        defn: call.function.clone(),
        line: call.line,
        span: call.span,
    }
}

fn build_assignment_maps(
    methods: &[MethodSummary],
) -> BTreeMap<(String, String), BTreeMap<String, String>> {
    methods
        .iter()
        .map(|method| {
            (
                (method.file.clone(), method.name.clone()),
                local_contract_assignments(method),
            )
        })
        .collect()
}

fn local_contract_assignments(method: &MethodSummary) -> BTreeMap<String, String> {
    local_flow::local_contract_assignments(method)
        .into_iter()
        .filter_map(|(name, source)| contract_of(&source, &BTreeMap::new(), 0).map(|c| (name, c)))
        .collect()
}

fn contract_of(
    receiver: &str,
    assignment_map: &BTreeMap<String, String>,
    depth: usize,
) -> Option<String> {
    let source = receiver.trim();
    if source.is_empty() || depth >= 8 {
        return None;
    }

    if let Some(mapped) = assignment_map.get(source) {
        return Some(mapped.clone());
    }
    if source.starts_with('@') {
        return Some(source.to_string());
    }

    static INDEX_SOURCE: OnceLock<Regex> = OnceLock::new();
    let index_source =
        INDEX_SOURCE.get_or_init(|| Regex::new(r"^(?:[A-Za-z_]\w*|self)\s*\[(.+)\]$").unwrap());
    if let Some(captures) = index_source.captures(source) {
        return Some(format!("[{}]", captures[1].trim()));
    }

    static LOCAL_SOURCE: OnceLock<Regex> = OnceLock::new();
    let local_source = LOCAL_SOURCE.get_or_init(|| Regex::new(r"^[A-Za-z_]\w*$").unwrap());
    if local_source.is_match(source) {
        return Some("~local".to_string());
    }

    if source.contains('.') {
        let mut member = source.split('.').last().unwrap_or("").to_string();
        if let Some(index) = member.find('(') {
            if member.ends_with(')') {
                member.truncate(index);
            }
        }
        if TRANSIENT_NOARG_MIDS.contains(&member.as_str()) || member.is_empty() {
            return None;
        }
        return Some(format!(".{member}"));
    }

    None
}

struct Report {
    guard: Vec<Hit>,
    dispatch: Vec<Hit>,
}

impl Report {
    fn new(guard: Vec<Hit>, dispatch: Vec<Hit>) -> Self {
        Self { guard, dispatch }
    }

    fn ranked(&self) -> Vec<DecisionPressureRow> {
        let mut ess = BTreeMap::new();
        for h in &self.dispatch {
            *ess.entry(&h.contract).or_insert(0) += 1;
        }

        let mut rows_map: Vec<(String, Vec<&Hit>)> = Vec::new();
        for h in &self.guard {
            if let Some((_, hits)) = rows_map
                .iter_mut()
                .find(|(contract, _)| contract == &h.contract)
            {
                hits.push(h);
            } else {
                rows_map.push((h.contract.clone(), vec![h]));
            }
        }

        let rows: Vec<_> = rows_map
            .into_iter()
            .map(|(contract, mut hs)| {
                hs.sort_by(|a, b| {
                    a.file
                        .cmp(&b.file)
                        .then_with(|| a.line.cmp(&b.line))
                        .then_with(|| a.defn.cmp(&b.defn))
                });
                let mut methods_set = BTreeSet::new();
                for h in &hs {
                    methods_set.insert((&h.file, &h.defn));
                }
                let sites = hs.iter().map(|h| loc(h)).collect();
                let spans = hs.iter().map(|h| (loc(h), h.span)).collect();
                let essential = ess.get(&contract).cloned().unwrap_or(0);
                DecisionPressureRow {
                    contract,
                    decisions: hs.len(),
                    essential,
                    methods: methods_set.len(),
                    sites,
                    spans,
                }
            })
            .collect();

        let mut named: Vec<_> = rows
            .iter()
            .filter(|r| r.contract != "~local")
            .cloned()
            .collect();
        named.sort_by(|a, b| {
            b.decisions
                .cmp(&a.decisions)
                .then_with(|| b.methods.cmp(&a.methods))
                .then_with(|| a.contract.cmp(&b.contract))
        });

        let mut local: Vec<_> = rows
            .into_iter()
            .filter(|r| r.contract == "~local")
            .collect();
        local.sort_by(|a, b| {
            b.decisions
                .cmp(&a.decisions)
                .then_with(|| b.methods.cmp(&a.methods))
                .then_with(|| a.contract.cmp(&b.contract))
        });
        named.into_iter().chain(local).collect()
    }
}

fn loc(h: &Hit) -> String {
    format!("{}:{}:{}", h.file, h.defn, h.line)
}
