use crate::decomplex::ast::Span;
use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{self, Document, Language};
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
    let blocks = local_flow::scan_documents(documents)
        .into_iter()
        .filter_map(|method| block_from_method(&method))
        .collect::<Vec<_>>();
    Report::new(blocks).inconsistent_renames()
}

fn block_from_method(method: &local_flow::MethodSummary) -> Option<Block> {
    if method.statements.len() < 3 {
        return None;
    }
    let mut skeleton = Vec::new();
    let mut names = Vec::new();
    for statement in &method.statements {
        tokenize_source(&statement.source, &mut skeleton, &mut names);
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

fn tokenize_source(source: &str, skeleton: &mut Vec<Skeleton>, names: &mut Vec<String>) {
    for token in token_re().find_iter(source).map(|match_| match_.as_str()) {
        if identifier_token(token) {
            skeleton.push(Skeleton::ID);
            names.push(
                token
                    .trim_start_matches('@')
                    .trim_end_matches('=')
                    .to_string(),
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

fn identifier_token(token: &str) -> bool {
    let token = token.strip_prefix('@').unwrap_or(token);
    let token = token.trim_end_matches(['!', '?', '=']);
    let mut chars = token.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
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
