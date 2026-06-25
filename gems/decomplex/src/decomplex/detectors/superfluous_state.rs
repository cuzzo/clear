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
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<SuperfluousStateFinding>> {
    let documents = crate::decomplex::syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<SuperfluousStateFinding> {
    let semantic_aliases = semantic_alias::scan_documents(documents);
    let sm_report = state_mesh::scan_documents_with_semantic_aliases_and_min_writes(
        documents,
        &semantic_aliases,
        1,
    );

    let icf_report = implicit_control_flow::scan_documents(documents);
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
        if !self_writes.is_empty() && row.readers.is_empty() {
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
                    let mut defns: Vec<String> = self_writes.iter().map(|w| w.defn.clone()).collect();
                    defns.sort();
                    defns.dedup();
                    defns
                },
                reader_methods: Vec::new(),
                ctorset: self_writes.iter().all(|w| w.defn == "initialize"),
                adjacent_sites: None,
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
                let mut defns: Vec<String> = writer_methods.iter().map(|(_, d)| d.clone()).collect();
                defns.sort();
                defns.dedup();
                defns
            },
            reader_methods: {
                let mut defns: Vec<String> = reader_methods.iter().map(|(_, d)| d.clone()).collect();
                defns.sort();
                defns.dedup();
                defns
            },
            ctorset,
            adjacent_sites: adj_sites,
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
                { "field": "intra_var", "receiver": "self", "file": "example.rb", "function": "m2", "line": 10, "span": [10, 1, 10, 10], "owner": "Class" }
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
}
