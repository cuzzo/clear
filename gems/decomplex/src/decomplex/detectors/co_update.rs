use crate::decomplex::syntax::{self, Document, Language, Span, StateWrite};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoUpdateReport {
    pub co_written_pairs: Vec<CoWrittenPair>,
    pub neglected_updates: Vec<NeglectedUpdate>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoWrittenPair {
    pub pair: Vec<String>,
    pub support: usize,
    pub sites: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedUpdate {
    pub pair: Vec<String>,
    pub support: usize,
    pub has: String,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
    pub recv: String,
}

#[derive(Clone, Debug)]
struct Write {
    attr: String,
    recv: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
    owner: String,
}

pub fn scan_files(files: &[PathBuf], language: Language, min_support: usize) -> Result<CoUpdateReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, min_support))
}

pub fn scan_documents(documents: &[Document], min_support: usize) -> CoUpdateReport {
    let mut writes = Vec::new();
    for doc in documents {
        for w in &doc.state_writes {
            writes.push(write_from_state_write(w));
        }
    }
    let report = Report::new(writes);
    CoUpdateReport {
        co_written_pairs: report.co_written_pairs(min_support),
        neglected_updates: report.neglected_updates(min_support),
    }
}

pub fn state_writes_for_documents(documents: &[Document]) -> Vec<StateWrite> {
    documents
        .iter()
        .flat_map(|document| document.state_writes.clone())
        .collect()
}

pub fn state_writes_for_files(files: &[PathBuf], language: Language) -> Result<Vec<StateWrite>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(state_writes_for_documents(&documents))
}

fn write_from_state_write(w: &StateWrite) -> Write {
    Write {
        attr: w.field.clone(),
        recv: w.receiver.clone(),
        file: w.file.clone(),
        defn: w.function.clone(),
        line: w.line,
        span: w.span,
        owner: w.owner.clone(),
    }
}

fn file_stem(file: &str) -> Option<String> {
    std::path::Path::new(file)
        .file_stem()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

fn is_dynamic_language(file: &str) -> bool {
    if let Some(ext) = std::path::Path::new(file).extension().and_then(|e| e.to_str()) {
        matches!(ext, "rb" | "py" | "js" | "php" | "lua")
    } else {
        false
    }
}

fn is_unknown(w: &Write) -> bool {
    if w.owner.is_empty() || w.owner == "Object" || w.owner == "(unknown)" {
        return true;
    }
    if is_dynamic_language(&w.file) && w.recv != "self" && w.recv != "this" {
        return true;
    }
    if let Some(stem) = file_stem(&w.file) {
        if w.owner.eq_ignore_ascii_case(&stem) {
            return true;
        }
    }
    false
}

fn can_pair(w1: &Write, w2: &Write) -> bool {
    if !w1.recv.is_empty() && w1.recv == w2.recv {
        if w1.owner == w2.owner || is_unknown(w1) || is_unknown(w2) {
            return true;
        }
    }
    if !is_unknown(w1) && !is_unknown(w2) && w1.owner == w2.owner {
        return true;
    }
    false
}

struct Report {
    #[allow(dead_code)]
    writes: Vec<Write>,
    by_unit: Vec<((String, String), Vec<Write>)>,
}

impl Report {
    fn new(writes: Vec<Write>) -> Self {
        let mut keys = Vec::new();
        let mut map: BTreeMap<(String, String), Vec<Write>> = BTreeMap::new();
        for w in &writes {
            let key = (w.file.clone(), w.defn.clone());
            if !map.contains_key(&key) {
                keys.push(key.clone());
            }
            map.entry(key).or_default().push(w.clone());
        }
        let by_unit = keys
            .into_iter()
            .map(|k| {
                let v = map.remove(&k).unwrap();
                (k, v)
            })
            .collect();
        Self { writes, by_unit }
    }

    fn pair_owners(&self) -> BTreeMap<(&str, &str), BTreeSet<&str>> {
        let mut pair_owners: BTreeMap<(&str, &str), BTreeSet<&str>> = BTreeMap::new();
        for (_unit, ws) in &self.by_unit {
            for i in 0..ws.len() {
                for j in i + 1..ws.len() {
                    let w1 = &ws[i];
                    let w2 = &ws[j];
                    if w1.attr != w2.attr && can_pair(w1, w2) {
                        let pair = if w1.attr < w2.attr { (w1.attr.as_str(), w2.attr.as_str()) } else { (w2.attr.as_str(), w1.attr.as_str()) };
                        let owner_ctx = if is_unknown(w1) || is_unknown(w2) {
                            ""
                        } else {
                            w1.owner.as_str()
                        };
                        pair_owners.entry(pair).or_default().insert(owner_ctx);
                    }
                }
            }
        }
        pair_owners
    }

    fn pair_recvs(&self) -> BTreeMap<(&str, &str), BTreeSet<&str>> {
        let mut pair_recvs: BTreeMap<(&str, &str), BTreeSet<&str>> = BTreeMap::new();
        for (_unit, ws) in &self.by_unit {
            for i in 0..ws.len() {
                for j in i + 1..ws.len() {
                    let w1 = &ws[i];
                    let w2 = &ws[j];
                    if w1.attr != w2.attr && can_pair(w1, w2) {
                        let pair = if w1.attr < w2.attr { (w1.attr.as_str(), w2.attr.as_str()) } else { (w2.attr.as_str(), w1.attr.as_str()) };
                        let entry = pair_recvs.entry(pair).or_default();
                        if !w1.recv.is_empty() {
                            entry.insert(w1.recv.as_str());
                        }
                        if !w2.recv.is_empty() {
                            entry.insert(w2.recv.as_str());
                        }
                    }
                }
            }
        }
        pair_recvs
    }

    fn co_written_pairs(&self, min_support: usize) -> Vec<CoWrittenPair> {
        let mut counts: BTreeMap<(&str, &str), BTreeSet<(&str, &str)>> = BTreeMap::new();
        for (unit, ws) in &self.by_unit {
            for i in 0..ws.len() {
                for j in i + 1..ws.len() {
                    let w1 = &ws[i];
                    let w2 = &ws[j];
                    if w1.attr != w2.attr && can_pair(w1, w2) {
                        let pair = if w1.attr < w2.attr { (w1.attr.as_str(), w2.attr.as_str()) } else { (w2.attr.as_str(), w1.attr.as_str()) };
                        counts.entry(pair).or_default().insert((unit.0.as_str(), unit.1.as_str()));
                    }
                }
            }
        }

        let mut out = Vec::new();
        for (pair, units) in counts {
            if units.len() < min_support {
                continue;
            }
            out.push(CoWrittenPair {
                pair: vec![pair.0.to_string(), pair.1.to_string()],
                support: units.len(),
                sites: units
                    .into_iter()
                    .map(|(f, d)| format!("{}:{}", f, d))
                    .collect(),
            });
        }
        out.sort_by(|a, b| b.support.cmp(&a.support));
        out
    }

    fn neglected_updates(&self, min_support: usize) -> Vec<NeglectedUpdate> {
        let pairs = self.co_written_pairs(min_support);
        let pair_owners = self.pair_owners();
        let pair_recvs = self.pair_recvs();
        let mut out = Vec::new();

        for ((file, defn), ws) in &self.by_unit {
            let attrs: BTreeSet<_> = ws.iter().map(|w| w.attr.clone()).collect();
            for p in &pairs {
                let a = &p.pair[0];
                let b = &p.pair[1];

                let (has, miss) = if attrs.contains(a) && !attrs.contains(b) {
                    (Some(a), Some(b))
                } else if attrs.contains(b) && !attrs.contains(a) {
                    (Some(b), Some(a))
                } else {
                    (None, None)
                };

                if let (Some(has), Some(miss)) = (has, miss) {
                    if let Some(w) = ws.iter().find(|x| &x.attr == has) {
                        let pair_tuple = if a < b { (a.as_str(), b.as_str()) } else { (b.as_str(), a.as_str()) };
                        let matches_owner = if is_unknown(w) {
                            true
                        } else if let Some(owners) = pair_owners.get(&pair_tuple) {
                            owners.contains("") || owners.contains(&w.owner.as_str())
                        } else {
                            false
                        };

                        let matches_recv = if is_dynamic_language(file) {
                            true
                        } else if let Some(recvs) = pair_recvs.get(&pair_tuple) {
                            if recvs.contains(&w.recv.as_str()) {
                                true
                            } else {
                                w.recv.is_empty() || w.recv == "self" || w.recv == "this" || recvs.contains("self") || recvs.contains("this")
                            }
                        } else {
                            true
                        };

                        if matches_owner && matches_recv {
                            let loc = format!("{}:{}:{}", file, defn, w.line);
                            let mut spans = BTreeMap::new();
                            spans.insert(loc.clone(), w.span);
                            out.push(NeglectedUpdate {
                                pair: p.pair.clone(),
                                support: p.support,
                                has: has.clone(),
                                missing: miss.clone(),
                                at: loc,
                                spans,
                                recv: w.recv.clone(),
                            });
                        }
                    }
                }
            }
        }
        out.sort_by(|a, b| b.support.cmp(&a.support));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_co_update_gaps() {
        let doc: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "state_writes": [
                {
                    "field": "a",
                    "receiver": "self",
                    "file": "foo.rb",
                    "function": "m",
                    "line": 1,
                    "span": [1, 2, 3, 4],
                    "owner": "MyType"
                },
                {
                    "field": "b",
                    "receiver": "self",
                    "file": "foo.rb",
                    "function": "m",
                    "line": 2,
                    "span": [1, 2, 3, 4],
                    "owner": "MyType"
                }
            ]
        })).unwrap();

        let writes = state_writes_for_documents(&[doc]);
        assert_eq!(writes.len(), 2);

        let writes_from_files = state_writes_for_files(&[], Language::Ruby).unwrap();
        assert!(writes_from_files.is_empty());

        let w1 = write_from_state_write(&writes[0]);
        let w2 = write_from_state_write(&writes[1]);
        let r = Report::new(vec![w1, w2]);
        let pairs = r.co_written_pairs(2);
        assert!(pairs.is_empty());
    }

    #[test]
    fn test_co_update_dynamic_mapping() {
        // Scenario 1: Pair is co-written in a KNOWN object context, but missed in an UNKNOWN context.
        let doc1: Document = serde_json::from_value(json!({
            "file": "known_to_unknown.rb",
            "language": "ruby",
            "state_writes": [
                // Unit 1: set_both (known context)
                {
                    "field": "a",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both",
                    "line": 1,
                    "span": [1, 1, 1, 10],
                    "owner": "KnownClass"
                },
                {
                    "field": "b",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both",
                    "line": 2,
                    "span": [2, 1, 2, 10],
                    "owner": "KnownClass"
                },
                // Unit 2: set_both_again (known context)
                {
                    "field": "a",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both_again",
                    "line": 5,
                    "span": [5, 1, 5, 10],
                    "owner": "KnownClass"
                },
                {
                    "field": "b",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both_again",
                    "line": 6,
                    "span": [6, 1, 6, 10],
                    "owner": "KnownClass"
                },
                // Unit 3: set_both_third (known context)
                {
                    "field": "a",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both_third",
                    "line": 10,
                    "span": [10, 1, 10, 10],
                    "owner": "KnownClass"
                },
                {
                    "field": "b",
                    "receiver": "self",
                    "file": "known_to_unknown.rb",
                    "function": "set_both_third",
                    "line": 11,
                    "span": [11, 1, 11, 10],
                    "owner": "KnownClass"
                },
                // Unit 4: misses_b (unknown context - receiver is local variable)
                {
                    "field": "a",
                    "receiver": "unknown_obj",
                    "file": "known_to_unknown.rb",
                    "function": "misses_b",
                    "line": 15,
                    "span": [15, 1, 15, 10],
                    "owner": "known_to_unknown"
                }
            ]
        })).unwrap();

        let writes1 = doc1.state_writes.iter().map(super::write_from_state_write).collect();
        let rep1 = super::Report::new(writes1);
        let report1 = super::CoUpdateReport {
            co_written_pairs: rep1.co_written_pairs(3),
            neglected_updates: rep1.neglected_updates(3),
        };
        assert_eq!(report1.co_written_pairs.len(), 1);
        assert_eq!(report1.co_written_pairs[0].pair, vec!["a", "b"]);
        assert_eq!(report1.co_written_pairs[0].support, 3);
        
        assert_eq!(report1.neglected_updates.len(), 1);
        assert_eq!(report1.neglected_updates[0].has, "a");
        assert_eq!(report1.neglected_updates[0].missing, "b");
        assert_eq!(report1.neglected_updates[0].recv, "unknown_obj");

        // Scenario 2: Pair is co-written in an UNKNOWN context, but missed in a KNOWN context.
        let doc2: Document = serde_json::from_value(json!({
            "file": "unknown_to_known.rb",
            "language": "ruby",
            "state_writes": [
                // Unit 1: stable_one (unknown context - receiver node)
                {
                    "field": "x",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_one",
                    "line": 1,
                    "span": [1, 1, 1, 10],
                    "owner": "unknown_to_known"
                },
                {
                    "field": "y",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_one",
                    "line": 2,
                    "span": [2, 1, 2, 10],
                    "owner": "unknown_to_known"
                },
                // Unit 2: stable_two (unknown context - receiver node)
                {
                    "field": "x",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_two",
                    "line": 5,
                    "span": [5, 1, 5, 10],
                    "owner": "unknown_to_known"
                },
                {
                    "field": "y",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_two",
                    "line": 6,
                    "span": [6, 1, 6, 10],
                    "owner": "unknown_to_known"
                },
                // Unit 3: stable_three (unknown context - receiver node)
                {
                    "field": "x",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_three",
                    "line": 10,
                    "span": [10, 1, 10, 10],
                    "owner": "unknown_to_known"
                },
                {
                    "field": "y",
                    "receiver": "node",
                    "file": "unknown_to_known.rb",
                    "function": "stable_three",
                    "line": 11,
                    "span": [11, 1, 11, 10],
                    "owner": "unknown_to_known"
                },
                // Unit 4: misses_y (known context)
                {
                    "field": "x",
                    "receiver": "self",
                    "file": "unknown_to_known.rb",
                    "function": "misses_y",
                    "line": 15,
                    "span": [15, 1, 15, 10],
                    "owner": "KnownClass2"
                }
            ]
        })).unwrap();

        let writes2 = doc2.state_writes.iter().map(super::write_from_state_write).collect();
        let rep2 = super::Report::new(writes2);
        let report2 = super::CoUpdateReport {
            co_written_pairs: rep2.co_written_pairs(3),
            neglected_updates: rep2.neglected_updates(3),
        };
        assert_eq!(report2.co_written_pairs.len(), 1);
        assert_eq!(report2.co_written_pairs[0].pair, vec!["x", "y"]);
        assert_eq!(report2.co_written_pairs[0].support, 3);

        assert_eq!(report2.neglected_updates.len(), 1);
        assert_eq!(report2.neglected_updates[0].has, "x");
        assert_eq!(report2.neglected_updates[0].missing, "y");
        assert_eq!(report2.neglected_updates[0].recv, "self");
    }
}

