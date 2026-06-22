use crate::syntax::{parser_grammar::grammar_for_language, Language};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use tree_sitter::{Node as TreeSitterNode, Parser};

mod adapters;
mod normalizer;
pub(in crate::ast) use normalizer::TreeSitterNormalizer;

pub type Span = [usize; 4];
const COMPARISON_OPERATORS: &[&str] = &["==", "!=", "===", "!==", "<", "<=", ">", ">="];
const OPERATOR_CALL_OPERATORS: &[&str] = &[
    "+", "-", "*", "/", "%", "**", "|", "&", "^", "<<", ">>", "=~", "!~",
];
const BINARY_WRAPPER_KINDS: &[&str] = &[
    "binary",
    "binary_expression",
    "binary_operator",
    "boolean_operator",
    "comparison_operator",
];
const BOOLEAN_EXPRESSION_KINDS: &[&str] = &["binary", "binary_expression", "boolean_operator"];
const COMPARISON_EXPRESSION_KINDS: &[&str] =
    &["binary", "binary_expression", "comparison_operator"];
const DOTTED_EXPRESSION_WRAPPER_KINDS: &[&str] =
    &["body_statement", "block_body", "statement", "argument_list"];

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct RawNode {
    pub kind: String,
    pub text: String,
    pub span: Span,
    pub named: bool,
    pub field_name: Option<String>,
    pub children: Vec<RawNode>,
}

impl RawNode {
    pub fn from_tree_sitter(node: TreeSitterNode<'_>, source: &str) -> Self {
        let mut cursor = node.walk();
        let mut children: Vec<RawNode> = node
            .children(&mut cursor)
            .enumerate()
            .map(|(index, child)| {
                let mut raw = Self::from_tree_sitter(child, source);
                raw.field_name = node.field_name_for_child(index as u32).map(str::to_string);
                raw
            })
            .collect();

        if node.kind() == "argument_list"
            && !node_text(node, source).trim_start().starts_with('(')
            && children.len() == 1
            && children[0].kind == "scope_resolution"
        {
            children = children[0].children.clone();
        }

        if node.kind() == "call" {
            let mut flattened = Vec::new();
            for child in children {
                if child.kind == "argument_list"
                    && !child.text.trim_start().starts_with('(')
                    && child.children.len() == 1
                    && child.children[0].kind != "scope_resolution"
                {
                    flattened.extend(child.children);
                } else {
                    flattened.push(child);
                }
            }
            children = flattened;
        }

        if node.kind() == "bare_string" {
            children.clear();
        }

        if matches!(node.kind(), "return" | "next" | "break" | "yield") {
            let mut flattened = Vec::new();
            for child in children {
                if child.kind == "argument_list" {
                    flattened.extend(child.children);
                } else {
                    flattened.push(child);
                }
            }
            children = flattened;
        }

        if node.kind() == "pattern" && children.len() == 1 && children[0].kind == "scope_resolution"
        {
            children = children[0].children.clone();
        }

        if node.kind() == "when" {
            let mut flattened = Vec::new();
            for child in children {
                if child.kind == "pattern"
                    && child.children.len() == 1
                    && child.children[0].kind != "scope_resolution"
                {
                    flattened.extend(child.children);
                } else {
                    flattened.push(child);
                }
            }
            children = flattened;
        }

        if node.kind() == "body_statement" && children.len() == 1 && children[0].kind == "array" {
            children = children[0].children.clone();
        }
        if node.kind() == "body_statement" && children.len() == 1 && children[0].kind == "call" {
            children = children[0].children.clone();
        }
        if node.kind() == "body_statement"
            && children.len() == 1
            && children[0].kind == "conditional"
        {
            children = children[0].children.clone();
        }
        if node.kind() == "body_statement" && children.len() == 1 && children[0].kind == "module" {
            children = children[0].children.clone();
        }
        if node.kind() == "body_statement" && children.len() == 1 && children[0].kind == "binary" {
            children = children[0].children.clone();
        }
        if node.kind() == "body_statement"
            && children.len() == 1
            && children[0].kind == "assignment"
            && children[0]
                .children
                .first()
                .map(|child| child.kind == "element_reference")
                .unwrap_or(false)
        {
            children = children[0].children.clone();
        }
        if node.kind() == "block_body" && children.len() == 1 && children[0].kind == "call" {
            children = children[0].children.clone();
        }
        if node.kind() == "block_body" && children.len() == 1 && children[0].kind == "assignment" {
            children = children[0].children.clone();
        }
        if node.kind() == "block_body"
            && children.len() == 1
            && matches!(
                children[0].kind.as_str(),
                "array" | "binary" | "string" | "unary"
            )
        {
            children = children[0].children.clone();
        }

        Self {
            kind: node.kind().to_string(),
            text: node_text(node, source).to_string(),
            span: span(node),
            named: node.is_named(),
            field_name: None,
            children,
        }
    }

    pub fn named_children(&self) -> Vec<&RawNode> {
        self.children.iter().filter(|child| child.named).collect()
    }

    pub fn walk<'a>(&'a self, out: &mut Vec<&'a RawNode>) {
        out.push(self);
        for child in &self.children {
            child.walk(out);
        }
    }

    pub fn line(&self) -> usize {
        self.span[0]
    }
}

pub fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn span(node: TreeSitterNode<'_>) -> Span {
    let start = node.start_position();
    let end = node.end_position();
    [start.row + 1, start.column, end.row + 1, end.column]
}

pub fn line(node: TreeSitterNode<'_>) -> usize {
    node.start_position().row + 1
}

pub fn node_text<'a>(node: TreeSitterNode<'_>, source: &'a str) -> &'a str {
    node.utf8_text(source.as_bytes()).unwrap_or("")
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum Child {
    Node(Box<Node>),
    Symbol(String),
    String(String),
    Integer(i64),
    Bool(bool),
    Nil,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct Node {
    pub r#type: String,
    pub children: Vec<Child>,
    pub first_lineno: usize,
    pub first_column: usize,
    pub last_lineno: usize,
    pub last_column: usize,
    pub text: String,
}

pub fn parse(file: &Path) -> Result<(Node, Vec<String>)> {
    let language = file
        .extension()
        .and_then(|extension| extension.to_str())
        .and_then(Language::for_extension)
        .with_context(|| format!("unsupported source extension for {}", file.display()))?;
    parse_with_language(file, language)
}

pub fn parse_with_language(file: &Path, language: Language) -> Result<(Node, Vec<String>)> {
    let source =
        fs::read_to_string(file).with_context(|| format!("failed to read {}", file.display()))?;
    let mut parser = Parser::new();
    parser
        .set_language(&grammar_for_language(language))
        .with_context(|| "failed to initialize tree-sitter parser")?;
    let tree = parser
        .parse(&source, None)
        .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
    let root = normalize_tree(tree.root_node(), &source, language);
    let lines = source.lines().map(ToString::to_string).collect();
    Ok((root, lines))
}

pub fn normalize_tree(root: TreeSitterNode<'_>, source: &str, language: Language) -> Node {
    TreeSitterNormalizer::new(source, language).normalize(root)
}

pub fn node(child: &Child) -> Option<&Node> {
    match child {
        Child::Node(node) => Some(node),
        _ => None,
    }
}

pub fn slice(node: &Node, _lines: &[String]) -> String {
    normalize_text(&node.text)
}

pub fn body_stmts(defn_node: &Node) -> Vec<&Node> {
    let scope_index = if defn_node.r#type == "DEFS" { 2 } else { 1 };
    let Some(scope) = defn_node.children.get(scope_index).and_then(node) else {
        return Vec::new();
    };
    if scope.r#type != "SCOPE" {
        return Vec::new();
    }
    let Some(body) = scope.children.get(2).and_then(node) else {
        return Vec::new();
    };
    statement_nodes(body)
}

fn statement_nodes(body: &Node) -> Vec<&Node> {
    match body.r#type.as_str() {
        "BLOCK" | "COMPOUND_STATEMENT" | "DECLARATION_LIST" | "FUNCTION_BODY" | "HASH"
        | "STATEMENTS" => body.children.iter().filter_map(node).collect(),
        "RESCUE" | "ENSURE" => {
            let mut out = Vec::new();
            if let Some(primary) = body.children.first().and_then(node) {
                out.extend(statement_nodes(primary));
            }
            out.extend(
                body.children
                    .iter()
                    .skip(1)
                    .filter_map(node)
                    .filter(|child| child.r#type != "SCOPE"),
            );
            out
        }
        _ => vec![body],
    }
}

pub fn canon_polarity(text: &str) -> (String, bool) {
    let trimmed = text.trim();
    if let Some(rest) = trimmed.strip_prefix('!') {
        (
            rest.trim_start_matches('(')
                .trim_end_matches(')')
                .trim()
                .to_string(),
            true,
        )
    } else {
        (trimmed.to_string(), false)
    }
}

pub fn flatten_and(node: &Node) -> Vec<&Node> {
    if matches!(node.r#type.as_str(), "CONDITION_CLAUSE") {
        let children = node
            .children
            .iter()
            .filter_map(self::node)
            .collect::<Vec<_>>();
        if children.len() == 1 {
            return flatten_and(children[0]);
        }
    }
    if node.r#type != "AND" {
        return vec![node];
    }
    node.children
        .iter()
        .filter_map(self::node)
        .flat_map(flatten_and)
        .collect()
}

const QUESTION_COLON_TERNARY_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "conditional",
];
const CASE_ARGUMENT_WHEN_KINDS: &[&str] = &[
    "when",
    "switch_case",
    "case_clause",
    "expression_case",
    "case_statement",
    "switch_section",
    "switch_block_statement_group",
    "switch_entry",
    "when_entry",
    "match_arm",
];
const CASE_ELSE_KINDS: &[&str] = &["else", "switch_default"];
const CASE_DEFAULT_PATTERN_KINDS: &[&str] = &["case_pattern", "match_pattern", "pattern"];
const LEADING_FUNCTION_WRAPPER_KINDS: &[&str] = &["body_statement", "statement"];
const OWNER_STATEMENT_NESTED_KINDS: &[&str] =
    &["class", "class_definition", "class_declaration", "module"];
const LEADING_OWNER_WRAPPER_KINDS: &[&str] = &["body_statement", "statement"];
const OWNER_NODE_KINDS: &[&str] = &["class", "class_definition", "class_declaration", "module"];
const LEADING_IF_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block",
    "block_body",
    "statement",
    "statements",
];
const LEADING_CASE_WRAPPER_KINDS: &[&str] = &["body_statement", "block", "block_body", "statement"];
const CASE_NODE_KINDS: &[&str] = &[
    "case",
    "switch_statement",
    "expression_switch_statement",
    "switch_expression",
    "match_statement",
    "match_expression",
    "when_expression",
];
const LEADING_LOOP_WRAPPER_KINDS: &[&str] = &["body_statement", "block", "block_body", "statement"];
const LOOP_NODE_KINDS: &[&str] = &["while", "while_statement", "while_modifier"];
const RESCUE_BODY_WRAPPER_KINDS: &[&str] = &["body_statement", "block_body", "statement"];
const ENSURE_BODY_WRAPPER_KINDS: &[&str] = &["body_statement", "block_body", "statement"];
const ARRAY_LITERAL_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block",
    "block_body",
    "statement",
    "argument_list",
    "expression_statement",
];
const ARRAY_LITERAL_NODE_KINDS: &[&str] = &["array", "list"];
const ELEMENT_REFERENCE_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block",
    "block_body",
    "statement",
    "expression_statement",
    "expression_list",
];
const ELEMENT_REFERENCE_NODE_KINDS: &[&str] = &[
    "element_reference",
    "subscript",
    "subscript_expression",
    "bracket_index_expression",
];
const HASH_LITERAL_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block",
    "block_body",
    "statement",
    "argument_list",
    "expression_statement",
    "parenthesized_expression",
];
const HASH_LITERAL_NODE_KINDS: &[&str] = &["hash", "dictionary", "object", "table_constructor"];
const STATEMENT_BLOCK_PARENT_KINDS: &[&str] = &[
    "method_declaration",
    "constructor_declaration",
    "function_declaration",
    "function_item",
    "function_body",
    "if_statement",
    "while_statement",
    "for_statement",
    "enhanced_for_statement",
    "try_statement",
    "catch_clause",
    "finally_clause",
    "do_statement",
    "lambda_expression",
];
const EMPTY_BODY_WRAPPER_KINDS: &[&str] = &["body_statement", "block", "block_body", "statement"];
const HEREDOC_BODY_WRAPPER_KINDS: &[&str] = &["body_statement", "block_body", "statement", "then"];
const INTERPOLATED_STATEMENT_WRAPPER_KINDS: &[&str] =
    &["body_statement", "block_body", "statement", "argument_list"];
const CONCATENATED_STRING_WRAPPER_KINDS: &[&str] =
    &["body_statement", "block_body", "statement", "argument_list"];

pub(crate) struct TernaryParts<'tree> {
    pub(crate) condition: TreeSitterNode<'tree>,
    pub(crate) positive: Vec<TreeSitterNode<'tree>>,
    pub(crate) negative: Vec<TreeSitterNode<'tree>>,
}

fn direct_binary_operator<'source>(
    node: TreeSitterNode<'_>,
    source: &'source str,
) -> Option<&'source str> {
    node.children(&mut node.walk())
        .find(|child| !child.is_named() && !matches!(node_text(*child, source), "(" | ")"))
        .map(|child| node_text(child, source))
}

fn question_colon_ternary_parts<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
    kinds: &[&str],
) -> Option<TernaryParts<'tree>> {
    if !kinds.contains(&node.kind()) {
        return None;
    }
    let Some((question_byte, colon_byte)) = ternary_separator_bytes(node, source) else {
        let raw_named = raw_named_children(node);
        if raw_named.len() == 1 && node_text(raw_named[0], source) == node_text(node, source) {
            return question_colon_ternary_parts(raw_named[0], source, kinds);
        }
        return None;
    };
    let named = named_children(node);
    let condition = *named.first()?;
    let positive = named
        .iter()
        .copied()
        .filter(|child| child.start_byte() > question_byte && child.end_byte() <= colon_byte)
        .collect::<Vec<_>>();
    let negative = named
        .iter()
        .copied()
        .filter(|child| child.start_byte() > colon_byte)
        .collect::<Vec<_>>();

    if positive.is_empty() || negative.is_empty() {
        return None;
    }

    Some(TernaryParts {
        condition,
        positive,
        negative,
    })
}

fn ternary_separator_bytes(node: TreeSitterNode<'_>, source: &str) -> Option<(usize, usize)> {
    let mut question = None;
    let mut colon = None;
    for child in node.children(&mut node.walk()) {
        if child.is_named() {
            continue;
        }
        let text = node_text(child, source);
        if text == "?" && question.is_none() {
            question = Some(child.start_byte());
        } else if text == ":" && question.is_some() {
            colon = Some(child.start_byte());
            break;
        }
    }
    Some((question?, colon?))
}

fn named_children<'tree>(node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
    node.children(&mut node.walk())
        .filter(|child| child.is_named())
        .collect()
}

fn raw_named_children<'tree>(node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
    node.children(&mut node.walk())
        .filter(|child| child.is_named())
        .collect()
}

fn identifier_kind_name(kind: &str) -> bool {
    matches!(
        kind,
        "identifier"
            | "simple_identifier"
            | "property_identifier"
            | "field_identifier"
            | "shorthand_property_identifier"
    )
}

fn case_arm_descendant(node: TreeSitterNode<'_>) -> bool {
    let mut stack = named_children(node);
    while let Some(child) = stack.pop() {
        if CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()) {
            return true;
        }
        stack.extend(named_children(child));
    }
    false
}

fn descendant<'tree>(node: TreeSitterNode<'tree>, kinds: &[&str]) -> Option<TreeSitterNode<'tree>> {
    let mut stack = named_children(node);
    while let Some(child) = stack.pop() {
        if kinds.contains(&child.kind()) {
            return Some(child);
        }
        stack.extend(named_children(child));
    }
    None
}

fn bracketed(node: TreeSitterNode<'_>, source: &str, opening: &str, closing: &str) -> bool {
    let children = node.children(&mut node.walk()).collect::<Vec<_>>();
    children
        .first()
        .map(|child| node_text(*child, source) == opening)
        .unwrap_or(false)
        && children
            .last()
            .map(|child| node_text(*child, source) == closing)
            .unwrap_or(false)
}

fn statement_block_wrapper(node: TreeSitterNode<'_>) -> bool {
    node.kind() == "block"
        && node
            .parent()
            .map(|parent| STATEMENT_BLOCK_PARENT_KINDS.contains(&parent.kind()))
            .unwrap_or(false)
}

fn element_reference_shape(node: TreeSitterNode<'_>, source: &str) -> bool {
    let children = node.children(&mut node.walk()).collect::<Vec<_>>();
    children
        .first()
        .map(|child| node_text(*child, source) != "[")
        .unwrap_or(false)
        && children
            .iter()
            .any(|child| !child.is_named() && node_text(*child, source) == "[")
        && children
            .iter()
            .any(|child| !child.is_named() && node_text(*child, source) == "]")
        && named_children(node).len() >= 2
        && named_children(node)
            .iter()
            .all(|child| !matches!(child.kind(), "block" | "do_block"))
}

fn optional_node(node: Option<Node>) -> Child {
    node.map(|node| Child::Node(Box::new(node)))
        .unwrap_or(Child::Nil)
}

fn child_node(child: Child) -> Option<Node> {
    match child {
        Child::Node(node) => Some(*node),
        _ => None,
    }
}

fn list_or_nil(
    children: Vec<Node>,
    source: TreeSitterNode<'_>,
    normalizer: &TreeSitterNormalizer<'_>,
) -> Child {
    if children.is_empty() {
        Child::Nil
    } else {
        Child::Node(Box::new(normalizer.list_node(children, source)))
    }
}

fn integer_text(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.chars().all(|ch| ch.is_ascii_digit())
}

fn dynamic_scope(mut node: Node) -> Node {
    if matches!(
        node.r#type.as_str(),
        "DEFN" | "DEFS" | "CLASS" | "MODULE" | "SCLASS" | "LAMBDA"
    ) {
        return node;
    }
    if node.r#type == "LASGN" {
        node.r#type = "DASGN".to_string();
    } else if node.r#type == "LVAR" {
        node.r#type = "DVAR".to_string();
    }
    node.children = node
        .children
        .into_iter()
        .map(|child| match child {
            Child::Node(node) => Child::Node(Box::new(dynamic_scope(*node))),
            other => other,
        })
        .collect();
    node
}

fn kind_type(kind: &str) -> String {
    let mut result = String::new();
    let mut in_separator = false;
    for ch in kind.chars() {
        if ch.is_ascii_alphanumeric() {
            result.push(ch.to_ascii_uppercase());
            in_separator = false;
        } else if !in_separator {
            result.push('_');
            in_separator = true;
        }
    }
    result
}

#[cfg(test)]
fn ts_node(node: Option<TreeSitterNode<'_>>) -> bool {
    node.is_some()
}

fn return_kind(kind: &str) -> &str {
    match kind {
        "return" | "return_statement" | "return_expression" => "RETURN",
        "break" | "break_statement" | "break_expression" => "BREAK",
        "next" | "continue_statement" => "NEXT",
        other => other,
    }
}

fn return_statement_kind(kind: &str) -> bool {
    matches!(
        kind,
        "return"
            | "return_statement"
            | "return_expression"
            | "break"
            | "break_statement"
            | "break_expression"
            | "next"
            | "continue_statement"
    )
}

fn literal_symbol_arguments(text: &str) -> Vec<String> {
    let chars = text.char_indices().collect::<Vec<_>>();
    let mut symbols = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        if chars[index].1 != ':' {
            index += 1;
            continue;
        }
        let Some((_, first)) = chars.get(index + 1).copied() else {
            index += 1;
            continue;
        };
        if !(first == '_' || first.is_ascii_alphabetic()) {
            index += 1;
            continue;
        }

        let start = chars[index + 1].0;
        let mut end = start + first.len_utf8();
        let mut cursor = index + 2;
        while let Some((byte, ch)) = chars.get(cursor).copied() {
            if ch == '_' || ch.is_ascii_alphanumeric() {
                end = byte + ch.len_utf8();
                cursor += 1;
            } else {
                break;
            }
        }
        if let Some((byte, ch)) = chars.get(cursor).copied() {
            if matches!(ch, '!' | '?' | '=') {
                end = byte + ch.len_utf8();
                cursor += 1;
            }
        }
        symbols.push(text[start..end].to_string());
        index = cursor;
    }
    symbols
}

fn bare_identifier_text(text: &str) -> bool {
    let text = text.trim();
    exact_bare_identifier_text(text)
}

fn exact_bare_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    let mut chars = chars.peekable();
    while let Some(ch) = chars.next() {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            continue;
        }
        if matches!(ch, '!' | '?' | '=') {
            return chars.peek().is_none();
        }
        return false;
    }
    true
}

fn exact_integer_text(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.chars().all(|ch| ch.is_ascii_digit())
}

fn comparison_operator_from_text(text: &str) -> Option<String> {
    for operator in ["===", "!==", "==", "!=", "<=", ">=", "<", ">"] {
        if text.contains(operator) {
            return Some(operator.to_string());
        }
    }
    None
}

fn operator_assignment_statement_operator(text: &str) -> Option<String> {
    match text {
        "+=" => Some("+".to_string()),
        "-=" => Some("-".to_string()),
        "*=" => Some("*".to_string()),
        "/=" => Some("/".to_string()),
        "%=" => Some("%".to_string()),
        "&=" => Some("&".to_string()),
        "|=" => Some("|".to_string()),
        "^=" => Some("^".to_string()),
        "||=" => Some("||".to_string()),
        "&&=" => Some("&&".to_string()),
        _ => None,
    }
}

pub fn child_to_string(child: Option<&Child>) -> Option<String> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value.clone()),
        Some(Child::Integer(value)) => Some(value.to_string()),
        _ => None,
    }
}

#[cfg(test)]
#[path = "ast-test.rs"]
mod tests;
