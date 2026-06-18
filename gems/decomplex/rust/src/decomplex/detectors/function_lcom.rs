use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FunctionLcomRow {
    pub at: String,
    pub owner: String,
    pub defn: String,
    pub score: usize,
    pub components: usize,
    pub mode: String,
    pub locals: usize,
    pub statements: usize,
    pub spans: BTreeMap<String, Span>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<FunctionLcomRow>> {
    let summaries = local_flow::scan_files(files, language)?;
    let mut detector = FunctionLcom::new(summaries);
    Ok(detector.findings())
}

struct FunctionLcom {
    summaries: Vec<local_flow::MethodSummary>,
    min_components: usize,
    min_locals: usize,
    min_statements: usize,
    min_score: usize,
}

impl FunctionLcom {
    fn new(summaries: Vec<local_flow::MethodSummary>) -> Self {
        Self {
            summaries,
            min_components: 2,
            min_locals: 5,
            min_statements: 5,
            min_score: 40,
        }
    }

    fn findings(&mut self) -> Vec<FunctionLcomRow> {
        let mut out: Vec<_> = self
            .summaries
            .iter()
            .filter_map(|s| self.finding_for(s))
            .collect();
        out.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.at.cmp(&b.at)));
        out
    }

    fn finding_for(&self, summary: &local_flow::MethodSummary) -> Option<FunctionLcomRow> {
        let all_locals = self.all_locals(summary);
        if all_locals.len() < self.min_locals {
            return None;
        }
        if summary.statements.len() < self.min_statements {
            return None;
        }

        let components = self.connected_components(summary, &all_locals);
        if components.len() < self.min_components {
            return None;
        }

        let score = (components.len() * 10) + all_locals.len() + summary.statements.len();
        if score < self.min_score {
            return None;
        }
        let mode = if self.late_join(summary, &components) {
            "late_join".to_string()
        } else {
            "disjoint".to_string()
        };

        let at = format!("{}:{}:{}", summary.file, summary.name, summary.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), summary.span);

        Some(FunctionLcomRow {
            at,
            owner: summary.owner.clone(),
            defn: summary.name.clone(),
            score,
            components: components.len(),
            mode,
            locals: all_locals.len(),
            statements: summary.statements.len(),
            spans,
        })
    }

    fn all_locals(&self, summary: &local_flow::MethodSummary) -> BTreeSet<String> {
        let mut locals = BTreeSet::new();
        for s in &summary.statements {
            locals.extend(s.reads.clone());
            locals.extend(s.writes.clone());
        }
        locals
    }

    fn connected_components(
        &self,
        summary: &local_flow::MethodSummary,
        locals: &BTreeSet<String>,
    ) -> Vec<BTreeSet<String>> {
        let mut adj: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for s in &summary.statements {
            let mut touched: Vec<_> = s.reads.union(&s.writes).cloned().collect();
            for (lhs, rhs) in &s.dependencies {
                touched.push(lhs.clone());
                touched.push(rhs.clone());
            }
            for i in 0..touched.len() {
                for j in i + 1..touched.len() {
                    adj.entry(touched[i].clone())
                        .or_default()
                        .insert(touched[j].clone());
                    adj.entry(touched[j].clone())
                        .or_default()
                        .insert(touched[i].clone());
                }
            }
        }

        let mut components = Vec::new();
        let mut unvisited = locals.clone();

        while let Some(start) = unvisited.iter().next().cloned() {
            let mut component = BTreeSet::new();
            let mut queue = vec![start];
            while let Some(node) = queue.pop() {
                if !unvisited.contains(&node) {
                    continue;
                }
                unvisited.remove(&node);
                component.insert(node.clone());
                if let Some(neighbors) = adj.get(&node) {
                    for n in neighbors {
                        if unvisited.contains(n) {
                            queue.push(n.clone());
                        }
                    }
                }
            }
            if component.len() > 0 {
                components.push(component);
            }
        }

        components.retain(|c| {
            c.len() > 1 || self.standalone_state_usage(summary, c.iter().next().unwrap())
        });
        components
    }

    fn standalone_state_usage(&self, summary: &local_flow::MethodSummary, local: &str) -> bool {
        let reads: usize = summary
            .statements
            .iter()
            .map(|s| s.reads.contains(local) as usize)
            .sum();
        let writes: usize = summary
            .statements
            .iter()
            .map(|s| s.writes.contains(local) as usize)
            .sum();
        reads + writes > 1
    }

    fn late_join(
        &self,
        summary: &local_flow::MethodSummary,
        components: &[BTreeSet<String>],
    ) -> bool {
        let Some(last) = summary.statements.last() else {
            return false;
        };
        let mut joined = 0;
        for c in components {
            if last.reads.intersection(c).next().is_some()
                || last.writes.intersection(c).next().is_some()
            {
                joined += 1;
            }
        }
        joined >= 2
    }
}
