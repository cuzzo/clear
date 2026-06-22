use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TemporalOrderingPressureRow {
    pub at: String,
    pub file: String,
    pub owner: String,
    pub public_methods: usize,
    pub state_methods: usize,
    pub writers: usize,
    pub state_fields: Vec<String>,
    pub shared_fields: Vec<String>,
    pub orderings: String,
    pub state_space: String,
    pub score: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct MethodState {
    name: String,
    line: usize,
    span: Span,
    visibility: String,
    reads: Vec<String>,
    writes: Vec<String>,
}

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<TemporalOrderingPressureRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<TemporalOrderingPressureRow> {
    let mut rows = Vec::new();
    for document in documents {
        rows.extend(scan_document_facts(document));
    }
    rows.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| b.state_methods.cmp(&a.state_methods))
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.owner.cmp(&b.owner))
    });
    rows
}

fn scan_document_facts(document: &Document) -> Vec<TemporalOrderingPressureRow> {
    let owners = document
        .owner_defs
        .iter()
        .map(|owner| owner.name.clone())
        .chain(
            document
                .function_defs
                .iter()
                .map(|function| function.owner.clone()),
        )
        .filter(|owner| !owner.is_empty())
        .collect::<BTreeSet<_>>();
    owners
        .into_iter()
        .filter_map(|owner| pressure_row_for_owner(document, &owner))
        .collect()
}

fn pressure_row_for_owner(document: &Document, owner: &str) -> Option<TemporalOrderingPressureRow> {
    let methods = document
        .function_defs
        .iter()
        .filter(|function| function.owner == owner)
        .map(|function| MethodState {
            name: function.name.clone(),
            line: function.line,
            span: function.span,
            visibility: function
                .visibility
                .clone()
                .unwrap_or_else(|| "public".to_string()),
            reads: sorted_unique(
                document
                    .state_reads
                    .iter()
                    .filter(|read| read.owner == function.owner && read.function == function.name)
                    .map(|read| read.field.clone()),
            ),
            writes: sorted_unique(
                document
                    .state_writes
                    .iter()
                    .filter(|write| {
                        write.owner == function.owner && write.function == function.name
                    })
                    .map(|write| write.field.clone()),
            ),
        })
        .collect::<Vec<_>>();
    pressure_row(document.file.as_str(), owner, &methods)
}

fn pressure_row(
    file: &str,
    owner: &str,
    methods: &[MethodState],
) -> Option<TemporalOrderingPressureRow> {
    let public_methods: Vec<_> = methods
        .iter()
        .filter(|m| m.visibility == "public")
        .collect();
    let state_methods: Vec<_> = public_methods
        .iter()
        .filter(|m| !m.reads.is_empty() || !m.writes.is_empty())
        .collect();
    let writers: Vec<_> = public_methods
        .iter()
        .filter(|m| !m.writes.is_empty())
        .collect();

    if state_methods.len() < 3 || writers.len() < 2 {
        return None;
    }

    let mut fields_set = BTreeSet::new();
    for m in &state_methods {
        fields_set.extend(m.reads.iter().cloned());
        fields_set.extend(m.writes.iter().cloned());
    }
    let fields = fields_set.into_iter().collect::<Vec<_>>();
    let shared_fields = fields
        .iter()
        .filter(|field| {
            state_methods
                .iter()
                .filter(|m| m.reads.contains(*field) || m.writes.contains(*field))
                .count()
                >= 2
        })
        .cloned()
        .collect::<Vec<_>>();
    if shared_fields.is_empty() {
        return None;
    }

    let n = state_methods.len();
    let state_space = 2usize.pow(fields.len().min(12) as u32);
    let score = (n * writers.len() * shared_fields.len().max(1)) + state_space;
    Some(TemporalOrderingPressureRow {
        at: format!("{}:{}:{}", file, owner, state_methods[0].line),
        file: file.to_string(),
        owner: owner.to_string(),
        public_methods: public_methods.len(),
        state_methods: n,
        writers: writers.len(),
        state_fields: fields,
        shared_fields,
        orderings: format!("{n}!"),
        state_space: format!(
            "2^{}",
            state_methods
                .iter()
                .flat_map(|m| m.reads.iter().chain(m.writes.iter()))
                .collect::<BTreeSet<_>>()
                .len()
        ),
        score,
        sites: state_methods
            .iter()
            .map(|m| format!("{}:{}:{}", file, m.name, m.line))
            .collect(),
        spans: state_methods
            .iter()
            .map(|m| (format!("{}:{}:{}", file, m.name, m.line), m.span))
            .collect(),
    })
}

fn sorted_unique(values: impl Iterator<Item = String>) -> Vec<String> {
    let mut out: Vec<_> = values.collect::<BTreeSet<_>>().into_iter().collect();
    out.sort();
    out
}
