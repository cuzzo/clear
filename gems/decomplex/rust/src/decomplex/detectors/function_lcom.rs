use crate::decomplex::ast::Span;
use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FunctionLcomRow {
    pub file: String,
    pub defn: String,
    pub owner: String,
    pub method: String,
    pub line: usize,
    pub at: String,
    pub score: usize,
    pub mode: String,
    pub components: usize,
    pub locals: usize,
    pub statements: usize,
    pub terminal_join: bool,
    pub component_vars: Vec<Vec<String>>,
    pub component_lines: Vec<Vec<usize>>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Component {
    vars: BTreeSet<String>,
    statements: Vec<usize>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<FunctionLcomRow>> {
    let summaries = local_flow::scan_files(files, language)?;
    Ok(scan_summaries(summaries))
}

pub fn scan_documents(documents: &[Document]) -> Vec<FunctionLcomRow> {
    scan_summaries(local_flow::scan_documents(documents))
}

pub fn scan_summaries(summaries: Vec<local_flow::MethodSummary>) -> Vec<FunctionLcomRow> {
    FunctionLcom::new(summaries).findings()
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

    fn findings(&self) -> Vec<FunctionLcomRow> {
        let mut out = self
            .summaries
            .iter()
            .filter_map(|summary| self.finding_for(summary))
            .collect::<Vec<_>>();
        out.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.line.cmp(&b.line))
        });
        out
    }

    fn finding_for(&self, summary: &local_flow::MethodSummary) -> Option<FunctionLcomRow> {
        if summary.statements.len() < self.min_statements {
            return None;
        }

        let full_components =
            self.substantial_components(self.components(&summary.statements), &summary.statements);
        let pre_terminal = self.pre_terminal_statements(summary);
        let pre_components =
            self.substantial_components(self.components(pre_terminal), pre_terminal);
        let local_count = self.local_names(&summary.statements).len();
        if local_count < self.min_locals {
            return None;
        }

        let terminal_join = self.terminal_join(summary, &pre_components);
        let mut report_components = full_components;
        let mut mode = "disjoint".to_string();
        if report_components.len() < self.min_components
            && terminal_join
            && pre_components.len() >= self.min_components
        {
            report_components = pre_components;
            mode = "late_join".to_string();
        }
        if report_components.len() < self.min_components {
            return None;
        }

        let score = self.score_for(
            &report_components,
            local_count,
            summary.statements.len(),
            terminal_join,
        );
        if score < self.min_score {
            return None;
        }

        let at = format!("{}:{}:{}", summary.file, summary.name, summary.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), summary.span);
        Some(FunctionLcomRow {
            file: summary.file.clone(),
            defn: summary.name.clone(),
            owner: summary.owner.clone(),
            method: summary.name.clone(),
            line: summary.line,
            at,
            score,
            mode,
            components: report_components.len(),
            locals: local_count,
            statements: summary.statements.len(),
            terminal_join,
            component_vars: report_components
                .iter()
                .map(|component| component.vars.iter().cloned().collect())
                .collect(),
            component_lines: report_components
                .iter()
                .map(|component| {
                    component
                        .statements
                        .iter()
                        .map(|index| summary.statements[*index].line)
                        .collect::<BTreeSet<_>>()
                        .into_iter()
                        .collect()
                })
                .collect(),
            spans,
        })
    }

    fn pre_terminal_statements<'a>(
        &self,
        summary: &'a local_flow::MethodSummary,
    ) -> &'a [local_flow::Statement] {
        if summary.statements.len() <= 1 {
            &[]
        } else {
            &summary.statements[..summary.statements.len() - 1]
        }
    }

    fn terminal_join(
        &self,
        summary: &local_flow::MethodSummary,
        pre_components: &[Component],
    ) -> bool {
        let Some(terminal) = summary.statements.last() else {
            return false;
        };
        let mut component_index = BTreeMap::new();
        for (index, component) in pre_components.iter().enumerate() {
            for name in &component.vars {
                component_index.insert(name.clone(), index);
            }
        }
        self.touched_vars(terminal)
            .into_iter()
            .filter_map(|name| component_index.get(&name).copied())
            .collect::<BTreeSet<_>>()
            .len()
            >= self.min_components
    }

    fn score_for(
        &self,
        components: &[Component],
        local_count: usize,
        statement_count: usize,
        terminal_join: bool,
    ) -> usize {
        (components.len() * 10) + local_count + statement_count + if terminal_join { 5 } else { 0 }
    }

    fn substantial_components(
        &self,
        raw_components: Vec<BTreeSet<String>>,
        statements: &[local_flow::Statement],
    ) -> Vec<Component> {
        let mut components = raw_components
            .into_iter()
            .filter_map(|vars| {
                let touched = statements
                    .iter()
                    .enumerate()
                    .filter_map(|(index, statement)| {
                        if !self.touched_vars(statement).is_disjoint(&vars) {
                            Some(index)
                        } else {
                            None
                        }
                    })
                    .collect::<Vec<_>>();
                if vars.len() < 2 || touched.len() < 2 {
                    return None;
                }
                Some(Component {
                    vars,
                    statements: touched,
                })
            })
            .collect::<Vec<_>>();
        components
            .sort_by_key(|component| component.statements.first().copied().unwrap_or(usize::MAX));
        components
    }

    fn components(&self, statements: &[local_flow::Statement]) -> Vec<BTreeSet<String>> {
        let vars = self.local_names(statements);
        let edges = self.graph_edges(statements);
        let mut adjacency = vars
            .iter()
            .map(|name| (name.clone(), BTreeSet::new()))
            .collect::<BTreeMap<_, _>>();
        for (left, right) in edges {
            if left == right {
                continue;
            }
            adjacency
                .entry(left.clone())
                .or_default()
                .insert(right.clone());
            adjacency.entry(right).or_default().insert(left);
        }

        let mut visited = BTreeSet::new();
        let mut components = Vec::new();
        for name in vars {
            if visited.contains(&name) {
                continue;
            }
            let mut component = BTreeSet::new();
            let mut stack = vec![name];
            while let Some(current) = stack.pop() {
                if visited.contains(&current) {
                    continue;
                }
                visited.insert(current.clone());
                component.insert(current.clone());
                if let Some(neighbors) = adjacency.get(&current) {
                    for neighbor in neighbors {
                        if !visited.contains(neighbor) {
                            stack.push(neighbor.clone());
                        }
                    }
                }
            }
            components.push(component);
        }
        components
    }

    fn graph_edges(&self, statements: &[local_flow::Statement]) -> Vec<(String, String)> {
        let mut edges = Vec::new();
        for statement in statements {
            edges.extend(statement.dependencies.iter().cloned());
            edges.extend(statement.co_uses.iter().cloned());
        }
        edges
    }

    fn local_names(&self, statements: &[local_flow::Statement]) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        for statement in statements {
            names.extend(self.touched_vars(statement));
        }
        names
    }

    fn touched_vars(&self, statement: &local_flow::Statement) -> BTreeSet<String> {
        statement.reads.union(&statement.writes).cloned().collect()
    }
}
