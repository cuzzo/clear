use super::normalized_behavior::{NormalizedLanguageBehavior, NormalizedOwner};
use crate::ast::{Node, Span};

pub(crate) struct RustNormalizedBehavior;

impl NormalizedLanguageBehavior for RustNormalizedBehavior {
    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        if node.text.trim_start().starts_with("impl ") {
            "impl".to_string()
        } else {
            default_kind.to_string()
        }
    }

    fn owner_name_from_text(&self, node: &Node) -> Option<String> {
        owner_after_keyword(&node.text, "impl").or_else(|| owner_after_keyword(&node.text, "struct"))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        (node.r#type == "STRUCT_ITEM")
            .then(|| owner_after_keyword(&node.text, "struct"))
            .flatten()
            .map(|name| NormalizedOwner {
                name,
                kind: "struct".to_string(),
            })
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        if node.r#type == "STRUCT_ITEM" {
            Some(default_span)
        } else {
            keyword_block_span(node, "struct").or(Some(default_span))
        }
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("pub ") {
            "public".to_string()
        } else {
            "private".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.trim();
        if text == "&self" || text == "&mut self" {
            return Some(text.to_string());
        }
        let before_colon = text.split_once(':')?.0.trim();
        let name = before_colon.strip_prefix("mut ").unwrap_or(before_colon);
        simple_identifier(name).then(|| name.to_string())
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        function_name_after_fn(text)
    }
}

static BEHAVIOR: RustNormalizedBehavior = RustNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

pub(crate) fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

pub(crate) fn function_name_after_fn(text: &str) -> Option<String> {
    let source = text.trim_start();
    let source = source.strip_prefix("pub ").unwrap_or(source).trim_start();
    let rest = source.strip_prefix("fn ")?;
    rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
}

fn owner_after_keyword(text: &str, keyword: &str) -> Option<String> {
    let rest = text.split_once(keyword)?.1.trim_start();
    rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
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
