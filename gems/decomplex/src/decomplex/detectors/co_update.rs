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
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<CoUpdateReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> CoUpdateReport {
    let mut writes = Vec::new();
    for doc in documents {
        for w in &doc.state_writes {
            writes.push(write_from_state_write(w));
        }
    }
    let report = Report::new(writes);
    CoUpdateReport {
        co_written_pairs: report.co_written_pairs(3),
        neglected_updates: report.neglected_updates(3),
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
    }
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

    fn co_written_pairs(&self, min_support: usize) -> Vec<CoWrittenPair> {
        let mut keys = Vec::new();
        let mut counts: BTreeMap<Vec<String>, Vec<(String, String)>> = BTreeMap::new();
        for (unit, ws) in &self.by_unit {
            let mut attrs: Vec<_> = ws
                .iter()
                .map(|w| w.attr.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
            attrs.sort();

            for i in 0..attrs.len() {
                for j in i + 1..attrs.len() {
                    let pair = vec![attrs[i].clone(), attrs[j].clone()];
                    if !counts.contains_key(&pair) {
                        keys.push(pair.clone());
                    }
                    counts.entry(pair).or_default().push(unit.clone());
                }
            }
        }

        let mut out = Vec::new();
        for pair in keys {
            let units = counts.remove(&pair).unwrap();
            if units.len() < min_support {
                continue;
            }
            out.push(CoWrittenPair {
                pair,
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
}

