use super::tree_sitter_adapter::{named_children, previous_sibling_raw_text, CallTarget};
use crate::decomplex::ast::{node_text, normalize_text, span};
use tree_sitter::Node;

pub(crate) struct CallShape {
    pub(crate) default_receiver: &'static str,
    pub(crate) receiver_field: &'static str,
    pub(crate) method_field: &'static str,
    pub(crate) method_fallback_kinds: &'static [&'static str],
}

pub(crate) fn invalid_message_text(text: &str) -> bool {
    text.chars()
        .any(|ch| matches!(ch, '"' | '\'' | '\n' | '\r'))
}

pub(crate) fn identifier_like(text: &str, lowercase_start: bool) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if lowercase_start {
        if !(first == '_' || first.is_ascii_lowercase()) {
            return false;
        }
    } else if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }

    let mut saw_suffix = false;
    for ch in chars {
        if matches!(ch, '!' | '?' | '=') {
            if saw_suffix {
                return false;
            }
            saw_suffix = true;
            continue;
        }
        if saw_suffix || !(ch == '_' || ch.is_ascii_alphanumeric()) {
            return false;
        }
    }
    true
}

pub(crate) fn receiver_message_call_target<'tree, FMsg, FArgs, FSafe, FBlock>(
    node: Node<'tree>,
    source: &str,
    shape: &CallShape,
    fallback_message: FMsg,
    arguments: FArgs,
    safe_navigation: FSafe,
    has_block: FBlock,
) -> Option<CallTarget<'tree>>
where
    FMsg: Fn(Node<'tree>, &str, Option<Node<'tree>>, Option<Node<'tree>>) -> Option<String>,
    FArgs: Fn(Node<'tree>, &str, &str) -> Vec<String>,
    FSafe: Fn(Node<'tree>, &str) -> bool,
    FBlock: Fn(Node<'tree>) -> bool,
{
    let receiver = node.child_by_field_name(shape.receiver_field);
    let method = node.child_by_field_name(shape.method_field);
    let message = method
        .map(|method| node_text(method, source).to_string())
        .or_else(|| first_named_text(node, source, shape.method_fallback_kinds))
        .or_else(|| fallback_message(node, source, receiver, method))?;
    let arguments = arguments(node, source, &message);
    let mut target = CallTarget::new(
        receiver
            .map(|receiver| normalize_text(node_text(receiver, source)))
            .unwrap_or_else(|| shape.default_receiver.to_string()),
        message,
        arguments,
    );
    if target.arguments.is_empty() && !has_block(node) {
        if let (Some(receiver), Some(method)) = (receiver, method) {
            target.span = Some([
                span(receiver)[0],
                span(receiver)[1],
                span(method)[2],
                span(method)[3],
            ]);
        }
    }
    target.safe_navigation = safe_navigation(node, source);
    Some(target)
}

pub(crate) fn argument_list_node<'tree>(
    node: Node<'tree>,
    argument_list_kind: &str,
) -> Option<Node<'tree>> {
    node.child_by_field_name("arguments").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == argument_list_kind)
    })
}

fn first_named_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    named_children(node)
        .into_iter()
        .find(|child| kinds.contains(&child.kind()))
        .map(|child| node_text(child, source).to_string())
}

pub(crate) fn argument_texts<F>(
    node: Node<'_>,
    source: &str,
    argument_list_kind: &str,
    special_arguments: F,
) -> Vec<String>
where
    F: Fn(Node<'_>, &str) -> Option<Vec<String>>,
{
    let Some(args) = argument_list_node(node, argument_list_kind) else {
        return Vec::new();
    };
    if let Some(arguments) = special_arguments(args, source) {
        return arguments;
    }
    let values = named_children(args)
        .into_iter()
        .map(|child| normalize_text(node_text(child, source)))
        .collect::<Vec<_>>();
    if !values.is_empty() {
        return values;
    }

    let mut text = node_text(args, source).trim().to_string();
    if text.starts_with('(') && text.ends_with(')') && text.len() >= 2 {
        text = text[1..text.len() - 1].to_string();
    }
    text.split(',')
        .map(normalize_text)
        .filter(|arg| !arg.is_empty())
        .collect()
}

pub(crate) fn narrow_no_arg_call_span(
    node: Node<'_>,
    source: &str,
    receiver: &str,
    message: &str,
    adjust_leading_bang: bool,
) -> Option<[usize; 4]> {
    if message.is_empty() || message == "[]" || message == "[]=" {
        return None;
    }
    let needle = if receiver == "self" {
        message.to_string()
    } else {
        format!("{receiver}.{message}")
    };
    let node_span = span(node);
    if let Some(line_text) = source.lines().nth(node_span[0].saturating_sub(1)) {
        if let Some(start) = line_text.find(&needle) {
            let end = start + needle.chars().count();
            return Some([node_span[0], start, node_span[0], end]);
        }
    }
    let text = node_text(node, source);
    let offset = text.find(&needle)?;
    if text[..offset].contains('\n') || needle.contains('\n') {
        return None;
    }
    let mut start = node_span[1] + text[..offset].chars().count();
    let end = start + needle.chars().count();
    if adjust_leading_bang
        && start == node_span[1]
        && (previous_sibling_raw_text(node).as_deref() == Some("!")
            || node
                .start_byte()
                .checked_sub(1)
                .and_then(|index| source.as_bytes().get(index))
                .copied()
                == Some(b'!'))
    {
        start += 1;
    }
    Some([node_span[0], start, node_span[0], end])
}
