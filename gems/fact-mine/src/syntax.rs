pub(crate) mod c;
pub mod cfg;
pub(crate) mod clone_similarity;
pub(crate) mod complexity;
pub(crate) mod complexity_facts;
pub(crate) mod cpp;
pub(crate) mod csharp;
pub(crate) mod effects;
pub(crate) mod go;
pub(crate) mod hazards;
pub(crate) mod imports;
pub(crate) mod java;
pub(crate) mod javascript;
pub(crate) mod kotlin;
pub mod local_flow;
pub(crate) mod lua;
pub(crate) mod normalized_behavior;
pub(crate) mod normalized_extractor;
pub(crate) mod parser_grammar;
pub(crate) mod passes;
pub mod path_condition;
pub(crate) mod php;
pub(crate) mod protocols;
pub(crate) mod python;
pub mod redundant_nil_guard;
pub(crate) mod ruby;
pub(crate) mod rust;
pub(crate) mod swift;
pub(crate) mod tree_sitter_adapter;
pub(crate) mod typescript;
pub(crate) mod visibility;
pub(crate) mod zig;

use crate::ast::RawNode;
pub use crate::ast::{Child, Node, Span};
use crate::parallel;
use anyhow::{bail, Result};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// Map a compiler-proven external symbol through the owning language's
/// reviewed complexity registry. Symbol parsing stays at the adapter boundary;
/// the SCIP importer and downstream analyzers remain language-neutral.
pub(crate) struct ExternalCallComplexity {
    pub time: &'static str,
    pub space: &'static str,
    pub provenance: &'static str,
    pub bound_quality: &'static str,
    pub candidates: Vec<String>,
    pub assumption: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ExternalSymbolMetadata {
    pub scope: &'static str,
    pub missing_cost_kind: String,
    pub parametric_cost: Option<String>,
}

pub(crate) fn external_symbol_call_complexity(
    language: &str,
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let language = Language::parse(language).ok()?;
    normalized_behavior::behavior(language).external_symbol_call_complexity(symbol, message)
}

/// Classify an exact external symbol at the language boundary. Shared SCIP
/// ingestion and diagnostics consume only these normalized values.
pub(crate) fn external_symbol_metadata(language: &str, symbol: &str) -> ExternalSymbolMetadata {
    Language::parse(language)
        .ok()
        .map(normalized_behavior::behavior)
        .map(|behavior| behavior.external_symbol_metadata(symbol))
        .unwrap_or(ExternalSymbolMetadata {
            scope: "external",
            missing_cost_kind: "external_cost_model_missing".to_string(),
            parametric_cost: None,
        })
}

pub(crate) fn external_symbol_owner(language: &str, symbol: &str) -> Option<String> {
    Language::parse(language)
        .ok()
        .and_then(|language| normalized_behavior::behavior(language).external_symbol_owner(symbol))
}

/// Whether a compiler symbol without callable descriptor punctuation denotes
/// a source-language access that can execute user code. This is intentionally
/// language-owned: C# properties dispatch through accessors, while an
/// identically shaped field symbol in most languages is only data projection.
pub(crate) fn scip_noncall_access_is_callable(language: &str, symbol: &str) -> bool {
    Language::parse(language)
        .map(|language| {
            normalized_behavior::behavior(language).scip_noncall_access_is_callable(symbol)
        })
        .unwrap_or(false)
}

/// Shared algebra for calls whose target identity is proven but whose cost is
/// parameterized by callback/implementation work.
pub(crate) fn parametric_call_complexity(kind: &str) -> Option<(&'static str, &'static str)> {
    match kind {
        "callback_once" => Some(("O(C)", "O(S)")),
        "callback_linear" => Some(("O(N*C)", "O(N*S)")),
        "callback_sort" => Some(("O(N log N*C)", "O(N+S)")),
        "reflective_once" => Some(("O(R)", "O(S)")),
        _ => None,
    }
}

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
            _ => bail!("unsupported FactMine native language: {value}"),
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
            "py" | "pyi" => Some(Self::Python),
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

    /// Detect a source language from a path. `.h` is the one ambiguous common
    /// extension: keep C as the conservative extension default, but recognize
    /// unmistakable C++ syntax before choosing a grammar. This belongs at the
    /// source-adapter boundary so every downstream consumer receives one
    /// correctly normalized language, rather than teaching analyzers about
    /// headers or repository conventions.
    pub fn for_path(path: &Path) -> Option<Self> {
        let extension = path.extension()?.to_str()?.to_ascii_lowercase();
        if extension != "h" {
            return Self::for_extension(&extension);
        }
        let source = std::fs::read_to_string(path).ok()?;
        Some(if looks_like_cpp_header(&source) {
            Self::Cpp
        } else {
            Self::C
        })
    }
}

fn looks_like_cpp_header(source: &str) -> bool {
    [
        "namespace ",
        "template <",
        "typename ",
        "constexpr ",
        "std::",
        "class ",
    ]
    .iter()
    .any(|marker| source.contains(marker))
}

impl<'de> Deserialize<'de> for Language {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct Document {
    pub file: String,
    pub language: Language,
    #[serde(default)]
    pub source_digest: String,
    #[serde(default)]
    pub raw_call_spans: Vec<Span>,
    #[serde(default)]
    pub symbol_scope: SymbolScope,
    #[serde(default)]
    pub function_defs: Vec<FunctionDef>,
    #[serde(default)]
    pub owner_defs: Vec<OwnerDef>,
    #[serde(default)]
    pub call_sites: Vec<CallSite>,
    #[serde(default)]
    pub call_receiver_projections: Vec<CallReceiverProjection>,
    #[serde(default)]
    pub state_declarations: Vec<StateDeclaration>,
    #[serde(default)]
    pub state_reads: Vec<StateRead>,
    #[serde(default)]
    pub state_writes: Vec<StateWrite>,
    #[serde(default)]
    pub decision_sites: Vec<DecisionSite>,
    #[serde(default)]
    pub branch_decisions: Vec<BranchDecision>,
    #[serde(default)]
    pub branch_arms: Vec<BranchArm>,
    #[serde(default)]
    pub dispatch_sites: Vec<DispatchSite>,
    #[serde(default)]
    pub semantic_effect_sites: Vec<SemanticEffectSite>,
    #[serde(default)]
    pub local_complexity_scores: BTreeMap<String, LocalComplexityScore>,
    #[serde(default)]
    pub local_methods: Vec<local_flow::MethodSummary>,
    #[serde(default)]
    pub predicate_aliases: Vec<PredicateAlias>,
    #[serde(default)]
    pub comparison_uses: Vec<ComparisonUse>,
    #[serde(default)]
    pub path_condition_sites: Vec<PathConditionSite>,
    #[serde(default)]
    pub control_flow_nodes: Vec<cfg::ControlFlowNode>,
    #[serde(default)]
    pub control_flow_edges: Vec<cfg::ControlFlowEdge>,
    #[serde(default)]
    pub control_flow_metrics: Vec<cfg::ControlFlowMetric>,
    #[serde(default)]
    pub places: Vec<cfg::Place>,
    #[serde(default)]
    pub node_effects: Vec<cfg::NodeEffect>,
    #[serde(default)]
    pub reachability: Vec<cfg::ReachabilityFact>,
    #[serde(default)]
    pub dominators: Vec<cfg::DominatorFact>,
    #[serde(default)]
    pub reaching_definitions: Vec<cfg::ReachingDefinitionFact>,
    #[serde(default)]
    pub def_use: Vec<cfg::DefUseFact>,
    #[serde(default)]
    pub liveness: Vec<cfg::LivenessFact>,
    #[serde(default)]
    pub flow_types: Vec<cfg::FlowTypeFact>,
    #[serde(default)]
    pub protocol_method_effects: Vec<ProtocolMethodEffect>,
    #[serde(default)]
    pub protocol_call_paths: Vec<ProtocolMethodPath>,
    #[serde(default)]
    pub(crate) clone_candidates: Vec<CloneCandidate>,
    #[serde(default)]
    pub redundant_nil_guards: Vec<redundant_nil_guard::RedundantNilGuardRow>,
    #[serde(default)]
    pub immutable_struct_readers: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub type_aliases: BTreeMap<String, String>,
    #[serde(default)]
    pub type_alias_lines: BTreeMap<String, usize>,
    #[serde(default)]
    pub method_param_types: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub method_local_types: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub state_param_origins: Vec<StateParamOrigin>,
    #[serde(default)]
    pub hazard_sites: Vec<HazardSite>,
    #[serde(default)]
    pub imports: Vec<imports::ImportFact>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HazardSite {
    pub path: String,
    pub line: u32,
    #[serde(rename = "source")]
    pub snippet: String,
    pub hazard_type: String,
    pub required_evidence: String,
    #[serde(default)]
    pub provider: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_column: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_column: Option<u32>,
}

/// Minimal, adapter-proven facts needed to canonicalize source symbols.
/// Consumers must leave cross-file targets unknown when these facts do not
/// establish an identity.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SymbolScope {
    pub canonical: bool,
    #[serde(default)]
    pub unqualified_types_use_current_namespace: bool,
    pub namespace: String,
    pub explicit_imports: BTreeMap<String, String>,
    #[serde(default)]
    pub preprocessor_callables: BTreeSet<String>,
    /// Language-owned namespace enclosing a particular declaration span.
    /// File-level namespaces are insufficient for languages such as C++
    /// where one translation unit may contain several namespace blocks.
    #[serde(default)]
    pub declaration_namespaces: BTreeMap<Span, String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct FunctionDef {
    pub file: String,
    pub name: String,
    pub owner: String,
    /// Adapter-proven dispatch domain. This is syntax knowledge: the generic
    /// profile must not infer static/free/instance semantics from owner text.
    #[serde(default)]
    pub dispatch_kind: String,
    pub line: usize,
    pub span: Span,
    pub(crate) body: RawNode,
    pub visibility: Option<String>,
    pub params: Vec<String>,
    #[serde(default)]
    pub callback_params: Vec<String>,
    #[serde(default)]
    pub signature: String,
}

impl FunctionDef {
    /// A definition synthesized from a declaration macro (e.g. Ruby attr_*).
    /// Lives here so passes never construct parser-internal body nodes.
    pub(crate) fn synthetic_accessor(
        file: String,
        name: String,
        owner: String,
        line: usize,
        span: Span,
        params: Vec<String>,
    ) -> Self {
        Self {
            file,
            name,
            owner,
            dispatch_kind: "instance".to_string(),
            line,
            span,
            body: RawNode {
                kind: "SYNTHETIC_ACCESSOR".to_string(),
                text: String::new(),
                span,
                named: false,
                field_name: None,
                children: Vec::new(),
            },
            visibility: Some("public".to_string()),
            params,
            callback_params: Vec::new(),
            signature: String::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct OwnerDef {
    pub file: String,
    pub name: String,
    pub kind: String,
    /// Normalized language fact: this declaration may reopen/extend another
    /// declaration with the same name.
    #[serde(default)]
    pub reopenable: bool,
    /// Language-adapter extracted direct base classes, interfaces, or promoted
    /// owner types. These are native spellings; project merge canonicalizes
    /// them before any hierarchy traversal.
    #[serde(default)]
    pub supertypes: Vec<String>,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

/// Structural identity for a direct call used as another call's receiver.
/// The normalizer emits spans rather than reconstructing receiver source text.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CallReceiverProjection {
    pub outer_span: Span,
    pub receiver_call_span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct StateDeclaration {
    pub field: String,
    pub owner: String,
    pub r#type: Option<String>,
    #[serde(default)]
    pub immutable: bool,
    pub file: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct StateWrite {
    pub field: String,
    /// Canonical owner-qualified identity when the language can prove that a
    /// bare field spelling is not globally unique.
    #[serde(default)]
    pub identity: String,
    pub receiver: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub owner: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct StateRead {
    pub field: String,
    /// Canonical owner-qualified identity when the language can prove that a
    /// bare field spelling is not globally unique.
    #[serde(default)]
    pub identity: String,
    pub receiver: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub owner: String,
}

pub fn receiver_targets_owner(receiver: &str, owner: &str) -> bool {
    // Language adapters normalize an explicit owner receiver to `self`.
    // Source-language spellings must not leak into this shared predicate.
    receiver == "self" || (!owner.is_empty() && receiver == owner)
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct StateParamOrigin {
    pub field: String,
    pub receiver: String,
    pub owner: String,
    pub param: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PredicateAlias {
    pub name: String,
    pub body: String,
    pub file: String,
    pub defn: String,
    #[serde(default)]
    pub owner: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BranchDecision {
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub predicate: String,
    pub state_refs: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BranchArm {
    pub file: String,
    pub function: String,
    pub kind: String,
    pub line: usize,
    pub span: Span,
    pub decision_line: usize,
    pub decision_span: Span,
    pub predicate: String,
    pub member: String,
    pub body: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DispatchSite {
    pub variant_set: Vec<String>,
    pub arm_members: BTreeMap<String, Vec<String>>,
    pub outside: Vec<String>,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SemanticEffectSite {
    pub kind: String,
    pub detail: String,
    #[serde(default)]
    pub receiver_scope: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct LocalComplexityScore {
    pub score: f64,
    pub signals: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ComparisonUse {
    pub canon_source: String,
    pub raw: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
    pub enclosing_span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PathConditionSite {
    pub guards: Vec<String>,
    pub action: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProtocolMethodEffect {
    pub file: String,
    pub owner: String,
    pub name: String,
    pub line: usize,
    pub reads: Vec<String>,
    pub writes: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProtocolCall {
    pub mid: String,
    pub file: String,
    pub owner: String,
    pub defn: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProtocolMethodPath {
    pub file: String,
    pub owner: String,
    pub name: String,
    pub line: usize,
    pub calls: Vec<ProtocolCall>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CloneCandidate {
    pub file: String,
    pub line: usize,
    pub span: Span,
    pub method_name: String,
    pub node_name: String,
    pub mass: usize,
    pub fingerprint: String,
    pub raw: String,
    pub child_fingerprints: Vec<String>,
    pub child_masses: Vec<usize>,
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

pub fn parse_file_for_report(file: PathBuf, language: Language) -> Result<Document> {
    tree_sitter_adapter::parse_file_for_report(file, language)
}

pub fn parse_files(files: &[PathBuf], language: Language) -> Result<Vec<Document>> {
    parallel::map_ordered(files, |file| parse_file(file.clone(), language))
}

pub(crate) fn protocol_method_effects(document: &Document) -> Vec<ProtocolMethodEffect> {
    document.protocol_method_effects.clone()
}

pub(crate) fn protocol_call_paths(document: &Document) -> Vec<ProtocolMethodPath> {
    document.protocol_call_paths.clone()
}

pub fn clone_candidates(document: &Document) -> Vec<CloneCandidate> {
    document.clone_candidates.clone()
}

pub fn core_owner_names(document: &Document) -> &'static [&'static str] {
    normalized_behavior::behavior(document.language).core_owner_names()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parallel;
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

    #[test]
    fn test_syntax_edge_cases() {
        assert_eq!(Language::parse("php").unwrap(), Language::Php);
        assert!(Language::parse("invalid").is_err());
        assert!(Language::for_extension("invalid").is_none());

        let mut c_header = tempfile::Builder::new()
            .suffix(".h")
            .tempfile()
            .expect("C header");
        c_header
            .write_all(b"typedef struct item { int value; } item;")
            .expect("write C header");
        assert_eq!(Language::for_path(c_header.path()), Some(Language::C));
        let mut cpp_header = tempfile::Builder::new()
            .suffix(".h")
            .tempfile()
            .expect("C++ header");
        cpp_header
            .write_all(b"namespace eventpp { template <typename T> class CallbackList {}; }")
            .expect("write C++ header");
        assert_eq!(Language::for_path(cpp_header.path()), Some(Language::Cpp));

        // Enable profile variable to cover profiling path
        std::env::set_var("DECOMPLEX_RUST_PROFILE", "1");

        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(b"def foo\nend").expect("write");
        let doc = parse_file_for_report(file.path().to_path_buf(), Language::Ruby).unwrap();
        assert_eq!(doc.file, file.path().to_string_lossy());

        std::env::remove_var("DECOMPLEX_RUST_PROFILE");

        let core_owners = core_owner_names(&doc);
        assert!(
            core_owners.is_empty() || core_owners.contains(&"Object") || core_owners.contains(&"")
        );
    }
}
