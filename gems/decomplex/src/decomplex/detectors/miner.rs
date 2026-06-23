use crate::decomplex::syntax::{self, DecisionSite, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MinerReport {
    pub missing_abstractions: Vec<MissingAbstraction>,
    pub neglected_conditions: Vec<NeglectedCondition>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MissingAbstraction {
    pub kind: String,
    pub members: Vec<String>,
    pub support: usize,
    pub scatter: usize,
    pub rank: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedCondition {
    pub pattern: Vec<String>,
    pub support: usize,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<MinerReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> MinerReport {
    let mut sites = Vec::new();
    for doc in documents {
        sites.extend(doc.decision_sites.clone());
    }
    let m = Miner::new(sites);
    MinerReport {
        missing_abstractions: m.missing_abstractions(2),
        neglected_conditions: m.neglected_conditions(3),
    }
}

struct Miner {
    sites: Vec<DecisionSite>,
    groups: Vec<((String, Vec<String>), Vec<DecisionSite>)>,
}

impl Miner {
    fn new(sites: Vec<DecisionSite>) -> Self {
        let mut groups: Vec<((String, Vec<String>), Vec<DecisionSite>)> = Vec::new();
        for s in &sites {
            let key = (s.kind.clone(), s.members.clone());
            if let Some((_, grouped)) = groups.iter_mut().find(|(existing, _)| existing == &key) {
                grouped.push(s.clone());
            } else {
                groups.push((key, vec![s.clone()]));
            }
        }
        Self { sites, groups }
    }

    fn missing_abstractions(&self, min_scatter: usize) -> Vec<MissingAbstraction> {
        let mut out = Vec::new();
        for ((kind, members), sts) in &self.groups {
            let mut methods = BTreeSet::new();
            for s in sts {
                methods.insert((s.file.clone(), s.function.clone()));
            }
            let scatter = methods.len();
            if scatter < min_scatter {
                continue;
            }

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for s in sts {
                let l = self.loc(s);
                sites.push(l.clone());
                spans.insert(l, s.span);
            }

            out.push(MissingAbstraction {
                kind: kind.clone(),
                members: members.clone(),
                support: sts.len(),
                scatter,
                rank: sts.len() * scatter,
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| b.rank.cmp(&a.rank));
        out
    }

    fn neglected_conditions(&self, min_support: usize) -> Vec<NeglectedCondition> {
        let mut popular = Vec::new();
        for ((kind, members), sts) in &self.groups {
            if sts.len() >= min_support {
                popular.push((kind.clone(), members.clone(), sts.len()));
            }
        }

        let mut out = Vec::new();
        for s in &self.sites {
            for (kind, mem, sup) in &popular {
                if kind != &s.kind {
                    continue;
                }

                let mem_set: BTreeSet<_> = mem.iter().cloned().collect();
                let s_mem_set: BTreeSet<_> = s.members.iter().cloned().collect();

                let diff_mem_s: BTreeSet<_> = mem_set.difference(&s_mem_set).cloned().collect();
                let diff_s_mem: BTreeSet<_> = s_mem_set.difference(&mem_set).cloned().collect();

                if diff_mem_s.len() == 1 && diff_s_mem.is_empty() {
                    let l = self.loc(s);
                    let mut spans = BTreeMap::new();
                    spans.insert(l.clone(), s.span);

                    out.push(NeglectedCondition {
                        pattern: mem.clone(),
                        support: *sup,
                        missing: diff_mem_s.into_iter().next().unwrap(),
                        at: l,
                        spans,
                    });
                }
            }
        }
        out.sort_by(|a, b| b.support.cmp(&a.support));
        out.dedup_by(|a, b| a.at == b.at && a.pattern == b.pattern);
        out
    }

    fn loc(&self, s: &DecisionSite) -> String {
        format!("{}:{}:{}", s.file, s.function, s.line)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_miner_gaps() {
        // We need 3 sites with kind1 and members ["a", "b", "c"] to make it popular (support >= 3)
        // We also need another site with kind2 (different kind) to hit line 115 continue.
        // We also need another site with kind1 and members ["a", "b"] to trigger the neglected condition (diff_mem_s is ["c"]).
        let doc: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "decision_sites": [
                {
                    "kind": "kind1", "members": ["a", "b", "c"], "file": "a.rb", "function": "f", "line": 1, "span": [1,2,3,4],
                    "predicate": "a && b && c", "enclosing_span": [1,2,3,4]
                },
                {
                    "kind": "kind1", "members": ["a", "b", "c"], "file": "a.rb", "function": "f", "line": 2, "span": [1,2,3,4],
                    "predicate": "a && b && c", "enclosing_span": [1,2,3,4]
                },
                {
                    "kind": "kind1", "members": ["a", "b", "c"], "file": "a.rb", "function": "f", "line": 3, "span": [1,2,3,4],
                    "predicate": "a && b && c", "enclosing_span": [1,2,3,4]
                },
                {
                    "kind": "kind2", "members": ["a", "b", "c"], "file": "a.rb", "function": "f", "line": 4, "span": [1,2,3,4],
                    "predicate": "a && b && c", "enclosing_span": [1,2,3,4]
                },
                {
                    "kind": "kind1", "members": ["a", "b"], "file": "a.rb", "function": "f", "line": 5, "span": [1,2,3,4],
                    "predicate": "a && b", "enclosing_span": [1,2,3,4]
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc]);
        assert_eq!(report.neglected_conditions.len(), 1);
        assert_eq!(report.neglected_conditions[0].missing, "c");
        assert_eq!(report.neglected_conditions[0].support, 3);
    }
}
