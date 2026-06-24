use super::effects::effect_from_call_with_lexicon;
use super::javascript;
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::{Node, Span};
use crate::ast::Child;

const TYPESCRIPT_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const TYPESCRIPT_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const TYPESCRIPT_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct TypeScriptNormalizedBehavior;

impl NormalizedLanguageBehavior for TypeScriptNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("private ") || text.starts_with("protected ") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let mut text = param.split('=').next().unwrap_or(param).trim();
        for prefix in ["public ", "private ", "protected ", "readonly "] {
            text = text.strip_prefix(prefix).unwrap_or(text);
        }
        let before_colon = text.split_once(':')?.0.trim().trim_end_matches('?');
        simple_identifier(before_colon).then(|| before_colon.to_string())
    }

    fn wrap_branch_predicate(&self, branch: &Node) -> bool {
        let _ = branch;
        true
    }

    fn explicit_self_state_ref(&self, node: &Node, message: &str) -> String {
        let _ = node;
        format!("this.{message}")
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        javascript::property_read_call(node, parts)
    }

    fn state_read_uses_access_span(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "console" || call.receiver == "this.sink" || call.receiver == "self"
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && call.message == "callback"
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            TYPESCRIPT_NIL_PREDICATES,
            TYPESCRIPT_NON_NIL_PREDICATES,
        )
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, TYPESCRIPT_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &javascript::JAVASCRIPT_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "const" | "let" | "var")
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "case"
                    | "class"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "function"
                    | "if"
                    | "in"
                    | "null"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text.contains("undefined")
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null") || text.contains("??")
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
    ) -> Option<StateDeclaration> {
        // Try structured children first: [name, type?, value?]
        let mut child_nodes: Vec<&Node> = node.children.iter().filter_map(|c| match c {
            Child::Node(n) => Some(n.as_ref()),
            _ => None,
        }).collect();

        // Skip any leading modifiers
        while !child_nodes.is_empty() {
            let text = child_nodes[0].text.trim();
            if matches!(
                text,
                "public"
                    | "private"
                    | "protected"
                    | "readonly"
                    | "static"
                    | "declare"
                    | "override"
                    | "abstract"
                    | "accessor"
            ) {
                child_nodes.remove(0);
            } else {
                break;
            }
        }

        if child_nodes.len() >= 2 {
            let name = child_nodes[0].text.trim();
            if is_simple_name(name) {
                let mut type_text = child_nodes[1].text.trim().to_string();
                if type_text.starts_with(':') {
                    type_text = type_text[1..].trim().to_string();
                }
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
        // Fallback: text-based (`name: Type`)
        let text = node.text.trim();
        if let Some((raw_name, rest)) = text.split_once(':') {
            let mut name = raw_name.trim();
            loop {
                let mut stripped = false;
                for modifier in [
                    "public",
                    "private",
                    "protected",
                    "readonly",
                    "static",
                    "declare",
                    "override",
                    "abstract",
                    "accessor",
                ] {
                    if let Some(rest_name) = name.strip_prefix(modifier) {
                        name = rest_name.trim();
                        stripped = true;
                        break;
                    }
                }
                if !stripped {
                    break;
                }
            }
            if is_simple_name(name) {
                let type_text = rest.split('=').next().unwrap_or(rest).trim()
                    .trim_end_matches(',').trim_end_matches(';').to_string();
                if !type_text.is_empty() && type_text != ":" {
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
}

static BEHAVIOR: TypeScriptNormalizedBehavior = TypeScriptNormalizedBehavior;

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

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn is_simple_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(' ')
        && !name.contains('.')
        && !name.contains('[')
        && !name.contains('<')
        && !name.contains('(')
        && name.chars().next().map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name.chars().all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}
