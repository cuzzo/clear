use super::effects::effect_from_call_with_lexicon;
use super::javascript;
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};
use super::CallSite;
use crate::ast::{Node, Span};

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
}

static BEHAVIOR: TypeScriptNormalizedBehavior = TypeScriptNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
