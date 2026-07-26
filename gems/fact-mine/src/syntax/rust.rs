// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_external_latency_bound, configured_semantic_symbol_call_complexity,
    configured_semantic_symbol_kind, configured_semantic_symbol_parametric_cost,
    eliminable_guard_from_call, nil_guard_from_predicates, type_after_parameter_colon,
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
    NormalizedNilGuardFact, NormalizedOwner, NormalizedSemanticEffect,
};
use super::StateDeclaration;
use super::{CallSite, ExternalCallComplexity};
use crate::ast::Child;
use crate::ast::{Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

fn scip_rust_parts(symbol: &str) -> Option<(&str, &str)> {
    let rest = symbol.strip_prefix("rust-analyzer cargo ")?;
    let mut fields = rest.splitn(3, ' ');
    let krate = fields.next()?;
    fields.next()?; // crate version or source URL
    Some((krate, fields.next()?))
}

fn rust_stdlib_crate(krate: &str) -> bool {
    matches!(krate, "core" | "alloc" | "std")
}

fn rust_semantic_constructor(descriptor: &str, message: &str) -> bool {
    !message.is_empty() && descriptor.ends_with(&format!("#{message}#"))
}

fn rust_descriptor_owner(descriptor: &str) -> Option<String> {
    if descriptor.contains("][ToString]") {
        return Some("ToString".to_string());
    }
    let Some((_, tail)) = descriptor.split_once("impl#[") else {
        let owner = if let Some((owner, _)) = descriptor.rsplit_once('#') {
            owner
        } else {
            // Free functions use a path descriptor such as `fs/write()`.
            descriptor.rsplit_once('/')?.0
        };
        return Some(
            owner
                .rsplit('/')
                .next()
                .unwrap_or(owner)
                .trim_matches('`')
                .to_string(),
        );
    };
    let raw = if let Some(tail) = tail.strip_prefix('`') {
        tail.split_once("`]")?.0
    } else {
        tail.split_once(']')?.0
    };
    let owner = if raw.contains("Vec<") || raw == "[T]" {
        // Feed the shared nominal parser a representative generic shape so
        // Vec is normalized to the language-neutral Array family.  A bare
        // `Vec` is deliberately not treated as an array by that parser.
        "Vec<Value>"
    } else if raw.contains("BTreeMap<") {
        "BTreeMap"
    } else if raw.contains("BTreeSet<") {
        "BTreeSet"
    } else if raw.contains("HashMap<") {
        "HashMap<Value, Value>"
    } else if raw.contains("HashSet<") {
        "HashSet<Value>"
    } else if raw.contains("Option<") {
        "Option"
    } else if raw.contains("Result<") {
        "Result"
    } else if descriptor.contains("][Iterator]")
        || descriptor.contains("][DoubleEndedIterator]")
        || raw.contains("Iter<")
        || raw.contains("IntoIter<")
        || raw.contains("Map<")
        || raw.contains("Split<")
        || raw.contains("Chars<")
    {
        "Iterator"
    } else if raw == "str" {
        "String"
    } else {
        raw.split('<').next().unwrap_or(raw).trim_matches('`')
    };
    Some(owner.to_string())
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let (krate, descriptor) = scip_rust_parts(symbol)?;
    // rust-analyzer emits enum variants as exact term symbols such as
    // `option/Option#Some#`, not callable method descriptors. At a normalized
    // call site that occurrence proves construction; argument costs are
    // accounted independently, so the construction operation itself is O(1).
    if rust_semantic_constructor(descriptor, message) {
        return Some(ExternalCallComplexity {
            time: "O(1)",
            space: "O(1)",
            provenance: "rust_semantic_constructor",
            bound_quality: "upper_bound_exact_target",
            candidates: Vec::new(),
            assumption: None,
        });
    }
    if configured_semantic_symbol_parametric_cost("rust", descriptor).is_some() {
        return None;
    }
    let exact = configured_semantic_symbol_call_complexity("rust", descriptor);
    let owner = rust_descriptor_owner(descriptor);
    let external_latency = owner
        .as_deref()
        .and_then(|owner| configured_external_latency_bound("rust", owner, message));
    if !rust_stdlib_crate(krate) && exact.is_none() && external_latency.is_none() {
        return None;
    }
    let behavior = RustNormalizedBehavior;
    let complexity = exact.or_else(|| {
        owner
            .as_deref()
            .and_then(|owner| behavior.call_complexity(&parse_declared_type(owner), message))
    });
    if let Some(complexity) = complexity {
        return Some(ExternalCallComplexity {
            time: complexity.time,
            space: complexity.space,
            provenance: if rust_stdlib_crate(krate) {
                "rust_stdlib_registry"
            } else {
                "rust_dependency_registry"
            },
            bound_quality: "upper_bound_exact_target",
            candidates: Vec::new(),
            assumption: None,
        });
    }
    let complexity = external_latency?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "rust_external_effect_registry",
        bound_quality: "upper_bound_external_latency_excluded",
        candidates: Vec::new(),
        assumption: Some(
            "computational Big-O only; filesystem, process, stream, or scheduler latency is excluded"
                .to_string(),
        ),
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> super::ExternalSymbolMetadata {
    let Some((krate, descriptor)) = scip_rust_parts(symbol) else {
        return super::ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    super::ExternalSymbolMetadata {
        scope: if rust_stdlib_crate(krate) {
            "stdlib"
        } else if krate == "fact-mine-rust" {
            "project_declaration"
        } else {
            "dependency"
        },
        missing_cost_kind: configured_semantic_symbol_kind("rust", descriptor).unwrap_or_else(
            || {
                if rust_stdlib_crate(krate) {
                    "stdlib_cost_model_missing".to_string()
                } else {
                    "dependency_cost_model_missing".to_string()
                }
            },
        ),
        parametric_cost: configured_semantic_symbol_parametric_cost("rust", descriptor),
    }
}

const RUST_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &["&mut "],
    trim_prefix_chars: &['&'],
    trim_suffix_chars: &[],
    array_names: &["Vec"],
    hash_names: &["HashMap"],
    set_names: &["HashSet"],
    string_names: &["String", "str"],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: false,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    nominal::parse(source, &RUST_NOMINAL_TYPE_SYNTAX)
}

const RUST_CONTEXT_PAIRS: &[(&str, &[&str])] = &[("SystemTime", &["now"]), ("Instant", &["now"])];

const RUST_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "downcast",
        "downcast_ref",
        "downcast_mut",
        "call",
        "call_mut",
        "call_once",
    ],
    meta_mids: &["transmute", "from_raw_parts", "from_raw_parts_mut"],
    method_obj_mids: &["method"],
    io_consts: &["std", "tokio", "fs", "env", "process", "net", "io"],
    io_bare: &[
        "panic",
        "todo",
        "unimplemented",
        "unreachable",
        "print",
        "println",
        "eprintln",
        "printf",
        "puts",
    ],
    context_pairs: RUST_CONTEXT_PAIRS,
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
        "read",
        "write",
        "spawn",
        "await",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const RUST_NIL_PREDICATES: &[&str] = &["isNull", "is_null", "is_none"];
const RUST_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const RUST_GUARD_MIDS: &[&str] = &["isNull", "is_null", "is_none", "is_some"];

// CFG-SPECIFIC START: Rust control-flow vocabulary.
const RUST_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "all",
        "any",
        "enumerate",
        "filter",
        "filter_map",
        "flat_map",
        "fold",
        "for_each",
        "into_iter",
        "iter",
        "iter_mut",
        "map",
        "reduce",
        "scan",
        "skip_while",
        "take_while",
    ],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct RustNormalizedBehavior;

impl NormalizedLanguageBehavior for RustNormalizedBehavior {
    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCallComplexity> {
        // Enum-variant constructors (`Some`/`None`/`Ok`/`Err`) wrap a value in
        // O(1); `transmute` is a reinterpret cast. These have no analyzable body
        // in source-only mode, so without this they read as unresolved calls.
        if matches!(message, "Some" | "None" | "Ok" | "Err" | "transmute") {
            return Some(super::normalized_behavior::NormalizedCallComplexity {
                time: "O(1)",
                space: "O(1)",
            });
        }
        self.stdlib_language().and_then(|language| {
            super::normalized_behavior::configured_intrinsic_call_complexity(
                language, receiver, message,
            )
        })
    }

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

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_after_local_colon(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("rust")
    }

    // CFG-SPECIFIC START: expose the Rust CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &RUST_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn project_call(
        &self,
        _node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.message == "call" {
            let receiver_text = call.receiver.clone();
            if let Some((receiver, message)) = receiver_text.rsplit_once("::") {
                call.receiver = receiver.to_string();
                call.message = message.to_string();
            }
        }
        call
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn record_method_calls_as_state_reads(&self) -> bool {
        false
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        if call.receiver == "self" && call.message == "callback" {
            return true;
        }
        matches!(
            call.message.as_str(),
            "to_string"
                | "to_owned"
                | "clone"
                | "unwrap"
                | "expect"
                | "unwrap_or"
                | "unwrap_or_else"
                | "get"
                | "get_mut"
                | "as_ref"
                | "as_mut"
                | "as_str"
                | "as_bytes"
                | "len"
                | "is_empty"
                | "trim"
                | "trim_start"
                | "trim_end"
                | "to_ascii_lowercase"
                | "to_ascii_uppercase"
                | "to_lowercase"
                | "to_uppercase"
                | "split"
                | "split_once"
                | "rsplit"
                | "rsplit_once"
        )
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        if node.text.trim_start().starts_with("impl ") {
            "impl".to_string()
        } else {
            default_kind.to_string()
        }
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        (node.r#type == "STRUCT_ITEM")
            .then(|| owner_after_keyword(&node.text, "struct"))
            .flatten()
            .map(|name| NormalizedOwner {
                name,
                kind: "struct".to_string(),
            })
    }

    fn owner_name_span(&self, _name: &str, _node: &Node, default_span: Span) -> Option<Span> {
        Some(default_span)
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("pub(") {
            // pub(crate) / pub(super) / pub(in path): crate-scoped, not public.
            "crate".to_string()
        } else if text.starts_with("pub ") {
            "public".to_string()
        } else {
            "private".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.trim();
        if text == "&self" || text == "&mut self" {
            return Some(text.to_string());
        }
        let before_colon = text.split_once(':')?.0.trim();
        let name = before_colon.strip_prefix("mut ").unwrap_or(before_colon);
        simple_identifier(name).then(|| name.to_string())
    }

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        type_after_parameter_colon(param)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            RUST_NIL_PREDICATES,
            RUST_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "panic" | "todo" | "unimplemented" | "unreachable")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, RUST_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &RUST_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        keyword == "let"
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "const"
                    | "continue"
                    | "else"
                    | "false"
                    | "fn"
                    | "for"
                    | "if"
                    | "in"
                    | "match"
                    | "mut"
                    | "pub"
                    | "return"
                    | "self"
                    | "static"
                    | "struct"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("none")
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
        in_method: bool,
    ) -> Option<StateDeclaration> {
        if in_method {
            return None;
        }
        // Try structured children first: [name, type?, value?]
        let child_nodes: Vec<&Node> = node
            .children
            .iter()
            .filter_map(|c| match c {
                Child::Node(n) => Some(n.as_ref()),
                _ => None,
            })
            .collect();
        if child_nodes.len() >= 2 {
            let name = child_nodes[0].text.trim();
            if is_simple_name(name) {
                let type_text = child_nodes[1].text.trim().to_string();
                if !type_text.is_empty() && type_text != ":" && !type_text.starts_with('=') {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        immutable: false,
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        None
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("Vec<{elem}>")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("HashMap<{key}, {val}>")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("HashSet<{elem}>")
    }

    fn untyped_array_type(&self) -> String {
        "Vec<Value>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "HashMap<String, Value>".to_string()
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty()
            || type_text == "nil"
            || type_text == "null"
            || type_text.starts_with("Option<")
        {
            type_text.to_string()
        } else {
            format!("Option<{}>", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "Value".to_string()
    }
}

static BEHAVIOR: RustNormalizedBehavior = RustNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

pub(crate) fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn owner_after_keyword(text: &str, keyword: &str) -> Option<String> {
    let rest = text.split_once(keyword)?.1.trim_start();
    rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
}

fn is_simple_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(' ')
        && !name.contains('.')
        && !name.contains('[')
        && !name.contains('<')
        && !name.contains('(')
        && name
            .chars()
            .next()
            .is_some_and(|c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn function_visibility_distinguishes_crate_scope() {
        let b = behavior();
        assert_eq!(
            b.function_visibility("f", &node("FN", "pub fn f() {}"), &[]),
            "public"
        );
        assert_eq!(
            b.function_visibility("f", &node("FN", "pub(crate) fn f() {}"), &[]),
            "crate"
        );
        assert_eq!(
            b.function_visibility("f", &node("FN", "pub(super) fn f() {}"), &[]),
            "crate"
        );
        assert_eq!(
            b.function_visibility("f", &node("FN", "fn f() {}"), &[]),
            "private"
        );
    }

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10 + text.lines().count().saturating_sub(1),
            last_column: text.lines().last().map(str::len).unwrap_or_default(),
            text: text.to_string(),
        }
    }

    #[test]
    fn rust_behavior_classifies_fallback_keywords_and_owner_spans() {
        let behavior = RustNormalizedBehavior;
        let impl_node = node("CLASS", "trait Widget {}");
        let struct_node = node("CLASS", "pub struct Widget {\n    value: usize,\n}");

        assert_eq!(behavior.owner_kind(&impl_node, "class"), "class");
        assert_eq!(
            behavior.owner_name_span("Widget", &struct_node, [1, 0, 1, 1]),
            Some([1, 0, 1, 1])
        );
        assert!(behavior.local_flow_declaration_keyword("let"));
        assert!(behavior.local_flow_keyword("match"));
        assert!(behavior.local_flow_keyword("mut"));
        assert!(!behavior.local_flow_keyword("domain_value"));
    }

    #[test]
    fn rust_behavior_projects_edge_calls_and_terminators() {
        let behavior = RustNormalizedBehavior;
        let call_node = node("CALL", "callback.call()");
        let projected = behavior.project_call(
            &call_node,
            NormalizedCallProjection {
                receiver: "callback".to_string(),
                message: "call".to_string(),
                arguments: Vec::new(),
                access_span: [10, 2, 10, 17],
                span: [10, 2, 10, 17],
            },
        );

        assert_eq!(projected.receiver, "callback");
        assert_eq!(projected.message, "call");
        assert!(behavior.terminating_call_message("panic"));
        assert!(!behavior.terminating_call_message("recover"));
        assert_eq!(owner_after_keyword("enum Widget {}", "struct"), None);
    }

    #[test]
    fn test_rust_behavior_state_declaration_and_spans() {
        let behavior = RustNormalizedBehavior;

        let field_node = Node {
            r#type: "struct_field".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "type_identifier".to_string(),
                    children: Vec::new(),
                    first_lineno: 12,
                    first_column: 4,
                    last_lineno: 12,
                    last_column: 8,
                    text: "my_field".to_string(),
                })),
                Child::Node(Box::new(Node {
                    r#type: "type_identifier".to_string(),
                    children: Vec::new(),
                    first_lineno: 12,
                    first_column: 10,
                    last_lineno: 12,
                    last_column: 15,
                    text: "usize".to_string(),
                })),
            ],
            first_lineno: 12,
            first_column: 4,
            last_lineno: 12,
            last_column: 15,
            text: "my_field: usize".to_string(),
        };
        let decl = behavior
            .state_declaration_from_node(&field_node, "Widget", false)
            .unwrap();
        assert_eq!(decl.field, "my_field");
        assert_eq!(decl.r#type, Some("usize".to_string()));

        let colon_field_node = Node {
            r#type: "struct_field".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "type_identifier".to_string(),
                    children: Vec::new(),
                    first_lineno: 12,
                    first_column: 4,
                    last_lineno: 12,
                    last_column: 8,
                    text: "my_field".to_string(),
                })),
                Child::Node(Box::new(Node {
                    r#type: "type_identifier".to_string(),
                    children: Vec::new(),
                    first_lineno: 12,
                    first_column: 10,
                    last_lineno: 12,
                    last_column: 11,
                    text: ":".to_string(),
                })),
            ],
            first_lineno: 12,
            first_column: 4,
            last_lineno: 12,
            last_column: 11,
            text: "my field: :".to_string(),
        };
        assert!(behavior
            .state_declaration_from_node(&colon_field_node, "Widget", false)
            .is_none());

        let multiline_node = Node {
            r#type: "CLASS".to_string(),
            children: Vec::new(),
            first_lineno: 20,
            first_column: 0,
            last_lineno: 22,
            last_column: 1,
            text: "\n    struct Widget {\n}".to_string(),
        };
        let span = behavior
            .owner_name_span("Widget", &multiline_node, [20, 0, 22, 1])
            .unwrap();
        assert_eq!(span, [20, 0, 22, 1]);

        let end_offset_zero_node = Node {
            r#type: "CLASS".to_string(),
            children: Vec::new(),
            first_lineno: 30,
            first_column: 5,
            last_lineno: 31,
            last_column: 17,
            text: "}\n    struct Widget".to_string(),
        };
        let span2 = behavior
            .owner_name_span("Widget", &end_offset_zero_node, [30, 5, 31, 17])
            .unwrap();
        assert_eq!(span2, [30, 5, 31, 17]);
    }

    #[test]
    fn test_rust_behavior_uncovered_methods() {
        let behavior = RustNormalizedBehavior;
        assert_eq!(behavior.format_array_type("i32"), "Vec<i32>");
        assert_eq!(
            behavior.format_hash_type("String", "i32"),
            "HashMap<String, i32>"
        );
        assert_eq!(behavior.format_set_type("i32"), "HashSet<i32>");
        assert_eq!(behavior.untyped_array_type(), "Vec<Value>");
        assert_eq!(behavior.untyped_hash_type(), "HashMap<String, Value>");
        assert_eq!(behavior.format_nilable_type(""), "");
        assert_eq!(behavior.format_nilable_type("Option<i32>"), "Option<i32>");
        assert_eq!(behavior.format_nilable_type("i32"), "Option<i32>");
        assert_eq!(behavior.parameter_name_from_signature("invalid_sig"), None);
        assert_eq!(behavior.untyped_type(), "Value");
    }

    #[test]
    fn rust_analyzer_symbols_use_proven_crate_identity() {
        let vec_len = "rust-analyzer cargo alloc https://github.com/rust-lang/rust/library/alloc vec/impl#[`Vec<T, A>`]len().";
        let tree_kind = "rust-analyzer cargo tree-sitter 0.25.8 impl#[`Node<'tree>`]kind().";
        let tempfile = "rust-analyzer cargo tempfile 3.10.1 impl#[`Builder<'a, 'b>`]tempfile().";
        let tempdir = "rust-analyzer cargo tempfile 3.10.1 dir/tempdir().";
        let unknown_dependency = "rust-analyzer cargo arbitrary 1.0.0 impl#[Thing]work().";

        assert_eq!(
            external_symbol_call_complexity(vec_len, "len").map(|complexity| complexity.time),
            Some("O(1)")
        );
        assert_eq!(
            external_symbol_call_complexity(tree_kind, "kind").map(|complexity| complexity.time),
            Some("O(1)")
        );
        assert_eq!(external_symbol_metadata(vec_len).scope, "stdlib");
        assert_eq!(external_symbol_metadata(tree_kind).scope, "dependency");
        assert_eq!(
            external_symbol_call_complexity(tempfile, "tempfile")
                .and_then(|complexity| complexity.assumption),
            Some(
                "computational Big-O only; filesystem, process, stream, or scheduler latency is excluded"
                    .to_string()
            )
        );
        assert!(external_symbol_call_complexity(tempdir, "tempdir")
            .and_then(|complexity| complexity.assumption)
            .is_some());
        assert!(external_symbol_call_complexity(unknown_dependency, "work").is_none());
    }

    #[test]
    fn rust_analyzer_term_symbols_prove_constant_enum_construction() {
        let some = "rust-analyzer cargo core https://github.com/rust-lang/rust/library/core option/Option#Some#";
        let project = "rust-analyzer cargo demo 0.1.0 model/Result#Ready#";

        for (symbol, message) in [(some, "Some"), (project, "Ready")] {
            let complexity = external_symbol_call_complexity(symbol, message).unwrap();
            assert_eq!(complexity.time, "O(1)");
            assert_eq!(complexity.space, "O(1)");
            assert_eq!(complexity.provenance, "rust_semantic_constructor");
            assert_eq!(complexity.bound_quality, "upper_bound_exact_target");
        }
        assert!(external_symbol_call_complexity(project, "Other").is_none());
    }

    #[test]
    fn rust_callback_and_iterator_contracts_remain_parametric() {
        let collect = "rust-analyzer cargo core https://github.com/rust-lang/rust/library/core iter/traits/iterator/Iterator#collect().";
        let metadata = external_symbol_metadata(collect);

        assert_eq!(metadata.parametric_cost.as_deref(), Some("callback_linear"));
        assert!(external_symbol_call_complexity(collect, "collect").is_none());
    }
}
