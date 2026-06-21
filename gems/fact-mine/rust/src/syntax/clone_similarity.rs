use super::adapters::LanguageProfile;
use super::{CloneCandidate, Document, FunctionDef};
use crate::ast::{normalize_text, Child, Node, RawNode};
use std::collections::{HashMap, HashSet};

const CLONE_IDENTIFIER_KINDS: &[&str] = &[
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "shorthand_property_identifier_pattern",
    "simple_identifier",
    "variable_name",
];
const CLONE_LITERAL_KINDS: &[&str] = &[
    "string",
    "string_content",
    "string_literal",
    "interpreted_string_literal",
    "raw_string_literal",
    "integer",
    "float",
    "int",
    "number",
    "rational",
    "imaginary",
    "character",
    "char_literal",
    "symbol",
    "simple_symbol",
    "true",
    "false",
    "nil",
    "none",
    "null",
];
const CLONE_SKIP_KINDS: &[&str] = &[
    "comment",
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "parameters",
    "formal_parameters",
    "parameter_list",
    "argument_list",
    "arguments",
    "block_parameters",
    "call_suffix",
    "function_value_parameters",
    "method_parameters",
    "value_argument",
    "scope_resolution",
];
const CLONE_CANDIDATE_KINDS: &[&str] = &[
    "array",
    "assignment",
    "assignment_statement",
    "body_statement",
    "block",
    "case",
    "case_clause",
    "class",
    "class_definition",
    "class_declaration",
    "compound_statement",
    "conjunction_expression",
    "control_structure_body",
    "do_block",
    "enum_declaration",
    "for",
    "for_statement",
    "function_body",
    "hash",
    "if",
    "if_statement",
    "match_expression",
    "match_statement",
    "method",
    "method_definition",
    "module",
    "operator_assignment",
    "singleton_method",
    "statements",
    "struct_declaration",
    "switch_case",
    "switch_expression",
    "switch_statement",
    "unless",
    "until",
    "while",
    "while_statement",
];
const CLONE_BODY_KINDS: &[&str] = &[
    "body",
    "body_statement",
    "block",
    "body_statement",
    "declaration_list",
    "statement_block",
    "compound_statement",
    "function_body",
    "statements",
    "suite",
    "do_block",
];
const CLONE_CALL_KINDS: &[&str] = &[
    "call",
    "call_expression",
    "function_call",
    "method_call",
    "method_invocation",
    "invocation_expression",
];

pub(crate) fn clone_candidates_for_profile(
    _profile: &dyn LanguageProfile,
    document: &Document,
) -> Vec<CloneCandidate> {
    return normalized_clone_candidates(document);
}

fn normalized_clone_candidates(document: &Document) -> Vec<CloneCandidate> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    normalized_walk_candidates(
        document,
        &document.normalized_root,
        None,
        &mut out,
        &mut seen,
    );
    out
}

fn normalized_walk_candidates(
    document: &Document,
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
            normalized_clone_candidate_for(document, node, current_function.as_deref()),
        );
    }

    for child in normalized_node_children(node) {
        normalized_walk_candidates(document, child, current_function.clone(), out, seen);
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
    document: &Document,
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
        file: document.file.clone(),
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
        "FCALL" | "VCALL" => normalized_scalar_child(node, 0),
        _ => None,
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
    "DEFN", "DEFS", "BLOCK", "IF", "UNLESS", "CASE", "CASE2", "WHEN", "AND", "OR", "FOR", "WHILE",
    "UNTIL", "ITER", "CALL", "QCALL", "FCALL", "VCALL", "OPCALL", "OP_ASGN1", "OP_ASGN2",
    "ATTRASGN", "HASH", "LIST",
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

#[allow(dead_code)]
fn raw_clone_candidates_for_profile(
    profile: &dyn LanguageProfile,
    document: &Document,
) -> Vec<CloneCandidate> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut fingerprint_cache = HashMap::new();

    for function in &document.function_defs {
        let candidate = clone_candidate_for(
            profile,
            document,
            &function.body,
            Some("defn"),
            Some(function.name.as_str()),
            &mut fingerprint_cache,
        );
        clone_add_candidate(&mut out, &mut seen, candidate);
    }

    let mut nodes = Vec::new();
    document.root.walk(&mut nodes);
    for node in nodes {
        if profile.clone_candidate_node(node) {
            let candidate =
                clone_candidate_for(profile, document, node, None, None, &mut fingerprint_cache);
            clone_add_candidate(&mut out, &mut seen, candidate);
        }
    }

    out
}

pub(crate) fn default_clone_candidate_node(node: &RawNode) -> bool {
    node.named
        && !CLONE_SKIP_KINDS.contains(&node.kind.as_str())
        && CLONE_CANDIDATE_KINDS.contains(&node.kind.as_str())
        && !clone_typed_struct_schema_text(&node.text)
        && !node.named_children().is_empty()
}

fn clone_add_candidate(
    out: &mut Vec<CloneCandidate>,
    seen: &mut HashSet<String>,
    candidate: Option<CloneCandidate>,
) {
    let Some(candidate) = candidate else { return };
    if clone_typed_struct_schema_text(&candidate.raw) {
        return;
    }
    let key = format!(
        "{}\0{}\0{:?}\0{}\0{}",
        candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint
    );
    if seen.insert(key) {
        out.push(candidate);
    }
}

fn clone_candidate_for(
    profile: &dyn LanguageProfile,
    document: &Document,
    node: &RawNode,
    node_name: Option<&str>,
    function_name: Option<&str>,
    fingerprint_cache: &mut HashMap<usize, (String, usize)>,
) -> Option<CloneCandidate> {
    let (fingerprint, mass) =
        clone_fingerprint_for_profile(profile, node, &mut HashSet::new(), fingerprint_cache);
    if fingerprint.is_empty() {
        return None;
    }

    let line = node.line();
    let method = clone_method_span_for(document, line);
    let children = clone_fuzzy_children_for(profile, node);
    let mut child_fingerprints = Vec::new();
    let mut child_masses = Vec::new();
    for child in children {
        let (child_fp, child_mass) =
            clone_fingerprint_for_profile(profile, child, &mut HashSet::new(), fingerprint_cache);
        if !child_fp.is_empty() && child_mass > 0 {
            child_fingerprints.push(child_fp);
            child_masses.push(child_mass);
        }
    }

    Some(CloneCandidate {
        file: document.file.clone(),
        line,
        span: node.span,
        method_name: function_name
            .map(ToString::to_string)
            .or_else(|| method.map(|function| function.name.clone()))
            .unwrap_or_else(|| "(top-level)".to_string()),
        node_name: node_name
            .map(ToString::to_string)
            .unwrap_or_else(|| clone_node_name(node).to_string()),
        mass,
        fingerprint,
        raw: normalize_text(&node.text),
        child_fingerprints,
        child_masses,
    })
}

fn clone_fuzzy_children_for<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
) -> Vec<&'a RawNode> {
    let source = clone_body_node_for(profile, node).unwrap_or(node);
    let mut children = profile
        .clone_fingerprint_children(source)
        .into_iter()
        .filter(|child| child.named)
        .collect::<Vec<_>>();
    if children.is_empty() {
        children = profile
            .clone_fingerprint_children(node)
            .into_iter()
            .filter(|child| child.named)
            .collect();
    }
    children
        .into_iter()
        .filter(|child| {
            !CLONE_SKIP_KINDS.contains(&child.kind.as_str())
                && !clone_typed_struct_schema_text(&child.text)
        })
        .collect()
}

fn clone_body_node_for<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
) -> Option<&'a RawNode> {
    clone_body_node(node).or_else(|| {
        profile
            .clone_fingerprint_children(node)
            .into_iter()
            .find(|child| CLONE_BODY_KINDS.contains(&child.kind.as_str()))
    })
}

fn clone_body_node(node: &RawNode) -> Option<&RawNode> {
    node.children
        .iter()
        .find(|child| CLONE_BODY_KINDS.contains(&child.kind.as_str()))
}

fn clone_fingerprint_for_profile(
    profile: &dyn LanguageProfile,
    node: &RawNode,
    active: &mut HashSet<String>,
    cache: &mut HashMap<usize, (String, usize)>,
) -> (String, usize) {
    let cache_key = clone_node_ptr(node);
    if let Some(cached) = cache.get(&cache_key) {
        return cached.clone();
    }

    let active_key = clone_node_key(node);
    if active.contains(&active_key) || node.kind == "comment" {
        return (String::new(), 0);
    }
    active.insert(active_key.clone());
    let out = if CLONE_CALL_KINDS.contains(&node.kind.as_str())
        && clone_call_message(node).is_some()
    {
        clone_fingerprint_call(profile, node, active, cache)
    } else if node.children.is_empty() {
        let token = clone_terminal_token(node);
        if token.is_empty() {
            (String::new(), 0)
        } else {
            (token, 1)
        }
    } else {
        let mut child_parts = Vec::new();
        let mut mass = 1;
        for child in profile.clone_fingerprint_children(node) {
            let (child_fp, child_mass) = profile
                .clone_child_fingerprint(node, child)
                .unwrap_or_else(|| clone_fingerprint_for_profile(profile, child, active, cache));
            if child_fp.is_empty() {
                continue;
            }
            child_parts.push(child_fp);
            mass += child_mass;
        }
        if child_parts.is_empty() {
            (clone_terminal_token(node), 1)
        } else {
            (format!("{}({})", node.kind, child_parts.join(" ")), mass)
        }
    };
    active.remove(&active_key);
    cache.insert(cache_key, out.clone());
    out
}

fn clone_fingerprint_call(
    profile: &dyn LanguageProfile,
    node: &RawNode,
    active: &mut HashSet<String>,
    cache: &mut HashMap<usize, (String, usize)>,
) -> (String, usize) {
    let message = clone_call_message(node).unwrap_or_default();
    let mut child_parts = Vec::new();
    let mut mass = 1;
    for child in profile.clone_fingerprint_children(node) {
        let (child_fp, child_mass) = profile
            .clone_child_fingerprint(node, child)
            .unwrap_or_else(|| clone_fingerprint_for_profile(profile, child, active, cache));
        if child_fp.is_empty() {
            continue;
        }
        child_parts.push(child_fp);
        mass += child_mass;
    }
    (
        format!("{}<{}>({})", node.kind, message, child_parts.join(" ")),
        mass,
    )
}

fn clone_call_message(node: &RawNode) -> Option<String> {
    if !node.children.iter().any(|child| {
        matches!(
            child.kind.as_str(),
            "argument_list" | "arguments" | "call_suffix"
        )
    }) {
        return None;
    }
    let argument_start = node
        .children
        .iter()
        .find(|child| {
            matches!(
                child.kind.as_str(),
                "argument_list" | "arguments" | "call_suffix"
            )
        })
        .map(|child| (child.span[0], child.span[1]));
    let named_before_args = node
        .named_children()
        .into_iter()
        .filter(|child| {
            argument_start
                .map(|start| (child.span[0], child.span[1]) < start)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    named_before_args
        .last()
        .and_then(|callee| clone_callee_message(callee))
}

fn clone_callee_message(node: &RawNode) -> Option<String> {
    if CLONE_IDENTIFIER_KINDS.contains(&node.kind.as_str()) {
        return Some(node.text.clone());
    }
    if matches!(
        node.kind.as_str(),
        "navigation_expression" | "directly_assignable_expression"
    ) {
        return clone_navigation_suffix_message(node);
    }

    node.named_children()
        .into_iter()
        .rev()
        .find(|child| CLONE_IDENTIFIER_KINDS.contains(&child.kind.as_str()))
        .map(|child| child.text.clone())
}

fn clone_navigation_suffix_message(node: &RawNode) -> Option<String> {
    let suffix = node
        .named_children()
        .into_iter()
        .rev()
        .find(|child| child.kind == "navigation_suffix")?;
    suffix
        .named_children()
        .into_iter()
        .rev()
        .find(|child| CLONE_IDENTIFIER_KINDS.contains(&child.kind.as_str()))
        .map(|child| child.text.clone())
}

fn clone_terminal_token(node: &RawNode) -> String {
    let kind = node.kind.as_str();
    if CLONE_IDENTIFIER_KINDS.contains(&kind) {
        return "id".to_string();
    }
    if CLONE_LITERAL_KINDS.contains(&kind) {
        return clone_literal_token(kind).to_string();
    }
    let text = normalize_text(&node.text);
    if text.is_empty() {
        return String::new();
    }
    if clone_identifier_text(&text) {
        return "id".to_string();
    }
    if clone_literal_text(&text) {
        return "lit".to_string();
    }
    format!("{kind}:{text}")
}

fn clone_literal_token(kind: &str) -> &str {
    match kind {
        "true" | "false" => "bool",
        "nil" | "none" | "null" => "nil",
        _ => "lit",
    }
}

fn clone_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| {
            char == '_' || char == '!' || char == '?' || char == '=' || char.is_ascii_alphanumeric()
        })
}

fn clone_literal_text(text: &str) -> bool {
    if clone_symbol_literal_text(text)
        || clone_quoted_literal_text(text, '"')
        || clone_quoted_literal_text(text, '\'')
    {
        return true;
    }
    text.parse::<f64>().is_ok()
}

fn clone_symbol_literal_text(text: &str) -> bool {
    let mut chars = text.chars();
    if chars.next() != Some(':') {
        return false;
    }
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| char == '_' || char.is_ascii_alphanumeric())
}

fn clone_quoted_literal_text(text: &str, quote: char) -> bool {
    text.len() >= 2 && text.starts_with(quote) && text.ends_with(quote)
}

fn clone_node_name(node: &RawNode) -> &str {
    match node.kind.as_str() {
        "method"
        | "function_definition"
        | "function_declaration"
        | "method_definition"
        | "function_item" => "defn",
        "singleton_method" => "defs",
        other => other,
    }
}

fn clone_typed_struct_schema_text(text: &str) -> bool {
    text.contains("< T::Struct")
        || text.contains("<T::Struct")
        || text.lines().all(|line| {
            let stripped = line.trim();
            stripped.is_empty() || stripped.starts_with("const :") || stripped.starts_with("prop :")
        })
}

fn clone_method_span_for(document: &Document, line_no: usize) -> Option<&FunctionDef> {
    document
        .function_defs
        .iter()
        .find(|function| function.span[0] <= line_no && line_no <= function.span[2])
}

fn clone_node_key(node: &RawNode) -> String {
    format!(
        "{}\0{}\0{}\0{}\0{}\0{}",
        node.kind,
        node.span[0],
        node.span[1],
        node.span[2],
        node.span[3],
        node.text.len()
    )
}

fn clone_node_ptr(node: &RawNode) -> usize {
    node as *const RawNode as usize
}
