use super::normalized_behavior::{NormalizedCallProjection, NormalizedLanguageBehavior};
use crate::ast::{Node, Span};

pub(crate) struct PhpNormalizedBehavior;

impl NormalizedLanguageBehavior for PhpNormalizedBehavior {
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

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: PhpNormalizedBehavior = PhpNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}
