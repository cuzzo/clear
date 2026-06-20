pub(crate) mod adapters;
pub(crate) mod complexity;
pub mod tree_sitter_adapter;

use crate::decomplex::ast::{Node as NormalizedNode, RawNode, Span};
use crate::decomplex::parallel;
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Language {
    Ruby,
    Python,
    JavaScript,
    Java,
    TypeScript,
    Swift,
    Kotlin,
    Go,
    Rust,
    Zig,
    Lua,
    C,
    Cpp,
    CSharp,
    Php,
}

impl Language {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "ruby" => Ok(Self::Ruby),
            "python" => Ok(Self::Python),
            "javascript" => Ok(Self::JavaScript),
            "java" => Ok(Self::Java),
            "typescript" => Ok(Self::TypeScript),
            "swift" => Ok(Self::Swift),
            "kotlin" => Ok(Self::Kotlin),
            "go" => Ok(Self::Go),
            "rust" => Ok(Self::Rust),
            "zig" => Ok(Self::Zig),
            "lua" => Ok(Self::Lua),
            "c" => Ok(Self::C),
            "cpp" => Ok(Self::Cpp),
            "csharp" => Ok(Self::CSharp),
            "php" => Ok(Self::Php),
            _ => bail!("unsupported Decomplex native language: {value}"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ruby => "ruby",
            Self::Python => "python",
            Self::JavaScript => "javascript",
            Self::Java => "java",
            Self::TypeScript => "typescript",
            Self::Swift => "swift",
            Self::Kotlin => "kotlin",
            Self::Go => "go",
            Self::Rust => "rust",
            Self::Zig => "zig",
            Self::Lua => "lua",
            Self::C => "c",
            Self::Cpp => "cpp",
            Self::CSharp => "csharp",
            Self::Php => "php",
        }
    }

    pub fn for_extension(extension: &str) -> Option<Self> {
        match extension {
            "rb" => Some(Self::Ruby),
            "py" => Some(Self::Python),
            "js" | "jsx" | "mjs" | "cjs" => Some(Self::JavaScript),
            "java" => Some(Self::Java),
            "ts" | "tsx" => Some(Self::TypeScript),
            "swift" => Some(Self::Swift),
            "kt" | "kts" => Some(Self::Kotlin),
            "go" => Some(Self::Go),
            "rs" => Some(Self::Rust),
            "zig" => Some(Self::Zig),
            "lua" => Some(Self::Lua),
            "c" | "h" => Some(Self::C),
            "cpp" | "cc" | "cxx" | "hpp" | "hh" | "hxx" => Some(Self::Cpp),
            "cs" => Some(Self::CSharp),
            "php" => Some(Self::Php),
            _ => None,
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
    pub normalized_root: NormalizedNode,
    pub function_defs: Vec<FunctionDef>,
    pub owner_defs: Vec<OwnerDef>,
    pub call_sites: Vec<CallSite>,
    pub state_reads: Vec<StateRead>,
    pub state_writes: Vec<StateWrite>,
    pub decision_sites: Vec<DecisionSite>,
    pub branch_decisions: Vec<BranchDecision>,
    pub dispatch_sites: Vec<DispatchSite>,
    pub semantic_effect_sites: Vec<SemanticEffectSite>,
    pub local_complexity_scores: BTreeMap<String, LocalComplexityScore>,
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
    pub visibility: Option<String>,
    pub params: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct OwnerDef {
    pub file: String,
    pub name: String,
    pub kind: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CallSite {
    pub receiver: String,
    pub message: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub line: usize,
    pub span: Span,
    pub conditional: bool,
    pub arguments: Vec<String>,
    pub control: Option<String>,
    pub safe_navigation: bool,
    pub block: bool,
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
pub struct StateRead {
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
    pub enclosing_span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct BranchDecision {
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub predicate: String,
    pub state_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DispatchSite {
    pub variant_set: Vec<String>,
    pub arm_members: BTreeMap<String, Vec<String>>,
    pub outside: Vec<String>,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SemanticEffectSite {
    pub kind: String,
    pub detail: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct LocalComplexityScore {
    pub score: f64,
    pub signals: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ComparisonUse {
    pub canon_source: String,
    pub raw: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub enclosing_span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct CloneCandidate {
    pub(crate) file: String,
    pub(crate) line: usize,
    pub(crate) span: Span,
    pub(crate) method_name: String,
    pub(crate) node_name: String,
    pub(crate) mass: usize,
    pub(crate) fingerprint: String,
    pub(crate) raw: String,
    pub(crate) child_fingerprints: Vec<String>,
    pub(crate) child_masses: Vec<usize>,
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
    tree_sitter_adapter::parse_file(file, language)
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

    fn document(source: &str, language: Language) -> Document {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        parse_file(file.path().to_path_buf(), language).expect("parse file")
    }

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

    #[test]
    fn parses_java_kotlin_and_swift_function_defs() {
        let cases = [
            (
                Language::Java,
                "class Billing { int mixed(int price, int tax) { return price + tax; } }",
            ),
            (
                Language::Kotlin,
                "class Billing { fun mixed(price: Int, tax: Int): Int { return price + tax } }",
            ),
            (
                Language::Swift,
                "class Billing { func mixed(price: Int, tax: Int) -> Int { return price + tax } }",
            ),
        ];

        for (language, source) in cases {
            let doc = document(source, language);
            let function = doc
                .function_defs
                .iter()
                .find(|function| function.name == "mixed")
                .expect("mixed function");

            assert_eq!(function.owner, "Billing");
        }
    }
}
