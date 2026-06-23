use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::OnceLock;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct InconsistentRenameCloneRow {
    pub file: String,
    pub defn: String,
    pub line: usize,
    pub at: String,
    pub ref_at: String,
    pub spans: BTreeMap<String, Span>,
    pub ref_name: String,
    pub divergent: Vec<String>,
    pub clone_size: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
enum Skeleton {
    ID,
    Node(String),
}

#[derive(Clone, Debug)]
struct Block {
    skeleton: Vec<Skeleton>,
    names: Vec<String>,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

const MIN_TOKENS: usize = 8;

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<InconsistentRenameCloneRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<InconsistentRenameCloneRow> {
    let summaries = local_flow::scan_documents(documents);
    scan_summaries(&summaries)
}

pub fn scan_summaries(summaries: &[local_flow::MethodSummary]) -> Vec<InconsistentRenameCloneRow> {
    let blocks = summaries
        .iter()
        .filter_map(block_from_method)
        .collect::<Vec<_>>();
    Report::new(blocks).inconsistent_renames()
}

fn block_from_method(method: &local_flow::MethodSummary) -> Option<Block> {
    if method.statements.len() < 3 {
        return None;
    }
    let dialect = crate::decomplex::dialect::dialect_for_method(method);

    let mut skeleton = Vec::new();
    let mut names = Vec::new();
    for statement in &method.statements {
        tokenize_source(&statement.source, &mut skeleton, &mut names, &*dialect);
    }
    if skeleton.len() < MIN_TOKENS {
        return None;
    }

    let first = method.statements.first()?;
    let last = method.statements.last()?;
    Some(Block {
        skeleton,
        names,
        file: method.file.clone(),
        defn: method.name.clone(),
        line: first.line,
        span: [first.span[0], first.span[1], last.span[2], last.span[3]],
    })
}

fn tokenize_source(source: &str, skeleton: &mut Vec<Skeleton>, names: &mut Vec<String>, dialect: &dyn crate::decomplex::dialect::Dialect) {
    for token in token_re().find_iter(source).map(|match_| match_.as_str()) {
        if dialect.is_identifier(token) {
            skeleton.push(Skeleton::ID);
            names.push(
                dialect.clean_identifier(token)
            );
        } else if literal_token(token) {
            skeleton.push(Skeleton::Node("LIT".to_string()));
        } else {
            skeleton.push(Skeleton::Node(token.to_string()));
        }
    }
}

fn token_re() -> &'static Regex {
    static TOKEN_RE: OnceLock<Regex> = OnceLock::new();
    TOKEN_RE.get_or_init(|| {
        Regex::new(r#"[A-Za-z_]\w*[!?=]?|@\w+|\d+(?:\.\d+)?|:[A-Za-z_]\w*|"[^"]*"|'[^']*'|\S"#)
            .expect("inconsistent-rename-clone token regex")
    })
}

fn literal_token(token: &str) -> bool {
    token.starts_with(':') || quoted_token(token) || numeric_token(token)
}

fn quoted_token(token: &str) -> bool {
    (token.starts_with('"') && token.ends_with('"'))
        || (token.starts_with('\'') && token.ends_with('\''))
}

fn numeric_token(token: &str) -> bool {
    let mut saw_digit = false;
    let mut saw_dot = false;
    for ch in token.chars() {
        if ch.is_ascii_digit() {
            saw_digit = true;
        } else if ch == '.' && !saw_dot {
            saw_dot = true;
        } else {
            return false;
        }
    }
    saw_digit
}

struct Report {
    groups: BTreeMap<Vec<Skeleton>, Vec<Block>>,
}

impl Report {
    fn new(blocks: Vec<Block>) -> Self {
        let mut groups: BTreeMap<Vec<Skeleton>, Vec<Block>> = BTreeMap::new();
        for b in blocks {
            groups.entry(b.skeleton.clone()).or_default().push(b);
        }
        groups.retain(|_, v| v.len() >= 2);
        Self { groups }
    }

    fn inconsistent_renames(&self) -> Vec<InconsistentRenameCloneRow> {
        let mut out = Vec::new();
        for members in self.groups.values() {
            out.extend(self.findings_for(members));
        }
        out.sort_by(|a, b| {
            b.clone_size
                .cmp(&a.clone_size)
                .then_with(|| a.at.cmp(&b.at))
        });
        out.dedup_by(|a, b| a.at == b.at && a.ref_at == b.ref_at && a.ref_name == b.ref_name);
        out
    }

    fn findings_for(&self, members: &[Block]) -> Vec<InconsistentRenameCloneRow> {
        let mut units = BTreeSet::new();
        for m in members {
            units.insert((m.file.clone(), m.defn.clone()));
        }
        if units.len() < 2 {
            return Vec::new();
        }

        let mut out = Vec::new();
        for i in 0..members.len() {
            for j in i + 1..members.len() {
                let ref_block = &members[i];
                let candidate = &members[j];
                if self.same_unit(ref_block, candidate) {
                    continue;
                }
                out.extend(self.inconsistent_pairs(ref_block, candidate));
            }
        }
        out
    }

    fn inconsistent_pairs(
        &self,
        ref_block: &Block,
        candidate: &Block,
    ) -> Vec<InconsistentRenameCloneRow> {
        let mut out = Vec::new();
        for (ref_name, positions) in self.ref_classes(ref_block) {
            let mut spellings = Vec::new();
            for pos in positions {
                if let Some(name) = candidate.names.get(pos) {
                    if !spellings.contains(name) {
                        spellings.push(name.clone());
                    }
                }
            }
            if spellings.len() < 2 {
                continue;
            }
            out.push(self.finding(ref_block, candidate, &ref_name, spellings));
        }
        out
    }

    fn ref_classes(&self, ref_block: &Block) -> Vec<(String, Vec<usize>)> {
        let mut order = Vec::new();
        let mut classes: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (index, name) in ref_block.names.iter().enumerate() {
            if !classes.contains_key(name) {
                order.push(name.clone());
            }
            classes.entry(name.clone()).or_default().push(index);
        }
        order
            .into_iter()
            .filter_map(|name| {
                let positions = classes.remove(&name)?;
                (positions.len() >= 2).then_some((name, positions))
            })
            .collect()
    }

    fn same_unit(&self, left: &Block, right: &Block) -> bool {
        left.file == right.file && left.defn == right.defn
    }

    fn finding(
        &self,
        ref_block: &Block,
        candidate: &Block,
        ref_name: &str,
        divergent: Vec<String>,
    ) -> InconsistentRenameCloneRow {
        let at = format!("{}:{}:{}", candidate.file, candidate.defn, candidate.line);
        let ref_at = format!("{}:{}:{}", ref_block.file, ref_block.defn, ref_block.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), candidate.span);
        spans.insert(ref_at.clone(), ref_block.span);
        InconsistentRenameCloneRow {
            file: candidate.file.clone(),
            defn: candidate.defn.clone(),
            line: candidate.line,
            at,
            ref_at,
            spans,
            ref_name: ref_name.to_string(),
            divergent,
            clone_size: 2,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_inconsistent_rename_clone_gaps() {
        // 1. Test short statements (line 64) and short tokens (line 74)
        // Also tests numeric_token with dot (lines 128-129) via "1.5"
        let doc_short: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "local_methods": [
                {
                    "id": "m1", "owner": "Class", "name": "short_statements", "file": "foo.rb", "line": 1, "span": [1, 1, 3, 1],
                    "statements": [
                        { "index": 0, "line": 1, "end_line": 1, "span": [1, 1, 1, 10], "source": "a = 1", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 2, "end_line": 2, "span": [2, 1, 2, 10], "source": "b = 1.5", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                },
                {
                    "id": "m2", "owner": "Class", "name": "short_tokens", "file": "foo.rb", "line": 5, "span": [5, 1, 8, 1],
                    "statements": [
                        { "index": 0, "line": 5, "end_line": 5, "span": [5, 1, 5, 10], "source": "a = 1", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 6, "end_line": 6, "span": [6, 1, 6, 10], "source": "b = 2", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 2, "line": 7, "end_line": 7, "span": [7, 1, 7, 10], "source": "c = 3", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc_short]);
        assert!(report.is_empty());

        // 2. Test clone/same_unit/spellings and sorting (lines 156-159, 170, 179, 203)
        let doc_main: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "local_methods": [
                {
                    "id": "m_ref", "owner": "Class", "name": "ref_method", "file": "foo.rb", "line": 10, "span": [10, 1, 14, 1],
                    "statements": [
                        { "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 11, "end_line": 11, "span": [11, 1, 11, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 2, "line": 12, "end_line": 12, "span": [12, 1, 12, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                },
                {
                    "id": "m_cand", "owner": "Class", "name": "cand_method", "file": "foo.rb", "line": 20, "span": [20, 1, 24, 1],
                    "statements": [
                        { "index": 0, "line": 20, "end_line": 20, "span": [20, 1, 20, 10], "source": "b = b", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 21, "end_line": 21, "span": [21, 1, 21, 10], "source": "b = c", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 2, "line": 22, "end_line": 22, "span": [22, 1, 22, 10], "source": "b = b", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                },
                // An exact clone of ref_method (consistent rename -> spells.len() < 2 -> skipped)
                {
                    "id": "m_exact", "owner": "Class", "name": "exact_method", "file": "foo.rb", "line": 30, "span": [30, 1, 34, 1],
                    "statements": [
                        { "index": 0, "line": 30, "end_line": 30, "span": [30, 1, 30, 10], "source": "x = x", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 31, "end_line": 31, "span": [31, 1, 31, 10], "source": "x = x", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 2, "line": 32, "end_line": 32, "span": [32, 1, 32, 10], "source": "x = x", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                },
                // Another copy of ref_method in the same unit (ref_method) to test same_unit skip (line 179)
                {
                    "id": "m_same_unit", "owner": "Class", "name": "ref_method", "file": "foo.rb", "line": 40, "span": [40, 1, 44, 1],
                    "statements": [
                        { "index": 0, "line": 40, "end_line": 40, "span": [40, 1, 40, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 1, "line": 41, "end_line": 41, "span": [41, 1, 41, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] },
                        { "index": 2, "line": 42, "end_line": 42, "span": [42, 1, 42, 10], "source": "a = a", "reads": [], "writes": [], "dependencies": [], "co_uses": [] }
                    ],
                    "boundaries": []
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc_main]);
        // ref_method and exact_method are consistent.
        // ref_method and cand_method have divergent spelling ("b" and "c").
        // exact_method and cand_method have divergent spelling ("b" and "c").
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].ref_name, "a");
        assert_eq!(report[0].divergent, vec!["b", "c"]);
    }
}
