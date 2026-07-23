use super::CloneCandidate;
use crate::ast::{normalize_text, Child, Node};
use std::collections::HashSet;

pub(crate) fn clone_candidates_from_normalized(
    file: &str,
    normalized_root: &Node,
) -> Vec<CloneCandidate> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    normalized_walk_candidates(file, normalized_root, None, &mut out, &mut seen);
    out
}

fn normalized_walk_candidates(
    file: &str,
    node: &Node,
    function_name: Option<String>,
    out: &mut Vec<CloneCandidate>,
    seen: &mut HashSet<String>,
) {
    let current_function = normalized_function_name(node).or(function_name);
    if normalized_candidate_node(node) {
        normalized_add_candidate(
            out,
            seen,
            normalized_clone_candidate_for(file, node, current_function.as_deref()),
        );
    }

    for child in normalized_node_children(node) {
        normalized_walk_candidates(file, child, current_function.clone(), out, seen);
    }
}

fn normalized_add_candidate(
    out: &mut Vec<CloneCandidate>,
    seen: &mut HashSet<String>,
    candidate: Option<CloneCandidate>,
) {
    let Some(candidate) = candidate else { return };
    let key = format!(
        "{}\0{}\0{:?}\0{}\0{}",
        candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint
    );
    if seen.insert(key) {
        out.push(candidate);
    }
}

fn normalized_clone_candidate_for(
    file: &str,
    node: &Node,
    function_name: Option<&str>,
) -> Option<CloneCandidate> {
    let (fingerprint, mass) = normalized_fingerprint_for(node, &mut HashSet::new());
    if fingerprint.is_empty() || mass == 0 {
        return None;
    }

    let child_data = normalized_candidate_children(node)
        .into_iter()
        .map(|child| normalized_fingerprint_for(child, &mut HashSet::new()))
        .filter(|(fingerprint, mass)| !fingerprint.is_empty() && *mass > 0)
        .collect::<Vec<_>>();

    Some(CloneCandidate {
        file: file.to_string(),
        line: node.first_lineno,
        span: [
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ],
        method_name: function_name.unwrap_or("(top-level)").to_string(),
        node_name: normalized_node_name(node),
        mass,
        fingerprint,
        raw: normalize_text(&node.text),
        child_fingerprints: child_data
            .iter()
            .map(|(fingerprint, _)| fingerprint.clone())
            .collect(),
        child_masses: child_data.iter().map(|(_, mass)| *mass).collect(),
    })
}

fn normalized_candidate_node(node: &Node) -> bool {
    !NORMALIZED_CLONE_SKIP_TYPES.contains(&node.r#type.as_str())
        && NORMALIZED_CLONE_CANDIDATE_TYPES.contains(&node.r#type.as_str())
        && !normalized_node_children(node).is_empty()
}

fn normalized_candidate_children(node: &Node) -> Vec<&Node> {
    let source = normalized_body_node(node).unwrap_or(node);
    normalized_node_children(source)
        .into_iter()
        .filter(|child| !NORMALIZED_CLONE_SKIP_TYPES.contains(&child.r#type.as_str()))
        .collect()
}

fn normalized_body_node(node: &Node) -> Option<&Node> {
    normalized_node_children(node)
        .into_iter()
        .find(|child| child.r#type == "BLOCK")
}

fn normalized_fingerprint_for(node: &Node, active: &mut HashSet<usize>) -> (String, usize) {
    let key = node as *const Node as usize;
    if active.contains(&key) {
        return (String::new(), 0);
    }

    active.insert(key);
    let out = if let Some(token) = normalized_terminal_token(node) {
        (token, 1)
    } else {
        let mut parts = normalized_scalar_tokens(node);
        let mut mass = 1;
        for child in normalized_node_children(node) {
            let (child_fp, child_mass) = normalized_fingerprint_for(child, active);
            if child_fp.is_empty() {
                continue;
            }
            parts.push(child_fp);
            mass += child_mass;
        }

        if parts.is_empty() {
            (String::new(), 0)
        } else {
            (
                format!(
                    "{}({})",
                    normalized_fingerprint_label(node),
                    parts.join(" ")
                ),
                mass,
            )
        }
    };
    active.remove(&key);
    out
}

fn normalized_scalar_tokens(node: &Node) -> Vec<String> {
    node.children
        .iter()
        .filter(|child| !matches!(child, Child::Node(_)))
        .filter_map(normalized_scalar_token)
        .collect()
}

fn normalized_scalar_token(child: &Child) -> Option<String> {
    let text = match child {
        Child::Symbol(value) | Child::String(value) => value.clone(),
        Child::Integer(value) => value.to_string(),
        Child::Bool(value) => value.to_string(),
        Child::Nil => String::new(),
        Child::Node(_) => String::new(),
    };
    if text.is_empty() {
        return None;
    }

    if normalized_identifier_text(&text) {
        Some("id".to_string())
    } else {
        Some("lit".to_string())
    }
}

fn normalized_fingerprint_label(node: &Node) -> String {
    let label = normalized_public_node_type(node);
    if let Some(message) = normalized_call_message(node) {
        format!("{label}<{message}>")
    } else {
        label
    }
}

fn normalized_call_message(node: &Node) -> Option<String> {
    if !matches!(
        node.r#type.as_str(),
        "CALL" | "QCALL" | "FCALL" | "VCALL" | "ATTRASGN"
    ) {
        return None;
    }

    let message = match node.r#type.as_str() {
        "CALL" | "QCALL" | "ATTRASGN" => normalized_scalar_child(node, 1),
        _ => normalized_scalar_child(node, 0),
    }?;
    let args = normalized_child_node(
        node,
        if matches!(node.r#type.as_str(), "CALL" | "QCALL" | "ATTRASGN") {
            2
        } else {
            1
        },
    )?;
    if normalized_node_children(args).is_empty() {
        return None;
    }

    Some(message)
}

fn normalized_terminal_token(node: &Node) -> Option<String> {
    if NORMALIZED_CLONE_IDENTIFIER_TYPES.contains(&node.r#type.as_str()) {
        return Some("id".to_string());
    }
    if matches!(node.r#type.as_str(), "TRUE" | "FALSE") {
        return Some("bool".to_string());
    }
    if node.r#type == "NIL" {
        return Some("nil".to_string());
    }
    if NORMALIZED_CLONE_LITERAL_TYPES.contains(&node.r#type.as_str()) {
        return Some("lit".to_string());
    }

    if normalized_node_children(node).is_empty() {
        let scalars = node
            .children
            .iter()
            .filter(|child| !matches!(child, Child::Node(_)))
            .filter_map(|child| {
                let text = normalized_child_text(child);
                if text.is_empty() {
                    None
                } else if normalized_identifier_text(&text) {
                    Some("id".to_string())
                } else {
                    Some(text)
                }
            })
            .collect::<Vec<_>>();
        if !scalars.is_empty() {
            return Some(scalars.join(":"));
        }
    }

    None
}

fn normalized_node_name(node: &Node) -> String {
    match node.r#type.as_str() {
        "DEFN" => "defn".to_string(),
        "DEFS" => "defs".to_string(),
        _ => normalized_public_node_type(node),
    }
}

fn normalized_public_node_type(node: &Node) -> String {
    match node.r#type.as_str() {
        "CLASS" => "class",
        "MODULE" => "module",
        "SCOPE" => "body",
        "BLOCK" => "body_statement",
        "DEFN" | "DEFS" => "method",
        "ARGS" => "parameters",
        "LASGN" | "DASGN" | "IASGN" | "GASGN" | "MASGN" | "ATTRASGN" | "OP_ASGN1" | "OP_ASGN2" => {
            "assignment"
        }
        "IF" => "if",
        "UNLESS" => "unless",
        "CASE" | "CASE2" => "case",
        "MATCH" | "MATCH2" | "MATCH3" => "match",
        "WHEN" => "when",
        "CALL" | "QCALL" | "FCALL" | "VCALL" | "OPCALL" => "call",
        "LIST" => "argument_list",
        "HASH" => "hash",
        "ITER" => "block",
        "AND" => "and",
        "OR" => "or",
        "FOR" => "for",
        "WHILE" => "while",
        "UNTIL" => "until",
        other => return other.to_ascii_lowercase(),
    }
    .to_string()
}

fn normalized_function_name(node: &Node) -> Option<String> {
    match node.r#type.as_str() {
        "DEFS" => normalized_scalar_child(node, 1),
        "DEFN" => normalized_scalar_child(node, 0),
        _ => None,
    }
}

fn normalized_node_children(node: &Node) -> Vec<&Node> {
    node.children
        .iter()
        .filter_map(|child| match child {
            Child::Node(node) => Some(node.as_ref()),
            _ => None,
        })
        .collect()
}

fn normalized_child_node(node: &Node, index: usize) -> Option<&Node> {
    match node.children.get(index) {
        Some(Child::Node(child)) => Some(child.as_ref()),
        _ => None,
    }
}

fn normalized_scalar_child(node: &Node, index: usize) -> Option<String> {
    node.children
        .get(index)
        .map(normalized_child_text)
        .and_then(|text| if text.is_empty() { None } else { Some(text) })
}

fn normalized_child_text(child: &Child) -> String {
    match child {
        Child::Symbol(value) | Child::String(value) => value.clone(),
        Child::Integer(value) => value.to_string(),
        Child::Bool(value) => value.to_string(),
        Child::Nil | Child::Node(_) => String::new(),
    }
}

fn normalized_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first.is_ascii_alphabetic() || matches!(first, '_' | '@' | ':' | '$'))
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '?' | '!' | '='))
}

const NORMALIZED_CLONE_CANDIDATE_TYPES: &[&str] = &[
    "DEFN", "DEFS", "BLOCK", "IF", "UNLESS", "CASE", "CASE2", "MATCH", "MATCH2", "MATCH3", "WHEN",
    "AND", "OR", "FOR", "WHILE", "UNTIL", "ITER", "CALL", "QCALL", "FCALL", "VCALL", "OPCALL",
    "OP_ASGN1", "OP_ASGN2", "ATTRASGN", "HASH", "LIST",
];
const NORMALIZED_CLONE_SKIP_TYPES: &[&str] = &["ROOT", "SCOPE", "ARGS", "ZLIST"];
const NORMALIZED_CLONE_IDENTIFIER_TYPES: &[&str] =
    &["LVAR", "DVAR", "IVAR", "GVAR", "CONST", "SELF"];
const NORMALIZED_CLONE_LITERAL_TYPES: &[&str] = &[
    "STR",
    "DSTR",
    "XSTR",
    "RAW_ARGUMENT",
    "FIELD_EXPRESSION",
    "INTEGER",
    "LIT",
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn test_cycle_detection() {
        let node = Node {
            r#type: "BLOCK".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        let mut active = HashSet::new();
        let key = &node as *const Node as usize;
        active.insert(key);
        let (fp, mass) = normalized_fingerprint_for(&node, &mut active);
        assert_eq!(fp, "");
        assert_eq!(mass, 0);
    }

    #[test]
    fn test_scalar_tokens() {
        let child_node = Child::Node(Box::new(Node {
            r#type: "LVAR".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        }));
        assert_eq!(normalized_scalar_token(&child_node), None);
        assert_eq!(
            normalized_scalar_token(&Child::Integer(42)),
            Some("lit".to_string())
        );
        assert_eq!(
            normalized_scalar_token(&Child::Bool(true)),
            Some("id".to_string())
        );
        assert_eq!(normalized_scalar_token(&Child::Nil), None);
    }

    #[test]
    fn test_empty_call_arguments() {
        let rec = Node {
            r#type: "SELF".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "self".to_string(),
        };
        let args = Node {
            r#type: "ARGS".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        let call_node = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(rec)),
                Child::Symbol("foo".to_string()),
                Child::Node(Box::new(args)),
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "self.foo()".to_string(),
        };
        assert_eq!(normalized_call_message(&call_node), None);
    }

    #[test]
    fn test_normalized_call_message_none_message() {
        let rec = Node {
            r#type: "SELF".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "self".to_string(),
        };
        let args = Node {
            r#type: "ARGS".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        let call_node = Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(rec)),
                Child::Nil,
                Child::Node(Box::new(args)),
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "self.foo()".to_string(),
        };
        assert_eq!(normalized_call_message(&call_node), None);
    }

    #[test]
    fn test_non_identifier_scalar_text() {
        let node = Node {
            r#type: "LIT_VAL".to_string(),
            children: vec![Child::Symbol("123".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "123".to_string(),
        };
        let token = normalized_terminal_token(&node);
        assert_eq!(token, Some("123".to_string()));
    }

    #[test]
    fn test_normalized_child_text_types() {
        assert_eq!(normalized_child_text(&Child::Integer(100)), "100");
        assert_eq!(normalized_child_text(&Child::Bool(false)), "false");
    }

    #[test]
    fn test_normalized_identifier_empty() {
        assert!(!normalized_identifier_text(""));
    }
}
