use super::{
    c, cpp, csharp, go, java, javascript, kotlin, lua, php, python, ruby, rust, swift, typescript,
    zig, CallSite, FunctionDef, Language, StateDeclaration,
};
use crate::ast::{Node, Span};
use crate::syntax::cfg::ControlFlowProfile;
use crate::type_inference::TypeExpr;
use std::collections::BTreeMap;
use std::sync::OnceLock;

#[derive(Clone, Debug, Default)]
pub(crate) struct SyntaxMetadata {
    pub(crate) immutable_struct_readers: BTreeMap<String, Vec<String>>,
    pub(crate) immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) type_aliases: BTreeMap<String, String>,
    pub(crate) type_alias_lines: BTreeMap<String, usize>,
    pub(crate) method_param_types: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) method_local_types: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedCallParts {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedCallProjection {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
    pub(crate) access_span: Span,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedOwner {
    pub(crate) name: String,
    pub(crate) kind: String,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedStateRead {
    pub(crate) receiver: String,
    pub(crate) field: String,
    pub(crate) line: Option<usize>,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedStateWrite {
    pub(crate) receiver: String,
    pub(crate) field: String,
    pub(crate) span: Span,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedSemanticEffect {
    pub(crate) kind: String,
    pub(crate) detail: String,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedVisibilityEvent {
    pub(crate) owner: String,
    pub(crate) visibility: String,
    pub(crate) line: usize,
    pub(crate) target_names: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct NormalizedNilGuardFact {
    pub(crate) local: String,
    pub(crate) non_nil_when_true: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BlockCallSemantics {
    Iteration,
    Once,
    Deferred,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CardinalityCallSemantics {
    PreservesReceiver,
    MeasuresReceiver,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CollectionAllocationSemantics {
    None,
    PreservesReceiver,
    UnknownSize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedCallComplexity {
    pub(crate) time: &'static str,
    pub(crate) space: &'static str,
}

/// Split the package coordinate from a global SCIP symbol while leaving the
/// language-owned descriptor opaque. SCIP standardizes the four leading
/// fields; only the descriptor grammar and package classification belong in
/// an adapter.
pub(crate) fn scip_global_parts<'a>(
    symbol: &'a str,
    scheme: &str,
    manager: &str,
) -> Option<(&'a str, &'a str, &'a str)> {
    let prefix = format!("{scheme} {manager} ");
    let rest = symbol.strip_prefix(&prefix)?;
    let mut fields = rest.splitn(3, ' ');
    Some((fields.next()?, fields.next()?, fields.next()?))
}

/// Split a SCIP descriptor on structural `/` separators while preserving
/// separators inside backtick-escaped descriptors (for example the
/// TypeScript module descriptor `"fs/promises"`).
pub(crate) fn scip_descriptor_segments(descriptor: &str) -> Vec<&str> {
    let mut segments = Vec::new();
    let mut start = 0usize;
    let mut quoted = false;
    for (offset, character) in descriptor.char_indices() {
        if character == '`' {
            quoted = !quoted;
        } else if character == '/' && !quoted {
            segments.push(&descriptor[start..offset]);
            start = offset + 1;
        }
    }
    segments.push(&descriptor[start..]);
    segments
}

/// Return the nearest enclosing type/namespace descriptor. This intentionally
/// does not infer a source-language type; adapters decide whether the returned
/// descriptor is a class, namespace, module, or standard-library owner.
pub(crate) fn scip_descriptor_owner(descriptor: &str) -> Option<String> {
    let segments = scip_descriptor_segments(descriptor);
    let callable = *segments.last()?;
    if let Some((owner, _)) = callable.split_once('#') {
        return Some(owner.trim_matches('`').to_string());
    }
    segments
        .iter()
        .rev()
        .nth(1)
        .map(|owner| owner.trim_matches('`').to_string())
        .filter(|owner| !owner.is_empty())
}

/// Fact-Mine's language registry maps a native collection API spelling to one
/// of these operations. The common operation algebra deliberately lives here,
/// rather than in an analyzer: all downstream facts describe the same
/// operation regardless of surface syntax.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NormalizedCollectionOperation {
    Constant,
    Logarithmic,
    LinearScan,
    LinearMaterialize,
    Sort,
    Pairwise,
    Cubic,
    Exponential,
}

impl NormalizedCollectionOperation {
    pub(crate) fn complexity(self) -> NormalizedCallComplexity {
        match self {
            Self::Constant => NormalizedCallComplexity {
                time: "O(1)",
                space: "O(1)",
            },
            Self::Logarithmic => NormalizedCallComplexity {
                time: "O(log N)",
                space: "O(1)",
            },
            Self::LinearScan => NormalizedCallComplexity {
                time: "O(N)",
                space: "O(1)",
            },
            Self::LinearMaterialize => NormalizedCallComplexity {
                time: "O(N)",
                space: "O(N)",
            },
            Self::Sort => NormalizedCallComplexity {
                time: "O(N log N)",
                space: "O(N)",
            },
            Self::Pairwise => NormalizedCallComplexity {
                time: "O(N * M)",
                space: "O(N)",
            },
            Self::Cubic => NormalizedCallComplexity {
                time: "O(N^3)",
                space: "O(N)",
            },
            Self::Exponential => NormalizedCallComplexity {
                time: "O(2^N)",
                space: "O(N)",
            },
        }
    }
}

type StdlibOperationMap = BTreeMap<String, BTreeMap<String, String>>;

const RUBY_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/ruby.yml");
const PYTHON_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/python.yml");
const TYPESCRIPT_STDLIB_OPERATIONS: &str =
    include_str!("../../config/stdlib_complexity/typescript.yml");
const JAVA_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/java.yml");
const CSHARP_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/csharp.yml");
const GO_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/go.yml");
const CPP_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/cpp.yml");
const C_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/c.yml");
const JAVASCRIPT_STDLIB_OPERATIONS: &str =
    include_str!("../../config/stdlib_complexity/javascript.yml");
const KOTLIN_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/kotlin.yml");
const LUA_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/lua.yml");
const PHP_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/php.yml");
const RUST_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/rust.yml");
const SWIFT_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/swift.yml");
const ZIG_STDLIB_OPERATIONS: &str = include_str!("../../config/stdlib_complexity/zig.yml");

fn parsed_stdlib_operations(
    source: &'static str,
    cache: &'static OnceLock<StdlibOperationMap>,
) -> &'static StdlibOperationMap {
    cache.get_or_init(|| {
        serde_yaml::from_str(source)
            .expect("Fact-Mine stdlib complexity configuration must be valid YAML")
    })
}

fn stdlib_operations(language: &str) -> Option<&'static StdlibOperationMap> {
    static RUBY: OnceLock<StdlibOperationMap> = OnceLock::new();
    static PYTHON: OnceLock<StdlibOperationMap> = OnceLock::new();
    static TYPESCRIPT: OnceLock<StdlibOperationMap> = OnceLock::new();
    static JAVA: OnceLock<StdlibOperationMap> = OnceLock::new();
    static CSHARP: OnceLock<StdlibOperationMap> = OnceLock::new();
    static GO: OnceLock<StdlibOperationMap> = OnceLock::new();
    static CPP: OnceLock<StdlibOperationMap> = OnceLock::new();
    static C: OnceLock<StdlibOperationMap> = OnceLock::new();
    static JAVASCRIPT: OnceLock<StdlibOperationMap> = OnceLock::new();
    static KOTLIN: OnceLock<StdlibOperationMap> = OnceLock::new();
    static LUA: OnceLock<StdlibOperationMap> = OnceLock::new();
    static PHP: OnceLock<StdlibOperationMap> = OnceLock::new();
    static RUST: OnceLock<StdlibOperationMap> = OnceLock::new();
    static SWIFT: OnceLock<StdlibOperationMap> = OnceLock::new();
    static ZIG: OnceLock<StdlibOperationMap> = OnceLock::new();

    match language {
        "ruby" => Some(parsed_stdlib_operations(RUBY_STDLIB_OPERATIONS, &RUBY)),
        "python" => Some(parsed_stdlib_operations(PYTHON_STDLIB_OPERATIONS, &PYTHON)),
        "typescript" => Some(parsed_stdlib_operations(
            TYPESCRIPT_STDLIB_OPERATIONS,
            &TYPESCRIPT,
        )),
        "javascript" => Some(parsed_stdlib_operations(
            JAVASCRIPT_STDLIB_OPERATIONS,
            &JAVASCRIPT,
        )),
        "java" => Some(parsed_stdlib_operations(JAVA_STDLIB_OPERATIONS, &JAVA)),
        "csharp" => Some(parsed_stdlib_operations(CSHARP_STDLIB_OPERATIONS, &CSHARP)),
        "go" => Some(parsed_stdlib_operations(GO_STDLIB_OPERATIONS, &GO)),
        "cpp" => Some(parsed_stdlib_operations(CPP_STDLIB_OPERATIONS, &CPP)),
        "c" => Some(parsed_stdlib_operations(C_STDLIB_OPERATIONS, &C)),
        "kotlin" => Some(parsed_stdlib_operations(KOTLIN_STDLIB_OPERATIONS, &KOTLIN)),
        "lua" => Some(parsed_stdlib_operations(LUA_STDLIB_OPERATIONS, &LUA)),
        "php" => Some(parsed_stdlib_operations(PHP_STDLIB_OPERATIONS, &PHP)),
        "rust" => Some(parsed_stdlib_operations(RUST_STDLIB_OPERATIONS, &RUST)),
        "swift" => Some(parsed_stdlib_operations(SWIFT_STDLIB_OPERATIONS, &SWIFT)),
        "zig" => Some(parsed_stdlib_operations(ZIG_STDLIB_OPERATIONS, &ZIG)),
        _ => None,
    }
}

/// Whether a declared receiver spelling is owned by the reviewed standard-
/// library registry for this language. This deliberately proves identity only;
/// the absence of a method model remains distinct from an unknown receiver.
pub(crate) fn configured_stdlib_type(language: &str, receiver_type: &TypeExpr) -> bool {
    let receiver = receiver_type.strip_nilable();
    let names = match &receiver {
        TypeExpr::Array(_) => vec!["Array".to_string()],
        TypeExpr::Hash { .. } => vec!["Hash".to_string()],
        TypeExpr::Set(_) => vec!["Set".to_string()],
        TypeExpr::Primitive(name) => {
            let unqualified = name
                .rsplit([':', '.'])
                .find(|part| !part.is_empty())
                .unwrap_or(name);
            vec![name.clone(), unqualified.to_string()]
        }
        _ => return false,
    };
    stdlib_operations(language)
        .is_some_and(|operations| names.into_iter().any(|name| operations.contains_key(&name)))
}

/// Whether a free/static call identity belongs to a reviewed language runtime
/// or standard-library declaration surface. `declaration` entries intentionally
/// carry no complexity model; this function is for provenance classification,
/// not cost inference.
pub(crate) fn configured_stdlib_call_identity(
    language: &str,
    lexical_symbol: Option<&str>,
    receiver_symbol: Option<&str>,
    message: &str,
) -> bool {
    let Some(operations) = stdlib_operations(language) else {
        return false;
    };
    let bare_message = message
        .split('<')
        .next()
        .unwrap_or(message)
        .trim_start_matches("::");
    if operations
        .get("Intrinsic")
        .is_some_and(|intrinsics| intrinsics.contains_key(bare_message))
    {
        return true;
    }
    let symbols = lexical_symbol.into_iter().chain(receiver_symbol);
    let Some(namespaces) = operations.get("Namespace") else {
        return false;
    };
    symbols.into_iter().any(|symbol| {
        let normalized = symbol
            .trim()
            .trim_matches(['\'', '"'])
            .trim_start_matches("const ")
            .trim_start_matches("readonly ")
            .trim_start_matches(['*', '&'])
            .trim_start_matches("::");
        namespaces.keys().any(|namespace| {
            normalized == namespace.as_str()
                || normalized.starts_with(&format!("{namespace}::"))
                || normalized.starts_with(&format!("{namespace}."))
        })
    })
}

pub(crate) fn configured_non_call_construct(language: &str, message: &str) -> bool {
    let Some(operations) = stdlib_operations(language) else {
        return false;
    };
    let message = message.trim();
    operations
        .get("NonCallConstruct")
        .is_some_and(|constructs| constructs.contains_key(message))
        || operations
            .get("NonCallPrefix")
            .is_some_and(|constructs| constructs.keys().any(|prefix| message.starts_with(prefix)))
}

pub(crate) fn configured_dynamic_global_binding(language: &str) -> bool {
    stdlib_operations(language)
        .and_then(|operations| operations.get("DynamicGlobalBinding"))
        .is_some_and(|configuration| configuration.contains_key("enabled"))
}

/// Split a language-selected base/interface clause without breaking generic
/// arguments. Selecting the clause remains language-specific; this helper only
/// normalizes the resulting nominal list.
pub(crate) fn split_declared_supertypes(source: &str) -> Vec<String> {
    let mut rows = Vec::new();
    let mut start = 0;
    let mut depth = 0usize;
    for (index, character) in source.char_indices() {
        match character {
            '<' | '(' | '[' => depth += 1,
            '>' | ')' | ']' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                rows.push(&source[start..index]);
                start = index + character.len_utf8();
            }
            _ => {}
        }
    }
    rows.push(&source[start..]);
    rows.into_iter()
        .filter_map(|row| {
            let mut words = row.split_whitespace().collect::<Vec<_>>();
            words.retain(|word| !matches!(*word, "public" | "protected" | "private" | "virtual"));
            let value = words.join(" ");
            let value = value.trim().trim_end_matches(['{', ':']).trim();
            (!value.is_empty()).then(|| value.to_string())
        })
        .collect()
}

pub(crate) fn declared_supertype_clause<'a>(
    header: &'a str,
    marker: &str,
    stops: &[&str],
) -> Option<&'a str> {
    let marker = format!(" {marker} ");
    let marker_start = top_level_marker(header, &marker)?;
    let tail = &header[marker_start + marker.len()..];
    let end = stops
        .iter()
        .filter_map(|stop| top_level_marker(tail, &format!(" {stop} ")))
        .min()
        .unwrap_or(tail.len());
    Some(tail[..end].trim())
}

fn top_level_marker(source: &str, marker: &str) -> Option<usize> {
    let mut angle_depth = 0usize;
    for (index, character) in source.char_indices() {
        match character {
            '<' => angle_depth += 1,
            '>' => angle_depth = angle_depth.saturating_sub(1),
            _ if angle_depth == 0 && source[index..].starts_with(marker) => {
                return Some(index);
            }
            _ => {}
        }
    }
    None
}

fn operation_from_config(value: &str) -> Option<NormalizedCollectionOperation> {
    match value {
        "constant" => Some(NormalizedCollectionOperation::Constant),
        "logarithmic" => Some(NormalizedCollectionOperation::Logarithmic),
        "linear_scan" => Some(NormalizedCollectionOperation::LinearScan),
        "linear_materialize" => Some(NormalizedCollectionOperation::LinearMaterialize),
        "sort" => Some(NormalizedCollectionOperation::Sort),
        "pairwise" => Some(NormalizedCollectionOperation::Pairwise),
        "cubic" => Some(NormalizedCollectionOperation::Cubic),
        "exponential" => Some(NormalizedCollectionOperation::Exponential),
        _ => None,
    }
}

/// Resolve a language-owned free function or static standard-library call.
/// The YAML key is either `function` for a bare intrinsic or `Type.function`
/// for a statically-qualified one. We deliberately do not match a qualified
/// call by bare method name: `Util.sort` is not `Collections.sort`.
pub(crate) fn configured_intrinsic_operation(
    language: &str,
    receiver: Option<&str>,
    message: &str,
) -> Option<NormalizedCollectionOperation> {
    let operations = stdlib_operations(language)?;
    let intrinsics = operations.get("Intrinsic")?;
    let key = receiver
        .filter(|receiver| !receiver.trim().is_empty())
        .map(|receiver| format!("{}.{}", receiver.trim(), message))
        .unwrap_or_else(|| message.to_string());
    intrinsics
        .get(&key)
        .and_then(|operation| operation_from_config(operation))
}

pub(crate) fn configured_intrinsic_call_complexity(
    language: &str,
    receiver: Option<&str>,
    message: &str,
) -> Option<NormalizedCallComplexity> {
    configured_intrinsic_operation(language, receiver, message)
        .map(NormalizedCollectionOperation::complexity)
}

/// Resolve an opaque compiler symbol discriminator when the registry has been
/// reviewed against that exact semantic scheme. This is preferable to
/// guessing an overload from argument text, and deliberately has no fallback
/// to owner/method spelling.
pub(crate) fn configured_semantic_symbol_call_complexity(
    language: &str,
    descriptor: &str,
) -> Option<NormalizedCallComplexity> {
    stdlib_operations(language)?
        .get("SemanticSymbol")?
        .get(descriptor)
        .and_then(|value| operation_from_config(value))
        .map(NormalizedCollectionOperation::complexity)
}

/// Return a language-owned semantic role for an exact compiler symbol.
/// Roles are diagnostic/proof obligations only; they never select a target or
/// supply a cost. Keeping them in YAML avoids embedding a language's standard
/// library vocabulary in shared SCIP or reporting code.
pub(crate) fn configured_semantic_symbol_kind(language: &str, descriptor: &str) -> Option<String> {
    stdlib_operations(language)?
        .get("SemanticSymbolKind")?
        .get(descriptor)
        .cloned()
}

pub(crate) fn configured_semantic_symbol_parametric_cost(
    language: &str,
    descriptor: &str,
) -> Option<String> {
    stdlib_operations(language)?
        .get("SemanticSymbolParametricCost")?
        .get(descriptor)
        .cloned()
}

/// Resolve a parametric contract from a proven declared receiver type. This
/// complements compiler-symbol contracts for producers that omit occurrences
/// on builtin interface methods (notably Go's predeclared `error`).
pub(crate) fn configured_parametric_call_cost(
    language: &str,
    receiver_type: &TypeExpr,
    message: &str,
) -> Option<String> {
    let TypeExpr::Primitive(name) = receiver_type.strip_nilable() else {
        return None;
    };
    let unqualified = name
        .rsplit([':', '.'])
        .find(|part| !part.is_empty())
        .unwrap_or(&name);
    let operations = stdlib_operations(language)?;
    let contracts = operations.get("ParametricCall")?;
    let result = [name.as_str(), unqualified].into_iter().find_map(|owner| {
        contracts.get(&format!("{owner}.{message}")).cloned()
    });
    result
}

pub(crate) fn configured_callable_type_cost(language: &str, declared_type: &str) -> Option<String> {
    let normalized = declared_type.trim().trim_start_matches('*');
    let unqualified = normalized
        .rsplit([':', '.'])
        .find(|part| !part.is_empty())
        .unwrap_or(normalized);
    let contracts = stdlib_operations(language)?.get("CallableType")?;
    contracts
        .get(normalized)
        .or_else(|| contracts.get(unqualified))
        .cloned()
}

/// Return a reviewed modeled-world bound for an exact compiler symbol. The
/// symbol proves API identity; the configured candidates and assumption make
/// explicit that dynamic callbacks/overrides are bounded only within a finite
/// reviewed universe rather than across arbitrary third-party code.
pub(crate) fn configured_semantic_symbol_upper_bound(
    language: &str,
    descriptor: &str,
) -> Option<(NormalizedCallComplexity, Vec<String>, Option<String>)> {
    let operations = stdlib_operations(language)?;
    let operation = operations
        .get("SemanticSymbolUpperBound")?
        .get(descriptor)
        .and_then(|value| operation_from_config(value))?;
    let candidates = operations
        .get("SemanticSymbolCandidates")
        .and_then(|rows| rows.get(descriptor))
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|candidate| !candidate.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let assumption = operations
        .get("SemanticSymbolAssumptions")
        .and_then(|rows| rows.get(descriptor))
        .cloned();
    Some((operation.complexity(), candidates, assumption))
}

/// Return a reviewed worst-case operation for an interface over a configured
/// implementation universe. This is deliberately separate from ordinary
/// declaration models: the result is a closed/modelled-world upper bound, not
/// proof that arbitrary third-party implementations share the same cost.
pub(crate) fn configured_interface_upper_bound(
    language: &str,
    owner: &str,
    message: &str,
) -> Option<(NormalizedCallComplexity, Vec<String>)> {
    let operations = stdlib_operations(language)?;
    let key = format!("{}.{}", owner.trim(), message);
    let operation = operations
        .get("InterfaceUpperBound")?
        .get(&key)
        .and_then(|value| operation_from_config(value))?;
    let candidates = operations
        .get("InterfaceCandidates")
        .and_then(|rows| rows.get(owner.trim()))
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|candidate| !candidate.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Some((operation.complexity(), candidates))
}

/// Computational bound for an API whose wall-clock latency depends on an
/// external device, filesystem, process, or stream. Consumers must preserve
/// the returned assumption instead of presenting it as an end-to-end latency
/// bound.
pub(crate) fn configured_external_latency_bound(
    language: &str,
    owner: &str,
    message: &str,
) -> Option<NormalizedCallComplexity> {
    let operations = stdlib_operations(language)?;
    let key = format!("{}.{}", owner.trim(), message);
    operations
        .get("ExternalLatency")?
        .get(&key)
        .and_then(|value| operation_from_config(value))
        .map(NormalizedCollectionOperation::complexity)
}

/// Resolve a language-owned collection spelling through Fact-Mine's YAML
/// configuration. Adapters provide the language identity and normalize native
/// declaration grammar; Espalier never loads or interprets a language-specific
/// complexity table.
pub(crate) fn configured_collection_operation(
    language: &str,
    receiver_type: &TypeExpr,
    message: &str,
) -> Option<NormalizedCollectionOperation> {
    let receiver = receiver_type.strip_nilable();
    let names = match &receiver {
        TypeExpr::Array(_) => vec!["Array".to_string()],
        TypeExpr::Hash { .. } => vec!["Hash".to_string()],
        TypeExpr::Set(_) => vec!["Set".to_string()],
        TypeExpr::Primitive(name) => {
            let unqualified = name.rsplit("::").next().unwrap_or(name);
            if unqualified == name {
                vec![name.clone()]
            } else {
                vec![name.clone(), unqualified.to_string()]
            }
        }
        _ => return None,
    };
    let operations = stdlib_operations(language)?;
    names.into_iter().find_map(|name| {
        operations
            .get(&name)
            .and_then(|methods| methods.get(message))
            .and_then(|operation| operation_from_config(operation))
    })
}

pub(crate) trait NormalizedLanguageBehavior: Sync {
    /// The configuration key for this source language. Keeping this at the
    /// adapter boundary ensures Fact-Mine owns native spellings while every
    /// downstream consumer sees only normalized complexity facts.
    fn stdlib_language(&self) -> Option<&'static str> {
        None
    }

    /// Interpret a compiler symbol only at the owning language boundary. The
    /// shared SCIP importer asks through this normalized interface and never
    /// contains a language-specific symbol grammar.
    fn external_symbol_call_complexity(
        &self,
        _symbol: &str,
        _message: &str,
    ) -> Option<super::ExternalCallComplexity> {
        None
    }

    fn external_symbol_metadata(&self, _symbol: &str) -> super::ExternalSymbolMetadata {
        super::ExternalSymbolMetadata {
            scope: "external",
            missing_cost_kind: "external_cost_model_missing".to_string(),
            parametric_cost: None,
        }
    }

    /// Native owner identity encoded in a compiler symbol. Shared SCIP logic
    /// uses this only to match an already-normalized project interface; the
    /// symbol grammar remains confined to the language adapter.
    fn external_symbol_owner(&self, _symbol: &str) -> Option<String> {
        None
    }

    /// Whether a non-call SCIP occurrence can execute source-language code.
    /// Most field/property-shaped symbols are data access; adapters opt in
    /// only when their language gives that syntax callable semantics.
    fn scip_noncall_access_is_callable(&self, _symbol: &str) -> bool {
        false
    }

    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        ControlFlowProfile::neutral_ref()
    }

    fn declared_type_hint_complete(&self, _type_name: &str) -> bool {
        true
    }

    /// Return the declared type of one local binding when the native syntax
    /// proves it. Adapters opt into a small shared declaration parser; type
    /// inference (`var`, `auto`, `let`, and similar forms) deliberately does
    /// not enter this contract.
    fn declared_local_type(&self, _source: &str, _name: &str) -> Option<String> {
        None
    }

    fn collection_allocation_semantics(&self, _message: &str) -> CollectionAllocationSemantics {
        CollectionAllocationSemantics::None
    }

    fn block_call_semantics(&self, _message: &str) -> BlockCallSemantics {
        BlockCallSemantics::Unknown
    }

    fn cardinality_call_semantics(&self, _message: &str) -> CardinalityCallSemantics {
        CardinalityCallSemantics::Unknown
    }

    fn iteration_bound_argument(&self, _message: &str, _argument_count: usize) -> Option<usize> {
        None
    }

    fn iteration_yields_collection_value(&self, _message: &str) -> bool {
        false
    }

    fn callback_parameter_names(&self, _function: &Node) -> Vec<String> {
        Vec::new()
    }

    fn callback_invocation_message(&self, _message: &str) -> bool {
        false
    }

    /// Whether a function nested inside another function is a lexical closure
    /// rather than an owner method.
    fn nested_function_is_lexical(&self, _function: &Node) -> bool {
        false
    }

    /// Whether a declaration nested below another method body represents a
    /// method on an anonymous owner rather than a lexical/local declaration.
    /// This is false unless the language's declaration model proves it.
    fn nested_function_is_owner_method(&self, _function: &Node) -> bool {
        false
    }

    /// Whether adapter-validated DEFNs nested in an executable body are
    /// independently callable declarations rather than syntax owned by the
    /// enclosing method.
    fn nested_function_is_local_callable(&self, _function: &Node) -> bool {
        false
    }

    /// Bindings introduced by a conditional header that shadow outer locals.
    fn conditional_local_bindings(&self, _conditional: &Node) -> Vec<String> {
        Vec::new()
    }

    /// Project equivalent state spellings to one owner-relative identity.
    fn canonical_state_field(&self, _receiver: &str, field: &str) -> String {
        field.to_string()
    }

    /// A stable state identity for analyzers that must distinguish two owners
    /// with the same field spelling. Owner qualification is the portable
    /// default: two unrelated classes both having `config` or `kind` state
    /// must never be analyzed as one mutable field.
    fn state_identity(&self, owner: &str, field: &str) -> String {
        (!owner.is_empty())
            .then(|| format!("{owner}::{field}"))
            .unwrap_or_default()
    }

    fn empty_check_call(&self, _message: &str) -> bool {
        false
    }
    fn visited_membership_call(&self, _message: &str) -> bool {
        false
    }
    fn visited_insert_call(&self, _message: &str) -> bool {
        false
    }
    fn empty_collection_constructor(&self, _message: &str) -> bool {
        false
    }
    fn collection_parameter_type(&self, _type_name: &str) -> bool {
        false
    }
    /// Maps a type-proven standard-library method to a normalized operation.
    /// The adapter owns native declaration grammar and receiver normalization;
    /// Fact-Mine's language registry owns native API spellings and costs.
    /// Unknown/user calls must return `None`.
    fn collection_operation(
        &self,
        receiver_type: &TypeExpr,
        message: &str,
    ) -> Option<NormalizedCollectionOperation> {
        self.stdlib_language()
            .and_then(|language| configured_collection_operation(language, receiver_type, message))
    }

    fn call_complexity(
        &self,
        receiver_type: &TypeExpr,
        message: &str,
    ) -> Option<NormalizedCallComplexity> {
        self.collection_operation(receiver_type, message)
            .map(NormalizedCollectionOperation::complexity)
    }

    fn parametric_call_cost(&self, receiver_type: &TypeExpr, message: &str) -> Option<String> {
        self.stdlib_language().and_then(|language| {
            configured_parametric_call_cost(language, receiver_type, message)
        })
    }

    /// Classify a language-owned declared function/callable type. The shared
    /// profile follows field projections; adapters only recognize native type
    /// grammar or reviewed named callable aliases.
    fn declared_callable_cost(&self, declared_type: &str) -> Option<String> {
        self.stdlib_language().and_then(|language| {
            configured_callable_type_cost(language, declared_type)
        })
    }

    /// Return a cost only when the adapter recognizes a language/runtime
    /// intrinsic without guessing the receiver's type. This keeps spellings in
    /// language adapters while downstream complexity analysis stays generic.
    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<NormalizedCallComplexity> {
        self.stdlib_language()
            .and_then(|language| configured_intrinsic_call_complexity(language, receiver, message))
    }

    /// Whether an unqualified call inside an instance method may dispatch to
    /// another method on the implicit current receiver. Languages such as Go
    /// require an explicit receiver (`x.f()`), while Ruby/Java-style method
    /// lookup permits a bare `f()`. This language-owned syntax rule prevents
    /// the shared resolver from confusing a predeclared function such as
    /// Go's `len` with an unrelated same-named method.
    fn supports_implicit_owner_dispatch(&self) -> bool {
        true
    }

    fn literal_receiver_type(&self, _node: &Node) -> Option<TypeExpr> {
        None
    }

    /// Whether a normalized ARRAY/LIST node is a source collection literal.
    /// Some parsers reuse those node kinds for argument lists, so the
    /// language adapter must make the syntax-identity decision.
    fn array_literal_node(&self, _node: &Node) -> bool {
        true
    }
    fn supports_parameter_normalization(&self) -> bool {
        false
    }

    fn yield_semantic_effect(&self, _node: &Node) -> bool {
        true
    }

    fn boolean_decision_members(&self, members: Vec<String>, _node: &Node) -> Vec<String> {
        members
    }

    fn state_write_span(
        &self,
        _receiver: &str,
        _field: &str,
        _node: &Node,
        default_span: Span,
    ) -> Span {
        default_span
    }

    fn call_access_span(&self, _node: &Node, computed_span: Option<Span>, full_span: Span) -> Span {
        computed_span.unwrap_or(full_span)
    }

    fn call_site_span(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        full_span: Span,
        access_span: Span,
        current_function: &str,
    ) -> Span {
        if self.access_span_call_site(&parts.message, current_function) {
            access_span
        } else {
            full_span
        }
    }

    fn call_receiver(&self, parts: &NormalizedCallParts) -> String {
        parts.receiver.clone()
    }

    fn project_call(
        &self,
        _node: &Node,
        call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        call
    }

    fn node_call_projections(&self, _node: &Node) -> Vec<NormalizedCallProjection> {
        Vec::new()
    }

    fn suppress_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn preserve_constant_receiver_call(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn is_type_guard(&self, _message: &str) -> bool {
        false
    }

    fn is_nil_check(&self, _message: &str) -> bool {
        false
    }

    fn is_type_normalizer(&self, _receiver: &str, _message: &str) -> bool {
        false
    }

    fn is_type_cast(&self, _receiver: &str, _message: &str) -> bool {
        false
    }

    fn struct_declaration_fields(&self, _node: &Node) -> Option<Vec<String>> {
        None
    }

    fn static_return_type(&self, _message: &str, _receiver_type: Option<&str>) -> Option<String> {
        None
    }

    fn static_call_return_type(
        &self,
        _node: &Node,
        _message: &str,
        _receiver_type: Option<&str>,
    ) -> Option<String> {
        None
    }

    fn known_return_type(&self, _name: &str) -> Option<String> {
        None
    }

    fn propagated_collection_return_type(
        &self,
        _message: &str,
        _receiver_type: Option<&str>,
    ) -> Option<String> {
        None
    }

    fn is_noreturn_method(&self, _message: &str) -> bool {
        false
    }

    fn emit_index_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn emit_index_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        false
    }

    fn emit_attribute_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        false
    }

    fn local_assignment_writes(
        &self,
        _field: Option<&str>,
        _node: &Node,
        _default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        Vec::new()
    }

    /// Excludes syntax that looks like a field assignment but only initializes
    /// a callable view. `this.run = this.run.bind(this)` does not create
    /// independently mutable domain state.
    fn suppress_state_write(&self, _receiver: &str, _field: &str, _node: &Node) -> bool {
        false
    }

    /// Whether passing the receiver aggregate to this call makes every field
    /// of that aggregate an opaque possible read.
    fn opaque_receiver_escape_call(&self, _call: &CallSite) -> bool {
        false
    }

    fn implicit_owner_fields(&self) -> bool {
        false
    }

    fn field_name_from_declaration(&self, _node: &Node) -> Option<String> {
        None
    }

    fn state_declaration_from_node(
        &self,
        _node: &Node,
        _owner: &str,
        _in_method: bool,
    ) -> Option<StateDeclaration> {
        None
    }

    /// Recover a declared state slot from a function-shaped normalized node.
    /// Some source constructs (for example a C# auto-property) are modeled as
    /// a function to retain their executable accessor body, but still declare
    /// a stable state slot.
    fn state_declaration_from_function(
        &self,
        _node: &Node,
        _owner: &str,
    ) -> Option<StateDeclaration> {
        None
    }

    fn embedded_member_reads(&self, _node: &Node) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn literal_state_reads(
        &self,
        _node: &Node,
        _normalized_text: &str,
        _span: Span,
        _source_text: &str,
    ) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn node_state_reads(&self, _node: &Node) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn initializer_field_reads(
        &self,
        _node: &Node,
        _owner: &str,
        _owner_fields: &[String],
        _function_name: &str,
    ) -> Vec<NormalizedStateRead> {
        Vec::new()
    }

    fn suppress_state_read_for_call(
        &self,
        _call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        false
    }

    fn record_method_calls_as_state_reads(&self) -> bool {
        true
    }

    fn suppress_method_call_state_read(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn suppress_self_call_state_read(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        false
    }

    fn suppress_branch_decision(&self, _node: &Node) -> bool {
        false
    }

    fn ternary_children_conditional(&self, _node: &Node) -> bool {
        true
    }

    fn ternary_if_node(&self, _node: &Node) -> bool {
        false
    }

    fn normalize_source_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn clean_identifier(&self, token: &str) -> String {
        token.strip_prefix("self.").unwrap_or(token).to_string()
    }

    fn clean_receiver(&self, receiver: &str) -> String {
        receiver.to_string()
    }

    fn source_message_text(&self, message: &str, _node: Option<&Node>) -> String {
        message.to_string()
    }

    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn owner_name_span(&self, _name: &str, _node: &Node, _default_span: Span) -> Option<Span> {
        None
    }

    fn owner_name_from_text(&self, _node: &Node) -> Option<String> {
        None
    }

    fn owner_kind(&self, _node: &Node, default_kind: &str) -> String {
        default_kind.to_string()
    }

    /// Direct native base/interface spellings owned by this language's
    /// declaration grammar. Shared consumers canonicalize and traverse them.
    fn owner_supertypes(&self, _node: &Node) -> Vec<String> {
        Vec::new()
    }

    /// Whether an owner declaration may extend a prior declaration with the
    /// same name. This is normalized evidence for downstream detectors; the
    /// language rule itself belongs in the language behavior.
    fn reopenable_owner(&self, _node: &Node) -> bool {
        false
    }

    fn declarative_owner(&self, _node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        None
    }

    fn mutating_receiver_message(&self, _message: &str) -> bool {
        false
    }

    /// Extract a declared type from a single normalized function parameter.
    /// Parsing the surface spelling stays in the syntax adapter; callers only
    /// consume the common parameter-name -> type contract.
    fn parameter_type_from_signature(&self, _parameter: &str) -> Option<String> {
        None
    }

    fn syntax_metadata(&self, source: &str, functions: &[FunctionDef]) -> SyntaxMetadata {
        SyntaxMetadata {
            method_param_types: method_param_types_from_signatures(self, source, functions),
            ..SyntaxMetadata::default()
        }
    }

    fn owner_for_function(
        &self,
        _name: &str,
        _node: &Node,
        current_owner: &str,
        _file_owner: &str,
    ) -> String {
        current_owner.to_string()
    }

    fn function_dispatch_name(&self, name: &str) -> String {
        name.to_string()
    }

    fn function_dispatch_kind(&self, _name: &str, owner: &str) -> String {
        if owner.is_empty() { "top" } else { "instance" }.to_string()
    }

    /// Project a function declaration's native dispatch form while the
    /// normalized declaration node is still available. Most languages use
    /// the ordinary owner/name contract; adapters override this only where a
    /// declaration modifier or receiver changes dispatch semantics.
    fn function_dispatch_kind_from_node(&self, name: &str, _node: &Node, owner: &str) -> String {
        self.function_dispatch_kind(name, owner)
    }

    fn receiver_is_type_reference(&self, _receiver: &str) -> bool {
        false
    }

    fn constructor_dispatch_name(&self, _receiver: &str, _message: &str) -> Option<String> {
        None
    }

    fn declarative_owner_constant_operations(&self, _node: &Node) -> Vec<String> {
        Vec::new()
    }

    fn body_owner_for_function(
        &self,
        _name: &str,
        _node: &Node,
        _current_owner: &str,
        _file_owner: &str,
    ) -> Option<NormalizedOwner> {
        None
    }

    fn receiver_aliases_for_function(&self, _node: &Node) -> BTreeMap<String, String> {
        BTreeMap::new()
    }

    fn function_visibility(&self, _name: &str, _node: &Node, _lines: &[String]) -> String {
        "public".to_string()
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        let source = text.trim();
        let before_paren = source
            .split_once('(')
            .map(|(before, _)| before)
            .unwrap_or(source);
        before_paren
            .split_whitespace()
            .next_back()
            .map(|value| value.trim_start_matches(['*', '&']).to_string())
            .filter(|value| !value.is_empty())
    }

    fn parameter_list_source(&self, source: &str) -> String {
        let Some(open_index) = source.find('(') else {
            return String::new();
        };
        let Some(close_index) = matching_paren_index(source, open_index) else {
            return String::new();
        };
        source[(open_index + 1)..close_index].to_string()
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.trim();
        if text.is_empty() {
            return None;
        }
        let text = text.split('=').next().unwrap_or(text).trim();
        text.split(|ch: char| !(ch == '_' || ch == '?' || ch.is_ascii_alphanumeric()))
            .filter(|part| !part.is_empty())
            .next_back()
            .map(|part| part.trim_end_matches('?').to_string())
    }

    fn property_read_call(&self, _node: &Node, _parts: &NormalizedCallParts) -> bool {
        false
    }

    fn case_pattern_values(&self, pattern_values: Vec<String>) -> Vec<String> {
        pattern_values
    }

    fn split_case_source(&self, source: &str) -> Vec<String> {
        source
            .split(',')
            .map(str::trim)
            .filter(|pattern| !pattern.is_empty())
            .map(|pattern| self.case_pattern_display(pattern))
            .collect()
    }

    fn case_pattern_display(&self, pattern: &str) -> String {
        pattern.to_string()
    }

    fn case_predicate_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn access_span_call_site(&self, _message: &str, _current_function: &str) -> bool {
        false
    }

    fn boolean_enclosing_span(
        &self,
        _node: &Node,
        _node_span: Span,
        decision_span: Option<Span>,
    ) -> Span {
        decision_span.unwrap_or(_node_span)
    }

    fn method_state_ref(&self, _node: &Node, _parts: &NormalizedCallParts) -> bool {
        false
    }

    fn initializer_writes(
        &self,
        _node: &Node,
        _source_text: &str,
        _span: Span,
    ) -> Vec<NormalizedStateWrite> {
        Vec::new()
    }

    /// Extract explicit 'this.' or 'self.' bindings
    fn literal_state_writes(&self, _node: &Node, _normalized_text: &str) -> Vec<String> {
        Vec::new()
    }

    fn literal_state_refs(&self, _node: &Node, _normalized_text: &str) -> Vec<String> {
        Vec::new()
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        message.to_string()
    }

    fn stream_insertion_operator(&self, _node: &Node) -> bool {
        false
    }

    fn branch_state_ref(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        let receiver = parts.receiver.as_str();
        if receiver
            .chars()
            .next()
            .is_some_and(|ch| ch == ':' || ch.is_ascii_uppercase())
            && !receiver.contains('(')
        {
            None
        } else {
            Some(default_ref)
        }
    }

    fn normalize_comparison_source(&self, source: &str) -> String {
        self.normalize_source_text(source.trim())
    }

    fn visibility_events_from_calls(&self, _calls: &[CallSite]) -> Vec<NormalizedVisibilityEvent> {
        Vec::new()
    }

    fn protocol_read_label_from_state(&self, receiver: &str, field: &str) -> Option<String> {
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!("{receiver}.{field}"))
        }
    }

    fn protocol_read_label_from_call(&self, receiver: &str, message: &str) -> Option<String> {
        (receiver == "self").then(|| message.to_string())
    }

    fn protocol_write_label(&self, receiver: &str, field: &str) -> Option<String> {
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!("{receiver}.{field}"))
        }
    }

    fn nil_guard_fact(&self, _message: &str, _subject: &str) -> Option<NormalizedNilGuardFact> {
        None
    }

    fn terminating_call_message(&self, _message: &str) -> bool {
        false
    }

    fn local_flow_assignment_operator(&self, operator: &str) -> bool {
        operator == "="
    }

    fn local_flow_declaration_keyword(&self, _keyword: &str) -> bool {
        false
    }

    fn local_flow_keyword(&self, _name: &str) -> bool {
        false
    }

    fn suppress_predicate_body_text(&self, _text: &str) -> bool {
        false
    }

    fn predicate_body_language_signal(&self, _text: &str) -> bool {
        false
    }

    fn semantic_effect_for_call(&self, _call: &CallSite) -> Option<NormalizedSemanticEffect> {
        None
    }

    fn core_owner_names(&self) -> &'static [&'static str] {
        &[]
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        _function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn rescue_semantic_effects(
        &self,
        _body: &Node,
        _resbody: &Node,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("T::Array[{}]", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("T::Hash[{}, {}]", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("T::Set[{}]", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None"
        {
            return type_text.to_string();
        }
        if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
            type_text.to_string()
        } else {
            format!("T.nilable({})", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "T.untyped".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "T::Array[T.untyped]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "T::Hash[T.untyped, T.untyped]".to_string()
    }
}

pub(crate) fn nil_guard_from_predicates(
    message: &str,
    subject: &str,
    nil_predicates: &[&str],
    non_nil_predicates: &[&str],
) -> Option<NormalizedNilGuardFact> {
    if nil_predicates.contains(&message) {
        return Some(NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: false,
        });
    }
    if non_nil_predicates.contains(&message) {
        return Some(NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: true,
        });
    }
    None
}

pub(crate) fn eliminable_guard_from_call(
    call: &CallSite,
    guard_messages: &[&str],
) -> Option<NormalizedSemanticEffect> {
    if call.receiver.is_empty() || !guard_messages.contains(&call.message.as_str()) {
        return None;
    }
    Some(NormalizedSemanticEffect {
        kind: "eliminable_guard".to_string(),
        detail: call.receiver.clone(),
    })
}

pub(crate) fn behavior(language: Language) -> &'static dyn NormalizedLanguageBehavior {
    match language {
        Language::Ruby => ruby::behavior(),
        Language::C => c::behavior(),
        Language::Cpp => cpp::behavior(),
        Language::Go => go::behavior(),
        Language::Java => java::behavior(),
        Language::JavaScript => javascript::behavior(),
        Language::CSharp => csharp::behavior(),
        Language::TypeScript => typescript::behavior(),
        Language::Kotlin => kotlin::behavior(),
        Language::Lua => lua::behavior(),
        Language::Php => php::behavior(),
        Language::Python => python::behavior(),
        Language::Rust => rust::behavior(),
        Language::Swift => swift::behavior(),
        Language::Zig => zig::behavior(),
    }
}

pub(crate) fn matching_paren_index(source: &str, open_index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, ch) in source
        .char_indices()
        .filter(|(index, _)| *index >= open_index)
    {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

pub(crate) fn method_param_types_from_signatures<B: NormalizedLanguageBehavior + ?Sized>(
    behavior: &B,
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    functions
        .iter()
        .filter_map(|function| {
            let parse = |declaration: &str| {
                let params = behavior.parameter_list_source(declaration);
                split_signature_parameters(&params)
                    .into_iter()
                    .filter_map(|parameter| {
                        let name = behavior.parameter_name_from_signature(&parameter)?;
                        let type_name = behavior.parameter_type_from_signature(&parameter)?;
                        (!type_name.trim().is_empty()).then_some((name, type_name))
                    })
                    .collect::<BTreeMap<_, _>>()
            };
            // Preserve the established single-line interpretation. Only
            // annotations and genuinely multiline declarations need the
            // source-span fallback.
            let first_line = source
                .lines()
                .nth(function.line.saturating_sub(1))
                .unwrap_or_default();
            let mut param_types = parse(first_line);
            if param_types.is_empty() {
                param_types = parse(&function_declaration_source(source, function)?);
            }
            (!param_types.is_empty()).then_some((
                method_parameter_type_key(&function.owner, &function.name, function.line),
                param_types,
            ))
        })
        .collect()
}

fn function_declaration_source(source: &str, function: &FunctionDef) -> Option<String> {
    let lines = source.lines().collect::<Vec<_>>();
    let start = function.line.saturating_sub(1).min(lines.len());
    let end = function.span[2].min(lines.len());
    let declaration_and_body = lines.get(start..end)?.join("\n");
    let name_start = declaration_and_body
        .match_indices(function.name.as_str())
        .find_map(|(index, _)| {
            let before = declaration_and_body[..index].chars().next_back();
            let after_index = index + function.name.len();
            let after = declaration_and_body[after_index..].chars().next();
            let identifier = |character: char| character == '_' || character.is_alphanumeric();
            if before.is_some_and(identifier) || after.is_some_and(identifier) {
                return None;
            }
            let suffix = declaration_and_body[after_index..].trim_start();
            (suffix.starts_with('(') || suffix.starts_with('<')).then_some(index)
        })?;
    Some(declaration_and_body[name_start..].to_string())
}

pub(crate) fn method_parameter_type_key(owner: &str, name: &str, line: usize) -> String {
    format!("{owner}\u{0}{name}\u{0}{line}")
}

fn split_signature_parameters(source: &str) -> Vec<String> {
    let mut params = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    for (index, character) in source.char_indices() {
        match character {
            '(' | '[' | '{' | '<' => depth += 1,
            ')' | ']' | '}' | '>' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                let parameter = source[start..index].trim();
                if !parameter.is_empty() {
                    params.push(parameter.to_string());
                }
                start = index + 1;
            }
            _ => {}
        }
    }
    let parameter = source[start..].trim();
    if !parameter.is_empty() {
        params.push(parameter.to_string());
    }
    params
}

/// Extract the declared type from C-family `Type name` parameters. Concrete
/// adapters decide that their grammar uses this shape; the shared helper only
/// handles token boundaries and common non-type modifiers.
pub(crate) fn type_before_parameter_name(parameter: &str) -> Option<String> {
    let text = parameter.split('=').next().unwrap_or(parameter).trim();
    let name = text
        .split_whitespace()
        .next_back()?
        .trim_matches(|ch: char| matches!(ch, '*' | '&' | '[' | ']' | ','))
        .trim_start_matches("...");
    if name.is_empty() {
        return None;
    }
    let name_index = text.rfind(name)?;
    let mut type_name = text[..name_index].trim();
    for modifier in ["final ", "ref ", "out ", "in ", "params ", "this "] {
        type_name = type_name.strip_prefix(modifier).unwrap_or(type_name);
    }
    let type_name = type_name.trim();
    (!type_name.is_empty()).then(|| type_name.to_string())
}

/// Extract the declared type from `name: Type` parameters. Languages opt in
/// explicitly; the shared helper does not assign meaning to colon syntax.
pub(crate) fn type_after_parameter_colon(parameter: &str) -> Option<String> {
    let declaration = parameter.split('=').next().unwrap_or(parameter).trim();
    let (_, type_name) = declaration.split_once(':')?;
    let type_name = type_name.trim();
    (!type_name.is_empty()).then(|| type_name.to_string())
}

fn usable_declared_local_type(type_name: &str) -> Option<String> {
    let type_name = type_name.trim();
    let lower = type_name.to_ascii_lowercase();
    (!type_name.is_empty()
        && !matches!(
            lower.as_str(),
            "any" | "auto" | "def" | "dynamic" | "let" | "unknown" | "var"
        ))
    .then(|| type_name.to_string())
}

/// Shared parser for declarations whose type precedes the local name, such
/// as Java/C#/C++ `final Service client = ...`. Languages opt in explicitly.
pub(crate) fn type_before_local_name(source: &str, name: &str) -> Option<String> {
    let name_start = source.match_indices(name).find_map(|(index, _)| {
        let before = source[..index].chars().next_back();
        let after = source[index + name.len()..].chars().next();
        let boundary = |character: Option<char>| {
            character.is_none_or(|character| !character.is_alphanumeric() && character != '_')
        };
        (boundary(before) && boundary(after)).then_some(index)
    })?;
    let mut prefix = source[..name_start]
        .rsplit([';', '{', '}'])
        .next()
        .unwrap_or_default()
        .trim();
    for control in ["for (", "foreach ("] {
        prefix = prefix.rsplit(control).next().unwrap_or(prefix).trim();
    }
    loop {
        let previous = prefix;
        for modifier in [
            "const ",
            "final ",
            "fixed ",
            "late ",
            "readonly ",
            "ref ",
            "scoped ",
            "static ",
            "using ",
            "volatile ",
        ] {
            prefix = prefix.strip_prefix(modifier).unwrap_or(prefix).trim();
        }
        if prefix == previous {
            break;
        }
    }
    usable_declared_local_type(prefix)
}

/// Shared parser for Python/TypeScript-style `name: Type` local annotations.
pub(crate) fn type_after_local_colon(source: &str, name: &str) -> Option<String> {
    let name_start = source.match_indices(name).find_map(|(index, _)| {
        let before = source[..index].chars().next_back();
        let after = source[index + name.len()..].chars().next();
        let boundary = |character: Option<char>| {
            character.is_none_or(|character| !character.is_alphanumeric() && character != '_')
        };
        (boundary(before) && boundary(after)).then_some(index)
    })?;
    let suffix = source[name_start + name.len()..].trim_start();
    let type_name = suffix.strip_prefix(':')?.trim_start();
    let type_name = type_name
        .split(['=', ';'])
        .next()
        .unwrap_or_default()
        .trim();
    usable_declared_local_type(type_name)
}

/// Shared parser for Go `var name Type` declarations. Short declarations are
/// inferred values and intentionally remain outside the declared-type fact.
pub(crate) fn type_after_go_local_name(source: &str, name: &str) -> Option<String> {
    let declaration = source.trim().strip_prefix("var ")?.trim();
    let suffix = declaration.strip_prefix(name)?.trim_start();
    let boundary = declaration[name.len()..].chars().next();
    if boundary.is_some_and(|character| character.is_alphanumeric() || character == '_') {
        return None;
    }
    let type_name = suffix.split(['=', ';']).next().unwrap_or_default().trim();
    usable_declared_local_type(type_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestBehavior;
    impl NormalizedLanguageBehavior for TestBehavior {}

    struct TestBehaviorOverride;
    impl NormalizedLanguageBehavior for TestBehaviorOverride {
        fn access_span_call_site(&self, _message: &str, _current_function: &str) -> bool {
            true
        }
    }

    #[test]
    fn test_default_behavior_methods() {
        let b = TestBehavior;
        let node = Node {
            r#type: "dummy".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };

        // call_site_span branches
        let parts = NormalizedCallParts {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
        };
        let full = [1, 0, 1, 10];
        let acc = [1, 0, 1, 5];
        assert_eq!(b.call_site_span(&node, &parts, full, acc, "func"), full);

        let bo = TestBehaviorOverride;
        assert_eq!(bo.call_site_span(&node, &parts, full, acc, "func"), acc);

        // other default trait methods with missing lines
        assert!(!b.emit_index_assignment_mutation(&node, None));
        assert_eq!(b.state_identity("First", "config"), "First::config");
        assert_eq!(b.state_identity("Second", "config"), "Second::config");
        assert_eq!(b.state_identity("", "config"), "");
        assert_eq!(b.self_member_receiver("m"), "m");
        assert!(b.owner_name_from_text(&node).is_none());
        assert!(b.literal_receiver_type(&node).is_none());
        assert_eq!(b.parameter_list_source("("), "");
        assert!(b.parameter_name_from_signature("").is_none());
        assert!(b.literal_state_refs(&node, "text").is_empty());
        assert!(b.nil_guard_fact("msg", "sub").is_none());
        assert!(!b.local_flow_declaration_keyword("key"));
        assert!(!b.local_flow_keyword("name"));
        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "".to_string(),
                message: "".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 0,
                span: [0, 0, 0, 0],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_none());
        assert!(b.core_owner_names().is_empty());
    }

    #[test]
    fn test_matching_paren_index_none() {
        assert!(matching_paren_index("(", 0).is_none());
    }

    #[test]
    fn all_language_configs_map_only_their_documented_operations() {
        let array = TypeExpr::Array(Box::new(TypeExpr::Untyped));
        let hash = TypeExpr::Hash {
            key: Box::new(TypeExpr::Untyped),
            value: Box::new(TypeExpr::Untyped),
        };
        let string = TypeExpr::Primitive("String".to_string());

        for (language, receiver, message, expected) in [
            (
                "ruby",
                &array,
                "include?",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "python",
                &array,
                "append",
                NormalizedCollectionOperation::Constant,
            ),
            (
                "javascript",
                &array,
                "shift",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "typescript",
                &array,
                "shift",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "java",
                &array,
                "contains",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "csharp",
                &array,
                "Remove",
                NormalizedCollectionOperation::LinearScan,
            ),
            ("go", &array, "len", NormalizedCollectionOperation::Constant),
            (
                "cpp",
                &array,
                "find",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "kotlin",
                &array,
                "contains",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "rust",
                &array,
                "binary_search",
                NormalizedCollectionOperation::Logarithmic,
            ),
            (
                "swift",
                &array,
                "sorted",
                NormalizedCollectionOperation::Sort,
            ),
            (
                "zig",
                &array,
                "append",
                NormalizedCollectionOperation::Constant,
            ),
        ] {
            assert_eq!(
                configured_collection_operation(language, receiver, message),
                Some(expected),
                "{language} {message}"
            );
        }
        assert_eq!(
            configured_collection_operation("php", &array, "unknown"),
            None
        );
        assert_eq!(
            configured_collection_operation("rust", &hash, "get"),
            Some(NormalizedCollectionOperation::Constant)
        );
        assert_eq!(
            configured_collection_operation("swift", &string, "count"),
            Some(NormalizedCollectionOperation::LinearScan)
        );
        for (language, receiver, message, expected) in [
            (
                "c",
                None,
                "strlen",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "c",
                None,
                "strcmp",
                NormalizedCollectionOperation::LinearScan,
            ),
            ("go", None, "len", NormalizedCollectionOperation::Constant),
            (
                "go",
                Some("strings"),
                "HasPrefix",
                NormalizedCollectionOperation::LinearScan,
            ),
            (
                "go",
                Some("slices"),
                "BinarySearch",
                NormalizedCollectionOperation::Logarithmic,
            ),
            (
                "go",
                Some("maps"),
                "Clone",
                NormalizedCollectionOperation::LinearMaterialize,
            ),
            (
                "go",
                Some("atomic"),
                "LoadInt64",
                NormalizedCollectionOperation::Constant,
            ),
            (
                "php",
                None,
                "array_map",
                NormalizedCollectionOperation::LinearMaterialize,
            ),
            (
                "lua",
                Some("table"),
                "sort",
                NormalizedCollectionOperation::Sort,
            ),
            (
                "java",
                Some("Collections"),
                "binarySearch",
                NormalizedCollectionOperation::Logarithmic,
            ),
            (
                "java",
                Some("Arrays"),
                "copyOf",
                NormalizedCollectionOperation::LinearMaterialize,
            ),
            (
                "java",
                Some("Math"),
                "sqrt",
                NormalizedCollectionOperation::Constant,
            ),
            (
                "csharp",
                Some("Array"),
                "BinarySearch",
                NormalizedCollectionOperation::Logarithmic,
            ),
            (
                "csharp",
                Some("Math"),
                "Sqrt",
                NormalizedCollectionOperation::Constant,
            ),
        ] {
            assert_eq!(
                configured_intrinsic_operation(language, receiver, message),
                Some(expected),
                "{language} {receiver:?}.{message}"
            );
        }
        assert_eq!(
            configured_intrinsic_operation("c", Some("project"), "strlen"),
            None
        );
        assert_eq!(
            configured_intrinsic_operation("javascript", Some("Object"), "keys"),
            None,
            "generic JavaScript object operations may invoke proxy or getter hooks"
        );
    }
}
