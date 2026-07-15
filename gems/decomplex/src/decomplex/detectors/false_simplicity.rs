use crate::decomplex::syntax::{self, Document, Language, Span};
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
    let core_owner_names = syntax::core_owner_names(document);
    let mut recs = Vec::new();
    let mut hits = Vec::new();

    for owner in &document.owner_defs {
        if !owner.reopenable {
            continue;
        }
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
        let core = !canonical.contains("::") && core_owner_names.contains(&simple.as_str());
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
    document
        .semantic_effect_sites
        .iter()
        .map(|site| Hit {
            kind: site.kind.clone(),
            detail: site.detail.clone(),
            file: site.file.clone(),
            defn: if site.function.is_empty() {
                "(top-level)".to_string()
            } else {
                site.function.clone()
            },
            line: site.line,
            span: site.span,
        })
        .collect()
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
        for (_name, mut recs) in grouped {
            recs.sort_by(|left, right| {
                left.file
                    .cmp(&right.file)
                    .then_with(|| left.line.cmp(&right.line))
            });
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
        for ((kind, detail), mut hits) in groups {
            hits.sort_by(|a, b| {
                a.file
                    .cmp(&b.file)
                    .then_with(|| a.line.cmp(&b.line))
                    .then_with(|| a.defn.cmp(&b.defn))
                    .then_with(|| a.span.cmp(&b.span))
            });
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_false_simplicity_gaps() {
        let doc: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "function_defs": [],
            "owner_defs": [
                {
                    "file": "foo.rb",
                    "name": "::",
                    "kind": "class",
                    "line": 1,
                    "span": [1, 2, 3, 4]
                },
                {
                    "file": "foo.rb",
                    "name": "UnusedClass",
                    "kind": "class",
                    "line": 2,
                    "span": [1, 2, 3, 4]
                }
            ],
            "call_sites": [],
            "state_declarations": [],
            "state_reads": [],
            "state_writes": [],
            "decision_sites": [],
            "branch_decisions": [],
            "branch_arms": [],
            "dispatch_sites": [],
            "semantic_effect_sites": [
                {
                    "file": "foo.rb",
                    "function": "",
                    "kind": "monkeypatch",
                    "detail": "test",
                    "line": 10,
                    "span": [1, 2, 3, 4]
                }
            ],
            "local_complexity_scores": {},
            "local_methods": [],
            "predicate_aliases": [],
            "comparison_uses": [],
            "path_condition_sites": [],
            "protocol_method_effects": [],
            "protocol_call_paths": [],
            "clone_candidates": [],
            "redundant_nil_guards": [],
            "immutable_struct_readers": {},
            "immutable_struct_reader_types": {},
            "type_aliases": {},
            "method_param_types": {},
            "state_param_origins": []
        }))
        .unwrap();

        let res = scan_documents(&[doc]);
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].detail, "test");
        assert_eq!(res[0].sites, vec!["foo.rb:(top-level):10"]);
    }

    #[test]
    fn non_reopenable_duplicate_types_are_not_monkey_patches() {
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("theme.ts");
        std::fs::write(
            &file_path,
            "class Theme { first() {} }\nclass Theme { second() {} }\n",
        )
        .unwrap();

        let findings = scan_files(&[file_path], Language::TypeScript).unwrap();
        assert!(findings.iter().all(|finding| finding.kind != "monkeypatch"));
    }
}
