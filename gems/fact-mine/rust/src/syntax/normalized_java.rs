use super::normalized_behavior::{
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedSemanticEffect,
};
use crate::ast::{Node, Span};

pub(crate) struct JavaNormalizedBehavior;

impl NormalizedLanguageBehavior for JavaNormalizedBehavior {
    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("private ") {
            "private".to_string()
        } else if text.starts_with("protected ") {
            "protected".to_string()
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
        !call.arguments.is_empty()
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        !call.arguments.is_empty()
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        _function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: JavaNormalizedBehavior = JavaNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}
