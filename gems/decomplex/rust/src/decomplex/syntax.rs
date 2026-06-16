pub mod ruby;

use crate::decomplex::ast::{RawNode, Span};
use crate::decomplex::parallel;
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
    pub decision_sites: Vec<DecisionSite>,
    pub predicate_aliases: Vec<PredicateAlias>,
    pub comparison_uses: Vec<ComparisonUse>,
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
pub struct DecisionSite {
    pub kind: String,
    pub members: Vec<String>,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub predicate: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ComparisonUse {
    pub canon_source: String,
    pub raw: String,
    pub file: String,
    pub function: String,
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
    parallel::map_ordered(files, |file| parse_file(file.clone(), language))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decomplex::parallel;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn parallel_parse_files_preserves_input_order() {
        parallel::set_jobs_for_process(Some(4)).expect("jobs");
        let mut first = NamedTempFile::new().expect("first");
        let mut second = NamedTempFile::new().expect("second");
        first
            .write_all(b"def first\n  1\nend\n")
            .expect("write first");
        second
            .write_all(b"def second\n  2\nend\n")
            .expect("write second");

        let files = vec![first.path().to_path_buf(), second.path().to_path_buf()];
        let docs = parse_files(&files, Language::Ruby).expect("parse files");

        assert_eq!(docs.len(), 2);
        assert_eq!(docs[0].file, first.path().to_string_lossy());
        assert_eq!(docs[1].file, second.path().to_string_lossy());
        assert_eq!(docs[0].function_defs[0].name, "first");
        assert_eq!(docs[1].function_defs[0].name, "second");
    }
}
