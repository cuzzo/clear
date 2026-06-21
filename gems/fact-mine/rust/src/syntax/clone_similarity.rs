use super::adapters::LanguageProfile;
use super::{CloneCandidate, Document, FunctionDef};
use crate::ast::{normalize_text, RawNode};
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
