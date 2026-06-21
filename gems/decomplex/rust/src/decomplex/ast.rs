use crate::decomplex::syntax::Language;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use tree_sitter::{Language as TreeSitterLanguage, Node as TreeSitterNode, Parser};

mod adapters;
use adapters::{normalization_adapter, AstNormalizationAdapter, NamedChildrenAction};

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
const PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "expression_statement",
];

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

fn ruby_exception_constant_text(text: &str) -> bool {
    let mut parts = text.split("::");
    let Some(first) = parts.next() else {
        return false;
    };
    let mut first_chars = first.chars();
    if !matches!(first_chars.next(), Some(ch) if ch.is_ascii_uppercase()) {
        return false;
    }
    if !first_chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric()) {
        return false;
    }
    parts.all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
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
    parse_with_language(file, Language::Ruby)
}

pub fn parse_with_language(file: &Path, language: Language) -> Result<(Node, Vec<String>)> {
    let source =
        fs::read_to_string(file).with_context(|| format!("failed to read {}", file.display()))?;
    let mut parser = Parser::new();
    parser
        .set_language(&language_grammar(language))
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

fn language_grammar(language: Language) -> TreeSitterLanguage {
    match language {
        Language::Ruby => tree_sitter_ruby::LANGUAGE.into(),
        Language::Python => tree_sitter_python::LANGUAGE.into(),
        Language::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
        Language::Java => tree_sitter_java::LANGUAGE.into(),
        Language::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        Language::Swift => tree_sitter_swift::LANGUAGE.into(),
        Language::Kotlin => tree_sitter_kotlin_ng::LANGUAGE.into(),
        Language::Go => tree_sitter_go::LANGUAGE.into(),
        Language::Rust => tree_sitter_rust::LANGUAGE.into(),
        Language::Zig => tree_sitter_zig::LANGUAGE.into(),
        Language::Lua => tree_sitter_lua::LANGUAGE.into(),
        Language::C => tree_sitter_c::LANGUAGE.into(),
        Language::Cpp => tree_sitter_cpp::LANGUAGE.into(),
        Language::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
        Language::Php => tree_sitter_php::LANGUAGE_PHP.into(),
    }
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
const TYPESCRIPT_TERNARY_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "conditional",
    "ternary_expression",
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
const PYTHON_LEADING_FUNCTION_WRAPPER_KINDS: &[&str] = &["block"];
const LUA_LEADING_FUNCTION_WRAPPER_KINDS: &[&str] = &["block"];
const OWNER_STATEMENT_NESTED_KINDS: &[&str] =
    &["class", "class_definition", "class_declaration", "module"];
const LEADING_OWNER_WRAPPER_KINDS: &[&str] = &["body_statement", "statement"];
const PYTHON_LEADING_OWNER_WRAPPER_KINDS: &[&str] = &["block"];
const OWNER_NODE_KINDS: &[&str] = &["class", "class_definition", "class_declaration", "module"];
const IF_NODE_KINDS: &[&str] = &[
    "if",
    "if_statement",
    "if_modifier",
    "unless",
    "unless_modifier",
    "if_expression",
    "conditional",
];
const LEADING_IF_WRAPPER_KINDS: &[&str] = &["body_statement", "block", "block_body", "statement"];
const PYTHON_LEADING_IF_WRAPPER_KINDS: &[&str] = &["block"];
const LUA_LEADING_IF_WRAPPER_KINDS: &[&str] = &["block"];
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
const LOOP_NODE_KINDS: &[&str] = &[
    "while",
    "while_statement",
    "while_modifier",
    "until",
    "until_modifier",
];
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
const PYTHON_CONCATENATED_STRING_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "block",
    "expression_statement",
];
const CONCATENATED_STRING_NODE_KINDS: &[&str] = &["chained_string", "concatenated_string"];

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

fn concatenated_string_node<'tree>(node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
    if !CONCATENATED_STRING_NODE_KINDS.contains(&node.kind()) {
        return None;
    }
    let children = named_children(node);
    if children.len() > 1 && children.iter().all(|child| child.kind() == "string") {
        Some(node)
    } else {
        None
    }
}

fn concatenated_string_target<'tree>(node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
    if let Some(target) = concatenated_string_node(node) {
        return Some(target);
    }
    let children = named_children(node);
    if children.len() == 1 {
        return concatenated_string_target(children[0]);
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

fn lua_positional_table_target<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
) -> Option<TreeSitterNode<'tree>> {
    if node.kind() == "block" {
        let named = named_children(node);
        if named.len() == 1 && named[0].kind() == "function_call" {
            return lua_positional_table_target(named[0], source);
        }
    }

    if node.kind() == "function_call" {
        let named = named_children(node);
        if named.len() == 2
            && named[0].kind() == "identifier"
            && node_text(named[0], source).is_empty()
        {
            return lua_positional_table_target(named[1], source);
        }
    }

    if node.kind() == "arguments" {
        let table = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "table_constructor")?;
        if node_text(node, source).trim() == node_text(table, source).trim() {
            return lua_positional_table_target(table, source).map(|_| node);
        }
        return None;
    }

    if node.kind() == "table_constructor" {
        let fields = named_children(node);
        if fields.is_empty() {
            return None;
        }
        if fields.iter().all(|field| {
            field.kind() == "field" && {
                let named = named_children(*field);
                named.len() <= 1
            }
        }) {
            return Some(node);
        }
    }

    None
}

fn lua_keyed_table_target<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
) -> Option<TreeSitterNode<'tree>> {
    if node.kind() == "block" {
        let named = named_children(node);
        if named.len() == 1 && node_text(named[0], source).trim() == node_text(node, source).trim()
        {
            return lua_keyed_table_target(named[0], source);
        }
        if named.len() == 2
            && named[0].kind() == "identifier"
            && node_text(named[0], source).is_empty()
        {
            return lua_keyed_table_target(named[1], source);
        }
    }

    if node.kind() == "function_call" {
        let named = named_children(node);
        if named.len() == 2
            && named[0].kind() == "identifier"
            && node_text(named[0], source).is_empty()
        {
            return lua_keyed_table_target(named[1], source);
        }
    }

    if node.kind() == "arguments" {
        if bracketed(node, source, "{", "}") {
            let fields = named_children(node);
            if fields.is_empty() {
                return Some(node);
            }
            if fields
                .iter()
                .any(|field| field.kind() != "field" || named_children(*field).len() > 1)
            {
                return Some(node);
            }
            return None;
        }

        let table = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "table_constructor")?;
        if node_text(node, source).trim() == node_text(table, source).trim() {
            return lua_keyed_table_target(table, source).map(|_| node);
        }
        return None;
    }

    if node.kind() == "table_constructor" {
        let fields = named_children(node);
        if fields.is_empty() {
            return Some(node);
        }
        if fields
            .iter()
            .any(|field| field.kind() != "field" || named_children(*field).len() > 1)
        {
            return Some(node);
        }
    }

    None
}

struct TreeSitterNormalizer<'source> {
    source: &'source str,
    #[cfg(test)]
    language: Language,
    normalization_adapter: &'static dyn AstNormalizationAdapter,
    local_stack: Vec<BTreeSet<String>>,
    root_span: Option<Span>,
    current_heredoc_body_span: Option<Span>,
}

impl<'source> TreeSitterNormalizer<'source> {
    fn new(source: &'source str, language: Language) -> Self {
        Self {
            source,
            #[cfg(test)]
            language,
            normalization_adapter: normalization_adapter(language),
            local_stack: Vec::new(),
            root_span: None,
            current_heredoc_body_span: None,
        }
    }

    fn normalize(mut self, root: TreeSitterNode<'_>) -> Node {
        self.root_span = Some(span(root));
        let children = if self.ruby() {
            self.with_ruby_scope(root, true, |normalizer| normalizer.normalize_children(root))
        } else {
            self.normalize_children(root)
        };
        self.wrap("ROOT", children, root)
    }

    fn normalize_node(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() == "comment" {
            return None;
        }
        if self.assignment_lhs(node) {
            return self.normalize_assignment_lhs(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.leading_function_statement(node) {
            return self.normalize_leading_function_statement(node);
        }
        if self.leading_owner_statement(node) {
            return self.normalize_leading_owner_statement(node);
        }
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if node.kind() == "elsif" {
            return Some(self.normalize_elsif(node));
        }
        if self.ensure_body_statement(node) {
            return self.normalize_ensure_body_statement(node);
        }
        if self.rescue_body_statement(node) {
            return self.normalize_rescue_body_statement(node);
        }
        if if_kind(node.kind()) {
            return self.normalize_if(node);
        }
        if self.leading_case_statement(node) {
            return self.normalize_leading_case_statement(node);
        }
        if self.leading_loop_statement(node) {
            return self.normalize_leading_loop_statement(node);
        }
        if let Some(loop_type) = self.loop_node_type(node.kind()) {
            return self.normalize_loop(node, loop_type);
        }
        if self.case_kind(node.kind()) || self.hidden_match(node) {
            return self.normalize_case(node);
        }
        if self.hash_literal_statement(node) {
            return self.normalize_hash_literal_statement(node);
        }
        if self.array_literal_statement(node) {
            return self.normalize_array_literal_statement(node);
        }
        if self.element_reference_statement(node) {
            return self.normalize_element_reference_statement(node);
        }
        if self.concatenated_string_statement(node) {
            return Some(self.normalize_concatenated_string_statement(node));
        }
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.wrapped_return_statement(node) {
            return self.normalize_wrapped_return_statement(node);
        }
        if self.heredoc_body_statement(node) {
            return self.normalize_heredoc_body_statement(node);
        }
        if self.empty_body_statement(node) {
            return None;
        }
        if self.terminal_statement(node) {
            return Some(self.normalize_terminal_statement(node));
        }
        if self.modifier_statement(node) {
            return self.normalize_modifier_statement(node);
        }
        if self.statement_call_with_block(node) {
            return self.normalize_statement_call_with_block(node);
        }
        if self.super_statement(node) {
            return Some(self.normalize_super_statement(node));
        }
        if self.command_call_statement(node) {
            return self.normalize_command_call_statement(node);
        }
        if self.yield_statement(node) {
            return Some(self.normalize_yield_statement(node));
        }
        if self.yield_argument_list(node) {
            return Some(self.normalize_yield_argument_list(node));
        }
        if self.super_statement(node) {
            return Some(self.normalize_super_statement(node));
        }
        if self.unary_not_statement(node) {
            return self.normalize_unary_not_statement(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.unary_minus_expression(node) {
            return self.normalize_unary_minus(node);
        }
        if self.unary_not_expression(node) {
            return self.normalize_unary_not(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.operator_call_expression(node) {
            return self.normalize_operator_call(node);
        }
        if self.comparison_expression(node) {
            return self.normalize_comparison(node);
        }
        if self.self_node(node) {
            return Some(self.wrap("SELF", Vec::new(), node));
        }
        if self.instance_variable(node) {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            ));
        }
        if self.global_variable(node) {
            return Some(self.normalize_global_variable(node));
        }
        if self.self_identifier(node) {
            return Some(self.wrap("SELF", Vec::new(), node));
        }
        if let Some(name) = self
            .normalization_adapter
            .local_identifier_text(node, self.source)
        {
            return Some(self.normalize_identifier_with_name(node, name));
        }
        if let Some(name) = self
            .normalization_adapter
            .constant_identifier_text(node, self.source)
        {
            return Some(self.wrap("CONST", vec![Child::Symbol(name)], node));
        }
        if self.class_node(node) {
            return self.normalize_class(node);
        }
        if self.module_node(node) {
            return self.normalize_module(node);
        }
        if self.lambda_expression(node) {
            return self.normalize_lambda(node);
        }

        match node.kind() {
            "program" => {
                let children = self.normalize_children(node);
                Some(self.wrap("ROOT", children, node))
            }
            "method"
            | "function_definition"
            | "function_declaration"
            | "method_definition"
            | "method_declaration"
            | "function_item" => self.normalize_function(node),
            "impl_item" => self.normalize_impl(node),
            "singleton_method" => self.normalize_singleton_function(node),
            _ if self.block_kind(node.kind()) => {
                let children = self.normalize_children(node);
                Some(self.wrap("BLOCK", children, node))
            }
            "ensure" => self.normalize_ensure_clause(node),
            "begin" => self.normalize_begin(node),
            "subshell" => Some(self.normalize_subshell(node)),
            "block_argument" => self.normalize_block_argument(node),
            "singleton_class" => self.normalize_singleton_class(node),
            "yield" => Some(self.normalize_yield(node)),
            "operator_assignment" => self.normalize_operator_assignment(node),
            "assignment" | "assignment_expression" | "assignment_statement" => {
                self.normalize_assignment(node)
            }
            "variable_declarator" if !self.has_assignment_operator_child(node) => {
                Some(self.wrap(&kind_type(node.kind()), Vec::new(), node))
            }
            "expression_list" if self.single_short_var_lhs(node) => {
                Some(self.wrap(&kind_type(node.kind()), Vec::new(), node))
            }
            _ if self.call_node(node) => self.normalize_call(node),
            _ if self.member_read_node(node) => self.normalize_member_read(node),
            _ if self.unwrap_node(node) => self
                .named_children(node)
                .into_iter()
                .next()
                .and_then(|child| self.normalize_node(child)),
            "element_reference" => self.normalize_element_reference(node),
            "rescue_modifier" => self.normalize_rescue_modifier(node),
            "super" => Some(self.normalize_super(node)),
            "return" | "return_statement" | "return_expression" | "break" | "break_statement"
            | "break_expression" | "next" | "continue_statement" => self.normalize_return(node),
            "nil" | "none" | "null" => Some(self.wrap("NIL", Vec::new(), node)),
            "true" => Some(self.wrap("TRUE", Vec::new(), node)),
            "false" => Some(self.wrap("FALSE", Vec::new(), node)),
            "instance_variable" => Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            )),
            "identifier"
            | "simple_identifier"
            | "property_identifier"
            | "field_identifier"
            | "shorthand_property_identifier" => Some(self.normalize_identifier(node)),
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier" => {
                Some(self.normalize_const(node))
            }
            "self" | "this" => Some(self.wrap("SELF", Vec::new(), node)),
            "global_variable" => Some(self.normalize_global_variable(node)),
            "array" => Some(self.normalize_array_literal(node)),
            _ if self.interpolation_node(node) => self.normalize_interpolation(node),
            "heredoc_beginning" => Some(self.normalize_heredoc_beginning(node)),
            "chained_string" | "concatenated_string" => Some(self.normalize_chained_string(node)),
            "string"
            | "string_content"
            | "string_literal"
            | "interpreted_string_literal"
            | "raw_string_literal" => {
                if self.interpolated_string(node) {
                    Some(self.normalize_interpolated_string(node))
                } else if let Some(content) = self.no_paren_string_argument_content(node) {
                    Some(self.wrap(
                        "STR",
                        vec![Child::String(node_text(content, self.source).to_string())],
                        content,
                    ))
                } else {
                    Some(self.wrap(
                        "STR",
                        vec![Child::String(node_text(node, self.source).to_string())],
                        node,
                    ))
                }
            }
            "integer" => Some(self.wrap("INTEGER", Vec::new(), node)),
            "float" | "float_literal" => Some(self.wrap("FLOAT", Vec::new(), node)),
            "pair" => self.normalize_pair(node),
            "simple_symbol" | "symbol" => Some(self.wrap(
                "LIT",
                vec![Child::Symbol(
                    node_text(node, self.source).trim_start_matches(':').to_string(),
                )],
                node,
            )),
            _ => {
                let children = self.normalize_children(node);
                Some(self.wrap(&kind_type(node.kind()), children, node))
            }
        }
    }

    fn normalize_function(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() == "singleton_method" {
            return self.normalize_singleton_function(node);
        }

        let name = self.function_name(node)?;
        let args = self.normalize_parameters(self.parameters_child(node));
        let body = self.with_ruby_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
            let body = normalizer.prepend_inline_parameter_begin(node, body);
            normalizer.elide_implicit_nil_body(body)
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "DEFN",
            vec![Child::Symbol(name), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_leading_function_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.leading_function_target(node)?;
        if function_kind(target.kind()) {
            return self.normalize_function(target);
        }
        let name = self
            .leading_function_name(target)
            .map(|name| node_text(name, self.source).to_string())?;
        let body_node = self.leading_function_body(target);
        let body = self.with_ruby_scope(target, true, |normalizer| {
            let body = body_node.and_then(|body| normalizer.normalize_body(body));
            normalizer.elide_tail_returns(body)
        });
        Some(self.wrap(
            "DEFN",
            vec![
                Child::Symbol(name),
                Child::Node(Box::new(self.scope(body, None, target))),
            ],
            target,
        ))
    }

    fn normalize_singleton_function(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.function_name(node)?;
        let receiver = self
            .singleton_receiver(node)
            .and_then(|child| self.normalize_node(child))
            .unwrap_or_else(|| self.wrap("SELF", Vec::new(), node));
        let args = self.normalize_parameters(self.parameters_child(node));
        let body = self.with_ruby_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
            let body = normalizer.prepend_inline_parameter_begin(node, body);
            normalizer.elide_implicit_nil_body(body)
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "DEFS",
            vec![
                Child::Node(Box::new(receiver)),
                Child::Symbol(name),
                Child::Node(Box::new(scope)),
            ],
            node,
        ))
    }

    fn normalize_class(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.const_for(
            self.named_field(node, "name")
                .or_else(|| self.first_named(node)),
            node,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        Some(self.wrap(
            "CLASS",
            vec![
                Child::Node(Box::new(name)),
                Child::Nil,
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    fn normalize_impl(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let type_node = self.named_field(node, "type").or_else(|| {
            self.named_children(node).into_iter().find(|child| {
                matches!(
                    child.kind(),
                    "type_identifier" | "scoped_type_identifier" | "identifier"
                )
            })
        });
        let name = self.const_for(type_node, node);
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .or(Some(node))
            .and_then(|body| self.normalize_body(body));
        Some(self.wrap(
            "CLASS",
            vec![
                Child::Node(Box::new(name)),
                Child::Nil,
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    fn normalize_nested_class_as_iter(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name_node = self
            .named_field(node, "name")
            .or_else(|| self.first_named(node))?;
        let name = node_text(name_node, self.source).to_string();
        let header_end = node
            .children(&mut node.walk())
            .find(|child| !child.is_named() && node_text(*child, self.source) == ":")
            .unwrap_or(name_node);
        let call = self.wrap_from_nodes(
            "VCALL",
            vec![Child::Symbol(name), Child::Nil],
            node,
            header_end,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        let scope = self.scope(body, None, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_module(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.const_for(
            self.named_field(node, "name")
                .or_else(|| self.first_named(node)),
            node,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        Some(self.wrap(
            "MODULE",
            vec![
                Child::Node(Box::new(name)),
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    fn normalize_singleton_class(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let receiver = named
            .first()
            .and_then(|receiver| self.normalize_node(*receiver));
        let body = named.get(1).and_then(|body| self.normalize_body(*body));
        Some(self.wrap(
            "SCLASS",
            vec![
                optional_node(receiver),
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    fn normalize_lambda(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.lambda_target(node).unwrap_or(node);
        let body_node = self
            .named_field(target, "body")
            .or_else(|| self.block_child(target))
            .or_else(|| self.named_children(target).into_iter().last())?;
        let body = self.with_ruby_scope(target, false, |normalizer| {
            normalizer.normalize_body(body_node).map(dynamic_scope)
        });
        let scope = self.scope(body, None, target);
        Some(self.wrap("LAMBDA", vec![Child::Node(Box::new(scope))], target))
    }

    fn normalize_yield(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_else(|| self.yield_inline_arguments(node));
        self.wrap(
            "YIELD",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    fn normalize_yield_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_else(|| self.yield_inline_arguments(node));
        self.wrap(
            "YIELD",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    fn normalize_yield_argument_list(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args = self.yield_argument_nodes(node);
        let source = self.parent_node(node).unwrap_or(node);
        self.wrap("YIELD", vec![list_or_nil(args, node, self)], source)
    }

    fn normalize_super_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let raw = self.raw_named_children(node);
        let children = if raw.len() == 1 && raw[0].kind() == "call" {
            self.raw_named_children(raw[0])
        } else {
            raw
        };
        let args_node = children
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_default();
        self.wrap(
            "SUPER",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    fn normalize_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(child) = self
            .normalization_adapter
            .nested_class_body_child(node, self.source)
        {
            return self.normalize_nested_class_as_iter(child);
        }
        if self.leading_function_statement(node) {
            return self.normalize_leading_function_statement(node);
        }
        if self.leading_owner_statement(node) {
            return self.normalize_leading_owner_statement(node);
        }
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if node.kind() == "elsif" {
            return Some(self.normalize_elsif(node));
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if if_kind(node.kind()) {
            return self.normalize_if(node);
        }
        if self.leading_case_statement(node) {
            return self.normalize_leading_case_statement(node);
        }
        if self.leading_loop_statement(node) {
            return self.normalize_leading_loop_statement(node);
        }
        if self.ensure_body_statement(node) {
            return self.normalize_ensure_body_statement(node);
        }
        if self.rescue_body_statement(node) {
            return self.normalize_rescue_body_statement(node);
        }
        if self.hash_literal_statement(node) {
            return self.normalize_hash_literal_statement(node);
        }
        if self.array_literal_statement(node) {
            return self.normalize_array_literal_statement(node);
        }
        if self.element_reference_statement(node) {
            return self.normalize_element_reference_statement(node);
        }
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.wrapped_return_statement(node) {
            return self.normalize_wrapped_return_statement(node);
        }
        if self.heredoc_body_statement(node) {
            return self.normalize_heredoc_body_statement(node);
        }
        if self.empty_body_statement(node) {
            return None;
        }
        if self.modifier_statement(node) {
            return self.normalize_modifier_statement(node);
        }
        if self.statement_call_with_block(node) {
            return self.normalize_statement_call_with_block(node);
        }
        if self.command_call_statement(node) {
            return self.normalize_command_call_statement(node);
        }
        if self.yield_statement(node) {
            return Some(self.normalize_yield_statement(node));
        }
        if self.unary_not_statement(node) {
            return self.normalize_unary_not_statement(node);
        }
        if self.operator_assignment_statement(node) {
            return self.normalize_operator_assignment_statement(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.unary_minus_expression(node) {
            return self.normalize_unary_minus(node);
        }
        if self.argument_list_unary_not(node) {
            return self.normalize_argument_list_unary_not(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.block_kind(node.kind()) {
            let children = self.normalize_children(node);
            if children.is_empty() {
                let text = node_text(node, self.source).trim();
                if bare_identifier_text(text) {
                    return Some(self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node));
                }
                return None;
            }
            if children.len() == 1 {
                return child_node(children.into_iter().next().unwrap());
            }

            return Some(self.wrap("BLOCK", children, node));
        }

        self.normalize_node(node)
    }

    fn normalize_if(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if matches!(node.kind(), "if_modifier" | "unless_modifier") {
            let named = self.named_children(node);
            let action = *named.first()?;
            let condition = *named.get(1)?;
            let node_type = if node.kind().starts_with("unless") {
                "UNLESS"
            } else {
                "IF"
            };
            let condition = optional_node(self.normalize_node(condition));
            let action = optional_node(self.normalize_modifier_action(action));
            return Some(self.wrap(node_type, vec![condition, action, Child::Nil], node));
        }

        let condition_raw = self
            .named_field(node, "condition")
            .or_else(|| self.named_field(node, "predicate"))
            .or_else(|| self.first_named(node))?;
        let condition = optional_node(self.normalize_node(condition_raw));
        let positive_raw = self
            .named_field(node, "consequence")
            .or_else(|| self.named_field(node, "body"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| child.kind() == "then")
            })
            .or_else(|| self.branch_child(node, condition_raw, 0));
        let negative_raw = self
            .named_field(node, "alternative")
            .or_else(|| self.explicit_alternative(node))
            .or_else(|| {
                if self.ruby() {
                    None
                } else {
                    self.branch_child(node, condition_raw, 1)
                }
            });
        let positive = optional_node(positive_raw.and_then(|child| self.normalize_body(child)));
        let negative =
            optional_node(negative_raw.and_then(|child| self.normalize_else_or_branch(child)));
        let node_type = if node.kind().starts_with("unless") {
            "UNLESS"
        } else {
            "IF"
        };
        Some(self.wrap(node_type, vec![condition, positive, negative], node))
    }

    fn normalize_elsif(&mut self, node: TreeSitterNode<'_>) -> Node {
        let condition = self
            .named_children(node)
            .into_iter()
            .find(|child| !matches!(child.kind(), "comment" | "then" | "elsif" | "else"));
        let positive = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "then");
        let negative = self
            .named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "elsif" | "else"));
        let condition = optional_node(condition.and_then(|child| self.normalize_node(child)));
        let positive = optional_node(positive.and_then(|child| self.normalize_body(child)));
        let negative =
            optional_node(negative.and_then(|child| self.normalize_else_or_branch(child)));

        self.wrap("IF", vec![condition, positive, negative], node)
    }

    fn normalize_loop(&mut self, node: TreeSitterNode<'_>, node_type: &str) -> Option<Node> {
        if matches!(node.kind(), "while_modifier" | "until_modifier") {
            let named = self.named_children(node);
            let action = *named.first()?;
            let condition = *named.get(1)?;
            let condition = optional_node(self.normalize_node(condition));
            let action = optional_node(self.normalize_modifier_action(action));
            return Some(self.wrap(node_type, vec![condition, action, Child::Bool(true)], node));
        }

        let condition = self
            .named_field(node, "condition")
            .or_else(|| self.first_named(node));
        let body = self
            .named_field(node, "body")
            .or_else(|| self.named_field(node, "consequence"))
            .or_else(|| self.block_child(node));
        let condition =
            optional_node(condition.and_then(|condition| self.normalize_node(condition)));
        let body = optional_node(body.and_then(|body| self.normalize_body(body)));
        Some(self.wrap(node_type, vec![condition, body], node))
    }

    fn normalize_else_or_branch(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(block) = self.normalization_adapter.else_if_block(node, self.source) {
            if let Some(normalized) = self.normalize_else_if_block_child(block) {
                return Some(self.wrap(
                    "ELSE_CLAUSE",
                    vec![Child::Node(Box::new(normalized))],
                    node,
                ));
            }
        }
        if node.kind() != "else" {
            return self.normalize_body(node);
        }
        if let Some(call) = self.single_dotted_else_body(node) {
            let trailing = self
                .source
                .get(call.end_byte()..node.end_byte())
                .unwrap_or("")
                .trim();
            if trailing.is_empty() {
                return self.normalize_node(call);
            }
        }
        self.normalize_body_nodes(self.named_children(node), node)
    }

    fn normalize_else_if_block_child(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let statements = self
            .raw_named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if statements.len() != 1 || statements[0].kind() != "if_statement" {
            return None;
        }
        let if_node = statements[0];
        self.normalize_if(if_node)
    }

    fn normalize_case(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let value_raw = self.case_value(node);
        let value = value_raw.and_then(|value| self.normalize_node(value));
        let whens = self
            .case_arms(node)
            .into_iter()
            .filter_map(|arm| self.normalize_when(arm))
            .collect::<Vec<_>>();
        let fallback = self.case_else_body(node);
        let chain = self.link_when_chain(whens, fallback);
        if value_raw.is_none() {
            Some(self.wrap("CASE2", vec![optional_node(chain)], node))
        } else {
            Some(self.wrap(
                "CASE",
                vec![optional_node(value), optional_node(chain)],
                node,
            ))
        }
    }

    fn normalize_when(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let patterns = self.normalize_patterns(node);
        let body = if let Some(body_nodes) = self
            .normalization_adapter
            .case_arm_body_nodes(node, self.source)
        {
            body_nodes
                .first()
                .copied()
                .and_then(|source| self.normalize_body_nodes(body_nodes, source))
        } else {
            self.when_body(node)
                .and_then(|body| self.normalize_body(body))
        };
        Some(self.wrap(
            "WHEN",
            vec![
                list_or_nil(patterns, node, self),
                optional_node(body),
                Child::Nil,
            ],
            node,
        ))
    }

    fn normalize_patterns(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        let mut patterns = self
            .raw_named_children(node)
            .into_iter()
            .filter(|child| {
                matches!(
                    child.kind(),
                    "pattern"
                        | "case_pattern"
                        | "match_pattern"
                        | "switch_pattern"
                        | "when_condition"
                )
            })
            .collect::<Vec<_>>();
        if patterns.is_empty() {
            if let Some(value) = self.named_field(node, "value") {
                patterns.push(value);
            }
        }
        if patterns.is_empty() {
            if let Some(pattern) = self
                .named_children(node)
                .into_iter()
                .find(|child| !self.block_kind(child.kind()) && !self.statement_node(child.kind()))
            {
                patterns.push(pattern);
            }
        }

        let mut normalized = Vec::new();
        for pattern in patterns {
            let pattern_text = node_text(pattern, self.source).to_string();
            let pattern_wrapper = matches!(
                pattern.kind(),
                "pattern"
                    | "case_pattern"
                    | "match_pattern"
                    | "switch_pattern"
                    | "when_condition"
                    | "expression_list"
            );
            let pattern_children = self.named_children(pattern);
            if pattern_text.contains("::") {
                normalized.push(self.wrap("CONST", vec![Child::Symbol(pattern_text)], pattern));
            } else if pattern_wrapper && pattern_children.is_empty() && integer_text(&pattern_text)
            {
                normalized.push(self.wrap("INTEGER", Vec::new(), pattern));
            } else if self.ruby()
                && pattern_wrapper
                && pattern_children.is_empty()
                && ruby_constant_text(&pattern_text)
            {
                normalized.push(self.wrap("CONST", vec![Child::Symbol(pattern_text)], pattern));
            } else if self.ruby()
                && pattern_wrapper
                && pattern_children.is_empty()
                && bare_identifier_text(&pattern_text)
            {
                normalized.push(self.local_or_call_for_name(&pattern_text, pattern));
            } else if pattern_wrapper {
                normalized.extend(
                    pattern_children
                        .into_iter()
                        .filter_map(|child| self.normalize_node(child)),
                );
            } else if let Some(pattern) = self.normalize_node(pattern) {
                normalized.push(pattern);
            }
        }
        normalized
    }

    fn link_when_chain(&self, whens: Vec<Node>, fallback: Option<Node>) -> Option<Node> {
        whens
            .into_iter()
            .rev()
            .fold(fallback, |next_when, mut current| {
                while current.children.len() <= 2 {
                    current.children.push(Child::Nil);
                }
                current.children[2] = optional_node(next_when);
                Some(current)
            })
    }

    fn case_else_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let else_node = self
            .normalization_adapter
            .case_else_node(node, self.source)?;
        if self
            .normalization_adapter
            .case_else_arm(else_node, self.source)
            || else_node.kind() == "switch_default"
        {
            if let Some(body) = self.when_body(else_node) {
                return self.normalize_body(body);
            }
        }
        self.normalize_else_or_branch(else_node)
    }

    fn normalize_body_nodes(
        &mut self,
        nodes: Vec<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let mut children = Vec::new();
        let mut index = 0;
        while index < nodes.len() {
            if index + 1 < nodes.len() {
                if let Some(call) = self.normalize_flat_dotted_nodes(&nodes[index..=index + 1]) {
                    children.push(Child::Node(Box::new(call)));
                    index += 2;
                    continue;
                }
            }
            if let Some(child) = self.normalize_body(nodes[index]) {
                children.push(Child::Node(Box::new(child)));
            }
            index += 1;
        }
        if children.is_empty() {
            None
        } else if children.len() == 1 {
            child_node(children.into_iter().next().unwrap())
        } else {
            Some(self.wrap("BLOCK", children, source))
        }
    }

    fn normalize_return(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_return_node(node)
    }

    fn normalize_super(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let args = args_node
            .map(|args| {
                self.named_children(args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.wrap(
            "SUPER",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    fn normalize_return_node(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_return_node_with_elide_symbol(node, false)
    }

    fn normalize_return_node_with_elide_symbol(
        &mut self,
        node: TreeSitterNode<'_>,
        elide_symbol: bool,
    ) -> Option<Node> {
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_return_value(child))
            .collect::<Vec<_>>();
        if elide_symbol
            && self.ruby()
            && children.len() == 1
            && self.symbol_literal_node(children.first())
        {
            return children.into_iter().next();
        }
        let children = children
            .into_iter()
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap(return_kind(node.kind()), children, node))
    }

    fn wrapped_return_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "block"
        ) && !node_text(node, self.source).contains('\n')
            && node
                .children(&mut node.walk())
                .next()
                .map(|child| {
                    return_statement_kind(child.kind())
                        && (!child.is_named()
                            || node_text(node, self.source) == node_text(child, self.source))
                })
                .unwrap_or(false)
    }

    fn normalize_wrapped_return_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let keyword = node.children(&mut node.walk()).next()?;
        if keyword.is_named()
            && return_statement_kind(keyword.kind())
            && node_text(node, self.source) == node_text(keyword, self.source)
        {
            return self.normalize_return_node(keyword);
        }
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_return_value(child))
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap(return_kind(keyword.kind()), children, node))
    }

    fn normalize_return_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() != "argument_list" {
            return self.normalize_node(node);
        }
        if self.named_children(node).is_empty() {
            return self.scalar_argument_list_value(node);
        }
        if self.argument_list_element_reference(node) {
            return self.normalize_argument_list_element_reference(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.case_argument_list(node) {
            return self.normalize_case(node);
        }
        if self.argument_list_call_with_block(node) {
            return self.normalize_argument_list_call_with_block(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.argument_list_unary_not(node) {
            return self.normalize_argument_list_unary_not(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        let children = self.named_children(node);
        if children.len() == 1
            && self.call_node(children[0])
            && node_text(children[0], self.source) == node_text(node, self.source)
        {
            if let Some(call) = self.normalize_return_value_call(children[0]) {
                return Some(call);
            }
        }
        if let (Some(function), Some(nested_args)) = (children.first(), children.get(1)) {
            if let Some(function_name) = self
                .identifier_text(*function)
                .filter(|_| nested_args.kind() == "argument_list")
            {
                let args = self
                    .named_children(*nested_args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>();
                let args_source = self
                    .parenthesized_source(*nested_args)
                    .or_else(|| self.parenthesized_source(node));
                let args_child = if let Some(source) = args_source {
                    self.list_or_nil_from_source_node(args, &source)
                } else {
                    list_or_nil(args, *nested_args, self)
                };
                return Some(self.wrap(
                    "FCALL",
                    vec![Child::Symbol(function_name), args_child],
                    node,
                ));
            }
        }
        let values = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect::<Vec<_>>();
        if values.len() == 1 {
            values.into_iter().next()
        } else if values.is_empty() {
            None
        } else {
            Some(self.list_node(values, node))
        }
    }

    fn normalize_return_value_call(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let function = self
            .named_field(node, "function")
            .or_else(|| self.named_field(node, "call"))
            .or_else(|| self.named_children(node).into_iter().next())?;
        let Some(function_name) = self.identifier_text(function) else {
            return None;
        };

        let args_node = self
            .named_field(node, "arguments")
            .or_else(|| self.named_field(node, "argument"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| matches!(child.kind(), "argument_list" | "arguments"))
            });
        let args = args_node
            .map(|args_node| {
                self.named_children(args_node)
                    .into_iter()
                    .filter(|child| *child != function)
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let args_child = if let Some(args_node) = args_node {
            if let Some(source) = self
                .parenthesized_source(args_node)
                .or_else(|| self.parenthesized_source(node))
            {
                self.list_or_nil_from_source_node(args, &source)
            } else {
                list_or_nil(args, args_node, self)
            }
        } else {
            Child::Nil
        };

        Some(self.wrap(
            "FCALL",
            vec![Child::Symbol(function_name), args_child],
            node,
        ))
    }

    fn normalize_ternary_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let parts = self.ternary_parts(node)?;
        let condition = optional_node(self.normalize_node(parts.condition));
        let positive = optional_node(self.normalize_ternary_branch(&parts.positive));
        let negative = optional_node(self.normalize_ternary_branch(&parts.negative));
        Some(self.wrap("IF", vec![condition, positive, negative], node))
    }

    fn normalize_boolean(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let operator = self.boolean_operator(node)?;
        let node_type = if operator == "or" { "OR" } else { "AND" };
        let mut operands = Vec::new();
        for child in self.named_children(node) {
            if let Some(normalized) = self.normalize_node(child) {
                if normalized.r#type == node_type {
                    operands.extend(normalized.children);
                } else {
                    operands.push(Child::Node(Box::new(normalized)));
                }
            }
        }
        Some(self.wrap(node_type, operands, node))
    }

    fn normalize_comparison(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && BINARY_WRAPPER_KINDS.contains(&raw_named[0].kind())
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let operands = self.named_children(target);
        let left = operands.first().and_then(|left| self.normalize_node(*left));
        let right_raw = operands.get(1).copied()?;
        let right = self.normalize_node(right_raw);
        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(self.comparison_operator(node)?),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    fn normalize_operator_call(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let operands = self.named_children(node);
        let direct_parts = match (
            operands.first().copied(),
            self.binary_operator(node),
            operands.get(1).copied(),
        ) {
            (Some(left), Some(operator), Some(right)) => Some((left, operator, right)),
            _ => None,
        };
        let (left_raw, operator, right_raw) =
            direct_parts.or_else(|| self.infix_statement_parts(node))?;
        let left = self.normalize_node(left_raw);
        let right = self.normalize_node(right_raw);
        if self.ruby() && operator == "=~" && self.regex_literal(Some(right_raw)) {
            return Some(self.wrap(
                "MATCH3",
                vec![optional_node(right), optional_node(left)],
                node,
            ));
        } else if self.ruby() && operator == "=~" {
            return Some(self.wrap(
                "CALL",
                vec![
                    optional_node(left),
                    Child::Symbol("=~".to_string()),
                    list_or_nil(right.into_iter().collect(), right_raw, self),
                ],
                node,
            ));
        }

        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(operator),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    fn normalize_infix_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let (left_raw, operator, right_raw) = self.infix_statement_parts(node)?;
        let left = self.normalize_node(left_raw);
        let right = self.normalize_node(right_raw);
        if self.ruby() && operator == "=~" && self.regex_literal(Some(right_raw)) {
            return Some(self.wrap(
                "MATCH3",
                vec![optional_node(right), optional_node(left)],
                node,
            ));
        } else if self.ruby() && operator == "=~" {
            return Some(self.wrap(
                "CALL",
                vec![
                    optional_node(left),
                    Child::Symbol("=~".to_string()),
                    list_or_nil(right.into_iter().collect(), right_raw, self),
                ],
                node,
            ));
        }
        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(operator),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    fn normalize_unary_not(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let operand = self.named_children(node).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    fn normalize_unary_not_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self.unary_not_expression(raw_named[0])
        {
            raw_named[0]
        } else {
            node
        };
        let operand = self.named_children(target).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    fn normalize_unary_minus(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self.unary_minus_expression(raw_named[0])
        {
            raw_named[0]
        } else {
            node
        };
        let operand = self.named_children(target).into_iter().next()?;
        if operand.kind() == "integer" {
            if let Ok(value) = node_text(operand, self.source).parse::<i64>() {
                return Some(self.wrap("INTEGER", vec![Child::Integer(-value)], operand));
            }
        }
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("-@".to_string()), Child::Nil],
            node,
        ))
    }

    fn normalize_ternary_branch(&mut self, nodes: &[TreeSitterNode<'_>]) -> Option<Node> {
        if nodes.is_empty() {
            return None;
        }
        if nodes.len() == 1 {
            return self.normalize_node(nodes[0]);
        }
        if let Some(call) = self.normalize_flat_dotted_nodes(nodes) {
            return Some(call);
        }
        self.normalize_body_nodes(nodes.to_vec(), nodes[0])
    }

    fn normalize_flat_dotted_nodes(&mut self, nodes: &[TreeSitterNode<'_>]) -> Option<Node> {
        let receiver = *nodes.first()?;
        let method = *nodes.get(1)?;
        let connector = self
            .source
            .get(receiver.end_byte()..method.start_byte())
            .unwrap_or("")
            .trim();
        if !matches!(connector, "." | "&.") {
            return None;
        }
        let node_type = if connector == "&." { "QCALL" } else { "CALL" };
        let receiver_node = optional_node(self.normalize_node(receiver));
        Some(self.wrap_from_nodes(
            node_type,
            vec![
                receiver_node,
                Child::Symbol(node_text(method, self.source).trim_end_matches('=').to_string()),
                Child::Nil,
            ],
            receiver,
            method,
        ))
    }

    fn normalize_assignment(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let left = self.assignment_left(node)?;
        let right = self
            .assignment_right(node)
            .and_then(|right| self.normalize_node(right));
        if left.kind() == "left_assignment_list" {
            return Some(self.normalize_multiple_assignment(left, right, node));
        }
        if let Some(target) = self.assignment_target(left, right.clone(), node) {
            return Some(target);
        }
        Some(self.wrap(
            "LASGN",
            vec![Child::String(self.target_name(left)), optional_node(right)],
            node,
        ))
    }

    fn normalize_operator_assignment(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let left = self.assignment_left(node)?;
        let right_raw = self.assignment_right(node);
        let right = right_raw.and_then(|right| self.normalize_node(right));
        let operator = self.operator_assignment_operator(node);

        if left.kind() == "element_reference" {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN1",
                vec![
                    receiver,
                    Child::Symbol(operator),
                    list_or_nil(args, left, self),
                    optional_node(right),
                ],
                node,
            ));
        }

        if self.member_read_node(left) {
            let (receiver, method) = self.member_parts(left)?;
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN2",
                vec![
                    receiver,
                    Child::Bool(false),
                    Child::Symbol(method),
                    Child::Symbol(operator),
                    optional_node(right),
                ],
                node,
            ));
        }

        if let Some(logical) =
            self.normalize_logical_operator_assignment(left, &operator, right.clone(), node)
        {
            return Some(logical);
        }

        if self.instance_variable(left) || self.global_variable(left) {
            let value = self.augmented_assignment_value(left, &operator, right_raw, node);
            return self.assignment_target(left, Some(value), node);
        }

        let value = self.augmented_assignment_value(left, &operator, right_raw, node);
        self.assignment_target(left, Some(value.clone()), node)
            .or_else(|| {
                Some(self.wrap(
                    "LASGN",
                    vec![
                        Child::String(self.target_name(left)),
                        Child::Node(Box::new(value)),
                    ],
                    node,
                ))
            })
    }

    fn normalize_operator_assignment_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let (left, operator, right_raw) = self.operator_assignment_statement_parts(node)?;
        let right = self.normalize_node(right_raw);

        if left.kind() == "element_reference" {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN1",
                vec![
                    receiver,
                    Child::Symbol(operator),
                    list_or_nil(args, left, self),
                    optional_node(right),
                ],
                node,
            ));
        }

        if self.member_read_node(left) {
            let (receiver, method) = self.member_parts(left)?;
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN2",
                vec![
                    receiver,
                    Child::Bool(false),
                    Child::Symbol(method),
                    Child::Symbol(operator),
                    optional_node(right),
                ],
                node,
            ));
        }

        if let Some(logical) =
            self.normalize_logical_operator_assignment(left, &operator, right.clone(), node)
        {
            return Some(logical);
        }

        if self.instance_variable(left) || self.global_variable(left) {
            let value = self.augmented_assignment_value(left, &operator, Some(right_raw), node);
            return self.assignment_target(left, Some(value), node);
        }

        if let Some(target) = self.assignment_target(left, right, node) {
            return Some(target);
        }

        let value = self.augmented_assignment_value(left, &operator, Some(right_raw), node);
        Some(self.wrap(
            "LASGN",
            vec![
                Child::String(self.target_name(left)),
                Child::Node(Box::new(value)),
            ],
            node,
        ))
    }

    fn operator_assignment_statement_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String, TreeSitterNode<'tree>)> {
        let mut left = None;
        let mut operator = None;
        let mut right = None;
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if child.is_named() {
                if left.is_none() {
                    left = Some(child);
                }
                if operator.is_some() {
                    right = Some(child);
                }
            } else if let Some(found_operator) =
                operator_assignment_statement_operator(node_text(child, self.source))
            {
                operator = Some(found_operator);
            }
        }

        if let (Some(left), Some(operator), Some(right)) = (left, operator, right) {
            return Some((left, operator, right));
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            return self.operator_assignment_statement_parts(raw_named[0]);
        }

        None
    }

    fn operator_assignment_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(node.kind(), "body_statement" | "block_body" | "statement") {
            return false;
        }
        if self.operator_assignment_statement_parts(node).is_some() {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self
                .operator_assignment_statement_parts(raw_named[0])
                .is_some()
    }

    fn normalize_logical_operator_assignment(
        &mut self,
        left: TreeSitterNode<'_>,
        operator: &str,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self
            .normalization_adapter
            .logical_operator_assignment(operator)
        {
            return None;
        }
        if self.identifier_text(left).is_none() {
            return None;
        }
        let name = self.target_name(left);
        let node_type = if operator == "||" {
            "OP_ASGN_OR"
        } else {
            "OP_ASGN_AND"
        };
        let receiver = self.wrap("LVAR", vec![Child::String(name.clone())], left);
        let assignment = self.wrap(
            "LASGN",
            vec![Child::String(name), optional_node(right)],
            source,
        );
        Some(self.wrap(
            node_type,
            vec![
                Child::Node(Box::new(receiver)),
                Child::Symbol(operator.to_string()),
                Child::Node(Box::new(assignment)),
            ],
            source,
        ))
    }

    fn augmented_assignment_value(
        &mut self,
        left: TreeSitterNode<'_>,
        operator: &str,
        right_raw: Option<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let receiver = optional_node(self.assignment_receiver(left));
        let right = right_raw.and_then(|right| self.normalize_node(right));
        self.wrap(
            "CALL",
            vec![
                receiver,
                Child::Symbol(operator.to_string()),
                list_or_nil(right.into_iter().collect(), right_raw.unwrap_or(left), self),
            ],
            source,
        )
    }

    fn assignment_receiver(&mut self, left: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(name) = self.identifier_text(left) {
            return Some(self.wrap("LVAR", vec![Child::String(name)], left));
        }
        if self.instance_variable(left) {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(left, self.source).to_string())],
                left,
            ));
        }
        if self.global_variable(left) {
            return Some(self.normalize_global_variable(left));
        }
        if self.const_kind(left.kind()) {
            return Some(self.normalize_const(left));
        }
        self.normalize_node(left)
    }

    fn normalize_multiple_assignment(
        &self,
        left: TreeSitterNode<'_>,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let targets = self
            .named_children(left)
            .into_iter()
            .map(|child| {
                let node_type = if child.kind() == "global_variable"
                    || node_text(child, self.source).starts_with('$')
                {
                    "GASGN"
                } else {
                    "LASGN"
                };
                self.wrap(
                    node_type,
                    vec![Child::String(self.target_name(child)), Child::Nil],
                    child,
                )
            })
            .collect::<Vec<_>>();
        self.wrap(
            "MASGN",
            vec![optional_node(right), list_or_nil(targets, left, self)],
            source,
        )
    }

    fn normalize_call(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self.zero_child_identifier_call(node) {
            return Some(self.normalize_zero_child_call(node));
        }
        if self.call_block(node).is_some() {
            return self.normalize_call_with_block(node);
        }
        if self.visibility_inline_def_call(node) {
            return self.normalize_visibility_inline_def(node);
        }
        self.normalize_call_without_block(node, None)
    }

    fn normalize_zero_child_call(&self, node: TreeSitterNode<'_>) -> Node {
        self.wrap(
            "VCALL",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    fn normalize_member_read(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(field) = self
            .normalization_adapter
            .state_field_name(node, self.source)
        {
            return Some(self.wrap("IVAR", vec![Child::String(field)], node));
        }
        let Some((receiver, method)) = self.member_parts(node) else {
            let children = self.normalize_children(node);
            return Some(self.wrap(&kind_type(node.kind()), children, node));
        };
        let receiver = optional_node(self.normalize_node(receiver));
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol(method), Child::Nil],
            node,
        ))
    }

    fn normalize_call_with_block(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let call = self.normalize_call_without_block(call_source, block)?;
        let args = self.normalize_block_parameters(block);
        let body = block.and_then(|block| {
            self.with_ruby_scope(block, false, |normalizer| {
                let body_node = normalizer
                    .named_field(block, "body")
                    .or_else(|| normalizer.block_child(block))
                    .unwrap_or(block);
                normalizer.normalize_body(body_node).map(dynamic_scope)
            })
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_argument_list_call(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if !self.ruby() || node.kind() != "argument_list" {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let function = self.named_children(target).into_iter().next()?;
        let args_node = self
            .named_children(target)
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let args = args_node
            .map(|args| {
                self.named_children(args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Some(self.wrap(
            "FCALL",
            vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                list_or_nil(args, args_node.unwrap_or(node), self),
            ],
            node,
        ))
    }

    fn normalize_argument_list_element_reference(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.ruby() || !self.argument_list_element_reference(node) {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "element_reference"
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let named = self.named_children(target);
        let recv = *named.first()?;
        let args = named
            .iter()
            .skip(1)
            .filter_map(|child| self.normalize_node(*child))
            .collect::<Vec<_>>();
        let recv = self.normalize_node(recv)?;
        Some(self.wrap(
            "CALL",
            vec![
                Child::Node(Box::new(recv)),
                Child::Symbol("[]".to_string()),
                list_or_nil(args, node, self),
            ],
            node,
        ))
    }

    fn normalize_argument_list_unary_not(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if !self.ruby() || !self.argument_list_unary_not(node) {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "unary"
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let operand = self.named_children(target).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    fn normalize_argument_list_call_with_block(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.ruby() || node.kind() != "argument_list" {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let block = self.call_block(target)?;
        let call = self.normalize_argument_list_call(node)?;
        let args = self.normalize_block_parameters(Some(block));
        let body = self.with_ruby_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer.normalize_body(body_node).map(dynamic_scope)
        });
        Some(self.wrap(
            "ITER",
            vec![
                Child::Node(Box::new(call)),
                Child::Node(Box::new(self.scope(body, args, node))),
            ],
            node,
        ))
    }

    fn normalize_statement_call_with_block(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = self.statement_block_call(node)?;
        let call = self.normalize_call_without_block(call_source, block)?;
        let args = self.normalize_block_parameters(block);
        let body = block.and_then(|block| {
            self.with_ruby_scope(block, false, |normalizer| {
                let body_node = normalizer
                    .named_field(block, "body")
                    .or_else(|| normalizer.block_child(block))
                    .unwrap_or(block);
                normalizer.normalize_body(body_node).map(dynamic_scope)
            })
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_dotted_expression(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = block.map(|block| self.source_before_child(node, block));
        let call = self.normalize_dotted_call_expression_with_source(node, call_source.as_ref())?;
        let Some(block) = block else {
            return Some(call);
        };
        let args = self.normalize_block_parameters(Some(block));
        let body = self.with_ruby_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer.normalize_body(body_node).map(dynamic_scope)
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_call_without_block(
        &mut self,
        node: TreeSitterNode<'_>,
        block: Option<TreeSitterNode<'_>>,
    ) -> Option<Node> {
        let call_source = block.map(|block| self.source_before_child(node, block));
        if let Some(name) = self
            .normalization_adapter
            .intrinsic_call_name(node, self.source)
        {
            let args = self.call_arguments(node, None);
            let node_type = if block.is_some() || !args.is_empty() {
                "FCALL"
            } else {
                "VCALL"
            };
            let children = vec![
                Child::Symbol(name.to_string()),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(node_type, children, source));
            }
            return Some(self.wrap(node_type, children, node));
        }
        if self.dotted_call(node) {
            let (receiver, method) = self.dotted_call_parts(node, block)?;
            let args = self.call_arguments(node, None);
            let node_type = if self.safe_navigation_call(node) {
                "QCALL"
            } else {
                "CALL"
            };
            let receiver = optional_node(self.normalize_node(receiver));
            let args = if let Some(source) = call_source.as_ref() {
                self.list_or_nil_from_source_node(args, source)
            } else {
                list_or_nil(args, node, self)
            };
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(
                    node_type,
                    vec![receiver, Child::Symbol(method), args],
                    source,
                ));
            }
            return Some(self.wrap(node_type, vec![receiver, Child::Symbol(method), args], node));
        }

        let function = self
            .named_field(node, "function")
            .or_else(|| self.named_field(node, "call"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| Some(*child) != block)
            })?;
        let args = self.call_arguments(node, Some(function));
        if let Some(function_name) = self.identifier_text(function) {
            let node_type = if block.is_some() || !args.is_empty() {
                "FCALL"
            } else {
                "VCALL"
            };
            let children = vec![
                Child::Symbol(function_name),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(node_type, children, source));
            }
            return Some(self.wrap(node_type, children, node));
        }
        if self
            .normalization_adapter
            .bare_const_call_function(function)
        {
            let children = vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("FCALL", children, source));
            }
            return Some(self.wrap("FCALL", children, node));
        }
        if self.member_read_node(function) {
            let (receiver, method) = self.member_parts(function)?;
            let receiver = optional_node(self.normalize_node(receiver));
            let args = if let Some(source) = call_source.as_ref() {
                self.list_or_nil_from_source_node(args, source)
            } else {
                list_or_nil(args, node, self)
            };
            let children = vec![receiver, Child::Symbol(method), args];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("CALL", children, source));
            }
            return Some(self.wrap("CALL", children, node));
        }
        let function = optional_node(self.normalize_node(function));
        let args = if let Some(source) = call_source.as_ref() {
            self.list_or_nil_from_source_node(args, source)
        } else {
            list_or_nil(args, node, self)
        };
        let children = vec![function, Child::Symbol("call".to_string()), args];
        if let Some(source) = call_source.as_ref() {
            return Some(self.wrap_from_source_node("CALL", children, source));
        }
        Some(self.wrap("CALL", children, node))
    }

    fn normalize_element_reference(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self
            .normalization_adapter
            .element_reference_target(node, self.source)
            .unwrap_or(node);
        let named = self.named_children(target);
        let receiver = *named.first()?;
        let args = named
            .iter()
            .skip(1)
            .filter_map(|arg| self.normalize_node(*arg))
            .collect::<Vec<_>>();
        if self.self_node(receiver) {
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol("[]".to_string()),
                    list_or_nil(args, node, self),
                ],
                node,
            ));
        }
        let receiver = optional_node(self.normalize_node(receiver));
        let args = list_or_nil(args, node, self);
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol("[]".to_string()), args],
            node,
        ))
    }

    fn normalize_rescue_modifier(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let body = named.first().and_then(|body| self.normalize_node(*body));
        let handler = named
            .get(1)
            .and_then(|handler| self.normalize_node(*handler));
        let resbody = self.wrap(
            "RESBODY",
            vec![Child::Nil, optional_node(handler), Child::Nil],
            node,
        );
        Some(self.wrap(
            "RESCUE",
            vec![
                optional_node(body),
                Child::Node(Box::new(resbody)),
                Child::Nil,
            ],
            node,
        ))
    }

    fn normalize_ensure_clause(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_body_nodes(self.named_children(node), node)
    }

    #[cfg(test)]
    fn normalize_dotted_call_expression(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_dotted_call_expression_with_source(node, None)
    }

    fn normalize_dotted_call_expression_with_source(
        &mut self,
        node: TreeSitterNode<'_>,
        source: Option<&Node>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1 && self.dotted_call(raw_named[0]) {
            raw_named[0]
        } else {
            node
        };
        let (receiver_raw, method) = self.dotted_call_parts(target, None)?;
        let args = self.call_arguments(target, None);
        let args = if let Some(source) = source {
            self.list_or_nil_from_source_node(args, source)
        } else {
            list_or_nil(args, node, self)
        };
        let receiver = optional_node(self.normalize_node(receiver_raw));
        let node_type = if self.safe_navigation_call(target) {
            "QCALL"
        } else {
            "CALL"
        };
        let children = vec![receiver, Child::Symbol(method), args];
        if let Some(source) = source {
            return Some(self.wrap_from_source_node(node_type, children, source));
        }
        Some(self.wrap(node_type, children, node))
    }

    fn normalize_begin(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let rescue_nodes = named
            .iter()
            .copied()
            .filter(|child| child.kind() == "rescue")
            .collect::<Vec<_>>();
        let ensure_node = named.iter().copied().find(|child| child.kind() == "ensure");
        if rescue_nodes.is_empty() {
            let Some(ensure_node) = ensure_node else {
                let children = self.normalize_children(node);
                return Some(self.wrap("BEGIN", children, node));
            };
            let body_nodes = named
                .iter()
                .copied()
                .take_while(|child| child.kind() != "ensure")
                .collect::<Vec<_>>();
            let body =
                self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
            let ensure_body = self.normalize_body(ensure_node);
            let source_start = body_nodes.first().copied().unwrap_or(node);
            let ensure_named = self.named_children(ensure_node);
            let source_end = ensure_named.last().copied().unwrap_or(ensure_node);
            let source = self.source_from_nodes(source_start, source_end);
            return Some(self.wrap_from_source_node(
                "ENSURE",
                vec![optional_node(body), optional_node(ensure_body)],
                &source,
            ));
        }

        let body_nodes = named
            .iter()
            .copied()
            .take_while(|child| child.kind() != "rescue")
            .collect::<Vec<_>>();
        let body =
            self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
        let resbodies = rescue_nodes
            .iter()
            .filter_map(|child| self.normalize_rescue_clause(*child))
            .collect::<Vec<_>>();
        let source_start = body_nodes.first().copied().unwrap_or(node);
        let source_end = rescue_nodes
            .last()
            .and_then(|last| self.rescue_source_end(*last))
            .or_else(|| rescue_nodes.last().copied())
            .unwrap_or(node);
        let source = self.source_from_nodes(source_start, source_end);
        let rescued = self.wrap_from_source_node(
            "RESCUE",
            vec![
                optional_node(body),
                optional_node(self.link_rescue_chain(resbodies)),
                Child::Nil,
            ],
            &source,
        );
        let Some(ensure_node) = ensure_node else {
            return Some(rescued);
        };
        let ensure_body = self.normalize_body(ensure_node);
        let ensure_named = self.named_children(ensure_node);
        let source_end = ensure_named.last().copied().unwrap_or(ensure_node);
        let source = self.source_from_nodes(source_start, source_end);
        Some(self.wrap_from_source_node(
            "ENSURE",
            vec![Child::Node(Box::new(rescued)), optional_node(ensure_body)],
            &source,
        ))
    }

    fn normalize_rescue_clause(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let exceptions = self
            .normalization_adapter
            .rescue_clause_exceptions(node, self.source);
        let exception_nodes = exceptions
            .iter()
            .filter_map(|child| {
                if child.kind() == "exceptions"
                    && ruby_exception_constant_text(node_text(*child, self.source))
                {
                    Some(self.normalize_const(*child))
                } else {
                    self.normalize_node(*child)
                }
            })
            .collect::<Vec<_>>();
        let exception_source = self
            .normalization_adapter
            .rescue_clause_exceptions_source(node, self.source);
        let exception_variable = self.rescue_exception_variable(node);
        let handler = self.normalization_adapter.rescue_clause_handler(node);
        let normalized_handler = handler.and_then(|handler| self.normalize_body(handler));
        let body = self.prepend_rescue_exception_assignment(normalized_handler, exception_variable);
        Some(self.wrap(
            "RESBODY",
            vec![
                list_or_nil(exception_nodes, exception_source.unwrap_or(node), self),
                optional_node(body),
                Child::Nil,
            ],
            node,
        ))
    }

    fn rescue_source_end<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(handler) = self.normalization_adapter.rescue_clause_handler(node) {
            return self
                .named_children(handler)
                .last()
                .copied()
                .or(Some(handler));
        }

        self.named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() != "comment")
            .or(Some(node))
    }

    fn link_rescue_chain(&self, mut resbodies: Vec<Node>) -> Option<Node> {
        let mut next = None;
        while let Some(mut current) = resbodies.pop() {
            while current.children.len() <= 2 {
                current.children.push(Child::Nil);
            }
            current.children[2] = optional_node(next);
            next = Some(current);
        }
        next
    }

    fn rescue_exception_variable(&self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self
            .normalization_adapter
            .rescue_clause_exception_variable_name(node)?;
        let source = self
            .normalization_adapter
            .rescue_clause_exception_variable_source(node)
            .unwrap_or(name);
        let errinfo = self.wrap("ERRINFO", Vec::new(), source);
        Some(self.wrap(
            "LASGN",
            vec![
                Child::String(node_text(name, self.source).to_string()),
                Child::Node(Box::new(errinfo)),
            ],
            source,
        ))
    }

    fn prepend_rescue_exception_assignment(
        &self,
        body: Option<Node>,
        assignment: Option<Node>,
    ) -> Option<Node> {
        let Some(assignment) = assignment else {
            return body;
        };
        let Some(mut body) = body else {
            return Some(assignment);
        };
        if body.r#type == "BLOCK" {
            let mut children = vec![Child::Node(Box::new(assignment))];
            children.extend(
                body.children
                    .into_iter()
                    .filter(|child| !matches!(child, Child::Nil)),
            );
            body.children = children;
            Some(body)
        } else {
            let source = self.source_from_normalized_nodes(&assignment, &body);
            Some(self.wrap_from_source_node(
                "BLOCK",
                vec![
                    Child::Node(Box::new(assignment)),
                    Child::Node(Box::new(body)),
                ],
                &source,
            ))
        }
    }

    fn normalize_modifier_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let keyword = self.modifier_keyword(node);
        let (action, condition) = self.modifier_parts(node)?;
        let node_type = match keyword.as_deref() {
            Some("unless") => "UNLESS",
            Some("while") => "WHILE",
            Some("until") => "UNTIL",
            _ => "IF",
        };
        let condition = optional_node(self.normalize_node(condition));
        let action = optional_node(self.normalize_modifier_action(action));
        let trailing = if matches!(node_type, "WHILE" | "UNTIL") {
            Child::Bool(true)
        } else {
            Child::Nil
        };
        Some(self.wrap(node_type, vec![condition, action, trailing], node))
    }

    fn normalize_modifier_action(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self.modifier_return_action(node) {
            self.normalize_return_node(node)
        } else {
            self.normalize_node(node)
        }
    }

    fn normalize_command_call_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) && raw_named.len() == 1
            && raw_named[0].kind() == "call"
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let function = self.named_children(target).into_iter().next()?;
        if self.visibility_inline_def_statement(node, function) {
            let method = self.inline_def_from_statement(node);
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol(node_text(function, self.source).to_string()),
                    list_or_nil(method.into_iter().collect(), node, self),
                ],
                node,
            ));
        }
        let args_node = self
            .named_children(target)
            .into_iter()
            .find(|child| matches!(child.kind(), "argument_list" | "arguments"));
        let args = args_node
            .map(|args| self.command_arguments(args))
            .unwrap_or_default();
        let block = self.call_block(target);
        let call_source = block.map(|block| self.source_before_child(node, block));
        if self.ruby() && node_text(function, self.source) == "yield" {
            let children = vec![list_or_nil(args, args_node.unwrap_or(node), self)];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("YIELD", children, source));
            }
            return Some(self.wrap("YIELD", children, node));
        }
        let call_type = if args.is_empty() { "VCALL" } else { "FCALL" };
        let call_children = vec![
            Child::Symbol(node_text(function, self.source).to_string()),
            list_or_nil(args, args_node.unwrap_or(node), self),
        ];
        let call = if let Some(source) = call_source.as_ref() {
            self.wrap_from_source_node(call_type, call_children, source)
        } else {
            self.wrap(call_type, call_children, node)
        };
        let Some(block) = block else {
            return Some(call);
        };
        let block_args = self.normalize_block_parameters(Some(block));
        let body = self.with_ruby_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer.normalize_body(body_node).map(dynamic_scope)
        });
        Some(self.wrap(
            "ITER",
            vec![
                Child::Node(Box::new(call)),
                Child::Node(Box::new(self.scope(body, block_args, node))),
            ],
            node,
        ))
    }

    fn normalize_visibility_inline_def(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let message =
            node_text(self.named_children(node).into_iter().next()?, self.source).to_string();
        let args = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list");
        let method = self.inline_def_from_argument_list(args);
        Some(self.wrap(
            "FCALL",
            vec![
                Child::Symbol(message),
                list_or_nil(method.into_iter().collect(), args.unwrap_or(node), self),
            ],
            node,
        ))
    }

    fn normalize_const(&mut self, node: TreeSitterNode<'_>) -> Node {
        if matches!(node.kind(), "scope_resolution" | "scoped_type_identifier") {
            let parts = self.named_children(node);
            let base = parts
                .first()
                .map(|part| self.normalize_const(*part))
                .map(|part| Child::Node(Box::new(part)))
                .unwrap_or(Child::Nil);
            let name = self
                .named_field(node, "name")
                .or_else(|| parts.last().copied())
                .map(|name| node_text(name, self.source).to_string())
                .unwrap_or_default();
            return self.wrap("COLON2", vec![base, Child::Symbol(name)], node);
        }

        self.wrap(
            "CONST",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    fn const_for(&mut self, node: Option<TreeSitterNode<'_>>, source: TreeSitterNode<'_>) -> Node {
        let Some(node) = node else {
            return self.wrap(
                "CONST",
                vec![Child::Symbol("(anonymous)".to_string())],
                source,
            );
        };
        if self.const_kind(node.kind()) {
            return self.normalize_const(node);
        }
        self.wrap(
            "CONST",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    fn normalize_global_variable(&self, node: TreeSitterNode<'_>) -> Node {
        let text = node_text(node, self.source).to_string();
        if let Some(value) = text.strip_prefix('$') {
            if value
                .chars()
                .next()
                .map(|first| matches!(first, '1'..='9'))
                .unwrap_or(false)
                && value.chars().all(|ch| ch.is_ascii_digit())
            {
                let number = value
                    .parse::<i64>()
                    .expect("validated global nth reference should parse");
                return self.wrap("NTH_REF", vec![Child::Integer(number)], node);
            }
        }
        self.wrap("GVAR", vec![Child::String(text)], node)
    }

    fn array_literal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .array_literal_statement(node, self.source)
    }

    fn normalize_array_literal_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self
            .normalization_adapter
            .array_literal_target(node, self.source)
            .unwrap_or(node);
        let values = self
            .normalization_adapter
            .array_literal_values(target, self.source)
            .into_iter()
            .filter_map(|child| self.normalize_array_literal_value(child))
            .collect::<Vec<_>>();
        if values.is_empty() {
            Some(self.wrap("ZLIST", Vec::new(), target))
        } else {
            Some(self.list_node(values, target))
        }
    }

    fn normalize_array_literal_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() == "field" {
            let named = self.named_children(node);
            if named.len() == 1 {
                return self.normalize_node(named[0]);
            }
            if named.is_empty() {
                return Some(self.normalize_terminal_statement(node));
            }
        }

        self.normalize_node(node)
    }

    fn element_reference_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .element_reference_statement(node, self.source)
    }

    fn normalize_element_reference_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self
            .normalization_adapter
            .element_reference_target(node, self.source)
            .unwrap_or(node);
        let receiver = self
            .normalization_adapter
            .element_reference_receiver(target, self.source)?;
        let args = self
            .normalization_adapter
            .element_reference_arguments(target, self.source)
            .into_iter()
            .filter_map(|arg| self.normalize_node(arg))
            .collect::<Vec<_>>();
        if self.ruby() && self.self_node(receiver) {
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol("[]".to_string()),
                    list_or_nil(args, target, self),
                ],
                target,
            ));
        }

        let receiver = optional_node(self.normalize_node(receiver));
        let args = list_or_nil(args, target, self);
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol("[]".to_string()), args],
            target,
        ))
    }

    fn hash_literal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .hash_literal_statement(node, self.source)
    }

    fn normalize_hash_literal_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self
            .normalization_adapter
            .hash_literal_target(node, self.source)
            .unwrap_or(node);
        let children = self
            .normalization_adapter
            .hash_literal_values(target, self.source)
            .into_iter()
            .filter_map(|child| self.normalize_hash_literal_value(child))
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap("HASH", children, target))
    }

    fn normalize_hash_literal_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() == "field" {
            let named = self.named_children(node);
            if named.len() >= 2 {
                let key = named[0];
                let value = named[1];
                let key_lit = self.wrap(
                    "LIT",
                    vec![Child::Symbol(node_text(key, self.source).to_string())],
                    key,
                );
                let value = self.normalize_node(value);
                return Some(self.wrap(
                    "HASH",
                    vec![Child::Node(Box::new(key_lit)), optional_node(value)],
                    node,
                ));
            }
        }

        self.normalize_node(node)
    }

    fn empty_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .empty_body_statement(node, self.source)
    }

    fn heredoc_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.heredoc_body_statement(node)
    }

    fn heredoc_call_for_body(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .heredoc_call_for_body(node, self.source)
    }

    fn terminal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) && self.named_children(node).is_empty()
            && !node_text(node, self.source).trim().is_empty()
    }

    fn normalize_terminal_statement(&self, node: TreeSitterNode<'_>) -> Node {
        let text = node_text(node, self.source).trim();
        if self.ruby() && text == "yield" {
            return self.wrap("YIELD", vec![Child::Nil], node);
        }
        if ruby_instance_variable_text(text) {
            return self.wrap("IVAR", vec![Child::String(text.to_string())], node);
        }
        if text.starts_with('$') {
            return self.normalize_global_variable(node);
        }
        if text == "nil" {
            return self.wrap("NIL", Vec::new(), node);
        }
        if text == "true" {
            return self.wrap("TRUE", Vec::new(), node);
        }
        if text == "false" {
            return self.wrap("FALSE", Vec::new(), node);
        }
        if let Some(symbol) = text.strip_prefix(':') {
            if exact_bare_identifier_text(symbol) {
                return self.wrap("LIT", vec![Child::Symbol(symbol.to_string())], node);
            }
        }
        if exact_integer_text(text) {
            if let Ok(value) = text.parse::<i64>() {
                return self.wrap("INTEGER", vec![Child::Integer(value)], node);
            }
        }
        if text == "[]" {
            return self.wrap("ZLIST", Vec::new(), node);
        }
        if bare_identifier_text(text) {
            if self.ruby() && !self.ruby_local_name(text) {
                return self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node);
            }
            return self.wrap("LVAR", vec![Child::String(text.to_string())], node);
        }

        self.wrap(&kind_type(node.kind()), Vec::new(), node)
    }

    fn normalize_array_literal(&mut self, node: TreeSitterNode<'_>) -> Node {
        let values = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_array_literal_value(child))
            .collect::<Vec<_>>();
        if values.is_empty() {
            self.wrap("ZLIST", Vec::new(), node)
        } else {
            self.list_node(values, node)
        }
    }

    fn normalize_pair(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let key = *named.first()?;
        let value_raw = named.get(1).copied();

        let has_hash_rocket = node
            .children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, self.source) == "=>");
        if has_hash_rocket {
            let children = [
                self.normalize_node(key),
                value_raw.and_then(|value| self.normalize_node(value)),
            ]
            .into_iter()
            .flatten()
            .map(|child| Child::Node(Box::new(child)))
            .collect();
            return Some(self.wrap("HASH", children, node));
        }

        let key_text = node_text(key, self.source);
        let key_lit = self.wrap("LIT", vec![Child::Symbol(key_text.to_string())], key);
        if self.ruby() && key.kind() == "hash_key_symbol" && value_raw.is_none() {
            let value = self.local_or_call_for_name(key_text, key);
            return Some(self.wrap(
                "HASH",
                vec![Child::Node(Box::new(key_lit)), Child::Node(Box::new(value))],
                node,
            ));
        }

        let mut children = vec![Child::Node(Box::new(key_lit))];
        if let Some(value) = value_raw.and_then(|value| self.normalize_node(value)) {
            children.push(Child::Node(Box::new(value)));
        }
        Some(self.wrap("HASH", children, node))
    }

    fn normalize_block_argument(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let value = self
            .named_children(node)
            .into_iter()
            .next()
            .and_then(|child| self.normalize_node(child));
        Some(self.wrap("BLOCK_PASS", vec![Child::Nil, optional_node(value)], node))
    }

    fn normalize_interpolated_string(&mut self, node: TreeSitterNode<'_>) -> Node {
        let children = self.normalize_children(node);
        self.wrap("DSTR", children, node)
    }

    fn normalize_subshell(&mut self, node: TreeSitterNode<'_>) -> Node {
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| match child.kind() {
                "interpolation" => self
                    .normalize_interpolation(child)
                    .map(|node| Child::Node(Box::new(node))),
                "string_content" => Some(Child::Node(Box::new(self.wrap(
                    "STR",
                    vec![Child::String(node_text(child, self.source).to_string())],
                    child,
                )))),
                _ => None,
            })
            .collect::<Vec<_>>();
        let node_type = if children
            .iter()
            .any(|child| matches!(child, Child::Node(node) if node.r#type == "EVSTR"))
        {
            "DXSTR"
        } else {
            "XSTR"
        };
        self.wrap(node_type, children, node)
    }

    fn normalize_chained_string(&mut self, node: TreeSitterNode<'_>) -> Node {
        let mut normalized_children = Vec::new();
        for child in self.named_children(node) {
            let normalized = self.normalize_node(child);
            normalized_children.push((child, normalized));
        }

        let mut parts = Vec::new();
        for (_, normalized) in &normalized_children {
            match normalized {
                Some(normalized) if normalized.r#type == "DSTR" => {
                    parts.extend(normalized.children.clone());
                }
                Some(normalized) => {
                    parts.push(Child::Node(Box::new(normalized.clone())));
                }
                None => {}
            }
        }

        let source = self
            .dynamic_string_source(&normalized_children)
            .or_else(|| normalized_children.first().map(|(child, _)| *child))
            .unwrap_or(node);
        self.wrap("DSTR", parts, source)
    }

    fn normalize_concatenated_string_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let target = concatenated_string_target(node).unwrap_or(node);
        let mut normalized_children = Vec::new();
        for child in self.named_children(target) {
            let normalized = self.normalize_node(child);
            normalized_children.push((child, normalized));
        }

        let mut parts = Vec::new();
        for (_, normalized) in &normalized_children {
            match normalized {
                Some(normalized) if normalized.r#type == "DSTR" => {
                    parts.extend(normalized.children.clone());
                }
                Some(normalized) => {
                    parts.push(Child::Node(Box::new(normalized.clone())));
                }
                None => {}
            }
        }

        let source = self
            .dynamic_string_source(&normalized_children)
            .or_else(|| normalized_children.first().map(|(child, _)| *child))
            .unwrap_or(node);
        self.wrap("DSTR", parts, source)
    }

    fn dynamic_string_source<'tree>(
        &self,
        normalized_children: &[(TreeSitterNode<'tree>, Option<Node>)],
    ) -> Option<TreeSitterNode<'tree>> {
        normalized_children
            .iter()
            .find(|(_, child_node)| {
                let Some(child_node) = child_node else {
                    return false;
                };
                child_node.r#type == "DSTR"
                    && child_node
                        .children
                        .iter()
                        .filter_map(self::node)
                        .any(|part| part.r#type == "EVSTR")
            })
            .map(|(child, _)| *child)
    }

    fn normalize_interpolated_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let children = self.normalize_children(node);
        self.wrap("DSTR", children, node)
    }

    fn normalize_interpolation(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let exprs = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect::<Vec<_>>();
        let body = if exprs.len() == 1 {
            exprs.into_iter().next()
        } else if exprs.is_empty() {
            None
        } else {
            Some(self.list_node(exprs, node))
        };
        Some(
            self.wrap(
                "EVSTR",
                body.into_iter()
                    .map(|node| Child::Node(Box::new(node)))
                    .collect(),
                node,
            ),
        )
    }

    fn normalize_heredoc_body_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let mut heredoc_bodies = self
            .named_children(node)
            .into_iter()
            .filter(|child| child.kind() == "heredoc_body");
        let mut children = Vec::new();

        for child in self.named_children(node) {
            if child.kind() == "heredoc_body" {
                continue;
            }

            let normalized = if self.heredoc_call_for_body(child) {
                let body = heredoc_bodies.next();
                self.with_current_heredoc_body(body, |normalizer| normalizer.normalize_node(child))
            } else {
                self.normalize_body(child)
            };

            if let Some(normalized) = normalized {
                children.push(normalized);
            }
        }

        if children.is_empty() {
            None
        } else if children.len() == 1 {
            children.into_iter().next()
        } else {
            Some(
                self.wrap(
                    "BLOCK",
                    children
                        .into_iter()
                        .map(|child| Child::Node(Box::new(child)))
                        .collect(),
                    node,
                ),
            )
        }
    }

    fn normalize_heredoc_beginning(&mut self, node: TreeSitterNode<'_>) -> Node {
        let mut heredoc_body = None;
        let mut ancestor = node.parent();
        while let Some(candidate) = ancestor {
            let bodies = self
                .named_children(candidate)
                .into_iter()
                .filter(|child| child.kind() == "heredoc_body")
                .collect::<Vec<_>>();
            if !bodies.is_empty() {
                heredoc_body = if let Some(current) = self.current_heredoc_body_span {
                    bodies
                        .iter()
                        .copied()
                        .find(|body| span(*body) == current)
                        .or_else(|| bodies.first().copied())
                } else {
                    bodies.first().copied()
                };
                break;
            }
            ancestor = candidate.parent();
        }
        let children = heredoc_body
            .map(|body| self.normalize_heredoc_children(body))
            .unwrap_or_default();
        self.wrap("DSTR", children, node)
    }

    fn with_current_heredoc_body<T>(
        &mut self,
        body: Option<TreeSitterNode<'_>>,
        block: impl FnOnce(&mut Self) -> T,
    ) -> T {
        let previous = self.current_heredoc_body_span;
        self.current_heredoc_body_span = body.map(span);
        let result = block(self);
        self.current_heredoc_body_span = previous;
        result
    }

    fn normalize_heredoc_children(&mut self, node: TreeSitterNode<'_>) -> Vec<Child> {
        self.named_children(node)
            .into_iter()
            .filter_map(|child| match child.kind() {
                "interpolation" => self.normalize_interpolation(child),
                "heredoc_content" => {
                    let text = node_text(child, self.source).to_string();
                    if text.is_empty() {
                        None
                    } else {
                        Some(self.wrap("STR", vec![Child::String(text)], child))
                    }
                }
                _ => None,
            })
            .map(|child| Child::Node(Box::new(child)))
            .collect()
    }

    fn normalize_identifier(&mut self, node: TreeSitterNode<'_>) -> Node {
        let name = self
            .identifier_text(node)
            .unwrap_or_else(|| node_text(node, self.source).to_string());
        self.normalize_identifier_with_name(node, name)
    }

    fn normalize_identifier_with_name(&mut self, node: TreeSitterNode<'_>, name: String) -> Node {
        if self.ruby_vcall_identifier(node, &name) || self.vcall_identifier(node, &name) {
            self.wrap("VCALL", vec![Child::Symbol(name)], node)
        } else {
            self.wrap("LVAR", vec![Child::String(name)], node)
        }
    }

    fn normalize_parameters(&mut self, node: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if !self.normalization_adapter.normalize_default_parameters() {
            return None;
        }
        let node = node?;
        let pre_init = self
            .named_children(node)
            .into_iter()
            .filter_map(|param| self.normalize_parameter_init(param))
            .map(|node| Child::Node(Box::new(node)))
            .collect::<Vec<_>>();
        if pre_init.is_empty() {
            None
        } else {
            Some(self.wrap("ARGS", pre_init, node))
        }
    }

    fn normalize_parameter_init(&mut self, param: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.parameter_name(param)?;
        let value = self
            .named_field(param, "value")
            .or_else(|| self.parameter_default_value(param))
            .and_then(|value| self.normalize_node(value));
        Some(self.wrap(
            "LASGN",
            vec![Child::Symbol(name), optional_node(value)],
            param,
        ))
    }

    fn parameter_name(&self, param: TreeSitterNode<'_>) -> Option<String> {
        if matches!(
            param.kind(),
            "identifier"
                | "hash_splat_parameter"
                | "splat_parameter"
                | "block_parameter"
                | "keyword_parameter"
                | "optional_parameter"
        ) {
            if let Some(name) = self.identifier_text(param) {
                return Some(name);
            }
        }
        self.named_field(param, "name")
            .and_then(|name| self.identifier_text(name))
            .or_else(|| {
                self.named_children(param)
                    .into_iter()
                    .find_map(|child| self.identifier_text(child))
            })
    }

    fn parameter_default_value<'tree>(
        &self,
        param: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if !matches!(param.kind(), "optional_parameter" | "keyword_parameter") {
            return None;
        }
        let name = self.parameter_name(param)?;
        self.named_children(param).into_iter().rev().find(|child| {
            self.identifier_text(*child).as_deref() != Some(name.as_str())
                && !matches!(child.kind(), "comment")
        })
    }

    fn normalize_block_parameters(&mut self, block: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if !self.normalization_adapter.normalize_block_parameters() {
            return None;
        }
        let block = block?;
        let params = self
            .named_children(block)
            .into_iter()
            .find(|child| child.kind() == "block_parameters")?;
        let pre_init = self
            .named_children(params)
            .into_iter()
            .filter(|param| param.kind() == "destructured_parameter")
            .filter_map(|param| self.normalize_destructured_block_parameter(param))
            .map(|node| Child::Node(Box::new(node)))
            .collect::<Vec<_>>();
        if pre_init.is_empty() {
            None
        } else {
            Some(self.wrap("ARGS", pre_init, params))
        }
    }

    fn normalize_destructured_block_parameter(
        &mut self,
        param: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let mut targets = Vec::new();
        for child in self.named_children(param) {
            self.collect_destructured_parameter_targets(child, &mut targets);
        }
        if targets.is_empty() {
            return None;
        }
        let dvar = self.wrap("DVAR", vec![Child::Nil], param);
        Some(self.wrap(
            "MASGN",
            vec![
                Child::Node(Box::new(dvar)),
                list_or_nil(targets, param, self),
                Child::Nil,
            ],
            param,
        ))
    }

    fn collect_destructured_parameter_targets(
        &mut self,
        node: TreeSitterNode<'_>,
        targets: &mut Vec<Node>,
    ) {
        if self.identifier_kind(node.kind()) {
            targets.push(self.wrap(
                "DASGN",
                vec![
                    Child::String(node_text(node, self.source).to_string()),
                    Child::Nil,
                ],
                node,
            ));
            return;
        }

        for child in self.named_children(node) {
            self.collect_destructured_parameter_targets(child, targets);
        }
    }

    fn normalize_children(&mut self, node: TreeSitterNode<'_>) -> Vec<Child> {
        let mut children = Vec::new();
        for child in self.named_children(node) {
            if child.kind() == "heredoc_body" {
                continue;
            }
            if self.assignment_rhs(child) {
                continue;
            }
            if let Some(normalized) = self.normalize_node(child) {
                children.push(Child::Node(Box::new(normalized)));
            }
        }
        children
    }

    fn scope(&self, body: Option<Node>, args: Option<Node>, source: TreeSitterNode<'_>) -> Node {
        let source_node = body.as_ref().or(args.as_ref()).cloned();
        let children = vec![Child::Nil, optional_node(args), optional_node(body)];
        if let Some(source_node) = source_node {
            self.wrap_from_source_node("SCOPE", children, &source_node)
        } else {
            self.wrap("SCOPE", children, source)
        }
    }

    #[cfg(test)]
    fn list(&self, children: Option<Vec<Node>>, source: TreeSitterNode<'_>) -> Option<Node> {
        let children = children?;
        if children.is_empty() {
            return None;
        }

        Some(self.list_node(children, source))
    }

    fn list_node(&self, children: Vec<Node>, source: TreeSitterNode<'_>) -> Node {
        self.wrap(
            "LIST",
            children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            source,
        )
    }

    fn list_or_nil_from_source_node(&self, children: Vec<Node>, source: &Node) -> Child {
        if children.is_empty() {
            Child::Nil
        } else {
            Child::Node(Box::new(
                self.wrap_from_source_node(
                    "LIST",
                    children
                        .into_iter()
                        .map(|child| Child::Node(Box::new(child)))
                        .collect(),
                    source,
                ),
            ))
        }
    }

    fn wrap(&self, node_type: &str, children: Vec<Child>, source: TreeSitterNode<'_>) -> Node {
        let node_span = span(source);
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: node_span[0],
            first_column: node_span[1],
            last_lineno: node_span[2],
            last_column: node_span[3],
            text: self.source_text(node_text(source, self.source)),
        }
    }

    fn wrap_from_nodes(
        &self,
        node_type: &str,
        children: Vec<Child>,
        first: TreeSitterNode<'_>,
        last: TreeSitterNode<'_>,
    ) -> Node {
        let first_span = span(first);
        let last_span = span(last);
        let text = self
            .source
            .get(first.start_byte()..last.end_byte())
            .unwrap_or("")
            .to_string();
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: first_span[0],
            first_column: first_span[1],
            last_lineno: last_span[2],
            last_column: last_span[3],
            text: self.source_text(&text),
        }
    }

    fn wrap_from_source_node(&self, node_type: &str, children: Vec<Child>, source: &Node) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: source.first_lineno,
            first_column: source.first_column,
            last_lineno: source.last_lineno,
            last_column: source.last_column,
            text: self.source_text(&source.text),
        }
    }

    fn with_ruby_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
        if !self.ruby() {
            return f(self);
        }
        let previous = self.local_stack.clone();
        if reset {
            self.local_stack.clear();
        }
        self.local_stack.push(self.ruby_scope_locals(node));
        let result = f(self);
        self.local_stack = previous;
        result
    }

    fn ruby_scope_locals(&self, node: TreeSitterNode<'_>) -> BTreeSet<String> {
        let mut locals = BTreeSet::new();
        self.collect_ruby_scope_locals(node, &mut locals, true);
        locals
    }

    fn collect_ruby_scope_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
        root: bool,
    ) {
        if !root && self.ruby_scope_boundary(node) {
            return;
        }
        self.collect_ruby_parameter_locals(node, locals);
        self.collect_ruby_assignment_locals(node, locals);
        for child in self.named_children(node) {
            if !self.ruby_scope_child_boundary(child) {
                self.collect_ruby_scope_locals(child, locals, false);
            }
        }
    }

    fn collect_ruby_parameter_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if !matches!(
            node.kind(),
            "method_parameters" | "block_parameters" | "lambda_parameters"
        ) {
            return;
        }

        for child in self.named_children(node) {
            self.collect_identifier_names(child, locals);
        }
    }

    fn collect_ruby_assignment_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if node.kind() == "exception_variable" {
            self.collect_identifier_names(node, locals);
            return;
        }

        if !self.ruby_assignment_node(node) {
            return;
        }

        if let Some(left) = self.assignment_left(node) {
            self.collect_assignment_target_names(left, locals);
        }
    }

    fn collect_assignment_target_names(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if let Some(name) = self.identifier_text(node) {
            locals.insert(name);
            return;
        }
        if matches!(
            node.kind(),
            "left_assignment_list"
                | "expression_list"
                | "splat"
                | "splat_parameter"
                | "rest_assignment"
        ) {
            for child in self.named_children(node) {
                self.collect_assignment_target_names(child, locals);
            }
        }
    }

    fn collect_identifier_names(&self, node: TreeSitterNode<'_>, locals: &mut BTreeSet<String>) {
        if let Some(name) = self.identifier_text(node) {
            locals.insert(name);
        }
        for child in self.raw_named_children(node) {
            self.collect_identifier_names(child, locals);
        }
    }

    fn ruby_scope_boundary(&self, node: TreeSitterNode<'_>) -> bool {
        if matches!(node.kind(), "block" | "do_block")
            && node
                .parent()
                .map(|parent| parent.kind() == "lambda")
                .unwrap_or(false)
        {
            return false;
        }
        matches!(
            node.kind(),
            "singleton_class" | "lambda" | "block" | "do_block"
        ) || function_kind(node.kind())
            || self.class_node(node)
            || self.module_node(node)
    }

    fn ruby_scope_child_boundary(&self, node: TreeSitterNode<'_>) -> bool {
        self.ruby_scope_boundary(node)
    }

    fn ruby_vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        self.ruby()
            && self.identifier_kind(node.kind())
            && !self.assignment_lhs(node)
            && !self.ruby_definition_identifier(node)
            && !self.ruby_local_name(name)
    }

    fn ruby_local_name(&self, name: &str) -> bool {
        self.local_stack
            .iter()
            .rev()
            .any(|scope| scope.contains(name))
    }

    fn ruby(&self) -> bool {
        self.normalization_adapter.ruby()
    }

    fn instance_variable(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .instance_variable(node, self.source)
    }

    fn global_variable(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .global_variable(node, self.source)
    }

    fn assignment_operator(&self, text: &str) -> bool {
        self.normalization_adapter.assignment_operator(text)
    }

    fn vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        if !self.identifier_kind(node.kind()) {
            return false;
        }
        if self.ruby() && self.ruby_local_name(name) {
            return false;
        }
        let Some(parent) = node.parent() else {
            return false;
        };
        if matches!(
            parent.kind(),
            "method" | "method_parameters" | "parameter_list" | "argument_list" | "arguments"
        ) {
            return false;
        }
        if self.member_read_node(parent) {
            return false;
        }
        if self.dotted_expression(parent) {
            return false;
        }
        if self.assignment_lhs(node) || self.assignment_rhs(node) {
            return false;
        }

        if matches!(parent.kind(), "body_statement" | "block_body" | "then")
            && self.parent_named_child(parent, node)
        {
            return true;
        }
        if matches!(parent.kind(), "if_modifier" | "unless_modifier")
            && self
                .named_children(parent)
                .into_iter()
                .next()
                .map(|child| child == node)
                .unwrap_or(false)
        {
            return true;
        }

        false
    }

    fn ruby_definition_identifier(&self, node: TreeSitterNode<'_>) -> bool {
        let Some(parent) = self.parent_node(node) else {
            return false;
        };
        if matches!(parent.kind(), "method" | "singleton_method") {
            let name = self.named_field(parent, "name").or_else(|| {
                self.named_children(parent)
                    .into_iter()
                    .find(|child| self.identifier_kind(child.kind()))
            });
            return name
                .map(|name| self.same_ts_node(name, node))
                .unwrap_or(false);
        }
        matches!(
            parent.kind(),
            "method_parameters"
                | "block_parameters"
                | "lambda_parameters"
                | "optional_parameter"
                | "keyword_parameter"
                | "block_parameter"
        )
    }

    fn ruby_assignment_node(&self, node: TreeSitterNode<'_>) -> bool {
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            return true;
        }
        if node.kind() == "pattern"
            && node
                .children(&mut node.walk())
                .any(|child| !child.is_named() && node_text(child, self.source) == "=")
        {
            return true;
        }
        let raw_named = self.raw_named_children(node);
        if node.kind() == "block_body"
            && raw_named.len() == 1
            && raw_named[0].kind() == "assignment"
        {
            return true;
        }

        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.has_assignment_operator_child(node)
    }

    fn self_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "self" | "this")
            || matches!(node_text(node, self.source), "self" | "this")
    }

    fn assignment_lhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.single_assignment_block_child(node) {
            return false;
        }
        if node
            .prev_sibling()
            .map(|sibling| node_text(sibling, self.source) == ":")
            .unwrap_or(false)
        {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        node.next_sibling()
            .map(|sibling| self.assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    fn literal_fragment_assignment_context(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .literal_fragment_assignment_context(node, self.source)
    }

    fn literal_fragment_expression_list(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "expression_list" {
            return false;
        }

        let named = self.named_children(node);
        named.len() == 1 && self.literal_fragment_assignment_context(named[0])
    }

    fn assignment_rhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.single_assignment_block_child(node) {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        node.prev_sibling()
            .map(|sibling| self.assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    fn single_assignment_block_child(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .single_assignment_block_child(node, self.source)
    }

    fn has_assignment_operator_child(&self, node: TreeSitterNode<'_>) -> bool {
        node.children(&mut node.walk()).any(|child| {
            !child.is_named() && self.assignment_operator(node_text(child, self.source))
        })
    }

    fn single_short_var_lhs(&self, node: TreeSitterNode<'_>) -> bool {
        let Some(parent) = node.parent() else {
            return false;
        };
        if parent.kind() != "short_var_declaration" {
            return false;
        }
        if self.named_children(node).len() != 1 {
            return false;
        }
        self.named_children(parent)
            .into_iter()
            .next()
            .map(|child| child == node)
            .unwrap_or(false)
    }

    fn modifier_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let named = self.named_children(node);
        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.modifier_keyword(node).is_some()
            && named.len() >= 2
    }

    fn modifier_return_action(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
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

    fn leading_if_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_if_statement(node, self.source)
    }

    fn leading_if_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_if_target(node, self.source)
    }

    fn normalize_leading_if_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.leading_if_target(node).unwrap_or(node);
        if target != node {
            return self.normalize_if(target);
        }
        let keyword = target
            .children(&mut target.walk())
            .next()
            .map(|child| child.kind().to_string())?;
        let condition = self
            .named_children(target)
            .into_iter()
            .find(|child| !matches!(child.kind(), "comment" | "then" | "elsif" | "else"))?;
        let consequence = self
            .named_children(target)
            .into_iter()
            .find(|child| child.kind() == "then")
            .or_else(|| self.branch_child(target, condition, 0));
        let alternative = self.explicit_alternative(target);
        let node_type = if keyword == "unless" { "UNLESS" } else { "IF" };
        let condition = optional_node(self.normalize_node(condition));
        let consequence = optional_node(consequence.and_then(|child| self.normalize_body(child)));
        let alternative =
            optional_node(alternative.and_then(|child| self.normalize_else_or_branch(child)));
        Some(self.wrap(node_type, vec![condition, consequence, alternative], target))
    }

    fn leading_case_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_case_statement(node, self.source)
    }

    fn leading_case_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_case_target(node, self.source)
    }

    fn normalize_leading_case_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.leading_case_target(node).unwrap_or(node);
        self.normalize_case(target)
    }

    fn leading_loop_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_loop_statement(node, self.source)
    }

    fn leading_loop_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_loop_target(node, self.source)
    }

    fn normalize_leading_loop_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.leading_loop_target(node).unwrap_or(node);
        if target != node {
            let keyword = target.children(&mut target.walk()).next()?.kind();
            let node_type = if keyword == "until" { "UNTIL" } else { "WHILE" };
            return self.normalize_loop(target, node_type);
        }
        let keyword = target.children(&mut target.walk()).next()?.kind();
        let node_type = if keyword == "until" { "UNTIL" } else { "WHILE" };
        let named = self.named_children(target);
        let condition = optional_node(
            named
                .first()
                .and_then(|condition| self.normalize_node(*condition)),
        );
        let body = optional_node(named.get(1).and_then(|body| self.normalize_body(*body)));
        Some(self.wrap(node_type, vec![condition, body], target))
    }

    fn normalize_leading_owner_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.leading_owner_target(node).unwrap_or(node);
        let keyword = target.children(&mut target.walk()).next()?.kind();
        let name = self.const_for(self.named_children(target).first().copied(), target);
        let body_node = self.named_field(target, "body").or_else(|| {
            self.named_children(target)
                .into_iter()
                .rev()
                .find(|child| self.block_kind(child.kind()))
        });
        let body = body_node.and_then(|body| self.normalize_body(body));
        if keyword == "module" {
            Some(self.wrap(
                "MODULE",
                vec![
                    Child::Node(Box::new(name)),
                    Child::Node(Box::new(self.scope(body, None, target))),
                ],
                target,
            ))
        } else {
            Some(self.wrap(
                "CLASS",
                vec![
                    Child::Node(Box::new(name)),
                    Child::Nil,
                    Child::Node(Box::new(self.scope(body, None, target))),
                ],
                target,
            ))
        }
    }

    fn rescue_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .rescue_body_statement(node, self.source)
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .rescue_body_target(node, self.source)
    }

    fn normalize_rescue_body_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.rescue_body_target(node)?;
        let body_nodes = self
            .normalization_adapter
            .rescue_body_nodes(target, self.source);
        let body = self.normalize_body_nodes(body_nodes.clone(), target);
        let rescue_nodes = self
            .normalization_adapter
            .rescue_clauses(target, self.source);
        let resbodies = rescue_nodes
            .iter()
            .filter_map(|child| self.normalize_rescue_clause(*child))
            .collect::<Vec<_>>();
        let source_start = body_nodes.first().copied().unwrap_or(target);
        let source_end = rescue_nodes
            .last()
            .and_then(|last| self.rescue_source_end(*last))
            .or_else(|| rescue_nodes.last().copied())
            .unwrap_or(target);
        let source = self.source_from_nodes(source_start, source_end);
        Some(self.wrap_from_source_node(
            "RESCUE",
            vec![
                optional_node(body),
                optional_node(self.link_rescue_chain(resbodies)),
                Child::Nil,
            ],
            &source,
        ))
    }

    fn ensure_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .ensure_body_statement(node, self.source)
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .ensure_body_target(node, self.source)
    }

    fn normalize_ensure_body_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.ensure_body_target(node)?;
        let body = if self.rescue_body_statement(target) {
            self.normalize_rescue_body_statement(target)
        } else {
            let body_nodes = self
                .normalization_adapter
                .ensure_body_nodes(target, self.source);
            self.normalize_body_nodes(body_nodes, target)
        };
        let ensure_node = self
            .normalization_adapter
            .ensure_clause(target, self.source)?;
        let ensure_body_node = self
            .normalization_adapter
            .ensure_clause_body(ensure_node)
            .unwrap_or(ensure_node);
        let ensure_body = self.normalize_body(ensure_body_node);
        let source = body.clone();
        let children = vec![optional_node(body), optional_node(ensure_body)];
        if let Some(source) = source.as_ref() {
            Some(self.wrap_from_source_node("ENSURE", children, source))
        } else {
            Some(self.wrap("ENSURE", children, target))
        }
    }

    fn command_call_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) || self.dotted_call(node)
        {
            return false;
        }

        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "call"
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let children = self.named_children(target);
        children
            .first()
            .map(|child| self.identifier_kind(child.kind()))
            .unwrap_or(false)
            && (children
                .iter()
                .any(|child| matches!(child.kind(), "argument_list" | "arguments"))
                || self.call_block(target).is_some())
    }

    fn visibility_inline_def_call(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "call" {
            return false;
        }
        let Some(message) = self.named_children(node).into_iter().next() else {
            return false;
        };
        if !inline_def_wrapper_mid(node_text(message, self.source)) {
            return false;
        }
        self.named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list")
            .map(|args| {
                node_text(args, self.source)
                    .trim_start()
                    .starts_with("def ")
            })
            .unwrap_or(false)
    }

    fn visibility_inline_def_statement(
        &self,
        node: TreeSitterNode<'_>,
        function: TreeSitterNode<'_>,
    ) -> bool {
        let function_text_source = self
            .normalization_adapter
            .inline_def_function_text_source(function, self.source);
        let function_text = node_text(function_text_source, self.source);
        inline_def_wrapper_mid(function_text) && node_text(node, self.source).contains("def ")
    }

    fn inline_def_from_argument_list(&mut self, args: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if !self.ruby() {
            return None;
        }
        self.inline_def_from_source(args?)
    }

    fn inline_def_from_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let source = self
            .named_children(target)
            .into_iter()
            .find(|child| child.kind() == "argument_list")
            .unwrap_or(target);
        self.inline_def_from_source(source)
    }

    fn inline_def_from_source(&mut self, source: TreeSitterNode<'_>) -> Option<Node> {
        if !self.ruby() {
            return None;
        }
        if let Some(method) = self
            .named_children(source)
            .into_iter()
            .find(|child| matches!(child.kind(), "method" | "singleton_method"))
        {
            return if method.kind() == "singleton_method" {
                self.normalize_singleton_function(method)
            } else {
                self.normalize_function(method)
            };
        }
        let body = self.inline_def_body(source);
        let receiver = self.inline_def_receiver(source);
        let normalized_body = self.with_ruby_scope(source, true, |normalizer| {
            let body = body.and_then(|body| normalizer.normalize_body(body));
            normalizer.elide_tail_returns(body)
        });
        if let Some(receiver) = receiver {
            let name = self.inline_def_name_after_receiver(source, receiver)?;
            if name.is_empty() {
                return None;
            }
            let receiver = self.normalize_node(receiver)?;
            return Some(self.wrap(
                "DEFS",
                vec![
                    Child::Node(Box::new(receiver)),
                    Child::Symbol(name),
                    Child::Node(Box::new(self.scope(normalized_body, None, source))),
                ],
                source,
            ));
        }

        let name = self
            .named_children(source)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))
            .map(|child| node_text(child, self.source).to_string())?;
        if name.is_empty() {
            return None;
        }
        Some(self.wrap(
            "DEFN",
            vec![
                Child::Symbol(name),
                Child::Node(Box::new(self.scope(normalized_body, None, source))),
            ],
            source,
        ))
    }

    fn inline_def_receiver<'tree>(
        &self,
        source: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let text = node_text(source, self.source);
        if !inline_def_receiver_text(text) {
            return None;
        }
        let children = self.named_children(source);
        if children.len() == 1
            && matches!(children[0].kind(), "method" | "singleton_method")
            && node_text(children[0], self.source) == text
        {
            return self.inline_def_receiver(children[0]);
        }

        children.into_iter().find(|child| {
            matches!(
                child.kind(),
                "self" | "this" | "constant" | "scope_resolution"
            )
        })
    }

    fn inline_def_name_after_receiver(
        &self,
        source: TreeSitterNode<'_>,
        receiver: TreeSitterNode<'_>,
    ) -> Option<String> {
        let children = self.named_children(source);
        if let Some(index) = children
            .iter()
            .position(|child| self.same_ts_node(*child, receiver))
        {
            return children
                .into_iter()
                .skip(index + 1)
                .find(|child| self.identifier_kind(child.kind()))
                .map(|child| node_text(child, self.source).to_string());
        }

        if children.len() == 1
            && matches!(children[0].kind(), "method" | "singleton_method")
            && node_text(children[0], self.source) == node_text(source, self.source)
        {
            return self.inline_def_name_after_receiver(children[0], receiver);
        }

        None
    }

    fn inline_def_body<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        let mut stack = self
            .named_children(node)
            .into_iter()
            .rev()
            .collect::<Vec<_>>();
        while let Some(child) = stack.pop() {
            if child.kind() == "body_statement" {
                return Some(child);
            }
            stack.extend(self.named_children(child).into_iter().rev());
        }
        None
    }

    fn modifier_keyword(&self, node: TreeSitterNode<'_>) -> Option<String> {
        let mut seen_named = false;
        for child in node.children(&mut node.walk()) {
            seen_named = seen_named || child.is_named();
            if seen_named
                && !child.is_named()
                && matches!(child.kind(), "if" | "unless" | "while" | "until")
            {
                return Some(child.kind().to_string());
            }
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            return self.modifier_keyword(raw_named[0]);
        }

        None
    }

    fn modifier_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, TreeSitterNode<'tree>)> {
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            if let Some(parts) = self.modifier_parts(raw_named[0]) {
                return Some(parts);
            }
        }

        let named = self.named_children(node);
        Some((*named.first()?, *named.last()?))
    }

    fn ternary_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .ternary_statement(node, self.source)
    }

    fn ternary_parts<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TernaryParts<'tree>> {
        self.normalization_adapter.ternary_parts(node, self.source)
    }

    fn case_argument_list(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .case_argument_list(node, self.source)
    }

    fn leading_function_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_function_statement(node, self.source)
    }

    fn leading_owner_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_owner_statement(node, self.source)
    }

    fn leading_owner_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_owner_target(node, self.source)
    }

    fn leading_function_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_function_target(node, self.source)
    }

    fn leading_function_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))
    }

    fn leading_function_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let body_kind = self.normalization_adapter.leading_function_body_kind();
        self.named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == body_kind)
    }

    fn zero_child_identifier_call(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .zero_child_identifier_call(node, self.source)
    }

    fn boolean_expression(&self, node: TreeSitterNode<'_>) -> bool {
        (self.normalization_adapter.boolean_expression_kind(node) || self.boolean_statement(node))
            && matches!(self.boolean_operator(node).as_deref(), Some("and" | "or"))
    }

    fn boolean_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return false;
        }
        let named = self.named_children(node);
        let target = self
            .normalization_adapter
            .boolean_statement_target(node, self.source, &named);
        if !matches!(
            self.binary_operator(target).as_deref(),
            Some("&&" | "||" | "and" | "or")
        ) {
            return false;
        }
        if self.named_children(target).len() < 2 {
            return false;
        }
        target.children(&mut target.walk()).all(|child| {
            child.is_named()
                || matches!(
                    node_text(child, self.source),
                    "&&" | "||" | "and" | "or" | "(" | ")"
                )
        })
    }

    fn operator_call_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .operator_call_expression_kind(node)
            && self.named_children(node).len() >= 2
            && self
                .binary_operator(node)
                .map(|operator| OPERATOR_CALL_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn comparison_expression(&self, node: TreeSitterNode<'_>) -> bool {
        if self.literal_fragment_expression_list(node) {
            return false;
        }

        self.normalization_adapter.comparison_expression_kind(node)
            && self
                .comparison_operator(node)
                .map(|operator| COMPARISON_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn infix_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.infix_statement_parts(node).is_some()
    }

    fn regex_literal(&self, node: Option<TreeSitterNode<'_>>) -> bool {
        node.map(|node| matches!(node.kind(), "regex" | "regex_literal"))
            .unwrap_or(false)
    }

    fn argument_list_unary_not(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "argument_list" {
            return false;
        }
        let named = self.named_children(node);
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| node_text(child, self.source) == "!")
            .unwrap_or(false)
            && named.len() == 1
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() != 1 || raw_named[0].kind() != "unary" {
            return false;
        }
        node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_not_expression(raw_named[0])
            && self.raw_named_children(raw_named[0]).len() == 1
    }

    fn unary_not_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return false;
        }
        let named = self.named_children(node);
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| node_text(child, self.source) == "!")
            .unwrap_or(false)
            && named.len() == 1
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && raw_named[0].kind() == "unary"
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_not_expression(raw_named[0])
            && self.raw_named_children(raw_named[0]).len() == 1
    }

    fn unary_not_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .unary_not_expression(node, self.source)
    }

    fn unary_minus_expression(&self, node: TreeSitterNode<'_>) -> bool {
        if self
            .normalization_adapter
            .unary_minus_expression(node, self.source)
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_minus_expression(raw_named[0])
    }

    fn infix_statement_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String, TreeSitterNode<'tree>)> {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return None;
        }
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && matches!(
                raw_named[0].kind(),
                "binary" | "binary_expression" | "comparison_operator"
            )
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let mut named_index = 0usize;
        let mut left = None;
        let mut right = None;
        let mut operator = None;
        for child in target.children(&mut target.walk()) {
            if child.is_named() {
                left.get_or_insert(child);
                if operator.is_some() {
                    right = Some(child);
                }
                named_index += 1;
            } else {
                let text = node_text(child, self.source);
                if COMPARISON_OPERATORS.contains(&text) || OPERATOR_CALL_OPERATORS.contains(&text) {
                    operator = Some(text.to_string());
                }
            }
        }
        if named_index == 2 {
            Some((left?, operator?, right?))
        } else {
            None
        }
    }

    fn boolean_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        let direct = self.binary_operator(node)?;
        if matches!(direct.as_str(), "&&" | "and") {
            Some("and".to_string())
        } else if matches!(direct.as_str(), "||" | "or") {
            Some("or".to_string())
        } else {
            None
        }
    }

    fn comparison_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if let Some(operator) = self.binary_operator(node) {
            if COMPARISON_OPERATORS.contains(&operator.as_str()) {
                return Some(operator);
            }
        }

        comparison_operator_from_text(&self.spaced_text(node))
    }

    fn binary_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        self.normalization_adapter
            .binary_operator(node, self.source)
    }

    fn spaced_text(&self, node: TreeSitterNode<'_>) -> String {
        format!(" {} ", node_text(node, self.source))
    }

    fn class_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.class_node(node)
    }

    fn module_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "module" && self.named_field(node, "name").is_some()
    }

    fn interpolated_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let children = self.named_children(node);
        self.normalization_adapter
            .interpolated_statement(node, &children)
    }

    fn concatenated_string_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let children = self.named_children(node);
        self.normalization_adapter
            .concatenated_string_statement(node, &children)
    }

    fn interpolated_string(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .interpolated_string(node, &self.named_children(node))
    }

    fn lambda_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .lambda_expression(node, self.source)
    }

    fn lambda_target<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.lambda_target(node, self.source)
    }

    fn interpolation_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.interpolation_node(node)
    }

    fn statement_call_with_block(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.call_block(node).is_some()
            && self.statement_block_call(node).is_some()
    }

    fn statement_block_call<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if self.dotted_call(node) {
            return Some(node);
        }

        let block = self.call_block(node);
        let child_source = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let children = self.named_children(child_source);

        children.into_iter().find(|child| {
            Some(*child) != block && (self.call_node(*child) || self.member_read_node(*child))
        })
    }

    fn yield_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .yield_statement(node, self.source)
    }

    fn yield_argument_list(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "argument_list" {
            return false;
        }
        let Some(parent) = self.parent_node(node) else {
            return false;
        };
        let mut cursor = parent.walk();
        let first_child_is_yield = parent
            .children(&mut cursor)
            .next()
            .map(|child| node_text(child, self.source) == "yield")
            .unwrap_or(false);
        first_child_is_yield
    }

    fn super_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .super_statement(node, self.source)
    }

    fn argument_list_element_reference(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "argument_list" {
            return false;
        }
        let named = self.named_children(node);
        if named
            .iter()
            .any(|child| matches!(child.kind(), "block" | "do_block"))
        {
            return false;
        }

        let children = node.children(&mut node.walk()).collect::<Vec<_>>();
        let direct_bracket_shape = children
            .first()
            .map(|child| node_text(*child, self.source) != "[")
            .unwrap_or(false)
            && children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "[")
            && children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "]")
            && named.len() >= 2;
        if direct_bracket_shape {
            return true;
        }

        if named.len() != 1 || named[0].kind() != "element_reference" {
            return false;
        }
        let reference = named[0];
        let reference_named = self.raw_named_children(reference);
        if reference_named.len() < 2
            || reference_named
                .iter()
                .any(|child| matches!(child.kind(), "block" | "do_block"))
        {
            return false;
        }
        let reference_children = reference
            .children(&mut reference.walk())
            .collect::<Vec<_>>();
        reference_children
            .first()
            .map(|child| node_text(*child, self.source) != "[")
            .unwrap_or(false)
            && reference_children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "[")
            && reference_children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "]")
    }

    fn dotted_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.dotted_expression_wrapper(node) && self.dotted_call(node)
    }

    fn argument_list_call_with_block(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "argument_list" || self.dotted_call(node) {
            return false;
        }

        let target = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);

        self.call_block(target).is_some()
            && self
                .named_children(target)
                .into_iter()
                .next()
                .map(|child| self.identifier_text(child).is_some())
                .unwrap_or(false)
    }

    fn dotted_call(&self, node: TreeSitterNode<'_>) -> bool {
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.dotted_call(raw_named[0])
        {
            return true;
        }

        if !node
            .children(&mut node.walk())
            .any(|child| self.member_access_operator(node_text(child, self.source)))
        {
            return false;
        }
        let callable = self
            .named_children(node)
            .into_iter()
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "block" | "do_block" | "argument_list" | "arguments"
                )
            })
            .collect::<Vec<_>>();
        if callable
            .iter()
            .any(|child| matches!(child.kind(), "string_content" | "interpolation"))
        {
            return false;
        }
        callable.len() >= 2
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .safe_navigation_call(node, self.source)
    }

    fn dotted_call_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        block: Option<TreeSitterNode<'tree>>,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.dotted_call(raw_named[0])
        {
            return self.dotted_call_parts(raw_named[0], block);
        }

        let callable = self
            .named_children(node)
            .into_iter()
            .filter(|child| Some(*child) != block)
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "block" | "do_block" | "argument_list" | "arguments"
                )
            })
            .collect::<Vec<_>>();
        let receiver = *callable.first()?;
        let method = node_text(*callable.get(1)?, self.source)
            .trim_start_matches("::")
            .trim_start_matches("->")
            .trim_start_matches(['.', '?'])
            .trim_end_matches('=')
            .to_string();
        Some((receiver, method))
    }

    fn member_read_node(&self, node: TreeSitterNode<'_>) -> bool {
        if self.normalization_adapter.member_read_excluded(node) {
            return false;
        }
        matches!(
            node.kind(),
            "call"
                | "attribute"
                | "member_expression"
                | "member_access_expression"
                | "field"
                | "field_access"
                | "selector_expression"
                | "field_expression"
                | "navigation_expression"
                | "directly_assignable_expression"
                | "expression_list"
        ) && self.member_parts(node).is_some()
    }

    fn member_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
        if node.kind() == "expression_list"
            && !(self.named_field(node, "operand").is_some()
                && self.named_field(node, "field").is_some())
        {
            return None;
        }
        if self.dotted_call(node) {
            return self.dotted_call_parts(node, None);
        }
        let named_children = self.named_children(node);
        let receiver = self
            .named_field(node, "receiver")
            .or_else(|| self.named_field(node, "object"))
            .or_else(|| self.named_field(node, "operand"))
            .or_else(|| self.named_field(node, "value"))
            .or_else(|| self.named_field(node, "expression"))
            .or_else(|| {
                named_children
                    .iter()
                    .copied()
                    .find(|child| child.kind() != "navigation_suffix")
            })?;
        let method = self
            .named_field(node, "method")
            .or_else(|| self.named_field(node, "field"))
            .or_else(|| self.named_field(node, "property"))
            .or_else(|| self.named_field(node, "suffix"))
            .or_else(|| {
                named_children
                    .iter()
                    .copied()
                    .find(|child| child.kind() == "navigation_suffix")
            })
            .or_else(|| {
                named_children.iter().copied().rev().find(|child| {
                    !matches!(
                        child.kind(),
                        "block" | "do_block" | "argument_list" | "arguments"
                    )
                })
            })?;
        (receiver != method).then(|| {
            (
                receiver,
                self.member_name(method).trim_end_matches('=').to_string(),
            )
        })
    }

    fn member_name(&self, node: TreeSitterNode<'_>) -> String {
        if node.kind() == "navigation_suffix" {
            let named_children = self.named_children(node);
            let suffix = self
                .named_field(node, "suffix")
                .or_else(|| {
                    named_children
                        .iter()
                        .copied()
                        .find(|child| self.identifier_kind(child.kind()))
                })
                .or_else(|| named_children.last().copied());
            return suffix
                .map(|suffix| {
                    node_text(suffix, self.source)
                        .trim_start_matches("::")
                        .trim_start_matches("->")
                        .trim_start_matches(['.', '?'])
                        .to_string()
                })
                .unwrap_or_default();
        }

        node_text(node, self.source)
            .trim_start_matches("::")
            .trim_start_matches("->")
            .trim_start_matches(['.', '?'])
            .to_string()
    }

    fn call_arguments(
        &mut self,
        node: TreeSitterNode<'_>,
        function: Option<TreeSitterNode<'_>>,
    ) -> Vec<Node> {
        let Some(args) = self
            .named_field(node, "arguments")
            .or_else(|| self.named_field(node, "argument"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| matches!(child.kind(), "argument_list" | "arguments"))
            })
        else {
            return Vec::new();
        };
        let children = self
            .named_children(args)
            .into_iter()
            .filter(|child| Some(*child) != function)
            .collect::<Vec<_>>();
        if self.dotted_expression(args) {
            return self.normalize_dotted_expression(args).into_iter().collect();
        }
        let raw_args = self.raw_named_children(args);
        if raw_args.len() == 1 && self.dotted_call(raw_args[0]) {
            let source = self.wrap("SOURCE", Vec::new(), args);
            return self
                .normalize_dotted_call_expression_with_source(raw_args[0], Some(&source))
                .into_iter()
                .collect();
        }
        if children.len() == 1
            && children[0].kind() == "heredoc_beginning"
            && heredoc_marker_text(node_text(args, self.source).trim_start())
        {
            return self.literal_arguments_from_text(args);
        }
        if children.is_empty() {
            return self
                .scalar_argument_list_value(args)
                .into_iter()
                .chain(self.literal_arguments_from_text(args))
                .collect();
        }
        if self.infix_statement(args) {
            return self.normalize_infix_statement(args).into_iter().collect();
        }

        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    fn literal_arguments_from_text(&mut self, args: TreeSitterNode<'_>) -> Vec<Node> {
        let text = node_text(args, self.source);
        if text.trim_start().starts_with("<<") && heredoc_marker_text(text.trim_start()) {
            return vec![self.normalize_heredoc_beginning(args)];
        }

        literal_symbol_arguments(text)
            .into_iter()
            .map(|name| self.wrap("LIT", vec![Child::Symbol(name)], args))
            .collect()
    }

    fn command_arguments(&mut self, args: TreeSitterNode<'_>) -> Vec<Node> {
        let children = self.named_children(args);
        if children.is_empty() {
            return self.scalar_argument_list_value(args).into_iter().collect();
        }
        if self.infix_statement(args) {
            return self.normalize_infix_statement(args).into_iter().collect();
        }
        if self.dotted_expression(args) {
            return self.normalize_dotted_expression(args).into_iter().collect();
        }
        if children.len() == 1
            && self.call_node(children[0])
            && self.call_block(children[0]).is_some()
        {
            return self
                .normalize_call_with_block(children[0])
                .into_iter()
                .collect();
        }
        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    fn yield_argument_nodes(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        let children = self.named_children(node);
        if children.is_empty() {
            return self.scalar_argument_list_value(node).into_iter().collect();
        }
        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    fn yield_inline_arguments(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        self.named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "yield")
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    fn scalar_argument_list_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let text = node_text(node, self.source).trim();
        if self.ruby() && text == "yield" {
            return Some(self.wrap("YIELD", vec![Child::Nil], node));
        }
        if text == "nil" {
            return Some(self.wrap("NIL", Vec::new(), node));
        }
        if text == "true" {
            return Some(self.wrap("TRUE", Vec::new(), node));
        }
        if text == "false" {
            return Some(self.wrap("FALSE", Vec::new(), node));
        }
        if let Some(symbol) = text.strip_prefix(':') {
            if bare_identifier_text(symbol) {
                return Some(self.wrap("LIT", vec![Child::Symbol(symbol.to_string())], node));
            }
        }
        if let Ok(value) = text.parse::<i64>() {
            return Some(self.wrap("INTEGER", vec![Child::Integer(value)], node));
        }
        if bare_identifier_text(text) {
            if self.ruby() && !self.ruby_local_name(text) {
                Some(self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node))
            } else {
                Some(self.wrap("LVAR", vec![Child::String(text.to_string())], node))
            }
        } else {
            None
        }
    }

    fn local_or_call_for_name(&self, name: &str, source: TreeSitterNode<'_>) -> Node {
        if self.ruby() && !self.ruby_local_name(name) {
            self.wrap("VCALL", vec![Child::Symbol(name.to_string())], source)
        } else {
            self.wrap("LVAR", vec![Child::String(name.to_string())], source)
        }
    }

    fn symbol_literal_node(&self, node: Option<&Node>) -> bool {
        matches!(
            node,
            Some(node)
                if node.r#type == "LIT" && matches!(node.children.first(), Some(Child::Symbol(_)))
        )
    }

    fn same_ts_node(&self, left: TreeSitterNode<'_>, right: TreeSitterNode<'_>) -> bool {
        left.kind() == right.kind()
            && left.start_byte() == right.start_byte()
            && left.end_byte() == right.end_byte()
    }

    fn parent_named_child(&self, parent: TreeSitterNode<'_>, node: TreeSitterNode<'_>) -> bool {
        self.named_children(parent)
            .into_iter()
            .any(|child| self.same_ts_node(child, node))
    }

    #[cfg(test)]
    fn node_key(&self, node: TreeSitterNode<'_>) -> (String, usize, usize) {
        (node.kind().to_string(), node.start_byte(), node.end_byte())
    }

    fn hidden_match(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "expression_statement"
            && node_text(node, self.source)
                .trim_start()
                .starts_with("match ")
            && self
                .named_children(node)
                .into_iter()
                .any(|child| child.kind() == "match_block")
    }

    fn assignment_left<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "left")
            .or_else(|| self.named_children(node).into_iter().next())
    }

    fn assignment_right<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "right")
            .or_else(|| self.named_children(node).into_iter().nth(1))
    }

    fn operator_assignment_operator(&self, node: TreeSitterNode<'_>) -> String {
        let mut cursor = node.walk();
        let raw = node.children(&mut cursor).find_map(|child| {
            let text = node_text(child, self.source);
            (!child.is_named() && self.assignment_operator(text)).then_some(text)
        });
        if let Some(raw) = raw {
            return match raw {
                "||=" => "||".to_string(),
                "&&=" => "&&".to_string(),
                _ => raw.trim_end_matches('=').to_string(),
            };
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source)
                .trim_end_matches(';')
                .trim_end()
                == node_text(raw_named[0], self.source)
        {
            return self.operator_assignment_operator(raw_named[0]);
        }

        String::new()
    }

    fn parameters_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "parameters").or_else(|| {
            self.named_children(node).into_iter().find(|child| {
                matches!(
                    child.kind(),
                    "parameters"
                        | "parameter_list"
                        | "formal_parameters"
                        | "function_value_parameters"
                        | "method_parameters"
                )
            })
        })
    }

    fn inline_parameter_begin_marker(&self, function_node: TreeSitterNode<'_>) -> Option<Node> {
        if !self.ruby() {
            return None;
        }

        let params = self.named_field(function_node, "parameters").or_else(|| {
            self.named_children(function_node)
                .into_iter()
                .find(|child| child.kind() == "method_parameters")
        })?;
        let semicolon = params.next_sibling()?;
        if semicolon.is_named() || node_text(semicolon, self.source) != ";" {
            return None;
        }

        let point = semicolon.start_position();
        Some(Node {
            r#type: "BEGIN".to_string(),
            children: vec![Child::Nil],
            first_lineno: point.row + 1,
            first_column: point.column,
            last_lineno: point.row + 1,
            last_column: point.column,
            text: String::new(),
        })
    }

    fn prepend_inline_parameter_begin(
        &self,
        function_node: TreeSitterNode<'_>,
        body: Option<Node>,
    ) -> Option<Node> {
        let Some(marker) = self.inline_parameter_begin_marker(function_node) else {
            return body;
        };

        let mut body = body?;
        if body.r#type == "BLOCK" {
            let mut children = body
                .children
                .into_iter()
                .filter(|child| !matches!(child, Child::Nil))
                .collect::<Vec<_>>();
            if children.is_empty() {
                return None;
            }

            body.children = vec![Child::Node(Box::new(marker))];
            body.children.append(&mut children);
            return Some(body);
        }

        Some(self.wrap(
            "BLOCK",
            vec![Child::Node(Box::new(marker)), Child::Node(Box::new(body))],
            function_node,
        ))
    }

    fn assignment_target(
        &mut self,
        left: TreeSitterNode<'_>,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if let Some(field) = self
            .normalization_adapter
            .state_field_name(left, self.source)
        {
            return Some(self.wrap(
                "IASGN",
                vec![Child::String(field), optional_node(right)],
                source,
            ));
        }
        if self.instance_variable(left) {
            return Some(self.wrap(
                "IASGN",
                vec![
                    Child::String(node_text(left, self.source).to_string()),
                    optional_node(right),
                ],
                source,
            ));
        }
        if self.global_variable(left) {
            return Some(self.wrap(
                "GASGN",
                vec![
                    Child::String(node_text(left, self.source).to_string()),
                    optional_node(right),
                ],
                source,
            ));
        }
        if left.kind() == "element_reference" {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let mut args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            if let Some(right) = right {
                args.push(right);
            }
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(args, left, self);
            return Some(self.wrap(
                "ATTRASGN",
                vec![receiver, Child::Symbol("[]=".to_string()), args],
                source,
            ));
        }
        if self.member_read_node(left)
            || self
                .normalization_adapter
                .member_assignment_target(left, self.source)
        {
            let (receiver, method) = self.member_parts(left)?;
            let writer = if node_text(left, self.source).contains("&.") {
                method
            } else {
                format!("{method}=")
            };
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(right.into_iter().collect(), left, self);
            return Some(self.wrap(
                "ATTRASGN",
                vec![receiver, Child::Symbol(writer), args],
                source,
            ));
        }
        if left.kind() == "expression_list" {
            return self
                .named_children(left)
                .into_iter()
                .next()
                .and_then(|child| self.assignment_target(child, right, source));
        }
        None
    }

    fn normalize_assignment_lhs(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let right = node
            .next_named_sibling()
            .and_then(|sibling| self.normalize_node(sibling));
        let source = node.parent().unwrap_or(node);
        self.assignment_target(node, right.clone(), source)
            .or_else(|| {
                Some(self.wrap(
                    "LASGN",
                    vec![Child::String(self.target_name(node)), optional_node(right)],
                    source,
                ))
            })
    }

    fn target_name(&self, node: TreeSitterNode<'_>) -> String {
        let text = node_text(node, self.source);
        if let Some(name) = self.identifier_text(node) {
            name
        } else if matches!(node.kind(), "splat" | "splat_parameter" | "rest_assignment") {
            text.trim_start_matches('*').to_string()
        } else {
            text.to_string()
        }
    }

    fn function_name(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if node.kind() == "singleton_method" {
            return Some(self.singleton_name(node));
        }

        Some(
            self.named_field(node, "name")
                .or_else(|| {
                    self.named_children(node).into_iter().find(|child| {
                        self.identifier_text(*child).is_some() || child.kind() == "constant"
                    })
                })
                .map(|name| {
                    self.identifier_text(name)
                        .unwrap_or_else(|| node_text(name, self.source).to_string())
                })
                .unwrap_or_default(),
        )
    }

    fn singleton_receiver<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(receiver) = self.named_field(node, "receiver") {
            return Some(receiver);
        }

        let children = self.named_children(node);
        let name = self.named_field(node, "name").or_else(|| {
            children
                .iter()
                .rev()
                .copied()
                .find(|child| self.identifier_text(*child).is_some())
        });
        let parameters = self.named_field(node, "parameters");
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node));

        children.into_iter().find(|child| {
            !name
                .map(|name| self.same_ts_node(*child, name))
                .unwrap_or(false)
                && !parameters
                    .map(|parameters| self.same_ts_node(*child, parameters))
                    .unwrap_or(false)
                && !body
                    .map(|body| self.same_ts_node(*child, body))
                    .unwrap_or(false)
        })
    }

    fn singleton_name(&self, node: TreeSitterNode<'_>) -> String {
        self.named_field(node, "name")
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .rev()
                    .find(|child| self.identifier_text(*child).is_some())
            })
            .map(|name| node_text(name, self.source).to_string())
            .unwrap_or_default()
    }

    fn block_child<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().find(|child| {
            matches!(
                child.kind(),
                "body_statement"
                    | "block_body"
                    | "block"
                    | "do_block"
                    | "class_body"
                    | "function_body"
                    | "match_block"
                    | "statement_block"
                    | "statement_list"
                    | "statements"
                    | "switch_body"
                    | "then"
                    | "control_structure_body"
            )
        })
    }

    fn call_block<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        if let Some(target) = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
        {
            return self.call_block(target);
        }

        self.named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "block" | "do_block"))
    }

    fn named_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.named_field(node, name)
    }

    fn parent_node<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.parent()
    }

    #[cfg(test)]
    fn next_sibling<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.next_sibling()
    }

    #[cfg(test)]
    fn prev_sibling<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.prev_sibling()
    }

    #[cfg(test)]
    fn next_named_sibling<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        node.next_named_sibling()
    }

    fn named_children<'tree>(&self, node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
        if node.kind() == "dotted_name" && !node_text(node, self.source).contains('.') {
            return Vec::new();
        }

        let children = self.raw_named_children(node);
        match self
            .normalization_adapter
            .named_children_action(node, self.source, &children)
        {
            NamedChildrenAction::Default => {}
            NamedChildrenAction::Drop => return Vec::new(),
            NamedChildrenAction::Recurse(child) => return self.named_children(child),
            NamedChildrenAction::Replace(children) => return children,
        }

        if node.kind() == "type" && children.len() == 1 {
            if children[0].kind() == "union_type" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "generic_type" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "attribute" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "string" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "list" {
                if self.raw_named_children(children[0]).is_empty() {
                    return Vec::new();
                }
                return self.named_children(children[0]);
            }
            if matches!(
                children[0].kind(),
                "ellipsis" | "identifier" | "nil" | "none" | "null"
            ) {
                return Vec::new();
            }
        }
        if node.kind() == "expression_statement"
            && children.len() == 1
            && matches!(children[0].kind(), "assignment" | "augmented_assignment")
        {
            return self.named_children(children[0]);
        }

        children
    }

    fn raw_named_children<'tree>(&self, node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
        node.children(&mut node.walk())
            .filter(|child| child.is_named())
            .collect()
    }

    fn no_paren_string_argument_content<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .no_paren_string_argument_content(node, self.source)
    }

    fn source_before_child(&self, node: TreeSitterNode<'_>, child: TreeSitterNode<'_>) -> Node {
        let text = self
            .source
            .get(node.start_byte()..child.start_byte())
            .unwrap_or("")
            .trim_end()
            .to_string();
        if text.is_empty() {
            return self.wrap("SOURCE", Vec::new(), node);
        }

        let lines = text.lines().collect::<Vec<_>>();
        let first_span = span(node);
        let last_lineno = first_span[0] + lines.len() - 1;
        let last_column = if lines.len() <= 1 {
            first_span[1] + text.len()
        } else {
            lines.last().map(|line| line.len()).unwrap_or(0)
        };
        Node {
            r#type: "SOURCE".to_string(),
            children: Vec::new(),
            first_lineno: first_span[0],
            first_column: first_span[1],
            last_lineno,
            last_column,
            text: self.source_text(&text),
        }
    }

    fn source_from_nodes(
        &self,
        first_node: TreeSitterNode<'_>,
        last_node: TreeSitterNode<'_>,
    ) -> Node {
        self.wrap_from_nodes("SOURCE", Vec::new(), first_node, last_node)
    }

    fn parenthesized_source(&self, node: TreeSitterNode<'_>) -> Option<Node> {
        let mut open = None;
        let mut close = None;
        for child in node.children(&mut node.walk()) {
            if child.is_named() {
                continue;
            }
            match node_text(child, self.source) {
                "(" if open.is_none() => open = Some(child),
                ")" => close = Some(child),
                _ => {}
            }
        }
        Some(self.source_from_nodes(open?, close?))
    }

    fn source_from_normalized_nodes(&self, first_node: &Node, last_node: &Node) -> Node {
        let lines = self.source.split_inclusive('\n').collect::<Vec<_>>();
        let text = if first_node.first_lineno == last_node.last_lineno {
            lines
                .get(first_node.first_lineno.saturating_sub(1))
                .and_then(|line| line.get(first_node.first_column..last_node.last_column))
                .unwrap_or("")
                .to_string()
        } else {
            let mut text = String::new();
            if let Some(line) = lines.get(first_node.first_lineno.saturating_sub(1)) {
                text.push_str(line.get(first_node.first_column..).unwrap_or(""));
            }
            for index in first_node.first_lineno..last_node.last_lineno.saturating_sub(1) {
                if let Some(line) = lines.get(index) {
                    text.push_str(line);
                }
            }
            if let Some(line) = lines.get(last_node.last_lineno.saturating_sub(1)) {
                text.push_str(line.get(..last_node.last_column).unwrap_or(""));
            }
            text
        };

        Node {
            r#type: "SOURCE".to_string(),
            children: Vec::new(),
            first_lineno: first_node.first_lineno,
            first_column: first_node.first_column,
            last_lineno: last_node.last_lineno,
            last_column: last_node.last_column,
            text: self.source_text(&text),
        }
    }

    fn first_named<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().next()
    }

    fn branch_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        condition: TreeSitterNode<'tree>,
        offset: usize,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node)
            .into_iter()
            .filter(|child| {
                *child != condition && !matches!(child.kind(), "comment" | "else" | "elsif")
            })
            .nth(offset)
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.explicit_alternative(node)
    }

    fn case_value<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "value")
            .or_else(|| self.named_field(node, "subject"))
            .or_else(|| self.named_field(node, "condition"))
            .or_else(|| {
                self.named_children(node).into_iter().find(|child| {
                    !self.when_kind(child.kind())
                        && !self.block_kind(child.kind())
                        && child.kind() != "else"
                })
            })
    }

    fn case_arms<'tree>(&self, node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
        let mut arms = Vec::new();
        let mut stack = self.named_children(node);
        while !stack.is_empty() {
            let child = stack.remove(0);
            if self.normalization_adapter.case_arm(child, self.source) {
                arms.push(child);
            } else if self
                .normalization_adapter
                .case_else_node_kind(child, self.source)
            {
                continue;
            } else if !function_kind(child.kind()) {
                stack.extend(self.named_children(child));
            }
        }
        arms
    }

    fn when_body<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "body")
            .or_else(|| self.named_field(node, "consequence"))
            .or_else(|| self.named_field(node, "value"))
            .or_else(|| {
                self.named_children(node).into_iter().rev().find(|child| {
                    self.block_kind(child.kind()) || self.statement_node(child.kind())
                })
            })
    }

    fn identifier_kind(&self, kind: &str) -> bool {
        identifier_kind_name(kind)
    }

    fn identifier_text(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if self.identifier_kind(node.kind()) {
            return Some(
                node_text(node, self.source)
                    .trim_start_matches('*')
                    .to_string(),
            );
        }
        self.normalization_adapter
            .local_identifier_text(node, self.source)
    }

    fn self_identifier(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .self_identifier(node, self.source)
    }

    fn call_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.call_kind(node.kind()) || self.normalization_adapter.call_node(node, self.source)
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        self.normalization_adapter
            .loop_node_type(kind)
            .or_else(|| loop_kind(kind))
    }

    fn member_access_operator(&self, text: &str) -> bool {
        self.normalization_adapter.member_access_operator(text)
    }

    fn source_text(&self, text: &str) -> String {
        self.normalization_adapter.source_text(text)
    }

    fn const_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
        )
    }

    fn call_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "call" | "call_expression" | "method_call" | "method_call_expression"
        )
    }

    fn block_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.block_node_kind(kind)
            || matches!(
                kind,
                "block"
                    | "body_statement"
                    | "statement_block"
                    | "statement_list"
                    | "class_body"
                    | "switch_body"
                    | "match_block"
                    | "then"
                    | "block_body"
                    | "control_structure_body"
                    | "function_body"
                    | "statements"
            )
    }

    fn case_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "case"
                | "switch_statement"
                | "expression_switch_statement"
                | "switch_expression"
                | "match_statement"
                | "match_expression"
                | "when_expression"
        )
    }

    fn when_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "when"
                | "switch_case"
                | "case_clause"
                | "expression_case"
                | "case_statement"
                | "switch_section"
                | "switch_block_statement_group"
                | "switch_entry"
                | "when_entry"
                | "match_arm"
        )
    }

    fn statement_node(&self, kind: &str) -> bool {
        kind.ends_with("_statement")
            || kind.ends_with("_expression")
            || matches!(kind, "return" | "break" | "next")
    }

    fn unwrap_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .unwrap_node(node, self.source, self.named_children(node).len())
    }

    fn single_dotted_else_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let children = self
            .named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if children.len() != 1 {
            return None;
        }
        self.single_dotted_body_node(children[0])
    }

    fn single_dotted_body_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if if_kind(node.kind())
            || loop_kind(node.kind()).is_some()
            || matches!(
                node.kind(),
                "if_modifier" | "unless_modifier" | "while_modifier" | "until_modifier"
            )
        {
            return None;
        }
        if self.call_node(node) && self.dotted_call(node) {
            return Some(node);
        }

        let children = self
            .named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if children.len() == 1 && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.single_dotted_body_node(children[0]);
        }
        None
    }

    fn elide_tail_returns(&self, node: Option<Node>) -> Option<Node> {
        if !self.normalization_adapter.elides_tail_returns() {
            return node;
        }
        let mut node = node?;
        if matches!(
            node.r#type.as_str(),
            "DEFN" | "DEFS" | "CLASS" | "MODULE" | "SCLASS" | "LAMBDA" | "ITER"
        ) {
            return Some(node);
        }
        if node.r#type == "RETURN" {
            return node.children.into_iter().next().and_then(child_node);
        }

        match node.r#type.as_str() {
            "BLOCK" => {
                if let Some(last) = node.children.pop() {
                    match child_node(last) {
                        Some(last_node) => {
                            if let Some(elided) = self.elide_tail_returns(Some(last_node)) {
                                node.children.push(Child::Node(Box::new(elided)));
                            } else {
                                node.children.push(Child::Nil);
                            }
                        }
                        None => node.children.push(Child::Nil),
                    }
                }
            }
            "SCOPE" => {
                if node.children.len() > 2 {
                    let child = std::mem::replace(&mut node.children[2], Child::Nil);
                    if let Some(elided) =
                        child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                    {
                        node.children[2] = Child::Node(Box::new(elided));
                    }
                }
            }
            "IF" | "UNLESS" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "CASE" | "CASE2" => {
                let index = if node.r#type == "CASE" { 1 } else { 0 };
                if node.children.len() > index {
                    let child = std::mem::replace(&mut node.children[index], Child::Nil);
                    if let Some(elided) =
                        child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                    {
                        node.children[index] = Child::Node(Box::new(elided));
                    }
                }
            }
            "WHEN" | "RESBODY" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "RESCUE" => {
                for index in [0usize, 1usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            _ => {}
        }

        Some(node)
    }

    fn elide_implicit_nil_body(&self, node: Option<Node>) -> Option<Node> {
        if !self.normalization_adapter.elides_implicit_nil_body() {
            return node;
        }
        let node = self.drop_trailing_nil_statement(node);
        match node {
            Some(node) if node.r#type == "NIL" => None,
            other => other,
        }
    }

    fn drop_trailing_nil_statement(&self, node: Option<Node>) -> Option<Node> {
        let mut node = node?;
        if node.r#type != "BLOCK" {
            return Some(node);
        }
        node.children.retain(|child| !matches!(child, Child::Nil));
        while node
            .children
            .last()
            .and_then(self::node)
            .map(|child| child.r#type == "NIL")
            .unwrap_or(false)
        {
            node.children.pop();
        }
        if node.children.is_empty() {
            None
        } else if node.children.len() == 1 {
            child_node(node.children.into_iter().next().unwrap())
        } else {
            Some(node)
        }
    }
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

fn ruby_constant_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_uppercase() && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
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

fn if_kind(kind: &str) -> bool {
    matches!(
        kind,
        "if" | "if_statement"
            | "if_modifier"
            | "unless"
            | "unless_modifier"
            | "if_expression"
            | "conditional"
    )
}

fn loop_kind(kind: &str) -> Option<&'static str> {
    match kind {
        "while" | "while_statement" | "while_modifier" => Some("WHILE"),
        "until_modifier" => Some("UNTIL"),
        "for" | "for_statement" | "for_in_clause" => Some("FOR"),
        _ => None,
    }
}

fn function_kind(kind: &str) -> bool {
    matches!(
        kind,
        "method"
            | "function_definition"
            | "function_declaration"
            | "method_definition"
            | "method_declaration"
            | "function_item"
            | "singleton_method"
    )
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

fn inline_def_wrapper_mid(text: &str) -> bool {
    matches!(
        text,
        "public" | "protected" | "private" | "private_class_method" | "module_function"
    )
}

fn inline_def_receiver_text(text: &str) -> bool {
    let mut tokens = text.split_whitespace();
    while let Some(token) = tokens.next() {
        if token != "def" {
            continue;
        }
        let Some(name) = tokens.next() else {
            return false;
        };
        let Some((receiver, _method)) = name.split_once('.') else {
            return false;
        };
        return !receiver.is_empty();
    }
    false
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

fn ruby_instance_variable_text(text: &str) -> bool {
    text.strip_prefix('@')
        .map(exact_bare_identifier_text)
        .unwrap_or(false)
}

fn exact_integer_text(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.chars().all(|ch| ch.is_ascii_digit())
}

fn heredoc_marker_text(text: &str) -> bool {
    text.split(|ch: char| ch.is_whitespace() || matches!(ch, '(' | ','))
        .any(|token| {
            let Some(marker) = token.strip_prefix("<<") else {
                return false;
            };
            let marker = marker
                .strip_prefix('-')
                .or_else(|| marker.strip_prefix('~'))
                .unwrap_or(marker);
            let mut chars = marker.chars();
            let Some(first) = chars.next() else {
                return false;
            };
            first == '_' || first.is_ascii_alphabetic()
        })
}

fn ruby_variable_name_text(text: &str) -> bool {
    let mut chars = text.chars().peekable();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    while let Some(ch) = chars.next() {
        if matches!(ch, '!' | '?' | '=') {
            return chars.peek().is_none();
        }
        if !(ch == '_' || ch.is_ascii_alphanumeric()) {
            return false;
        }
    }
    true
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
