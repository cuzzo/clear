use crate::decomplex::detectors::local_flow::{self, MethodSummary, Statement};
use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DerivedStateRow {
    pub file: String,
    pub defn: String,
    pub derived: String,
    pub source: String,
    pub derived_at: usize,
    pub source_reassigned_at: usize,
    pub gap: isize,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Asgn {
    name: String,
    deps: Vec<String>,
    line: usize,
    span: Span,
    statement_index: usize,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<DerivedStateRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<DerivedStateRow> {
    let summaries = local_flow::scan_documents(documents);
    scan_summaries(&summaries)
}

pub fn scan_summaries(summaries: &[MethodSummary]) -> Vec<DerivedStateRow> {
    let mut out = summaries
        .iter()
        .flat_map(|method| analyze_method(method))
        .collect::<Vec<_>>();
    out.sort_by(|a, b| {
        b.gap
            .cmp(&a.gap)
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.derived_at.cmp(&b.derived_at))
            .then_with(|| a.derived.cmp(&b.derived))
            .then_with(|| a.source.cmp(&b.source))
    });
    out
}

fn analyze_method(method: &MethodSummary) -> Vec<DerivedStateRow> {
    analyze(&method.file, &method.name, &assignments(method))
}

fn assignments(method: &MethodSummary) -> Vec<Asgn> {
    method
        .statements
        .iter()
        .flat_map(|statement| {
            let mut writes = statement.writes.iter().cloned().collect::<Vec<_>>();
            writes.sort_by(|a, b| {
                write_position(&statement.source, a)
                    .cmp(&write_position(&statement.source, b))
                    .then_with(|| a.cmp(b))
            });
            writes
                .into_iter()
                .map(|name| Asgn {
                    deps: dependencies_for(statement, &name),
                    name,
                    line: statement.line,
                    span: statement.span,
                    statement_index: statement.index,
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn write_position(source: &str, name: &str) -> usize {
    identifier_positions(source)
        .into_iter()
        .find_map(|(identifier, position)| (identifier == name).then_some(position))
        .unwrap_or(usize::MAX)
}

fn identifier_positions(source: &str) -> Vec<(String, usize)> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut start = 0usize;
    for (index, ch) in source.char_indices() {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            if current.is_empty() {
                start = index;
            }
            current.push(ch);
        } else if !current.is_empty() {
            if current
                .chars()
                .next()
                .map(|first| first == '_' || first.is_ascii_alphabetic())
                .unwrap_or(false)
            {
                out.push((current.clone(), start));
            }
            current.clear();
        }
    }
    if !current.is_empty()
        && current
            .chars()
            .next()
            .map(|first| first == '_' || first.is_ascii_alphabetic())
            .unwrap_or(false)
    {
        out.push((current, start));
    }
    out
}

fn dependencies_for(statement: &Statement, name: &str) -> Vec<String> {
    let mut deps: Vec<_> = statement
        .dependencies
        .iter()
        .filter_map(|(left, right)| {
            if left == name {
                Some(right.clone())
            } else {
                None
            }
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    deps.sort();
    deps
}

fn analyze(file: &str, defn: &str, asgns: &[Asgn]) -> Vec<DerivedStateRow> {
    let mut out = Vec::new();
    for (i, b) in asgns.iter().enumerate() {
        if b.deps.is_empty() {
            continue;
        }

        for a in &b.deps {
            if a == &b.name {
                continue;
            }

            // a reassigned strictly after b's definition?
            let reasn = asgns
                .iter()
                .skip(i + 1)
                .find(|x| &x.name == a && x.statement_index > b.statement_index);
            let Some(reasn) = reasn else { continue };

            // b recomputed at or after a's reassignment?
            let recomputed = asgns
                .iter()
                .skip(i + 1)
                .any(|x| &x.name == &b.name && x.statement_index >= reasn.statement_index);
            if recomputed {
                continue;
            }

            let loc = format!("{}:{}:{}", file, defn, b.line);
            let mut spans = BTreeMap::new();
            spans.insert(loc.clone(), b.span);

            out.push(DerivedStateRow {
                file: file.to_string(),
                defn: defn.to_string(),
                derived: b.name.clone(),
                source: a.clone(),
                derived_at: b.line,
                source_reassigned_at: reasn.line,
                gap: (reasn.line as isize) - (b.line as isize),
                at: loc,
                spans,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_derived_state_gaps() {
        let m1: MethodSummary = serde_json::from_value(json!({
            "id": "1", "owner": "T", "name": "m1", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 14, "end_line": 14, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m2: MethodSummary = serde_json::from_value(json!({
            "id": "2", "owner": "T", "name": "m1", "file": "a.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 14, "end_line": 14, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m3: MethodSummary = serde_json::from_value(json!({
            "id": "3", "owner": "T", "name": "m2", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m4: MethodSummary = serde_json::from_value(json!({
            "id": "4", "owner": "T", "name": "m3", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m5: MethodSummary = serde_json::from_value(json!({
            "id": "5", "owner": "T", "name": "m4", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "c = a", "reads": [], "writes": ["c"], "dependencies": [["c", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m6: MethodSummary = serde_json::from_value(json!({
            "id": "6", "owner": "T", "name": "m5", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "b = a; b = c", "reads": [], "writes": ["b"], "dependencies": [["b", "a"], ["b", "c"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2; c = 2", "reads": [], "writes": ["a", "c"], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let res = scan_summaries(&[m1, m2, m3, m4, m5, m6]);
        assert_eq!(res.len(), 7);
        assert_eq!(res[0].file, "b.rb");
        assert_eq!(res[0].gap, 5);

        assert_eq!(res[1].file, "a.rb");
        assert_eq!(res[1].gap, 4);

        assert_eq!(res[2].file, "b.rb");
        assert_eq!(res[2].derived_at, 10);

        // res[3] and res[4] both have derived = "b", derived_at = 11, source = "a"
        assert_eq!(res[3].derived, "b");
        assert_eq!(res[3].derived_at, 11);
        assert_eq!(res[3].source, "a");

        assert_eq!(res[4].derived, "b");
        assert_eq!(res[4].derived_at, 11);
        assert_eq!(res[4].source, "a");

        // res[5] has derived = "b", source = "c"
        assert_eq!(res[5].derived, "b");
        assert_eq!(res[5].source, "c");

        // res[6] has derived = "c"
        assert_eq!(res[6].derived, "c");
    }
}



