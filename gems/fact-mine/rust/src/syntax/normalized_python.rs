use super::normalized_behavior::{
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedStateRead,
};
use crate::ast::{Node, Span};

pub(crate) struct PythonNormalizedBehavior;

impl NormalizedLanguageBehavior for PythonNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn function_visibility(&self, name: &str, _node: &Node, _lines: &[String]) -> String {
        if name.starts_with('_') && !name.starts_with("__") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && matches!(call.message.as_str(), "callback" | "len" | "open")
    }

    fn embedded_member_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        dotted_member_reads(&node.text, node.first_lineno, node.first_column)
            .into_iter()
            .filter(|read| read.field != "_lock" && !read.field.ends_with("_lock"))
            .collect()
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }
}

static BEHAVIOR: PythonNormalizedBehavior = PythonNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn dotted_member_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    if text.contains('=') || text.contains(':') {
        return Vec::new();
    }
    let mut reads = Vec::new();
    for (receiver, field, start, end) in dotted_segments(text) {
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
