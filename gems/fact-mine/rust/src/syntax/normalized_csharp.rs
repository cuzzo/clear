use super::normalized_behavior::{
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
};
use crate::ast::{Node, Span};

pub(crate) struct CSharpNormalizedBehavior;

impl NormalizedLanguageBehavior for CSharpNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("public ") {
            "public".to_string()
        } else if text.starts_with("protected ") {
            "protected".to_string()
        } else {
            "private".to_string()
        }
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
        call.receiver == "self" && !call.arguments.is_empty()
    }

    fn implicit_owner_fields(&self) -> bool {
        true
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: CSharpNormalizedBehavior = CSharpNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}
