use crate::decomplex::ast::Span;
use crate::decomplex::syntax::adapters::false_simplicity_lexicon::{
    false_simplicity_lexicon, FalseSimplicityLexicon,
};
use crate::decomplex::syntax::{self, CallSite, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FalseSimplicityRow {
    pub kind: String,
    pub detail: String,
    pub support: usize,
    pub scatter: usize,
    pub at: String,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Hit {
    kind: String,
    detail: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct ClassRec {
    name: String,
    file: String,
    line: usize,
    core: bool,
    span: Span,
}

const GENERIC_SYSTEM_IO_BARE: &[&str] =
    &["print", "println", "eprintln", "printf", "puts", "panic"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<FalseSimplicityRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<FalseSimplicityRow> {
    let mut hits = Vec::new();
    let mut classrecs = Vec::new();
    for document in documents {
        hits.extend(hits_for_document(document));
        let (doc_recs, doc_hits) = class_records_for_document(document);
        classrecs.extend(doc_recs);
        hits.extend(doc_hits);
    }
    Report::new(hits, classrecs).findings()
}

fn class_records_for_document(document: &Document) -> (Vec<ClassRec>, Vec<Hit>) {
    let function_owners = document
        .function_defs
        .iter()
        .map(|function| function.owner.clone())
        .filter(|owner| !owner.is_empty())
        .collect::<BTreeSet<_>>();
    let lexicon = false_simplicity_lexicon(document.language);
    let mut recs = Vec::new();
    let mut hits = Vec::new();

    for owner in &document.owner_defs {
        let canonical = owner.name.trim_start_matches("::").to_string();
        if canonical.is_empty() {
            continue;
        }
        if !function_owners.contains(&owner.name) && !function_owners.contains(&canonical) {
            continue;
        }
        let simple = canonical
            .split("::")
            .last()
            .unwrap_or(canonical.as_str())
            .to_string();
        let core = !canonical.contains("::") && lexicon.core_consts.contains(&simple.as_str());
        recs.push(ClassRec {
            name: canonical.clone(),
            file: owner.file.clone(),
            line: owner.line,
            core,
            span: owner.span,
        });
        if core {
            hits.push(Hit {
                kind: "monkeypatch".to_string(),
                detail: simple.clone(),
                file: owner.file.clone(),
                defn: simple,
                line: owner.line,
                span: owner.span,
            });
        }
    }

    (recs, hits)
}

fn hits_for_document(document: &Document) -> Vec<Hit> {
    let lexicon = false_simplicity_lexicon(document.language);
    document
        .call_sites
        .iter()
        .filter_map(|call| semantic_effect_hit_for_call(call, &lexicon))
        .collect()
}

fn semantic_effect_hit_for_call(call: &CallSite, lexicon: &FalseSimplicityLexicon) -> Option<Hit> {
    let message = call.message.as_str();
    let (kind, detail) = if effect_callback_call(call, message, lexicon) {
        ("callback_inversion", message.to_string())
    } else if lexicon.meta_mids.contains(&message) {
        ("metaprogramming", message.to_string())
    } else if lexicon.dispatch_mids.contains(&message) {
        ("dynamic_dispatch", message.to_string())
    } else if message == "call" && !call.receiver.is_empty() {
        if method_object_receiver(&call.receiver, lexicon) {
            ("dynamic_dispatch", "method(...).call".to_string())
        } else if variable_receiver(&call.receiver) {
            ("dynamic_dispatch", format!("{}.call", call.receiver))
        } else {
            return None;
        }
    } else if let Some((kind, detail)) = const_effect_kind_detail(call, message, lexicon) {
        (kind, detail)
    } else if call.receiver == "self"
        && (lexicon.io_bare.contains(&message) || GENERIC_SYSTEM_IO_BARE.contains(&message))
    {
        ("hidden_io", message.to_string())
    } else if call.receiver == "self" && lexicon.context_bare.contains(&message) {
        ("context_dependency", message.to_string())
    } else if message.len() > 1 && message.ends_with('!') && !matches!(message, "!=" | "!~") {
        ("hidden_mutation", message.to_string())
    } else {
        return None;
    };

    Some(Hit {
        kind: kind.to_string(),
        detail,
        file: call.file.clone(),
        defn: call.function.clone(),
        line: call.line,
        span: call.span,
    })
}

fn const_effect_kind_detail(
    call: &CallSite,
    message: &str,
    lexicon: &FalseSimplicityLexicon,
) -> Option<(&'static str, String)> {
    let receiver = call.receiver.as_str();
    if receiver.is_empty() || receiver == "self" {
        return None;
    }
    let base = receiver
        .trim_start_matches("::")
        .split("::")
        .next()
        .unwrap_or("");
    if base == "Dir" && lexicon.dir_context.contains(&message) {
        return Some(("context_dependency", format!("Dir.{message}")));
    }
    if lexicon.io_consts.contains(&base) || receiver.starts_with("Net::") {
        return Some((
            "hidden_io",
            format!("{}.{}", receiver.trim_start_matches("::"), message),
        ));
    }
    if receiver == "ENV" {
        return Some(("context_dependency", "ENV".to_string()));
    }
    if lexicon
        .context_pairs
        .iter()
        .any(|(name, mids)| *name == base && mids.contains(&message))
    {
        return Some(("context_dependency", format!("{base}.{message}")));
    }
    None
}

fn effect_callback_call(call: &CallSite, message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    (call.block || call.arguments.iter().any(|arg| arg.starts_with('&')))
        && effect_callback_name(message, lexicon)
        && !lexicon.meta_mids.contains(&message)
}

fn effect_callback_name(message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    lexicon.callback_set.contains(&message)
        || message.starts_with("with_")
        || message.starts_with("around_")
        || message.starts_with("on_")
        || message.starts_with("before_")
        || message.starts_with("after_")
        || message.ends_with("_hook")
}

fn method_object_receiver(receiver: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    lexicon
        .method_obj_mids
        .iter()
        .any(|name| receiver.contains(name))
}

fn variable_receiver(receiver: &str) -> bool {
    let mut chars = receiver.chars();
    matches!(chars.next(), Some(first) if first == '@' || first == '$' || first == '_' || first.is_ascii_lowercase())
        && chars.all(|ch| ch == '_' || ch == '!' || ch == '?' || ch.is_ascii_alphanumeric())
}

struct Report {
    hits: Vec<Hit>,
}

impl Report {
    fn new(mut hits: Vec<Hit>, classrecs: Vec<ClassRec>) -> Self {
        let mut grouped: Vec<(String, Vec<ClassRec>)> = Vec::new();
        for rec in classrecs {
            if let Some((_, recs)) = grouped.iter_mut().find(|(name, _)| name == &rec.name) {
                recs.push(rec);
            } else {
                grouped.push((rec.name.clone(), vec![rec]));
            }
        }
        for (_name, recs) in grouped {
            if recs.first().is_some_and(|rec| rec.core) {
                continue;
            }
            let file_count = recs
                .iter()
                .map(|rec| rec.file.clone())
                .collect::<BTreeSet<_>>()
                .len();
            if file_count < 2 {
                continue;
            }
            for rec in recs {
                hits.push(Hit {
                    kind: "monkeypatch".to_string(),
                    detail: format!("reopen {}", rec.name),
                    file: rec.file.clone(),
                    defn: rec.name.clone(),
                    line: rec.line,
                    span: rec.span,
                });
            }
        }
        Self { hits }
    }

    fn findings(&self) -> Vec<FalseSimplicityRow> {
        let mut groups: Vec<((String, String), Vec<&Hit>)> = Vec::new();
        for hit in &self.hits {
            let key = (hit.kind.clone(), hit.detail.clone());
            if let Some((_, hits)) = groups.iter_mut().find(|(existing, _)| existing == &key) {
                hits.push(hit);
            } else {
                groups.push((key, vec![hit]));
            }
        }

        let mut out = Vec::new();
        for ((kind, detail), hits) in groups {
            let units = hits
                .iter()
                .map(|hit| (hit.file.clone(), hit.defn.clone()))
                .collect::<BTreeSet<_>>();
            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for hit in &hits {
                let loc = format!("{}:{}:{}", hit.file, hit.defn, hit.line);
                if !sites.contains(&loc) {
                    sites.push(loc.clone());
                }
                spans.entry(loc).or_insert(hit.span);
            }
            out.push(FalseSimplicityRow {
                kind,
                detail,
                support: hits.len(),
                scatter: units.len(),
                at: sites.first().cloned().unwrap_or_default(),
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| {
            b.scatter
                .cmp(&a.scatter)
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.kind.cmp(&b.kind))
                .then_with(|| a.detail.cmp(&b.detail))
        });
        out
    }
}
