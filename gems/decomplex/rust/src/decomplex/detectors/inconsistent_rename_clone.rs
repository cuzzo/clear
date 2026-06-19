use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

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
    MID,
    CALL,
    FCALL,
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

const HOLE_TYPES: &[&str] = &["LVAR", "DVAR", "IVAR", "LASGN", "DASGN", "IASGN"];
const MIN_TOKENS: usize = 8;

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<InconsistentRenameCloneRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<InconsistentRenameCloneRow> {
    let mut blocks = Vec::new();
    for document in documents {
        let detector = InconsistentRenameClone::new(document.file.clone());
        detector.collect(&document.normalized_root, &Vec::new(), &mut blocks);
    }
    Report::new(blocks).inconsistent_renames()
}

struct InconsistentRenameClone {
    file: String,
}

impl InconsistentRenameClone {
    fn new(file: String) -> Self {
        Self { file }
    }

    fn collect(&self, node: &Node, defstack: &[String], blocks: &mut Vec<Block>) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        if node.r#type == "BLOCK" {
            let stmts: Vec<_> = node.children.iter().filter_map(ast::node).collect();
            if stmts.len() >= 3 {
                self.add_block(&stmts, &next_defstack, blocks);
            }
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.collect(child, &next_defstack, blocks);
        }
    }

    fn add_block(&self, stmts: &[&Node], defstack: &[String], blocks: &mut Vec<Block>) {
        let mut skeleton = Vec::new();
        let mut names = Vec::new();
        for stmt in stmts {
            self.tokenize(stmt, &mut skeleton, &mut names);
        }
        if skeleton.len() < MIN_TOKENS {
            return;
        }

        blocks.push(Block {
            skeleton,
            names,
            file: self.file.clone(),
            defn: defstack
                .last()
                .cloned()
                .unwrap_or_else(|| "(top-level)".to_string()),
            line: stmts[0].first_lineno,
            span: [
                stmts[0].first_lineno,
                stmts[0].first_column,
                stmts.last().unwrap().last_lineno,
                stmts.last().unwrap().last_column,
            ],
        });
    }

    fn tokenize(&self, node: &Node, skeleton: &mut Vec<Skeleton>, names: &mut Vec<String>) {
        match node.r#type.as_str() {
            t if HOLE_TYPES.contains(&t) => {
                skeleton.push(Skeleton::ID);
                if let Some(Child::String(name)) = node.children.first() {
                    names.push(name.clone());
                }
            }
            "VCALL" => {
                skeleton.push(Skeleton::ID);
                if let Some(Child::Symbol(name)) = node.children.first() {
                    names.push(name.clone());
                }
            }
            "CALL" | "FCALL" => {
                skeleton.push(if node.r#type == "CALL" {
                    Skeleton::CALL
                } else {
                    Skeleton::FCALL
                });
                let mid_index = if node.r#type == "CALL" { 1 } else { 0 };
                skeleton.push(Skeleton::MID);
                if let Some(Child::Symbol(mid)) = node.children.get(mid_index) {
                    names.push(mid.clone());
                }
            }
            "LIT" | "STR" | "SYM" | "INTEGER" | "FLOAT" => {
                skeleton.push(Skeleton::Node(node.r#type.clone()));
            }
            _ => {
                skeleton.push(Skeleton::Node(node.r#type.clone()));
            }
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.tokenize(child, skeleton, names);
        }
    }
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
                out.extend(self.inconsistent_pairs(candidate, ref_block));
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
            let mut spellings = BTreeSet::new();
            for pos in positions {
                if let Some(name) = candidate.names.get(pos) {
                    spellings.insert(name.clone());
                }
            }
            if spellings.len() < 2 {
                continue;
            }
            out.push(self.finding(
                ref_block,
                candidate,
                &ref_name,
                spellings.into_iter().collect(),
            ));
        }
        out
    }

    fn ref_classes(&self, ref_block: &Block) -> BTreeMap<String, Vec<usize>> {
        let mut classes: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (index, name) in ref_block.names.iter().enumerate() {
            classes.entry(name.clone()).or_default().push(index);
        }
        classes.retain(|_, v| v.len() >= 2);
        classes
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
