// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

#[allow(unused_macros)]
macro_rules! println {
    ($($arg:tt)*) => {
        if std::env::var("FACT_MINE_DEBUG").is_ok() {
            std::println!($($arg)*);
        }
    };
}

#[allow(unused_macros)]
macro_rules! eprintln {
    ($($arg:tt)*) => {
        if std::env::var("FACT_MINE_DEBUG").is_ok() {
            std::eprintln!($($arg)*);
        }
    };
}

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};

use super::normalized_behavior::{
    configured_collection_operation, configured_external_latency_bound,
    configured_intrinsic_call_complexity, configured_semantic_symbol_call_complexity,
    configured_semantic_symbol_kind, configured_semantic_symbol_parametric_cost,
    configured_stdlib_call_identity, eliminable_guard_from_call, matching_paren_index,
    method_parameter_type_key, BlockCallSemantics, CardinalityCallSemantics,
    CollectionAllocationSemantics, NormalizedCallComplexity, NormalizedCallParts,
    NormalizedCallProjection, NormalizedCollectionOperation, NormalizedLanguageBehavior,
    NormalizedNilGuardFact, NormalizedSemanticEffect, NormalizedVisibilityEvent, SyntaxMetadata,
};
use super::{CallSite, ExternalCallComplexity, FunctionDef, StateDeclaration};
use crate::ast::{self, Node, Span};
use crate::type_inference::TypeExpr;
use std::collections::{BTreeMap, BTreeSet};

fn scip_ruby_descriptor(symbol: &str) -> Option<&str> {
    let rest = symbol.strip_prefix("scip-ruby gem ")?;
    let mut fields = rest.splitn(3, ' ');
    fields.next()?; // gem name
    fields.next()?; // gem version
    fields.next()
}

fn ruby_descriptor_owner(descriptor: &str) -> Option<String> {
    let owner = descriptor.split_once('#')?.0.trim_matches('`');
    let owner = owner
        .strip_prefix("<Class:")
        .and_then(|owner| owner.strip_suffix('>'))
        .unwrap_or(owner);
    if owner.starts_with("Proc")
        && owner[4..]
            .chars()
            .all(|character| character.is_ascii_digit())
    {
        Some("Proc".to_string())
    } else {
        Some(owner.to_string())
    }
}

fn ruby_stdlib_descriptor(descriptor: &str, message: &str) -> bool {
    ruby_descriptor_owner(descriptor)
        .is_some_and(|owner| configured_stdlib_call_identity("ruby", Some(&owner), None, message))
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let descriptor = scip_ruby_descriptor(symbol)?;
    if !ruby_stdlib_descriptor(descriptor, message)
        || configured_semantic_symbol_parametric_cost("ruby", descriptor).is_some()
    {
        return None;
    }
    let owner = ruby_descriptor_owner(descriptor)?;
    let behavior = RubyNormalizedBehavior;
    let complexity = configured_semantic_symbol_call_complexity("ruby", descriptor)
        .or_else(|| behavior.call_complexity(&TypeExpr::Primitive(owner.clone()), message))
        .or_else(|| behavior.intrinsic_call_complexity(Some(&owner), message));
    if let Some(complexity) = complexity {
        return Some(ExternalCallComplexity {
            time: complexity.time,
            space: complexity.space,
            provenance: "ruby_stdlib_registry",
            bound_quality: "upper_bound_exact_target",
            candidates: Vec::new(),
            assumption: None,
        });
    }
    let complexity = configured_external_latency_bound("ruby", &owner, message)?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "ruby_external_effect_registry",
        bound_quality: "upper_bound_external_latency_excluded",
        candidates: Vec::new(),
        assumption: Some(
            "computational Big-O only; filesystem, process, stream, or terminal latency is excluded"
                .to_string(),
        ),
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> super::ExternalSymbolMetadata {
    let Some(descriptor) = scip_ruby_descriptor(symbol) else {
        return super::ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    let message = descriptor
        .rsplit_once('#')
        .map(|(_, member)| member)
        .unwrap_or_default()
        .trim_matches('`')
        .split('(')
        .next()
        .unwrap_or_default();
    if ruby_stdlib_descriptor(descriptor, message) {
        super::ExternalSymbolMetadata {
            scope: "stdlib",
            missing_cost_kind: configured_semantic_symbol_kind("ruby", descriptor)
                .unwrap_or_else(|| "stdlib_cost_model_missing".to_string()),
            parametric_cost: configured_semantic_symbol_parametric_cost("ruby", descriptor),
        }
    } else {
        super::ExternalSymbolMetadata {
            scope: "project_declaration",
            missing_cost_kind: "project_declaration_body_or_generated_member_missing".to_string(),
            parametric_cost: None,
        }
    }
}

const RUBY_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("Dir", &["pwd", "getwd", "home"]),
    ("Time", &["now", "current"]),
    ("Date", &["today", "current"]),
    ("DateTime", &["now", "current"]),
    ("Process", &["pid", "ppid", "uid", "gid", "euid"]),
    ("Thread", &["current", "list", "main"]),
    ("Fiber", &["current"]),
    ("Random", &["rand", "bytes"]),
    ("GC", &["stat", "count"]),
    ("ObjectSpace", &["each_object", "count_objects"]),
];

const RUBY_CALLBACK_SET: &[&str] = &[
    "transaction",
    "synchronize",
    "lock",
    "with_lock",
    "unlock",
    "mutex",
    "atomic",
    "reentrant",
    "subscribe",
    "callback",
    "hook",
];

const RUBY_ITERATION_METHODS: &[&str] = &[
    "each",
    "each_key",
    "each_value",
    "each_pair",
    "each_with_index",
    "each_with_object",
    "each_entry",
    "each_index",
    "each_slice",
    "each_cons",
    "each_char",
    "each_line",
    "cycle",
    "with_index",
    "with_object",
    "map",
    "map!",
    "collect",
    "collect!",
    "select",
    "reject",
    "filter",
    "filter_map",
    "flat_map",
    "group_by",
    "partition",
    "delete_if",
    "keep_if",
    "select!",
    "reject!",
    "sort_by",
    "sort_by!",
    "reverse_each",
    "times",
    "upto",
    "downto",
    "step",
    "any?",
    "all?",
    "none?",
    "one?",
    "count",
    "find",
    "find_index",
    "index",
    "rindex",
    "detect",
    "reduce",
    "inject",
    "sum",
    "min_by",
    "max_by",
    "uniq",
    "merge!",
    "to_h",
    "gsub",
    "scan",
    "loop",
    "transform_keys",
    "transform_keys!",
    "transform_values",
    "transform_values!",
];

const RUBY_ONCE_BLOCK_METHODS: &[&str] = &[
    "tap",
    "then",
    "yield_self",
    "synchronize",
    "with_lock",
    "transaction",
    "atomic",
    "reentrant",
];

const RUBY_CORE_CONSTS: &[&str] = &[
    "String",
    "Symbol",
    "Integer",
    "Float",
    "Numeric",
    "Rational",
    "Complex",
    "Array",
    "Hash",
    "Set",
    "Range",
    "Struct",
    "Object",
    "BasicObject",
    "Kernel",
    "Module",
    "Class",
    "Comparable",
    "Enumerable",
    "Enumerator",
    "Proc",
    "Method",
    "UnboundMethod",
    "NilClass",
    "TrueClass",
    "FalseClass",
    "Exception",
    "StandardError",
    "RuntimeError",
    "ArgumentError",
    "TypeError",
    "NameError",
    "NoMethodError",
    "IO",
    "File",
    "Dir",
    "Time",
    "Date",
    "DateTime",
    "Regexp",
    "MatchData",
    "Thread",
    "Mutex",
    "Fiber",
    "Process",
    "Math",
    "GC",
    "ObjectSpace",
    "Marshal",
    "Random",
    "Encoding",
];
const RUBY_GUARD_MIDS: &[&str] = &["is_a?", "kind_of?", "instance_of?", "nil?", "respond_to?"];

const RUBY_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "send",
        "__send__",
        "public_send",
        "const_get",
        "constantize",
        "instance_variable_get",
    ],
    meta_mids: &[
        "define_method",
        "define_singleton_method",
        "alias_method",
        "class_eval",
        "module_eval",
        "instance_eval",
        "class_exec",
        "module_exec",
        "instance_exec",
        "eval",
        "const_set",
        "instance_variable_set",
        "remove_method",
        "undef_method",
        "prepend",
        "singleton_class",
        "binding",
    ],
    method_obj_mids: &["method", "public_method", "instance_method"],
    io_consts: &[
        "File",
        "IO",
        "Dir",
        "FileUtils",
        "Open3",
        "Socket",
        "TCPSocket",
        "UDPSocket",
        "TCPServer",
        "UNIXSocket",
        "Tempfile",
        "Pathname",
        "Marshal",
    ],
    io_pairs: &[("URI", &["open"])],
    io_receiver_prefixes: &["Net::"],
    io_bare: &[
        "puts",
        "print",
        "warn",
        "gets",
        "readline",
        "readlines",
        "system",
        "exec",
        "spawn",
        "fork",
        "sleep",
        "open",
        "abort",
        "exit",
        "exit!",
    ],
    context_pairs: RUBY_CONTEXT_PAIRS,
    context_consts: &["ENV"],
    context_bare: &["rand", "srand"],
    callback_set: RUBY_CALLBACK_SET,
    callback_requires_block: false,
    // A trailing bang means "more dangerous than the non-bang form" in Ruby;
    // it does not prove mutation (checked accessors commonly use it too).
    bang_mutation: false,
};

// CFG-SPECIFIC START: Ruby control-flow vocabulary.
const RUBY_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "all",
        "any",
        "collect",
        "detect",
        "downto",
        "each",
        "each_cons",
        "each_entry",
        "each_key",
        "each_pair",
        "each_slice",
        "each_value",
        "filter_map",
        "find",
        "find_all",
        "flat_map",
        "inject",
        "loop",
        "map",
        "none",
        "reduce",
        "reject",
        "select",
        "step",
        "times",
        "upto",
    ],
    ignored_callback_body_sources: &["do end", "{}"],
};
// CFG-SPECIFIC END

pub(crate) struct RubyNormalizedBehavior;

impl NormalizedLanguageBehavior for RubyNormalizedBehavior {
    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        external_symbol_call_complexity(symbol, message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> super::ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let header = node.text.lines().next().unwrap_or(&node.text);
        header
            .split_once(" < ")
            .map(|(_, supertype)| super::normalized_behavior::split_declared_supertypes(supertype))
            .unwrap_or_default()
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("ruby")
    }

    fn reopenable_owner(&self, node: &Node) -> bool {
        matches!(node.r#type.as_str(), "CLASS" | "MODULE")
    }

    fn declared_type_hint_complete(&self, type_name: &str) -> bool {
        !type_name.contains("T.untyped")
    }

    fn function_dispatch_name(&self, name: &str) -> String {
        name.strip_prefix("self.").unwrap_or(name).to_string()
    }

    fn function_dispatch_kind(&self, name: &str, owner: &str) -> String {
        if name.starts_with("self.") {
            "class"
        } else if owner.is_empty() {
            "top"
        } else {
            "instance"
        }
        .to_string()
    }

    fn receiver_is_type_reference(&self, receiver: &str) -> bool {
        let receiver = receiver.strip_prefix("::").unwrap_or(receiver);
        !receiver.is_empty()
            && receiver.split("::").all(|segment| {
                segment
                    .chars()
                    .next()
                    .is_some_and(|first| first.is_ascii_uppercase())
                    && segment
                        .chars()
                        .all(|character| character.is_ascii_alphanumeric() || character == '_')
            })
    }

    fn constructor_dispatch_name(&self, receiver: &str, message: &str) -> Option<String> {
        (message == "new" && self.receiver_is_type_reference(receiver))
            .then(|| "initialize".to_string())
    }

    fn declarative_owner_constant_operations(&self, node: &Node) -> Vec<String> {
        let Some(value) = node.children.get(1).and_then(ast::node) else {
            return Vec::new();
        };
        let call = if value.r#type == "ITER" {
            value.children.first().and_then(ast::node).unwrap_or(value)
        } else {
            value
        };
        let receiver = call
            .children
            .first()
            .and_then(ast::node)
            .map(|node| node.text.as_str());
        let message = call.children.get(1).and_then(|child| match child {
            ast::Child::Symbol(value) | ast::Child::String(value) => Some(value.as_str()),
            _ => None,
        });
        match (receiver, message) {
            (Some("Struct"), Some("new")) => vec!["new", "[]", "[]="],
            (Some("Data"), Some("define")) => vec!["new"],
            _ => Vec::new(),
        }
        .into_iter()
        .map(ToString::to_string)
        .collect()
    }

    // CFG-SPECIFIC START: expose the Ruby CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &RUBY_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    // TYPE-INFERENCE-SPECIFIC: Ruby's normalized LIST/ARRAY vocabulary is
    // also used for call arguments. Only bracket-delimited nodes represent
    // source array literals and are eligible for tuple-shape facts.
    fn array_literal_node(&self, node: &Node) -> bool {
        node.text.trim_start().starts_with('[')
    }

    fn collection_allocation_semantics(&self, message: &str) -> CollectionAllocationSemantics {
        if [
            "map",
            "collect",
            "select",
            "reject",
            "filter",
            "filter_map",
            "group_by",
            "partition",
            "compact",
            "sort",
            "sort_by",
            "reverse",
            "to_a",
            "keys",
            "values",
            "transform_keys",
            "transform_values",
        ]
        .contains(&message)
        {
            CollectionAllocationSemantics::PreservesReceiver
        } else if ["flat_map", "flatten"].contains(&message) {
            CollectionAllocationSemantics::UnknownSize
        } else {
            CollectionAllocationSemantics::None
        }
    }

    fn block_call_semantics(&self, message: &str) -> BlockCallSemantics {
        if RUBY_ITERATION_METHODS.contains(&message) {
            BlockCallSemantics::Iteration
        } else if RUBY_ONCE_BLOCK_METHODS.contains(&message) {
            BlockCallSemantics::Once
        } else if ["lambda", "proc"].contains(&message) {
            BlockCallSemantics::Deferred
        } else {
            BlockCallSemantics::Unknown
        }
    }

    fn cardinality_call_semantics(&self, message: &str) -> CardinalityCallSemantics {
        if ["length", "size", "count"].contains(&message) {
            CardinalityCallSemantics::MeasuresReceiver
        } else if [
            "map",
            "map!",
            "collect",
            "collect!",
            "select",
            "reject",
            "filter",
            "filter_map",
            "flat_map",
            "compact",
            "flatten",
            "sort",
            "sort_by",
            "reverse",
            "to_a",
            "keys",
            "values",
            "transform_keys",
            "transform_keys!",
            "transform_values",
            "transform_values!",
        ]
        .contains(&message)
        {
            CardinalityCallSemantics::PreservesReceiver
        } else {
            CardinalityCallSemantics::Unknown
        }
    }

    fn iteration_yields_collection_value(&self, message: &str) -> bool {
        message == "each_value"
    }

    fn callback_parameter_names(&self, function: &Node) -> Vec<String> {
        fn collect(node: &Node, output: &mut BTreeSet<String>) {
            if node.r#type == "LASGN" && node.text.trim_start().starts_with('&') {
                if let Some(name) = node.children.first().and_then(|child| match child {
                    ast::Child::String(value) | ast::Child::Symbol(value) => Some(value.clone()),
                    _ => None,
                }) {
                    output.insert(name);
                }
            }
            for child in node.children.iter().filter_map(ast::node) {
                collect(child, output);
            }
        }

        let mut output = BTreeSet::new();
        collect(function, &mut output);
        output.into_iter().collect()
    }

    fn callback_invocation_message(&self, message: &str) -> bool {
        message == "call"
    }

    fn empty_check_call(&self, message: &str) -> bool {
        message == "empty?"
    }

    fn visited_membership_call(&self, message: &str) -> bool {
        ["include?", "contains"].contains(&message)
    }

    fn visited_insert_call(&self, message: &str) -> bool {
        ["add", "insert", "<<"].contains(&message)
    }

    fn empty_collection_constructor(&self, message: &str) -> bool {
        message == "new"
    }

    fn collection_parameter_type(&self, type_name: &str) -> bool {
        ["Array", "Hash", "Set", "Enumerable"]
            .iter()
            .any(|name| type_name.contains(name))
    }

    fn collection_operation(
        &self,
        receiver_type: &TypeExpr,
        message: &str,
    ) -> Option<NormalizedCollectionOperation> {
        configured_collection_operation("ruby", receiver_type, message)
    }

    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<NormalizedCallComplexity> {
        let sorbet_type_operation = receiver == Some("T")
            && [
                "any",
                "bind",
                "cast",
                "let",
                "must",
                "nilable",
                "proc",
                "type_parameter",
                "unsafe",
                "untyped",
            ]
            .contains(&message);
        let sorbet_generic_operation =
            receiver.is_some_and(|receiver| receiver.starts_with("T::")) && message == "[]";
        if sorbet_type_operation || sorbet_generic_operation {
            return Some(NormalizedCallComplexity {
                time: "O(1)",
                space: "O(1)",
            });
        }

        configured_intrinsic_call_complexity("ruby", receiver, message)
    }

    fn literal_receiver_type(&self, node: &Node) -> Option<TypeExpr> {
        match node.r#type.as_str() {
            "ARRAY" | "LIST" | "ZLIST" => Some(TypeExpr::Array(Box::new(TypeExpr::Untyped))),
            "HASH" => Some(TypeExpr::Hash {
                key: Box::new(TypeExpr::Untyped),
                value: Box::new(TypeExpr::Untyped),
            }),
            "STR" | "DSTR" => Some(TypeExpr::Primitive("String".to_string())),
            _ => None,
        }
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        owner: &str,
        _in_method: bool,
    ) -> Option<StateDeclaration> {
        if node.r#type != "IASGN" {
            return None;
        }
        let field = node.children.first().and_then(|child| match child {
            ast::Child::String(value) | ast::Child::Symbol(value) => Some(value.clone()),
            _ => None,
        })?;
        let value = node.children.get(1).and_then(ast::node)?;
        if !matches!(value.r#type.as_str(), "CALL" | "QCALL") {
            return None;
        }
        let receiver = value.children.first().and_then(ast::node)?;
        let message = value.children.get(1).and_then(|child| match child {
            ast::Child::String(value) | ast::Child::Symbol(value) => Some(value.as_str()),
            _ => None,
        })?;
        if receiver.text != "T" || message != "let" {
            return None;
        }
        let arguments = value.children.get(2).and_then(ast::node)?;
        let declared_type = arguments
            .children
            .iter()
            .filter_map(ast::node)
            .nth(1)?
            .text
            .trim()
            .to_string();
        if declared_type.is_empty() || declared_type == "T.untyped" {
            return None;
        }

        Some(StateDeclaration {
            field,
            owner: owner.to_string(),
            r#type: Some(declared_type),
            immutable: false,
            file: String::new(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        })
    }
    fn supports_parameter_normalization(&self) -> bool {
        true
    }

    fn static_call_return_type(
        &self,
        node: &Node,
        message: &str,
        receiver_type: Option<&str>,
    ) -> Option<String> {
        if message == "[]" {
            if let Some(r) = receiver_type {
                let r = r.trim();
                if (r.starts_with("T::Array[") || r.starts_with("Array[")) && r.ends_with(']') {
                    let prefix_len = if r.starts_with("T::Array[") { 9 } else { 6 };
                    let inner = &r[prefix_len..r.len() - 1];
                    let mut is_range = false;
                    let call_node = if node.r#type == "ITER" {
                        node.children.first().and_then(ast::node).unwrap_or(node)
                    } else {
                        node
                    };
                    if let Some(args_node) = call_node.children.get(2).and_then(ast::node) {
                        let first_arg = args_node.children.first().and_then(ast::node);
                        if let Some(arg) = first_arg {
                            if arg.r#type == "RANGE" || arg.r#type == "DOT2" || arg.r#type == "DOT3"
                            {
                                is_range = true;
                            }
                        }
                    }
                    if is_range {
                        return Some(format!("T::Array[{}]", inner));
                    } else {
                        return Some(wrap_nilable(inner));
                    }
                }
                if (r.starts_with("T::Hash[") || r.starts_with("Hash[")) && r.ends_with(']') {
                    let prefix_len = if r.starts_with("T::Hash[") { 8 } else { 5 };
                    let inner = &r[prefix_len..r.len() - 1];
                    if let Some((_, v)) = inner.split_once(", ") {
                        return Some(wrap_nilable(v.trim()));
                    }
                }
            }
        }
        None
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(
            message,
            "<<" | "[]="
                | "add"
                | "append"
                | "clear"
                | "collect!"
                | "compact!"
                | "concat"
                | "delete"
                | "delete_if"
                | "fill"
                | "filter!"
                | "flatten!"
                | "insert"
                | "keep_if"
                | "map!"
                | "merge!"
                | "move"
                | "prepend"
                | "push"
                | "reject!"
                | "replace"
                | "reverse!"
                | "rotate!"
                | "select!"
                | "shift"
                | "shuffle!"
                | "slice!"
                | "sort!"
                | "sort_by!"
                | "store"
                | "transform_keys!"
                | "transform_values!"
                | "uniq!"
                | "unshift"
                | "update"
                | "write"
        )
    }

    fn parameter_list_source(&self, source: &str) -> String {
        let first_line = source.lines().next().unwrap_or("");
        let Some(open_index) = first_line.find('(') else {
            return String::new();
        };
        let Some(close_index) = matching_paren_index(source, open_index) else {
            return String::new();
        };
        source[(open_index + 1)..close_index].to_string()
    }

    fn syntax_metadata(&self, source: &str, functions: &[FunctionDef]) -> SyntaxMetadata {
        let metadata = ruby_metadata(source, functions);
        SyntaxMetadata {
            immutable_struct_readers: metadata.immutable_struct_readers,
            immutable_struct_reader_types: metadata.immutable_struct_reader_types,
            type_aliases: metadata.type_aliases,
            type_alias_lines: metadata.type_alias_lines,
            method_param_types: metadata.method_param_types,
            method_local_types: BTreeMap::new(),
        }
    }

    fn suppress_self_call_state_read(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "self"
    }

    fn declarative_owner(
        &self,
        node: &Node,
        current_owner: &str,
    ) -> Option<super::normalized_behavior::NormalizedOwner> {
        if node.r#type != "LASGN" && node.r#type != "CASGN" {
            return None;
        }
        let var_name = node.children.iter().find_map(|child| match child {
            ast::Child::Symbol(value) | ast::Child::String(value) => Some(value.clone()),
            _ => None,
        })?;
        if var_name.is_empty() || !var_name.chars().next().unwrap().is_ascii_uppercase() {
            return None;
        }
        let val_node = node.children.get(1).and_then(ast::node)?;
        let actual_val = if val_node.r#type == "ITER" {
            val_node
                .children
                .first()
                .and_then(ast::node)
                .unwrap_or(val_node)
        } else {
            val_node
        };
        if actual_val.r#type == "CALL" || actual_val.r#type == "QCALL" {
            let receiver = actual_val.children.first().and_then(ast::node)?;
            let method = actual_val.children.get(1).and_then(|child| match child {
                ast::Child::Symbol(s) | ast::Child::String(s) => Some(s.clone()),
                _ => None,
            })?;
            if (method == "new" && receiver.text == "Struct")
                || (method == "define" && receiver.text == "Data")
            {
                let name = if current_owner.is_empty() {
                    var_name
                } else {
                    format!("{current_owner}::{var_name}")
                };
                return Some(super::normalized_behavior::NormalizedOwner {
                    name,
                    kind: "struct".to_string(),
                });
            }
        }
        None
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn clean_identifier(&self, token: &str) -> String {
        let t = token.strip_prefix("self.").unwrap_or(token);
        let t = t.strip_prefix('@').unwrap_or(t);
        let t = t.strip_prefix('$').unwrap_or(t);
        t.to_string()
    }

    fn clean_receiver(&self, receiver: &str) -> String {
        let t = receiver.replace('@', "");
        t.replace('$', "")
    }

    fn is_type_guard(&self, message: &str) -> bool {
        RUBY_GUARD_MIDS.contains(&message) && message != "nil?" && message != "respond_to?"
    }

    fn is_nil_check(&self, message: &str) -> bool {
        message == "nil?"
    }

    fn is_type_normalizer(&self, receiver: &str, message: &str) -> bool {
        receiver == "T" && message == "let"
    }

    fn is_type_cast(&self, receiver: &str, message: &str) -> bool {
        receiver == "T" && (message == "cast" || message == "must")
    }

    fn struct_declaration_fields(&self, node: &Node) -> Option<Vec<String>> {
        let val_node = node.children.get(1).and_then(ast::node)?;
        let actual_val = if val_node.r#type == "ITER" {
            val_node
                .children
                .first()
                .and_then(ast::node)
                .unwrap_or(val_node)
        } else {
            val_node
        };

        let args_node = actual_val.children.get(2).and_then(ast::node)?;
        let mut fields = Vec::new();
        for arg in &args_node.children {
            if let Some(arg_node) = ast::node(arg) {
                if arg_node.r#type == "LIT"
                    || arg_node.r#type == "SYMBOL"
                    || arg_node.r#type == "SYM"
                {
                    let field_name = arg_node.text.trim_start_matches(':').to_string();
                    if !field_name.is_empty() {
                        fields.push(field_name);
                    }
                }
            }
        }
        Some(fields)
    }

    fn known_return_type(&self, name: &str) -> Option<String> {
        match name {
            "puts" | "print" | "warn" => Some("NilClass".to_string()),
            "to_s" | "to_str" | "inspect" => Some("String".to_string()),
            "to_i" | "size" | "length" | "count" | "hash" => Some("Integer".to_string()),
            "to_f" => Some("Float".to_string()),
            "nil?" | "empty?" | "include?" | "any?" | "all?" | "none?" | "one?" | "key?"
            | "has_key?" | "!" => Some("T::Boolean".to_string()),
            _ => None,
        }
    }

    fn static_return_type(&self, message: &str, receiver_type: Option<&str>) -> Option<String> {
        let r = receiver_type.unwrap_or("T.untyped");
        let (_receiver_bare, _) = if r.starts_with("T.nilable(") && r.ends_with(')') {
            let bare = r["T.nilable(".len()..r.len() - 1].to_string();
            (bare, true)
        } else {
            (r.to_string(), false)
        };

        if message == "=="
            || message == "!="
            || message == "==="
            || message == ">>"
            || message == "<"
            || message == "<="
            || message == ">"
            || message == ">="
        {
            return Some("T::Boolean".to_string());
        }
        if message == "<=>" {
            return Some("T.nilable(Integer)".to_string());
        }
        if message == "hash" {
            return Some("Integer".to_string());
        }
        if message == "inspect" {
            return Some("String".to_string());
        }
        if message == "clone"
            || message == "dup"
            || message == "freeze"
            || message == "taint"
            || message == "untaint"
            || message == "+"
            || message == "-"
            || message == "*"
            || message == "/"
            || message == "%"
            || message == "**"
            || message == "&"
            || message == "|"
            || message == "^"
            || message == "~"
            || message == "+@"
            || message == "-@"
            || message == "<<"
        {
            return receiver_type.map(|t| t.to_string());
        }

        // Module#name is nil for anonymous classes and modules. Keep this Ruby
        // semantic in the language adapter so generic flow analysis does not
        // incorrectly declare safe-navigation on `self.class.name` dead.
        if message == "name" {
            return Some("T.nilable(String)".to_string());
        }
        if message == "to_s" || message == "to_str" {
            return Some("String".to_string());
        }
        if message == "to_sym" || message == "intern" {
            return Some("Symbol".to_string());
        }
        if message == "to_i"
            || message == "to_int"
            || message == "size"
            || message == "length"
            || message == "count"
        {
            return Some("Integer".to_string());
        }
        if message == "to_f" {
            return Some("Float".to_string());
        }
        if message == "to_a" || message == "to_ary" {
            return Some("T::Array[T.untyped]".to_string());
        }
        if message == "to_h" || message == "to_hash" {
            return Some("T::Hash[T.untyped, T.untyped]".to_string());
        }
        if message == "include?"
            || message == "empty?"
            || message == "nil?"
            || message == "is_a?"
            || message == "kind_of?"
            || message == "instance_of?"
            || message == "respond_to?"
            || message == "has_key?"
            || message == "key?"
            || message == "has_value?"
            || message == "value?"
            || message == "any?"
            || message == "all?"
            || message == "none?"
            || message == "one?"
        {
            return Some("T::Boolean".to_string());
        }
        if message == "class" {
            return Some("Class".to_string());
        }
        if r == "String" {
            if message == "upcase"
                || message == "downcase"
                || message == "capitalize"
                || message == "swapcase"
                || message == "strip"
                || message == "lstrip"
                || message == "rstrip"
                || message == "chomp"
                || message == "chop"
                || message == "gsub"
                || message == "sub"
                || message == "reverse"
            {
                return Some("String".to_string());
            }
            if message == "split" || message == "chars" || message == "lines" {
                return Some("T::Array[String]".to_string());
            }
        }
        None
    }

    fn propagated_collection_return_type(
        &self,
        message: &str,
        receiver_type: Option<&str>,
    ) -> Option<String> {
        let r = receiver_type.unwrap_or("T.untyped");
        if message == "concat" || message == "push" || message == "unshift" || message == "append" {
            return receiver_type.map(|t| t.to_string());
        }
        if (message == "first"
            || message == "last"
            || message == "pop"
            || message == "shift"
            || message == "sample")
            && r.starts_with("T::Array[")
            && r.ends_with(']')
        {
            let inner = &r[9..r.len() - 1];
            return Some(wrap_nilable(inner));
        }
        if message == "map"
            || message == "select"
            || message == "reject"
            || message == "filter"
            || message == "sort"
            || message == "split"
        {
            return Some("T::Array[T.untyped]".to_string());
        }
        if message == "compact" && r.starts_with("T::Array[") && r.ends_with(']') {
            let inner = &r[9..r.len() - 1];
            let no_nil = inner.trim_start_matches("T.nilable(").trim_end_matches(')');
            return Some(format!("T::Array[{}]", no_nil));
        }
        if message == "flatten" && r.starts_with("T::Array[T::Array[") {
            let inner = &r[18..r.len() - 2];
            return Some(format!("T::Array[{}]", inner));
        }
        if message == "keys" && r.starts_with("T::Hash[") {
            if let Some((k, _)) = r[8..r.len() - 1].split_once(", ") {
                return Some(format!("T::Array[{}]", k));
            }
        }
        if message == "values" && r.starts_with("T::Hash[") {
            if let Some((_, v)) = r[8..r.len() - 1].split_once(", ") {
                return Some(format!("T::Array[{}]", v));
            }
        }
        if message == "join" && (r.starts_with("T::Array[") || r == "Array") {
            return Some("String".to_string());
        }
        if message == "to_a"
            && (r.starts_with("T::Array[") || r.starts_with("T::Hash[") || r.starts_with("T::Set["))
        {
            return Some(r.to_string());
        }
        if message == "to_h" && (r.starts_with("T::Hash[") || r.starts_with("T::Array[")) {
            return Some(r.to_string());
        }
        None
    }

    fn is_noreturn_method(&self, message: &str) -> bool {
        message == "raise"
            || message == "fail"
            || message == "abort"
            || message == "exit"
            || message == "exit!"
            || message == "panic"
    }

    fn emit_index_call_site(&self, _node: &Node, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn emit_index_assignment_mutation(&self, _node: &Node, _field: Option<&str>) -> bool {
        true
    }

    fn emit_attribute_assignment_mutation(&self, _node: &Node, field: Option<&str>) -> bool {
        field != Some("[]")
    }

    fn preserve_constant_receiver_call(&self, call: &NormalizedCallProjection) -> bool {
        let base = call
            .receiver
            .trim_start_matches("::")
            .split("::")
            .next()
            .unwrap_or("");
        (call.receiver == "ENV")
            || RUBY_EFFECT_LEXICON
                .context_pairs
                .iter()
                .any(|(name, mids)| *name == base && mids.contains(&call.message.as_str()))
            || RUBY_EFFECT_LEXICON.io_consts.contains(&base)
            || RUBY_EFFECT_LEXICON
                .io_pairs
                .iter()
                .any(|(name, mids)| *name == base && mids.contains(&call.message.as_str()))
            || RUBY_EFFECT_LEXICON
                .io_receiver_prefixes
                .iter()
                .any(|prefix| call.receiver.starts_with(prefix))
            || (call.receiver == "T" && call.message == "type_alias")
            || RUBY_CORE_CONSTS.contains(&base)
    }

    fn branch_state_ref(
        &self,
        _node: &Node,
        _parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        Some(default_ref)
    }

    fn normalize_comparison_source(&self, source: &str) -> String {
        let mut text = source.trim().to_string();
        if let Some(rest) = text.strip_prefix('!') {
            text = rest
                .trim_start_matches('(')
                .trim_end_matches(')')
                .trim()
                .to_string();
        }
        if let Some(rest) = text.strip_prefix("self.") {
            text = rest.to_string();
        }
        if let Some(rest) = text.strip_prefix('@') {
            text = rest.to_string();
        }
        if let Some(dot_index) = text.find('.') {
            let receiver = &text[..dot_index];
            let rest = &text[(dot_index + 1)..];
            if simple_identifier(receiver)
                && (rest.contains(" == ") || rest.contains(" != ") || rest.contains('.'))
            {
                text = rest.to_string();
            }
        }
        crate::ast::normalize_text(&text)
    }

    fn accessor_declaration_methods(&self) -> &'static [(&'static str, bool, bool)] {
        &[
            ("attr_reader", true, false),
            ("attr_writer", false, true),
            ("attr_accessor", true, true),
        ]
    }

    fn visibility_events_from_calls(
        &self,
        calls: &[super::CallSite],
    ) -> Vec<NormalizedVisibilityEvent> {
        calls
            .iter()
            .filter(|call| {
                call.receiver == "self"
                    && matches!(call.message.as_str(), "public" | "protected" | "private")
            })
            .map(|call| NormalizedVisibilityEvent {
                owner: call.owner.clone(),
                visibility: call.message.clone(),
                line: call.line,
                target_names: call
                    .arguments
                    .iter()
                    .map(|argument| visibility_argument_name(argument))
                    .filter(|argument| !argument.is_empty())
                    .collect(),
            })
            .collect()
    }

    fn protocol_read_label_from_state(&self, receiver: &str, field: &str) -> Option<String> {
        let field = field
            .trim_start_matches('@')
            .trim_start_matches('$')
            .trim_end_matches(['?', '!']);
        if receiver.trim().is_empty() || receiver == "self" {
            Some(field.to_string())
        } else {
            Some(format!(
                "{}.{}",
                receiver.trim_start_matches('@').trim_start_matches('$'),
                field
            ))
        }
    }

    fn protocol_read_label_from_call(&self, receiver: &str, message: &str) -> Option<String> {
        (receiver == "self").then(|| message.trim_end_matches(['?', '!']).to_string())
    }

    fn protocol_write_label(&self, receiver: &str, field: &str) -> Option<String> {
        self.protocol_read_label_from_state(receiver, field)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        (message == "nil?").then(|| NormalizedNilGuardFact {
            local: subject.to_string(),
            non_nil_when_true: false,
        })
    }

    fn nil_comparison_operator(&self, operator: &str) -> bool {
        matches!(operator, "==" | "!=" | "===")
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "raise" | "fail" | "abort" | "exit" | "exit!")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, RUBY_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &RUBY_EFFECT_LEXICON))
            .or_else(|| {
                self.mutating_receiver_message(&call.message)
                    .then(|| NormalizedSemanticEffect {
                        kind: "hidden_mutation".to_string(),
                        detail: call.message.clone(),
                    })
            })
    }

    fn core_owner_names(&self) -> &'static [&'static str] {
        RUBY_CORE_CONSTS
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        matches!(
            name,
            "break"
                | "case"
                | "class"
                | "def"
                | "do"
                | "else"
                | "elsif"
                | "end"
                | "false"
                | "for"
                | "if"
                | "in"
                | "module"
                | "nil"
                | "private"
                | "protected"
                | "public"
                | "return"
                | "self"
                | "true"
                | "unless"
                | "while"
        )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text == "nil"
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        let lower = text.to_ascii_lowercase();
        lower.contains("nil") || lower.contains(" and ") || lower.contains(" or ")
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        node.is_class_or_module().then_some(default_span)
    }

    fn boolean_enclosing_span(
        &self,
        _node: &Node,
        node_span: Span,
        _decision_span: Option<Span>,
    ) -> Span {
        node_span
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        if matches!(function_name, "method_missing" | "respond_to_missing?") {
            vec![NormalizedSemanticEffect {
                kind: "metaprogramming".to_string(),
                detail: format!("def {function_name}"),
            }]
        } else {
            Vec::new()
        }
    }

    fn rescue_semantic_effects(
        &self,
        body: &Node,
        resbody: &Node,
    ) -> Vec<NormalizedSemanticEffect> {
        if ruby_nil_rescue_fallback(resbody) {
            vec![NormalizedSemanticEffect {
                kind: "eliminable_guard".to_string(),
                detail: ast::normalize_text(&body.text),
            }]
        } else {
            Vec::new()
        }
    }
}

static RUBY_BEHAVIOR: RubyNormalizedBehavior = RubyNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &RUBY_BEHAVIOR
}

fn ruby_nil_rescue_fallback(node: &Node) -> bool {
    if node.r#type == "NIL" {
        return true;
    }
    let children = node
        .children
        .iter()
        .filter_map(ast::node)
        .collect::<Vec<_>>();
    if node.r#type == "RESBODY" {
        if let Some(child) = children.get(1) {
            return ruby_nil_rescue_fallback(child);
        }
    }
    children.len() == 1 && ruby_nil_rescue_fallback(children[0])
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn visibility_argument_name(argument: &str) -> String {
    argument
        .trim()
        .trim_start_matches(':')
        .trim_matches('"')
        .trim_matches('\'')
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_string()
}

#[derive(Clone, Debug, Default)]
struct RubyMetadata {
    immutable_struct_readers: BTreeMap<String, Vec<String>>,
    immutable_struct_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    type_aliases: BTreeMap<String, String>,
    type_alias_lines: BTreeMap<String, usize>,
    method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

fn ruby_metadata(source: &str, functions: &[FunctionDef]) -> RubyMetadata {
    let (type_aliases, type_alias_lines) = type_alias_metadata(source);
    RubyMetadata {
        immutable_struct_readers: reader_sets_to_vecs(immutable_struct_reader_sets(
            source, functions,
        )),
        immutable_struct_reader_types: immutable_struct_reader_types(source, functions),
        type_aliases,
        type_alias_lines,
        method_param_types: method_param_types(source, functions),
    }
}

fn immutable_struct_reader_sets(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeSet<String>> {
    let mut readers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    // Exclude lambdas: a `factory: -> { [] }` default on a `prop`/`const` line
    // is an inline expression, not a method body, and must not mask the
    // struct-field line from this line-based reader.
    let method_ranges: Vec<(usize, usize)> = functions
        .iter()
        .filter(|f| f.dispatch_kind != "lambda")
        .map(|f| (f.span[0], f.span[2]))
        .collect();
    for (idx, line) in source.lines().enumerate() {
        let line_num = idx + 1;
        if method_ranges
            .iter()
            .any(|&(start, end)| line_num >= start && line_num <= end)
        {
            continue;
        }
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some(field) = stripped
                .strip_prefix("const :")
                .and_then(|rest| {
                    rest.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                        .next()
                })
                .filter(|field| !field.is_empty())
            {
                readers
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    readers
}

fn reader_sets_to_vecs(
    readers: BTreeMap<String, BTreeSet<String>>,
) -> BTreeMap<String, Vec<String>> {
    readers
        .into_iter()
        .map(|(owner, fields)| (owner, fields.into_iter().collect()))
        .collect()
}

fn immutable_struct_reader_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut reader_types: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    // Exclude lambdas: a `factory: -> { [] }` default on a `prop`/`const` line
    // is an inline expression, not a method body, and must not mask the
    // struct-field line from this line-based reader.
    let method_ranges: Vec<(usize, usize)> = functions
        .iter()
        .filter(|f| f.dispatch_kind != "lambda")
        .map(|f| (f.span[0], f.span[2]))
        .collect();
    for (idx, line) in source.lines().enumerate() {
        let line_num = idx + 1;
        if method_ranges
            .iter()
            .any(|&(start, end)| line_num >= start && line_num <= end)
        {
            continue;
        }
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            let mut line_rest = None;
            if let Some(rest) = stripped.strip_prefix("const :") {
                line_rest = Some(rest);
            } else if let Some(rest) = stripped.strip_prefix("prop :") {
                line_rest = Some(rest);
            }
            if let Some(rest) = line_rest {
                let parts = split_top_level_params_local(rest);
                if parts.len() >= 2 {
                    let field = parts[0].trim().trim_start_matches(':').trim();
                    let type_name = parts[1].trim();
                    let field_clean: String = field
                        .chars()
                        .filter(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    if !field_clean.is_empty() && is_valid_type(type_name) {
                        reader_types
                            .entry(owner.clone())
                            .or_default()
                            .insert(field_clean, type_name.to_string());
                    }
                }
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    reader_types
}

#[cfg(test)]
fn type_aliases(source: &str) -> BTreeMap<String, String> {
    type_alias_metadata(source).0
}

fn type_alias_metadata(source: &str) -> (BTreeMap<String, String>, BTreeMap<String, usize>) {
    let mut aliases = BTreeMap::new();
    let mut alias_lines = BTreeMap::new();
    let lines: Vec<&str> = source.lines().map(|l| l.trim()).collect();
    let mut owner_stack: Vec<String> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if line.is_empty() || line.starts_with('#') {
            i += 1;
            continue;
        }

        if line.starts_with("class ") || line.starts_with("module ") {
            let parts: Vec<&str> = line.split_whitespace().collect();
            let name = parts[1].trim_end_matches('<');
            let name = name.split('<').next().unwrap_or(name).trim();
            let qualified = if let Some(parent) = owner_stack.last() {
                if name.contains("::") {
                    name.to_string()
                } else {
                    format!("{parent}::{name}")
                }
            } else {
                name.to_string()
            };
            owner_stack.push(qualified);
            i += 1;
            continue;
        }

        if line == "end" {
            owner_stack.pop();
            i += 1;
            continue;
        }

        if let Some((name, rest)) = line.split_once('=') {
            let name = name.trim();
            if constant_path(name) {
                let rest = rest.trim();
                if rest.starts_with("T.type_alias") {
                    let mut target = String::new();
                    if rest.contains('{') {
                        let mut depth = 0;
                        let mut found_start = false;
                        let mut current_line = i;
                        let mut block_text = String::new();
                        while current_line < lines.len() {
                            let text = if current_line == i {
                                rest
                            } else {
                                lines[current_line]
                            };
                            for ch in text.chars() {
                                if ch == '{' {
                                    depth += 1;
                                    found_start = true;
                                    if depth == 1 {
                                        continue;
                                    }
                                } else if ch == '}' {
                                    depth -= 1;
                                    if depth == 0 {
                                        break;
                                    }
                                }
                                if found_start {
                                    block_text.push(ch);
                                }
                            }
                            if found_start && depth == 0 {
                                break;
                            }
                            current_line += 1;
                        }
                        target = block_text.trim().to_string();
                    } else if rest.contains(" do")
                        || rest.ends_with(" do")
                        || (i + 1 < lines.len() && lines[i + 1].starts_with("do"))
                    {
                        let mut current_line = i;
                        let mut block_lines = Vec::new();
                        let mut started = false;
                        while current_line < lines.len() {
                            let text = if current_line == i {
                                rest
                            } else {
                                lines[current_line]
                            };
                            if !started {
                                if let Some((_, right)) = text.split_once("do") {
                                    let right_trimmed = right.trim();
                                    if !right_trimmed.is_empty() {
                                        block_lines.push(right_trimmed);
                                    }
                                    started = true;
                                }
                            } else {
                                if text == "end"
                                    || text.starts_with("end ")
                                    || text.ends_with(" end")
                                {
                                    let (left, _) = text.split_once("end").unwrap();
                                    let left_trimmed = left.trim();
                                    if !left_trimmed.is_empty() {
                                        block_lines.push(left_trimmed);
                                    }
                                    break;
                                }
                                block_lines.push(text);
                            }
                            current_line += 1;
                        }
                        target = block_lines.join(" ").trim().to_string();
                    } else {
                        let parts: Vec<&str> = rest.split_whitespace().collect();
                        if parts.len() > 1 {
                            target = parts[1..].join(" ").trim().to_string();
                        }
                    }

                    if target.is_empty() {
                        i += 1;
                        continue;
                    }
                    let qualified_name = if let Some(parent) = owner_stack.last() {
                        format!("{parent}::{name}")
                    } else {
                        name.to_string()
                    };
                    alias_lines.insert(qualified_name.clone(), i + 1);
                    aliases.insert(qualified_name, target);
                }
            }
        }
        i += 1;
    }
    (aliases, alias_lines)
}

fn method_param_types(
    source: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, BTreeMap<String, String>> {
    functions
        .iter()
        .map(|function| {
            (
                method_parameter_type_key(&function.owner, &function.name, function.line),
                sig_param_types(source, function.line),
            )
        })
        .filter(|(_, param_types)| !param_types.is_empty())
        .collect()
}

fn is_valid_type(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return false;
    }
    trimmed.starts_with(|c: char| c.is_ascii_uppercase())
        || trimmed.starts_with("T.")
        || trimmed.starts_with("::")
}

fn split_top_level_params_local(params: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0u32;
    let mut start = 0usize;
    for (i, c) in params.char_indices() {
        match c {
            '(' | '<' | '[' | '{' => depth += 1,
            ')' | '>' | ']' | '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                out.push(params[start..i].to_string());
                start = i + 1;
            }
            _ => {}
        }
    }
    let remainder = params[start..].trim().to_string();
    if !remainder.is_empty() {
        out.push(remainder);
    }
    out
}

fn sig_param_types(source: &str, function_line: usize) -> BTreeMap<String, String> {
    let lines = source.lines().collect::<Vec<_>>();
    let mut sig_lines = Vec::new();
    let mut cursor = function_line.saturating_sub(2);
    while let Some(line) = lines.get(cursor) {
        let stripped = line.trim();
        if stripped.starts_with("def ")
            || stripped.starts_with("class ")
            || stripped.starts_with("module ")
        {
            return BTreeMap::new();
        }
        if !stripped.is_empty() {
            sig_lines.push(*line);
        }
        if stripped.starts_with("sig") {
            break;
        }
        if cursor == 0 {
            break;
        }
        cursor -= 1;
    }
    sig_lines.reverse();
    let sig = sig_lines.join("\n");
    if !sig.trim_start().starts_with("sig") {
        return BTreeMap::new();
    }
    let marker = "params(";
    let Some(params_start_idx) = sig.find(marker) else {
        return BTreeMap::new();
    };
    let inner = &sig[params_start_idx + marker.len()..];
    let mut depth = 1u32;
    let mut params_end_idx = None;
    for (i, c) in inner.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    params_end_idx = Some(i);
                    break;
                }
            }
            _ => {}
        }
    }
    let Some(end_idx) = params_end_idx else {
        return BTreeMap::new();
    };
    let params_str = &inner[..end_idx];

    let mut out = BTreeMap::new();
    for entry in split_top_level_params_local(params_str) {
        if let Some((name, type_name)) = entry.split_once(':') {
            let name = name.trim();
            let type_name = type_name.trim();
            if identifier(name) && is_valid_type(type_name) {
                out.insert(name.to_string(), type_name.to_string());
            }
        }
    }
    out
}

fn identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(ch) if ch == '_' || ch.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn constant_path(value: &str) -> bool {
    value.split("::").all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}

fn wrap_nilable(ty: &str) -> String {
    let t = ty.trim();
    if t == "T.untyped" || t == "NilClass" || t.starts_with("T.nilable(") {
        t.to_string()
    } else {
        format!("T.nilable({t})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::normalized_behavior::NormalizedLanguageBehavior;

    #[test]
    fn ruby_behavior_edge_cases() {
        let behavior = RubyNormalizedBehavior;

        assert_eq!(
            behavior.collection_allocation_semantics("map"),
            CollectionAllocationSemantics::PreservesReceiver
        );
        assert_eq!(
            behavior.collection_allocation_semantics("flatten"),
            CollectionAllocationSemantics::UnknownSize
        );
        assert_eq!(
            behavior.collection_allocation_semantics("each"),
            CollectionAllocationSemantics::None
        );
        assert_eq!(behavior.core_owner_names(), RUBY_CORE_CONSTS);
        assert_eq!(behavior.self_member_receiver("foo"), "self.foo");

        // Test local_flow_keyword
        assert!(behavior.local_flow_keyword("break"));
        assert!(behavior.local_flow_keyword("return"));
        assert!(!behavior.local_flow_keyword("my_var"));

        // sig_param_types syntax error fallback (params_end not found)
        let param_types = sig_param_types("sig { params(x: String", 1);
        assert!(param_types.is_empty());

        // type_aliases edge cases
        let aliases = type_aliases(
            r#"
            TopLevelAlias = T.type_alias { String }
            module Parent
              class Nested::Child
                MyAlias1 = T.type_alias { T.any(String, Integer) }
                MyAlias2 = T.type_alias {
                  T.any(
                    String,
                    Integer
                  )
                }
                MyAlias3 = T.type_alias do T.any(String, Integer) end
                MyAlias4 = T.type_alias do
                  T.any(String, Integer) end
                # Trigger right_trimmed.is_empty() and left_trimmed.is_empty()
                MyAlias5 = T.type_alias do
                  T.any(String, Integer)
                end
                # Trigger split_once("do") returning None
                MyAlias6 = T.type_alias
                do
                  T.any(String, Integer)
                end
              end
            end
            class 
            module 
            "#,
        );
        assert_eq!(aliases.len(), 7);
        assert!(aliases.contains_key("TopLevelAlias"));
        assert!(aliases.contains_key("Nested::Child::MyAlias1"));
        assert!(aliases.contains_key("Nested::Child::MyAlias2"));
        assert!(aliases.contains_key("Nested::Child::MyAlias3"));
        assert!(aliases.contains_key("Nested::Child::MyAlias4"));
        assert!(aliases.contains_key("Nested::Child::MyAlias5"));
        assert!(aliases.contains_key("Parent::MyAlias6"));
        assert!(!aliases.contains_key("Nested::Child::MyAliasEmpty"));
    }

    #[test]
    fn sig_param_types_accepts_long_multiline_signatures() {
        let source = r#"sig do
    params(
      first: String,
      second: Integer,
      third: Symbol,
      fourth: T::Boolean,
      fifth: T.nilable(String),
      sixth: T::Array[String],
      seventh: T::Hash[String, Integer],
      eighth: Float,
      ninth: Object,
      tenth: Numeric,
      eleventh: BasicObject,
      twelfth: Exception,
      thirteenth: Thread,
      weak: T::Array[T.untyped]
    ).void
  end
  def call(first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh, twelfth, thirteenth)
  end"#;

        let param_types = sig_param_types(source, 18);

        assert_eq!(param_types.get("first").map(String::as_str), Some("String"));
        assert_eq!(
            param_types.get("thirteenth").map(String::as_str),
            Some("Thread")
        );
        assert_eq!(
            param_types.get("weak").map(String::as_str),
            Some("T::Array[T.untyped]")
        );
        assert_eq!(param_types.len(), 14);
    }

    #[test]
    fn test_ruby_behavior_uncovered_methods() {
        use crate::syntax::Child;
        let behavior = RubyNormalizedBehavior;

        // format_array_type etc
        assert_eq!(behavior.format_array_type("String"), "T::Array[String]");
        assert_eq!(
            behavior.format_hash_type("Symbol", "Integer"),
            "T::Hash[Symbol, Integer]"
        );
        assert_eq!(behavior.format_set_type("String"), "T::Set[String]");
        assert_eq!(behavior.untyped_type(), "T.untyped");
        assert_eq!(behavior.untyped_array_type(), "T::Array[T.untyped]");
        assert_eq!(
            behavior.untyped_hash_type(),
            "T::Hash[T.untyped, T.untyped]"
        );
        for message in [
            "each_pair",
            "with_index",
            "index",
            "to_h",
            "gsub",
            "transform_values",
        ] {
            assert_eq!(
                behavior.block_call_semantics(message),
                BlockCallSemantics::Iteration
            );
        }
        assert_eq!(
            behavior.block_call_semantics("lambda"),
            BlockCallSemantics::Deferred
        );
        assert_eq!(
            behavior.block_call_semantics("proc"),
            BlockCallSemantics::Deferred
        );
        let array = TypeExpr::Array(Box::new(TypeExpr::Primitive("String".into())));
        let hash = TypeExpr::Hash {
            key: Box::new(TypeExpr::Primitive("String".into())),
            value: Box::new(TypeExpr::Primitive("Integer".into())),
        };
        let set = TypeExpr::Set(Box::new(TypeExpr::Primitive("String".into())));
        let string = TypeExpr::Primitive("String".into());
        for message in ["[]", "include?", "each", "map", "sort", "-"] {
            assert!(
                behavior.call_complexity(&array, message).is_some(),
                "Array##{message}"
            );
        }
        for message in ["[]", "each_value", "keys", "sort"] {
            assert!(
                behavior.call_complexity(&hash, message).is_some(),
                "Hash##{message}"
            );
        }
        for message in ["include?", "each", "map"] {
            assert!(
                behavior.call_complexity(&set, message).is_some(),
                "Set##{message}"
            );
        }
        for message in ["length", "split"] {
            assert!(
                behavior.call_complexity(&string, message).is_some(),
                "String##{message}"
            );
        }
        assert!(behavior
            .call_complexity(&TypeExpr::Primitive("T::Array".into()), "concat")
            .is_some());
        assert!(behavior
            .call_complexity(&TypeExpr::Nilable(Box::new(hash)), "key?")
            .is_some());
        assert!(behavior.call_complexity(&array, "mystery").is_none());
        assert!(behavior
            .call_complexity(&TypeExpr::Untyped, "each")
            .is_none());
        assert!(behavior.iteration_yields_collection_value("each_value"));
        assert!(!behavior.iteration_yields_collection_value("each_pair"));

        // format_nilable_type
        assert_eq!(behavior.format_nilable_type(""), "");
        assert_eq!(behavior.format_nilable_type("nil"), "nil");
        assert_eq!(
            behavior.format_nilable_type("T.nilable(String)"),
            "T.nilable(String)"
        );
        assert_eq!(behavior.format_nilable_type("String"), "T.nilable(String)");

        // clean_identifier / clean_receiver
        assert_eq!(behavior.clean_identifier("self.foo"), "foo");
        assert_eq!(behavior.clean_receiver("@foo"), "foo");

        // known_return_type
        assert_eq!(
            behavior.known_return_type("puts"),
            Some("NilClass".to_string())
        );
        assert_eq!(
            behavior.known_return_type("to_s"),
            Some("String".to_string())
        );
        assert_eq!(
            behavior.known_return_type("size"),
            Some("Integer".to_string())
        );
        assert_eq!(
            behavior.known_return_type("to_f"),
            Some("Float".to_string())
        );
        assert_eq!(
            behavior.known_return_type("nil?"),
            Some("T::Boolean".to_string())
        );
        assert_eq!(behavior.known_return_type("invalid"), None);

        // static_return_type
        assert_eq!(
            behavior.static_return_type("<=>", None),
            Some("T.nilable(Integer)".to_string())
        );
        assert_eq!(
            behavior.static_return_type("hash", None),
            Some("Integer".to_string())
        );
        assert_eq!(
            behavior.static_return_type("inspect", None),
            Some("String".to_string())
        );
        assert_eq!(
            behavior.static_return_type("to_sym", None),
            Some("Symbol".to_string())
        );
        assert_eq!(
            behavior.static_return_type("to_f", None),
            Some("Float".to_string())
        );
        assert_eq!(
            behavior.static_return_type("to_a", None),
            Some("T::Array[T.untyped]".to_string())
        );
        assert_eq!(
            behavior.static_return_type("to_h", None),
            Some("T::Hash[T.untyped, T.untyped]".to_string())
        );
        assert_eq!(
            behavior
                .propagated_collection_return_type("compact", Some("T::Array[T.nilable(String)]")),
            Some("T::Array[String]".to_string())
        );
        assert_eq!(
            behavior
                .propagated_collection_return_type("flatten", Some("T::Array[T::Array[String]]")),
            Some("T::Array[String]".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("keys", Some("T::Hash[Symbol, Integer]")),
            Some("T::Array[Symbol]".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("values", Some("T::Hash[Symbol, Integer]")),
            Some("T::Array[Integer]".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("to_a", Some("T::Array[String]")),
            Some("T::Array[String]".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("to_h", Some("T::Hash[Symbol, Integer]")),
            Some("T::Hash[Symbol, Integer]".to_string())
        );

        // is_noreturn_method
        assert!(behavior.is_noreturn_method("raise"));
        assert!(!behavior.is_noreturn_method("other"));

        // struct_declaration_fields
        let symbol_node = Node {
            r#type: "SYM".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: ":x".to_string(),
        };
        let args_node = Node {
            r#type: "ARGS".to_string(),
            children: vec![Child::Node(Box::new(symbol_node))],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "(:x)".to_string(),
        };
        let call_node = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "IDENT".to_string(),
                    children: Vec::new(),
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 4,
                    text: "new".to_string(),
                })),
                Child::Node(Box::new(Node {
                    r#type: "IDENT".to_string(),
                    children: Vec::new(),
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 4,
                    text: "new".to_string(),
                })),
                Child::Node(Box::new(args_node)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "new(:x)".to_string(),
        };
        let struct_node = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "IDENT".to_string(),
                    children: Vec::new(),
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 4,
                    text: "Struct".to_string(),
                })),
                Child::Node(Box::new(call_node)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "Struct = Struct.new(:x)".to_string(),
        };
        let fields = behavior.struct_declaration_fields(&struct_node).unwrap();
        assert_eq!(fields, vec!["x".to_string()]);

        // immutable_struct_reader_sets
        let mock_body = crate::ast::RawNode {
            kind: String::new(),
            text: String::new(),
            span: [0, 0, 0, 0],
            named: false,
            field_name: None,
            children: Vec::new(),
        };
        let mock_fn = FunctionDef {
            file: "foo.rb".to_string(),
            name: "bar".to_string(),
            owner: "Parent".to_string(),
            dispatch_kind: "instance".to_string(),
            line: 5,
            span: [5, 0, 7, 0],
            body: mock_body.clone(),
            visibility: None,
            params: Vec::new(),
            callback_params: Vec::new(),
            signature: String::new(),
        };
        let reader_sets = immutable_struct_reader_sets("class Parent; end", &[mock_fn]);
        assert!(reader_sets.is_empty());

        fn node(kind: &str, text: &str) -> Node {
            Node {
                r#type: kind.to_string(),
                children: Vec::new(),
                first_lineno: 10,
                first_column: 0,
                last_lineno: 10,
                last_column: text.len(),
                text: text.to_string(),
            }
        }

        // static_return_type string chars and lines
        assert_eq!(
            behavior.static_return_type("chars", Some("String")),
            Some("T::Array[String]".to_string())
        );
        assert_eq!(
            behavior.static_return_type("lines", Some("String")),
            Some("T::Array[String]".to_string())
        );

        // propagated_collection_return_type skipped blocks
        assert_eq!(
            behavior.propagated_collection_return_type("compact", Some("Integer")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("flatten", Some("Integer")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("keys", Some("Integer")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("values", Some("Integer")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("to_a", Some("Integer")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("to_h", Some("Integer")),
            None
        );

        // static_call_return_type for Arrays, Hashes, and Iters
        let index_arg = Node {
            r#type: "RANGE".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "1..3".to_string(),
        };
        let args_node_array = Node {
            r#type: "ARGS".to_string(),
            children: vec![Child::Node(Box::new(index_arg))],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "(1..3)".to_string(),
        };
        let lookup_node = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "arr"))),
                Child::Node(Box::new(node("IDENT", "[]"))),
                Child::Node(Box::new(args_node_array)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "arr[1..3]".to_string(),
        };
        assert_eq!(
            behavior.static_call_return_type(&lookup_node, "[]", Some("T::Array[String]")),
            Some("T::Array[String]".to_string())
        );

        // Iter / block lookup
        let iter_node = Node {
            r#type: "ITER".to_string(),
            children: vec![Child::Node(Box::new(lookup_node))],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "arr[1..3] { }".to_string(),
        };
        assert_eq!(
            behavior.static_call_return_type(&iter_node, "[]", Some("T::Array[String]")),
            Some("T::Array[String]".to_string())
        );

        // Hash split_once None path
        let simple_lookup = Node {
            r#type: "CALL".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "hash[x]".to_string(),
        };
        assert_eq!(
            behavior.static_call_return_type(&simple_lookup, "[]", Some("T::Hash[Invalid]")),
            None
        );
        assert_eq!(
            behavior.static_call_return_type(&simple_lookup, "[]", Some("T::Array[String]")),
            Some("T.nilable(String)".to_string())
        );

        // parameter_list_source no closing parenthesis
        assert_eq!(behavior.parameter_list_source("def foo(a"), "");

        // declarative_owner fallback paths
        let invalid_lasgn = Node {
            r#type: "LASGN".to_string(),
            children: vec![Child::Integer(123)],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "x = 1".to_string(),
        };
        assert!(behavior.declarative_owner(&invalid_lasgn, "").is_none());

        let invalid_call = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "Struct"))),
                Child::Integer(123),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "Struct.new".to_string(),
        };
        let lasgn_with_invalid_call = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Symbol("MyAlias".to_string()),
                Child::Node(Box::new(invalid_call)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "MyAlias = Struct.new".to_string(),
        };
        assert!(behavior
            .declarative_owner(&lasgn_with_invalid_call, "")
            .is_none());

        // struct_declaration_fields non-node children
        let invalid_args = Node {
            r#type: "ARGS".to_string(),
            children: vec![
                Child::Integer(123),
                Child::Node(Box::new(node("IDENT", "not_a_symbol"))),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "(123)".to_string(),
        };
        let invalid_call_for_struct = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "new"))),
                Child::Node(Box::new(node("IDENT", "new"))),
                Child::Node(Box::new(invalid_args)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "new(123)".to_string(),
        };
        let invalid_struct_node = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "Struct"))),
                Child::Node(Box::new(invalid_call_for_struct)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "Struct = Struct.new(123)".to_string(),
        };
        assert!(behavior
            .struct_declaration_fields(&invalid_struct_node)
            .unwrap()
            .is_empty());

        // keys and values fallback coverage
        assert_eq!(
            behavior.propagated_collection_return_type("keys", Some("T::Hash[Invalid]")),
            None
        );
        assert_eq!(
            behavior.propagated_collection_return_type("values", Some("T::Hash[Invalid]")),
            None
        );

        // index lookup empty args
        let empty_args_node = Node {
            r#type: "ARGS".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "()".to_string(),
        };
        let lookup_empty_args = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "arr"))),
                Child::Node(Box::new(node("IDENT", "[]"))),
                Child::Node(Box::new(empty_args_node)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "arr[]".to_string(),
        };
        assert_eq!(
            behavior.static_call_return_type(&lookup_empty_args, "[]", Some("T::Array[String]")),
            Some("T.nilable(String)".to_string())
        );

        // is_valid_type
        assert!(!is_valid_type(""));
        assert!(!is_valid_type("lowercase"));
        assert!(is_valid_type("T.foo"));
        assert!(behavior.declared_type_hint_complete("T::Array[String]"));
        assert!(!behavior.declared_type_hint_complete("T.untyped"));
        assert!(!behavior.declared_type_hint_complete("T::Array[T.untyped]"));

        // parameter_list_source success path
        assert_eq!(behavior.parameter_list_source("def foo(a, b)"), "a, b");

        // declarative_owner with non-empty current_owner
        let struct_with_owner = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Symbol("MyStruct".to_string()),
                Child::Node(Box::new(Node {
                    r#type: "CALL".to_string(),
                    children: vec![
                        Child::Node(Box::new(node("IDENT", "Struct"))),
                        Child::Symbol("new".to_string()),
                    ],
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 4,
                    text: "Struct.new".to_string(),
                })),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "MyStruct = Struct.new".to_string(),
        };
        assert_eq!(
            behavior
                .declarative_owner(&struct_with_owner, "MyModule")
                .unwrap()
                .name,
            "MyModule::MyStruct"
        );

        // struct_declaration_fields with ITER
        let call_in_iter = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("IDENT", "Struct"))),
                Child::Symbol("new".to_string()),
                Child::Node(Box::new(Node {
                    r#type: "ARGS".to_string(),
                    children: vec![Child::Node(Box::new(node("SYM", ":x")))],
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 4,
                    text: "(:x)".to_string(),
                })),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "Struct.new(:x)".to_string(),
        };
        let iter_with_call = Node {
            r#type: "ITER".to_string(),
            children: vec![Child::Node(Box::new(call_in_iter))],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "Struct.new(:x) { }".to_string(),
        };
        let struct_decl_with_iter = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Symbol("MyStruct".to_string()),
                Child::Node(Box::new(iter_with_call)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "MyStruct = Struct.new(:x) { }".to_string(),
        };
        assert_eq!(
            behavior.struct_declaration_fields(&struct_decl_with_iter),
            Some(vec!["x".to_string()])
        );

        // struct_declaration_fields empty ITER
        let empty_iter = Node {
            r#type: "ITER".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: " { }".to_string(),
        };
        let struct_decl_empty_iter = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Symbol("MyStruct".to_string()),
                Child::Node(Box::new(empty_iter)),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 4,
            text: "MyStruct = { }".to_string(),
        };
        assert!(behavior
            .struct_declaration_fields(&struct_decl_empty_iter)
            .is_none());

        // static_return_type nilable receiver and comparison / conversion operators
        assert_eq!(
            behavior.static_return_type("==", Some("T.nilable(String)")),
            Some("T::Boolean".to_string())
        );
        assert_eq!(
            behavior.static_return_type("to_i", None),
            Some("Integer".to_string())
        );
        assert_eq!(
            behavior.static_return_type("class", None),
            Some("Class".to_string())
        );
        assert_eq!(
            behavior.static_return_type("name", Some("Class")),
            Some("T.nilable(String)".to_string())
        );
        assert_eq!(
            behavior.static_return_type("upcase", Some("String")),
            Some("String".to_string())
        );

        // propagated_collection_return_type first and join
        assert_eq!(
            behavior.propagated_collection_return_type("first", Some("T::Array[String]")),
            Some("T.nilable(String)".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("join", Some("T::Array[String]")),
            Some("String".to_string())
        );
        assert_eq!(
            behavior.propagated_collection_return_type("join", Some("Array")),
            Some("String".to_string())
        );

        // type alias blank target / invalid type / blank type declaration
        let mock_fn_for_sig = FunctionDef {
            file: "foo.rb".to_string(),
            name: "bar".to_string(),
            owner: "Parent".to_string(),
            dispatch_kind: "instance".to_string(),
            line: 8,
            span: [8, 0, 10, 0],
            body: mock_body.clone(),
            visibility: None,
            params: Vec::new(),
            callback_params: Vec::new(),
            signature: String::new(),
        };

        let metadata = ruby_metadata(
            "
            MyAliasEmpty = T.type_alias
            MyAlias = T.type_alias { String }
            class Parent < T::Struct
              const :x
              const :y, lowercase
              sig { params(x: T.any(Integer, String), y: T::Hash[Symbol, String]) }
              def bar
              end
            end
            ",
            &[mock_fn_for_sig],
        );
        assert!(metadata.type_aliases.contains_key("MyAlias"));
    }

    #[test]
    fn scip_ruby_symbols_use_proven_core_identity() {
        let length = "scip-ruby gem clear-compiler workspace Array#length().";
        let file = "scip-ruby gem clear-compiler workspace `<Class:File>`#join().";
        let generated = "scip-ruby gem clear-compiler workspace AST#BinaryOp#left().";

        assert_eq!(
            external_symbol_call_complexity(length, "length").map(|complexity| complexity.time),
            Some("O(1)")
        );
        assert_eq!(
            external_symbol_call_complexity(file, "join").map(|complexity| complexity.time),
            Some("O(N)")
        );
        assert_eq!(external_symbol_metadata(length).scope, "stdlib");
        assert_eq!(
            external_symbol_metadata(generated).scope,
            "project_declaration"
        );
    }

    #[test]
    fn ruby_callback_contracts_remain_parametric() {
        let each = "scip-ruby gem clear-compiler workspace Array#each().";
        let metadata = external_symbol_metadata(each);

        assert_eq!(metadata.parametric_cost.as_deref(), Some("callback_linear"));
        assert!(external_symbol_call_complexity(each, "each").is_none());
    }
}
