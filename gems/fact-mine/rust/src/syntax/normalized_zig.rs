use super::normalized_behavior::{
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedOwner, NormalizedStateRead,
    NormalizedStateWrite,
};
use super::StateDeclaration;
use crate::ast::{Child, Node, Span};

pub(crate) struct ZigNormalizedBehavior;

impl NormalizedLanguageBehavior for ZigNormalizedBehavior {
    fn state_write_span(
        &self,
        receiver: &str,
        field: &str,
        node: &Node,
        default_span: Span,
    ) -> Span {
        target_span_from_text(node, &format!("{receiver}.{field}")).unwrap_or(default_span)
    }

    fn suppress_call_site(&self, _node: &Node, call: &NormalizedCallProjection) -> bool {
        call.receiver == "std.debug" && call.message == "print"
    }

    fn local_assignment_writes(
        &self,
        field: Option<&str>,
        _node: &Node,
        default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        let Some(field) = field.and_then(|field| field.strip_prefix('.')) else {
            return Vec::new();
        };
        vec![NormalizedStateWrite {
            receiver: ".literal".to_string(),
            field: field.to_string(),
            span: default_span,
        }]
    }

    fn literal_state_reads(
        &self,
        node: &Node,
        normalized_text: &str,
        span: Span,
        source_text: &str,
    ) -> Vec<NormalizedStateRead> {
        let Some(field) = normalized_text.strip_prefix('.') else {
            return Vec::new();
        };
        if !simple_identifier(field) {
            return Vec::new();
        }
        vec![NormalizedStateRead {
            receiver: ".literal".to_string(),
            field: field.to_string(),
            line: Some(node.first_lineno),
            span: literal_span(node, normalized_text, span, source_text),
        }]
    }

    fn literal_state_refs(&self, _node: &Node, normalized_text: &str) -> Vec<String> {
        normalized_text
            .strip_prefix('.')
            .map(|field| vec![format!(".literal.{field}")])
            .unwrap_or_default()
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "std" && call.message == "debug"
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        keyword_block_span(node, "struct").or(Some(default_span))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        if node.r#type != "VARIABLE_DECLARATION" {
            return None;
        }
        let text = node.text.as_str();
        if !text.contains("const ") || !text.contains("= struct") {
            return None;
        }
        let name = text
            .split_once("const ")?
            .1
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())?;
        Some(NormalizedOwner {
            name: name.to_string(),
            kind: "struct".to_string(),
        })
    }

    fn body_owner_for_function(
        &self,
        name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> Option<NormalizedOwner> {
        if current_owner != file_owner || !node.text.contains("return struct") {
            return None;
        }
        let source = node.text.trim_start();
        if source.starts_with(&format!("fn {name}")) || source.starts_with(&format!("pub fn {name}")) {
            Some(NormalizedOwner {
                name: name.to_string(),
                kind: "struct".to_string(),
            })
        } else {
            None
        }
    }

    fn state_declaration_from_node(&self, node: &Node, _owner: &str) -> Option<StateDeclaration> {
        if node.r#type != "CONTAINER_FIELD" {
            return None;
        }
        let field = node.children.iter().find_map(|child| match child {
            Child::Node(child) if child.r#type == "LVAR" => child.children.first().and_then(|item| match item {
                Child::String(value) | Child::Symbol(value) => Some(value.clone()),
                _ => None,
            }),
            _ => None,
        })?;
        let ty = node
            .text
            .trim_start()
            .strip_prefix(&field)?
            .trim_start()
            .strip_prefix(':')?
            .split(['=', ',', '\n'])
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        (!ty.is_empty()).then(|| StateDeclaration {
            field,
            owner: String::new(),
            r#type: Some(ty),
            file: String::new(),
            line: node.first_lineno,
            span: span(node),
        })
    }

    fn owner_for_function(
        &self,
        _name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> String {
        if current_owner != file_owner {
            return current_owner.to_string();
        }
        self_owner_from_zig_fn(&node.text).unwrap_or_else(|| current_owner.to_string())
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("pub ") {
            "public".to_string()
        } else {
            "private".to_string()
        }
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        let source = text.trim_start();
        let source = source.strip_prefix("pub ").unwrap_or(source).trim_start();
        let rest = source.strip_prefix("fn ")?;
        rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())
            .map(str::to_string)
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let before_colon = param.split_once(':')?.0.trim();
        simple_identifier(before_colon).then(|| before_colon.to_string())
    }

    fn case_pattern_values(&self, pattern_values: Vec<String>) -> Vec<String> {
        pattern_values.into_iter().take(1).collect()
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }
}

static BEHAVIOR: ZigNormalizedBehavior = ZigNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn span(node: &Node) -> Span {
    [node.first_lineno, node.first_column, node.last_lineno, node.last_column]
}

fn target_span_from_text(node: &Node, target: &str) -> Option<Span> {
    if node.first_lineno != node.last_lineno {
        return None;
    }
    let index = node.text.find(target)?;
    Some([
        node.first_lineno,
        node.first_column + index,
        node.first_lineno,
        node.first_column + index + target.len(),
    ])
}

fn literal_span(node: &Node, text: &str, node_span: Span, source_text: &str) -> Span {
    if node.first_lineno != node.last_lineno {
        return node_span;
    }
    let source = if source_text.is_empty() { node.text.as_str() } else { source_text };
    let Some(index) = source.find(text) else {
        return node_span;
    };
    [
        node.first_lineno,
        node.first_column + index,
        node.first_lineno,
        node.first_column + index + text.len(),
    ]
}

fn self_owner_from_zig_fn(text: &str) -> Option<String> {
    let params = text.split_once('(')?.1.split_once(')')?.0;
    let first = params.split(',').next()?.trim();
    let after_colon = first.split_once(':')?.1.trim();
    let owner = after_colon.trim_start_matches('*').trim();
    simple_identifier(owner).then(|| owner.to_string())
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
