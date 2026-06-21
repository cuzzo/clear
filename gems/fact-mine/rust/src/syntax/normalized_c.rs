use super::normalized_behavior::{
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedOwner,
};
use crate::ast::{Node, Span};
use std::collections::BTreeMap;

struct CNormalizedBehavior;

impl NormalizedLanguageBehavior for CNormalizedBehavior {
    fn call_receiver(&self, parts: &NormalizedCallParts) -> String {
        if parts.receiver != "self" {
            return parts.receiver.clone();
        }
        let first_arg = parts.arguments.first().map(String::as_str).unwrap_or("");
        first_arg
            .strip_prefix("self->")
            .filter(|field| simple_identifier(field))
            .map(|field| format!("self.{field}"))
            .unwrap_or_else(|| parts.receiver.clone())
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self->{message}")
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver.starts_with("self.") && !call.arguments.is_empty()
    }

    fn suppress_self_call_state_read(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "self" && !call.arguments.is_empty()
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        keyword_block_span(node, "struct").or(Some(default_span))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        if node.r#type != "TYPE_DEFINITION" || !node.text.contains("struct") {
            return None;
        }
        let name = node
            .text
            .split_once('}')?
            .1
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())?;
        Some(NormalizedOwner {
            name: name.to_string(),
            kind: "struct".to_string(),
        })
    }

    fn owner_for_function(
        &self,
        name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> String {
        if current_owner != file_owner {
            return current_owner.to_string();
        }

        let params = self.parameter_list_source(&node.text);
        let first = params.split(',').next().unwrap_or_default().trim();
        if let Some(owner) = typed_self_owner(first) {
            return owner;
        }

        name.split_once('_')
            .and_then(|(prefix, _)| {
                prefix
                    .chars()
                    .next()
                    .filter(|ch| ch.is_ascii_uppercase())
                    .map(|_| prefix.to_string())
            })
            .unwrap_or_else(|| current_owner.to_string())
    }

    fn receiver_aliases_for_function(&self, node: &Node) -> BTreeMap<String, String> {
        let params = self.parameter_list_source(&node.text);
        let first = params.split(',').next().unwrap_or_default().trim();
        let name = first
            .split_whitespace()
            .next_back()
            .map(|value| value.trim_start_matches('*').trim())
            .filter(|value| simple_identifier(value));
        let mut aliases = BTreeMap::new();
        if first.contains('*') {
            if let Some(name) = name {
                aliases.insert(name.to_string(), "self".to_string());
            }
        }
        aliases
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("static ") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn case_pattern_display(&self, pattern: &str) -> String {
        pattern
            .strip_prefix("AST_")
            .map(|tail| format!("AST.{tail}"))
            .unwrap_or_else(|| pattern.to_string())
    }
}

static BEHAVIOR: CNormalizedBehavior = CNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn typed_self_owner(parameter: &str) -> Option<String> {
    let normalized = parameter.replace(['*', '&'], " ");
    let tokens = normalized
        .split_whitespace()
        .filter(|token| !matches!(*token, "const" | "struct"))
        .collect::<Vec<_>>();
    if tokens.last().copied() != Some("self") || tokens.len() < 2 {
        return None;
    }
    tokens
        .get(tokens.len() - 2)
        .filter(|owner| {
            owner
                .chars()
                .all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
        })
        .map(|owner| (*owner).to_string())
}

fn keyword_block_span(node: &Node, keyword: &str) -> Option<Span> {
    let lines = node.text.lines().collect::<Vec<_>>();
    let start_offset = lines.iter().position(|line| line.contains(keyword))?;
    let end_offset = lines.iter().rposition(|line| line.contains('}')).unwrap_or(lines.len() - 1);
    let start_line = node.first_lineno + start_offset;
    let end_line = node.first_lineno + end_offset;
    let start_column =
        if start_offset == 0 { node.first_column } else { 0 } + lines[start_offset].find(keyword).unwrap_or(0);
    let end_column = if end_offset == 0 { node.first_column } else { 0 }
        + lines[end_offset].find('}').unwrap_or(lines[end_offset].len())
        + 1;
    Some([start_line, start_column, end_line, end_column])
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
