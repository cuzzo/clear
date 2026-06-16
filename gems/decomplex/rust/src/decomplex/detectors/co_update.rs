use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, Language, StateWrite};
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
    let mut writes = Vec::new();
    for file in files {
        let doc = syntax::parse_file(file.clone(), language)?;
        for w in doc.state_writes {
            writes.push(Write {
                attr: w.field,
                recv: w.receiver,
                file: w.file,
                defn: w.function,
                line: w.line,
                span: w.span,
            });
        }
    }
    let report = Report::new(writes);
    Ok(CoUpdateReport {
        co_written_pairs: report.co_written_pairs(3),
        neglected_updates: report.neglected_updates(3),
    })
}

pub fn state_writes_for_files(files: &[PathBuf], language: Language) -> Result<Vec<StateWrite>> {
    let mut out = Vec::new();
    for file in files {
        let doc = syntax::parse_file(file.clone(), language)?;
        out.extend(doc.state_writes);
    }
    Ok(out)
}

struct Report {
    #[allow(dead_code)]
    writes: Vec<Write>,
    by_unit: Vec<((String, String), Vec<Write>)>,
}

impl Report {
    fn new(writes: Vec<Write>) -> Self {
        let mut by_unit: Vec<((String, String), Vec<Write>)> = Vec::new();
        for w in &writes {
            let key = (w.file.clone(), w.defn.clone());
            if let Some(entry) = by_unit.iter_mut().find(|(k, _)| k == &key) {
                entry.1.push(w.clone());
            } else {
                by_unit.push((key, vec![w.clone()]));
            }
        }
        Self { writes, by_unit }
    }

    fn co_written_pairs(&self, min_support: usize) -> Vec<CoWrittenPair> {
        let mut counts: Vec<(Vec<String>, Vec<(String, String)>)> = Vec::new();
        for (unit, ws) in &self.by_unit {
            let mut attrs: Vec<_> = ws.iter().map(|w| w.attr.clone()).collect::<BTreeSet<_>>().into_iter().collect();
            attrs.sort();
            
            for i in 0..attrs.len() {
                for j in i+1..attrs.len() {
                    let pair = vec![attrs[i].clone(), attrs[j].clone()];
                    if let Some(entry) = counts.iter_mut().find(|(p, _)| p == &pair) {
                        entry.1.push(unit.clone());
                    } else {
                        counts.push((pair, vec![unit.clone()]));
                    }
                }
            }
        }

        let mut out = Vec::new();
        for (pair, units) in counts {
            if units.len() < min_support { continue; }
            out.push(CoWrittenPair {
                pair,
                support: units.len(),
                sites: units.into_iter().map(|(f, d)| format!("{}:{}", f, d)).collect(),
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
