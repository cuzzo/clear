use crate::decomplex::ast::Span;
use crate::decomplex::detectors::local_flow::{self, MethodSummary};
use crate::decomplex::syntax::{self, CallSite, Document, Language};
use anyhow::Result;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::OnceLock;

const GUARD_MIDS: &[&str] = &[
    "is_a?",
    "kind_of?",
    "instance_of?",
    "nil?",
    "respond_to?",
    "is_none",
    "is_some",
    "is_null",
    "isNull",
];
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
    scan_documents_with_summaries(documents, local_flow::scan_documents(documents))
}

pub fn scan_documents_with_summaries(
    documents: &[Document],
    methods: Vec<MethodSummary>,
) -> Vec<DecisionPressureRow> {
    let mut guard = Vec::new();
    let mut dispatch = Vec::new();
    let assignment_maps = build_assignment_maps(&methods);
    let methods_by_file = methods_by_file(&methods);

    for document in documents {
        for call in &document.call_sites {
            if call.receiver.is_empty() {
                continue;
            }
            let empty = BTreeMap::new();
            let assignment_map = assignment_maps
                .get(&(call.file.clone(), call.function.clone()))
                .unwrap_or(&empty);
            if eliminable_guard(call) {
                if let Some(contract) = contract_of(&call.receiver, assignment_map, 0) {
                    guard.push(hit(contract, call));
                }
            } else if essential_dispatch(call) {
                if let Some(contract) = contract_of(&call.receiver, assignment_map, 0) {
                    dispatch.push(hit(contract, call));
                }
            }
        }

        if let Some(methods) = methods_by_file.get(&document.file) {
            guard.extend(rescue_nil_hits(document, methods, &assignment_maps));
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

fn eliminable_guard(call: &CallSite) -> bool {
    GUARD_MIDS.contains(&call.message.as_str()) || call.safe_navigation
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

fn methods_by_file<'a>(methods: &'a [MethodSummary]) -> BTreeMap<String, Vec<&'a MethodSummary>> {
    let mut out: BTreeMap<String, Vec<&MethodSummary>> = BTreeMap::new();
    for method in methods {
        out.entry(method.file.clone()).or_default().push(method);
    }
    out
}

fn local_contract_assignments(method: &MethodSummary) -> BTreeMap<String, String> {
    local_flow::local_contract_assignments(method)
        .into_iter()
        .filter_map(|(name, source)| contract_of(&source, &BTreeMap::new(), 0).map(|c| (name, c)))
        .collect()
}

fn rescue_nil_hits(
    document: &Document,
    methods: &[&MethodSummary],
    assignment_maps: &BTreeMap<(String, String), BTreeMap<String, String>>,
) -> Vec<Hit> {
    let mut out = Vec::new();
    for method in methods {
        let empty = BTreeMap::new();
        let assignment_map = assignment_maps
            .get(&(method.file.clone(), method.name.clone()))
            .unwrap_or(&empty);
        for statement in &method.statements {
            if !statement.source.contains("rescue nil") {
                continue;
            }
            let Some(call) = document.call_sites.iter().find(|candidate| {
                candidate.function == method.name && inside_span(candidate.span, statement.span)
            }) else {
                continue;
            };
            let Some(contract) = contract_of(&call_expression(call), assignment_map, 0) else {
                continue;
            };
            out.push(Hit {
                contract,
                file: method.file.clone(),
                defn: method.name.clone(),
                line: statement.line,
                span: statement.span,
            });
        }
    }
    out
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

fn call_expression(call: &CallSite) -> String {
    [call.receiver.as_str(), call.message.as_str()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(".")
}

fn inside_span(inner: Span, outer: Span) -> bool {
    let starts_after_or_at =
        (inner[0] > outer[0]) || (inner[0] == outer[0] && inner[1] >= outer[1]);
    let ends_before_or_at = (inner[2] < outer[2]) || (inner[2] == outer[2] && inner[3] <= outer[3]);
    starts_after_or_at && ends_before_or_at
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
            .map(|(contract, hs)| {
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
        });

        let local: Vec<_> = rows
            .into_iter()
            .filter(|r| r.contract == "~local")
            .collect();
        named.into_iter().chain(local).collect()
    }
}

fn loc(h: &Hit) -> String {
    format!("{}:{}:{}", h.file, h.defn, h.line)
}
