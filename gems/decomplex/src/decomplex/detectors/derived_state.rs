use crate::decomplex::detectors::local_flow::{self, MethodSummary, Statement};
use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use fact_mine_rust::syntax::{Child, Node};
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
    analyze(method, &assignments(method))
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

fn identifier_positions(source: &str) -> Vec<(&str, usize)> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut in_ident = false;
    for (index, ch) in source.char_indices() {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            if !in_ident {
                start = index;
                in_ident = true;
            }
        } else if in_ident {
            let current = &source[start..index];
            if current
                .chars()
                .next()
                .map(|first| first == '_' || first.is_ascii_alphabetic())
                .unwrap_or(false)
            {
                out.push((current, start));
            }
            in_ident = false;
        }
    }
    if in_ident {
        let current = &source[start..];
        if current
            .chars()
            .next()
            .map(|first| first == '_' || first.is_ascii_alphabetic())
            .unwrap_or(false)
        {
            out.push((current, start));
        }
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

fn span_contains(parent: Span, child: Span) -> bool {
    let start_ok = parent[0] < child[0] || (parent[0] == child[0] && parent[1] <= child[1]);
    let end_ok = parent[2] > child[2] || (parent[2] == child[2] && parent[3] >= child[3]);
    start_ok && end_ok
}

fn is_local_helper(b: &Asgn, a: &str, asgns: &[Asgn]) -> bool {
    let mut preceding = asgns
        .iter()
        .filter(|x| &x.name == a && x.statement_index <= b.statement_index)
        .peekable();

    if preceding.peek().is_none() {
        return false;
    }

    preceding.all(|x| {
        if x.statement_index < b.statement_index {
            false
        } else {
            span_contains(b.span, x.span)
        }
    })
}

fn analyze(method: &MethodSummary, asgns: &[Asgn]) -> Vec<DerivedStateRow> {
    let file = &method.file;
    let defn = &method.name;
    let mut out = Vec::new();
    for (i, b) in asgns.iter().enumerate() {
        if b.deps.is_empty() {
            continue;
        }

        for a in &b.deps {
            if a == &b.name {
                continue;
            }

            if is_local_helper(b, a, asgns) {
                continue;
            }

            // a reassigned strictly after b's definition?
            let reasn = asgns
                .iter()
                .skip(i + 1)
                .find(|x| &x.name == a && x.statement_index > b.statement_index);
            let Some(reasn) = reasn else { continue };

            // `snapshot = original` followed by `original = snapshot` is a
            // deliberate snapshot/restore sequence, not a stale derived
            // cache. A bare copy remains analyzable: it is only this explicit
            // reverse data-flow edge that proves snapshot semantics.
            if reasn.deps.iter().any(|dependency| dependency == &b.name) {
                continue;
            }

            // b recomputed at or after a's reassignment?
            let recomputed = asgns
                .iter()
                .skip(i + 1)
                .any(|x| &x.name == &b.name && x.statement_index >= reasn.statement_index);
            if recomputed {
                continue;
            }

            // `snapshot = state; state = temporary; state = snapshot` is a
            // scoped restoration protocol. The snapshot is intentionally read
            // after mutation and is not a stale cache of the temporary state.
            let restored_from_snapshot = asgns.iter().skip(i + 1).any(|x| {
                &x.name == a && x.deps.iter().any(|dependency| dependency == &b.name)
            });
            if restored_from_snapshot {
                continue;
            }

            let reassignment_reads_derived = method.statements.iter().any(|statement| {
                statement.index == reasn.statement_index && statement.reads.contains(&b.name)
            });
            if reassignment_reads_derived {
                continue;
            }

            // Is the derived variable b read at or after a's reassignment?
            let is_read_after_reasn = method
                .statements
                .iter()
                .any(|stmt| stmt.index >= reasn.statement_index && stmt.reads.contains(&b.name));
            if !is_read_after_reasn {
                continue;
            }

            // Check if b and reasn are in sibling blocks
            let mut path_b = Vec::new();
            let mut path_reasn = Vec::new();
            if find_ancestors(&method.node, b.span, &mut path_b)
                && find_ancestors(&method.node, reasn.span, &mut path_reasn)
            {
                let mut lca_index = 0;
                while lca_index < path_b.len() && lca_index < path_reasn.len() {
                    if path_b[lca_index].first_lineno != path_reasn[lca_index].first_lineno
                        || path_b[lca_index].first_column != path_reasn[lca_index].first_column
                        || path_b[lca_index].last_lineno != path_reasn[lca_index].last_lineno
                        || path_b[lca_index].last_column != path_reasn[lca_index].last_column
                    {
                        break;
                    }
                    lca_index += 1;
                }
                let b_has_block = path_b[lca_index..]
                    .iter()
                    .any(|node| is_block_introducing(&node.r#type));
                let reasn_has_block = path_reasn[lca_index..]
                    .iter()
                    .any(|node| is_block_introducing(&node.r#type));
                if b_has_block && reasn_has_block {
                    continue;
                }
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

fn find_ancestors(node: &Node, target_span: Span, path: &mut Vec<Node>) -> bool {
    let node_span = [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ];
    path.push(node.clone());
    if node_span == target_span {
        return true;
    }
    for child in &node.children {
        if let Child::Node(child_node) = child {
            if find_ancestors(child_node, target_span, path) {
                return true;
            }
        }
    }
    path.pop();
    false
}

fn is_block_introducing(node_type: &str) -> bool {
    matches!(
        node_type,
        "ITER" | "LAMBDA" | "FOR" | "WHILE" | "UNTIL" | "ARROW_FUNCTION" | "FUNCTION_EXPRESSION"
    )
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
                { "index": 1, "line": 14, "end_line": 14, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(b)", "reads": ["b"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m2: MethodSummary = serde_json::from_value(json!({
            "id": "2", "owner": "T", "name": "m1", "file": "a.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 14, "end_line": 14, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(b)", "reads": ["b"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m3: MethodSummary = serde_json::from_value(json!({
            "id": "3", "owner": "T", "name": "m2", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(b)", "reads": ["b"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m4: MethodSummary = serde_json::from_value(json!({
            "id": "4", "owner": "T", "name": "m3", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "b = a", "reads": [], "writes": ["b"], "dependencies": [["b", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(b)", "reads": ["b"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m5: MethodSummary = serde_json::from_value(json!({
            "id": "5", "owner": "T", "name": "m4", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "c = a", "reads": [], "writes": ["c"], "dependencies": [["c", "a"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2", "reads": [], "writes": ["a"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(c)", "reads": ["c"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let m6: MethodSummary = serde_json::from_value(json!({
            "id": "6", "owner": "T", "name": "m5", "file": "b.rb", "line": 1, "span": [1,2,3,4],
            "statements": [
                { "index": 0, "line": 11, "end_line": 11, "span": [1,2,3,4], "source": "b = a; b = c", "reads": [], "writes": ["b"], "dependencies": [["b", "a"], ["b", "c"]], "co_uses": [] },
                { "index": 1, "line": 15, "end_line": 15, "span": [1,2,3,4], "source": "a = 2; c = 2", "reads": [], "writes": ["a", "c"], "dependencies": [], "co_uses": [] },
                { "index": 2, "line": 20, "end_line": 20, "span": [1,2,3,4], "source": "use(b)", "reads": ["b"], "writes": [], "dependencies": [], "co_uses": [] }
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

    #[test]
    fn test_derived_state_sibling_blocks() {
        let m_sibling: MethodSummary = serde_json::from_value(json!({
            "id": "7", "owner": "T", "name": "m_sibling", "file": "b.rb", "line": 1, "span": [1,0,30,0],
            "node": {
                "type": "DEFN",
                "first_lineno": 1, "first_column": 0, "last_lineno": 30, "last_column": 0,
                "text": "def m_sibling...",
                "children": [
                    {
                        "Node": {
                            "type": "ITER",
                            "first_lineno": 5, "first_column": 0, "last_lineno": 15, "last_column": 0,
                            "text": "declarations.each...",
                            "children": [
                                {
                                    "Node": {
                                        "type": "LASGN",
                                        "first_lineno": 10, "first_column": 0, "last_lineno": 10, "last_column": 0,
                                        "text": "bucket = candidate",
                                        "children": []
                                    }
                                }
                            ]
                        }
                    },
                    {
                        "Node": {
                            "type": "ITER",
                            "first_lineno": 20, "first_column": 0, "last_lineno": 28, "last_column": 0,
                            "text": "order.each...",
                            "children": [
                                {
                                    "Node": {
                                        "type": "LASGN",
                                        "first_lineno": 25, "first_column": 0, "last_lineno": 25, "last_column": 0,
                                        "text": "candidate = bucket",
                                        "children": []
                                    }
                                }
                            ]
                        }
                    }
                ]
            },
            "statements": [
                { "index": 0, "line": 10, "end_line": 10, "span": [10,0,10,0], "source": "bucket = candidate", "reads": [], "writes": ["bucket"], "dependencies": [["bucket", "candidate"]], "co_uses": [] },
                { "index": 1, "line": 25, "end_line": 25, "span": [25,0,25,0], "source": "candidate = bucket", "reads": [], "writes": ["candidate"], "dependencies": [["candidate", "bucket"]], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        let res = scan_summaries(&[m_sibling]);
        // BEFORE FIX: this will be 1 because 'bucket' on line 10 depends on 'candidate', which is reassigned on line 25
        // AFTER FIX: it must be 0 because they are in sibling ITER blocks
        assert_eq!(res.len(), 0);
    }

    #[test]
    fn test_derived_state_local_helper() {
        let m_local_helper: MethodSummary = serde_json::from_value(json!({
            "id": "8", "owner": "T", "name": "m_local_helper", "file": "c.rs", "line": 1, "span": [1,0,30,0],
            "statements": [
                {
                    "index": 0, "line": 5, "end_line": 15, "span": [5,0,15,0],
                    "source": "let target_commit = { let mut stmt = 1; stmt };",
                    "reads": [], "writes": ["target_commit", "stmt"],
                    "dependencies": [["target_commit", "stmt"]], "co_uses": []
                },
                {
                    "index": 1, "line": 20, "end_line": 20, "span": [20,0,20,0],
                    "source": "let mut stmt = 2;",
                    "reads": [], "writes": ["stmt"],
                    "dependencies": [], "co_uses": []
                },
                {
                    "index": 2, "line": 25, "end_line": 25, "span": [25,0,25,0],
                    "source": "use(target_commit);",
                    "reads": ["target_commit"], "writes": [],
                    "dependencies": [], "co_uses": []
                }
            ], "boundaries": []
        })).unwrap();

        let res = scan_summaries(&[m_local_helper]);
        assert_eq!(res.len(), 0);
    }

    #[test]
    fn test_derived_state_non_local_helper() {
        let m_non_local: MethodSummary = serde_json::from_value(json!({
            "id": "9", "owner": "T", "name": "m_non_local", "file": "d.rs", "line": 1, "span": [1,0,30,0],
            "statements": [
                {
                    "index": 0, "line": 2, "end_line": 2, "span": [2,0,2,0],
                    "source": "let mut stmt = 0;",
                    "reads": [], "writes": ["stmt"],
                    "dependencies": [], "co_uses": []
                },
                {
                    "index": 1, "line": 5, "end_line": 15, "span": [5,0,15,0],
                    "source": "let target_commit = { stmt = 1; stmt };",
                    "reads": [], "writes": ["target_commit", "stmt"],
                    "dependencies": [["target_commit", "stmt"]], "co_uses": []
                },
                {
                    "index": 2, "line": 20, "end_line": 20, "span": [20,0,20,0],
                    "source": "let mut stmt = 2;",
                    "reads": [], "writes": ["stmt"],
                    "dependencies": [], "co_uses": []
                },
                {
                    "index": 3, "line": 25, "end_line": 25, "span": [25,0,25,0],
                    "source": "use(target_commit);",
                    "reads": ["target_commit"], "writes": [],
                    "dependencies": [], "co_uses": []
                }
            ], "boundaries": []
        })).unwrap();

        let res = scan_summaries(&[m_non_local]);
        assert_eq!(res.len(), 1);
    }

    #[test]
    fn state_snapshot_restoration_is_not_staleness() {
        let method: MethodSummary = serde_json::from_value(json!({
            "id": "10", "owner": "T", "name": "with_state", "file": "state.rb", "line": 1, "span": [1,0,10,0],
            "statements": [
                { "index": 0, "line": 2, "end_line": 2, "span": [2,0,2,20], "source": "previous = @state", "reads": ["state"], "writes": ["previous"], "dependencies": [["previous", "state"]], "co_uses": [] },
                { "index": 1, "line": 3, "end_line": 3, "span": [3,0,3,20], "source": "@state = replacement", "reads": ["replacement"], "writes": ["state"], "dependencies": [["state", "replacement"]], "co_uses": [] },
                { "index": 2, "line": 5, "end_line": 5, "span": [5,0,5,20], "source": "@state = previous", "reads": ["previous"], "writes": ["state"], "dependencies": [["state", "previous"]], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        assert!(
            scan_summaries(&[method]).is_empty(),
            "save/mutate/restore is a scoped state guard, not a stale derived value"
        );
    }

    #[test]
    fn derived_guard_driving_normalization_is_not_staleness() {
        let method: MethodSummary = serde_json::from_value(json!({
            "id": "11", "owner": "T", "name": "normalize", "file": "state.rb", "line": 1, "span": [1,0,10,0],
            "statements": [
                { "index": 0, "line": 2, "end_line": 2, "span": [2,0,2,30], "source": "wrapped = state.optional?", "reads": ["state"], "writes": ["wrapped"], "dependencies": [["wrapped", "state"]], "co_uses": [] },
                { "index": 1, "line": 3, "end_line": 3, "span": [3,0,3,35], "source": "state = unwrap(state) if wrapped", "reads": ["state", "wrapped"], "writes": ["state"], "dependencies": [["state", "state"]], "co_uses": [] },
                { "index": 2, "line": 4, "end_line": 4, "span": [4,0,4,20], "source": "use(wrapped)", "reads": ["wrapped"], "writes": [], "dependencies": [], "co_uses": [] }
            ], "boundaries": []
        })).unwrap();

        assert!(
            scan_summaries(&[method]).is_empty(),
            "a predicate that controls source normalization is intentionally retained"
        );
    }
}
