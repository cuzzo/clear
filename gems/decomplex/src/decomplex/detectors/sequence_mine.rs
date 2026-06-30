use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BrokenProtocolReport {
    pub broken: Vec<BrokenProtocol>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BrokenProtocol {
    pub pair: Vec<String>,
    pub support: usize,
    pub confidence: f64,
    pub has: String,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Call {
    mid: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language, min_support: usize) -> Result<BrokenProtocolReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, min_support))
}

pub fn scan_documents(documents: &[Document], min_support: usize) -> BrokenProtocolReport {
    let mut calls = Vec::new();
    for document in documents {
        for path in &document.protocol_call_paths {
            for call in &path.calls {
                calls.push(Call {
                    mid: call.mid.clone(),
                    file: call.file.clone(),
                    defn: call.defn.clone(),
                    line: call.line,
                    span: call.span,
                });
            }
        }
    }
    Report::new(calls).findings(min_support)
}

struct PairSupport {
    pair: Vec<String>,
    support: usize,
}

struct Report {
    by_unit: Vec<((String, String), Vec<Call>)>,
    support: BTreeMap<String, usize>,
}

impl Report {
    fn new(calls: Vec<Call>) -> Self {
        let mut by_unit: Vec<((String, String), Vec<Call>)> = Vec::new();
        for call in calls {
            let key = (call.file.clone(), call.defn.clone());
            if let Some((_, unit_calls)) = by_unit.iter_mut().find(|(existing, _)| existing == &key)
            {
                unit_calls.push(call);
            } else {
                by_unit.push((key, vec![call]));
            }
        }

        let mut support = BTreeMap::new();
        for (_, calls) in &by_unit {
            for mid in unique_mids(calls) {
                *support.entry(mid.to_string()).or_insert(0) += 1;
            }
        }

        Self { by_unit, support }
    }

    fn findings(&self, min_support: usize) -> BrokenProtocolReport {
        BrokenProtocolReport {
            broken: self.broken_protocol(min_support, 0.75),
        }
    }

    fn broken_protocol(&self, min_support: usize, min_confidence: f64) -> Vec<BrokenProtocol> {
        let pairs = self.co_called_pairs(min_support);
        let mut out = Vec::new();
        for ((file, defn), calls) in &self.by_unit {
            let mids = unique_mids(calls);
            for pair in &pairs {
                let (has, missing) =
                    if mids.contains(&pair.pair[0].as_str()) && !mids.contains(&pair.pair[1].as_str()) {
                        (pair.pair[0].clone(), pair.pair[1].clone())
                    } else if mids.contains(&pair.pair[1].as_str()) && !mids.contains(&pair.pair[0].as_str()) {
                        (pair.pair[1].clone(), pair.pair[0].clone())
                    } else {
                        continue;
                    };
                let denominator = *self.support.get(&has).unwrap_or(&0);
                let confidence = pair.support as f64 / denominator as f64;
                if confidence < min_confidence {
                    continue;
                }
                let has_call = calls
                    .iter()
                    .filter(|call| call.mid == has)
                    .min_by(|left, right| {
                        left.line
                            .cmp(&right.line)
                            .then_with(|| left.span.cmp(&right.span))
                            .then_with(|| left.mid.cmp(&right.mid))
                    })
                    .unwrap();
                let loc = format!("{}:{}:{}", file, defn, has_call.line);
                let mut spans = BTreeMap::new();
                spans.insert(loc.clone(), has_call.span);
                out.push(BrokenProtocol {
                    pair: pair.pair.clone(),
                    support: pair.support,
                    confidence: (confidence * 100.0).round() / 100.0,
                    has,
                    missing,
                    at: loc,
                    spans,
                });
            }
        }
        out.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap()
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.at.cmp(&b.at))
        });
        out
    }

    fn co_called_pairs(&self, min_support: usize) -> Vec<PairSupport> {
        let mut counts: BTreeMap<(&str, &str), usize> = BTreeMap::new();
        for (_, calls) in &self.by_unit {
            let mids = unique_mids(calls);
            for i in 0..mids.len() {
                for j in i + 1..mids.len() {
                    *counts.entry((mids[i], mids[j])).or_insert(0) += 1;
                }
            }
        }
        let mut out: Vec<_> = counts
            .into_iter()
            .filter(|(_, support)| *support >= min_support)
            .map(|((m1, m2), support)| PairSupport {
                pair: vec![m1.to_string(), m2.to_string()],
                support,
            })
            .collect();
        out.sort_by(|a, b| b.support.cmp(&a.support));
        out
    }
}

fn unique_mids(calls: &[Call]) -> Vec<&str> {
    let set: BTreeSet<_> = calls.iter().map(|call| call.mid.as_str()).collect();
    set.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_sequence_mine_gaps() {
        let doc: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "protocol_call_paths": [
                {
                    "file": "foo.rb",
                    "owner": "Class",
                    "name": "u1",
                    "line": 1,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u1", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u1", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u1", "line": 10, "span": [14, 15, 16, 17] },
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u1", "line": 11, "span": [10, 11, 12, 13] },
                        { "mid": "b", "file": "foo.rb", "owner": "Class", "defn": "u1", "line": 10, "span": [10, 11, 12, 13] }
                    ]
                },
                {
                    "file": "foo.rb",
                    "owner": "Class",
                    "name": "u2",
                    "line": 2,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u2", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "b", "file": "foo.rb", "owner": "Class", "defn": "u2", "line": 10, "span": [10, 11, 12, 13] }
                    ]
                },
                {
                    "file": "foo.rb",
                    "owner": "Class",
                    "name": "u3",
                    "line": 3,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u3", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "b", "file": "foo.rb", "owner": "Class", "defn": "u3", "line": 10, "span": [10, 11, 12, 13] }
                    ]
                },
                {
                    "file": "foo.rb",
                    "owner": "Class",
                    "name": "u4",
                    "line": 4,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u4", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "b", "file": "foo.rb", "owner": "Class", "defn": "u4", "line": 10, "span": [10, 11, 12, 13] }
                    ]
                },
                {
                    "file": "foo.rb",
                    "owner": "Class",
                    "name": "u5",
                    "line": 5,
                    "calls": [
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u5", "line": 10, "span": [10, 11, 12, 13] },
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u5", "line": 10, "span": [10, 10, 12, 13] },
                        { "mid": "a", "file": "foo.rb", "owner": "Class", "defn": "u5", "line": 11, "span": [11, 11, 12, 13] }
                    ]
                }
            ]
        })).unwrap();

        let mut calls = Vec::new();
        for path in &doc.protocol_call_paths {
            for call in &path.calls {
                calls.push(super::Call {
                    mid: call.mid.clone(),
                    file: call.file.clone(),
                    defn: call.defn.clone(),
                    line: call.line,
                    span: call.span,
                });
            }
        }
        let report = super::BrokenProtocolReport {
            broken: super::Report::new(calls).broken_protocol(3, 0.75),
        };
        assert_eq!(report.broken.len(), 1);
        assert_eq!(report.broken[0].has, "a");
        assert_eq!(report.broken[0].missing, "b");
        assert_eq!(report.broken[0].at, "foo.rb:u5:10");
        assert_eq!(report.broken[0].confidence, 0.8);
    }
}
