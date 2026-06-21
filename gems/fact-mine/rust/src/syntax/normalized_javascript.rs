use super::normalized_behavior::{
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
};
use crate::ast::{Node, Span};

pub(crate) struct JavaScriptNormalizedBehavior;

impl NormalizedLanguageBehavior for JavaScriptNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, name: &str, _node: &Node, _lines: &[String]) -> String {
        if name.starts_with('#') {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        format!("this.{message}")
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

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        property_read_call(node, parts)
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: JavaScriptNormalizedBehavior = JavaScriptNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

pub(crate) fn property_read_call(node: &Node, parts: &NormalizedCallParts) -> bool {
    if node.r#type == "VCALL" || !parts.arguments.is_empty() {
        return false;
    }
    let text = node.text.as_str();
    !text.contains('(') || (text.starts_with('(') && text.ends_with(')'))
}
