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

pub fn scan_documents_with_corpus(documents: &[Document], corpus_complete: bool) -> Vec<SuperfluousStateFinding> {
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
            results.push(SuperfluousStateFinding {
                field: norm.clone(),
                score: if corpus_complete { 0.85 } else { 0.35 },
                classification: if corpus_complete { "dead_state" } else { "unread_in_corpus" }.to_string(),
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
                confidence: if corpus_complete { "high" } else { "low" }.to_string(),
                confidence_reason: (!corpus_complete).then(|| "the selected files are not a proven closed corpus; readers may exist outside the target".to_string()),
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
        // 2. Constructor-set only (ctorset)
        // 3. Score below threshold (< 0.1)
        // 4. Derived cache (read & write in different methods, not adjacent)
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
                // Derived cache (different methods, no adjacency info)
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
                // Derived cache read
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

        // Validate "rbw" (Read-Before-Write) is classified as derived_cache since it's disqualified from intra_method
        let rbw = findings.iter().find(|f| f.field == "rbw").unwrap();
        assert_eq!(rbw.classification, "derived_cache");
        assert_eq!(rbw.score, 0.5); // base (1/2) * intra_bonus (1) * ctor_penalty (1)

        // Validate "ctor_var" has the 0.33x penalty
        let ctor = findings.iter().find(|f| f.field == "ctor_var").unwrap();
        assert!(ctor.ctorset);
        assert_eq!(ctor.classification, "derived_cache");
        assert!((ctor.score - 0.165).abs() < 0.01); // base (1/2) * ctor_penalty (0.33) = 0.165

        // Validate "derived" is classified as derived_cache
        let derived = findings.iter().find(|f| f.field == "derived").unwrap();
        assert_eq!(derived.classification, "derived_cache");
        assert_eq!(derived.score, 0.5);

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
    fn partial_corpus_downgrades_dead_state_claim() {
        let doc: Document = serde_json::from_value(json!({
            "file": "annotator.rb", "language": "ruby",
            "state_writes": [{ "field": "semantic_index", "receiver": "self", "file": "annotator.rb", "function": "annotate", "line": 10, "span": [10, 1, 10, 20], "owner": "Annotator" }]
        })).unwrap();
        let findings = scan_documents_with_corpus(&[doc], false);
        assert_eq!(findings[0].classification, "unread_in_corpus");
        assert_eq!(findings[0].confidence, "low");
        assert!(findings[0].confidence_reason.is_some());
    }
}
