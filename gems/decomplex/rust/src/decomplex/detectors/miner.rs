use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, DecisionSite, Language};
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
    let mut sites = Vec::new();
    for doc in documents {
        sites.extend(doc.decision_sites);
    }
    let m = Miner::new(sites);
    Ok(MinerReport {
        missing_abstractions: m.missing_abstractions(2),
        neglected_conditions: m.neglected_conditions(3),
    })
}

struct Miner {
    sites: Vec<DecisionSite>,
    groups: BTreeMap<(String, Vec<String>), Vec<DecisionSite>>,
}

impl Miner {
    fn new(sites: Vec<DecisionSite>) -> Self {
        let mut groups = BTreeMap::new();
        for s in &sites {
            groups.entry((s.kind.clone(), s.members.clone())).or_insert_with(Vec::new).push(s.clone());
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
            if scatter < min_scatter { continue; }

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
                if kind != &s.kind { continue; }
                
                let mem_set: BTreeSet<_> = mem.iter().cloned().collect();
                let s_mem_set: BTreeSet<_> = s.members.iter().cloned().collect();
                
                let diff_mem_s: BTreeSet<_> = mem_set.difference(&s_mem_set).cloned().collect();
                let diff_s_mem: BTreeSet<_> = s_mem_set.difference(&mem_set).cloned().collect();

                if diff_mem_s.len() == 1 && diff_s_mem.is_empty() {
                    if s.members == *mem { continue; }

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
