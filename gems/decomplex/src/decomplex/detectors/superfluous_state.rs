use crate::decomplex::detectors::{implicit_control_flow, semantic_alias, state_mesh};
use crate::decomplex::syntax::{Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct SuperfluousStateFinding {
    pub field: String,
    pub score: f64,
    pub classification: String,
    pub writer_method_count: usize,
    pub reader_method_count: usize,
    pub write_sites: Vec<String>,
    pub read_sites: Vec<String>,
    pub writer_methods: Vec<String>,
    pub reader_methods: Vec<String>,
    pub ctorset: bool,
    pub adjacent_sites: Option<Vec<String>>,
    pub confidence: String,
    pub confidence_reason: Option<String>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<SuperfluousStateFinding>> {
    let documents = crate::decomplex::syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<SuperfluousStateFinding> {
    scan_documents_with_corpus(documents, true)
}

pub fn scan_documents_with_corpus(
    documents: &[Document],
    corpus_complete: bool,
) -> Vec<SuperfluousStateFinding> {
    // Public accessor reads are call facts rather than owner-local state reads.
    // Without points-to proof, a same-named external message or a self message
    // from a different method is enough to make a `dead_state` verdict unsound.
    // Exclude same-named self calls so direct recursion does not look like a
    // field accessor.
    let accessor_messages: BTreeSet<String> = documents
        .iter()
        .flat_map(|document| document.call_sites.iter())
        .filter(|call| call.receiver != "self" || call.function != call.message)
        .map(|call| call.message.clone())
        .collect();
    let semantic_aliases = semantic_alias::scan_documents(documents);
    let sm_report = state_mesh::scan_documents_with_semantic_aliases_and_min_writes(
        documents,
        &semantic_aliases,
        1,
    );

    let icf_report = implicit_control_flow::scan_documents(documents);
    let opaque_state_escapes = opaque_state_escape_functions(documents);
    // (file, function) -> owner, used to resolve what class a chained read's
    // receiver attribute (`spec` in `self.spec.namespace`) is declared on.
    let function_owner: BTreeMap<(String, String), String> = documents
        .iter()
        .flat_map(|document| {
            document
                .function_defs
                .iter()
                .map(|f| ((document.file.clone(), f.name.clone()), f.owner.clone()))
        })
        .collect();
    // (owner, field) -> declared type text, used to check whether that
    // receiver attribute is actually an instance of the field's own owner.
    let declared_type: BTreeMap<(String, String), String> = documents
        .iter()
        .flat_map(|document| {
            document.state_declarations.iter().filter_map(|decl| {
                decl.r#type
                    .clone()
                    .map(|ty| ((decl.owner.clone(), decl.field.clone()), ty))
            })
        })
        .collect();
    let chained_reads_by_field: BTreeMap<&str, Vec<&crate::decomplex::syntax::StateRead>> =
        documents
            .iter()
            .flat_map(|document| document.chained_self_reads.iter())
            .fold(BTreeMap::new(), |mut acc, read| {
                acc.entry(read.field.as_str()).or_default().push(read);
                acc
            });
    let mut adjacent_pairs: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    for proto in &icf_report.ordered_protocols {
        if proto.dependency.contains(&"write_read".to_string()) && proto.protocol.len() >= 2 {
            let writer = proto.protocol[0].clone();
            let reader = proto.protocol[1].clone();
            let entry = adjacent_pairs.entry((writer, reader)).or_default();
            for state in &proto.states {
                entry.insert(state.clone());
            }
        }
    }

    let mut results = Vec::new();

    for (norm, row) in &sm_report.fields {
        let self_writes: Vec<_> = row.writers.iter().filter(|w| w.recv == "self").collect();
        let self_reads: Vec<_> = row.readers.iter().filter(|r| r.recv == "self").collect();

        // ---- Pattern 1: dead state (written, never read) ----
        if !self_writes.is_empty()
            && row.readers.is_empty()
            && !self_writes.iter().any(|writer| {
                opaque_state_escapes.contains(&(writer.file.clone(), writer.defn.clone()))
            })
            && !accessor_messages.contains(norm)
        {
            // Absence of a reader is not evidence of dead state when the
            // selected corpus is open. Readers commonly live in consumers,
            // tests, or a later compiler stage outside the requested path.
            // Do not count an unverifiable observation as superfluous state.
            if !corpus_complete {
                continue;
            }

            // `norm` collapses to the bare field name whenever it is the only
            // slot with that spelling in the corpus, so the writer's owner
            // must come from the writer sites themselves, not by parsing it
            // back out of the display key.
            let field_name = norm.rsplit("::").next().unwrap_or(norm.as_str());
            let writer_owner: Option<&str> = self_writes.iter().find_map(|writer| {
                function_owner
                    .get(&(writer.file.clone(), writer.defn.clone()))
                    .map(String::as_str)
            });

            // A chained read (`self.spec.namespace`) is only unsound when the
            // receiver's actual type can't be checked. Resolve it against
            // that receiver's own declared type when we have one; only when
            // it's genuinely unresolvable does this become a confidence
            // downgrade instead of a full reader.
            let mut proven_reader = false;
            let mut unresolved_sites = Vec::new();
            if let Some(candidates) = chained_reads_by_field.get(field_name) {
                for read in candidates {
                    let resolved = function_owner
                        .get(&(read.file.clone(), read.function.clone()))
                        .and_then(|reading_owner| {
                            declared_type.get(&(reading_owner.clone(), read.receiver.clone()))
                        });
                    match (resolved, writer_owner) {
                        (Some(ty), Some(writer_owner)) if ty == writer_owner => {
                            proven_reader = true;
                            break;
                        }
                        _ => {
                            unresolved_sites.push(format!(
                                "{}:{}:{} (via {}.{})",
                                read.file, read.function, read.line, read.receiver, read.field
                            ));
                        }
                    }
                }
            }
            if proven_reader {
                continue;
            }

            let (confidence, confidence_reason) = if unresolved_sites.is_empty() {
                ("high".to_string(), None)
            } else {
                unresolved_sites.sort();
                unresolved_sites.dedup();
                (
                    "low".to_string(),
                    Some(format!(
                        "possible external reader via an unresolved chained receiver: {}",
                        unresolved_sites.join(", ")
                    )),
                )
            };

            results.push(SuperfluousStateFinding {
                field: norm.clone(),
                score: 0.85,
                classification: "dead_state".to_string(),
                writer_method_count: self_writes
                    .iter()
                    .map(|w| (w.file.clone(), w.defn.clone()))
                    .collect::<BTreeSet<_>>()
                    .len(),
                reader_method_count: 0,
                write_sites: {
                    let mut sites: Vec<String> = self_writes
                        .iter()
                        .map(|w| format!("{}:{}:{}", w.file, w.defn, w.line))
                        .collect();
                    sites.sort();
                    sites.dedup();
                    sites
                },
                read_sites: Vec::new(),
                writer_methods: {
                    let mut defns: Vec<String> =
                        self_writes.iter().map(|w| w.defn.clone()).collect();
                    defns.sort();
                    defns.dedup();
                    defns
                },
                reader_methods: Vec::new(),
                ctorset: self_writes.iter().all(|w| w.defn == "initialize"),
                adjacent_sites: None,
                confidence,
                confidence_reason,
            });
            continue;
        }

        // ---- Pattern 2-4: eliminability scoring ----
        if self_writes.is_empty() || self_reads.is_empty() {
            continue;
        }

        let writer_methods: BTreeSet<(String, String)> = self_writes
            .iter()
            .map(|w| (w.file.clone(), w.defn.clone()))
            .collect();
        let reader_methods: BTreeSet<(String, String)> = self_reads
            .iter()
            .map(|r| (r.file.clone(), r.defn.clone()))
            .collect();

        let all_sites: BTreeSet<(String, String)> =
            writer_methods.union(&reader_methods).cloned().collect();

        let wc = writer_methods.len();
        let rc = reader_methods.len();

        // base dampened score
        let base = 1.0 / ((wc * rc) as f64 + 1.0);

        // intra-method pass-through
        let mut intra = all_sites.len() == 1;
        if intra {
            let first_write_line = self_writes.iter().map(|w| w.line).min().unwrap_or(0);
            if self_reads.iter().any(|r| r.line < first_write_line) {
                intra = false;
            }
        }
        let intra_bonus = if intra { 10.0 } else { 1.0 };

        // constructor-set penalty
        let ctorset = wc == 1 && writer_methods.iter().next().unwrap().1 == "initialize";
        let ctor_penalty = if ctorset { 0.33 } else { 1.0 };

        // adjacent-call bonus
        let mut adj_bonus = 1.0;
        let mut adj_sites = None;
        if wc == 1 && rc == 1 && !intra {
            let wm_name = &writer_methods.iter().next().unwrap().1;
            let rm_name = &reader_methods.iter().next().unwrap().1;
            let pair_key = (wm_name.clone(), rm_name.clone());
            if let Some(fields) = adjacent_pairs.get(&pair_key) {
                if fields.contains(norm) {
                    adj_bonus = 5.0;
                    let mut sites: Vec<String> = fields.iter().cloned().collect();
                    sites.sort();
                    adj_sites = Some(sites);
                }
            }
        }

        let score = base * intra_bonus * adj_bonus * ctor_penalty;
        if score < 0.1 {
            continue;
        }

        // A field is not a derived cache merely because one method writes it
        // and another reads it. That is the normal shape of encapsulated
        // object state and immutable result records. Require independent
        // re-derivation evidence before making the eliminability claim.
        if !intra && adj_bonus == 1.0 && row.re_derivations.is_empty() {
            continue;
        }

        let classification = if intra {
            "intra_method".to_string()
        } else if adj_bonus > 1.0 {
            "adjacent_call".to_string()
        } else {
            "derived_cache".to_string()
        };

        results.push(SuperfluousStateFinding {
            field: norm.clone(),
            score,
            classification,
            writer_method_count: wc,
            reader_method_count: rc,
            write_sites: {
                let mut sites: Vec<String> = self_writes
                    .iter()
                    .map(|w| format!("{}:{}:{}", w.file, w.defn, w.line))
                    .collect();
                sites.sort();
                sites.dedup();
                sites
            },
            read_sites: {
                let mut sites: Vec<String> = self_reads
                    .iter()
                    .map(|r| format!("{}:{}:{}", r.file, r.defn, r.line))
                    .collect();
                sites.sort();
                sites.dedup();
                sites
            },
            writer_methods: {
                let mut defns: Vec<String> =
                    writer_methods.iter().map(|(_, d)| d.clone()).collect();
                defns.sort();
                defns.dedup();
                defns
            },
            reader_methods: {
                let mut defns: Vec<String> =
                    reader_methods.iter().map(|(_, d)| d.clone()).collect();
                defns.sort();
                defns.dedup();
                defns
            },
            ctorset,
            adjacent_sites: adj_sites,
            confidence: "medium".to_string(),
            confidence_reason: None,
        });
    }

    results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.field.cmp(&b.field))
    });

    results
}

/// Language adapters emit this normalized effect only when a call can
/// externally inspect an owned aggregate. The detector merely consumes it.
fn opaque_state_escape_functions(documents: &[Document]) -> BTreeSet<(String, String)> {
    documents
        .iter()
        .flat_map(|document| {
            document
                .semantic_effect_sites
                .iter()
                .filter(|site| site.kind == "opaque_state_escape")
                .map(|site| (site.file.clone(), site.function.clone()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_superfluous_state() {
        let doc: Document = serde_json::from_value(json!({
            "file": "example.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "dead_state", "receiver": "self", "file": "example.rb", "function": "m1", "line": 5, "span": [5, 1, 5, 10], "owner": "Class" },
                { "field": "intra_var", "receiver": "self", "file": "example.rb", "function": "m2", "line": 10, "span": [10, 1, 10, 10], "owner": "Class" },
                // Non-self writes to test filters
                { "field": "other_var", "receiver": "other", "file": "example.rb", "function": "m2", "line": 11, "span": [11, 1, 11, 10], "owner": "Class" }
            ],
            "state_reads": [
                { "field": "intra_var", "receiver": "self", "file": "example.rb", "function": "m2", "line": 12, "span": [12, 1, 12, 10], "owner": "Class" }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);
        assert_eq!(findings.len(), 2);

        assert_eq!(findings[0].field, "intra_var");
        assert_eq!(findings[0].classification, "intra_method");
        assert_eq!(findings[0].score, 5.0); // base (1/2) * intra_bonus (10) * ctor_penalty (1)

        assert_eq!(findings[1].field, "dead_state");
        assert_eq!(findings[1].classification, "dead_state");
        assert_eq!(findings[1].score, 0.85);
    }

    #[test]
    fn test_superfluous_state_edge_cases() {
        // 1. Read-before-write in same method (disqualifies intra-method)
        // 2. Constructor-set state without derivation evidence
        // 3. Score below threshold (< 0.1)
        // 4. Ordinary state (read & write in different methods, not adjacent)
        // 5. Adjacent call bonus
        let doc: Document = serde_json::from_value(json!({
            "file": "example.rb",
            "language": "ruby",
            "state_writes": [
                // Read-before-write
                { "field": "rbw", "receiver": "self", "file": "example.rb", "function": "m1", "line": 10, "span": [10, 1, 10, 10], "owner": "Class" },
                // Constructor-set only (ctorset) -> written in initialize, read in m2
                { "field": "ctor_var", "receiver": "self", "file": "example.rb", "function": "initialize", "line": 5, "span": [5, 1, 5, 10], "owner": "Class" },
                // Low-score variable (large wc * rc -> base score too low)
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "w1", "line": 20, "span": [20, 1, 20, 10], "owner": "Class" },
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "w2", "line": 21, "span": [21, 1, 21, 10], "owner": "Class" },
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "w3", "line": 22, "span": [22, 1, 22, 10], "owner": "Class" },
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "w4", "line": 23, "span": [23, 1, 23, 10], "owner": "Class" },
                // Ordinary state (different methods, no adjacency/derivation evidence)
                { "field": "derived", "receiver": "self", "file": "example.rb", "function": "m3", "line": 30, "span": [30, 1, 30, 10], "owner": "Class" },
                // Adjacent call
                { "field": "adj", "receiver": "self", "file": "example.rb", "function": "set_val", "line": 40, "span": [40, 1, 40, 10], "owner": "Class" }
            ],
            "state_reads": [
                // Read-before-write read at line 8
                { "field": "rbw", "receiver": "self", "file": "example.rb", "function": "m1", "line": 8, "span": [8, 1, 8, 10], "owner": "Class" },
                // Constructor-set read
                { "field": "ctor_var", "receiver": "self", "file": "example.rb", "function": "m2", "line": 15, "span": [15, 1, 15, 10], "owner": "Class" },
                // Low score reads
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "r1", "line": 25, "span": [25, 1, 25, 10], "owner": "Class" },
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "r2", "line": 26, "span": [26, 1, 26, 10], "owner": "Class" },
                { "field": "low_score", "receiver": "self", "file": "example.rb", "function": "r3", "line": 27, "span": [27, 1, 27, 10], "owner": "Class" },
                // Ordinary state read
                { "field": "derived", "receiver": "self", "file": "example.rb", "function": "m4", "line": 35, "span": [35, 1, 35, 10], "owner": "Class" },
                // Adjacent call read
                { "field": "adj", "receiver": "self", "file": "example.rb", "function": "get_val", "line": 45, "span": [45, 1, 45, 10], "owner": "Class" }
            ],
            "protocol_call_paths": [
                {
                    "file": "example.rb", "name": "caller", "line": 50, "owner": "Class",
                    "calls": [
                        { "mid": "set_val", "file": "example.rb", "owner": "Class", "defn": "caller", "line": 51, "span": [51, 1, 51, 10] },
                        { "mid": "get_val", "file": "example.rb", "owner": "Class", "defn": "caller", "line": 52, "span": [52, 1, 52, 10] }
                    ]
                }
            ],
            "protocol_method_effects": [
                {
                    "file": "example.rb", "owner": "Class", "name": "set_val", "line": 40,
                    "reads": [], "writes": ["adj"]
                },
                {
                    "file": "example.rb", "owner": "Class", "name": "get_val", "line": 45,
                    "reads": ["adj"], "writes": []
                }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);

        // Validate "low_score" is excluded (base = 1/(12+1) = 0.076 < 0.1)
        assert!(!findings.iter().any(|f| f.field == "low_score"));

        // Ordinary state is not eliminable without evidence of re-derivation.
        assert!(!findings.iter().any(|f| f.field == "rbw"));
        assert!(!findings.iter().any(|f| f.field == "ctor_var"));
        assert!(!findings.iter().any(|f| f.field == "derived"));

        // Validate "adj" is classified as adjacent_call with a 5.0x bonus
        let adj = findings.iter().find(|f| f.field == "adj").unwrap();
        assert_eq!(adj.classification, "adjacent_call");
        assert_eq!(adj.score, 2.5); // base (1/2) * adj_bonus (5) = 2.5
        assert_eq!(adj.adjacent_sites, Some(vec!["adj".to_string()]));
    }

    #[test]
    fn test_sorting_and_scan_files() {
        // Check sorting behavior for equal scores (alphabetical sorting of field names)
        let doc: Document = serde_json::from_value(json!({
            "file": "example.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "y_field", "receiver": "self", "file": "example.rb", "function": "m1", "line": 5, "span": [5, 1, 5, 10], "owner": "Class" },
                { "field": "x_field", "receiver": "self", "file": "example.rb", "function": "m2", "line": 10, "span": [10, 1, 10, 10], "owner": "Class" }
            ],
            "state_reads": []
        })).unwrap();

        let findings = scan_documents(&[doc]);
        assert_eq!(findings.len(), 2);
        assert_eq!(findings[0].field, "x_field"); // sorted alphabetically before y_field since both have score 0.85
        assert_eq!(findings[1].field, "y_field");

        // Validate scan_files does not panic
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("test.rb");
        std::fs::write(&file_path, "def foo\n  @x = 1\nend\n").unwrap();
        let results = scan_files(&[file_path], Language::Ruby).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].field, "x");
        assert_eq!(results[0].classification, "dead_state");
    }

    #[test]
    fn c_aggregate_escape_prevents_false_dead_field() {
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("state.c");
        std::fs::write(
            &file_path,
            "struct State { int flag; };\nvoid observe(struct State* state);\nvoid update(struct State* state) { state->flag = 1; observe(state); }\n",
        )
        .unwrap();

        let findings = scan_files(&[file_path], Language::C).unwrap();
        assert!(
            findings.is_empty(),
            "opaque aggregate call is a possible read: {findings:?}"
        );
    }

    #[test]
    fn accessor_calls_disqualify_dead_state() {
        let doc: Document = serde_json::from_value(json!({
            "file": "context.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "alloc_count", "receiver": "self", "file": "context.rb", "function": "initialize", "line": 5, "span": [5, 1, 5, 10], "owner": "Context" }
            ],
            "state_reads": [],
            "call_sites": [
                { "receiver": "ctx", "message": "alloc_count", "file": "consumer.rb", "function": "finish", "owner": "Consumer", "line": 8, "span": [8, 1, 8, 16], "conditional": false, "arguments": [], "control": null, "safe_navigation": false, "block": false },
                { "receiver": "self", "message": "alloc_count", "file": "context.rb", "function": "count", "owner": "Context", "line": 12, "span": [12, 1, 12, 12], "conditional": false, "arguments": [], "control": null, "safe_navigation": false, "block": false }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);
        assert!(
            findings
                .iter()
                .all(|finding| finding.field != "alloc_count"),
            "a public accessor read must prevent a dead-state verdict"
        );
    }

    #[test]
    fn partial_corpus_omits_dead_state_claim() {
        let doc: Document = serde_json::from_value(json!({
            "file": "annotator.rb", "language": "ruby",
            "state_writes": [{ "field": "semantic_index", "receiver": "self", "file": "annotator.rb", "function": "annotate", "line": 10, "span": [10, 1, 10, 20], "owner": "Annotator" }]
        })).unwrap();
        let findings = scan_documents_with_corpus(&[doc], false);
        assert!(findings.is_empty());
    }

    #[test]
    fn rederivation_evidence_identifies_a_real_derived_cache() {
        let doc: Document = serde_json::from_value(json!({
            "file": "cache.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "cache", "receiver": "self", "file": "cache.rb", "function": "refresh", "line": 4, "span": [4, 1, 4, 10], "owner": "Cache" }
            ],
            "state_reads": [
                { "field": "cache", "receiver": "self", "file": "cache.rb", "function": "fetch", "line": 8, "span": [8, 1, 8, 10], "owner": "Cache" }
            ],
            "predicate_aliases": [
                { "name": "cache_valid?", "body": "@cache == source", "file": "cache.rb", "defn": "cache_valid?", "line": 12, "span": [12, 1, 12, 24] }
            ],
            "comparison_uses": [
                { "canon_source": "@cache == source", "file": "cache.rb", "function": "recompute", "line": 16, "raw": "@cache == source", "span": [16, 1, 16, 24], "enclosing_span": [16, 1, 16, 24] }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);
        let cache = findings
            .iter()
            .find(|finding| finding.field == "cache")
            .unwrap();
        assert_eq!(cache.classification, "derived_cache");
    }

    fn function_def(file: &str, name: &str, owner: &str, line: usize) -> serde_json::Value {
        json!({
            "file": file, "name": name, "owner": owner, "line": line, "span": [line, 0, line, 1],
            "body": { "kind": "def", "text": "", "span": [line, 0, line, 1], "named": true, "field_name": null, "children": [] },
            "visibility": "public", "params": []
        })
    }

    #[test]
    fn cross_instance_read_with_unresolved_receiver_downgrades_confidence_instead_of_suppressing() {
        let doc: Document = serde_json::from_value(json!({
            "file": "app.rb",
            "language": "ruby",
            "function_defs": [
                function_def("app.rb", "set_namespace", "HookSpec", 3),
                function_def("app.rb", "describe", "HookImpl", 8)
            ],
            "state_declarations": [
                { "field": "spec", "owner": "HookImpl", "type": null, "file": "app.rb", "line": 6, "span": [6, 1, 6, 10] }
            ],
            "state_writes": [
                { "field": "namespace", "receiver": "self", "file": "app.rb", "function": "set_namespace", "line": 3, "span": [3, 1, 3, 10], "owner": "HookSpec" }
            ],
            "chained_self_reads": [
                { "field": "namespace", "receiver": "spec", "file": "app.rb", "function": "describe", "line": 8, "span": [8, 1, 8, 20], "owner": "HookImpl" }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);
        let namespace = findings
            .iter()
            .find(|finding| finding.field.ends_with("namespace"))
            .expect("namespace must still be reported since spec's type is unresolved");
        assert_eq!(namespace.classification, "dead_state");
        assert_eq!(namespace.confidence, "low");
        assert!(
            namespace
                .confidence_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("spec")),
            "reason should cite the unresolved receiver, got {:?}",
            namespace.confidence_reason
        );
    }

    #[test]
    fn cross_instance_read_with_resolved_receiver_type_is_a_proven_reader() {
        let doc: Document = serde_json::from_value(json!({
            "file": "app.rb",
            "language": "ruby",
            "function_defs": [
                function_def("app.rb", "set_namespace", "HookSpec", 3),
                function_def("app.rb", "describe", "HookImpl", 8)
            ],
            "state_declarations": [
                { "field": "spec", "owner": "HookImpl", "type": "HookSpec", "file": "app.rb", "line": 6, "span": [6, 1, 6, 10] }
            ],
            "state_writes": [
                { "field": "namespace", "receiver": "self", "file": "app.rb", "function": "set_namespace", "line": 3, "span": [3, 1, 3, 10], "owner": "HookSpec" }
            ],
            "chained_self_reads": [
                { "field": "namespace", "receiver": "spec", "file": "app.rb", "function": "describe", "line": 8, "span": [8, 1, 8, 20], "owner": "HookImpl" }
            ]
        })).unwrap();

        let findings = scan_documents(&[doc]);
        assert!(
            !findings
                .iter()
                .any(|finding| finding.field.ends_with("namespace")),
            "spec is proven to be a HookSpec, so namespace has a real reader, got {:?}",
            findings
        );
    }
}
