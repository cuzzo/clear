use super::normalized_behavior::{
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedStateRead,
};
use crate::ast::{Node, Span};

pub(crate) struct LuaNormalizedBehavior;

impl NormalizedLanguageBehavior for LuaNormalizedBehavior {
    fn project_call(
        &self,
        node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.message == "call" {
            if let Some((receiver, message)) = lua_method_receiver_message(&call.receiver) {
                call.receiver = receiver;
                call.message = message;
                call.span = lua_method_span(node, call.span);
            }
        }
        call
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self"
            && matches!(call.message.as_str(), "callback" | "ipairs" | "print" | "setmetatable")
    }

    fn embedded_member_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        dotted_member_reads(&node.text, node.first_lineno, node.first_column)
    }

    fn function_visibility(&self, _name: &str, _node: &Node, _lines: &[String]) -> String {
        "public".to_string()
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: LuaNormalizedBehavior = LuaNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn lua_method_receiver_message(receiver: &str) -> Option<(String, String)> {
    let (receiver, message) = receiver.rsplit_once(':')?;
    Some((receiver.to_string(), message.to_string()))
}

fn lua_method_span(node: &Node, fallback: Span) -> Span {
    if node.first_lineno != node.last_lineno {
        return fallback;
    }
    let Some(paren) = node.text.find('(') else {
        return fallback;
    };
    [
        node.first_lineno,
        node.first_column,
        node.first_lineno,
        node.first_column + paren,
    ]
}

fn dotted_member_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    let mut reads = Vec::new();
    for (receiver, field, start, end) in dotted_segments(text) {
        if receiver == "_" && field == "_" {
            continue;
        }
        reads.push(NormalizedStateRead {
            receiver,
            field,
            line: Some(line),
            span: [line, column + start, line, column + end],
        });
    }
    reads
}

fn dotted_segments(text: &str) -> Vec<(String, String, usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    for index in 0..bytes.len() {
        if bytes[index] != b'.' || index == 0 || index + 1 >= bytes.len() {
            continue;
        }
        let receiver_start = text[..index]
            .rfind(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric() || ch == '.'))
            .map(|offset| offset + 1)
            .unwrap_or(0);
        let field_end = text[(index + 1)..]
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| index + 1 + offset)
            .unwrap_or(text.len());
        let receiver = &text[receiver_start..index];
        let field = &text[(index + 1)..field_end];
        if simple_dotted_part(receiver) && simple_identifier(field) {
            out.push((receiver.to_string(), field.to_string(), receiver_start, field_end));
        }
    }
    out
}

fn simple_dotted_part(value: &str) -> bool {
    !value.is_empty() && value.split('.').all(simple_identifier)
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
