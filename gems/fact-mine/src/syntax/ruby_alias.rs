//! Ruby-only normalization for the language-neutral allocation, alias, and
//! escape analysis. Concrete Ruby node kinds and method names must stay here.

// ALIAS-SPECIFIC START: Ruby allocation, alias, and escape vocabulary.

use crate::ast::{self, Child, Node};
use crate::syntax::cfg::aliasing::{
    AliasNormalizer, NormalizedAlias, NormalizedAliasEffects, NormalizedAllocation,
    NormalizedEscape,
};

pub(crate) fn normalizer() -> &'static dyn AliasNormalizer {
    static NORMALIZER: RubyAliasNormalizer = RubyAliasNormalizer;
    &NORMALIZER
}

struct RubyAliasNormalizer;

impl AliasNormalizer for RubyAliasNormalizer {
    fn effects(&self, node: &Node, _role: &str) -> NormalizedAliasEffects {
        let mut effects = NormalizedAliasEffects::default();
        normalize_top_level(node, &mut effects);
        effects.allocations.sort_by(|left, right| {
            left.place
                .cmp(&right.place)
                .then_with(|| left.kind.cmp(&right.kind))
        });
        effects.aliases.sort_by(|left, right| {
            left.destination
                .cmp(&right.destination)
                .then_with(|| left.source.cmp(&right.source))
        });
        effects.escapes.sort_by(|left, right| {
            left.place
                .cmp(&right.place)
                .then_with(|| left.sink.cmp(&right.sink))
        });
        effects.terminal_escapes.sort_by(|left, right| {
            left.place
                .cmp(&right.place)
                .then_with(|| left.sink.cmp(&right.sink))
        });
        effects
    }
}

fn normalize_top_level(node: &Node, effects: &mut NormalizedAliasEffects) {
    if write_node(node) {
        normalize_assignment(node, effects);
        return;
    }
    if node.r#type == "RETURN" {
        if let Some(value) = node.children.iter().find_map(ast::node) {
            if let Some(place) = alias_source(value) {
                effects.escapes.push(NormalizedEscape {
                    place,
                    sink: "return".to_string(),
                });
            }
        }
        return;
    }
    if let Some(place) = alias_source(node) {
        effects.terminal_escapes.push(NormalizedEscape {
            place,
            sink: "return".to_string(),
        });
    }
    normalize_call_escapes(node, effects);
}

fn normalize_assignment(node: &Node, effects: &mut NormalizedAliasEffects) {
    let Some(destination) = node_name(node) else {
        return;
    };
    let Some(rhs) = node.children.iter().skip(1).find_map(ast::node) else {
        return;
    };
    let semantic_rhs = transparent_value(rhs).unwrap_or(rhs);
    if let Some(kind) = allocation_kind(semantic_rhs) {
        effects.allocations.push(NormalizedAllocation {
            place: destination.clone(),
            kind,
        });
    } else if let Some(source) = alias_source(semantic_rhs) {
        effects.aliases.push(NormalizedAlias {
            destination: destination.clone(),
            source: source.clone(),
        });
        if non_local_write(node) {
            effects.escapes.push(NormalizedEscape {
                place: source,
                sink: field_sink(node).to_string(),
            });
        }
    }
    if non_local_write(node) && allocation_kind(semantic_rhs).is_some() {
        effects.escapes.push(NormalizedEscape {
            place: destination,
            sink: field_sink(node).to_string(),
        });
    }
    normalize_call_escapes(rhs, effects);
}

fn normalize_call_escapes(node: &Node, effects: &mut NormalizedAliasEffects) {
    let Some((receiver, message, arguments)) = call_parts(node) else {
        return;
    };
    if receiver.is_some_and(|receiver| receiver.text == "T")
        && matches!(message.as_str(), "let" | "cast" | "bind" | "must")
    {
        return;
    }
    let sink = if matches!(
        message.as_str(),
        "<<" | "push" | "append" | "unshift" | "store" | "[]="
    ) {
        "aggregate_store"
    } else {
        "unknown_call"
    };
    for argument in arguments {
        if let Some(place) = alias_source(argument) {
            effects.escapes.push(NormalizedEscape {
                place,
                sink: sink.to_string(),
            });
        }
    }
}

fn transparent_value(node: &Node) -> Option<&Node> {
    let (receiver, message, arguments) = call_parts(node)?;
    let receiver = receiver?;
    (receiver.text == "T" && matches!(message.as_str(), "let" | "cast" | "bind" | "must"))
        .then(|| arguments.first().copied())
        .flatten()
}

fn alias_source(node: &Node) -> Option<String> {
    if read_node(node) {
        return node_name(node);
    }
    if let Some(value) = transparent_value(node) {
        return alias_source(value);
    }
    if matches!(node.r#type.as_str(), "BEGIN" | "BLOCK" | "SCOPE") {
        let children = node
            .children
            .iter()
            .filter_map(ast::node)
            .collect::<Vec<_>>();
        if children.len() == 1 {
            return alias_source(children[0]);
        }
    }
    None
}

fn allocation_kind(node: &Node) -> Option<String> {
    match node.r#type.as_str() {
        "ARRAY" | "LIST" => return Some("array".to_string()),
        "HASH" => return Some("hash".to_string()),
        "STR" | "STRING" | "DSTR" => return Some("string".to_string()),
        _ => {}
    }
    let (receiver, message, _) = call_parts(node)?;
    if matches!(message.as_str(), "dup" | "clone") {
        return Some("copy".to_string());
    }
    if message == "new" {
        return Some(
            receiver
                .map(|receiver| format!("object:{}", receiver.text))
                .unwrap_or_else(|| "object".to_string()),
        );
    }
    None
}

fn call_parts(node: &Node) -> Option<(Option<&Node>, String, Vec<&Node>)> {
    match node.r#type.as_str() {
        "CALL" | "QCALL" | "OPCALL" | "ATTRASGN" => {
            let receiver = node.children.first().and_then(ast::node);
            let message = scalar(node.children.get(1)?)?;
            let arguments = node
                .children
                .get(2)
                .and_then(ast::node)
                .map(argument_nodes)
                .unwrap_or_default();
            Some((receiver, message, arguments))
        }
        "FCALL" | "VCALL" => {
            let message = scalar(node.children.first()?)?;
            let arguments = node
                .children
                .get(1)
                .and_then(ast::node)
                .map(argument_nodes)
                .unwrap_or_default();
            Some((None, message, arguments))
        }
        _ => None,
    }
}

fn argument_nodes(node: &Node) -> Vec<&Node> {
    if matches!(node.r#type.as_str(), "LIST" | "ARRAY" | "ARGUMENT_LIST") {
        node.children.iter().filter_map(ast::node).collect()
    } else {
        vec![node]
    }
}

fn scalar(child: &Child) -> Option<String> {
    match child {
        Child::String(value) | Child::Symbol(value) => Some(value.clone()),
        _ => None,
    }
}

fn node_name(node: &Node) -> Option<String> {
    node.children.first().and_then(scalar)
}

fn write_node(node: &Node) -> bool {
    matches!(
        node.r#type.as_str(),
        "LASGN" | "DASGN" | "IASGN" | "CVASGN" | "GASGN"
    )
}

fn non_local_write(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "IASGN" | "CVASGN" | "GASGN")
}

fn field_sink(node: &Node) -> &'static str {
    match node.r#type.as_str() {
        "GASGN" => "global_store",
        "CVASGN" => "class_store",
        _ => "field_store",
    }
}

fn read_node(node: &Node) -> bool {
    matches!(
        node.r#type.as_str(),
        "LVAR" | "DVAR" | "IVAR" | "CVAR" | "GVAR"
    )
}

// ALIAS-SPECIFIC END

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, children: Vec<Child>, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children,
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: text.len(),
            text: text.to_string(),
        }
    }

    fn boxed(node: Node) -> Child {
        Child::Node(Box::new(node))
    }

    #[test]
    fn distinguishes_alias_copy_and_return_escape() {
        let field = node("IVAR", vec![Child::String("@items".to_string())], "@items");
        let t = node("CONST", vec![Child::String("T".to_string())], "T");
        let args = node("LIST", vec![boxed(field)], "@items, T::Array[String]");
        let let_call = node(
            "CALL",
            vec![boxed(t), Child::Symbol("let".to_string()), boxed(args)],
            "T.let(@items, T::Array[String])",
        );
        let assignment = node(
            "LASGN",
            vec![Child::String("items".to_string()), boxed(let_call)],
            "items = T.let(@items, T::Array[String])",
        );
        assert_eq!(
            normalizer()
                .effects(&assignment, "linear_statement")
                .aliases,
            vec![NormalizedAlias {
                destination: "items".to_string(),
                source: "@items".to_string(),
            }]
        );

        let receiver = node("LVAR", vec![Child::String("items".to_string())], "items");
        let copy = node(
            "CALL",
            vec![
                boxed(receiver),
                Child::Symbol("dup".to_string()),
                Child::Nil,
            ],
            "items.dup",
        );
        let copy_assignment = node(
            "LASGN",
            vec![Child::String("copy".to_string()), boxed(copy)],
            "copy = items.dup",
        );
        assert_eq!(
            normalizer()
                .effects(&copy_assignment, "linear_statement")
                .allocations,
            vec![NormalizedAllocation {
                place: "copy".to_string(),
                kind: "copy".to_string(),
            }]
        );

        let returned = node("LVAR", vec![Child::String("items".to_string())], "items");
        let return_node = node("RETURN", vec![boxed(returned)], "return items");
        assert_eq!(
            normalizer().effects(&return_node, "return").escapes,
            vec![NormalizedEscape {
                place: "items".to_string(),
                sink: "return".to_string(),
            }]
        );
    }
}
