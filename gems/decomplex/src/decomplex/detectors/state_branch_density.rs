use crate::decomplex::syntax::{self, Document, Language, Span};
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
    let metadata = BranchMetadata::from_documents(documents);
    let all_decisions = documents
        .iter()
        .flat_map(|document| decisions_from_mined_facts(document, &metadata))
        .collect::<Vec<_>>();
    Report::new(all_decisions).findings()
}

fn decisions_from_mined_facts(document: &Document, metadata: &BranchMetadata) -> Vec<Decision> {
    filter_wrapper_decisions(
        document
            .branch_decisions
            .iter()
            .filter_map(|decision| {
                let state_refs = decision
                    .state_refs
                    .iter()
                    .filter(|state_ref| {
                        !metadata.immutable_state_ref(document, &decision.function, state_ref)
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                (!state_refs.is_empty()).then(|| Decision {
                    file: decision.file.clone(),
                    defn: decision.function.clone(),
                    line: decision.line,
                    span: decision.span,
                    predicate: decision.predicate.clone(),
                    state_refs,
                })
            })
            .collect(),
    )
}

#[derive(Default)]
struct BranchMetadata {
    immutable_readers: BTreeMap<String, BTreeSet<String>>,
    immutable_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    type_aliases: BTreeMap<String, String>,
}

impl BranchMetadata {
    fn from_documents(documents: &[Document]) -> Self {
        let mut metadata = Self::default();
        for document in documents {
            for (owner, readers) in &document.immutable_struct_readers {
                metadata
                    .immutable_readers
                    .entry(owner.clone())
                    .or_default()
                    .extend(readers.iter().cloned());
            }
            for (owner, reader_types) in &document.immutable_struct_reader_types {
                metadata
                    .immutable_reader_types
                    .entry(owner.clone())
                    .or_default()
                    .extend(reader_types.clone());
            }
            metadata.type_aliases.extend(document.type_aliases.clone());
        }
        metadata
    }

    fn immutable_state_ref(&self, document: &Document, function: &str, state_ref: &str) -> bool {
        let mut parts = state_ref.split('.').collect::<Vec<_>>();
        if parts.len() < 2 {
            return false;
        }
        let param = parts.remove(0);
        let Some(mut type_name) = document
            .method_param_types
            .get(function)
            .and_then(|params| params.get(param))
            .cloned()
        else {
            return false;
        };

        while parts.len() > 1 {
            let reader = parts.remove(0);
            let Some(next_type) = self.immutable_reader_result_type(&type_name, reader) else {
                return false;
            };
            type_name = next_type;
        }

        self.immutable_reader(&type_name, parts[0])
    }

    fn immutable_reader(&self, type_name: &str, field: &str) -> bool {
        let resolved = self.resolve_type_alias(type_name);
        let short = resolved.split("::").last().unwrap_or(&resolved);
        let field = field.trim_end_matches('?');
        self.immutable_readers
            .get(&resolved)
            .or_else(|| self.immutable_readers.get(short))
            .map(|readers| readers.contains(field))
            .unwrap_or(false)
    }

    fn immutable_reader_result_type(&self, type_name: &str, field: &str) -> Option<String> {
        let resolved = self.resolve_type_alias(type_name);
        let short = resolved.split("::").last().unwrap_or(&resolved);
        let field = field.trim_end_matches('?');
        self.immutable_reader_types
            .get(&resolved)
            .or_else(|| self.immutable_reader_types.get(short))
            .and_then(|reader_types| reader_types.get(field))
            .cloned()
    }

    fn resolve_type_alias(&self, type_name: &str) -> String {
        let mut seen = BTreeSet::new();
        let mut current = type_name.to_string();
        loop {
            if !seen.insert(current.clone()) {
                return current;
            }
            let short = current.split("::").last().unwrap_or(&current);
            let Some(next) = self
                .type_aliases
                .get(&current)
                .or_else(|| self.type_aliases.get(short))
            else {
                return current;
            };
            current = next.clone();
        }
    }
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
    let _ = predicate;
    false
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_branch_metadata() {
        let doc: Document = serde_json::from_value(serde_json::json!({
            "file": "foo.rb",
            "language": "ruby",
            "immutable_struct_readers": {
                "OtherType": ["b"]
            },
            "immutable_struct_reader_types": {
                "MyType": { "a": "OtherType" }
            },
            "type_aliases": {
                "AliasType": "MyType",
                "Loop1": "Loop2",
                "Loop2": "Loop1"
            },
            "method_param_types": {
                "foo": { "obj": "AliasType" }
            }
        })).unwrap();

        let metadata = BranchMetadata::from_documents(&[doc.clone()]);

        // len < 2
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj"));

        // param not found
        assert!(!metadata.immutable_state_ref(&doc, "foo", "missing.field"));

        // valid path obj.a.b
        assert!(metadata.immutable_state_ref(&doc, "foo", "obj.a.b"));

        // path where middle type reader doesn't exist
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj.unknown.b"));

        // path where last field is not reader
        assert!(!metadata.immutable_state_ref(&doc, "foo", "obj.a.unknown"));

        // loop alias resolution
        let mut loop_doc = doc.clone();
        loop_doc.method_param_types.insert(
            "loop_fn".to_string(),
            vec![("obj".to_string(), "Loop1".to_string())].into_iter().collect(),
        );
        let metadata_loop = BranchMetadata::from_documents(&[loop_doc.clone()]);
        assert!(!metadata_loop.immutable_state_ref(&loop_doc, "loop_fn", "obj.a"));
    }

    #[test]
    fn test_span_encloses_and_nested_state_decision() {
        assert!(span_encloses([1, 0, 3, 10], [1, 2, 2, 5]));
        assert!(span_encloses([1, 0, 3, 10], [1, 2, 3, 5]));
        assert!(span_encloses([1, 2, 3, 10], [1, 2, 3, 10]));
        assert!(!span_encloses([1, 2, 3, 10], [1, 1, 3, 10]));
        assert!(!span_encloses([1, 2, 3, 10], [1, 2, 3, 11]));

        let d1 = Decision {
            file: "foo.rb".to_string(),
            defn: "foo".to_string(),
            line: 1,
            span: [1, 0, 5, 10],
            predicate: "a".to_string(),
            state_refs: vec!["x".to_string(), "y".to_string()],
        };

        let d2 = Decision {
            file: "foo.rb".to_string(),
            defn: "foo".to_string(),
            line: 2,
            span: [2, 0, 3, 10],
            predicate: "b".to_string(),
            state_refs: vec!["x".to_string()],
        };

        // d1 encloses d2, and d2's state refs are subset of d1's state refs
        let decisions = &[d1, d2];
        // d1 (outer) has nested d2
        assert!(nested_state_decision(&decisions[0], decisions));
        // d2 (inner) has no nested
        assert!(!nested_state_decision(&decisions[1], decisions));
    }

    #[test]
    fn test_report_findings_sorting() {
        let d_a = Decision {
            file: "a.rb".to_string(),
            defn: "foo".to_string(),
            line: 1,
            span: [1, 0, 1, 10],
            predicate: "a".to_string(),
            state_refs: vec!["x".to_string()],
        };

        let d_b = Decision {
            file: "b.rb".to_string(),
            defn: "foo".to_string(),
            line: 1,
            span: [1, 0, 1, 10],
            predicate: "b".to_string(),
            state_refs: vec!["x".to_string(), "y".to_string()],
        };

        let report = Report::new(vec![d_a, d_b]);
        let findings = report.findings();
        assert_eq!(findings.len(), 2);
        // d_b should sort first because score is 1 * 2 = 2, vs d_a score is 1 * 1 = 1
        assert_eq!(findings[0].file, "b.rb");
        assert_eq!(findings[1].file, "a.rb");
    }
}

