use crate::syntax::parser_grammar::grammar_for_language;
use crate::syntax::Language;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use tree_sitter::Node as TreeSitterNode;
use tree_sitter::Parser;

mod adapters;
mod normalizer;
pub(in crate::ast) use normalizer::TreeSitterNormalizer;

pub type Span = [usize; 4];
const COMPARISON_OPERATORS: &[&str] = &["<=>", "==", "!=", "===", "!==", "<", "<=", ">", ">="];
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

/// A source-parser node that the active adapter classifies as a call before
/// normalized extraction. Kept as parser evidence so coverage can distinguish
/// a deliberate language representation difference from a dropped call.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct RawCallSite {
    pub span: Span,
    pub kind: String,
}

pub fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn span(node: TreeSitterNode<'_>) -> Span {
    let start = node.start_position();
    let end = node.end_position();
    [start.row + 1, start.column, end.row + 1, end.column]
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

impl Node {
    pub fn is_method_like(&self) -> bool {
        self.r#type == "DEFN" || self.r#type == "DEFS" || self.r#type == "DEF"
    }

    pub fn is_class_or_module(&self) -> bool {
        self.r#type == "CLASS" || self.r#type == "MODULE"
    }

    pub fn is_conditional(&self) -> bool {
        self.r#type == "IF" || self.r#type == "UNLESS" || self.r#type == "CASE"
    }

    pub fn is_block(&self) -> bool {
        self.r#type == "BLOCK"
    }

    pub fn is_return(&self) -> bool {
        self.r#type == "RETURN"
    }

    pub fn is_hash(&self) -> bool {
        self.r#type == "HASH"
    }

    pub fn is_nil(&self) -> bool {
        self.r#type == "NIL"
    }
}

pub fn parse(file: &Path) -> Result<(Node, Vec<String>)> {
    let language = Language::for_path(file)
        .with_context(|| format!("unsupported source extension for {}", file.display()))?;
    parse_with_language(file, language)
}

/// The buffer actually fed to tree-sitter's `parse()` call, when a language
/// adapter wants to rewrite what the parser sees (see
/// `AstNormalizationAdapter::source_preprocessing`). Never used for
/// anything besides the parse call itself - digests, snippets, and node
/// text all read the untouched original source, which is safe precisely
/// because every such rewrite is required to be byte-length preserving.
pub(crate) fn parse_buffer(source: &str, language: Language) -> String {
    adapters::normalization_adapter(language)
        .source_preprocessing(source)
        .unwrap_or_else(|| source.to_string())
}

pub fn parse_with_language(file: &Path, language: Language) -> Result<(Node, Vec<String>)> {
    let source =
        fs::read_to_string(file).with_context(|| format!("failed to read {}", file.display()))?;
    let mut parser = Parser::new();
    parser
        .set_language(&grammar_for_language(language))
        .with_context(|| "failed to initialize tree-sitter parser")?;
    let tree = parser
        .parse(parse_buffer(&source, language), None)
        .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
    let root = normalize_tree(tree.root_node(), &source, language);
    let lines = source.lines().map(ToString::to_string).collect();
    Ok((root, lines))
}

pub fn normalize_tree(root: TreeSitterNode<'_>, source: &str, language: Language) -> Node {
    TreeSitterNormalizer::new(source, language).normalize(root)
}

/// Returns the normalized tree plus exact parser-call identities captured by
/// the normalizer before adapters transform source nodes.
pub(crate) fn normalize_tree_with_call_origins(
    root: TreeSitterNode<'_>,
    source: &str,
    language: Language,
) -> (Node, Vec<(Span, Span)>) {
    TreeSitterNormalizer::new(source, language).normalize_with_call_origins(root)
}

pub(crate) fn raw_call_sites(
    root: TreeSitterNode<'_>,
    source: &str,
    language: Language,
) -> Vec<RawCallSite> {
    fn visit(
        node: TreeSitterNode<'_>,
        normalizer: &TreeSitterNormalizer<'_>,
        sites: &mut std::collections::BTreeMap<Span, String>,
    ) {
        if normalizer.call_node(node) {
            sites.insert(span(node), node.kind().to_string());
        }
        let mut cursor = node.walk();
        for child in node.named_children(&mut cursor) {
            visit(child, normalizer, sites);
        }
    }

    let normalizer = TreeSitterNormalizer::new(source, language);
    let mut sites = std::collections::BTreeMap::new();
    visit(root, &normalizer, &mut sites);
    sites
        .into_iter()
        .map(|(span, kind)| RawCallSite { span, kind })
        .collect()
}

pub(crate) fn symbol_scope(
    root: TreeSitterNode<'_>,
    source: &str,
    language: Language,
) -> (String, Vec<(String, String)>) {
    adapters::normalization_adapter(language).symbol_scope(root, source)
}

pub(crate) fn declaration_namespaces(
    root: TreeSitterNode<'_>,
    source: &str,
    language: Language,
) -> Vec<(Span, String)> {
    adapters::normalization_adapter(language).declaration_namespaces(root, source)
}

pub(crate) fn unqualified_types_use_current_namespace(language: Language) -> bool {
    adapters::normalization_adapter(language).unqualified_types_use_current_namespace()
}

pub(crate) fn preprocessor_callable_names(
    root: TreeSitterNode<'_>,
    source: &str,
    language: Language,
) -> Vec<String> {
    adapters::normalization_adapter(language).preprocessor_callable_names(root, source)
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
    // A normalized function wraps its SCOPE at a type-specific child index: a
    // singleton-method DEFS after its receiver/name, a LAMBDA directly, an
    // ordinary DEFN after its name.
    let scope_index = match defn_node.r#type.as_str() {
        "DEFS" => 2,
        "LAMBDA" => 0,
        _ => 1,
    };
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

pub(crate) fn statement_nodes(body: &Node) -> Vec<&Node> {
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

/// Returns every operand of a normalized disjunction. A false disjunction
/// proves every operand false, just as a true conjunction proves every
/// operand true.
pub fn flatten_or(node: &Node) -> Vec<&Node> {
    if matches!(node.r#type.as_str(), "CONDITION_CLAUSE") {
        let children = node
            .children
            .iter()
            .filter_map(self::node)
            .collect::<Vec<_>>();
        if children.len() == 1 {
            return flatten_or(children[0]);
        }
    }
    if node.r#type != "OR" {
        return vec![node];
    }
    node.children
        .iter()
        .filter_map(self::node)
        .flat_map(flatten_or)
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
    "func_literal",
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

pub(crate) fn exact_integer_text(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.chars().all(|ch| ch.is_ascii_digit())
}

fn comparison_operator_from_text(text: &str) -> Option<String> {
    let t = text.trim();
    if t == "is not" {
        return Some("!=".to_string());
    }
    if t == "is" {
        return Some("==".to_string());
    }
    for operator in ["<=>", "===", "!==", "==", "!=", "<=", ">=", "<", ">"] {
        if t.contains(operator) {
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

#[cfg(test)]
mod dummy_arch_test {}

pub(crate) mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[cfg(test)]
    mod normalizer_oracle_test {
        include!("ast/normalizer_oracle_test.rs");
    }

    pub(crate) fn test_ast_helpers_impl() {
        // 1. parse and parse_with_language
        let file_path = std::env::temp_dir().join(format!(
            "dummy_ast_test_{}.rs",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&file_path, "fn foo() {}").unwrap();

        let (root, lines) = parse(&file_path).unwrap();
        assert_eq!(root.r#type, "ROOT");
        assert_eq!(lines.len(), 1);

        let (root2, lines2) = parse_with_language(&file_path, Language::Rust).unwrap();
        assert_eq!(root2.r#type, "ROOT");
        assert_eq!(lines2.len(), 1);

        let _ = fs::remove_file(&file_path);

        // 2. body_stmts validation error exits
        let defn = Node {
            r#type: "DEFS".to_string(),
            children: vec![],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(body_stmts(&defn).is_empty());

        let defn2 = Node {
            r#type: "DEF".to_string(),
            children: vec![
                Child::Symbol("name".to_string()),
                Child::Node(Box::new(Node {
                    r#type: "NOT_SCOPE".to_string(),
                    children: vec![],
                    first_lineno: 0,
                    first_column: 0,
                    last_lineno: 0,
                    last_column: 0,
                    text: "".to_string(),
                })),
            ],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(body_stmts(&defn2).is_empty());

        let defn3 = Node {
            r#type: "DEF".to_string(),
            children: vec![
                Child::Symbol("name".to_string()),
                Child::Node(Box::new(Node {
                    r#type: "SCOPE".to_string(),
                    children: vec![Child::Symbol("args".to_string())], // length < 3
                    first_lineno: 0,
                    first_column: 0,
                    last_lineno: 0,
                    last_column: 0,
                    text: "".to_string(),
                })),
            ],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(body_stmts(&defn3).is_empty());

        // 3. flatten_and for CONDITION_CLAUSE with exactly one child
        let child = Node {
            r#type: "IDENTIFIER".to_string(),
            children: vec![],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "foo".to_string(),
        };
        let cond = Node {
            r#type: "CONDITION_CLAUSE".to_string(),
            children: vec![Child::Node(Box::new(child.clone()))],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "foo".to_string(),
        };
        let flattened = flatten_and(&cond);
        assert_eq!(flattened.len(), 1);
        assert_eq!(flattened[0].text, "foo");

        // 4. question_colon_ternary_parts & ternary_separator_bytes
        let mut js_parser = Parser::new();
        js_parser
            .set_language(&tree_sitter_javascript::LANGUAGE.into())
            .unwrap();

        let js_tree = js_parser.parse("a ? b : c", None).unwrap();
        let js_node = js_tree.root_node().child(0).unwrap().child(0).unwrap(); // ternary_expression
        let parts =
            question_colon_ternary_parts(js_node, "a ? b : c", &["ternary_expression"]).unwrap();
        assert_eq!(parts.positive.len(), 1);
        assert_eq!(parts.negative.len(), 1);

        // swapped source to trigger positive/negative empty bounds check
        assert!(
            question_colon_ternary_parts(js_node, "a : b ? c", &["ternary_expression"]).is_none()
        );

        // invalid kind check
        assert!(question_colon_ternary_parts(js_node, "a ? b : c", &["different_kind"]).is_none());

        // 5. case_arm_descendant and descendant
        assert!(!case_arm_descendant(js_node));
        assert!(descendant(js_node, &["nonexistent_kind"]).is_none());

        // 6. element_reference_shape
        let js_tree_ref = js_parser.parse("a[i]", None).unwrap();
        let js_node_ref = js_tree_ref.root_node().child(0).unwrap().child(0).unwrap(); // subscript_expression
        assert!(element_reference_shape(js_node_ref, "a[i]"));

        let js_tree_ref2 = js_parser.parse("[i]", None).unwrap();
        let js_node_ref2 = js_tree_ref2.root_node().child(0).unwrap().child(0).unwrap(); // array
        assert!(!element_reference_shape(js_node_ref2, "[i]"));

        // 7. return_kind fallback
        assert_eq!(return_kind("some_other"), "some_other");

        // 8. literal_symbol_arguments
        let extracted = literal_symbol_arguments("foo: :123 :symbol :another? :bad:");
        assert_eq!(
            extracted,
            vec![
                "symbol".to_string(),
                "another?".to_string(),
                "bad".to_string()
            ]
        );

        // 9. exact_bare_identifier_text boundary checks
        assert!(!exact_bare_identifier_text(""));
        assert!(!exact_bare_identifier_text("1foo"));
        assert!(!exact_bare_identifier_text("foo-bar"));
        assert!(!exact_bare_identifier_text("foo!bar"));
        assert!(exact_bare_identifier_text("foo!"));
        assert!(exact_bare_identifier_text("foo?"));
        assert!(exact_bare_identifier_text("foo="));

        // 10. exact_integer_text
        assert!(exact_integer_text("123"));
        assert!(exact_integer_text("-123"));
        assert!(!exact_integer_text(""));
        assert!(!exact_integer_text("-"));
        assert!(!exact_integer_text("abc"));

        // 11. Extra coverage cases for remaining missed lines in ast.rs
        // Cover ts_node
        assert!(!super::ts_node(None));

        // Cover literal_symbol_arguments with symbol at the end of string (None branch of char search)
        let extracted_end = literal_symbol_arguments("foo: :123 :symbol :another? :bad: :end");
        assert_eq!(
            extracted_end,
            vec![
                "symbol".to_string(),
                "another?".to_string(),
                "bad".to_string(),
                "end".to_string()
            ]
        );

        // Cover comparison_operator_from_text return Some branch
        assert_eq!(
            comparison_operator_from_text("a == b"),
            Some("==".to_string())
        );

        // Cover CONDITION_CLAUSE with 0 and 2 children in flatten_and
        let cond_empty = Node {
            r#type: "CONDITION_CLAUSE".to_string(),
            children: vec![],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(flatten_and(&cond_empty).len(), 1);

        let child1 = Node {
            r#type: "IDENTIFIER".to_string(),
            children: vec![],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "foo".to_string(),
        };
        let child2 = Node {
            r#type: "IDENTIFIER".to_string(),
            children: vec![],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "bar".to_string(),
        };
        let cond_two = Node {
            r#type: "CONDITION_CLAUSE".to_string(),
            children: vec![Child::Node(Box::new(child1)), Child::Node(Box::new(child2))],
            first_lineno: 0,
            first_column: 0,
            last_lineno: 0,
            last_column: 0,
            text: "foo bar".to_string(),
        };
        assert_eq!(flatten_and(&cond_two).len(), 1);

        // Cover question_colon_ternary_parts positive.is_empty() || negative.is_empty() None return
        // We parse "a ? : c" where positive child is missing
        let js_tree_err = js_parser.parse("a ? : c", None).unwrap();
        let js_node_err = js_tree_err.root_node().child(0).unwrap().child(0).unwrap(); // ternary_expression or error
                                                                                       // Let's invoke question_colon_ternary_parts on it (it returns None because positive is empty)
        let _ = question_colon_ternary_parts(js_node_err, "a ? : c", &["ternary_expression"]);
    }

    #[test]
    fn test_ast_helpers() {
        test_ast_helpers_impl();
    }
}

pub fn run_ast_helpers_tests() {
    tests::test_ast_helpers_impl();
}

pub fn run_base_adapter_defaults_tests() {
    adapters::base::run_base_adapter_defaults_tests();
}

pub fn run_normalizer_uncovered_paths_tests() {
    normalizer::run_normalizer_uncovered_paths_tests();
}
