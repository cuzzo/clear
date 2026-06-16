pub mod ruby;

use crate::decomplex::ast::{RawNode, Span};
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Language {
    Ruby,
}

impl Language {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "ruby" => Ok(Self::Ruby),
            _ => bail!("unsupported Decomplex native language: {value}"),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Document {
    pub file: String,
    pub language: Language,
    pub source: String,
    pub lines: Vec<String>,
    pub root: RawNode,
    pub function_defs: Vec<FunctionDef>,
    pub state_writes: Vec<StateWrite>,
    pub predicate_aliases: Vec<PredicateAlias>,
}

#[derive(Clone, Debug)]
pub struct FunctionDef {
    pub file: String,
    pub name: String,
    pub owner: String,
    pub line: usize,
    pub span: Span,
    pub body: RawNode,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StateWrite {
    pub field: String,
    pub receiver: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub owner: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PredicateAlias {
    pub name: String,
    pub body: String,
    pub file: String,
    pub defn: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SimilarityFinding {
    pub at: String,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
    pub clone_type: String,
    pub node: String,
    pub mass: usize,
    pub locations: Vec<String>,
}

pub fn parse_file(file: PathBuf, language: Language) -> Result<Document> {
    match language {
        Language::Ruby => ruby::parse_file(file),
    }
}

pub fn parse_files(files: &[PathBuf], language: Language) -> Result<Vec<Document>> {
    files
        .iter()
        .map(|file| parse_file(file.clone(), language))
        .collect()
}
