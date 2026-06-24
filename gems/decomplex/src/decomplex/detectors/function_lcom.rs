use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{Document, Language, Span};
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
    Ok(scan_summaries(&summaries))
}

pub fn scan_documents(documents: &[Document]) -> Vec<FunctionLcomRow> {
    let summaries = local_flow::scan_documents(documents);
    scan_summaries(&summaries)
}

pub fn scan_summaries(summaries: &[local_flow::MethodSummary]) -> Vec<FunctionLcomRow> {
    FunctionLcom::new(summaries).findings()
}

struct FunctionLcom<'a> {
    summaries: &'a [local_flow::MethodSummary],
    min_components: usize,
    min_locals: usize,
    min_statements: usize,
    min_score: usize,
}

impl<'a> FunctionLcom<'a> {
    fn new(summaries: &'a [local_flow::MethodSummary]) -> Self {
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

    fn pre_terminal_statements<'m>(
        &self,
        summary: &'m local_flow::MethodSummary,
    ) -> &'m [local_flow::Statement] {
        &summary.statements[..summary.statements.len() - 1]
    }

    fn terminal_join(
        &self,
        summary: &local_flow::MethodSummary,
        pre_components: &[Component],
    ) -> bool {
        let terminal = summary.statements.last().unwrap();
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
                for neighbor in &adjacency[&current] {
                    if !visited.contains(neighbor) {
                        stack.push(neighbor.clone());
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_function_lcom_gaps() {
        let m_few_locals: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "1", "owner": "C", "name": "foo", "file": "a.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 1, "end_line": 1, "span": [1,2,3,4], "source": "a = 1", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 1, "line": 2, "end_line": 2, "span": [1,2,3,4], "source": "b = 2", "reads": [], "writes": ["b"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 3, "end_line": 3, "span": [1,2,3,4], "source": "c = 3", "reads": [], "writes": ["c"], "dependencies": [], "co_uses": [] },
                { "index": 3, "line": 4, "end_line": 4, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 4, "line": 5, "end_line": 5, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 5, "line": 6, "end_line": 6, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 6, "line": 7, "end_line": 7, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 7, "line": 8, "end_line": 8, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 8, "line": 9, "end_line": 9, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 9, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 10, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m_short: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "2", "owner": "C", "name": "short", "file": "a.rb", "line": 10, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "a = 1", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m_empty: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "3", "owner": "C", "name": "empty", "file": "a.rb", "line": 20, "span": [1,2,3,4],
            "statements": [], "boundaries": []
        })).unwrap();

        let m_low_score: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "4", "owner": "C", "name": "low", "file": "a.rb", "line": 30, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 30, "end_line": 30, "span": [1,2,3,4], "source": "a = 1", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 1, "line": 31, "end_line": 31, "span": [1,2,3,4], "source": "b = 2", "reads": [], "writes": ["b"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 32, "end_line": 32, "span": [1,2,3,4], "source": "c = 3", "reads": [], "writes": ["c"], "dependencies": [], "co_uses": [] },
                { "index": 3, "line": 33, "end_line": 33, "span": [1,2,3,4], "source": "d = 4", "reads": [], "writes": ["d"], "dependencies": [], "co_uses": [] },
                { "index": 4, "line": 34, "end_line": 34, "span": [1,2,3,4], "source": "e = 5", "reads": [], "writes": ["e"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m_high1: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "5", "owner": "C", "name": "high1", "file": "a.rb", "line": 50, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 50, "end_line": 50, "span": [1,2,3,4], "source": "y = x", "reads": ["x"], "writes": ["y"], "dependencies": [["y", "x"], ["x", "x"]], "co_uses": [] },
                { "index": 1, "line": 51, "end_line": 51, "span": [1,2,3,4], "source": "x = 1", "reads": [], "writes": ["x"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 52, "end_line": 52, "span": [1,2,3,4], "source": "z = w", "reads": ["w"], "writes": ["z"], "dependencies": [["z", "w"], ["w", "not_in_vars"]], "co_uses": [] },
                { "index": 3, "line": 53, "end_line": 53, "span": [1,2,3,4], "source": "w = 2", "reads": [], "writes": ["w"], "dependencies": [], "co_uses": [] },
                { "index": 4, "line": 54, "end_line": 54, "span": [1,2,3,4], "source": "v = u", "reads": ["u"], "writes": ["v"], "dependencies": [["v", "u"]], "co_uses": [] },
                { "index": 5, "line": 55, "end_line": 55, "span": [1,2,3,4], "source": "u = 3", "reads": [], "writes": ["u"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m_high2: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "6", "owner": "C", "name": "high2", "file": "a.rb", "line": 40, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 40, "end_line": 40, "span": [1,2,3,4], "source": "y = x", "reads": ["x"], "writes": ["y"], "dependencies": [["y", "x"]], "co_uses": [] },
                { "index": 1, "line": 41, "end_line": 41, "span": [1,2,3,4], "source": "x = 1", "reads": [], "writes": ["x"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 42, "end_line": 42, "span": [1,2,3,4], "source": "z = w", "reads": ["w"], "writes": ["z"], "dependencies": [["z", "w"]], "co_uses": [] },
                { "index": 3, "line": 43, "end_line": 43, "span": [1,2,3,4], "source": "w = 2", "reads": [], "writes": ["w"], "dependencies": [], "co_uses": [] },
                { "index": 4, "line": 44, "end_line": 44, "span": [1,2,3,4], "source": "v = u", "reads": ["u"], "writes": ["v"], "dependencies": [["v", "u"]], "co_uses": [] },
                { "index": 5, "line": 45, "end_line": 45, "span": [1,2,3,4], "source": "u = 3", "reads": [], "writes": ["u"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m_high3: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "7", "owner": "C", "name": "high3", "file": "b.rb", "line": 45, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 45, "end_line": 45, "span": [1,2,3,4], "source": "y = x", "reads": ["x"], "writes": ["y"], "dependencies": [["y", "x"]], "co_uses": [] },
                { "index": 1, "line": 46, "end_line": 46, "span": [1,2,3,4], "source": "x = 1", "reads": [], "writes": ["x"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 47, "end_line": 47, "span": [1,2,3,4], "source": "z = w", "reads": ["w"], "writes": ["z"], "dependencies": [["z", "w"]], "co_uses": [] },
                { "index": 3, "line": 48, "end_line": 48, "span": [1,2,3,4], "source": "w = 2", "reads": [], "writes": ["w"], "dependencies": [], "co_uses": [] },
                { "index": 4, "line": 49, "end_line": 49, "span": [1,2,3,4], "source": "v = u", "reads": ["u"], "writes": ["v"], "dependencies": [["v", "u"]], "co_uses": [] },
                { "index": 5, "line": 50, "end_line": 50, "span": [1,2,3,4], "source": "u = 3", "reads": [], "writes": ["u"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let summaries = vec![m_few_locals, m_short, m_empty, m_low_score, m_high1, m_high2, m_high3];
        let res = scan_summaries(&summaries);
        
        assert_eq!(res.len(), 3);
        assert_eq!(res[0].file, "a.rb");
        assert_eq!(res[0].line, 40);
        assert_eq!(res[1].file, "a.rb");
        assert_eq!(res[1].line, 50);
        assert_eq!(res[2].file, "b.rb");
        assert_eq!(res[2].line, 45);

        let doc: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "local_methods": summaries
        })).unwrap();
        let doc_res = scan_documents(&[doc]);
        assert_eq!(doc_res.len(), 3);
    }
}
