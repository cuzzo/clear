use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedOwner,
    NormalizedSemanticEffect,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};

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

pub(crate) struct RustNormalizedBehavior;

impl NormalizedLanguageBehavior for RustNormalizedBehavior {
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

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && call.message == "callback"
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
        if node.text.trim_start().starts_with("pub ") {
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
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.starts_with("Option<") {
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(behavior.format_hash_type("String", "i32"), "HashMap<String, i32>");
        assert_eq!(behavior.format_set_type("i32"), "HashSet<i32>");
        assert_eq!(behavior.untyped_array_type(), "Vec<Value>");
        assert_eq!(behavior.untyped_hash_type(), "HashMap<String, Value>");
        assert_eq!(behavior.format_nilable_type(""), "");
        assert_eq!(behavior.format_nilable_type("Option<i32>"), "Option<i32>");
        assert_eq!(behavior.format_nilable_type("i32"), "Option<i32>");
        assert_eq!(behavior.parameter_name_from_signature("invalid_sig"), None);
        assert_eq!(behavior.untyped_type(), "Value");
    }
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
            .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}
