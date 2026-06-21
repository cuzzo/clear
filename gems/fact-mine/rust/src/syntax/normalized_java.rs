use super::normalized_behavior::{
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
    NormalizedSemanticEffect,
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

    fn project_call(
        &self,
        node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.receiver == "self" && !call.arguments.is_empty() && node.text.contains("this.") {
            call.message = "this".to_string();
            return call;
        }
        if let Some(rest) = call.receiver.strip_prefix("System.").map(str::to_string) {
            if !call.arguments.is_empty() {
                call.receiver = "System".to_string();
                call.message = rest
                    .split('.')
                    .next()
                    .map(str::to_string)
                    .unwrap_or(rest);
                return call;
            }
        }
        if let Some((base, message)) = java_receiver_method_message(&call.receiver) {
            call.receiver = base;
            call.message = message;
            return call;
        }
        if let Some(field) = call.receiver.strip_prefix("this.").map(str::to_string) {
            if call.arguments.is_empty() && node.text.contains('(') {
                call.receiver = "self".to_string();
                call.message = field
                    .split('.')
                    .next()
                    .map(str::to_string)
                    .unwrap_or(field);
            }
        }
        call
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
        call.span != call.access_span || call.span[3] > call.access_span[3]
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn suppress_call_site(&self, node: &Node, call: &NormalizedCallProjection) -> bool {
        if node.text.contains("this.status.name()") && call.receiver == "self" && call.message == "status" {
            return false;
        }
        false
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

    fn case_pattern_display(&self, pattern: &str) -> String {
        if pattern.starts_with("case ") {
            pattern.to_string()
        } else {
            format!("case {pattern}")
        }
    }

    fn branch_state_ref(
        &self,
        node: &Node,
        parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        if node.text.contains('(') {
            return None;
        }
        if parts
            .receiver
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_uppercase())
        {
            return None;
        }
        Some(default_ref)
    }
}

static BEHAVIOR: JavaNormalizedBehavior = JavaNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn java_receiver_method_message(receiver: &str) -> Option<(String, String)> {
    if !receiver.ends_with("()") {
        return None;
    }
    let (base, method) = receiver.split_once('.')?;
    Some((base.to_string(), method.to_string()))
}
