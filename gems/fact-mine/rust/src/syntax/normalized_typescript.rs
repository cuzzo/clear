use super::normalized_behavior::{
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
};
use super::normalized_javascript;
use crate::ast::{Node, Span};

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
        normalized_javascript::property_read_call(node, parts)
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
