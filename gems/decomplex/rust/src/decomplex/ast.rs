use crate::decomplex::syntax::Language;
use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use tree_sitter::{Language as TreeSitterLanguage, Node as TreeSitterNode, Parser};

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

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RawNode {
    pub kind: String,
    pub text: String,
    pub span: Span,
    pub named: bool,
    pub children: Vec<RawNode>,
}

impl RawNode {
    pub fn from_tree_sitter(node: TreeSitterNode<'_>, source: &str) -> Self {
        let mut cursor = node.walk();
        let mut children: Vec<RawNode> = node
            .children(&mut cursor)
            .map(|child| Self::from_tree_sitter(child, source))
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Child {
    Node(Box<Node>),
    Symbol(String),
    String(String),
    Integer(i64),
    Bool(bool),
    Nil,
}

#[derive(Clone, Debug, Eq, PartialEq)]
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
    let root = TreeSitterNormalizer::new(&source, language).normalize(tree.root_node());
    let lines = source.lines().map(ToString::to_string).collect();
    Ok((root, lines))
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
    if body.r#type == "BLOCK" {
        body.children.iter().filter_map(node).collect()
    } else {
        vec![body]
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TreeSitterNormalizationAdapter {
    Default,
    Ruby,
    Python,
    Lua,
    TypeScript,
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
const RUBY_LEADING_FUNCTION_TARGET_KINDS: &[&str] = &["method", "singleton_method"];
const PYTHON_LEADING_FUNCTION_TARGET_KINDS: &[&str] = &["function_definition"];
const LUA_LEADING_FUNCTION_TARGET_KINDS: &[&str] = &["function_declaration"];
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

struct TernaryParts<'tree> {
    condition: TreeSitterNode<'tree>,
    positive: Vec<TreeSitterNode<'tree>>,
    negative: Vec<TreeSitterNode<'tree>>,
}

impl TreeSitterNormalizationAdapter {
    fn for_language(language: Language) -> Self {
        match language {
            Language::Ruby => Self::Ruby,
            Language::Python => Self::Python,
            Language::Lua => Self::Lua,
            Language::TypeScript | Language::JavaScript => Self::TypeScript,
            _ => Self::Default,
        }
    }

    fn ruby(self) -> bool {
        self == Self::Ruby
    }

    fn yield_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let allowed = match self {
            Self::Python => matches!(
                node.kind(),
                "body_statement" | "block" | "block_body" | "expression_statement" | "statement"
            ),
            _ => matches!(
                node.kind(),
                "body_statement" | "block" | "block_body" | "statement"
            ),
        };
        if !allowed {
            return false;
        }
        let named_children = node
            .children(&mut node.walk())
            .filter(|child| child.is_named())
            .collect::<Vec<_>>();
        named_children.len() == 1
            && named_children[0].kind() == "yield"
            && node_text(named_children[0], source) == node_text(node, source)
    }

    fn super_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Ruby {
            return false;
        }
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "call" | "statement"
        ) {
            return false;
        }
        if node_text(node, source).trim() == "super" {
            return true;
        }
        let raw = raw_named_children(node);
        let named = if raw.len() == 1 && raw[0].kind() == "call" {
            raw_named_children(raw[0])
        } else {
            raw
        };
        named
            .first()
            .map(|child| child.kind() == "super")
            .unwrap_or(false)
            && named
                .iter()
                .skip(1)
                .all(|child| child.kind() == "argument_list")
    }

    fn safe_navigation_call(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let ruby_safe_navigation = node
            .children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, source) == "&.");
        if self != Self::TypeScript {
            return ruby_safe_navigation;
        }

        ruby_safe_navigation
            || node
                .children(&mut node.walk())
                .any(|child| child.kind() == "optional_chain" && node_text(child, source) == "?.")
            || (node.kind() == "call_expression"
                && named_children(node)
                    .into_iter()
                    .any(|child| self.safe_navigation_call(child, source)))
    }

    fn ternary_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.ternary_parts(node, source).is_some()
    }

    fn ternary_parts<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TernaryParts<'tree>> {
        match self {
            Self::Python => {
                if node.kind() != "conditional_expression" {
                    return None;
                }
                let named = named_children(node);
                Some(TernaryParts {
                    condition: *named.get(1)?,
                    positive: vec![*named.first()?],
                    negative: vec![*named.get(2)?],
                })
            }
            Self::Lua => None,
            Self::TypeScript => {
                question_colon_ternary_parts(node, source, TYPESCRIPT_TERNARY_KINDS)
            }
            Self::Default | Self::Ruby => {
                question_colon_ternary_parts(node, source, QUESTION_COLON_TERNARY_KINDS)
            }
        }
    }

    fn case_argument_list(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Ruby || node.kind() != "argument_list" {
            return false;
        }
        let raw_named = named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "case"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            raw_named[0]
        } else {
            node
        };
        let has_case_keyword = target
            .children(&mut target.walk())
            .any(|child| !child.is_named() && child.kind() == "case");
        has_case_keyword
            && named_children(target)
                .iter()
                .any(|child| CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()))
    }

    fn case_arm(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        CASE_ARGUMENT_WHEN_KINDS.contains(&node.kind()) && !self.case_else_arm(node, source)
    }

    fn case_else_node<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let mut stack = named_children(node);
        while !stack.is_empty() {
            let child = stack.remove(0);
            if self.case_else_node_kind(child, source) {
                return Some(child);
            }
            if CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()) {
                continue;
            }
            if !function_kind(child.kind()) {
                stack.extend(named_children(child));
            }
        }
        None
    }

    fn case_else_node_kind(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        CASE_ELSE_KINDS.contains(&node.kind()) || self.case_else_arm(node, source)
    }

    fn case_else_arm(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Python || node.kind() != "case_clause" {
            return false;
        }

        named_children(node)
            .into_iter()
            .find(|child| CASE_DEFAULT_PATTERN_KINDS.contains(&child.kind()))
            .map(|pattern| node_text(pattern, source).trim() == "_")
            .unwrap_or(false)
    }

    fn leading_function_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_function_target(node, source) else {
            return false;
        };
        let expected_keyword = match self {
            Self::Lua => "function",
            _ => "def",
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| child.kind() == expected_keyword)
            .unwrap_or(false)
            && named_children(target)
                .iter()
                .any(|child| identifier_kind_name(child.kind()))
    }

    fn leading_function_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let (wrapper_kinds, target_kinds) = match self {
            Self::Ruby | Self::Default => (
                LEADING_FUNCTION_WRAPPER_KINDS,
                RUBY_LEADING_FUNCTION_TARGET_KINDS,
            ),
            Self::Python => (
                PYTHON_LEADING_FUNCTION_WRAPPER_KINDS,
                PYTHON_LEADING_FUNCTION_TARGET_KINDS,
            ),
            Self::Lua => (
                LUA_LEADING_FUNCTION_WRAPPER_KINDS,
                LUA_LEADING_FUNCTION_TARGET_KINDS,
            ),
            Self::TypeScript => return None,
        };
        if !wrapper_kinds.contains(&node.kind()) {
            return None;
        }
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| matches!(child.kind(), "def" | "function"))
            .unwrap_or(false)
        {
            return Some(node);
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && target_kinds.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        None
    }

    fn leading_owner_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_owner_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "class" | "module"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
            && named_children(target)
                .first()
                .map(|child| !OWNER_STATEMENT_NESTED_KINDS.contains(&child.kind()))
                .unwrap_or(false)
    }

    fn leading_owner_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let wrapper_kinds = match self {
            Self::Python => PYTHON_LEADING_OWNER_WRAPPER_KINDS,
            Self::Ruby | Self::Default => LEADING_OWNER_WRAPPER_KINDS,
            Self::Lua | Self::TypeScript => LEADING_OWNER_WRAPPER_KINDS,
        };
        if !wrapper_kinds.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && OWNER_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_if_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_if_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "if" | "unless"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
            && named_children(target)
                .first()
                .map(|child| !IF_NODE_KINDS.contains(&child.kind()))
                .unwrap_or(false)
    }

    fn leading_if_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let wrapper_kinds = match self {
            Self::Python => PYTHON_LEADING_IF_WRAPPER_KINDS,
            Self::Lua => LUA_LEADING_IF_WRAPPER_KINDS,
            Self::Ruby | Self::TypeScript | Self::Default => LEADING_IF_WRAPPER_KINDS,
        };
        if !wrapper_kinds.contains(&node.kind()) {
            return None;
        }
        if matches!(self, Self::Python | Self::Lua) {
            let raw_named = named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "if_statement"
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && IF_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_case_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_case_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "case" | "match" | "switch"))
            .unwrap_or(false)
            && case_arm_descendant(target)
    }

    fn leading_case_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_CASE_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && CASE_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_loop_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_loop_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| !child.is_named() && matches!(child.kind(), "while" | "until"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
    }

    fn leading_loop_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_LOOP_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && LOOP_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn rescue_body_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        !self.rescue_clauses(node, source).is_empty()
    }

    fn rescue_body_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => {
                if node.kind() == "try_statement" {
                    return Some(node);
                }
                if node.kind() == "block" {
                    let raw_named = named_children(node);
                    if raw_named.len() == 1
                        && raw_named[0].kind() == "try_statement"
                        && node_text(raw_named[0], source) == node_text(node, source)
                    {
                        return Some(raw_named[0]);
                    }
                }
            }
            Self::TypeScript => {
                if node.kind() == "try_statement" {
                    return Some(node);
                }
                if node.kind() == "statement_block" {
                    let raw_named = named_children(node);
                    if raw_named.len() == 1
                        && raw_named[0].kind() == "try_statement"
                        && node_text(raw_named[0], source) == node_text(node, source)
                    {
                        return Some(raw_named[0]);
                    }
                }
            }
            _ => {}
        }

        if RESCUE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            Some(node)
        } else {
            None
        }
    }

    fn rescue_body_nodes<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.rescue_body_target(node, source) else {
            return Vec::new();
        };
        let named = named_children(target);
        match self {
            Self::Python => {
                if target.kind() == "try_statement" {
                    return named
                        .into_iter()
                        .take_while(|child| {
                            !matches!(child.kind(), "except_clause" | "finally_clause")
                        })
                        .collect();
                }
            }
            Self::TypeScript => {
                if target.kind() == "try_statement" {
                    return named
                        .into_iter()
                        .take_while(|child| {
                            !matches!(child.kind(), "catch_clause" | "finally_clause")
                        })
                        .collect();
                }
            }
            _ => {}
        }

        let Some(index) = named.iter().position(|child| self.rescue_clause(*child)) else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn rescue_clauses<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.rescue_body_target(node, source) else {
            return Vec::new();
        };
        let clause_kind = match self {
            Self::Python => "except_clause",
            Self::TypeScript => "catch_clause",
            _ => "rescue",
        };
        named_children(target)
            .into_iter()
            .filter(|child| child.kind() == clause_kind)
            .collect()
    }

    fn rescue_clause_exceptions<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        match self {
            Self::Python => {
                let Some(pattern) = named_children(node)
                    .into_iter()
                    .find(|child| !matches!(child.kind(), "block" | "comment"))
                else {
                    return Vec::new();
                };
                if pattern.kind() != "as_pattern" {
                    return vec![pattern];
                }
                named_children(pattern)
                    .into_iter()
                    .find(|child| child.kind() != "as_pattern_target")
                    .into_iter()
                    .collect()
            }
            Self::TypeScript => Vec::new(),
            _ => {
                let Some(exceptions) = named_children(node)
                    .into_iter()
                    .find(|child| child.kind() == "exceptions")
                else {
                    return Vec::new();
                };
                let text = node_text(exceptions, source).trim();
                if ruby_exception_constant_text(text)
                    || (named_children(exceptions).is_empty() && !text.is_empty())
                {
                    return vec![exceptions];
                }
                named_children(exceptions)
            }
        }
    }

    fn rescue_clause_exceptions_source<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => self
                .rescue_clause_exceptions(node, source)
                .into_iter()
                .next(),
            Self::TypeScript => None,
            _ => named_children(node)
                .into_iter()
                .find(|child| child.kind() == "exceptions"),
        }
    }

    fn rescue_clause_exception_variable_name<'tree>(
        self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => named_children(node)
                .into_iter()
                .find(|child| child.kind() == "as_pattern")
                .and_then(|pattern| descendant(pattern, &["as_pattern_target"])),
            Self::TypeScript => named_children(node)
                .into_iter()
                .find(|child| identifier_kind_name(child.kind())),
            _ => named_children(node)
                .into_iter()
                .find(|child| child.kind() == "exception_variable")
                .and_then(|variable| {
                    named_children(variable)
                        .into_iter()
                        .find(|child| identifier_kind_name(child.kind()))
                }),
        }
    }

    fn rescue_clause_exception_variable_source<'tree>(
        self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python | Self::TypeScript => self.rescue_clause_exception_variable_name(node),
            _ => named_children(node)
                .into_iter()
                .find(|child| child.kind() == "exception_variable"),
        }
    }

    fn rescue_clause_handler<'tree>(
        self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => named_children(node)
                .into_iter()
                .rev()
                .find(|child| child.kind() == "block"),
            Self::TypeScript => named_children(node)
                .into_iter()
                .rev()
                .find(|child| child.kind() == "statement_block"),
            _ => named_children(node).into_iter().rev().find(|child| {
                !matches!(
                    child.kind(),
                    "exceptions" | "exception_variable" | "comment"
                )
            }),
        }
    }

    fn rescue_clause(self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "rescue"
    }

    fn ensure_body_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.ensure_clause(node, source).is_some()
    }

    fn ensure_body_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => {
                if node.kind() == "try_statement" {
                    return Some(node);
                }
                if node.kind() == "block" {
                    let raw_named = named_children(node);
                    if raw_named.len() == 1
                        && raw_named[0].kind() == "try_statement"
                        && node_text(raw_named[0], source) == node_text(node, source)
                    {
                        return Some(raw_named[0]);
                    }
                }
            }
            Self::TypeScript => {
                if node.kind() == "try_statement" {
                    return Some(node);
                }
                if node.kind() == "statement_block" {
                    let raw_named = named_children(node);
                    if raw_named.len() == 1
                        && raw_named[0].kind() == "try_statement"
                        && node_text(raw_named[0], source) == node_text(node, source)
                    {
                        return Some(raw_named[0]);
                    }
                }
            }
            _ => {}
        }

        if ENSURE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            Some(node)
        } else {
            None
        }
    }

    fn ensure_body_nodes<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.ensure_body_target(node, source) else {
            return Vec::new();
        };
        let named = named_children(target);
        let ensure_kind = match self {
            Self::Python | Self::TypeScript => "finally_clause",
            _ => "ensure",
        };
        let Some(index) = named.iter().position(|child| child.kind() == ensure_kind) else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn ensure_clause<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let target = self.ensure_body_target(node, source)?;
        let ensure_kind = match self {
            Self::Python | Self::TypeScript => "finally_clause",
            _ => "ensure",
        };
        named_children(target)
            .into_iter()
            .find(|child| child.kind() == ensure_kind)
    }

    fn ensure_clause_body<'tree>(
        self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        match self {
            Self::Python => named_children(node)
                .into_iter()
                .rev()
                .find(|child| child.kind() == "block"),
            Self::TypeScript => named_children(node)
                .into_iter()
                .rev()
                .find(|child| child.kind() == "statement_block"),
            _ => None,
        }
    }

    fn array_literal_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.array_literal_target(node, source).is_some()
    }

    fn array_literal_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if self == Self::Lua {
            if let Some(target) = lua_positional_table_target(node, source) {
                return Some(target);
            }
        }

        if ARRAY_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !ARRAY_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if bracketed(node, source, "[", "]") {
            return Some(node);
        }

        let named = named_children(node);
        let child = *named.first()?;
        if named.len() == 1 {
            if ARRAY_LITERAL_NODE_KINDS.contains(&child.kind()) {
                return Some(child);
            }

            if matches!(child.kind(), "expression_statement" | "statement")
                && node_text(child, source).trim() == node_text(node, source).trim()
            {
                return self.array_literal_target(child, source);
            }

            let stripped = node_text(node, source).trim();
            if stripped == node_text(child, source)
                || stripped == format!("{};", node_text(child, source))
            {
                if ARRAY_LITERAL_NODE_KINDS.contains(&child.kind()) {
                    return Some(child);
                }
            }
        }

        None
    }

    fn array_literal_values<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.array_literal_target(node, source).unwrap_or(node);
        if self == Self::Lua {
            if target.kind() == "arguments" {
                if let Some(table) = named_children(target)
                    .into_iter()
                    .find(|child| child.kind() == "table_constructor")
                {
                    if node_text(target, source).trim() == node_text(table, source).trim() {
                        return named_children(table);
                    }
                }
            }
            if target.kind() == "table_constructor" {
                return named_children(target);
            }
        }

        named_children(target)
    }

    fn element_reference_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.element_reference_target(node, source).is_some()
    }

    fn element_reference_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if ELEMENT_REFERENCE_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !ELEMENT_REFERENCE_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }

        let named = named_children(node);
        if named.len() == 1
            && ELEMENT_REFERENCE_WRAPPER_KINDS.contains(&named[0].kind())
            && node_text(named[0], source).trim() == node_text(node, source).trim()
        {
            return self.element_reference_target(named[0], source);
        }
        if named.len() == 1 && ELEMENT_REFERENCE_NODE_KINDS.contains(&named[0].kind()) {
            let stripped = node_text(node, source).trim();
            let child_text = node_text(named[0], source);
            if stripped == child_text || stripped == format!("{child_text};") {
                return Some(named[0]);
            }
        }

        if element_reference_shape(node, source) {
            Some(node)
        } else {
            None
        }
    }

    fn element_reference_receiver<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let target = self.element_reference_target(node, source).unwrap_or(node);
        named_children(target).first().copied()
    }

    fn element_reference_arguments<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.element_reference_target(node, source).unwrap_or(node);
        named_children(target).into_iter().skip(1).collect()
    }

    fn hash_literal_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.hash_literal_target(node, source).is_some()
    }

    fn hash_literal_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if self == Self::Lua {
            if let Some(target) = lua_keyed_table_target(node, source) {
                return Some(target);
            }
        }

        if HASH_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !HASH_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if statement_block_wrapper(node) {
            return None;
        }
        if bracketed(node, source, "{", "}") {
            return Some(node);
        }

        let named = named_children(node);
        if named.len() != 1 {
            return None;
        }

        let child = named[0];
        if node.kind() == "parenthesized_expression" {
            return self.hash_literal_target(child, source);
        }

        let stripped = node_text(node, source).trim();
        let child_text = node_text(child, source);
        if stripped == child_text || stripped == format!("{child_text};") {
            if HASH_LITERAL_NODE_KINDS.contains(&child.kind()) {
                return Some(child);
            }
            if HASH_LITERAL_WRAPPER_KINDS.contains(&child.kind()) {
                return self.hash_literal_target(child, source);
            }
        }

        None
    }

    fn hash_literal_values<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.hash_literal_target(node, source).unwrap_or(node);
        if self == Self::Lua {
            if target.kind() == "arguments" {
                if let Some(table) = named_children(target)
                    .into_iter()
                    .find(|child| child.kind() == "table_constructor")
                {
                    return named_children(table);
                }
                return named_children(target);
            }
            if target.kind() == "table_constructor" {
                return named_children(target);
            }
        }

        named_children(target)
    }

    fn empty_body_statement(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if EMPTY_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node).is_empty()
            && node_text(node, source).trim().is_empty()
        {
            return true;
        }

        match self {
            Self::Python => {
                if node.kind() == "pass_statement" {
                    return true;
                }
                if node.kind() == "block" && node_text(node, source).trim() == "pass" {
                    let named = named_children(node);
                    return named.is_empty()
                        || named.iter().all(|child| child.kind() == "pass_statement");
                }
                false
            }
            Self::TypeScript => {
                node.kind() == "statement_block"
                    && named_children(node).is_empty()
                    && node_text(node, source).trim() == "{}"
            }
            _ => false,
        }
    }

    fn heredoc_body_statement(self, node: TreeSitterNode<'_>) -> bool {
        self == Self::Ruby
            && HEREDOC_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node)
                .iter()
                .any(|child| child.kind() == "heredoc_body")
    }

    fn heredoc_call_for_body(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Ruby {
            return false;
        }
        if node.kind() == "heredoc_beginning" {
            return true;
        }
        if matches!(node.kind(), "call" | "argument_list")
            && heredoc_marker_text(node_text(node, source))
        {
            return true;
        }

        named_children(node).into_iter().any(|child| {
            if named_children(child)
                .into_iter()
                .any(|grandchild| grandchild.kind() == "heredoc_body")
            {
                return false;
            }

            self.heredoc_call_for_body(child, source)
        })
    }

    fn interpolated_statement(
        self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        INTERPOLATED_STATEMENT_WRAPPER_KINDS.contains(&node.kind())
            && children.iter().any(|child| child.kind() == "interpolation")
    }

    fn concatenated_string_statement(
        self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        if concatenated_string_node(node).is_some() {
            return true;
        }
        let wrapper_kinds = match self {
            Self::Python => PYTHON_CONCATENATED_STRING_WRAPPER_KINDS,
            _ => CONCATENATED_STRING_WRAPPER_KINDS,
        };
        if !wrapper_kinds.contains(&node.kind()) {
            return false;
        }
        if children.len() > 1 && children.iter().all(|child| child.kind() == "string") {
            return true;
        }
        children.len() == 1 && concatenated_string_target(children[0]).is_some()
    }

    fn zero_child_identifier_call(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Ruby
            || node.kind() != "call"
            || !ruby_variable_name_text(node_text(node, source))
        {
            return false;
        }
        let named = named_children(node);
        named.is_empty()
            || (named.len() == 1
                && identifier_kind_name(named[0].kind())
                && node_text(named[0], source) == node_text(node, source))
    }

    fn boolean_expression_kind(self, node: TreeSitterNode<'_>) -> bool {
        BOOLEAN_EXPRESSION_KINDS.contains(&node.kind())
            || (self == Self::Lua && node.kind() == "expression_list")
    }

    fn comparison_expression_kind(self, node: TreeSitterNode<'_>) -> bool {
        COMPARISON_EXPRESSION_KINDS.contains(&node.kind())
            || (self == Self::Lua && node.kind() == "expression_list")
    }

    fn dotted_expression_wrapper(self, node: TreeSitterNode<'_>) -> bool {
        let kinds = match self {
            Self::Python => PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS,
            _ => DOTTED_EXPRESSION_WRAPPER_KINDS,
        };
        kinds.contains(&node.kind())
    }

    fn unary_not_expression(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        matches!(node.kind(), "unary" | "unary_expression")
            && node_text(node, source).trim_start().starts_with('!')
    }

    fn unary_minus_expression(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        match self {
            Self::Python => {
                matches!(node.kind(), "unary" | "unary_expression" | "unary_operator")
                    && node_text(node, source).trim_start().starts_with('-')
            }
            Self::Lua => {
                (matches!(node.kind(), "unary" | "unary_expression")
                    && node_text(node, source).trim_start().starts_with('-'))
                    || (node.kind() == "expression_list"
                        && node
                            .children(&mut node.walk())
                            .next()
                            .map(|child| node_text(child, source) == "-")
                            .unwrap_or(false)
                        && named_children(node).len() == 1)
            }
            _ => {
                matches!(node.kind(), "unary" | "unary_expression")
                    && node_text(node, source).trim_start().starts_with('-')
            }
        }
    }

    fn binary_operator(self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if let Some(operator) = direct_binary_operator(node, source) {
            return Some(operator.to_string());
        }

        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && BINARY_WRAPPER_KINDS.contains(&raw_named[0].kind())
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            return self.binary_operator(raw_named[0], source);
        }

        None
    }

    fn class_node(self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "class" | "class_definition" | "class_declaration" | "class_specifier"
        )
    }

    fn identifier_text_node(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self == Self::Lua
            && matches!(node.kind(), "variable_list" | "expression_list")
            && bare_identifier_text(node_text(node, source))
    }

    fn member_assignment_target(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if self != Self::Lua || node.kind() != "variable_list" {
            return false;
        }

        let raw_named = raw_named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "dot_index_expression"
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            raw_named[0]
        } else {
            node
        };

        raw_named_children(target).len() == 2
            && target
                .children(&mut target.walk())
                .any(|child| !child.is_named() && node_text(child, source) == ".")
    }

    fn instance_variable(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() == "instance_variable" {
            return true;
        }

        self == Self::Ruby
            && node_text(node, source)
                .strip_prefix('@')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn global_variable(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() == "global_variable" {
            return true;
        }

        self == Self::Ruby
            && node_text(node, source)
                .strip_prefix('$')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn assignment_operator(self, text: &str) -> bool {
        match self {
            Self::Ruby => matches!(
                text,
                "=" | "+="
                    | "-="
                    | "*="
                    | "/="
                    | "%="
                    | "**="
                    | "&&="
                    | "||="
                    | "&="
                    | "|="
                    | "^="
                    | "<<="
                    | ">>="
            ),
            Self::Python => matches!(
                text,
                "=" | "+="
                    | "-="
                    | "*="
                    | "/="
                    | "%="
                    | "//="
                    | "**="
                    | "@="
                    | "&="
                    | "|="
                    | "^="
                    | "<<="
                    | ">>="
                    | ":="
            ),
            Self::Lua => text == "=",
            Self::TypeScript => matches!(
                text,
                "=" | "+="
                    | "-="
                    | "*="
                    | "/="
                    | "%="
                    | "**="
                    | "<<="
                    | ">>="
                    | ">>>="
                    | "&="
                    | "|="
                    | "^="
                    | "&&="
                    | "||="
                    | "??="
            ),
            Self::Default => matches!(text, "=" | "+=" | "-=" | "*=" | "/=" | "%="),
        }
    }

    fn unwrap_node(self, node: TreeSitterNode<'_>, source: &str, named_child_count: usize) -> bool {
        if matches!(
            node.kind(),
            "parenthesized_expression"
                | "parenthesized_statements"
                | "expression_statement"
                | "statement"
                | "case_pattern"
                | "match_pattern"
                | "pattern"
        ) && named_child_count == 1
        {
            return true;
        }

        if self != Self::Lua || node.kind() != "expression_list" || named_child_count != 1 {
            return false;
        }

        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && raw_named[0].kind() == "parenthesized_expression"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return true;
        }

        let mut cursor = node.walk();
        let raw_children = node.children(&mut cursor).collect::<Vec<_>>();
        raw_children
            .first()
            .map(|child| node_text(*child, source) == "(")
            .unwrap_or(false)
            && raw_children
                .last()
                .map(|child| node_text(*child, source) == ")")
                .unwrap_or(false)
    }

    fn interpolated_string(
        self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        if node.kind() == "string" && children.iter().any(|child| child.kind() == "interpolation") {
            return true;
        }

        self == Self::TypeScript
            && node.kind() == "template_string"
            && children
                .iter()
                .any(|child| child.kind() == "template_substitution")
    }

    fn lambda_expression(self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.lambda_target(node, source).is_some()
    }

    fn lambda_target<'tree>(
        self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "lambda" {
            return Some(node);
        }

        if self == Self::TypeScript
            && matches!(node.kind(), "arrow_function" | "function_expression")
        {
            return Some(node);
        }

        if self == Self::Lua {
            if node.kind() == "function_definition" {
                return Some(node);
            }

            if node.kind() == "expression_list" {
                let named = named_children(node);
                if named.len() == 1
                    && named[0].kind() == "function_definition"
                    && node_text(named[0], source) == node_text(node, source)
                {
                    return Some(named[0]);
                }
            }
        }

        None
    }

    fn interpolation_node(self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "interpolation"
            || (self == Self::TypeScript && node.kind() == "template_substitution")
    }

    fn explicit_alternative<'tree>(
        self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let alternatives: &[&str] = match self {
            Self::Ruby => &["elsif", "else"],
            Self::Python => &["elif_clause", "else", "else_clause"],
            Self::Lua => &["elseif_statement", "else", "else_statement"],
            Self::TypeScript => &["else", "else_clause"],
            Self::Default => &["else", "else_clause", "else_statement"],
        };
        named_children(node)
            .into_iter()
            .find(|child| alternatives.contains(&child.kind()))
    }
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
    language: Language,
    normalization_adapter: TreeSitterNormalizationAdapter,
    local_stack: Vec<BTreeSet<String>>,
    root_span: Option<Span>,
    current_heredoc_body_span: Option<Span>,
}

impl<'source> TreeSitterNormalizer<'source> {
    fn new(source: &'source str, language: Language) -> Self {
        Self {
            source,
            language,
            normalization_adapter: TreeSitterNormalizationAdapter::for_language(language),
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
        if let Some(loop_type) = loop_kind(node.kind()) {
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
            "call" | "call_expression" | "method_call" | "method_call_expression" => {
                self.normalize_call(node)
            }
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
                } else if let Some(content) = self.lua_no_paren_string_argument_content(node) {
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

    fn normalize_python_nested_class_as_iter(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
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
        if self.language == Language::Python && node.kind() == "block" {
            let raw_children = self.raw_named_children(node);
            if raw_children.len() == 1
                && raw_children[0].kind() == "class_definition"
                && node
                    .parent()
                    .map(|parent| parent.kind() == "class_definition")
                    .unwrap_or(false)
            {
                return self.normalize_python_nested_class_as_iter(raw_children[0]);
            }
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
        if self.language == Language::Python && node.kind() == "else_clause" {
            if let Some(block) = self
                .raw_named_children(node)
                .into_iter()
                .find(|child| child.kind() == "block")
            {
                if let Some(normalized) = self.normalize_python_else_if_block(block) {
                    return Some(self.wrap(
                        "ELSE_CLAUSE",
                        vec![Child::Node(Box::new(normalized))],
                        node,
                    ));
                }
            }
        }
        if node.kind() != "else" {
            return self.normalize_body(node);
        }
        if let Some(call) = self.first_dotted_call_descendant(node) {
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

    fn normalize_python_else_if_block(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
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
        let body = self
            .when_body(node)
            .and_then(|body| self.normalize_body(body));
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
            && self.call_kind(children[0].kind())
            && node_text(children[0], self.source) == node_text(node, self.source)
        {
            if let Some(call) = self.normalize_return_value_call(children[0]) {
                return Some(call);
            }
        }
        if let (Some(function), Some(nested_args)) = (children.first(), children.get(1)) {
            if self.identifier_kind(function.kind()) && nested_args.kind() == "argument_list" {
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
                    vec![
                        Child::Symbol(node_text(*function, self.source).to_string()),
                        args_child,
                    ],
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
        if !self.identifier_kind(function.kind()) {
            return None;
        }

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
            vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                args_child,
            ],
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
        if self.language != Language::Ruby || !matches!(operator, "||" | "&&") {
            return None;
        }
        if !self.identifier_kind(left.kind()) {
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
        if self.identifier_kind(left.kind()) {
            return Some(self.wrap(
                "LVAR",
                vec![Child::String(node_text(left, self.source).to_string())],
                left,
            ));
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

    fn normalize_declaration(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let mut assignments = Vec::new();
        for entry in self.declaration_entries(node) {
            let Some(name) = self.declaration_name(entry) else {
                continue;
            };
            let right = self
                .declaration_value(entry)
                .and_then(|value| self.normalize_node(value));
            assignments.push(self.wrap(
                "LASGN",
                vec![Child::String(self.target_name(name)), optional_node(right)],
                entry,
            ));
        }

        if assignments.is_empty() {
            None
        } else if assignments.len() == 1 {
            assignments.into_iter().next()
        } else {
            Some(
                self.wrap(
                    "BLOCK",
                    assignments
                        .into_iter()
                        .map(|assignment| Child::Node(Box::new(assignment)))
                        .collect(),
                    node,
                ),
            )
        }
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
        let call_source = if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
        {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(node, self.source) == node_text(raw_named[0], self.source)
            {
                raw_named[0]
            } else {
                node
            }
        } else {
            node
        };
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
        if self.identifier_kind(function.kind()) {
            let node_type = if block.is_some() || !args.is_empty() {
                "FCALL"
            } else {
                "VCALL"
            };
            let children = vec![
                Child::Symbol(node_text(function, self.source).to_string()),
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
        if self.language == Language::Ruby && self.const_kind(function.kind()) {
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
        let name = node_text(node, self.source).to_string();
        if self.ruby_vcall_identifier(node, &name) || self.vcall_identifier(node, &name) {
            self.wrap("VCALL", vec![Child::Symbol(name)], node)
        } else {
            self.wrap("LVAR", vec![Child::String(name)], node)
        }
    }

    fn normalize_parameters(&mut self, node: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if self.language != Language::Ruby {
            return None;
        }
        let node = node?;
        let defaults = self
            .named_children(node)
            .into_iter()
            .filter_map(|param| {
                let name = self.named_field(param, "name")?;
                let value = self.named_field(param, "value")?;
                let value = optional_node(self.normalize_node(value));
                Some(self.wrap(
                    "LASGN",
                    vec![
                        Child::Symbol(node_text(name, self.source).to_string()),
                        value,
                    ],
                    param,
                ))
            })
            .map(|node| Child::Node(Box::new(node)))
            .collect::<Vec<_>>();
        if defaults.is_empty() {
            None
        } else {
            Some(self.wrap("ARGS", defaults, node))
        }
    }

    fn normalize_block_parameters(&mut self, block: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if self.language != Language::Ruby {
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
            text: node_text(source, self.source).to_string(),
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
            text,
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
            text: source.text.clone(),
        }
    }

    fn wrap_from_span_text(
        &self,
        node_type: &str,
        children: Vec<Child>,
        node_span: Span,
        text: &str,
    ) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: node_span[0],
            first_column: node_span[1],
            last_lineno: node_span[2],
            last_column: node_span[3],
            text: text.to_string(),
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
        if self.identifier_kind(node.kind()) {
            locals.insert(
                node_text(node, self.source)
                    .trim_start_matches('*')
                    .to_string(),
            );
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
        if self.identifier_kind(node.kind()) {
            locals.insert(
                node_text(node, self.source)
                    .trim_start_matches('*')
                    .to_string(),
            );
        }
        if self
            .normalization_adapter
            .identifier_text_node(node, self.source)
        {
            locals.insert(node_text(node, self.source).to_string());
        }
        for child in self.raw_named_children(node) {
            self.collect_identifier_names(child, locals);
        }
    }

    fn collect_parameter_names(&self, node: TreeSitterNode<'_>, locals: &mut BTreeSet<String>) {
        if let Some(name) = self.named_field(node, "name") {
            self.collect_identifier_names(name, locals);
            return;
        }
        if let Some(name) = self
            .named_children(node)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))
        {
            locals.insert(
                node_text(name, self.source)
                    .trim_start_matches('*')
                    .to_string(),
            );
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
        if self.lua_single_assignment_block_child(node) {
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
        let Some(parent) = node.parent() else {
            return false;
        };
        if matches!(
            parent.kind(),
            "string" | "delimited_symbol" | "regex" | "regex_literal"
        ) {
            return true;
        }
        if self.language == Language::Lua
            && matches!(
                node.kind(),
                "string_content" | "escape_sequence" | "interpolation" | "string_fragment"
            )
            && parent.kind() == "expression_list"
        {
            return true;
        }

        matches!(
            node.kind(),
            "string_content" | "escape_sequence" | "interpolation" | "string_fragment"
        ) && parent
            .parent()
            .map(|grandparent| {
                matches!(
                    grandparent.kind(),
                    "string" | "delimited_symbol" | "regex" | "regex_literal"
                )
            })
            .unwrap_or(false)
    }

    fn literal_fragment_expression_list(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() != "expression_list" {
            return false;
        }

        let named = self.named_children(node);
        named.len() == 1 && self.literal_fragment_assignment_context(named[0])
    }

    fn assignment_rhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.lua_single_assignment_block_child(node) {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        node.prev_sibling()
            .map(|sibling| self.assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    fn lua_single_assignment_block_child(&self, node: TreeSitterNode<'_>) -> bool {
        if self.language != Language::Lua {
            return false;
        }
        let Some(parent) = node.parent() else {
            return false;
        };
        if parent.kind() != "assignment_statement" {
            return false;
        }
        let Some(grandparent) = parent.parent() else {
            return false;
        };
        grandparent.kind() == "block"
            && node_text(grandparent, self.source) == node_text(parent, self.source)
            && self.raw_named_children(grandparent).len() == 1
    }

    fn lua_single_assignment_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if self.language != Language::Lua || node.kind() != "assignment_statement" {
            return false;
        }
        let Some(parent) = node.parent() else {
            return false;
        };
        parent.kind() == "block"
            && node_text(parent, self.source) == node_text(node, self.source)
            && self.raw_named_children(parent).len() == 1
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
        let function_text = if self.language == Language::Ruby && function.kind() == "call" {
            self.named_children(function)
                .into_iter()
                .next()
                .map(|child| node_text(child, self.source))
                .unwrap_or_else(|| node_text(function, self.source))
        } else {
            node_text(function, self.source)
        };
        inline_def_wrapper_mid(function_text) && node_text(node, self.source).contains("def ")
    }

    fn inline_def_from_argument_list(&mut self, args: Option<TreeSitterNode<'_>>) -> Option<Node> {
        if !self.ruby() {
            return None;
        }
        self.inline_def_from_source(args?)
    }

    fn inline_def_from_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
        {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        } else {
            node
        };
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
        let body_kind = match self.normalization_adapter {
            TreeSitterNormalizationAdapter::Python | TreeSitterNormalizationAdapter::Lua => "block",
            _ => "body_statement",
        };
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
        let target = if self.language == Language::Ruby
            && named.len() == 1
            && matches!(
                named[0].kind(),
                "binary" | "binary_expression" | "binary_operator" | "boolean_operator"
            )
            && node_text(node, self.source) == node_text(named[0], self.source)
        {
            named[0]
        } else {
            node
        };
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
        let operator_call_kind = match self.language {
            Language::Python => matches!(
                node.kind(),
                "binary" | "binary_expression" | "binary_operator"
            ),
            Language::Lua => matches!(
                node.kind(),
                "binary" | "binary_expression" | "expression_list"
            ),
            _ => matches!(node.kind(), "binary" | "binary_expression"),
        };

        operator_call_kind
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
        let children = if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
        {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(node, self.source) == node_text(raw_named[0], self.source)
            {
                self.named_children(raw_named[0])
            } else {
                self.named_children(node)
            }
        } else {
            self.named_children(node)
        };

        children.into_iter().find(|child| {
            Some(*child) != block && (self.call_kind(child.kind()) || self.member_read_node(*child))
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

        let target = if self.language == Language::Ruby {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(node, self.source) == node_text(raw_named[0], self.source)
            {
                raw_named[0]
            } else {
                node
            }
        } else {
            node
        };

        self.call_block(target).is_some()
            && self
                .named_children(target)
                .into_iter()
                .next()
                .map(|child| self.identifier_kind(child.kind()))
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
            .any(|child| matches!(node_text(child, self.source), "." | "&."))
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
            .trim_end_matches('=')
            .to_string();
        Some((receiver, method))
    }

    fn member_read_node(&self, node: TreeSitterNode<'_>) -> bool {
        if self.language == Language::Lua && node.kind() == "field" {
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
                        .trim_start_matches(['.', '?'])
                        .to_string()
                })
                .unwrap_or_default();
        }

        node_text(node, self.source)
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
            && self.call_kind(children[0].kind())
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

    fn declaration_entries<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Vec<TreeSitterNode<'tree>> {
        if matches!(node.kind(), "local_variable_declaration") {
            let entries = self
                .named_children(node)
                .into_iter()
                .filter(|child| child.kind() == "variable_declarator")
                .collect::<Vec<_>>();
            if !entries.is_empty() {
                return entries;
            }
        }
        if matches!(
            node.kind(),
            "local_variable_declaration"
                | "variable_declarator"
                | "variable_declaration"
                | "property_declaration"
        ) {
            vec![node]
        } else {
            Vec::new()
        }
    }

    fn declaration_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(name) = self.named_field(node, "name") {
            return Some(name);
        }

        for child in self.named_children(node) {
            if child.kind() == "variable_declaration" {
                if let Some(name) = self.declaration_name(child) {
                    return Some(name);
                }
            }
            if matches!(child.kind(), "identifier" | "simple_identifier" | "pattern") {
                return Some(child);
            }
        }
        None
    }

    fn declaration_value<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "property_declaration" {
            let mut after_target = false;
            for child in self.named_children(node) {
                if !after_target && matches!(child.kind(), "variable_declaration" | "pattern") {
                    after_target = true;
                    continue;
                }
                if after_target && !declaration_metadata_kind(child.kind()) {
                    return Some(child);
                }
            }
        }

        self.named_field(node, "value").or_else(|| {
            self.named_children(node).into_iter().find(|child| {
                !declaration_metadata_kind(child.kind())
                    && !matches!(
                        child.kind(),
                        "identifier" | "simple_identifier" | "pattern" | "variable_declaration"
                    )
            })
        })
    }

    fn assignment_target(
        &mut self,
        left: TreeSitterNode<'_>,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
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
        if self.identifier_kind(node.kind())
            || matches!(node.kind(), "splat" | "splat_parameter" | "rest_assignment")
        {
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
                        self.identifier_kind(child.kind()) || child.kind() == "constant"
                    })
                })
                .map(|name| node_text(name, self.source).to_string())
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
                .find(|child| self.identifier_kind(child.kind()))
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
                    .find(|child| self.identifier_kind(child.kind()))
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
        if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
        {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "call"
                && node_text(node, self.source) == node_text(raw_named[0], self.source)
            {
                return self.call_block(raw_named[0]);
            }
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
        if self.language == Language::Python
            && matches!(name, "body" | "consequence")
            && matches!(
                node.kind(),
                "elif_clause"
                    | "else_clause"
                    | "for_statement"
                    | "function_definition"
                    | "if_statement"
                    | "try_statement"
                    | "while_statement"
                    | "with_statement"
            )
        {
            if let Some(block) = self
                .raw_named_children(node)
                .into_iter()
                .find(|child| child.kind() == "block")
            {
                return Some(block);
            }
        }
        node.child_by_field_name(name)
    }

    fn parent_node<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.parent()
    }

    fn next_sibling<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.next_sibling()
    }

    fn prev_sibling<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        node.prev_sibling()
    }

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
        if self.language == Language::Python
            && node.kind() == "with_clause"
            && bare_identifier_text(node_text(node, self.source))
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "variable_list"
            && self.raw_named_children(node).len() == 1
            && self
                .raw_named_children(node)
                .first()
                .map(|child| self.identifier_kind(child.kind()))
                .unwrap_or(false)
            && self.lua_single_assignment_block_child(node)
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "variable_list"
            && self.raw_named_children(node).len() == 1
            && node
                .parent()
                .map(|parent| parent.kind() == "for_generic_clause")
                .unwrap_or(false)
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "variable_list"
            && self.raw_named_children(node).len() == 1
            && node
                .parent()
                .map(|parent| {
                    parent.kind() == "variable_declaration"
                        && self.raw_named_children(parent).len() == 1
                })
                .unwrap_or(false)
        {
            return Vec::new();
        }

        let children = self.raw_named_children(node);
        if self.language == Language::Lua
            && node.kind() == "variable_list"
            && children.len() == 1
            && children[0].kind() == "dot_index_expression"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Ruby
            && INTERPOLATED_STATEMENT_WRAPPER_KINDS.contains(&node.kind())
            && children.len() == 1
            && children[0].kind() == "string"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            let string_children = self.raw_named_children(children[0]);
            if string_children
                .iter()
                .any(|child| child.kind() == "interpolation")
            {
                return string_children;
            }
        }
        if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "if_modifier" | "unless_modifier" | "while_modifier" | "until_modifier"
            )
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Ruby
            && matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && children.len() == 1
            && children[0].kind() == "yield"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Lua
            && node.kind() == "expression_list"
            && children.len() == 1
            && self.identifier_kind(children[0].kind())
            && node
                .parent()
                .map(|parent| matches!(parent.kind(), "assignment_statement" | "return_statement"))
                .unwrap_or(false)
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "expression_list"
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "true" | "false" | "nil" | "number" | "integer" | "float"
            )
            && node
                .parent()
                .map(|parent| matches!(parent.kind(), "assignment_statement" | "return_statement"))
                .unwrap_or(false)
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "expression_list"
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "binary_expression"
                    | "function_call"
                    | "dot_index_expression"
                    | "function_definition"
                    | "string"
            )
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Lua
            && node.kind() == "expression_list"
            && children.len() == 1
            && children[0].kind() == "table_constructor"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Lua
            && node.kind() == "field"
            && children.len() == 1
            && self.identifier_kind(children[0].kind())
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return Vec::new();
        }
        if self.language == Language::Lua
            && node.kind() == "field"
            && children.len() == 1
            && children[0].kind() == "string"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Lua
            && node.kind() == "field"
            && children.len() == 1
            && children[0].kind() == "function_call"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Lua
            && node.kind() == "block"
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "function_call" | "return_statement" | "variable_declaration"
            )
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "relative_import"
            && children.len() == 1
            && children[0].kind() == "import_prefix"
        {
            return Vec::new();
        }
        if self.language == Language::Python && node.kind() == "block" && children.len() == 1 {
            if children[0].kind() == "function_definition" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "decorated_definition" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "pass_statement"
                && node_text(node, self.source).trim() == "pass"
            {
                return Vec::new();
            }
            if matches!(children[0].kind(), "break_statement" | "continue_statement")
                && bare_identifier_text(node_text(node, self.source).trim())
            {
                return Vec::new();
            }
            if children[0].kind() == "return_statement"
                && node_text(node, self.source) == node_text(children[0], self.source)
            {
                if self.raw_named_children(children[0]).is_empty() {
                    return Vec::new();
                }
                return self.named_children(children[0]);
            }
            if children[0].kind() == "delete_statement" {
                return self.named_children(children[0]);
            }
            if children[0].kind() == "if_statement" {
                return self.named_children(children[0]);
            }
            if matches!(
                children[0].kind(),
                "assert_statement"
                    | "for_statement"
                    | "import_from_statement"
                    | "import_statement"
                    | "raise_statement"
                    | "try_statement"
                    | "while_statement"
                    | "with_statement"
            ) {
                return self.named_children(children[0]);
            }
            if children[0].kind() != "expression_statement" {
                return children;
            }
            let statement_children = self.raw_named_children(children[0]);
            if statement_children.len() == 1
                && statement_children[0].kind() == "identifier"
                && node_text(node, self.source) == node_text(children[0], self.source)
            {
                return Vec::new();
            }
            if statement_children.len() == 1 && statement_children[0].kind() == "ellipsis" {
                return Vec::new();
            }
            if statement_children.len() == 1
                && matches!(
                    statement_children[0].kind(),
                    "assignment"
                        | "augmented_assignment"
                        | "binary_operator"
                        | "call"
                        | "string"
                        | "subscript"
                )
            {
                return self.named_children(statement_children[0]);
            }
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "yield"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "identifier"
        {
            return Vec::new();
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "binary_operator"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "comparison_operator"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "call"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "attribute"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "expression_statement"
            && children.len() == 1
            && children[0].kind() == "string"
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python && node.kind() == "as_pattern_target" {
            return Vec::new();
        }
        if self.language == Language::Python
            && matches!(node.kind(), "with_clause" | "with_item")
            && children.len() == 1
            && matches!(children[0].kind(), "with_item" | "as_pattern")
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "with_item"
            && children.len() == 1
            && children[0].kind() == "call"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if self.language == Language::Python
            && node.kind() == "with_item"
            && children.len() == 1
            && children[0].kind() == "attribute"
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.named_children(children[0]);
        }
        if node.kind() == "type" && children.len() == 1 {
            if children[0].kind() == "union_type" {
                return self.named_children(children[0]);
            }
            if self.language == Language::Python && children[0].kind() == "binary_operator" {
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

    fn lua_no_paren_string_argument_content<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if self.language != Language::Lua || node.kind() != "string" {
            return None;
        }
        let parent = node.parent()?;
        if parent.kind() != "arguments"
            || node_text(parent, self.source) != node_text(node, self.source)
        {
            return None;
        }
        self.raw_named_children(node)
            .into_iter()
            .find(|child| child.kind() == "string_content")
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
            text,
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
            text,
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
        matches!(
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

    fn first_dotted_call_descendant<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        for child in self.named_children(node) {
            if self.call_kind(child.kind()) && self.dotted_call(child) {
                return Some(child);
            }
            if let Some(found) = self.first_dotted_call_descendant(child) {
                return Some(found);
            }
        }
        None
    }

    fn elide_tail_returns(&self, node: Option<Node>) -> Option<Node> {
        if self.language != Language::Ruby {
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
        if self.language != Language::Ruby {
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

fn declaration_metadata_kind(kind: &str) -> bool {
    matches!(
        kind,
        "modifiers"
            | "type"
            | "nullable_type"
            | "parenthesized_type"
            | "user_type"
            | "type_identifier"
            | "integral_type"
            | "floating_point_type"
            | "void_type"
    )
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
mod tests {
    use super::{parse, parse_with_language, Child, Node};
    use crate::decomplex::syntax::Language;
    use serde_json::{json, Value};
    use std::collections::BTreeSet;
    use std::io::Write;
    use std::path::Path;
    use std::process::Command;
    use tree_sitter::{Node as TreeSitterNode, Parser as TreeSitterParser};

    fn parse_source(source: &str) -> Node {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("create temp ruby file");
        file.write_all(source.as_bytes())
            .expect("write temp ruby file");
        parse(file.path()).expect("parse temp ruby file").0
    }

    fn parse_language_source(source: &str, language: Language, suffix: &str) -> Node {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create temp source file");
        file.write_all(source.as_bytes())
            .expect("write temp source file");
        parse_with_language(file.path(), language)
            .expect("parse temp source file")
            .0
    }

    fn nodes_of_type<'a>(node: &'a Node, node_type: &str, out: &mut Vec<&'a Node>) {
        if node.r#type == node_type {
            out.push(node);
        }
        for child in node.children.iter().filter_map(super::node) {
            nodes_of_type(child, node_type, out);
        }
    }

    fn first_node<'a>(root: &'a Node, node_type: &str, text: &str) -> &'a Node {
        let mut nodes = Vec::new();
        nodes_of_type(root, node_type, &mut nodes);
        nodes
            .into_iter()
            .find(|node| node.text == text)
            .unwrap_or_else(|| panic!("expected {node_type} with text {text:?} in {root:#?}"))
    }

    fn child_node(node: &Node, index: usize) -> &Node {
        node.children
            .get(index)
            .and_then(super::node)
            .unwrap_or_else(|| panic!("expected child node {index} in {node:#?}"))
    }

    fn child_types(node: &Node) -> Vec<&str> {
        node.children
            .iter()
            .filter_map(super::node)
            .map(|child| child.r#type.as_str())
            .collect()
    }

    fn test_node(node_type: &str, children: Vec<Child>) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 1,
            text: node_type.to_string(),
        }
    }

    fn infix_parts_text(
        normalizer: &super::TreeSitterNormalizer<'_>,
        node: TreeSitterNode<'_>,
        source: &str,
    ) -> Option<(String, String, String)> {
        let (left, operator, right) = normalizer.infix_statement_parts(node)?;
        Some((
            super::node_text(left, source).to_string(),
            operator,
            super::node_text(right, source).to_string(),
        ))
    }

    fn node_value(node: &Node) -> Value {
        json!({
            "type": node.r#type,
            "children": node.children.iter().map(child_value).collect::<Vec<_>>(),
            "first_lineno": node.first_lineno,
            "first_column": node.first_column,
            "last_lineno": node.last_lineno,
            "last_column": node.last_column,
            "text": node.text,
        })
    }

    fn child_value(child: &Child) -> Value {
        match child {
            Child::Node(node) => node_value(node),
            Child::Symbol(value) | Child::String(value) => Value::String(value.clone()),
            Child::Integer(value) => Value::Number((*value).into()),
            Child::Bool(value) => Value::Bool(*value),
            Child::Nil => Value::Null,
        }
    }

    fn children_value(children: &[Child]) -> Value {
        Value::Array(children.iter().map(child_value).collect())
    }

    fn ruby_language_name(language: Language) -> &'static str {
        match language {
            Language::Ruby => "ruby",
            Language::Python => "python",
            Language::JavaScript => "javascript",
            Language::Java => "java",
            Language::TypeScript => "typescript",
            Language::Swift => "swift",
            Language::Kotlin => "kotlin",
            Language::Go => "go",
            Language::Rust => "rust",
            Language::Zig => "zig",
            Language::Lua => "lua",
            Language::C => "c",
            Language::Cpp => "cpp",
            Language::CSharp => "csharp",
        }
    }

    fn ruby_normalized_value(path: &Path, language: Language) -> Value {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          root, = Decomplex::Ast.parse(ARGV.fetch(0))

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(root))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(path)
            .output()
            .expect("run ruby normalizer");
        assert!(
            output.status.success(),
            "ruby normalizer failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby normalizer should emit JSON")
    }

    fn assert_ruby_parity(source: &str, language: Language, suffix: &str) {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create parity temp source file");
        file.write_all(source.as_bytes())
            .expect("write parity temp source file");

        let rust = node_value(
            &parse_with_language(file.path(), language)
                .expect("parse parity temp source file")
                .0,
        );
        let ruby = ruby_normalized_value(file.path(), language);
        assert_eq!(rust, ruby);
    }

    fn raw_tree(source: &str, language: Language) -> tree_sitter::Tree {
        let mut parser = TreeSitterParser::new();
        parser
            .set_language(&super::language_grammar(language))
            .expect("set raw parser language");
        parser.parse(source, None).expect("parse raw source")
    }

    fn first_raw_node<'tree>(
        node: TreeSitterNode<'tree>,
        source: &str,
        kind: &str,
        text: &str,
    ) -> TreeSitterNode<'tree> {
        if node.kind() == kind && super::node_text(node, source) == text {
            return node;
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if let Some(found) = first_raw_node_opt(child, source, kind, text) {
                return found;
            }
        }
        panic!("expected raw node kind={kind:?} text={text:?}");
    }

    fn first_raw_node_opt<'tree>(
        node: TreeSitterNode<'tree>,
        source: &str,
        kind: &str,
        text: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == kind && super::node_text(node, source) == text {
            return Some(node);
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if let Some(found) = first_raw_node_opt(child, source, kind, text) {
                return Some(found);
            }
        }
        None
    }

    fn nth_raw_node<'tree>(
        node: TreeSitterNode<'tree>,
        source: &str,
        kind: &str,
        text: &str,
        index: usize,
    ) -> TreeSitterNode<'tree> {
        let mut found = Vec::new();
        collect_raw_nodes(node, source, kind, text, &mut found);
        *found.get(index).unwrap_or_else(|| {
            panic!("expected raw node kind={kind:?} text={text:?} index={index}")
        })
    }

    fn collect_raw_nodes<'tree>(
        node: TreeSitterNode<'tree>,
        source: &str,
        kind: &str,
        text: &str,
        found: &mut Vec<TreeSitterNode<'tree>>,
    ) {
        if node.kind() == kind && super::node_text(node, source) == text {
            found.push(node);
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            collect_raw_nodes(child, source, kind, text, found);
        }
    }

    fn ruby_private_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby predicate temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby predicate temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(method, target) ? "true" : "false"
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private predicate");
        assert!(
            output.status.success(),
            "ruby predicate failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby predicate output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_collected_names(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> BTreeSet<String> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby collected names temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby collected names temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          locals = Set.new
          normalizer.send(method, target, locals)
          puts JSON.generate(locals.to_a.sort)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-r",
                "set",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby collected names helper");
        assert!(
            output.status.success(),
            "ruby collected names helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Vec<String>>(&output.stdout)
            .expect("ruby collected names output should be json")
            .into_iter()
            .collect()
    }

    fn ruby_private_scope_collected_names(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        root: bool,
    ) -> BTreeSet<String> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby scope collected names temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby scope collected names temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          require "set"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          root = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          locals = Set.new
          normalizer.send(:collect_ruby_scope_locals, target, locals, root: root)
          puts JSON.generate(locals.to_a.sort)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(if root { "true" } else { "false" })
            .output()
            .expect("run ruby scope collected names helper");
        assert!(
            output.status.success(),
            "ruby scope collected names helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Vec<String>>(&output.stdout)
            .expect("ruby scope collected names output should be json")
            .into_iter()
            .collect()
    }

    fn ruby_private_ruby_scope_locals(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> BTreeSet<String> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby scope locals temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby scope locals temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts JSON.generate(normalizer.send(:ruby_scope_locals, target).to_a.sort)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-r",
                "set",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby scope locals helper");
        assert!(
            output.status.success(),
            "ruby scope locals helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Vec<String>>(&output.stdout)
            .expect("ruby scope locals output should be json")
            .into_iter()
            .collect()
    }

    fn ruby_private_with_ruby_scope_trace(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        reset: bool,
        initial_stack: &[Vec<&str>],
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby with_ruby_scope temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby with_ruby_scope temp source file");
        let initial_stack_json =
            serde_json::to_string(initial_stack).expect("serialize initial local stack");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          reset = ARGV.fetch(3) == "true"
          initial = JSON.parse(ARGV.fetch(4)).map { |names| Set.new(names) }
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalizer.instance_variable_set(:@local_stack, initial)
          snapshot = lambda do
            Array(normalizer.instance_variable_get(:@local_stack)).map { |locals| locals.to_a.sort }
          end
          before = snapshot.call
          inside = nil
          result = normalizer.send(:with_ruby_scope, target, reset: reset) do
            inside = snapshot.call
            "block-result"
          end
          after = snapshot.call
          puts JSON.generate("before" => before, "inside" => inside, "after" => after, "result" => result)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-r",
                "set",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(if reset { "true" } else { "false" })
            .arg(initial_stack_json)
            .output()
            .expect("run ruby with_ruby_scope helper");
        assert!(
            output.status.success(),
            "ruby with_ruby_scope helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby with_ruby_scope output should be json")
    }

    fn local_stack_from(names: &[Vec<&str>]) -> Vec<BTreeSet<String>> {
        names
            .iter()
            .map(|scope| scope.iter().map(|name| name.to_string()).collect())
            .collect()
    }

    fn local_stack_value(stack: &[BTreeSet<String>]) -> Value {
        json!(stack
            .iter()
            .map(|scope| scope.iter().cloned().collect::<Vec<_>>())
            .collect::<Vec<_>>())
    }

    fn ruby_private_destructured_parameter_targets_value(
        source: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("create ruby destructured parameter temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby destructured parameter temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          targets = []
          normalizer.send(:collect_destructured_parameter_targets, target, targets)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(targets.map { |node| value(node) })
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env(
                "DECOMPLEX_FORCE_LANGUAGE",
                ruby_language_name(Language::Ruby),
            )
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby destructured parameter helper");
        assert!(
            output.status.success(),
            "ruby destructured parameter helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby destructured parameter output should be json")
    }

    fn ruby_private_scope_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        mode: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby scope temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby scope temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)

          body = mode == "body" ? normalizer.send(:wrap, :BODY, children: [], source: target) : nil
          args = mode == "args" ? normalizer.send(:wrap, :ARGS, children: [], source: target) : nil
          result = normalizer.send(:scope, body, args: args, source: target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(mode)
            .output()
            .expect("run ruby scope helper");
        assert!(
            output.status.success(),
            "ruby scope helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby scope output should be json")
    }

    fn ruby_private_list_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        mode: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby list temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby list temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)

          item = normalizer.send(:wrap, :ITEM, children: [], source: target)
          children =
            case mode
            when "nil" then nil
            when "empty" then []
            when "one" then [item]
            else abort "unknown list mode: #{mode}"
            end
          result = normalizer.send(:list, children, source: target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(mode)
            .output()
            .expect("run ruby list helper");
        assert!(
            output.status.success(),
            "ruby list helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby list output should be json")
    }

    fn ruby_private_string(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> String {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby string temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby string temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(method, target).to_s
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private string helper");
        assert!(
            output.status.success(),
            "ruby string helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby string helper output should be utf8")
            .trim_end_matches(['\r', '\n'])
            .to_string()
    }

    fn ruby_private_text_predicate(language: Language, method: &str, text: &str) -> bool {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          language = ARGV.fetch(0).to_sym
          text = ARGV.fetch(1)
          method = ARGV.fetch(2)
          document = Object.new
          document.define_singleton_method(:language) { language }
          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          puts normalizer.send(method, text) ? "true" : "false"
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args(["-I", "lib", "-r", "decomplex/ast", "-e", script])
            .arg(ruby_language_name(language))
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private text predicate");
        assert!(
            output.status.success(),
            "ruby text predicate failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby text predicate output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_text_string(language: Language, method: &str, text: &str) -> String {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          language = ARGV.fetch(0).to_sym
          text = ARGV.fetch(1)
          method = ARGV.fetch(2)
          document = Object.new
          document.define_singleton_method(:language) { language }
          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          puts normalizer.send(method, text).to_s
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args(["-I", "lib", "-r", "decomplex/ast", "-e", script])
            .arg(ruby_language_name(language))
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private text string helper");
        assert!(
            output.status.success(),
            "ruby text string helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby text string output should be utf8")
            .trim_end_matches(['\r', '\n'])
            .to_string()
    }

    fn ruby_private_ts_node_value(value: &str) -> bool {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Object.new
          document.define_singleton_method(:language) { :ruby }
          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          target =
            case ARGV.fetch(0)
            when "nil"
              nil
            when "string"
              "value"
            when "normalized_node"
              Decomplex::Ast::Node.new(type: :LIT, children: [], first_lineno: 1, first_column: 0, last_lineno: 1, last_column: 1, text: "1")
            else
              abort "unknown ts_node? probe"
            end
          puts normalizer.send(:ts_node?, target) ? "true" : "false"
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args(["-I", "lib", "-r", "decomplex/ast", "-e", script])
            .arg(value)
            .output()
            .expect("run ruby private ts_node? value helper");
        assert!(
            output.status.success(),
            "ruby ts_node? value helper failed for {value}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby ts_node? value output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_regex_literal_value(value: &str) -> bool {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Object.new
          document.define_singleton_method(:language) { :ruby }
          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          target =
            case ARGV.fetch(0)
            when "nil"
              nil
            when "string"
              "value"
            when "normalized_node"
              Decomplex::Ast::Node.new(type: :LIT, children: [], first_lineno: 1, first_column: 0, last_lineno: 1, last_column: 1, text: "1")
            else
              abort "unknown regex_literal? probe"
            end
          puts normalizer.send(:regex_literal?, target) ? "true" : "false"
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args(["-I", "lib", "-r", "decomplex/ast", "-e", script])
            .arg(value)
            .output()
            .expect("run ruby private regex_literal? value helper");
        assert!(
            output.status.success(),
            "ruby regex_literal? value helper failed for {value}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby regex_literal? value output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_node_signature(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> Option<(String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby node signature temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby node signature temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(method, target)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private node signature helper");
        assert!(
            output.status.success(),
            "ruby node signature helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby node signature output should be json");
        if value.is_null() {
            return None;
        }
        let pair = value
            .as_array()
            .expect("ruby node signature should be an array");
        Some((
            pair[0]
                .as_str()
                .expect("node kind should be string")
                .to_string(),
            pair[1]
                .as_str()
                .expect("node text should be string")
                .to_string(),
        ))
    }

    fn ruby_private_inline_def_name_after_receiver(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> String {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby inline def name temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby inline def name temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          receiver = normalizer.send(:inline_def_receiver, target)
          puts normalizer.send(:inline_def_name_after_receiver, target, receiver).to_s
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby inline def name helper");
        assert!(
            output.status.success(),
            "ruby inline def name helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby inline def name output should be utf8")
            .trim()
            .to_string()
    }

    fn ruby_private_inline_parameter_begin_marker_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby inline_parameter_begin_marker temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby inline_parameter_begin_marker temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:inline_parameter_begin_marker, target)
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private inline_parameter_begin_marker helper");
        assert!(
            output.status.success(),
            "ruby inline_parameter_begin_marker helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby inline_parameter_begin_marker output should be json")
    }

    fn ruby_private_prepend_inline_parameter_begin_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        body: &Value,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby prepend_inline_parameter_begin temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby prepend_inline_parameter_begin temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            Decomplex::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |ts_node|
            if ts_node.respond_to?(:kind)
              target ||= ts_node if ts_node.kind == target_kind && ts_node.text.to_s == target_text
              ts_node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target

          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          body = node(JSON.parse(ARGV.fetch(3)))
          result = normalizer.send(:prepend_inline_parameter_begin, target, body)
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(body.to_string())
            .output()
            .expect("run ruby private prepend_inline_parameter_begin helper");
        assert!(
            output.status.success(),
            "ruby prepend_inline_parameter_begin helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby prepend_inline_parameter_begin output should be json")
    }

    fn ruby_private_local_or_call_for_name_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        name: &str,
        local: bool,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby local_or_call_for_name temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby local_or_call_for_name temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          require "set"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          name = ARGV.fetch(3)
          local = ARGV.fetch(4) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalizer.instance_variable_set(:@local_stack, local ? [Set[name]] : [])
          result = normalizer.send(:local_or_call_for_name, name, target)
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(name)
            .arg(if local { "true" } else { "false" })
            .output()
            .expect("run ruby private local_or_call_for_name helper");
        assert!(
            output.status.success(),
            "ruby local_or_call_for_name helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby local_or_call_for_name output should be json")
    }

    fn ruby_private_ruby_vcall_identifier_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        local_names: &[&str],
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby ruby_vcall_identifier temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby ruby_vcall_identifier temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          require "set"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalizer.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          puts normalizer.send(:ruby_vcall_identifier?, target)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(local_names.join(","))
            .output()
            .expect("run ruby private ruby_vcall_identifier? helper");
        assert!(
            output.status.success(),
            "ruby ruby_vcall_identifier? helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby ruby_vcall_identifier? output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_vcall_identifier_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        local_names: &[&str],
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby vcall_identifier temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby vcall_identifier temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          require "set"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalizer.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          puts normalizer.send(:vcall_identifier?, target)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(local_names.join(","))
            .output()
            .expect("run ruby private vcall_identifier? helper");
        assert!(
            output.status.success(),
            "ruby vcall_identifier? helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby vcall_identifier? output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_normalize_terminal_statement_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        local_names: &[&str],
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize_terminal_statement temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize_terminal_statement temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          require "set"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalizer.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          result = normalizer.send(:normalize_terminal_statement, target)
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(local_names.join(","))
            .output()
            .expect("run ruby private normalize_terminal_statement helper");
        assert!(
            output.status.success(),
            "ruby normalize_terminal_statement helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby normalize_terminal_statement output should be json")
    }

    fn ruby_private_node_list_signature(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> Vec<(String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby node list signature temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby node list signature temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = Array(normalizer.send(method, target))
          puts JSON.generate(result.map { |node| [node.kind, node.text.to_s] })
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby node list signature helper");
        assert!(
            output.status.success(),
            "ruby node list signature helper failed for {method}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby node list signature output should be json");
        value
            .as_array()
            .expect("ruby node list signature should be an array")
            .iter()
            .map(|item| {
                let item = item
                    .as_array()
                    .expect("ruby node list item should be an array");
                (
                    item[0]
                        .as_str()
                        .expect("ruby node list kind should be a string")
                        .to_string(),
                    item[1]
                        .as_str()
                        .expect("ruby node list text should be a string")
                        .to_string(),
                )
            })
            .collect()
    }

    fn ruby_private_dotted_call_parts(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Option<(String, String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby dotted_call_parts temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby dotted_call_parts temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          receiver, method = normalizer.send(:dotted_call_parts, target)
          if receiver
            puts JSON.generate([receiver.kind, receiver.text.to_s, method.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private dotted_call_parts helper");
        assert!(
            output.status.success(),
            "ruby dotted_call_parts helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby dotted_call_parts output should be json");
        if value.is_null() {
            return None;
        }
        let parts = value
            .as_array()
            .expect("ruby dotted_call_parts should be an array");
        Some((
            parts[0]
                .as_str()
                .expect("receiver kind should be string")
                .to_string(),
            parts[1]
                .as_str()
                .expect("receiver text should be string")
                .to_string(),
            parts[2]
                .as_str()
                .expect("method should be string")
                .to_string(),
        ))
    }

    fn ruby_private_member_parts(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Option<(String, String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby member_parts temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby member_parts temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          receiver, method = normalizer.send(:member_parts, target)
          if receiver
            puts JSON.generate([receiver.kind, receiver.text.to_s, method.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private member_parts helper");
        assert!(
            output.status.success(),
            "ruby member_parts helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby member_parts output should be json");
        if value.is_null() {
            return None;
        }
        let parts = value
            .as_array()
            .expect("ruby member_parts should be an array");
        Some((
            parts[0]
                .as_str()
                .expect("receiver kind should be string")
                .to_string(),
            parts[1]
                .as_str()
                .expect("receiver text should be string")
                .to_string(),
            parts[2]
                .as_str()
                .expect("method should be string")
                .to_string(),
        ))
    }

    fn ruby_private_named_field_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        field: &str,
    ) -> Option<(String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby named_field temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby named_field temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          field = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:named_field, target, field)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(field)
            .output()
            .expect("run ruby private named_field helper");
        assert!(
            output.status.success(),
            "ruby named_field helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value =
            serde_json::from_slice(&output.stdout).expect("ruby named_field output should be json");
        if value.is_null() {
            return None;
        }
        let pair = value
            .as_array()
            .expect("ruby named_field output should be an array");
        Some((
            pair[0]
                .as_str()
                .expect("named_field kind should be string")
                .to_string(),
            pair[1]
                .as_str()
                .expect("named_field text should be string")
                .to_string(),
        ))
    }

    fn ruby_private_branch_child_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        condition_kind: &str,
        condition_text: &str,
        index: usize,
    ) -> Option<(String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby branch_child temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby branch_child temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          condition_kind = ARGV.fetch(3)
          condition_text = ARGV.fetch(4)
          index = Integer(ARGV.fetch(5))
          target = nil
          condition = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              condition ||= node if node.kind == condition_kind && node.text.to_s == condition_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          abort "condition node not found" unless condition
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:branch_child, target, condition, index)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(condition_kind)
            .arg(condition_text)
            .arg(index.to_string())
            .output()
            .expect("run ruby private branch_child helper");
        assert!(
            output.status.success(),
            "ruby branch_child helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby branch_child output should be json");
        if value.is_null() {
            return None;
        }
        let pair = value
            .as_array()
            .expect("ruby branch_child output should be an array");
        Some((
            pair[0]
                .as_str()
                .expect("branch_child kind should be string")
                .to_string(),
            pair[1]
                .as_str()
                .expect("branch_child text should be string")
                .to_string(),
        ))
    }

    fn ruby_private_wrap_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        normalized_source: bool,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby wrap temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby wrap temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          normalized_source = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          source = if normalized_source
            normalizer.send(:wrap, :INNER, children: [], source: target)
          else
            target
          end
          result = normalizer.send(:wrap, :OUTER, children: [:child], source: source)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(if normalized_source { "true" } else { "false" })
            .output()
            .expect("run ruby private wrap helper");
        assert!(
            output.status.success(),
            "ruby wrap helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby wrap output should be json")
    }

    fn ruby_private_normalize_method_value(
        source: &str,
        language: Language,
        suffix: &str,
        method: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize method temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize method temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(method, target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(method)
            .output()
            .expect("run ruby private normalize method helper");
        assert!(
            output.status.success(),
            "ruby normalize method helper failed for {method}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby normalize method output should be json")
    }

    fn ruby_private_normalize_return_node_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        elide_symbol: bool,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize return node temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize return node temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          elide_symbol = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_return_node, target, elide_symbol: elide_symbol)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(if elide_symbol { "true" } else { "false" })
            .output()
            .expect("run ruby private normalize_return_node helper");
        assert!(
            output.status.success(),
            "ruby normalize_return_node helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby normalize_return_node output should be json")
    }

    fn ruby_private_normalize_body_nodes_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize body nodes temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize body nodes temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          if target_kind == "__root__"
            target = document.root
          else
            walk = lambda do |node|
              if node.respond_to?(:kind)
                target ||= node if node.kind == target_kind && node.text.to_s == target_text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(document.root)
          end
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_body_nodes, target.named_children, source: target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private normalize_body_nodes helper");
        assert!(
            output.status.success(),
            "ruby normalize_body_nodes helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby normalize_body_nodes output should be json")
    }

    fn ruby_private_inline_def_from_argument_list_nil_value(
        source: &str,
        language: Language,
        suffix: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby inline def argument nil temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby inline def argument nil temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:inline_def_from_argument_list, nil)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .output()
            .expect("run ruby private inline def argument nil helper");
        assert!(
            output.status.success(),
            "ruby inline def argument nil helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby inline def argument nil output should be json")
    }

    fn ruby_private_assignment_target_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby assignment target temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby assignment target temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:parent_node, target) || target
          right_raw = normalizer.send(:assignment_right, source)
          right = right_raw ? normalizer.send(:normalize_node, right_raw) : nil
          result = normalizer.send(:assignment_target, target, right, source: source)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private assignment target helper");
        assert!(
            output.status.success(),
            "ruby assignment target helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby assignment target output should be json")
    }

    fn ruby_private_normalize_multiple_assignment_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby multiple assignment temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby multiple assignment temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          left = normalizer.send(:assignment_left, target)
          right_raw = normalizer.send(:assignment_right, target)
          right = right_raw ? normalizer.send(:normalize_node, right_raw) : nil
          result = normalizer.send(:normalize_multiple_assignment, left, right, target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private multiple assignment helper");
        assert!(
            output.status.success(),
            "ruby multiple assignment helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby multiple assignment output should be json")
    }

    fn ruby_private_augmented_assignment_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        operator: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby augmented assignment value temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby augmented assignment value temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          operator = ARGV.fetch(3).to_sym
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:parent_node, target) || target
          right_raw = normalizer.send(:assignment_right, source)
          result = normalizer.send(:augmented_assignment_value, target, operator, right_raw, source)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(operator)
            .output()
            .expect("run ruby private augmented assignment value helper");
        assert!(
            output.status.success(),
            "ruby augmented assignment value helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby augmented assignment value output should be json")
    }

    fn ruby_private_logical_operator_assignment_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby logical operator assignment temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby logical operator assignment temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          left = normalizer.send(:assignment_left, target)
          right_raw = normalizer.send(:assignment_right, target)
          right = normalizer.send(:normalize_node, right_raw)
          operator = normalizer.send(:operator_assignment_operator, target)
          result = normalizer.send(:normalize_logical_operator_assignment, left, operator, right, source: target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private logical operator assignment helper");
        assert!(
            output.status.success(),
            "ruby logical operator assignment helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby logical operator assignment output should be json")
    }

    fn ruby_private_call_arguments_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        function_mode: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby call arguments temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby call arguments temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          function_mode = ARGV.fetch(3)
          target = nil
          fallback_target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              fallback_target ||= node if node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target ||= fallback_target
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          function =
            case function_mode
            when "auto"
              normalizer.send(:named_field, target, "function") ||
                normalizer.send(:named_field, target, "call") ||
                target.named_children.first
            when "none"
              nil
            else
              abort "unknown function mode: #{function_mode.inspect}"
            end
          result = normalizer.send(:call_arguments, target, function)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(function_mode)
            .output()
            .expect("run ruby private call arguments helper");
        assert!(
            output.status.success(),
            "ruby call arguments helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby call arguments output should be json")
    }

    fn ruby_private_normalize_call_without_block_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        block_mode: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize_call_without_block temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize_call_without_block temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          block_mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          block =
            case block_mode
            when "auto"
              normalizer.send(:call_block, target)
            when "none"
              nil
            else
              abort "unknown block mode: #{block_mode.inspect}"
            end
          result = normalizer.send(:normalize_call_without_block, target, block)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(block_mode)
            .output()
            .expect("run ruby private normalize_call_without_block helper");
        assert!(
            output.status.success(),
            "ruby normalize_call_without_block helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby normalize_call_without_block output should be json")
    }

    fn ruby_private_normalize_patterns_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby normalize_patterns temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby normalize_patterns temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_patterns, target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private normalize_patterns helper");
        assert!(
            output.status.success(),
            "ruby normalize_patterns helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby normalize_patterns output should be json")
    }

    fn ruby_private_command_arguments_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby command arguments temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby command arguments temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          fallback_target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              fallback_target ||= node if node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target ||= fallback_target
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:command_arguments, target)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private command arguments helper");
        assert!(
            output.status.success(),
            "ruby command arguments helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby command arguments output should be json")
    }

    fn ruby_private_const_for_nil_value(source: &str, language: Language, suffix: &str) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby const_for nil temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby const_for nil temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:const_for, nil)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .output()
            .expect("run ruby private const_for nil helper");
        assert!(
            output.status.success(),
            "ruby const_for nil helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("ruby const_for nil output should be json")
    }

    fn ruby_private_source_before_child_wrap_value(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        child_kind: &str,
        child_text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby source_before_child temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby source_before_child temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          child_kind = ARGV.fetch(3)
          child_text = ARGV.fetch(4)
          target = nil
          child = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              child ||= node if node.kind == child_kind && node.text.to_s == child_text
              node.named_children.each { |next_child| walk.call(next_child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          abort "child node not found" unless child
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:source_before_child, target, child)
          result = normalizer.send(:wrap, :OUTER, children: [], source: source)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(child_kind)
            .arg(child_text)
            .output()
            .expect("run ruby private source_before_child helper");
        assert!(
            output.status.success(),
            "ruby source_before_child helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby source_before_child output should be json")
    }

    fn ruby_private_source_from_nodes_value(
        source: &str,
        language: Language,
        suffix: &str,
        first_kind: &str,
        first_text: &str,
        last_kind: &str,
        last_text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby source_from_nodes temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby source_from_nodes temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          first_kind = ARGV.fetch(1)
          first_text = ARGV.fetch(2)
          last_kind = ARGV.fetch(3)
          last_text = ARGV.fetch(4)
          first_node = nil
          last_node = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              first_node ||= node if node.kind == first_kind && node.text.to_s == first_text
              last_node = node if node.kind == last_kind && node.text.to_s == last_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "first node not found: #{first_kind} #{first_text.inspect}" unless first_node
          abort "last node not found: #{last_kind} #{last_text.inspect}" unless last_node
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:source_from_nodes, first_node, last_node)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(first_kind)
            .arg(first_text)
            .arg(last_kind)
            .arg(last_text)
            .output()
            .expect("run ruby private source_from_nodes helper");
        assert!(
            output.status.success(),
            "ruby source_from_nodes helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby source_from_nodes output should be json")
    }

    fn ruby_private_source_from_normalized_nodes_value(
        source: &str,
        language: Language,
        suffix: &str,
        first_kind: &str,
        first_text: &str,
        last_kind: &str,
        last_text: &str,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby source_from_normalized_nodes temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby source_from_normalized_nodes temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          first_kind = ARGV.fetch(1)
          first_text = ARGV.fetch(2)
          last_kind = ARGV.fetch(3)
          last_text = ARGV.fetch(4)
          first_raw = nil
          last_raw = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              first_raw ||= node if node.kind == first_kind && node.text.to_s == first_text
              last_raw ||= node if node.kind == last_kind && node.text.to_s == last_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "first node not found" unless first_raw
          abort "last node not found" unless last_raw
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          first_node = normalizer.send(:wrap, :FIRST, children: [], source: first_raw)
          last_node = normalizer.send(:wrap, :LAST, children: [], source: last_raw)
          result = normalizer.send(:source_from_normalized_nodes, first_node, last_node)

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(first_kind)
            .arg(first_text)
            .arg(last_kind)
            .arg(last_text)
            .output()
            .expect("run ruby private source_from_normalized_nodes helper");
        assert!(
            output.status.success(),
            "ruby source_from_normalized_nodes helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby source_from_normalized_nodes output should be json")
    }

    fn ruby_private_dynamic_string_source_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Option<(String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby dynamic_string_source temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby dynamic_string_source temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          normalized = target.named_children.map { |child| [child, normalizer.send(:normalize_node, child)] }
          result = normalizer.send(:dynamic_string_source, normalized)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private dynamic_string_source helper");
        assert!(
            output.status.success(),
            "ruby dynamic_string_source helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby dynamic_string_source output should be json");
        if value.is_null() {
            return None;
        }
        let pair = value
            .as_array()
            .expect("ruby dynamic_string_source output should be an array");
        Some((
            pair[0]
                .as_str()
                .expect("dynamic_string_source kind should be string")
                .to_string(),
            pair[1]
                .as_str()
                .expect("dynamic_string_source text should be string")
                .to_string(),
        ))
    }

    fn ruby_private_operator_assignment_statement_parts_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Option<(String, String, String, String, String)> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby operator_assignment_statement_parts temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby operator_assignment_statement_parts temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          left, operator, right = normalizer.send(:operator_assignment_statement_parts, target)
          if left && operator && right
            puts JSON.generate([left.kind, left.text.to_s, operator.to_s, right.kind, right.text.to_s])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private operator_assignment_statement_parts helper");
        assert!(
            output.status.success(),
            "ruby operator_assignment_statement_parts helper failed for {language:?} {kind:?} {text:?}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby operator_assignment_statement_parts output should be json");
        if value.is_null() {
            return None;
        }
        let parts = value
            .as_array()
            .expect("ruby operator_assignment_statement_parts output should be an array");
        Some((
            parts[0]
                .as_str()
                .expect("operator_assignment left kind should be string")
                .to_string(),
            parts[1]
                .as_str()
                .expect("operator_assignment left text should be string")
                .to_string(),
            parts[2]
                .as_str()
                .expect("operator_assignment operator should be string")
                .to_string(),
            parts[3]
                .as_str()
                .expect("operator_assignment right kind should be string")
                .to_string(),
            parts[4]
                .as_str()
                .expect("operator_assignment right text should be string")
                .to_string(),
        ))
    }

    fn ruby_private_modifier_parts_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> Option<((String, String), (String, String))> {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby modifier_parts temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby modifier_parts temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          action, condition = normalizer.send(:modifier_parts, target)
          if action && condition
            puts JSON.generate([[action.kind, action.text.to_s], [condition.kind, condition.text.to_s]])
          else
            puts "null"
          end
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private modifier_parts helper");
        assert!(
            output.status.success(),
            "ruby modifier_parts helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value = serde_json::from_slice(&output.stdout)
            .expect("ruby modifier_parts output should be json");
        if value.is_null() {
            return None;
        }
        let pairs = value
            .as_array()
            .expect("ruby modifier_parts output should be an array");
        let action = pairs[0]
            .as_array()
            .expect("modifier_parts action should be an array");
        let condition = pairs[1]
            .as_array()
            .expect("modifier_parts condition should be an array");
        Some((
            (
                action[0]
                    .as_str()
                    .expect("modifier_parts action kind should be string")
                    .to_string(),
                action[1]
                    .as_str()
                    .expect("modifier_parts action text should be string")
                    .to_string(),
            ),
            (
                condition[0]
                    .as_str()
                    .expect("modifier_parts condition kind should be string")
                    .to_string(),
                condition[1]
                    .as_str()
                    .expect("modifier_parts condition text should be string")
                    .to_string(),
            ),
        ))
    }

    fn ruby_private_visibility_inline_def_statement_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby visibility_inline_def_statement temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby visibility_inline_def_statement temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:visibility_inline_def_statement?, target, target.named_children.first)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .output()
            .expect("run ruby private visibility_inline_def_statement helper");
        assert!(
            output.status.success(),
            "ruby visibility_inline_def_statement helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby visibility_inline_def_statement output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_drop_trailing_nil_statement_value(input: &Value) -> Value {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            Decomplex::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          result = normalizer.send(:drop_trailing_nil_statement, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(input.to_string())
            .output()
            .expect("run ruby private drop_trailing_nil_statement helper");
        assert!(
            output.status.success(),
            "ruby drop_trailing_nil_statement helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby drop_trailing_nil_statement output should be json")
    }

    fn ruby_private_elide_tail_returns_value(input: &Value, ruby: bool) -> Value {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            Decomplex::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          adapter = if ARGV.fetch(1) == "ruby"
                    Decomplex::Ast::RubyTreeSitterNormalizationAdapter.new(nil)
                    else
                    Decomplex::Ast::TreeSitterNormalizationAdapter.new(nil)
                    end
          normalizer.instance_variable_set(:@normalization_adapter, adapter)
          result = normalizer.send(:elide_tail_returns, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(input.to_string())
            .arg(if ruby { "ruby" } else { "other" })
            .output()
            .expect("run ruby private elide_tail_returns helper");
        assert!(
            output.status.success(),
            "ruby elide_tail_returns helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby elide_tail_returns output should be json")
    }

    fn ruby_private_elide_implicit_nil_body_value(input: &Value, ruby: bool) -> Value {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            Decomplex::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          adapter = if ARGV.fetch(1) == "ruby"
                    Decomplex::Ast::RubyTreeSitterNormalizationAdapter.new(nil)
                    else
                    Decomplex::Ast::TreeSitterNormalizationAdapter.new(nil)
                    end
          normalizer.instance_variable_set(:@normalization_adapter, adapter)
          result = normalizer.send(:elide_implicit_nil_body, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(input.to_string())
            .arg(if ruby { "ruby" } else { "other" })
            .output()
            .expect("run ruby private elide_implicit_nil_body helper");
        assert!(
            output.status.success(),
            "ruby elide_implicit_nil_body helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby elide_implicit_nil_body output should be json")
    }

    fn ruby_private_prepend_rescue_exception_assignment_value(
        source: &str,
        body: &Value,
        assignment: &Value,
    ) -> Value {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("create ruby prepend rescue temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby prepend rescue temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            Decomplex::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(Decomplex::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          body = node(JSON.parse(ARGV.fetch(1)))
          assignment = node(JSON.parse(ARGV.fetch(2)))
          result = normalizer.send(:prepend_rescue_exception_assignment, body, assignment)
          puts JSON.generate(value(result))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", "ruby")
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(body.to_string())
            .arg(assignment.to_string())
            .output()
            .expect("run ruby private prepend_rescue_exception_assignment helper");
        assert!(
            output.status.success(),
            "ruby prepend_rescue_exception_assignment helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout)
            .expect("ruby prepend_rescue_exception_assignment output should be json")
    }

    fn ruby_private_symbol_literal_node_predicate(
        node_type: Option<&str>,
        child_kind: Option<&str>,
    ) -> bool {
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          def child(kind)
            case kind
            when "symbol"
              :value
            when "string"
              "value"
            when "node"
              Decomplex::Ast::Node.new(
                type: :NIL,
                children: [],
                first_lineno: 1,
                first_column: 0,
                last_lineno: 1,
                last_column: 1,
                text: "NIL"
              )
            when "nil"
              nil
            else
              nil
            end
          end

          node_type = ARGV.fetch(0)
          child_kind = ARGV.fetch(1)
          target = if node_type == "none"
                     nil
                   else
                     children = child_kind == "none" ? [] : [child(child_kind)]
                     Decomplex::Ast::Node.new(
                       type: node_type.to_sym,
                       children: children,
                       first_lineno: 1,
                       first_column: 0,
                       last_lineno: 1,
                       last_column: 1,
                       text: node_type
                     )
                   end
          normalizer = Decomplex::Ast::TreeSitterNormalizer.allocate
          puts normalizer.send(:symbol_literal_node?, target)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .args(["-I", "lib", "-r", "decomplex/ast", "-e", script])
            .arg(node_type.unwrap_or("none"))
            .arg(child_kind.unwrap_or("none"))
            .output()
            .expect("run ruby private symbol_literal_node? helper");
        assert!(
            output.status.success(),
            "ruby symbol_literal_node? helper failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby symbol_literal_node? output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_same_ts_node_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        left_kind: &str,
        left_text: &str,
        left_index: usize,
        right_kind: &str,
        right_text: &str,
        right_index: usize,
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby same_ts_node temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby same_ts_node temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          left_kind = ARGV.fetch(1)
          left_text = ARGV.fetch(2)
          left_index = ARGV.fetch(3).to_i
          right_kind = ARGV.fetch(4)
          right_text = ARGV.fetch(5)
          right_index = ARGV.fetch(6).to_i

          def matches(root, kind, text)
            found = []
            walk = lambda do |node|
              if node.respond_to?(:kind)
                found << node if node.kind == kind && node.text.to_s == text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(root)
            found
          end

          left = matches(document.root, left_kind, left_text).fetch(left_index)
          right = matches(document.root, right_kind, right_text).fetch(right_index)
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:same_ts_node?, left, right)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(left_kind)
            .arg(left_text)
            .arg(left_index.to_string())
            .arg(right_kind)
            .arg(right_text)
            .arg(right_index.to_string())
            .output()
            .expect("run ruby private same_ts_node? helper");
        assert!(
            output.status.success(),
            "ruby same_ts_node? helper failed for {language:?}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby same_ts_node? output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_parent_named_child_predicate(
        source: &str,
        language: Language,
        suffix: &str,
        parent_kind: &str,
        parent_text: &str,
        parent_index: usize,
        child_kind: &str,
        child_text: &str,
        child_index: usize,
    ) -> bool {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby parent_named_child temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby parent_named_child temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          parent_kind = ARGV.fetch(1)
          parent_text = ARGV.fetch(2)
          parent_index = ARGV.fetch(3).to_i
          child_kind = ARGV.fetch(4)
          child_text = ARGV.fetch(5)
          child_index = ARGV.fetch(6).to_i

          def matches(root, kind, text)
            found = []
            walk = lambda do |node|
              if node.respond_to?(:kind)
                found << node if node.kind == kind && node.text.to_s == text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(root)
            found
          end

          parent = matches(document.root, parent_kind, parent_text).fetch(parent_index)
          child = matches(document.root, child_kind, child_text).fetch(child_index)
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:parent_named_child?, parent, child)
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(parent_kind)
            .arg(parent_text)
            .arg(parent_index.to_string())
            .arg(child_kind)
            .arg(child_text)
            .arg(child_index.to_string())
            .output()
            .expect("run ruby private parent_named_child? helper");
        assert!(
            output.status.success(),
            "ruby parent_named_child? helper failed for {language:?}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("ruby parent_named_child? output should be utf8")
            .trim()
            == "true"
    }

    fn ruby_private_node_key_signature(
        source: &str,
        language: Language,
        suffix: &str,
        kind: &str,
        text: &str,
        index: usize,
    ) -> (String, usize, usize) {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("create ruby node_key temp source file");
        file.write_all(source.as_bytes())
            .expect("write ruby node_key temp source file");
        let decomplex_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("decomplex rust dir should have gem parent");
        let script = r#"
          document = Decomplex::Syntax.parse(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target_index = ARGV.fetch(3).to_i
          found = []
          walk = lambda do |node|
            if node.respond_to?(:kind)
              found << node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target = found.fetch(target_index)
          normalizer = Decomplex::Ast::TreeSitterNormalizer.new(document)
          puts JSON.generate(normalizer.send(:node_key, target))
        "#;
        let output = Command::new("ruby")
            .current_dir(decomplex_dir)
            .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
            .args([
                "-I",
                "lib",
                "-r",
                "decomplex/ast",
                "-r",
                "decomplex/syntax",
                "-r",
                "json",
                "-e",
                script,
            ])
            .arg(file.path())
            .arg(kind)
            .arg(text)
            .arg(index.to_string())
            .output()
            .expect("run ruby private node_key helper");
        assert!(
            output.status.success(),
            "ruby node_key helper failed for {language:?}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let value: Value =
            serde_json::from_slice(&output.stdout).expect("ruby node_key output should be json");
        let key = value
            .as_array()
            .expect("ruby node_key output should be an array");
        (
            key[0]
                .as_str()
                .expect("node_key kind should be string")
                .to_string(),
            key[1]
                .as_u64()
                .expect("node_key start byte should be integer") as usize,
            key[2]
                .as_u64()
                .expect("node_key end byte should be integer") as usize,
        )
    }

    #[test]
    fn tree_normalizer_new_initializes_empty_state() {
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

        assert_eq!(normalizer.source, "");
        assert_eq!(normalizer.language, Language::Ruby);
        assert!(normalizer.local_stack.is_empty());
        assert_eq!(normalizer.root_span, None);
    }

    #[test]
    fn normalize_root_matches_ruby_across_tree_normalizer_languages() {
        for (source, language, suffix) in [
            (
                "class C\n  def each(value)\n    yield value\n    case value\n    when 1 then :one\n    else :other\n    end\n  end\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "def gen(value):\n    yield value\n    other()\n",
                Language::Python,
                ".py",
            ),
            (
                "function f(value: number) { switch (value) { case 1: one(); break; default: other(); } return value ? one() : other(); }\n",
                Language::TypeScript,
                ".ts",
            ),
            (
                "function f(value)\n  if value then\n    one()\n  else\n    other()\n  end\n  return value\nend\n",
                Language::Lua,
                ".lua",
            ),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn tree_normalizer_yield_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield :item\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield :item",
            ),
            (
                "def each\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield item",
            ),
            (
                "def gen():\n    yield from items\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield from items",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "block",
                "yield item\n    other()",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.yield_statement(node),
                ruby_private_predicate(source, language, suffix, "yield_statement?", kind, text),
                "yield_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn yield_argument_list_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield(:item)\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "(:item)",
            ),
            (
                "def each\n  yield :item\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":item",
            ),
            (
                "def call\n  foo(:item)\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "(:item)",
            ),
            (
                "yield_value(value)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(value)",
            ),
            (
                "yield(value);\n",
                Language::TypeScript,
                ".ts",
                "parenthesized_expression",
                "(value)",
            ),
            (
                "coroutine.yield(value)\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.yield_argument_list(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "yield_argument_list?",
                    kind,
                    text
                ),
                "yield_argument_list? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn yield_argument_nodes_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield(:item)\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "(:item)",
            ),
            (
                "def each\n  yield nil\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "nil",
            ),
            (
                "def each\n  yield item, other\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "item, other",
            ),
            (
                "yield_value(value)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(value)",
            ),
            (
                "yield(value);\n",
                Language::TypeScript,
                ".ts",
                "parenthesized_expression",
                "(value)",
            ),
            (
                "coroutine.yield(value)\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = Value::Array(
                normalizer
                    .yield_argument_nodes(node)
                    .iter()
                    .map(node_value)
                    .collect(),
            );

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "yield_argument_nodes",
                    kind,
                    text
                ),
                "yield_argument_nodes mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn yield_inline_arguments_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield item",
            ),
            (
                "function* gen() { yield item; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "yield item;",
            ),
            (
                "coroutine.yield(item)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "coroutine.yield(item)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = Value::Array(
                normalizer
                    .yield_inline_arguments(node)
                    .iter()
                    .map(node_value)
                    .collect(),
            );

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "yield_inline_arguments",
                    kind,
                    text
                ),
                "yield_inline_arguments mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_yield_argument_list_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield(:item)\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "(:item)",
            ),
            (
                "def each\n  yield :item\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":item",
            ),
            (
                "def each\n  yield nil\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "nil",
            ),
            (
                "yield_value(value)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = node_value(&normalizer.normalize_yield_argument_list(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_yield_argument_list",
                    kind,
                    text
                ),
                "normalize_yield_argument_list mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_yield_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield",
            ),
            (
                "def each\n  yield item\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield item",
            ),
            (
                "def each\n  yield nil\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield nil",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield item",
            ),
            (
                "function* gen() { yield item; }\n",
                Language::TypeScript,
                ".ts",
                "yield_expression",
                "yield item",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = node_value(&normalizer.normalize_yield(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_yield",
                    kind,
                    text
                ),
                "normalize_yield mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_yield_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield",
            ),
            (
                "def each\n  yield item\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield item",
            ),
            (
                "def each\n  yield nil\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield nil",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield item",
            ),
            (
                "def gen():\n    yield from items\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield from items",
            ),
            (
                "function* gen() { yield item; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "yield item;",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = node_value(&normalizer.normalize_yield_statement(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_yield_statement",
                    kind,
                    text
                ),
                "normalize_yield_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_node_dispatch_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def each\n  yield item\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "yield item",
            ),
            (
                "def check\n  !flag\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "!flag",
            ),
            (
                "def gen():\n    yield item\n    other()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "yield item",
            ),
            (
                "switch (value) { case 1: one(); default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); default: other(); }",
            ),
            (
                "if value then one() else other() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value then one() else other() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_node(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_node",
                    kind,
                    text
                ),
                "normalize_node mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn python_yield_statement_in_multi_statement_block_matches_ruby_ast() {
        let source = "def gen():\n    yield item\n    other()\n";
        assert_ruby_parity(source, Language::Python, ".py");

        let root = parse_language_source(source, Language::Python, ".py");
        let defn = first_node(&root, "DEFN", "def gen():\n    yield item\n    other()");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(child_types(body), vec!["YIELD", "EXPRESSION_STATEMENT"]);
    }

    #[test]
    fn tree_normalizer_super_statement_matches_ruby_private_predicate() {
        for (source, kind, text) in [
            (
                "class Child < Parent\n  def call\n    super\n  end\nend\n",
                "body_statement",
                "super",
            ),
            (
                "class Child < Parent\n  def call\n    super :item\n  end\nend\n",
                "body_statement",
                "super :item",
            ),
            (
                "class Child < Parent\n  def call\n    value\n  end\nend\n",
                "body_statement",
                "value",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

            assert_eq!(
                normalizer.super_statement(node),
                ruby_private_predicate(
                    source,
                    Language::Ruby,
                    ".rb",
                    "super_statement?",
                    kind,
                    text
                ),
                "super_statement? mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_super_statement_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "class Child < Parent\n  def call\n    super\n  end\nend\n",
                "body_statement",
                "super",
            ),
            (
                "class Child < Parent\n  def call\n    super :item\n  end\nend\n",
                "body_statement",
                "super :item",
            ),
            (
                "class Child < Parent\n  def call\n    super value\n  end\nend\n",
                "body_statement",
                "super value",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = node_value(&normalizer.normalize_super_statement(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_super_statement",
                    kind,
                    text
                ),
                "normalize_super_statement mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_super_statement_normalization_matches_ruby_ast() {
        let source = "class Child < Parent\n  def bare\n    super\n  end\n  def with_arg\n    super :item\n  end\nend\n";
        assert_ruby_parity(source, Language::Ruby, ".rb");

        let root = parse_language_source(source, Language::Ruby, ".rb");
        let bare = first_node(&root, "SUPER", "super");
        let with_arg = first_node(&root, "SUPER", "super :item");

        assert_eq!(bare.children, vec![Child::Nil]);
        assert_eq!(child_types(with_arg), vec!["LIST"]);
        assert_eq!(child_types(child_node(with_arg, 0)), vec!["LIT"]);
    }

    #[test]
    fn tree_normalizer_argument_list_element_reference_matches_ruby_private_predicate() {
        for (source, text) in [
            ("def indexed\n  return items[0]\nend\n", "items[0]"),
            ("def indexed\n  return obj.foo[0]\nend\n", "obj.foo[0]"),
            ("def indexed\n  return [0]\nend\n", "[0]"),
            (
                "def indexed\n  return items[0], other\nend\n",
                "items[0], other",
            ),
            ("def indexed\n  return items[]\nend\n", "items[]"),
            (
                "def indexed\n  return items[0] { nope }\nend\n",
                "items[0] { nope }",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, "argument_list", text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

            assert_eq!(
                normalizer.argument_list_element_reference(node),
                ruby_private_predicate(
                    source,
                    Language::Ruby,
                    ".rb",
                    "argument_list_element_reference?",
                    "argument_list",
                    text
                ),
                "argument_list_element_reference? mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn normalize_argument_list_element_reference_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def indexed\n  return items[0]\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "items[0]",
            ),
            (
                "def indexed\n  return obj.foo[0]\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "obj.foo[0]",
            ),
            (
                "def indexed\n  return [0]\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "[0]",
            ),
            (
                "def indexed\n  return items[0], other\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "items[0], other",
            ),
            (
                "def indexed\n  return items[0] { nope }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "items[0] { nope }",
            ),
            (
                "def indexed():\n    return foo(items[0])\n",
                Language::Python,
                ".py",
                "argument_list",
                "(items[0])",
            ),
            (
                "function indexed(){ return foo(items[0]); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(items[0])",
            ),
            (
                "function indexed() return foo(items[0]) end\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(items[0])",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_argument_list_element_reference(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_argument_list_element_reference",
                    kind,
                    text
                ),
                "normalize_argument_list_element_reference mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn dynamic_scope_rewrites_locals_without_crossing_scope_boundaries() {
        let inner_assignment = test_node("LASGN", vec![Child::Symbol("inner".to_string())]);
        let node = test_node(
            "BLOCK",
            vec![
                Child::Node(Box::new(test_node(
                    "LASGN",
                    vec![Child::Symbol("value".to_string())],
                ))),
                Child::Node(Box::new(test_node(
                    "LVAR",
                    vec![Child::Symbol("value".to_string())],
                ))),
                Child::Node(Box::new(test_node(
                    "DEFN",
                    vec![
                        Child::Symbol("nested".to_string()),
                        Child::Node(Box::new(test_node(
                            "SCOPE",
                            vec![
                                Child::Nil,
                                Child::Nil,
                                Child::Node(Box::new(inner_assignment)),
                            ],
                        ))),
                    ],
                ))),
            ],
        );

        let result = super::dynamic_scope(node);

        assert_eq!(child_node(&result, 0).r#type, "DASGN");
        assert_eq!(child_node(&result, 1).r#type, "DVAR");
        let nested = child_node(&result, 2);
        assert_eq!(nested.r#type, "DEFN");
        let nested_scope = child_node(nested, 1);
        assert_eq!(nested_scope.r#type, "SCOPE");
        assert_eq!(child_node(nested_scope, 2).r#type, "LASGN");
    }

    #[test]
    fn link_when_chain_sets_next_arm_and_pads_short_when_nodes() {
        let fallback = test_node("ELSE", Vec::new());
        let first = test_node(
            "WHEN",
            vec![
                Child::Symbol("patterns".to_string()),
                Child::Nil,
                Child::Nil,
            ],
        );
        let second = test_node(
            "WHEN",
            vec![
                Child::Symbol("patterns".to_string()),
                Child::Nil,
                Child::Nil,
            ],
        );
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

        let result = normalizer
            .link_when_chain(vec![first, second], Some(fallback))
            .expect("expected linked when chain");

        assert_eq!(result.r#type, "WHEN");
        let next = child_node(&result, 2);
        assert_eq!(next.r#type, "WHEN");
        assert_eq!(child_node(next, 2).r#type, "ELSE");

        let short = test_node("WHEN", vec![Child::Symbol("patterns".to_string())]);
        let fallback = test_node("ELSE", Vec::new());
        let result = normalizer
            .link_when_chain(vec![short], Some(fallback))
            .expect("expected padded when chain");

        assert_eq!(result.children.len(), 3);
        assert_eq!(result.children[1], Child::Nil);
        assert_eq!(child_node(&result, 2).r#type, "ELSE");
    }

    #[test]
    fn link_rescue_chain_sets_next_rescue_and_pads_short_resbody_nodes() {
        let first = test_node(
            "RESBODY",
            vec![
                Child::Symbol("exceptions".to_string()),
                Child::Nil,
                Child::Nil,
            ],
        );
        let second = test_node(
            "RESBODY",
            vec![
                Child::Symbol("exceptions".to_string()),
                Child::Nil,
                Child::Nil,
            ],
        );
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

        let result = normalizer
            .link_rescue_chain(vec![first, second])
            .expect("expected linked rescue chain");

        assert_eq!(result.r#type, "RESBODY");
        let next = child_node(&result, 2);
        assert_eq!(next.r#type, "RESBODY");
        assert_eq!(next.children[2], Child::Nil);

        let short = test_node("RESBODY", vec![Child::Symbol("exceptions".to_string())]);
        let result = normalizer
            .link_rescue_chain(vec![short])
            .expect("expected padded rescue chain");

        assert_eq!(result.children.len(), 3);
        assert_eq!(result.children[1], Child::Nil);
        assert_eq!(result.children[2], Child::Nil);
    }

    #[test]
    fn infix_statement_parts_extracts_allowed_wrapper_parts() {
        let source = "def calc\n  left + right\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let body = first_raw_node(tree.root_node(), source, "body_statement", "left + right");
        let binary = first_raw_node(tree.root_node(), source, "binary", "left + right");

        assert_eq!(
            infix_parts_text(&normalizer, body, source),
            Some(("left".to_string(), "+".to_string(), "right".to_string()))
        );
        assert_eq!(infix_parts_text(&normalizer, binary, source), None);

        let source = "def calc\n  return left + right\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let args = first_raw_node(tree.root_node(), source, "argument_list", "left + right");
        assert_eq!(
            infix_parts_text(&normalizer, args, source),
            Some(("left".to_string(), "+".to_string(), "right".to_string()))
        );

        let source = "def calc\n  left && right\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let boolean = first_raw_node(tree.root_node(), source, "body_statement", "left && right");
        assert_eq!(infix_parts_text(&normalizer, boolean, source), None);
    }

    #[test]
    fn infix_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right",
            ),
            (
                "def calc\n  return left + right\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "left + right",
            ),
            (
                "def calc\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && right",
            ),
            (
                "const value = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.infix_statement(node),
                ruby_private_predicate(source, language, suffix, "infix_statement?", kind, text),
                "infix_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_infix_statement_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def calc\n  left + right\nend\n",
                "body_statement",
                "left + right",
            ),
            (
                "def calc\n  return left + right\nend\n",
                "argument_list",
                "left + right",
            ),
            (
                "def match\n  value =~ /left/\nend\n",
                "body_statement",
                "value =~ /left/",
            ),
            (
                "def match\n  value =~ pattern\nend\n",
                "body_statement",
                "value =~ pattern",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_infix_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_infix_statement",
                    kind,
                    text
                ),
                "normalize_infix_statement mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn regex_literal_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "value =~ /left/\n",
                Language::Ruby,
                ".rb",
                "regex",
                "/left/",
            ),
            (
                "value = \"left\"\n",
                Language::Ruby,
                ".rb",
                "string",
                "\"left\"",
            ),
            (
                "const pattern = /left/;\n",
                Language::TypeScript,
                ".ts",
                "regex",
                "/left/",
            ),
            (
                "pattern = r\"left\"\n",
                Language::Python,
                ".py",
                "string",
                "r\"left\"",
            ),
            (
                "local pattern = \"left\"\n",
                Language::Lua,
                ".lua",
                "string_content",
                "left",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.regex_literal(Some(node)),
                ruby_private_predicate(source, language, suffix, "regex_literal?", kind, text),
                "regex_literal? mismatch for {language:?} {kind} {text:?}"
            );
        }

        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        assert_eq!(
            normalizer.regex_literal(None),
            ruby_private_regex_literal_value("nil")
        );
        assert!(!ruby_private_regex_literal_value("string"));
        assert!(!ruby_private_regex_literal_value("normalized_node"));
    }

    #[test]
    fn argument_list_unary_not_matches_ruby_private_predicate() {
        for (line, text) in [
            ("return !flag", "!flag"),
            ("return !!flag", "!!flag"),
            ("return flag", "flag"),
            ("return !flag, other", "!flag, other"),
            ("return (!flag)", "(!flag)"),
            ("return not flag", "not flag"),
        ] {
            let source = format!("def check\n  {line}\nend\n");
            let tree = raw_tree(&source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), &source, "argument_list", text);
            let normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);

            assert_eq!(
                normalizer.argument_list_unary_not(node),
                ruby_private_predicate(
                    &source,
                    Language::Ruby,
                    ".rb",
                    "argument_list_unary_not?",
                    "argument_list",
                    text
                ),
                "argument_list_unary_not? mismatch for {line:?}"
            );
        }
    }

    #[test]
    fn normalize_argument_list_unary_not_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  return !flag\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "!flag",
            ),
            (
                "def check\n  return !!flag\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "!!flag",
            ),
            (
                "def check\n  return flag\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "flag",
            ),
            (
                "def check\n  return !flag, other\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "!flag, other",
            ),
            (
                "def check():\n    return foo(not flag)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(not flag)",
            ),
            (
                "function check(){ return foo(!flag); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(!flag)",
            ),
            (
                "function check() return foo(not flag) end\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(not flag)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_argument_list_unary_not(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_argument_list_unary_not",
                    kind,
                    text
                ),
                "normalize_argument_list_unary_not mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn unary_not_statement_matches_ruby_private_predicate() {
        for (line, text) in [
            ("!flag", "!flag"),
            ("!!flag", "!!flag"),
            ("flag", "flag"),
            ("!flag; other", "!flag; other"),
            ("(!flag)", "(!flag)"),
            ("not flag", "not flag"),
        ] {
            let source = format!("def check\n  {line}\nend\n");
            let tree = raw_tree(&source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), &source, "body_statement", text);
            let normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);

            assert_eq!(
                normalizer.unary_not_statement(node),
                ruby_private_predicate(
                    &source,
                    Language::Ruby,
                    ".rb",
                    "unary_not_statement?",
                    "body_statement",
                    text
                ),
                "unary_not_statement? mismatch for {line:?}"
            );
        }
    }

    #[test]
    fn unary_not_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "!flag",
            ),
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "!!flag",
            ),
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "-flag",
            ),
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "not flag",
            ),
            (
                "function check(flag: boolean) { return !flag; }\n",
                Language::TypeScript,
                ".ts",
                "unary_expression",
                "!flag",
            ),
            (
                "if not flag:\n    pass\n",
                Language::Python,
                ".py",
                "not_operator",
                "not flag",
            ),
            (
                "if not flag then end\n",
                Language::Lua,
                ".lua",
                "unary_expression",
                "not flag",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.unary_not_expression(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "unary_not_expression?",
                    kind,
                    text
                ),
                "unary_not_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_unary_not_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "!flag",
            ),
            (
                "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "!!flag",
            ),
            (
                "function check(flag: boolean) { return !flag; }\n",
                Language::TypeScript,
                ".ts",
                "unary_expression",
                "!flag",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_unary_not(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_unary_not",
                    kind,
                    text
                ),
                "normalize_unary_not mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_unary_not_statement_matches_ruby_private_method() {
        for (line, text) in [("!flag", "!flag"), ("!!flag", "!!flag")] {
            let source = format!("def check\n  {line}\nend\n");
            let tree = raw_tree(&source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), &source, "body_statement", text);
            let mut normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);
            let rust = normalizer
                .normalize_unary_not_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    &source,
                    Language::Ruby,
                    ".rb",
                    "normalize_unary_not_statement",
                    "body_statement",
                    text
                ),
                "normalize_unary_not_statement mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn unary_minus_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  -flag\n  !flag\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "-flag",
            ),
            (
                "def check\n  -flag\n  !flag\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "!flag",
            ),
            (
                "function check(value: number) { return -value; }\n",
                Language::TypeScript,
                ".ts",
                "unary_expression",
                "-value",
            ),
            (
                "x = -value\n",
                Language::Python,
                ".py",
                "unary_operator",
                "-value",
            ),
            (
                "local x = -value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "-value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.unary_minus_expression(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "unary_minus_expression?",
                    kind,
                    text
                ),
                "unary_minus_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_unary_minus_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  -1\n  -flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "-1",
            ),
            (
                "def check\n  -1\n  -flag\nend\n",
                Language::Ruby,
                ".rb",
                "unary",
                "-flag",
            ),
            (
                "function check(value: number) { return -value; }\n",
                Language::TypeScript,
                ".ts",
                "unary_expression",
                "-value",
            ),
            (
                "x = -value\n",
                Language::Python,
                ".py",
                "unary_operator",
                "-value",
            ),
            (
                "local x = -value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "-value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_unary_minus(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_unary_minus",
                    kind,
                    text
                ),
                "normalize_unary_minus mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn binary_operator_matches_ruby_private_helper() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left + right\n  left && right\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left + right",
            ),
            (
                "def calc\n  left + right\n  left && right\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left && right",
            ),
            (
                "def calc\n  left + right\n  left && right\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right\n  left && right\n  value",
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right && other",
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left + right and other",
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left + right and other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right and other",
            ),
            (
                "local value = left + right and other\n",
                Language::Lua,
                ".lua",
                "binary_expression",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.binary_operator(node).unwrap_or_default(),
                ruby_private_string(source, language, suffix, "binary_operator", kind, text),
                "binary_operator mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn boolean_operator_matches_ruby_private_helper() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left && right\n  left || right\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left && right",
            ),
            (
                "def calc\n  left && right\n  left || right\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left || right",
            ),
            (
                "def calc\n  left && right\n  left || right\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left + right",
            ),
            (
                "const value = left && right || other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left && right",
            ),
            (
                "const value = left && right || other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left && right || other",
            ),
            (
                "value = left and right or other\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left and right",
            ),
            (
                "value = left and right or other\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left and right or other",
            ),
            (
                "local value = left and right or other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left and right or other",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.boolean_operator(node).unwrap_or_default(),
                ruby_private_string(source, language, suffix, "boolean_operator", kind, text),
                "boolean_operator mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn comparison_operator_matches_ruby_private_helper() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left == right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left == right",
            ),
            (
                "def calc\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right",
            ),
            (
                "const value = left === right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left === right",
            ),
            (
                "const value = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left == right\n",
                Language::Python,
                ".py",
                "comparison_operator",
                "left == right",
            ),
            (
                "value = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left == right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left == right",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.comparison_operator(node).unwrap_or_default(),
                ruby_private_string(source, language, suffix, "comparison_operator", kind, text),
                "comparison_operator mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn comparison_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left == right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left == right",
            ),
            (
                "const value = left === right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left === right",
            ),
            (
                "const value = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left == right\n",
                Language::Python,
                ".py",
                "comparison_operator",
                "left == right",
            ),
            (
                "value = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left == right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left == right",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.comparison_expression(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "comparison_expression?",
                    kind,
                    text
                ),
                "comparison_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn comparison_expression_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("value = left == right\n", Language::Python, ".py"),
            (
                "const value = left === right;\n",
                Language::TypeScript,
                ".ts",
            ),
            ("local value = left == right\n", Language::Lua, ".lua"),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn normalize_comparison_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left == right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left == right",
            ),
            (
                "value = left == right\n",
                Language::Python,
                ".py",
                "comparison_operator",
                "left == right",
            ),
            (
                "const value = left === right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left === right",
            ),
            (
                "local value = left == right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left == right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_comparison(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_comparison",
                    kind,
                    text
                ),
                "normalize_comparison mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn boolean_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && right",
            ),
            (
                "def calc\n  left or right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left or right",
            ),
            (
                "def calc\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right",
            ),
            (
                "foo(left && right)\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "(left && right)",
            ),
            (
                "value = left and right\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left and right",
            ),
            (
                "local value = left and right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left and right",
            ),
            (
                "const value = left && right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left && right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.boolean_statement(node),
                ruby_private_predicate(source, language, suffix, "boolean_statement?", kind, text),
                "boolean_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn boolean_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && right",
            ),
            (
                "def calc\n  left && right\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left && right",
            ),
            (
                "def calc\n  left && right\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left + right",
            ),
            (
                "const value = left && right;\nconst other = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left && right",
            ),
            (
                "const value = left && right;\nconst other = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left and right\nother = left + right\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left and right",
            ),
            (
                "value = left and right\nother = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left and right\nlocal other = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left and right",
            ),
            (
                "local value = left and right\nlocal other = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.boolean_expression(node),
                ruby_private_predicate(source, language, suffix, "boolean_expression?", kind, text),
                "boolean_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_boolean_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && right",
            ),
            (
                "def calc\n  left || right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left || right",
            ),
            (
                "def calc\n  left && middle && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && middle && right",
            ),
            (
                "value = left and right\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left and right",
            ),
            (
                "value = left or right\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left or right",
            ),
            (
                "local value = left and right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left and right",
            ),
            (
                "local value = left or right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left or right",
            ),
            (
                "const value = left && right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left && right",
            ),
            (
                "const value = left || right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left || right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_boolean(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_boolean",
                    kind,
                    text
                ),
                "normalize_boolean mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn boolean_expression_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def calc\n  left && right\nend\n", Language::Ruby, ".rb"),
            ("value = left and right\n", Language::Python, ".py"),
            ("local value = left and right\n", Language::Lua, ".lua"),
            (
                "const value = left && right;\n",
                Language::TypeScript,
                ".ts",
            ),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn operator_call_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left + right\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left + right",
            ),
            (
                "def calc\n  left + right\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "binary",
                "left && right",
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right && other",
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                ".py",
                "boolean_operator",
                "left + right and other",
            ),
            (
                "local value = left + right\nlocal other = left and right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
            (
                "local value = left + right\nlocal other = left and right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left and right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.operator_call_expression(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "operator_call_expression?",
                    kind,
                    text
                ),
                "operator_call_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_operator_call_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right",
            ),
            (
                "def calc\n  left =~ /right/\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left =~ /right/",
            ),
            (
                "def calc\n  left =~ pattern\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left =~ pattern",
            ),
            (
                "value = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "const value = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_operator_call(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_operator_call",
                    kind,
                    text
                ),
                "normalize_operator_call mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn operator_call_expression_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("value = left + right\n", Language::Python, ".py"),
            ("local value = left + right\n", Language::Lua, ".lua"),
            ("const value = left + right;\n", Language::TypeScript, ".ts"),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn spaced_text_matches_ruby_private_helper() {
        for (source, language, suffix, kind, text) in [
            (
                "def calc\n  left + right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left + right",
            ),
            (
                "const value = left + right;\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "left + right",
            ),
            (
                "value = left + right\n",
                Language::Python,
                ".py",
                "binary_operator",
                "left + right",
            ),
            (
                "local value = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.spaced_text(node),
                ruby_private_string(source, language, suffix, "spaced_text", kind, text),
                "spaced_text mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn class_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "class Thing; end\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Thing; end",
            ),
            (
                "class Thing:\n    pass\n",
                Language::Python,
                ".py",
                "class_definition",
                "class Thing:\n    pass",
            ),
            (
                "class Thing {}\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Thing {}",
            ),
            (
                "local Thing = {}\n",
                Language::Lua,
                ".lua",
                "variable_declaration",
                "local Thing = {}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.class_node(node),
                ruby_private_predicate(source, language, suffix, "class_node?", kind, text),
                "class_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn module_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "module Thing\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "module",
                "module Thing\n  value\nend",
            ),
            (
                "class Thing; end\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Thing; end",
            ),
            (
                "value = 1\n",
                Language::Python,
                ".py",
                "module",
                "value = 1\n",
            ),
            (
                "namespace Thing { const value = 1; }\n",
                Language::TypeScript,
                ".ts",
                "program",
                "namespace Thing { const value = 1; }\n",
            ),
            (
                "local Thing = {}\n",
                Language::Lua,
                ".lua",
                "chunk",
                "local Thing = {}\n",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.module_node(node),
                ruby_private_predicate(source, language, suffix, "module_node?", kind, text),
                "module_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_module_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "module Thing\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "module",
                "module Thing\n  value\nend",
            ),
            (
                "module Empty\nend\n",
                Language::Ruby,
                ".rb",
                "module",
                "module Empty\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_module(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_module",
                    kind,
                    text
                ),
                "normalize_module mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_singleton_class_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class << self\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "singleton_class",
                "class << self\n  value\nend",
            ),
            (
                "class << object\nend\n",
                Language::Ruby,
                ".rb",
                "singleton_class",
                "class << object\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_singleton_class(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_singleton_class",
                    kind,
                    text
                ),
                "normalize_singleton_class mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_definition_identifier_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def helper(arg)\n  arg\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "helper",
            ),
            (
                "def helper(arg)\n  arg\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "arg",
            ),
            (
                "items.each { |item| item }\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "item",
            ),
            (
                "def helper\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value",
            ),
            (
                "def helper(arg):\n    return arg\n",
                Language::Python,
                ".py",
                "identifier",
                "arg",
            ),
            (
                "function helper(arg) { return arg; }\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "arg",
            ),
            (
                "function helper(arg)\n  return arg\nend\n",
                Language::Lua,
                ".lua",
                "identifier",
                "arg",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_definition_identifier(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "ruby_definition_identifier?",
                    kind,
                    text
                ),
                "ruby_definition_identifier? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn literal_fragment_assignment_context_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "value = \"left = right\"\n",
                Language::Ruby,
                ".rb",
                "string_content",
                "left = right",
            ),
            ("value = 1\n", Language::Ruby, ".rb", "identifier", "value"),
            (
                "value = \"left = right\"\n",
                Language::Python,
                ".py",
                "string_content",
                "left = right",
            ),
            (
                "const value = \"left = right\";\n",
                Language::TypeScript,
                ".ts",
                "string_fragment",
                "left = right",
            ),
            (
                "local value = \"left = right\"\n",
                Language::Lua,
                ".lua",
                "string_content",
                "left = right",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.literal_fragment_assignment_context(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "literal_fragment_assignment_context?",
                    kind,
                    text
                ),
                "literal_fragment_assignment_context? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_lhs_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "other",
            ),
            (
                "{ key: value }\n",
                Language::Ruby,
                ".rb",
                "hash_key_symbol",
                "key",
            ),
            (
                "{ key: value }\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "variable_declarator",
                "value = other",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.assignment_lhs(node),
                ruby_private_predicate(source, language, suffix, "assignment_lhs?", kind, text),
                "assignment_lhs? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_rhs_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "other",
            ),
            (
                "{ key: value }\n",
                Language::Ruby,
                ".rb",
                "hash_key_symbol",
                "key",
            ),
            (
                "{ key: value }\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "variable_declarator",
                "value = other",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.assignment_rhs(node),
                ruby_private_predicate(source, language, suffix, "assignment_rhs?", kind, text),
                "assignment_rhs? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_assignment_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "value = 1\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "value = 1",
            ),
            (
                "value += 1\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value += 1",
            ),
            (
                "def helper\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value",
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block_body",
                "local = item",
            ),
            (
                "value = 1\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = 1",
            ),
            (
                "value = other;\n",
                Language::TypeScript,
                ".ts",
                "assignment_expression",
                "value = other",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_assignment_node(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "ruby_assignment_node?",
                    kind,
                    text
                ),
                "ruby_assignment_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn collect_assignment_target_names_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "left, *rest = values\n",
                Language::Ruby,
                ".rb",
                "left_assignment_list",
                "left, *rest",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "const value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut names = BTreeSet::new();
            normalizer.collect_assignment_target_names(node, &mut names);

            assert_eq!(
                names,
                ruby_private_collected_names(
                    source,
                    language,
                    suffix,
                    "collect_assignment_target_names",
                    kind,
                    text
                ),
                "collect_assignment_target_names mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn collect_identifier_names_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "left, *rest = values\n",
                Language::Ruby,
                ".rb",
                "left_assignment_list",
                "left, *rest",
            ),
            (
                "receiver.call(argument)\n",
                Language::Ruby,
                ".rb",
                "call",
                "receiver.call(argument)",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "const value = { shorthand };\n",
                Language::TypeScript,
                ".ts",
                "object",
                "{ shorthand }",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "variable_declaration",
                "local value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut names = BTreeSet::new();
            normalizer.collect_identifier_names(node, &mut names);

            assert_eq!(
                names,
                ruby_private_collected_names(
                    source,
                    language,
                    suffix,
                    "collect_identifier_names",
                    kind,
                    text
                ),
                "collect_identifier_names mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn member_name_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "identifier", "name"),
            ("user&.name\n", Language::Ruby, ".rb", "identifier", "name"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "identifier",
                "name",
            ),
            (
                "user?.name;\n",
                Language::TypeScript,
                ".ts",
                "property_identifier",
                "name",
            ),
            ("user.name()\n", Language::Lua, ".lua", "identifier", "name"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.member_name(node),
                ruby_private_string(source, language, suffix, "member_name", kind, text),
                "member_name mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn member_parts_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user.name(thing)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.name(thing)",
            ),
            (
                "user.name();\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name(thing);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "user.name(thing)",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.member_parts(node).map(|(receiver, method)| {
                (
                    receiver.kind().to_string(),
                    super::node_text(receiver, source).to_string(),
                    method,
                )
            });

            assert_eq!(
                rust,
                ruby_private_member_parts(source, language, suffix, kind, text),
                "member_parts mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn member_read_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            ("foo()\n", Language::Ruby, ".rb", "call", "foo()"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user.name(thing)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.name(thing)",
            ),
            (
                "user.name();\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name(thing);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "user.name(thing)",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.member_read_node(node),
                ruby_private_predicate(source, language, suffix, "member_read_node?", kind, text),
                "member_read_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_member_read_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
            ("value\n", Language::Ruby, ".rb", "identifier", "value"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_member_read(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_member_read",
                    kind,
                    text
                ),
                "normalize_member_read mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_left_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "value = other",
            ),
            (
                "left, right = values\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "left, right = values",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "value = other;\n",
                Language::TypeScript,
                ".ts",
                "assignment_expression",
                "value = other",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.assignment_left(node).map(|left| {
                (
                    left.kind().to_string(),
                    super::node_text(left, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "assignment_left",
                    kind,
                    text
                ),
                "assignment_left mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_right_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "value = other",
            ),
            (
                "left, right = values\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "left, right = values",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "value = other;\n",
                Language::TypeScript,
                ".ts",
                "assignment_expression",
                "value = other",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.assignment_right(node).map(|right| {
                (
                    right.kind().to_string(),
                    super::node_text(right, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "assignment_right",
                    kind,
                    text
                ),
                "assignment_right mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn singleton_receiver_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def self.foo\nend\n",
                "singleton_method",
                "def self.foo\nend",
            ),
            (
                "def User.foo\nend\n",
                "singleton_method",
                "def User.foo\nend",
            ),
            (
                "def object.foo\nend\n",
                "singleton_method",
                "def object.foo\nend",
            ),
            (
                "def self.foo(value)\n  value\nend\n",
                "singleton_method",
                "def self.foo(value)\n  value\nend",
            ),
            (
                "def object.foo\n  value\nend\n",
                "singleton_method",
                "def object.foo\n  value\nend",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer.singleton_receiver(node).map(|receiver| {
                (
                    receiver.kind().to_string(),
                    super::node_text(receiver, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    Language::Ruby,
                    ".rb",
                    "singleton_receiver",
                    kind,
                    text
                ),
                "singleton_receiver mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn singleton_name_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def self.foo\nend\n",
                "singleton_method",
                "def self.foo\nend",
            ),
            (
                "def User.foo\nend\n",
                "singleton_method",
                "def User.foo\nend",
            ),
            (
                "def object.foo\nend\n",
                "singleton_method",
                "def object.foo\nend",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

            assert_eq!(
                normalizer.singleton_name(node),
                ruby_private_string(source, Language::Ruby, ".rb", "singleton_name", kind, text),
                "singleton_name mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_singleton_function_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def self.hidden(value)\n  return value\nend\n",
                "singleton_method",
                "def self.hidden(value)\n  return value\nend",
            ),
            (
                "def User.hidden\nend\n",
                "singleton_method",
                "def User.hidden\nend",
            ),
            (
                "def object.hidden\n  value\nend\n",
                "singleton_method",
                "def object.hidden\n  value\nend",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_singleton_function(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_singleton_function",
                    kind,
                    text
                ),
                "normalize_singleton_function mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_function_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check(value)\n  return value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def check(value)\n  return value\nend",
            ),
            (
                "def empty\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def empty\nend",
            ),
            (
                "def object.hidden\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "singleton_method",
                "def object.hidden\n  value\nend",
            ),
            (
                "def check(value):\n    return value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def check(value):\n    return value",
            ),
            (
                "function check(value) { return value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function check(value) { return value; }",
            ),
            (
                "class Box { check(value) { return value; } }\n",
                Language::TypeScript,
                ".ts",
                "method_definition",
                "check(value) { return value; }",
            ),
            (
                "function check(value)\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function check(value)\n  return value\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_function(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_function",
                    kind,
                    text
                ),
                "normalize_function mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn lambda_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "fn = ->(x) { x + 1 }\n",
                Language::Ruby,
                ".rb",
                "lambda",
                "->(x) { x + 1 }",
            ),
            (
                "fn = lambda x: x + 1\n",
                Language::Python,
                ".py",
                "lambda",
                "lambda x: x + 1",
            ),
            (
                "const fn = (x) => x + 1;\n",
                Language::TypeScript,
                ".ts",
                "arrow_function",
                "(x) => x + 1",
            ),
            (
                "const fn = function(x) { return x + 1; };\n",
                Language::TypeScript,
                ".ts",
                "function_expression",
                "function(x) { return x + 1; }",
            ),
            (
                "local fn = function(x) return x + 1 end\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "function(x) return x + 1 end",
            ),
            (
                "function f(x) return x + 1 end\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f(x) return x + 1 end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.lambda_expression(node),
                ruby_private_predicate(source, language, suffix, "lambda_expression?", kind, text),
                "lambda_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_lambda_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "fn = ->(x) { x + 1 }\n",
                Language::Ruby,
                ".rb",
                "lambda",
                "->(x) { x + 1 }",
            ),
            (
                "fn = lambda x: x + 1\n",
                Language::Python,
                ".py",
                "lambda",
                "lambda x: x + 1",
            ),
            (
                "const fn = (x) => x + 1;\n",
                Language::TypeScript,
                ".ts",
                "arrow_function",
                "(x) => x + 1",
            ),
            (
                "const fn = function(x) { return x + 1; };\n",
                Language::TypeScript,
                ".ts",
                "function_expression",
                "function(x) { return x + 1; }",
            ),
            (
                "local fn = function(x) return x + 1 end\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "function(x) return x + 1 end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_lambda(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_lambda",
                    kind,
                    text
                ),
                "normalize_lambda mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn lambda_expression_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("fn = ->(x) { x + 1 }\n", Language::Ruby, ".rb"),
            ("fn = lambda x: x + 1\n", Language::Python, ".py"),
            ("const fn = (x) => x + 1;\n", Language::TypeScript, ".ts"),
            (
                "const fn = function(x) { return x + 1; };\n",
                Language::TypeScript,
                ".ts",
            ),
            (
                "local fn = function(x) return x + 1 end\n",
                Language::Lua,
                ".lua",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut lambdas = Vec::new();
            nodes_of_type(&root, "LAMBDA", &mut lambdas);
            assert!(
                !lambdas.is_empty(),
                "expected LAMBDA for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn function_name_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def run\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def run\nend",
            ),
            (
                "def self.run\nend\n",
                Language::Ruby,
                ".rb",
                "singleton_method",
                "def self.run\nend",
            ),
            (
                "def run():\n    pass\n",
                Language::Python,
                ".py",
                "function_definition",
                "def run():\n    pass",
            ),
            (
                "function run() {}\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function run() {}",
            ),
            (
                "class Box { run() {} }\n",
                Language::TypeScript,
                ".ts",
                "method_definition",
                "run() {}",
            ),
            (
                "function run()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function run()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.function_name(node).unwrap_or_default(),
                ruby_private_string(source, language, suffix, "function_name", kind, text),
                "function_name mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn collect_destructured_parameter_targets_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "items.each { |(left, right)| left }\n",
                "destructured_parameter",
                "(left, right)",
            ),
            (
                "items.each do |(left, (middle, right))| left end\n",
                "destructured_parameter",
                "(left, (middle, right))",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let mut targets = Vec::new();
            normalizer.collect_destructured_parameter_targets(node, &mut targets);
            let rust = Value::Array(targets.iter().map(node_value).collect());

            assert_eq!(
                rust,
                ruby_private_destructured_parameter_targets_value(source, kind, text),
                "collect_destructured_parameter_targets mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_block_parameters_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "items.each { |(left, right)| left }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |(left, right)| left }",
            ),
            (
                "items.each { |item, (left, right)| item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item, (left, right)| item }",
            ),
            (
                "items.each { |item| item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| item }",
            ),
            (
                "def f(x):\n    pass\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f(x):\n    pass",
            ),
            (
                "items.forEach((item) => item);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "items.forEach((item) => item);",
            ),
            (
                "function f(x)\n  return x\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f(x)\n  return x\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_block_parameters(Some(node))
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_block_parameters",
                    kind,
                    text
                ),
                "normalize_block_parameters mismatch for {language:?} {kind} {text:?}"
            );
        }

        let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        assert!(normalizer.normalize_block_parameters(None).is_none());
    }

    #[test]
    fn normalize_parameters_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(value = 1)\nend\n",
                Language::Ruby,
                ".rb",
                "method_parameters",
                "(value = 1)",
            ),
            (
                "def f(value)\nend\n",
                Language::Ruby,
                ".rb",
                "method_parameters",
                "(value)",
            ),
            (
                "def f(value=1):\n    pass\n",
                Language::Python,
                ".py",
                "parameters",
                "(value=1)",
            ),
            (
                "function f(value = 1) {}\n",
                Language::TypeScript,
                ".ts",
                "formal_parameters",
                "(value = 1)",
            ),
            (
                "function f(value)\nend\n",
                Language::Lua,
                ".lua",
                "parameters",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_parameters(Some(node))
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_parameters",
                    kind,
                    text
                ),
                "normalize_parameters mismatch for {language:?} {kind} {text:?}"
            );
        }

        let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        assert!(normalizer.normalize_parameters(None).is_none());
    }

    #[test]
    fn normalize_destructured_block_parameter_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "items.each { |(left, right)| left }\n",
                "destructured_parameter",
                "(left, right)",
            ),
            (
                "items.each do |(left, (middle, right))| left end\n",
                "destructured_parameter",
                "(left, (middle, right))",
            ),
            ("items.each { |item| item }\n", "identifier", "item"),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_destructured_block_parameter(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_destructured_block_parameter",
                    kind,
                    text
                ),
                "normalize_destructured_block_parameter mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn scope_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, mode) in [
            ("1\n", Language::Ruby, ".rb", "integer", "1", "body"),
            (
                "1\n",
                Language::Python,
                ".py",
                "expression_statement",
                "1",
                "body",
            ),
            (
                "value;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
                "args",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "value",
                "empty",
            ),
        ] {
            let tree = raw_tree(source, language);
            let root = tree.root_node();
            let node = first_raw_node(root, source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            normalizer.root_span = Some(super::span(root));
            let body = if mode == "body" {
                Some(normalizer.wrap("BODY", Vec::new(), node))
            } else {
                None
            };
            let args = if mode == "args" {
                Some(normalizer.wrap("ARGS", Vec::new(), node))
            } else {
                None
            };
            let rust = node_value(&normalizer.scope(body, args, node));

            assert_eq!(
                rust,
                ruby_private_scope_value(source, language, suffix, kind, text, mode),
                "scope mismatch for {language:?} {kind} {text:?} mode {mode}"
            );
        }
    }

    #[test]
    fn list_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, mode) in [
            (
                "value\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                "one",
            ),
            (
                "value\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
                "empty",
            ),
            (
                "value;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
                "nil",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "value",
                "one",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let item = normalizer.wrap("ITEM", Vec::new(), node);
            let children = match mode {
                "nil" => None,
                "empty" => Some(Vec::new()),
                "one" => Some(vec![item]),
                _ => panic!("unknown list mode: {mode}"),
            };
            let rust = normalizer
                .list(children, node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_list_value(source, language, suffix, kind, text, mode),
                "list mismatch for {language:?} {kind} {text:?} mode {mode}"
            );
        }
    }

    #[test]
    fn unwrap_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  (value)\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "parenthesized_statements",
                "(value)",
            ),
            (
                "value\n(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
            ),
            (
                "value\n(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "(value)",
            ),
            (
                "const value = (other);\n",
                Language::TypeScript,
                ".ts",
                "parenthesized_expression",
                "(other)",
            ),
            (
                "local first = (other)\nlocal second = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "(other)",
            ),
            (
                "local first = (other)\nlocal second = left + right\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "left + right",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.unwrap_node(node),
                ruby_private_predicate(source, language, suffix, "unwrap_node?", kind, text),
                "unwrap_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn statement_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  return value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "return value",
            ),
            (
                "def check\n  return value\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "check",
            ),
            (
                "value\n(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "(value)",
            ),
            (
                "value\n(value)\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "function check() { return value + other; }\n",
                Language::TypeScript,
                ".ts",
                "return_statement",
                "return value + other;",
            ),
            (
                "function check() { return value + other; }\n",
                Language::TypeScript,
                ".ts",
                "binary_expression",
                "value + other",
            ),
            (
                "function check() { return value + other; }\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "return_statement",
                "return value",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.statement_node(node.kind()),
                ruby_private_predicate(source, language, suffix, "statement_node?", kind, text),
                "statement_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn local_identifier_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\nend\nclass Thing; end\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "check",
            ),
            (
                "def check\nend\nclass Thing; end\n",
                Language::Ruby,
                ".rb",
                "constant",
                "Thing",
            ),
            (
                "def check(value):\n    pass\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "def check(value):\n    pass\n",
                Language::Python,
                ".py",
                "parameters",
                "(value)",
            ),
            (
                "const value = object.field;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "const value = object.field;\n",
                Language::TypeScript,
                ".ts",
                "property_identifier",
                "field",
            ),
            (
                "const value = object.field;\n",
                Language::TypeScript,
                ".ts",
                "lexical_declaration",
                "const value = object.field;",
            ),
            (
                "local value = other\nprint(value)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "value",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.identifier_kind(node.kind()),
                ruby_private_predicate(source, language, suffix, "local_identifier?", kind, text),
                "local_identifier? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_local_name_matches_scope_stack_lookup() {
        let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        normalizer.local_stack = vec![
            BTreeSet::from(["outer".to_string(), "shared".to_string()]),
            BTreeSet::from(["inner".to_string()]),
        ];

        assert!(normalizer.ruby_local_name("outer"));
        assert!(normalizer.ruby_local_name("inner"));
        assert!(normalizer.ruby_local_name("shared"));
        assert!(!normalizer.ruby_local_name("missing"));
    }

    #[test]
    fn ruby_vcall_identifier_matches_ruby_private_predicate() {
        let cases = vec![
            (
                "ruby_vcall",
                "foo\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "ruby_local",
                "foo\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                vec!["foo"],
            ),
            (
                "assignment_lhs",
                "foo = 1\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "method_name",
                "def foo\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "parameter",
                "def f(foo)\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "non_identifier",
                "Thing\n",
                Language::Ruby,
                ".rb",
                "constant",
                "Thing",
                Vec::<&str>::new(),
            ),
            (
                "non_ruby",
                "foo\n",
                Language::Python,
                ".py",
                "expression_statement",
                "foo",
                Vec::<&str>::new(),
            ),
        ];

        for (label, source, language, suffix, kind, text, locals) in cases {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            if !locals.is_empty() {
                normalizer
                    .local_stack
                    .push(locals.iter().map(|name| name.to_string()).collect());
            }

            assert_eq!(
                normalizer.ruby_vcall_identifier(node, super::node_text(node, source)),
                ruby_private_ruby_vcall_identifier_predicate(
                    source, language, suffix, kind, text, &locals,
                ),
                "ruby_vcall_identifier? mismatch for {label}"
            );
        }
    }

    #[test]
    fn vcall_identifier_matches_ruby_private_predicate() {
        let cases = vec![
            (
                "ruby_modifier_action",
                "foo if cond\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "ruby_local",
                "foo if cond\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                vec!["foo"],
            ),
            (
                "method_name",
                "def foo\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "argument",
                "call(foo)\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "member_read",
                "def f\n  user.name\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "name",
                Vec::<&str>::new(),
            ),
            (
                "assignment_lhs",
                "foo = bar\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "python_identifier",
                "foo\n",
                Language::Python,
                ".py",
                "expression_statement",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "typescript_identifier",
                "foo;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "lua_identifier",
                "foo()\n",
                Language::Lua,
                ".lua",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
        ];

        for (label, source, language, suffix, kind, text, locals) in cases {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            if !locals.is_empty() {
                normalizer
                    .local_stack
                    .push(locals.iter().map(|name| name.to_string()).collect());
            }

            assert_eq!(
                normalizer.vcall_identifier(node, super::node_text(node, source)),
                ruby_private_vcall_identifier_predicate(
                    source, language, suffix, kind, text, &locals,
                ),
                "vcall_identifier? mismatch for {label}"
            );
        }

        let source = "def f\n  Thing\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, "constant", "Thing");
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        assert!(
            !normalizer.vcall_identifier(node, super::node_text(node, source)),
            "vcall_identifier? must reject non-local identifiers in statement wrappers"
        );

        let source = "foo\n";
        let tree = raw_tree(source, Language::Python);
        let node = first_raw_node(tree.root_node(), source, "identifier", "foo");
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Python);
        assert!(
            !normalizer.vcall_identifier(node, super::node_text(node, source)),
            "vcall_identifier? must reject Python bare identifiers"
        );
    }

    #[test]
    fn collect_ruby_parameter_locals_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def f(a, b = 1, *rest, key:, **opts, &block)\nend\n",
                "method_parameters",
                "(a, b = 1, *rest, key:, **opts, &block)",
            ),
            (
                "[1].each { |item, (left, right)| item }\n",
                "block_parameters",
                "|item, (left, right)|",
            ),
            ("fn = ->(x, y:) { x }\n", "lambda_parameters", "(x, y:)"),
            ("value = other\n", "assignment", "value = other"),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let mut locals = BTreeSet::new();
            normalizer.collect_ruby_parameter_locals(node, &mut locals);

            assert_eq!(
                locals,
                ruby_private_collected_names(
                    source,
                    Language::Ruby,
                    ".rb",
                    "collect_ruby_parameter_locals",
                    kind,
                    text
                ),
                "collect_ruby_parameter_locals mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn collect_ruby_assignment_locals_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "value = other",
            ),
            (
                "left, *rest = values\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "left, *rest = values",
            ),
            (
                "value += 1\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value += 1",
            ),
            (
                "begin\n  work\nrescue => error\n  error\nend\n",
                Language::Ruby,
                ".rb",
                "exception_variable",
                "=> error",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "variable_declarator",
                "value = other",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut locals = BTreeSet::new();
            normalizer.collect_ruby_assignment_locals(node, &mut locals);

            assert_eq!(
                locals,
                ruby_private_collected_names(
                    source,
                    language,
                    suffix,
                    "collect_ruby_assignment_locals",
                    kind,
                    text
                ),
                "collect_ruby_assignment_locals mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn collect_ruby_scope_locals_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, root) in [
            (
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend",
                true,
            ),
            (
                "def outer(a)\n  local = 1\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\nend",
                false,
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| local = item }",
                true,
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
                true,
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "variable_declarator",
                "value = other",
                true,
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
                true,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut locals = BTreeSet::new();
            normalizer.collect_ruby_scope_locals(node, &mut locals, root);

            assert_eq!(
                locals,
                ruby_private_scope_collected_names(source, language, suffix, kind, text, root),
                "collect_ruby_scope_locals mismatch for {language:?} {kind} {text:?} root={root}"
            );
        }
    }

    #[test]
    fn ruby_scope_locals_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend",
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| local = item }",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "variable_declarator",
                "value = other",
            ),
            (
                "local value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_scope_locals(node),
                ruby_private_ruby_scope_locals(source, language, suffix, kind, text),
                "ruby_scope_locals mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn with_ruby_scope_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, reset, initial_stack) in [
            (
                "def f(a)\n  local = 1\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a)\n  local = 1\nend",
                false,
                vec![vec!["outer"]],
            ),
            (
                "def f(a)\n  local = 1\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a)\n  local = 1\nend",
                true,
                vec![vec!["outer"]],
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| local = item }",
                false,
                vec![],
            ),
            (
                "def f(value):\n    local = value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f(value):\n    local = value",
                true,
                vec![vec!["outer"]],
            ),
            (
                "function f(value) { let local = value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f(value) { let local = value; }",
                true,
                vec![vec!["outer"]],
            ),
            (
                "function f(value)\n  local local_value = value\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f(value)\n  local local_value = value\nend",
                true,
                vec![vec!["outer"]],
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            normalizer.local_stack = local_stack_from(&initial_stack);
            let before = local_stack_value(&normalizer.local_stack);
            let inside = normalizer.with_ruby_scope(node, reset, |normalizer| {
                local_stack_value(&normalizer.local_stack)
            });
            let after = local_stack_value(&normalizer.local_stack);
            let rust = json!({
                "before": before,
                "inside": inside,
                "after": after,
                "result": "block-result",
            });

            assert_eq!(
                rust,
                ruby_private_with_ruby_scope_trace(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    reset,
                    &initial_stack,
                ),
                "with_ruby_scope mismatch for {language:?} {kind} {text:?} reset={reset}"
            );
        }
    }

    #[test]
    fn ruby_scope_boundary_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f\n  value\nend",
            ),
            (
                "class Box\nend\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Box\nend",
            ),
            (
                "module Admin\nend\n",
                Language::Ruby,
                ".rb",
                "module",
                "module Admin\nend",
            ),
            (
                "items.each { |item| item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| item }",
            ),
            (
                "handler = -> { value }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ value }",
            ),
            (
                "def f():\n    return value\n    break\n    continue\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    return value\n    break\n    continue",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "block",
                "return value",
            ),
            (
                "class Box:\n    pass\n",
                Language::Python,
                ".py",
                "class_definition",
                "class Box:\n    pass",
            ),
            (
                "function f() { return value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f() { return value; }",
            ),
            (
                "class Box {}\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Box {}",
            ),
            (
                "function f()\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f()\n  return value\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_scope_boundary(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "ruby_scope_boundary?",
                    kind,
                    text
                ),
                "ruby_scope_boundary? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_scope_child_boundary_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f\n  value\nend",
            ),
            (
                "class Box\nend\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Box\nend",
            ),
            (
                "module Admin\nend\n",
                Language::Ruby,
                ".rb",
                "module",
                "module Admin\nend",
            ),
            (
                "items.each { |item| item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| item }",
            ),
            (
                "handler = -> { value }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ value }",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    return value",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "block",
                "return value",
            ),
            (
                "class Box:\n    pass\n",
                Language::Python,
                ".py",
                "class_definition",
                "class Box:\n    pass",
            ),
            (
                "function f() { return value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f() { return value; }",
            ),
            (
                "class Box {}\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Box {}",
            ),
            (
                "function f()\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f()\n  return value\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_scope_child_boundary(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "ruby_scope_child_boundary?",
                    kind,
                    text
                ),
                "ruby_scope_child_boundary? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_predicate_uses_normalization_adapter() {
        for (language, expected) in [
            (Language::Ruby, true),
            (Language::Python, false),
            (Language::Lua, false),
            (Language::TypeScript, false),
        ] {
            let normalizer = super::TreeSitterNormalizer::new("", language);

            assert_eq!(
                normalizer.ruby(),
                expected,
                "ruby? mismatch for {language:?}"
            );
        }
    }

    #[test]
    fn interpolated_string_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "name = \"hi #{user}\"\nplain = \"hi\"\n",
                Language::Ruby,
                ".rb",
                "string",
                "\"hi #{user}\"",
            ),
            (
                "name = \"hi #{user}\"\nplain = \"hi\"\n",
                Language::Ruby,
                ".rb",
                "string",
                "\"hi\"",
            ),
            (
                "name = f\"hi {user}\"\nplain = \"hi\"\n",
                Language::Python,
                ".py",
                "string",
                "f\"hi {user}\"",
            ),
            (
                "name = f\"hi {user}\"\nplain = \"hi\"\n",
                Language::Python,
                ".py",
                "string",
                "\"hi\"",
            ),
            (
                "const name = `hi ${user}`;\nconst plain = `hi`;\n",
                Language::TypeScript,
                ".ts",
                "template_string",
                "`hi ${user}`",
            ),
            (
                "const name = `hi ${user}`;\nconst plain = `hi`;\n",
                Language::TypeScript,
                ".ts",
                "template_string",
                "`hi`",
            ),
            (
                "local name = \"hi\"\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "\"hi\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.interpolated_string(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "interpolated_string?",
                    kind,
                    text
                ),
                "interpolated_string? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_interpolated_string_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "name = \"hi #{user}\"\n",
                Language::Ruby,
                ".rb",
                "string",
                "\"hi #{user}\"",
            ),
            (
                "name = f\"hi {user}\"\n",
                Language::Python,
                ".py",
                "string",
                "f\"hi {user}\"",
            ),
            (
                "const name = `hi ${user}`;\n",
                Language::TypeScript,
                ".ts",
                "template_string",
                "`hi ${user}`",
            ),
            (
                "local name = \"hi\"\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "\"hi\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = node_value(&normalizer.normalize_interpolated_string(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_interpolated_string",
                    kind,
                    text
                ),
                "normalize_interpolated_string mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_subshell_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = `echo hi`\n",
                Language::Ruby,
                ".rb",
                "subshell",
                "`echo hi`",
            ),
            (
                "value = `echo #{name}`\n",
                Language::Ruby,
                ".rb",
                "subshell",
                "`echo #{name}`",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = node_value(&normalizer.normalize_subshell(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_subshell",
                    kind,
                    text
                ),
                "normalize_subshell mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn const_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "class Thing; end\ndef check; end\n",
                Language::Ruby,
                ".rb",
                "constant",
                "Thing",
            ),
            (
                "class Thing; end\ndef check; end\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "check",
            ),
            (
                "class Thing:\n    pass\n",
                Language::Python,
                ".py",
                "identifier",
                "Thing",
            ),
            (
                "type Thing = Other;\nconst value = Thing;\n",
                Language::TypeScript,
                ".ts",
                "type_identifier",
                "Thing",
            ),
            (
                "type Thing = Other;\nconst value = Thing;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "local Thing = {}\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "Thing",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.const_kind(node.kind()),
                ruby_private_predicate(source, language, suffix, "const_node?", kind, text),
                "const_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn self_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("self\nother\n", Language::Ruby, ".rb", "self", "self"),
            (
                "self\nother\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "other",
            ),
            (
                "self.value\nother.value\n",
                Language::Python,
                ".py",
                "identifier",
                "self",
            ),
            (
                "self.value\nother.value\n",
                Language::Python,
                ".py",
                "identifier",
                "other",
            ),
            (
                "this.value;\nother;\n",
                Language::TypeScript,
                ".ts",
                "this",
                "this",
            ),
            (
                "this.value;\nother;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "other",
            ),
            (
                "print(self.value)\nprint(other.value)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "self",
            ),
            (
                "print(self.value)\nprint(other.value)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.self_node(node),
                ruby_private_predicate(source, language, suffix, "self_node?", kind, text),
                "self_node? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn instance_variable_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "@value\nname\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "@value",
            ),
            (
                "@value\nname\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "name",
            ),
            (
                "@decorator\ndef call():\n    pass\n",
                Language::Python,
                ".py",
                "decorator",
                "@decorator",
            ),
            (
                "@sealed\nclass Thing {}\n",
                Language::TypeScript,
                ".ts",
                "decorator",
                "@sealed",
            ),
            (
                "print(value)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.instance_variable(node),
                ruby_private_predicate(source, language, suffix, "instance_variable?", kind, text),
                "instance_variable? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn global_variable_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "$value\nname\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            (
                "$value\nname\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "name",
            ),
            (
                "value = \"$name\"\n",
                Language::Python,
                ".py",
                "string_content",
                "$name",
            ),
            (
                "const $value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "$value",
            ),
            (
                "print(\"$name\")\n",
                Language::Lua,
                ".lua",
                "string_content",
                "$name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.global_variable(node),
                ruby_private_predicate(source, language, suffix, "global_variable?", kind, text),
                "global_variable? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_global_variable_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "$value\n$1\n$12\n$0\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            (
                "$value\n$1\n$12\n$0\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$1",
            ),
            (
                "$value\n$1\n$12\n$0\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$12",
            ),
            (
                "$value\n$1\n$12\n$0\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$0",
            ),
            (
                "value = \"$name\"\n",
                Language::Python,
                ".py",
                "string_content",
                "$name",
            ),
            (
                "const $value = 1;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "$value",
            ),
            (
                "print(\"$name\")\n",
                Language::Lua,
                ".lua",
                "string_content",
                "$name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.normalize_global_variable(node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_global_variable",
                    kind,
                    text
                ),
                "normalize_global_variable mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_operator_matches_ruby_private_predicate() {
        for (language, text) in [
            (Language::Ruby, "="),
            (Language::Ruby, "**="),
            (Language::Ruby, "??="),
            (Language::Python, ":="),
            (Language::Python, "//="),
            (Language::Python, "&&="),
            (Language::TypeScript, "??="),
            (Language::TypeScript, ">>>="),
            (Language::TypeScript, ":="),
            (Language::Lua, "="),
            (Language::Lua, "+="),
        ] {
            let normalizer = super::TreeSitterNormalizer::new("", language);

            assert_eq!(
                normalizer.assignment_operator(text),
                ruby_private_text_predicate(language, "assignment_operator?", text),
                "assignment_operator? mismatch for {language:?} {text:?}"
            );
        }
    }

    #[test]
    fn operator_assignment_operator_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value **= other\nflag ||= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value **= other",
            ),
            (
                "value **= other\nflag ||= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "flag ||= fallback",
            ),
            (
                "value //= other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value //= other",
            ),
            (
                "value ??= other;\ncount >>>= 1;\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "value ??= other",
            ),
            (
                "value ??= other;\ncount >>>= 1;\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "count >>>= 1",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.operator_assignment_operator(node),
                ruby_private_string(
                    source,
                    language,
                    suffix,
                    "operator_assignment_operator",
                    kind,
                    text
                ),
                "operator_assignment_operator mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_logical_operator_assignment_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value ||= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value ||= fallback",
            ),
            (
                "value &&= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value &&= fallback",
            ),
            (
                "value += fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value += fallback",
            ),
            (
                "@value ||= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "@value ||= fallback",
            ),
            (
                "value //= fallback\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value //= fallback",
            ),
            (
                "value ||= fallback;\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "value ||= fallback",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let left = normalizer
                .assignment_left(node)
                .expect("operator assignment should have left side");
            let right = normalizer
                .assignment_right(node)
                .and_then(|right| normalizer.normalize_node(right));
            let operator = normalizer.operator_assignment_operator(node);
            let rust = normalizer
                .normalize_logical_operator_assignment(left, &operator, right, node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_logical_operator_assignment_value(
                    source, language, suffix, kind, text
                ),
                "normalize_logical_operator_assignment mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_operator_assignment_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value += other\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "value += other",
            ),
            (
                "$value += 1\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "$value += 1",
            ),
            (
                "items[index] += value\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "items[index] += value",
            ),
            (
                "object.value += 1\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "object.value += 1",
            ),
            (
                "flag ||= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "flag ||= fallback",
            ),
            (
                "flag &&= fallback\n",
                Language::Ruby,
                ".rb",
                "operator_assignment",
                "flag &&= fallback",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_operator_assignment(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_operator_assignment",
                    kind,
                    text
                ),
                "normalize_operator_assignment mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn first_named_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class Thing; end\nname\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Thing; end",
            ),
            (
                "class Thing; end\nname\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "name",
            ),
            (
                "def check(value):\n    return value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def check(value):\n    return value",
            ),
            (
                "function check(value) { return value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function check(value) { return value; }",
            ),
            (
                "print(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "print(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.first_named(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "first_named", kind, text),
                "first_named mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn block_child_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def check\n  call\nend",
            ),
            (
                "items.each do\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.each do\n  call\nend",
            ),
            (
                "def check():\n    call()\n",
                Language::Python,
                ".py",
                "function_definition",
                "def check():\n    call()",
            ),
            (
                "function check() { call(); }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function check() { call(); }",
            ),
            (
                "function check()\n  call()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function check()\n  call()\nend",
            ),
            ("name\n", Language::Ruby, ".rb", "identifier", "name"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.block_child(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "block_child", kind, text),
                "block_child mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn branch_child_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, condition_kind, condition_text, index) in [
            (
                "if ready\n  call\nelse\n  stop\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nelse\n  stop\nend",
                "identifier",
                "ready",
                0,
            ),
            (
                "if ready\n  call\nelse\n  stop\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nelse\n  stop\nend",
                "identifier",
                "ready",
                1,
            ),
            (
                "if ready\n  # note\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  # note\n  call\nend",
                "identifier",
                "ready",
                0,
            ),
            (
                "if ready:\n    call()\nelse:\n    stop()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()\nelse:\n    stop()",
                "identifier",
                "ready",
                1,
            ),
            (
                "if (ready) { call(); } else { stop(); }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (ready) { call(); } else { stop(); }",
                "parenthesized_expression",
                "(ready)",
                0,
            ),
            (
                "if ready then\n  call()\nelse\n  stop()\nend\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if ready then\n  call()\nelse\n  stop()\nend",
                "identifier",
                "ready",
                1,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let condition =
                first_raw_node(tree.root_node(), source, condition_kind, condition_text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.branch_child(node, condition, index).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_branch_child_signature(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    condition_kind,
                    condition_text,
                    index
                ),
                "branch_child mismatch for {language:?} {kind} {text:?} index {index}"
            );
        }
    }

    #[test]
    fn explicit_alternative_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "if ready\n  call\nelsif other\n  stop\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nelsif other\n  stop\nend",
            ),
            (
                "if ready\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nend",
            ),
            (
                "if ready:\n    call()\nelif other:\n    stop()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()\nelif other:\n    stop()",
            ),
            (
                "if (ready) { call(); } else { stop(); }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (ready) { call(); } else { stop(); }",
            ),
            (
                "if ready then\n  call()\nelseif other then\n  stop()\nend\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if ready then\n  call()\nelseif other then\n  stop()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.explicit_alternative(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "explicit_alternative",
                    kind,
                    text
                ),
                "explicit_alternative mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn wrap_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "first\nsecond\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "second",
            ),
            (
                "first\nsecond\n",
                Language::Python,
                ".py",
                "expression_statement",
                "second",
            ),
            (
                "first;\nsecond;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "second",
            ),
            (
                "print(first)\nprint(second)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "second",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            let raw_wrapped =
                normalizer.wrap("OUTER", vec![Child::Symbol("child".to_string())], node);
            assert_eq!(
                node_value(&raw_wrapped),
                ruby_private_wrap_value(source, language, suffix, kind, text, false),
                "wrap raw-source mismatch for {language:?} {kind} {text:?}"
            );

            let inner = normalizer.wrap("INNER", Vec::new(), node);
            let node_wrapped = normalizer.wrap_from_source_node(
                "OUTER",
                vec![Child::Symbol("child".to_string())],
                &inner,
            );
            assert_eq!(
                node_value(&node_wrapped),
                ruby_private_wrap_value(source, language, suffix, kind, text, true),
                "wrap normalized-source mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn source_before_child_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, child_kind, child_text) in [
            (
                "if ready\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nend",
                "then",
                "\n  call",
            ),
            (
                "if ready:\n    call()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()",
                "block",
                "call()",
            ),
            (
                "if (ready) { call(); }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (ready) { call(); }",
                "statement_block",
                "{ call(); }",
            ),
            (
                "if ready then\n  call()\nend\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if ready then\n  call()\nend",
                "block",
                "call()",
            ),
            (
                "puts value\n",
                Language::Ruby,
                ".rb",
                "call",
                "puts value",
                "identifier",
                "puts",
            ),
            (
                "call()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "call()",
                "identifier",
                "call",
            ),
            (
                "call();\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "call();",
                "identifier",
                "call",
            ),
            (
                "call()\n",
                Language::Lua,
                ".lua",
                "function_call",
                "call()",
                "identifier",
                "call",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let child = first_raw_node(tree.root_node(), source, child_kind, child_text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let source_node = normalizer.source_before_child(node, child);
            let wrapped = normalizer.wrap_from_source_node("OUTER", Vec::new(), &source_node);

            assert_eq!(
                node_value(&wrapped),
                ruby_private_source_before_child_wrap_value(
                    source, language, suffix, kind, text, child_kind, child_text
                ),
                "source_before_child mismatch for {language:?} {kind} {text:?} before {child_kind} {child_text:?}"
            );
        }
    }

    #[test]
    fn source_from_nodes_matches_ruby_private_method() {
        for (source, language, suffix, first_kind, first_text, last_kind, last_text) in [
            (
                "left + right\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "left",
                "identifier",
                "right",
            ),
            (
                "left = one\nright = two\n",
                Language::Python,
                ".py",
                "identifier",
                "one",
                "identifier",
                "two",
            ),
            (
                "const left = one;\nconst right = two;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "one",
                "identifier",
                "two",
            ),
            (
                "local left = one\nlocal right = two\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "one",
                "expression_list",
                "two",
            ),
        ] {
            let tree = raw_tree(source, language);
            let first_raw = first_raw_node(tree.root_node(), source, first_kind, first_text);
            let last_raw = first_raw_node(tree.root_node(), source, last_kind, last_text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let source_node = normalizer.source_from_nodes(first_raw, last_raw);

            assert_eq!(
                node_value(&source_node),
                ruby_private_source_from_nodes_value(
                    source, language, suffix, first_kind, first_text, last_kind, last_text
                ),
                "source_from_nodes mismatch for {language:?} {first_kind} {first_text:?} through {last_kind} {last_text:?}"
            );
        }
    }

    #[test]
    fn source_from_normalized_nodes_matches_ruby_private_method() {
        for (source, language, suffix, first_kind, first_text, last_kind, last_text) in [
            (
                "first\nsecond\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "first",
                "identifier",
                "second",
            ),
            (
                "first\nsecond\n",
                Language::Python,
                ".py",
                "expression_statement",
                "first",
                "expression_statement",
                "second",
            ),
            (
                "first;\nsecond;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "first;",
                "expression_statement",
                "second;",
            ),
            (
                "print(first)\nprint(second)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "print(first)",
                "function_call",
                "print(second)",
            ),
            (
                "first + second\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "first",
                "identifier",
                "second",
            ),
        ] {
            let tree = raw_tree(source, language);
            let first_raw = first_raw_node(tree.root_node(), source, first_kind, first_text);
            let last_raw = first_raw_node(tree.root_node(), source, last_kind, last_text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let first_node = normalizer.wrap("FIRST", Vec::new(), first_raw);
            let last_node = normalizer.wrap("LAST", Vec::new(), last_raw);
            let source_node = normalizer.source_from_normalized_nodes(&first_node, &last_node);

            assert_eq!(
                node_value(&source_node),
                ruby_private_source_from_normalized_nodes_value(
                    source, language, suffix, first_kind, first_text, last_kind, last_text
                ),
                "source_from_normalized_nodes mismatch for {language:?} {first_kind} {first_text:?} through {last_kind} {last_text:?}"
            );
        }
    }

    #[test]
    fn named_field_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, field) in [
            (
                "def check(value)\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def check(value)\n  value\nend",
                "name",
            ),
            (
                "def check(value)\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def check(value)\n  value\nend",
                "missing",
            ),
            (
                "if ready:\n    call()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()",
                "body",
            ),
            (
                "if ready:\n    call()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()",
                "condition",
            ),
            (
                "function check(value) { return value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function check(value) { return value; }",
                "body",
            ),
            (
                "function check(value)\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function check(value)\n  return value\nend",
                "body",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.named_field(node, field).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_named_field_signature(source, language, suffix, kind, text, field),
                "named_field mismatch for {language:?} {kind} {text:?} field {field}"
            );
        }
    }

    #[test]
    fn parent_node_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def check\nend\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "check",
            ),
            ("value\n", Language::Ruby, ".rb", "program", "value\n"),
            (
                "if ready:\n    call()\n",
                Language::Python,
                ".py",
                "identifier",
                "ready",
            ),
            (
                "call(value);\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "call(value)\n",
                Language::Lua,
                ".lua",
                "identifier",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.parent_node(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "parent_node", kind, text),
                "parent_node mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn next_sibling_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("a + b\n", Language::Ruby, ".rb", "identifier", "a"),
            ("a + b\n", Language::Python, ".py", "identifier", "a"),
            ("a + b;\n", Language::TypeScript, ".ts", "identifier", "a"),
            ("print(a, b)\n", Language::Lua, ".lua", "identifier", "a"),
            ("a\n", Language::Ruby, ".rb", "identifier", "a"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.next_sibling(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "next_sibling", kind, text),
                "next_sibling mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn prev_sibling_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("a + b\n", Language::Ruby, ".rb", "identifier", "b"),
            ("a + b\n", Language::Python, ".py", "identifier", "b"),
            ("a + b;\n", Language::TypeScript, ".ts", "identifier", "b"),
            ("print(a, b)\n", Language::Lua, ".lua", "identifier", "b"),
            ("a\n", Language::Ruby, ".rb", "identifier", "a"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.prev_sibling(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "prev_sibling", kind, text),
                "prev_sibling mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn next_named_sibling_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("a + b\n", Language::Ruby, ".rb", "identifier", "a"),
            ("a + b\n", Language::Python, ".py", "identifier", "a"),
            ("a + b;\n", Language::TypeScript, ".ts", "identifier", "a"),
            ("print(a, b)\n", Language::Lua, ".lua", "identifier", "a"),
            ("a\n", Language::Ruby, ".rb", "identifier", "a"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.next_named_sibling(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "next_named_sibling",
                    kind,
                    text
                ),
                "next_named_sibling mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ternary_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(cond, a, b)\n  cond ? a : b\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "cond ? a : b",
            ),
            (
                "value = a if cond else b\n",
                Language::Python,
                ".py",
                "conditional_expression",
                "a if cond else b",
            ),
            (
                "const value = cond ? a : b;\n",
                Language::TypeScript,
                ".ts",
                "ternary_expression",
                "cond ? a : b",
            ),
            (
                "local value = cond and a or b\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "cond and a or b",
            ),
            (
                "def f(cond)\n  cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "cond",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ternary_statement(node),
                ruby_private_predicate(source, language, suffix, "ternary_statement?", kind, text),
                "ternary_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_ternary_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(cond, a, b)\n  cond ? a : b\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "cond ? a : b",
            ),
            (
                "value = a if cond else b\n",
                Language::Python,
                ".py",
                "conditional_expression",
                "a if cond else b",
            ),
            (
                "const value = cond ? a : b;\n",
                Language::TypeScript,
                ".ts",
                "ternary_expression",
                "cond ? a : b",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_ternary_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_ternary_statement",
                    kind,
                    text
                ),
                "normalize_ternary_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ternary_statement_normalization_matches_ruby() {
        for (source, language, suffix, if_text) in [
            (
                "def f(cond, a, b)\n  cond ? a : b\nend\n",
                Language::Ruby,
                ".rb",
                "cond ? a : b",
            ),
            (
                "def f(cond, a, b):\n    return a if cond else b\n",
                Language::Python,
                ".py",
                "a if cond else b",
            ),
            (
                "function f(cond: boolean, a: number, b: number) { return cond ? a : b; }\n",
                Language::TypeScript,
                ".ts",
                "cond ? a : b",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let if_node = first_node(&root, "IF", if_text);
            assert_eq!(child_node(if_node, 0).text, "cond");
            assert_eq!(child_node(if_node, 1).text, "a");
            assert_eq!(child_node(if_node, 2).text, "b");
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn case_argument_list_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(x)\n  return case x\n  when 1 then :one\n  else :other\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "case x\n  when 1 then :one\n  else :other\n  end",
            ),
            (
                "case x\nwhen 1 then :one\nelse :other\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case x\nwhen 1 then :one\nelse :other\nend",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "case_clause",
                "case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); break; }\n",
                Language::TypeScript,
                ".ts",
                "switch_case",
                "case 1: one(); break;",
            ),
            (
                "if value == 1 then one() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.case_argument_list(node),
                ruby_private_predicate(source, language, suffix, "case_argument_list?", kind, text),
                "case_argument_list? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn leading_function_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def outer\n  def inner\n    x\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "def inner\n    x\n  end",
            ),
            (
                "def outer():\n    def inner():\n        x\n",
                Language::Python,
                ".py",
                "block",
                "def inner():\n        x",
            ),
            (
                "function outer()\n  function inner()\n    x()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "function inner()\n    x()\n  end",
            ),
            (
                "function outer() { function inner() { x; } }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function inner() { x; }",
            ),
            (
                "def outer\n  x\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.leading_function_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "leading_function_statement?",
                    kind,
                    text
                ),
                "leading_function_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_leading_function_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def outer\n  def inner\n    x\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "def inner\n    x\n  end",
            ),
            (
                "def outer():\n    def inner():\n        x\n",
                Language::Python,
                ".py",
                "block",
                "def inner():\n        x",
            ),
            (
                "function outer()\n  function inner()\n    x()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "function inner()\n    x()\n  end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_leading_function_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_leading_function_statement",
                    kind,
                    text
                ),
                "normalize_leading_function_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn leading_function_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            (
                "def outer\n  def inner\n    x\n  end\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "def outer():\n    def inner():\n        x\n",
                Language::Python,
                ".py",
            ),
            (
                "function outer()\n  function inner()\n    x()\n  end\nend\n",
                Language::Lua,
                ".lua",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut defns = Vec::new();
            nodes_of_type(&root, "DEFN", &mut defns);
            assert!(
                defns
                    .iter()
                    .any(|node| matches!(node.children.first(), Some(Child::Symbol(name)) if name == "inner")),
                "expected nested DEFN inner for {language:?} in {root:#?}"
            );
            let mut iters = Vec::new();
            nodes_of_type(&root, "ITER", &mut iters);
            assert!(
                iters.iter().all(|node| !node.text.contains("inner")),
                "nested function must not normalize as ITER for {language:?}: {iters:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn leading_owner_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def outer\n  class Inner\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "class Inner\n    value\n  end",
            ),
            (
                "def outer\n  module Inner\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "module Inner\n    value\n  end",
            ),
            (
                "def outer():\n    class Inner:\n        pass\n",
                Language::Python,
                ".py",
                "block",
                "class Inner:\n        pass",
            ),
            (
                "function outer() { class Inner {} }\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Inner {}",
            ),
            (
                "function outer()\n  Inner = {}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "Inner = {}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.leading_owner_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "leading_owner_statement?",
                    kind,
                    text
                ),
                "leading_owner_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_leading_owner_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def outer\n  class Inner\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "class Inner\n    value\n  end",
            ),
            (
                "def outer\n  module Inner\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "module Inner\n    value\n  end",
            ),
            (
                "def outer():\n    class Inner:\n        pass\n",
                Language::Python,
                ".py",
                "block",
                "class Inner:\n        pass",
            ),
            (
                "function outer() { class Inner {} }\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Inner {}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_leading_owner_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_leading_owner_statement",
                    kind,
                    text
                ),
                "normalize_leading_owner_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn modifier_keyword_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value if cond",
            ),
            (
                "def f\n  value unless cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value unless cond",
            ),
            (
                "def f\n  value while cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value while cond",
            ),
            (
                "def f\n  value until cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value until cond",
            ),
            (
                "def f\n  if cond\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "if cond\n    value\n  end",
            ),
            (
                "def f():\n    if cond:\n        value()\n",
                Language::Python,
                ".py",
                "block",
                "if cond:\n        value()",
            ),
            (
                "function f() { if (cond) { value(); } }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (cond) { value(); }",
            ),
            (
                "function f()\n  if cond then\n    value()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if cond then\n    value()\n  end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.modifier_keyword(node).unwrap_or_default();

            assert_eq!(
                rust,
                ruby_private_string(source, language, suffix, "modifier_keyword", kind, text),
                "modifier_keyword mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn modifier_parts_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value if cond",
            ),
            (
                "def f\n  value unless cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value unless cond",
            ),
            (
                "def f\n  if cond\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "if cond\n    value\n  end",
            ),
            (
                "def f():\n    if cond:\n        value()\n",
                Language::Python,
                ".py",
                "block",
                "if cond:\n        value()",
            ),
            (
                "function f() { if (cond) { value(); } }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (cond) { value(); }",
            ),
            (
                "function f()\n  if cond then\n    value()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if cond then\n    value()\n  end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.modifier_parts(node).map(|(action, condition)| {
                (
                    (
                        action.kind().to_string(),
                        super::node_text(action, source).to_string(),
                    ),
                    (
                        condition.kind().to_string(),
                        super::node_text(condition, source).to_string(),
                    ),
                )
            });

            assert_eq!(
                rust,
                ruby_private_modifier_parts_signature(source, language, suffix, kind, text),
                "modifier_parts mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn modifier_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value if cond",
            ),
            (
                "def f\n  return value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "return value if cond",
            ),
            (
                "def f\n  if cond\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "if cond\n    value\n  end",
            ),
            (
                "def f():\n    if cond:\n        value()\n",
                Language::Python,
                ".py",
                "block",
                "if cond:\n        value()",
            ),
            (
                "function f() { if (cond) { value(); } }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (cond) { value(); }",
            ),
            (
                "function f()\n  if cond then\n    value()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if cond then\n    value()\n  end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.modifier_statement(node),
                ruby_private_predicate(source, language, suffix, "modifier_statement?", kind, text),
                "modifier_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_modifier_action_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "return value if cond\n",
                Language::Ruby,
                ".rb",
                "return",
                "return value",
            ),
            ("break if done\n", Language::Ruby, ".rb", "break", "break"),
            (
                "value if cond\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_modifier_action(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_modifier_action",
                    kind,
                    text
                ),
                "normalize_modifier_action mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_modifier_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value if cond",
            ),
            (
                "def f\n  value unless cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value unless cond",
            ),
            (
                "def f\n  value while cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value while cond",
            ),
            (
                "def f\n  value until cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value until cond",
            ),
            (
                "def f\n  return value if cond\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "return value if cond",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_modifier_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_modifier_statement",
                    kind,
                    text
                ),
                "normalize_modifier_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn modifier_return_action_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "return value if ready\n",
                Language::Ruby,
                ".rb",
                "return",
                "return value",
            ),
            ("break if done\n", Language::Ruby, ".rb", "break", "break"),
            ("next if skip\n", Language::Ruby, ".rb", "next", "next"),
            (
                "return value if ready\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "ready",
            ),
            (
                "def f():\n    return value\n    break\n    continue\n",
                Language::Python,
                ".py",
                "return_statement",
                "return value",
            ),
            (
                "def f():\n    return value\n    break\n    continue\n",
                Language::Python,
                ".py",
                "break_statement",
                "break",
            ),
            (
                "def f():\n    return value\n    break\n    continue\n",
                Language::Python,
                ".py",
                "continue_statement",
                "continue",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "function f() { return value; break; continue; }\n",
                Language::TypeScript,
                ".ts",
                "return_statement",
                "return value;",
            ),
            (
                "function f() { return value; break; continue; }\n",
                Language::TypeScript,
                ".ts",
                "break_statement",
                "break;",
            ),
            (
                "function f() { return value; break; continue; }\n",
                Language::TypeScript,
                ".ts",
                "continue_statement",
                "continue;",
            ),
            (
                "function f() { return value; }\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "return_statement",
                "return value",
            ),
            (
                "return value\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.modifier_return_action(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "modifier_return_action?",
                    kind,
                    text
                ),
                "modifier_return_action? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn call_block_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "items.each do |item|\n  item\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.each do |item|\n  item\nend",
            ),
            (
                "items.map { |item| item }\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.map { |item| item }",
            ),
            (
                "def f\n  items.map { |item| item }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items.map { |item| item }",
            ),
            ("items.each\n", Language::Ruby, ".rb", "call", "items.each"),
            (
                "def f():\n    value()\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    value()",
            ),
            (
                "function f()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f()\n  value()\nend",
            ),
            (
                "function f() { value(); }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f() { value(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.call_block(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(source, language, suffix, "call_block", kind, text),
                "call_block mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn statement_block_call_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  items.map { |item| item }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items.map { |item| item }",
            ),
            (
                "items.map { |item| item }\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.map { |item| item }",
            ),
            (
                "def f\n  foo(bar) { baz }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo(bar) { baz }",
            ),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "def f():\n    value()\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    value()",
            ),
            (
                "user.name();\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "function f() { value(); }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f() { value(); }",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
            (
                "function f()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f()\n  value()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let found = normalizer.statement_block_call(node).map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });

            assert_eq!(
                found,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "statement_block_call",
                    kind,
                    text
                ),
                "statement_block_call mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn statement_call_with_block_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  items.map { |item| item }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items.map { |item| item }",
            ),
            (
                "items.map { |item| item }\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.map { |item| item }",
            ),
            (
                "def f\n  foo(bar) { baz }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo(bar) { baz }",
            ),
            (
                "def f\n  items.map\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items.map",
            ),
            (
                "def f():\n    value(lambda item: item)\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    value(lambda item: item)",
            ),
            (
                "items.map(item => item);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "items.map(item => item);",
            ),
            (
                "items:map(function(item) return item end)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "items:map(function(item) return item end)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.statement_call_with_block(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "statement_call_with_block?",
                    kind,
                    text
                ),
                "statement_call_with_block? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_statement_call_with_block_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [(
            "def f\n  items.map { |item| item }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items.map { |item| item }",
        )] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_statement_call_with_block(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_statement_call_with_block",
                    kind,
                    text
                ),
                "normalize_statement_call_with_block mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn visibility_inline_def_call_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "private def hidden; value; end\n",
                Language::Ruby,
                ".rb",
                "call",
                "private def hidden; value; end",
            ),
            (
                "public def visible\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "public def visible\n  value\nend",
            ),
            (
                "private :hidden\n",
                Language::Ruby,
                ".rb",
                "call",
                "private :hidden",
            ),
            (
                "private(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "private(value)",
            ),
            (
                "private(value);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "private(value)",
            ),
            (
                "private(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "private(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.visibility_inline_def_call(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "visibility_inline_def_call?",
                    kind,
                    text
                ),
                "visibility_inline_def_call? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn visibility_inline_def_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "private def hidden\n    value\n  end",
            ),
            (
                "class C\n  module_function def helper\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "module_function def helper\n    value\n  end",
            ),
            (
                "class C\n  private :hidden\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "private :hidden",
            ),
            (
                "private(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "private(value)",
            ),
            (
                "private(value);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "private(value);",
            ),
            (
                "private(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "private(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let function = normalizer.named_children(node).into_iter().next().expect(
                "visibility_inline_def_statement test target should have a first named child",
            );

            assert_eq!(
                normalizer.visibility_inline_def_statement(node, function),
                ruby_private_visibility_inline_def_statement_predicate(
                    source, language, suffix, kind, text
                ),
                "visibility_inline_def_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_visibility_inline_def_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "private def hidden\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "private def hidden\n  value\nend",
            ),
            (
                "public def visible\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "public def visible\n  value\nend",
            ),
            (
                "module_function def self.helper\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "module_function def self.helper\n  value\nend",
            ),
            (
                "private(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "private(value)",
            ),
            (
                "private(value);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "private(value)",
            ),
            (
                "private(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "private(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_visibility_inline_def(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_visibility_inline_def",
                    kind,
                    text
                ),
                "normalize_visibility_inline_def mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_def_from_argument_list_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def hidden\n    value\n  end",
            ),
            (
                "class C\n  private def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def self.hidden\n    value\n  end",
            ),
            (
                "class C\n  private :hidden\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":hidden",
            ),
            (
                "private(value)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(value)",
            ),
            (
                "private(value);\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(value)",
            ),
            (
                "private(value)\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .inline_def_from_argument_list(Some(node))
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "inline_def_from_argument_list",
                    kind,
                    text
                ),
                "inline_def_from_argument_list mismatch for {language:?} {kind} {text:?}"
            );
        }

        for (source, language, suffix) in [
            ("private def hidden\n  value\nend\n", Language::Ruby, ".rb"),
            ("private(value)\n", Language::Python, ".py"),
            ("private(value);\n", Language::TypeScript, ".ts"),
            ("private(value)\n", Language::Lua, ".lua"),
        ] {
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .inline_def_from_argument_list(None)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_inline_def_from_argument_list_nil_value(source, language, suffix),
                "inline_def_from_argument_list nil mismatch for {language:?}"
            );
        }
    }

    #[test]
    fn inline_def_from_source_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def hidden\n    value\n  end",
            ),
            (
                "class C\n  private def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def self.hidden\n    value\n  end",
            ),
            (
                "def hidden\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def hidden\n  value\nend",
            ),
            (
                "def self.hidden\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "singleton_method",
                "def self.hidden\n  value\nend",
            ),
            (
                "class C\n  private :hidden\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":hidden",
            ),
            (
                "def hidden():\n    value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def hidden():\n    value",
            ),
            (
                "function hidden() {\n  value;\n}\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function hidden() {\n  value;\n}",
            ),
            (
                "function hidden()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function hidden()\n  value()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .inline_def_from_source(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "inline_def_from_source",
                    kind,
                    text
                ),
                "inline_def_from_source mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_def_from_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "private def hidden\n    value\n  end",
            ),
            (
                "class C\n  module_function def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "module_function def self.hidden\n    value\n  end",
            ),
            (
                "private def hidden\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "private def hidden\n  value\nend",
            ),
            (
                "class C\n  private :hidden\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "private :hidden",
            ),
            (
                "private(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "private(value)",
            ),
            (
                "private(value);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "private(value);",
            ),
            (
                "private(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "private(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .inline_def_from_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "inline_def_from_statement",
                    kind,
                    text
                ),
                "inline_def_from_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_def_body_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def hidden\n    value\n  end",
            ),
            (
                "class C\n  private def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def self.hidden\n    value\n  end",
            ),
            (
                "class C\n  private def empty\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def empty\n  end",
            ),
            (
                "def hidden():\n    value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def hidden():\n    value",
            ),
            (
                "function hidden() {\n  value;\n}\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function hidden() {\n  value;\n}",
            ),
            (
                "function hidden()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function hidden()\n  value()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.inline_def_body(node).map(|body| {
                (
                    body.kind().to_string(),
                    super::node_text(body, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "inline_def_body",
                    kind,
                    text
                ),
                "inline_def_body mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_def_receiver_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def hidden\n    value\n  end",
            ),
            (
                "class C\n  private def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def self.hidden\n    value\n  end",
            ),
            (
                "class C\n  private def Owner.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def Owner.hidden\n    value\n  end",
            ),
            (
                "class C\n  private def Owner::Nested.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def Owner::Nested.hidden\n    value\n  end",
            ),
            (
                "def hidden():\n    value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def hidden():\n    value",
            ),
            (
                "function hidden() {\n  value;\n}\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function hidden() {\n  value;\n}",
            ),
            (
                "function hidden()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function hidden()\n  value()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.inline_def_receiver(node).map(|receiver| {
                (
                    receiver.kind().to_string(),
                    super::node_text(receiver, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "inline_def_receiver",
                    kind,
                    text
                ),
                "inline_def_receiver mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_def_name_after_receiver_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class C\n  private def self.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def self.hidden\n    value\n  end",
            ),
            (
                "class C\n  private def Owner.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def Owner.hidden\n    value\n  end",
            ),
            (
                "class C\n  private def Owner::Nested.hidden\n    value\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "def Owner::Nested.hidden\n    value\n  end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let receiver = normalizer
                .inline_def_receiver(node)
                .expect("inline def receiver should exist for name-after-receiver case");
            let rust = normalizer
                .inline_def_name_after_receiver(node, receiver)
                .unwrap_or_default();

            assert_eq!(
                rust,
                ruby_private_inline_def_name_after_receiver(source, language, suffix, kind, text),
                "inline_def_name_after_receiver mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn inline_parameter_begin_marker_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(a); a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a); a; end",
            ),
            (
                "def f a; a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f a; a; end",
            ),
            (
                "def f(a)\n  a\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a)\n  a\nend",
            ),
            (
                "def f(a):\n    return a\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f(a):\n    return a",
            ),
            (
                "function f(a) { return a; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f(a) { return a; }",
            ),
            (
                "function f(a)\n  return a\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f(a)\n  return a\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .inline_parameter_begin_marker(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_inline_parameter_begin_marker_value(
                    source, language, suffix, kind, text
                ),
                "inline_parameter_begin_marker mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn prepend_inline_parameter_begin_matches_ruby_private_method() {
        let scalar = test_node("VCALL", Vec::new());
        let block = test_node(
            "BLOCK",
            vec![Child::Node(Box::new(scalar.clone())), Child::Nil],
        );
        let empty_block = test_node("BLOCK", vec![Child::Nil]);

        let cases = vec![
            (
                "no_marker",
                "def f(a)\n  a\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a)\n  a\nend",
                Some(scalar.clone()),
            ),
            (
                "marker_nil_body",
                "def f(a); a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a); a; end",
                None,
            ),
            (
                "marker_scalar_body",
                "def f(a); a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a); a; end",
                Some(scalar.clone()),
            ),
            (
                "marker_block_body",
                "def f(a); a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a); a; end",
                Some(block),
            ),
            (
                "marker_empty_block",
                "def f(a); a; end\n",
                Language::Ruby,
                ".rb",
                "method",
                "def f(a); a; end",
                Some(empty_block),
            ),
            (
                "non_ruby",
                "def f(a):\n    return a\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f(a):\n    return a",
                Some(scalar),
            ),
        ];

        for (label, source, language, suffix, kind, text, body) in cases {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .prepend_inline_parameter_begin(node, body.clone())
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);
            let body_value = body.as_ref().map(node_value).unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_prepend_inline_parameter_begin_value(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    &body_value,
                ),
                "prepend_inline_parameter_begin mismatch for {label}"
            );
        }
    }

    #[test]
    fn scalar_argument_list_value_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  return yield\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "yield",
            ),
            (
                "def f\n  return nil\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "nil",
            ),
            (
                "def f\n  return true\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "true",
            ),
            (
                "def f\n  return false\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "false",
            ),
            (
                "def f\n  return :ok?\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":ok?",
            ),
            (
                "def f\n  return 12\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "12",
            ),
            (
                "def f\n  return -12\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "-12",
            ),
            (
                "def f\n  return name\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "name",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "function f() { return value; }\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "function f()\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "value",
            ),
            (
                "function f() { return yield; }\n",
                Language::TypeScript,
                ".ts",
                "yield_expression",
                "yield",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .scalar_argument_list_value(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "scalar_argument_list_value",
                    kind,
                    text,
                ),
                "scalar_argument_list_value mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn local_or_call_for_name_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, name, local) in [
            (
                "def f\n  {name:}\nend\n",
                Language::Ruby,
                ".rb",
                "hash_key_symbol",
                "name",
                "name",
                false,
            ),
            (
                "def f\n  {name:}\nend\n",
                Language::Ruby,
                ".rb",
                "hash_key_symbol",
                "name",
                "name",
                true,
            ),
            (
                "def f():\n    value\n",
                Language::Python,
                ".py",
                "identifier",
                "f",
                "f",
                false,
            ),
            (
                "function f() { value; }\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
                "value",
                false,
            ),
            (
                "function f()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "identifier",
                "value",
                "value",
                false,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            if local {
                normalizer
                    .local_stack
                    .push(BTreeSet::from([name.to_string()]));
            }
            let rust = node_value(&normalizer.local_or_call_for_name(name, node));

            assert_eq!(
                rust,
                ruby_private_local_or_call_for_name_value(
                    source, language, suffix, kind, text, name, local
                ),
                "local_or_call_for_name mismatch for {language:?} {name:?} local={local}"
            );
        }
    }

    #[test]
    fn literal_arguments_from_text_normalization_matches_ruby() {
        let symbol_source = "puts :ok\n";
        let root = parse_language_source(symbol_source, Language::Ruby, ".rb");
        let fcall = first_node(&root, "FCALL", "puts :ok");
        assert_eq!(
            fcall.children.first(),
            Some(&Child::Symbol("puts".to_string()))
        );
        let args = child_node(fcall, 1);
        assert_eq!(args.r#type, "LIST");
        let lit = child_node(args, 0);
        assert_eq!(lit.r#type, "LIT");
        assert_eq!(lit.children.first(), Some(&Child::Symbol("ok".to_string())));
        assert_ruby_parity(symbol_source, Language::Ruby, ".rb");

        let heredoc_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
        let root = parse_language_source(heredoc_source, Language::Ruby, ".rb");
        let fcall = first_node(&root, "FCALL", "puts <<~TXT");
        let args = child_node(fcall, 1);
        assert_eq!(args.r#type, "LIST");
        let dstr = child_node(args, 0);
        assert_eq!(dstr.r#type, "DSTR");
        assert_eq!(child_types(dstr), vec!["STR"]);
        let body = child_node(dstr, 0);
        assert_eq!(
            body.children.first(),
            Some(&Child::String("\n    hi\n  ".to_string()))
        );
        assert_ruby_parity(heredoc_source, Language::Ruby, ".rb");
    }

    #[test]
    fn literal_symbol_arguments_matches_ruby_scan_contract() {
        assert_eq!(
            super::literal_symbol_arguments(":one, :two?, :three!, :four=, :1, ::Name"),
            vec![
                "one".to_string(),
                "two?".to_string(),
                "three!".to_string(),
                "four=".to_string(),
                "Name".to_string(),
            ]
        );
    }

    #[test]
    fn elide_tail_returns_matches_ruby_private_method() {
        let leaf = |node_type: &str| test_node(node_type, vec![Child::String("value".to_string())]);
        let return_leaf = || test_node("RETURN", vec![Child::Node(Box::new(leaf("LVAR")))]);
        let protected_def = test_node(
            "DEFN",
            vec![
                Child::Symbol("kept".to_string()),
                Child::Node(Box::new(test_node(
                    "SCOPE",
                    vec![Child::Nil, Child::Nil, Child::Node(Box::new(return_leaf()))],
                ))),
            ],
        );
        let cases = vec![
            None,
            Some(return_leaf()),
            Some(test_node(
                "BLOCK",
                vec![
                    Child::Node(Box::new(leaf("LVAR"))),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "SCOPE",
                vec![Child::Nil, Child::Nil, Child::Node(Box::new(return_leaf()))],
            )),
            Some(test_node(
                "IF",
                vec![
                    Child::Node(Box::new(leaf("COND"))),
                    Child::Node(Box::new(return_leaf())),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "UNLESS",
                vec![
                    Child::Node(Box::new(leaf("COND"))),
                    Child::Node(Box::new(return_leaf())),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "CASE",
                vec![
                    Child::Node(Box::new(leaf("LVAR"))),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "CASE2",
                vec![Child::Node(Box::new(return_leaf()))],
            )),
            Some(test_node(
                "WHEN",
                vec![
                    Child::Node(Box::new(leaf("LIST"))),
                    Child::Node(Box::new(return_leaf())),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "RESCUE",
                vec![
                    Child::Node(Box::new(return_leaf())),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(test_node(
                "RESBODY",
                vec![
                    Child::Node(Box::new(leaf("LIST"))),
                    Child::Node(Box::new(return_leaf())),
                    Child::Node(Box::new(return_leaf())),
                ],
            )),
            Some(protected_def),
        ];
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

        for node in cases {
            let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
            let rust = normalizer
                .elide_tail_returns(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_elide_tail_returns_value(&input, true),
                "elide_tail_returns mismatch for input {input}"
            );
        }

        let non_ruby = Some(return_leaf());
        let input = non_ruby.as_ref().map(node_value).unwrap_or(Value::Null);
        let normalizer = super::TreeSitterNormalizer::new("", Language::Python);
        let rust = normalizer
            .elide_tail_returns(non_ruby)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(rust, input);
        assert_eq!(ruby_private_elide_tail_returns_value(&input, false), input);
    }

    #[test]
    fn elide_implicit_nil_body_matches_ruby_private_method() {
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        let leaf = || test_node("LVAR", vec![Child::String("value".to_string())]);
        let nil_node = || test_node("NIL", Vec::new());
        let cases = vec![
            None,
            Some(nil_node()),
            Some(leaf()),
            Some(test_node(
                "BLOCK",
                vec![
                    Child::Node(Box::new(leaf())),
                    Child::Node(Box::new(nil_node())),
                    Child::Node(Box::new(nil_node())),
                ],
            )),
            Some(test_node(
                "BLOCK",
                vec![Child::Nil, Child::Node(Box::new(nil_node()))],
            )),
            Some(test_node(
                "BLOCK",
                vec![
                    Child::Node(Box::new(leaf())),
                    Child::Node(Box::new(leaf())),
                    Child::Node(Box::new(nil_node())),
                ],
            )),
        ];

        for node in cases {
            let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
            let rust = normalizer
                .elide_implicit_nil_body(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_elide_implicit_nil_body_value(&input, true),
                "elide_implicit_nil_body mismatch for input {input}"
            );
        }

        let non_ruby = Some(nil_node());
        let input = non_ruby.as_ref().map(node_value).unwrap_or(Value::Null);
        let normalizer = super::TreeSitterNormalizer::new("", Language::Python);
        let rust = normalizer
            .elide_implicit_nil_body(non_ruby)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(rust, input);
        assert_eq!(
            ruby_private_elide_implicit_nil_body_value(&input, false),
            input
        );
    }

    #[test]
    fn drop_trailing_nil_statement_matches_ruby_private_method() {
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        let leaf = |node_type: &str| test_node(node_type, vec![Child::Symbol("value".to_string())]);
        let nil_node = || test_node("NIL", Vec::new());
        let block = |children| test_node("BLOCK", children);

        for node in [
            None,
            Some(nil_node()),
            Some(block(vec![
                Child::Node(Box::new(leaf("LASGN"))),
                Child::Node(Box::new(nil_node())),
            ])),
            Some(block(vec![
                Child::Node(Box::new(leaf("LASGN"))),
                Child::Node(Box::new(nil_node())),
                Child::Node(Box::new(nil_node())),
            ])),
            Some(block(vec![
                Child::Node(Box::new(leaf("LASGN"))),
                Child::Nil,
                Child::Node(Box::new(nil_node())),
            ])),
            Some(block(vec![Child::Nil, Child::Node(Box::new(nil_node()))])),
            Some(block(vec![
                Child::Node(Box::new(leaf("LASGN"))),
                Child::Nil,
                Child::Node(Box::new(leaf("VCALL"))),
            ])),
            Some(block(vec![
                Child::Node(Box::new(leaf("LASGN"))),
                Child::Nil,
                Child::Node(Box::new(leaf("VCALL"))),
                Child::Node(Box::new(nil_node())),
            ])),
        ] {
            let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
            let rust = normalizer
                .drop_trailing_nil_statement(node)
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_drop_trailing_nil_statement_value(&input),
                "drop_trailing_nil_statement mismatch for input {input}"
            );
        }
    }

    #[test]
    fn symbol_literal_node_matches_ruby_private_predicate() {
        let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
        for (node, node_type, child_kind) in [
            (None, None, None),
            (
                Some(test_node("LIT", vec![Child::Symbol("value".to_string())])),
                Some("LIT"),
                Some("symbol"),
            ),
            (
                Some(test_node("LIT", vec![Child::String("value".to_string())])),
                Some("LIT"),
                Some("string"),
            ),
            (Some(test_node("LIT", Vec::new())), Some("LIT"), None),
            (
                Some(test_node("STR", vec![Child::Symbol("value".to_string())])),
                Some("STR"),
                Some("symbol"),
            ),
            (
                Some(test_node(
                    "LIT",
                    vec![Child::Node(Box::new(test_node("NIL", Vec::new())))],
                )),
                Some("LIT"),
                Some("node"),
            ),
            (
                Some(test_node("LIT", vec![Child::Nil])),
                Some("LIT"),
                Some("nil"),
            ),
        ] {
            assert_eq!(
                normalizer.symbol_literal_node(node.as_ref()),
                ruby_private_symbol_literal_node_predicate(node_type, child_kind),
                "symbol_literal_node? mismatch for node_type={node_type:?} child_kind={child_kind:?}"
            );
        }
    }

    #[test]
    fn same_ts_node_matches_ruby_private_predicate() {
        for (
            source,
            language,
            suffix,
            left_kind,
            left_text,
            left_index,
            right_kind,
            right_text,
            right_index,
        ) in [
            (
                "value\nvalue\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                0,
                "identifier",
                "value",
                0,
            ),
            (
                "value\nvalue\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                0,
                "identifier",
                "value",
                1,
            ),
            (
                "value\nvalue\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
                0,
                "expression_statement",
                "value",
                0,
            ),
            (
                "value\nvalue\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
                0,
                "expression_statement",
                "value",
                1,
            ),
            (
                "value;\nvalue;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "value;",
                0,
                "expression_statement",
                "value;",
                1,
            ),
            (
                "value()\nvalue()\n",
                Language::Lua,
                ".lua",
                "function_call",
                "value()",
                0,
                "function_call",
                "value()",
                0,
            ),
            (
                "value()\nvalue()\n",
                Language::Lua,
                ".lua",
                "function_call",
                "value()",
                0,
                "function_call",
                "value()",
                1,
            ),
        ] {
            let tree = raw_tree(source, language);
            let left = nth_raw_node(tree.root_node(), source, left_kind, left_text, left_index);
            let right = nth_raw_node(
                tree.root_node(),
                source,
                right_kind,
                right_text,
                right_index,
            );
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.same_ts_node(left, right),
                ruby_private_same_ts_node_predicate(
                    source,
                    language,
                    suffix,
                    left_kind,
                    left_text,
                    left_index,
                    right_kind,
                    right_text,
                    right_index
                ),
                "same_ts_node? mismatch for {language:?} {left_kind}:{left_text:?}[{left_index}] vs {right_kind}:{right_text:?}[{right_index}]"
            );
        }
    }

    #[test]
    fn parent_named_child_matches_ruby_private_predicate() {
        for (
            source,
            language,
            suffix,
            parent_kind,
            parent_text,
            parent_index,
            child_kind,
            child_text,
            child_index,
        ) in [
            (
                "def f\n  {name:}\nend\n",
                Language::Ruby,
                ".rb",
                "pair",
                "name:",
                0,
                "hash_key_symbol",
                "name",
                0,
            ),
            (
                "def f\n  {name:}\nend\n",
                Language::Ruby,
                ".rb",
                "pair",
                "name:",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "def f():\n    value\n",
                Language::Python,
                ".py",
                "function_definition",
                "def f():\n    value",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "def f():\n    value\n",
                Language::Python,
                ".py",
                "block",
                "value",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "function f() { value; }\n",
                Language::TypeScript,
                ".ts",
                "function_declaration",
                "function f() { value; }",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "function f() { value; }\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{ value; }",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "function f()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "function_declaration",
                "function f()\n  value()\nend",
                0,
                "identifier",
                "f",
                0,
            ),
            (
                "function f()\n  value()\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "value()",
                0,
                "identifier",
                "f",
                0,
            ),
        ] {
            let tree = raw_tree(source, language);
            let parent = nth_raw_node(
                tree.root_node(),
                source,
                parent_kind,
                parent_text,
                parent_index,
            );
            let child = nth_raw_node(
                tree.root_node(),
                source,
                child_kind,
                child_text,
                child_index,
            );
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.parent_named_child(parent, child),
                ruby_private_parent_named_child_predicate(
                    source,
                    language,
                    suffix,
                    parent_kind,
                    parent_text,
                    parent_index,
                    child_kind,
                    child_text,
                    child_index
                ),
                "parent_named_child? mismatch for {language:?} {parent_kind}:{parent_text:?}[{parent_index}] -> {child_kind}:{child_text:?}[{child_index}]"
            );
        }
    }

    #[test]
    fn node_key_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, index) in [
            (
                "value\nvalue\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                0,
            ),
            (
                "value\nvalue\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                1,
            ),
            (
                "value\nvalue\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
                1,
            ),
            (
                "value;\nvalue;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "value;",
                0,
            ),
            (
                "value()\nvalue()\n",
                Language::Lua,
                ".lua",
                "function_call",
                "value()",
                1,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = nth_raw_node(tree.root_node(), source, kind, text, index);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.node_key(node),
                ruby_private_node_key_signature(source, language, suffix, kind, text, index),
                "node_key mismatch for {language:?} {kind}:{text:?}[{index}]"
            );
        }
    }

    #[test]
    fn bare_identifier_text_matches_ruby_private_predicate() {
        for text in [
            "value",
            "_value",
            "value1",
            "value?",
            "value!",
            "value=",
            " value? ",
            "",
            "1value",
            "value-name",
            "value?name",
            "value??",
            "value!=",
            "value =",
        ] {
            assert_eq!(
                super::bare_identifier_text(text),
                ruby_private_text_predicate(Language::Ruby, "bare_identifier_text?", text),
                "bare_identifier_text? mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn hidden_match_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "match(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "match(value)",
            ),
            (
                "match value:\n    case 1:\n        result\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        result",
            ),
            (
                "match(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "match(value)",
            ),
            (
                "match(value);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "match(value);",
            ),
            (
                "match(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "match(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.hidden_match(node),
                ruby_private_predicate(source, language, suffix, "hidden_match?", kind, text),
                "hidden_match? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn kind_type_matches_ruby_private_method() {
        for kind in [
            "",
            "body_statement",
            "block_body",
            "block",
            "statements",
            "expression_statement",
            "alreadyCAPS",
            "argument-list??",
            "foo__bar",
            "123kind",
            "é_node",
        ] {
            assert_eq!(
                super::kind_type(kind),
                ruby_private_text_string(Language::Ruby, "kind_type", kind),
                "kind_type mismatch for {kind:?}"
            );
        }
    }

    #[test]
    fn ts_node_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("ready?\n", Language::Ruby, ".rb", "call", "ready?"),
            (
                "value\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value",
            ),
            (
                "let value = 1;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);

            assert_eq!(
                super::ts_node(Some(node)),
                ruby_private_predicate(source, language, suffix, "ts_node?", kind, text),
                "ts_node? raw-node mismatch for {language:?} {kind}:{text:?}"
            );
        }

        assert_eq!(super::ts_node(None), ruby_private_ts_node_value("nil"));
        assert!(!ruby_private_ts_node_value("string"));
        assert!(!ruby_private_ts_node_value("normalized_node"));
    }

    #[test]
    fn command_call_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  puts value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "puts value",
            ),
            (
                "def f\n  foo { value }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { value }",
            ),
            (
                "def f\n  foo\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo",
            ),
            (
                "def f\n  user.name value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name value",
            ),
            (
                "print(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "print(value)",
            ),
            (
                "console.log(value);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "console.log(value);",
            ),
            (
                "print(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "print(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.command_call_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "command_call_statement?",
                    kind,
                    text
                ),
                "command_call_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_command_call_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  puts value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "puts value",
            ),
            (
                "def f\n  foo { value }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { value }",
            ),
            (
                "print(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "print(value)",
            ),
            (
                "console.log(value);\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "console.log(value);",
            ),
            (
                "print(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "print(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_command_call_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_command_call_statement",
                    kind,
                    text
                ),
                "normalize_command_call_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn zero_child_identifier_call_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("foo?\n", Language::Ruby, ".rb", "call", "foo?"),
            ("foo!\n", Language::Ruby, ".rb", "call", "foo!"),
            ("foo()\n", Language::Ruby, ".rb", "call", "foo()"),
            (
                "foo()\n",
                Language::Python,
                ".py",
                "expression_statement",
                "foo()",
            ),
            (
                "foo();\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "foo()",
            ),
            ("foo()\n", Language::Lua, ".lua", "function_call", "foo()"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.zero_child_identifier_call(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "zero_child_identifier_call?",
                    kind,
                    text
                ),
                "zero_child_identifier_call? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn zero_child_identifier_call_normalization_matches_ruby() {
        for source in ["foo?\n", "foo!\n"] {
            let root = parse_language_source(source, Language::Ruby, ".rb");
            let text = source.trim();
            let vcall = first_node(&root, "VCALL", text);
            assert_eq!(
                vcall.children.first(),
                Some(&Child::Symbol(text.to_string()))
            );
            assert_ruby_parity(source, Language::Ruby, ".rb");
        }
    }

    #[test]
    fn normalize_zero_child_call_matches_ruby_private_method() {
        for source in ["foo?\n", "foo!\n", "foo()\n"] {
            let text = source.trim();
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, "call", text);
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer.normalize_zero_child_call(node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_zero_child_call",
                    "call",
                    text
                ),
                "normalize_zero_child_call mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn normalize_const_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("Foo\n", Language::Ruby, ".rb", "constant", "Foo"),
            (
                "Foo::Bar\n",
                Language::Ruby,
                ".rb",
                "scope_resolution",
                "Foo::Bar",
            ),
            (
                "class Foo::Bar::Baz\nend\n",
                Language::Ruby,
                ".rb",
                "scope_resolution",
                "Foo::Bar::Baz",
            ),
            (
                "type Alias = Foo;\n",
                Language::TypeScript,
                ".ts",
                "type_identifier",
                "Foo",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.normalize_const(node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_const",
                    kind,
                    text
                ),
                "normalize_const mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_receiver_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("value += 1\n", Language::Ruby, ".rb", "identifier", "value"),
            (
                "@value += 1\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "@value",
            ),
            (
                "$value += 1\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            ("VALUE += 1\n", Language::Ruby, ".rb", "constant", "VALUE"),
            (
                "user.value += 1\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.value",
            ),
            (
                "value += 1\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "user.value += 1\n",
                Language::Python,
                ".py",
                "attribute",
                "user.value",
            ),
            (
                "value += 1;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "user.value += 1;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.value",
            ),
            (
                "value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "user.value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "user.value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .assignment_receiver(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "assignment_receiver",
                    kind,
                    text
                ),
                "assignment_receiver mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn assignment_target_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "@value = 1\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "@value",
            ),
            (
                "$value = 1\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            (
                "items[index] = value\n",
                Language::Ruby,
                ".rb",
                "element_reference",
                "items[index]",
            ),
            (
                "user.value = 1\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.value",
            ),
            (
                "user.value = 1\n",
                Language::Python,
                ".py",
                "attribute",
                "user.value",
            ),
            (
                "user.value = 1;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.value",
            ),
            (
                "user.value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "user.value",
            ),
            (
                "value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let source_node = normalizer.parent_node(node).unwrap_or(node);
            let right = normalizer
                .assignment_right(source_node)
                .and_then(|right| normalizer.normalize_node(right));
            let rust = normalizer
                .assignment_target(node, right, source_node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_assignment_target_value(source, language, suffix, kind, text),
                "assignment_target mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn augmented_assignment_value_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, operator) in [
            (
                "value += 1\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
                "+",
            ),
            (
                "@value *= 2\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "@value",
                "*",
            ),
            (
                "$value += 1\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
                "+",
            ),
            (
                "VALUE -= 1\n",
                Language::Ruby,
                ".rb",
                "constant",
                "VALUE",
                "-",
            ),
            (
                "user.value += 1\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.value",
                "+",
            ),
            (
                "value += 1\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
                "+",
            ),
            (
                "user.value += 1\n",
                Language::Python,
                ".py",
                "attribute",
                "user.value",
                "+",
            ),
            (
                "value += 1;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
                "+",
            ),
            (
                "user.value += 1;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.value",
                "+",
            ),
            (
                "value = 1\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
                "+",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let source_node = normalizer.parent_node(node).unwrap_or(node);
            let right_raw = normalizer.assignment_right(source_node);
            let rust =
                normalizer.augmented_assignment_value(node, operator, right_raw, source_node);

            assert_eq!(
                node_value(&rust),
                ruby_private_augmented_assignment_value(
                    source, language, suffix, kind, text, operator
                ),
                "augmented_assignment_value mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn target_name_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "$value = other\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            (
                "VALUE = other\n",
                Language::Ruby,
                ".rb",
                "constant",
                "VALUE",
            ),
            (
                "a, *rest = values\n",
                Language::Ruby,
                ".rb",
                "rest_assignment",
                "*rest",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "let value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                Value::String(normalizer.target_name(node)),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "target_name",
                    kind,
                    text
                ),
                "target_name mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_multiple_assignment_matches_ruby_private_method() {
        for (source, kind, text) in [
            ("a, b = values\n", "assignment", "a, b = values"),
            ("$a, b = values\n", "assignment", "$a, b = values"),
            ("a, *rest = values\n", "assignment", "a, *rest = values"),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let left = normalizer
                .assignment_left(node)
                .expect("multiple assignment should have left side");
            let right = normalizer
                .assignment_right(node)
                .and_then(|right| normalizer.normalize_node(right));
            let rust = normalizer.normalize_multiple_assignment(left, right, node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_multiple_assignment_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    kind,
                    text
                ),
                "normalize_multiple_assignment mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn normalize_assignment_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "value = other",
            ),
            (
                "@value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "@value = other",
            ),
            (
                "$value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "$value = other",
            ),
            (
                "items[index] = value\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "items[index] = value",
            ),
            (
                "user.value = other\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "user.value = other",
            ),
            (
                "a, b = values\n",
                Language::Ruby,
                ".rb",
                "assignment",
                "a, b = values",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "value = other",
            ),
            (
                "user.value = other\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.value = other",
            ),
            (
                "value = other;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "value = other;",
            ),
            (
                "user.value = other;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "user.value = other;",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "value = other",
            ),
            (
                "user.value = other\n",
                Language::Lua,
                ".lua",
                "assignment_statement",
                "user.value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_assignment(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_assignment",
                    kind,
                    text
                ),
                "normalize_assignment mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_assignment_lhs_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "value = other\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "value",
            ),
            (
                "@value = other\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "@value",
            ),
            (
                "$value = other\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "$value",
            ),
            (
                "items[index] = value\n",
                Language::Ruby,
                ".rb",
                "element_reference",
                "items[index]",
            ),
            (
                "user.value = other\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.value",
            ),
            (
                "value = other\n",
                Language::Python,
                ".py",
                "identifier",
                "value",
            ),
            (
                "user.value = other\n",
                Language::Python,
                ".py",
                "attribute",
                "user.value",
            ),
            (
                "value = other;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "value",
            ),
            (
                "user.value = other;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.value",
            ),
            (
                "value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "value",
            ),
            (
                "user.value = other\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "user.value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_assignment_lhs(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_assignment_lhs",
                    kind,
                    text
                ),
                "normalize_assignment_lhs mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_begin_matches_ruby_private_method() {
        for (source, text) in [
            ("begin\n  work\n  done\nend\n", "begin\n  work\n  done\nend"),
            (
                "begin\n  work\nensure\n  cleanup\nend\n",
                "begin\n  work\nensure\n  cleanup\nend",
            ),
            (
                "begin\n  work\nrescue Error => e\n  handle\nend\n",
                "begin\n  work\nrescue Error => e\n  handle\nend",
            ),
            (
                "begin\n  work\nrescue Error => e\n  handle\nensure\n  cleanup\nend\n",
                "begin\n  work\nrescue Error => e\n  handle\nensure\n  cleanup\nend",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, "begin", text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_begin(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_begin",
                    "begin",
                    text
                ),
                "normalize_begin mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn normalize_block_argument_matches_ruby_private_method() {
        for (source, text) in [
            ("foo(&block)\n", "&block"),
            ("foo(&:to_s)\n", "&:to_s"),
            ("foo(&method(:bar))\n", "&method(:bar)"),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, "block_argument", text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_block_argument(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_block_argument",
                    "block_argument",
                    text
                ),
                "normalize_block_argument mismatch for {text:?}"
            );
        }
    }

    #[test]
    fn normalize_body_nodes_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("\n", Language::Ruby, ".rb", "__root__", ""),
            ("value\n", Language::Ruby, ".rb", "__root__", ""),
            ("first\nsecond\n", Language::Ruby, ".rb", "__root__", ""),
            (
                "first()\nsecond()\n",
                Language::Python,
                ".py",
                "__root__",
                "",
            ),
            (
                "first();\nsecond();\n",
                Language::TypeScript,
                ".ts",
                "__root__",
                "",
            ),
            ("first()\nsecond()\n", Language::Lua, ".lua", "__root__", ""),
        ] {
            let tree = raw_tree(source, language);
            let target = if kind == "__root__" {
                tree.root_node()
            } else {
                first_raw_node(tree.root_node(), source, kind, text)
            };
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let nodes = normalizer.named_children(target);
            let rust = normalizer
                .normalize_body_nodes(nodes, target)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_body_nodes_value(source, language, suffix, kind, text),
                "normalize_body_nodes mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_children_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  one\n  two\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "one\n  two",
            ),
            (
                "def f\n  value = other\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value = other",
            ),
            (
                "def f\n  x = <<~TXT\n    hi\n  TXT\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x = <<~TXT\n    hi\n  TXT",
            ),
            (
                "def f():\n    one()\n    two()\n",
                Language::Python,
                ".py",
                "block",
                "one()\n    two()",
            ),
            (
                "def f():\n    value = other\n",
                Language::Python,
                ".py",
                "block",
                "value = other",
            ),
            (
                "function f(){ one(); two(); }\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{ one(); two(); }",
            ),
            (
                "function f(){ value = other; }\n",
                Language::TypeScript,
                ".ts",
                "assignment_expression",
                "value = other",
            ),
            (
                "function f()\n  one()\n  two()\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "one()\n  two()",
            ),
            (
                "function f()\n  value = other\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = children_value(&normalizer.normalize_children(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_children",
                    kind,
                    text
                ),
                "normalize_children mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_class_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "class Thing; end\n",
                Language::Ruby,
                ".rb",
                "class",
                "class Thing; end",
            ),
            (
                "class Thing:\n    pass\n",
                Language::Python,
                ".py",
                "class_definition",
                "class Thing:\n    pass",
            ),
            (
                "class Thing {}\n",
                Language::TypeScript,
                ".ts",
                "class_declaration",
                "class Thing {}",
            ),
            (
                "local Thing = {}\n",
                Language::Lua,
                ".lua",
                "variable_declaration",
                "local Thing = {}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_class(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_class",
                    kind,
                    text
                ),
                "normalize_class mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_impl_matches_ruby_private_method() {
        for (source, kind, text) in [(
            "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}\n",
            "impl_item",
            "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}",
        )] {
            let tree = raw_tree(source, Language::Rust);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Rust);
            let rust = normalizer
                .normalize_impl(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Rust,
                    ".rs",
                    "normalize_impl",
                    kind,
                    text
                ),
                "normalize_impl mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn rust_impl_normalization_matches_ruby() {
        let source = "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}\n";
        let root = parse_language_source(source, Language::Rust, ".rs");
        let class_node = first_node(&root, "CLASS", source.trim_end());

        assert_eq!(child_node(class_node, 0).r#type, "CONST");
        assert_ruby_parity(source, Language::Rust, ".rs");
    }

    #[test]
    fn normalize_body_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value",
            ),
            (
                "def f\n  return value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "return value",
            ),
            (
                "def f\n  items[index]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items[index]",
            ),
            (
                "def f\n  [first, second]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "[first, second]",
            ),
            (
                "def f\n  value if ready?\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "value if ready?",
            ),
            (
                "def f\n  left && right\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "left && right",
            ),
            (
                "def f():\n    return value\n",
                Language::Python,
                ".py",
                "block",
                "return value",
            ),
            (
                "def f():\n    value = other\n",
                Language::Python,
                ".py",
                "block",
                "value = other",
            ),
            (
                "function f() {\n  return value;\n}\n",
                Language::TypeScript,
                ".ts",
                "return_statement",
                "return value;",
            ),
            (
                "function f() {\n  value = other;\n}\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "value = other;",
            ),
            (
                "function f()\n  return value\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "return value",
            ),
            (
                "function f()\n  value = other\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "value = other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_body(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_body",
                    kind,
                    text
                ),
                "normalize_body mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_return_value_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  return nil\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "nil",
            ),
            (
                "def f\n  return items[index]\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "items[index]",
            ),
            (
                "def f\n  return left && right\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "left && right",
            ),
            (
                "def f\n  return condition ? yes : no\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "condition ? yes : no",
            ),
            (
                "def f\n  return foo { value }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo { value }",
            ),
            (
                "def f\n  return user.name\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "user.name",
            ),
            (
                "def f\n  return !value\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "!value",
            ),
            (
                "def f\n  return left + right\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "left + right",
            ),
            (
                "def f\n  return foo(bar)\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo(bar)",
            ),
            (
                "def f():\n    return value + other\n",
                Language::Python,
                ".py",
                "binary_operator",
                "value + other",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_return_value(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_return_value",
                    kind,
                    text
                ),
                "normalize_return_value mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_return_node_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, elide_symbol) in [
            (
                "return :ok if cond\n",
                Language::Ruby,
                ".rb",
                "return",
                "return :ok",
                false,
            ),
            (
                "return :ok if cond\n",
                Language::Ruby,
                ".rb",
                "return",
                "return :ok",
                true,
            ),
            (
                "return value if cond\n",
                Language::Ruby,
                ".rb",
                "return",
                "return value",
                true,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_return_node_with_elide_symbol(node, elide_symbol)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_return_node_value(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    elide_symbol
                ),
                "normalize_return_node mismatch for {language:?} {kind} {text:?} elide_symbol={elide_symbol}"
            );
        }
    }

    #[test]
    fn normalize_return_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "return :ok if cond\n",
                Language::Ruby,
                ".rb",
                "return",
                "return :ok",
            ),
            ("break if done\n", Language::Ruby, ".rb", "break", "break"),
            (
                "next value if done\n",
                Language::Ruby,
                ".rb",
                "next",
                "next value",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_return(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_return",
                    kind,
                    text
                ),
                "normalize_return mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn call_arguments_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, function_mode) in [
            (
                "foo(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(value)",
                "auto",
            ),
            (
                "foo(left + right)\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(left + right)",
                "auto",
            ),
            (
                "foo(user.name)\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(user.name)",
                "auto",
            ),
            (
                "user.name(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.name(value)",
                "none",
            ),
            (
                "foo(value)\n",
                Language::Python,
                ".py",
                "call",
                "foo(value)",
                "auto",
            ),
            (
                "foo(value);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "foo(value)",
                "auto",
            ),
            (
                "foo(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "foo(value)",
                "auto",
            ),
            (
                "user.name(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "user.name(value)",
                "none",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let function = match function_mode {
                "auto" => normalizer
                    .named_field(node, "function")
                    .or_else(|| normalizer.named_field(node, "call"))
                    .or_else(|| normalizer.named_children(node).into_iter().next()),
                "none" => None,
                other => panic!("unknown function mode {other:?}"),
            };
            let rust = Value::Array(
                normalizer
                    .call_arguments(node, function)
                    .iter()
                    .map(node_value)
                    .collect(),
            );

            assert_eq!(
                rust,
                ruby_private_call_arguments_value(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    function_mode
                ),
                "call_arguments mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_call_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("ready?\n", Language::Ruby, ".rb", "call", "ready?"),
            ("foo(value)\n", Language::Ruby, ".rb", "call", "foo(value)"),
            (
                "user.name(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.name(value)",
            ),
            (
                "def f\n  foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { bar }",
            ),
            (
                "foo(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "foo(value)",
            ),
            (
                "foo(value);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "foo(value)",
            ),
            (
                "foo(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "foo(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_call(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_call",
                    kind,
                    text
                ),
                "normalize_call mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_call_with_block_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "items.map { |item| item }\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.map { |item| item }",
            ),
            (
                "items.each do |item|\n  item\nend\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.each do |item|\n  item\nend",
            ),
            (
                "foo(1) { bar }\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(1) { bar }",
            ),
            (
                "def f\n  foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { bar }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_call_with_block(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_call_with_block",
                    kind,
                    text
                ),
                "normalize_call_with_block mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_call_without_block_matches_ruby_private_method() {
        for (source, language, suffix, kind, text, block_mode) in [
            (
                "foo(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(value)",
                "none",
            ),
            (
                "user.name(value)\n",
                Language::Ruby,
                ".rb",
                "call",
                "user.name(value)",
                "none",
            ),
            (
                "foo(1) { bar }\n",
                Language::Ruby,
                ".rb",
                "call",
                "foo(1) { bar }",
                "auto",
            ),
            (
                "items.map(1) { |item| item }\n",
                Language::Ruby,
                ".rb",
                "call",
                "items.map(1) { |item| item }",
                "auto",
            ),
            (
                "Foo { bar }\n",
                Language::Ruby,
                ".rb",
                "call",
                "Foo { bar }",
                "auto",
            ),
            (
                "foo(value)\n",
                Language::Python,
                ".py",
                "expression_statement",
                "foo(value)",
                "none",
            ),
            (
                "foo(value);\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "foo(value)",
                "none",
            ),
            (
                "foo(value)\n",
                Language::Lua,
                ".lua",
                "function_call",
                "foo(value)",
                "none",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let block = match block_mode {
                "auto" => normalizer.call_block(node),
                "none" => None,
                other => panic!("unknown block mode {other:?}"),
            };
            let rust = normalizer
                .normalize_call_without_block(node, block)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_call_without_block_value(
                    source, language, suffix, kind, text, block_mode
                ),
                "normalize_call_without_block mismatch for {language:?} {kind} {text:?} with block mode {block_mode:?}"
            );
        }
    }

    #[test]
    fn command_arguments_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "foo value\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "value",
            ),
            (
                "foo :name\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                ":name",
            ),
            (
                "foo left + right\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "left + right",
            ),
            (
                "foo user.name\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "user.name",
            ),
            (
                "foo(value)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(value)",
            ),
            (
                "foo(left + right)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(left + right)",
            ),
            (
                "foo(value);\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(value)",
            ),
            (
                "foo(value)\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(value)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = Value::Array(
                normalizer
                    .command_arguments(node)
                    .iter()
                    .map(node_value)
                    .collect(),
            );

            assert_eq!(
                rust,
                ruby_private_command_arguments_value(source, language, suffix, kind, text),
                "command_arguments mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn const_for_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("Foo\n", Language::Ruby, ".rb", "constant", "Foo"),
            ("foo\n", Language::Ruby, ".rb", "identifier", "foo"),
            (
                "class Foo:\n    pass\n",
                Language::Python,
                ".py",
                "identifier",
                "Foo",
            ),
            (
                "type Alias = Foo;\n",
                Language::TypeScript,
                ".ts",
                "type_identifier",
                "Foo",
            ),
            (
                "local Foo = {}\n",
                Language::Lua,
                ".lua",
                "variable_list",
                "Foo",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.const_for(Some(node), node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "const_for",
                    kind,
                    text
                ),
                "const_for mismatch for {language:?} {kind} {text:?}"
            );
        }

        for (source, language, suffix) in [
            ("class Foo\nend\n", Language::Ruby, ".rb"),
            ("class Foo:\n    pass\n", Language::Python, ".py"),
            ("class Foo {}\n", Language::TypeScript, ".ts"),
            ("local Foo = {}\n", Language::Lua, ".lua"),
        ] {
            let tree = raw_tree(source, language);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.const_for(None, tree.root_node());

            assert_eq!(
                node_value(&rust),
                ruby_private_const_for_nil_value(source, language, suffix),
                "const_for nil mismatch for {language:?}"
            );
        }
    }

    #[test]
    fn normalize_patterns_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when 1\n  one",
            ),
            (
                "case\nwhen ready\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when ready\n  one",
            ),
            (
                "case value\nwhen Foo::Bar\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when Foo::Bar\n  one",
            ),
            (
                "case value\nwhen Foo\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when Foo\n  one",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "case_clause",
                "case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_case",
                "case 1: one();",
            ),
            ("return 1\n", Language::Lua, ".lua", "expression_list", "1"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = Value::Array(
                normalizer
                    .normalize_patterns(node)
                    .iter()
                    .map(node_value)
                    .collect(),
            );

            assert_eq!(
                rust,
                ruby_private_normalize_patterns_value(source, language, suffix, kind, text),
                "normalize_patterns mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn case_value_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case value\nwhen 1\n  one\nend",
            ),
            (
                "case\nwhen ready\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case\nwhen ready\n  one\nend",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); }",
            ),
            (
                "if value == 1 then one() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.case_value(node).map(|value| {
                (
                    value.kind().to_string(),
                    super::node_text(value, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(source, language, suffix, "case_value", kind, text),
                "case_value mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn case_arms_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend",
            ),
            (
                "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        one()\n    case _:\n        other()",
            ),
            (
                "switch (value) { case 1: one(); default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); default: other(); }",
            ),
            (
                "if value == 1 then one() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .case_arms(node)
                .into_iter()
                .map(|arm| {
                    (
                        arm.kind().to_string(),
                        super::node_text(arm, source).to_string(),
                    )
                })
                .collect::<Vec<_>>();

            assert_eq!(
                rust,
                ruby_private_node_list_signature(source, language, suffix, "case_arms", kind, text),
                "case_arms mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn when_body_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when 1\n  one",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "case_clause",
                "case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_case",
                "case 1: one();",
            ),
            (
                "switch (value) { case 1: one(); default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_default",
                "default: other();",
            ),
            (
                "if value == 1 then one() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.when_body(node).map(|body| {
                (
                    body.kind().to_string(),
                    super::node_text(body, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(source, language, suffix, "when_body", kind, text),
                "when_body mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_when_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when 1\n  one",
            ),
            (
                "case value\nwhen Foo::Bar\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "when",
                "when Foo::Bar\n  one",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "case_clause",
                "case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); break; default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_case",
                "case 1: one(); break;",
            ),
            (
                "if value == 1 then one() else other() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() else other() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_when(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_when",
                    kind,
                    text
                ),
                "normalize_when mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn case_else_body_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nelse\n  other\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case value\nwhen 1\n  one\nelse\n  other\nend",
            ),
            (
                "case value\nwhen 1\n  one\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case value\nwhen 1\n  one\nend",
            ),
            (
                "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        one()\n    case _:\n        other()",
            ),
            (
                "match value:\n    case 1:\n        one()\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        one()",
            ),
            (
                "switch (value) { case 1: one(); break; default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); break; default: other(); }",
            ),
            (
                "switch (value) { case 1: one(); break; }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); break; }",
            ),
            (
                "if value == 1 then one() else other() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() else other() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .case_else_body(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "case_else_body",
                    kind,
                    text
                ),
                "case_else_body mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_case_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend",
            ),
            (
                "case\nwhen ready\n  one\nelse\n  other\nend\n",
                Language::Ruby,
                ".rb",
                "case",
                "case\nwhen ready\n  one\nelse\n  other\nend",
            ),
            (
                "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
                Language::Python,
                ".py",
                "match_statement",
                "match value:\n    case 1:\n        one()\n    case _:\n        other()",
            ),
            (
                "switch (value) { case 1: one(); break; default: other(); }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (value) { case 1: one(); break; default: other(); }",
            ),
            (
                "if value == 1 then one() else other() end\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if value == 1 then one() else other() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_case(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_case",
                    kind,
                    text
                ),
                "normalize_case mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn dotted_call_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
            ("user\n", Language::Ruby, ".rb", "identifier", "user"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user",
            ),
            (
                "user.name();\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            ("user;\n", Language::TypeScript, ".ts", "identifier", "user"),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
            ("user()\n", Language::Lua, ".lua", "function_call", "user()"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.dotted_call(node),
                ruby_private_predicate(source, language, suffix, "dotted_call?", kind, text),
                "dotted_call? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn dotted_expression_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  user.name\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name",
            ),
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            (
                "user.name\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "user.name;",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.dotted_expression(node),
                ruby_private_predicate(source, language, suffix, "dotted_expression?", kind, text),
                "dotted_expression? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn dotted_expression_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f\n  user.name\nend\n", Language::Ruby, ".rb"),
            ("user.name\n", Language::Python, ".py"),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn normalize_else_or_branch_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "if ready\n  call\nelse\n  stop\nend\n",
                Language::Ruby,
                ".rb",
                "else",
                "else\n  stop",
            ),
            (
                "if ready\n  call\nelse\n  user.name\nend\n",
                Language::Ruby,
                ".rb",
                "else",
                "else\n  user.name",
            ),
            (
                "if ready:\n    call()\nelse:\n    stop()\n",
                Language::Python,
                ".py",
                "else_clause",
                "else:\n    stop()",
            ),
            (
                "if ready:\n    call()\nelse:\n    if backup:\n        stop()\n",
                Language::Python,
                ".py",
                "else_clause",
                "else:\n    if backup:\n        stop()",
            ),
            (
                "if (ready) { call(); } else { stop(); }\n",
                Language::TypeScript,
                ".ts",
                "else_clause",
                "else { stop(); }",
            ),
            (
                "if ready then\n  call()\nelse\n  stop()\nend\n",
                Language::Lua,
                ".lua",
                "else_statement",
                "else\n  stop()",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_else_or_branch(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_else_or_branch",
                    kind,
                    text
                ),
                "normalize_else_or_branch mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_if_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "if ready\n  call\nelse\n  stop\nend\n",
                Language::Ruby,
                ".rb",
                "if",
                "if ready\n  call\nelse\n  stop\nend",
            ),
            (
                "call if ready\n",
                Language::Ruby,
                ".rb",
                "if_modifier",
                "call if ready",
            ),
            (
                "unless ready\n  call\nend\n",
                Language::Ruby,
                ".rb",
                "unless",
                "unless ready\n  call\nend",
            ),
            (
                "if ready:\n    call()\nelse:\n    stop()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()\nelse:\n    stop()",
            ),
            (
                "if ready:\n    call()\nelif other:\n    stop()\n",
                Language::Python,
                ".py",
                "if_statement",
                "if ready:\n    call()\nelif other:\n    stop()",
            ),
            (
                "if (ready) { call(); } else { stop(); }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (ready) { call(); } else { stop(); }",
            ),
            (
                "if ready then\n  call()\nelseif other then\n  stop()\nend\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if ready then\n  call()\nelseif other then\n  stop()\nend",
            ),
            (
                "if ready then\n  call()\nelse\n  stop()\nend\n",
                Language::Lua,
                ".lua",
                "if_statement",
                "if ready then\n  call()\nelse\n  stop()\nend",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_if(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_if",
                    kind,
                    text
                ),
                "normalize_if mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_elsif_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "if ready\n  call\nelsif other\n  stop\nend\n",
                "elsif",
                "elsif other\n  stop",
            ),
            (
                "if ready\n  call\nelsif other\n  stop\nelse\n  done\nend\n",
                "elsif",
                "elsif other\n  stop\nelse\n  done",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = node_value(&normalizer.normalize_elsif(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_elsif",
                    kind,
                    text
                ),
                "normalize_elsif mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_loop_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "while ready\n  work\nend\n",
                Language::Ruby,
                ".rb",
                "while",
                "while ready\n  work\nend",
            ),
            (
                "work while ready\n",
                Language::Ruby,
                ".rb",
                "while_modifier",
                "work while ready",
            ),
            (
                "work until ready\n",
                Language::Ruby,
                ".rb",
                "until_modifier",
                "work until ready",
            ),
            (
                "for item in items\n  work\nend\n",
                Language::Ruby,
                ".rb",
                "for",
                "for item in items\n  work\nend",
            ),
            (
                "while ready:\n    work()\n",
                Language::Python,
                ".py",
                "while_statement",
                "while ready:\n    work()",
            ),
            (
                "for item in items:\n    work()\n",
                Language::Python,
                ".py",
                "for_statement",
                "for item in items:\n    work()",
            ),
            (
                "while ready do\n  work()\nend\n",
                Language::Lua,
                ".lua",
                "while_statement",
                "while ready do\n  work()\nend",
            ),
            (
                "while (ready) { work(); }\n",
                Language::TypeScript,
                ".ts",
                "while_statement",
                "while (ready) { work(); }",
            ),
            (
                "for (let i = 0; i < n; i++) { work(i); }\n",
                Language::TypeScript,
                ".ts",
                "for_statement",
                "for (let i = 0; i < n; i++) { work(i); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let node_type = super::loop_kind(node.kind()).expect("test node should be a loop kind");
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_loop(node, node_type)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_loop",
                    kind,
                    text
                ),
                "normalize_loop mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_elsif_normalization_matches_ruby() {
        for source in [
            "if ready\n  call\nelsif other\n  stop\nend\n",
            "if ready\n  call\nelsif other\n  stop\nelse\n  done\nend\n",
        ] {
            let root = parse_language_source(source, Language::Ruby, ".rb");
            let if_node = first_node(&root, "IF", source.trim_end());

            assert_eq!(
                child_node(if_node, 2).r#type,
                "IF",
                "expected Ruby elsif alternative to normalize as nested IF: {if_node:#?}"
            );
            assert_ruby_parity(source, Language::Ruby, ".rb");
        }
    }

    #[test]
    fn normalize_dotted_expression_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  user.name\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name",
            ),
            (
                "def f\n  user.name { value }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name { value }",
            ),
            (
                "user.name\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.name",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "user.name;",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_dotted_expression(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_dotted_expression",
                    kind,
                    text
                ),
                "normalize_dotted_expression mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_dotted_call_expression_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  user.name\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name",
            ),
            (
                "def f\n  user.name(1)\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name(1)",
            ),
            (
                "def f\n  user&.name\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user&.name",
            ),
            (
                "def f\n  user.name { value }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "user.name { value }",
            ),
            (
                "user.name\n",
                Language::Python,
                ".py",
                "expression_statement",
                "user.name",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_dotted_call_expression(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_dotted_call_expression",
                    kind,
                    text
                ),
                "normalize_dotted_call_expression mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn argument_list_call_with_block_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  return foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo { bar }",
            ),
            (
                "def f\n  return foo do\n    bar\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo do\n    bar\n  end",
            ),
            (
                "def f\n  return foo(1) { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo(1) { bar }",
            ),
            (
                "def f\n  foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { bar }",
            ),
            (
                "def f\n  return foo.bar { baz }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo.bar { baz }",
            ),
            (
                "def f\n  return Foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "Foo { bar }",
            ),
            (
                "def f():\n    return foo(lambda: bar)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(lambda: bar)",
            ),
            (
                "function f(){ return foo(() => bar); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(() => bar)",
            ),
            (
                "function f() return foo(function() return bar end) end\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(function() return bar end)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.argument_list_call_with_block(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "argument_list_call_with_block?",
                    kind,
                    text
                ),
                "argument_list_call_with_block? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_argument_list_call_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  return foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo { bar }",
            ),
            (
                "def f\n  return foo do\n    bar\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo do\n    bar\n  end",
            ),
            (
                "def f\n  return foo(1) { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo(1) { bar }",
            ),
            (
                "def f\n  foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { bar }",
            ),
            (
                "def f():\n    return foo(lambda: bar)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(lambda: bar)",
            ),
            (
                "function f(){ return foo(() => bar); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(() => bar)",
            ),
            (
                "function f() return foo(function() return bar end) end\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(function() return bar end)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_argument_list_call(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_argument_list_call",
                    kind,
                    text
                ),
                "normalize_argument_list_call mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_argument_list_call_with_block_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  return foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo { bar }",
            ),
            (
                "def f\n  return foo do\n    bar\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo do\n    bar\n  end",
            ),
            (
                "def f\n  return foo(1) { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "foo(1) { bar }",
            ),
            (
                "def f\n  foo { bar }\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo { bar }",
            ),
            (
                "def f():\n    return foo(lambda: bar)\n",
                Language::Python,
                ".py",
                "argument_list",
                "(lambda: bar)",
            ),
            (
                "function f(){ return foo(() => bar); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "(() => bar)",
            ),
            (
                "function f() return foo(function() return bar end) end\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(function() return bar end)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_argument_list_call_with_block(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_argument_list_call_with_block",
                    kind,
                    text
                ),
                "normalize_argument_list_call_with_block mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn safe_navigation_call_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user?.name;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user?.name",
            ),
            (
                "user?.name();\n",
                Language::TypeScript,
                ".ts",
                "call_expression",
                "user?.name()",
            ),
            (
                "user.name;\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.safe_navigation_call(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "safe_navigation_call?",
                    kind,
                    text
                ),
                "safe_navigation_call? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn rescue_source_end_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "begin\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "rescue",
                "rescue Error => e\n  handle",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle()\n",
                Language::Python,
                ".py",
                "except_clause",
                "except Error as e:\n    handle()",
            ),
            (
                "try { work(); } catch (e) { handle(); }\n",
                Language::TypeScript,
                ".ts",
                "catch_clause",
                "catch (e) { handle(); }",
            ),
            ("work()\n", Language::Lua, ".lua", "function_call", "work()"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.rescue_source_end(node).map(|source_end| {
                (
                    source_end.kind().to_string(),
                    super::node_text(source_end, source).to_string(),
                )
            });

            assert_eq!(
                rust,
                ruby_private_node_signature(
                    source,
                    language,
                    suffix,
                    "rescue_source_end",
                    kind,
                    text
                ),
                "rescue_source_end mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn rescue_exception_variable_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "begin\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "rescue",
                "rescue Error => e\n  handle",
            ),
            (
                "begin\n  work\nrescue Error\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "rescue",
                "rescue Error\n  handle",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle()\n",
                Language::Python,
                ".py",
                "except_clause",
                "except Error as e:\n    handle()",
            ),
            (
                "try:\n    work()\nexcept Error:\n    handle()\n",
                Language::Python,
                ".py",
                "except_clause",
                "except Error:\n    handle()",
            ),
            (
                "try { work(); } catch (e) { handle(); }\n",
                Language::TypeScript,
                ".ts",
                "catch_clause",
                "catch (e) { handle(); }",
            ),
            ("work()\n", Language::Lua, ".lua", "function_call", "work()"),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .rescue_exception_variable(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "rescue_exception_variable",
                    kind,
                    text
                ),
                "rescue_exception_variable mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_rescue_clause_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "begin\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "rescue",
                "rescue Error => e\n  handle",
            ),
            (
                "begin\n  work\nrescue Net::Error\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "rescue",
                "rescue Net::Error\n  handle",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
                Language::Python,
                ".py",
                "except_clause",
                "except Error as e:\n    handle(e)",
            ),
            (
                "try { work(); } catch (e) { handle(e); }\n",
                Language::TypeScript,
                ".ts",
                "catch_clause",
                "catch (e) { handle(e); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_rescue_clause(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_rescue_clause",
                    kind,
                    text
                ),
                "normalize_rescue_clause mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_rescue_modifier_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [(
            "value rescue fallback\n",
            Language::Ruby,
            ".rb",
            "rescue_modifier",
            "value rescue fallback",
        )] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_rescue_modifier(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_rescue_modifier",
                    kind,
                    text
                ),
                "normalize_rescue_modifier mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn prepend_rescue_exception_assignment_matches_ruby_private_method() {
        fn synthetic_node(
            node_type: &str,
            text: &str,
            first_lineno: usize,
            first_column: usize,
            last_lineno: usize,
            last_column: usize,
            children: Vec<Child>,
        ) -> Node {
            Node {
                r#type: node_type.to_string(),
                children,
                first_lineno,
                first_column,
                last_lineno,
                last_column,
                text: text.to_string(),
            }
        }

        let source = "assign\nbody\n";
        let assignment = synthetic_node("LASGN", "assign", 1, 0, 1, 6, Vec::new());
        let body = synthetic_node("VCALL", "body", 2, 0, 2, 4, Vec::new());
        let block = synthetic_node(
            "BLOCK",
            "body",
            2,
            0,
            2,
            4,
            vec![Child::Node(Box::new(body.clone())), Child::Nil],
        );

        for (label, body_node, assignment_node) in [
            ("no_assignment", Some(body.clone()), None),
            ("no_body", None, Some(assignment.clone())),
            ("block_body", Some(block), Some(assignment.clone())),
            ("scalar_body", Some(body), Some(assignment)),
        ] {
            let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .prepend_rescue_exception_assignment(body_node.clone(), assignment_node.clone())
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);
            let body_value = body_node.as_ref().map(node_value).unwrap_or(Value::Null);
            let assignment_value = assignment_node
                .as_ref()
                .map(node_value)
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_prepend_rescue_exception_assignment_value(
                    source,
                    &body_value,
                    &assignment_value
                ),
                "prepend_rescue_exception_assignment mismatch for {label}"
            );
        }
    }

    #[test]
    fn dotted_call_parts_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
            ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
            (
                "user.name()\n",
                Language::Python,
                ".py",
                "attribute",
                "user.name",
            ),
            (
                "user.name();\n",
                Language::TypeScript,
                ".ts",
                "member_expression",
                "user.name",
            ),
            (
                "user.name()\n",
                Language::Lua,
                ".lua",
                "dot_index_expression",
                "user.name",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .dotted_call_parts(node, None)
                .map(|(receiver, method)| {
                    (
                        receiver.kind().to_string(),
                        super::node_text(receiver, source).to_string(),
                        method,
                    )
                });

            assert_eq!(
                rust,
                ruby_private_dotted_call_parts(source, language, suffix, kind, text),
                "dotted_call_parts mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn dotted_call_parts_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("user.name\n", Language::Ruby, ".rb"),
            ("user&.name\n", Language::Ruby, ".rb"),
            ("user.name()\n", Language::Python, ".py"),
            ("user.name();\n", Language::TypeScript, ".ts"),
            ("user.name()\n", Language::Lua, ".lua"),
        ] {
            let root = parse_language_source(source, language, suffix);
            if language != Language::Lua {
                let mut calls = Vec::new();
                nodes_of_type(&root, "CALL", &mut calls);
                let mut qcalls = Vec::new();
                nodes_of_type(&root, "QCALL", &mut qcalls);
                assert!(
                    calls
                        .iter()
                        .chain(qcalls.iter())
                        .any(|node| matches!(node.children.get(1), Some(Child::Symbol(method)) if method == "name")),
                    "expected dotted call method name for {language:?} in {root:#?}"
                );
            }
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn leading_if_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  if x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "if x\n    y\n  end",
            ),
            (
                "def f():\n    if x:\n        y()\n",
                Language::Python,
                ".py",
                "block",
                "if x:\n        y()",
            ),
            (
                "function f()\n  if x then\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if x then\n    y()\n  end",
            ),
            (
                "function f() { if (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (x) { y(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.leading_if_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "leading_if_statement?",
                    kind,
                    text
                ),
                "leading_if_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_leading_if_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  if x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "if x\n    y\n  end",
            ),
            (
                "def f():\n    if x:\n        y()\n",
                Language::Python,
                ".py",
                "block",
                "if x:\n        y()",
            ),
            (
                "function f()\n  if x then\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if x then\n    y()\n  end",
            ),
            (
                "function f() { if (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
                "if_statement",
                "if (x) { y(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_leading_if_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_leading_if_statement",
                    kind,
                    text
                ),
                "normalize_leading_if_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn leading_if_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f\n  if x\n    y\n  end\nend\n", Language::Ruby, ".rb"),
            (
                "def f():\n    if x:\n        y()\n",
                Language::Python,
                ".py",
            ),
            (
                "function f()\n  if x then\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
            ),
            (
                "function f() { if (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut if_nodes = Vec::new();
            nodes_of_type(&root, "IF", &mut if_nodes);
            assert!(
                !if_nodes.is_empty(),
                "expected IF node for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn leading_case_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "case x\n  when 1 then y\n  else z\n  end",
            ),
            (
                "def f(x):\n    match x:\n        case 1:\n            y()\n",
                Language::Python,
                ".py",
                "block",
                "match x:\n        case 1:\n            y()",
            ),
            (
                "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (x) { case 1: y(); break; default: z(); }",
            ),
            (
                "function f(x)\n  if x == 1 then y() end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "if x == 1 then y() end",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.leading_case_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "leading_case_statement?",
                    kind,
                    text
                ),
                "leading_case_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_leading_case_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "case x\n  when 1 then y\n  else z\n  end",
            ),
            (
                "def f(x):\n    match x:\n        case 1:\n            y()\n",
                Language::Python,
                ".py",
                "block",
                "match x:\n        case 1:\n            y()",
            ),
            (
                "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
                Language::TypeScript,
                ".ts",
                "switch_statement",
                "switch (x) { case 1: y(); break; default: z(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_leading_case_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_leading_case_statement",
                    kind,
                    text
                ),
                "normalize_leading_case_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn leading_case_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            (
                "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "def f(x):\n    match x:\n        case 1:\n            y()\n",
                Language::Python,
                ".py",
            ),
            (
                "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
                Language::TypeScript,
                ".ts",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut case_nodes = Vec::new();
            nodes_of_type(&root, "CASE", &mut case_nodes);
            assert!(
                !case_nodes.is_empty(),
                "expected CASE node for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn leading_loop_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(x)\n  while x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "while x\n    y\n  end",
            ),
            (
                "def f(x):\n    while x:\n        y()\n",
                Language::Python,
                ".py",
                "block",
                "while x:\n        y()",
            ),
            (
                "function f(x)\n  while x do\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "while x do\n    y()\n  end",
            ),
            (
                "function f(x) { while (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
                "while_statement",
                "while (x) { y(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.leading_loop_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "leading_loop_statement?",
                    kind,
                    text
                ),
                "leading_loop_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_leading_loop_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f(x)\n  while x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "while x\n    y\n  end",
            ),
            (
                "def f(x)\n  until x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "until x\n    y\n  end",
            ),
            (
                "def f(x):\n    while x:\n        y()\n",
                Language::Python,
                ".py",
                "block",
                "while x:\n        y()",
            ),
            (
                "function f(x)\n  while x do\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "while x do\n    y()\n  end",
            ),
            (
                "function f(x) { while (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
                "while_statement",
                "while (x) { y(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_leading_loop_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_leading_loop_statement",
                    kind,
                    text
                ),
                "normalize_leading_loop_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn leading_loop_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            (
                "def f(x)\n  while x\n    y\n  end\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "def f(x):\n    while x:\n        y()\n",
                Language::Python,
                ".py",
            ),
            (
                "function f(x)\n  while x do\n    y()\n  end\nend\n",
                Language::Lua,
                ".lua",
            ),
            (
                "function f(x) { while (x) { y(); } }\n",
                Language::TypeScript,
                ".ts",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut while_nodes = Vec::new();
            nodes_of_type(&root, "WHILE", &mut while_nodes);
            assert!(
                !while_nodes.is_empty(),
                "expected WHILE node for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn rescue_body_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "work\nrescue Error => e\n  handle",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
                Language::Python,
                ".py",
                "try_statement",
                "try:\n    work()\nexcept Error as e:\n    handle(e)",
            ),
            (
                "try { work(); } catch (e) { handle(e); }\n",
                Language::TypeScript,
                ".ts",
                "try_statement",
                "try { work(); } catch (e) { handle(e); }",
            ),
            (
                "local ok, err = pcall(work)\n",
                Language::Lua,
                ".lua",
                "variable_declaration",
                "local ok, err = pcall(work)",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.rescue_body_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "rescue_body_statement?",
                    kind,
                    text
                ),
                "rescue_body_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_rescue_body_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "work\nrescue Error => e\n  handle",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
                Language::Python,
                ".py",
                "try_statement",
                "try:\n    work()\nexcept Error as e:\n    handle(e)",
            ),
            (
                "try { work(); } catch (e) { handle(e); }\n",
                Language::TypeScript,
                ".ts",
                "try_statement",
                "try { work(); } catch (e) { handle(e); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_rescue_body_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_rescue_body_statement",
                    kind,
                    text
                ),
                "normalize_rescue_body_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn rescue_body_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            (
                "def f\n  work\nrescue Error => e\n  handle\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
                Language::Python,
                ".py",
            ),
            (
                "try { work(); } catch (e) { handle(e); }\n",
                Language::TypeScript,
                ".ts",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut rescue_nodes = Vec::new();
            nodes_of_type(&root, "RESCUE", &mut rescue_nodes);
            assert!(
                !rescue_nodes.is_empty(),
                "expected RESCUE node for {language:?} in {root:#?}"
            );
            let mut resbody_nodes = Vec::new();
            nodes_of_type(&root, "RESBODY", &mut resbody_nodes);
            assert!(
                !resbody_nodes.is_empty(),
                "expected RESBODY node for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn ensure_body_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  work\nensure\n  cleanup\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "work\nensure\n  cleanup",
            ),
            (
                "try:\n    work()\nfinally:\n    cleanup()\n",
                Language::Python,
                ".py",
                "try_statement",
                "try:\n    work()\nfinally:\n    cleanup()",
            ),
            (
                "try { work(); } finally { cleanup(); }\n",
                Language::TypeScript,
                ".ts",
                "try_statement",
                "try { work(); } finally { cleanup(); }",
            ),
            (
                "work()\ncleanup()\n",
                Language::Lua,
                ".lua",
                "function_call",
                "work()",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ensure_body_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "ensure_body_statement?",
                    kind,
                    text
                ),
                "ensure_body_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ensure_body_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            (
                "def f\n  work\nensure\n  cleanup\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "try:\n    work()\nfinally:\n    cleanup()\n",
                Language::Python,
                ".py",
            ),
            (
                "try { work(); } finally { cleanup(); }\n",
                Language::TypeScript,
                ".ts",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()\n",
                Language::Python,
                ".py",
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut ensure_nodes = Vec::new();
            nodes_of_type(&root, "ENSURE", &mut ensure_nodes);
            assert!(
                !ensure_nodes.is_empty(),
                "expected ENSURE node for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn normalize_ensure_body_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  work\nensure\n  cleanup\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "work\nensure\n  cleanup",
            ),
            (
                "try:\n    work()\nfinally:\n    cleanup()\n",
                Language::Python,
                ".py",
                "try_statement",
                "try:\n    work()\nfinally:\n    cleanup()",
            ),
            (
                "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()\n",
                Language::Python,
                ".py",
                "try_statement",
                "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()",
            ),
            (
                "try { work(); } finally { cleanup(); }\n",
                Language::TypeScript,
                ".ts",
                "try_statement",
                "try { work(); } finally { cleanup(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_ensure_body_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_ensure_body_statement",
                    kind,
                    text
                ),
                "normalize_ensure_body_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_ensure_clause_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "begin\n  work\nensure\n  cleanup\nend\n",
                "ensure",
                "ensure\n  cleanup",
            ),
            (
                "begin\n  work\nensure\n  user.name\nend\n",
                "ensure",
                "ensure\n  user.name",
            ),
            (
                "begin\n  work\nensure\n  user.name\n  cleanup\nend\n",
                "ensure",
                "ensure\n  user.name\n  cleanup",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_ensure_clause(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_ensure_clause",
                    kind,
                    text
                ),
                "normalize_ensure_clause mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn ruby_begin_ensure_clause_keeps_all_body_statements() {
        let source = "begin\n  work\nensure\n  user.name\n  cleanup\nend\n";
        let root = parse_language_source(source, Language::Ruby, ".rb");
        let ensure = first_node(&root, "ENSURE", "work\nensure\n  user.name\n  cleanup");
        let ensure_body = child_node(ensure, 1);

        assert_eq!(
            child_types(ensure_body),
            vec!["CALL", "VCALL"],
            "Ruby ensure clause body must retain all statements: {ensure:#?}"
        );
        assert_ruby_parity(source, Language::Ruby, ".rb");
    }

    #[test]
    fn array_literal_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  [a, b]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "[a, b]",
            ),
            (
                "def f():\n    [a, b]\n",
                Language::Python,
                ".py",
                "block",
                "[a, b]",
            ),
            (
                "function f() { [a, b]; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "[a, b];",
            ),
            (
                "function f()\n  {a, b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {a, b}",
            ),
            (
                "function f()\n  {x = a, y = b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {x = a, y = b}",
            ),
            (
                "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
                Language::Lua,
                ".lua",
                "arguments",
                "({rocks_tree, \"a_rock\"})",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.array_literal_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "array_literal_statement?",
                    kind,
                    text
                ),
                "array_literal_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn array_literal_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f\n  [a, b]\nend\n", Language::Ruby, ".rb"),
            ("def f():\n    [a, b]\n", Language::Python, ".py"),
            ("function f() { [a, b]; }\n", Language::TypeScript, ".ts"),
            ("function f()\n  {a, b}\nend\n", Language::Lua, ".lua"),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut lists = Vec::new();
            nodes_of_type(&root, "LIST", &mut lists);
            assert!(
                lists
                    .iter()
                    .any(|node| node.text.contains('a') && node.text.contains('b')),
                "expected LIST for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn normalize_array_literal_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  [a, b]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "[a, b]",
            ),
            (
                "def f\n  []\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "[]",
            ),
            (
                "def f():\n    [a, b]\n",
                Language::Python,
                ".py",
                "block",
                "[a, b]",
            ),
            ("def f():\n    []\n", Language::Python, ".py", "block", "[]"),
            (
                "function f() { [a, b]; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "[a, b];",
            ),
            (
                "function f() { []; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "[];",
            ),
            (
                "function f()\n  {a, b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {a, b}",
            ),
            (
                "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
                Language::Lua,
                ".lua",
                "arguments",
                "(install, { bin = { P\"bin/binfile\" } })",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_array_literal_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_array_literal_statement",
                    kind,
                    text
                ),
                "normalize_array_literal_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn element_reference_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  items[0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items[0]",
            ),
            (
                "def f\n  [0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "[0]",
            ),
            (
                "def f():\n    items[0]\n",
                Language::Python,
                ".py",
                "block",
                "items[0]",
            ),
            (
                "return items[0]\n",
                Language::Python,
                ".py",
                "subscript",
                "items[0]",
            ),
            (
                "function f() { items[0]; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "items[0];",
            ),
            (
                "return items[0];\n",
                Language::TypeScript,
                ".ts",
                "subscript_expression",
                "items[0]",
            ),
            (
                "return items[1]\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "items[1]",
            ),
            (
                "print(items[1])\n",
                Language::Lua,
                ".lua",
                "bracket_index_expression",
                "items[1]",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.element_reference_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "element_reference_statement?",
                    kind,
                    text
                ),
                "element_reference_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_element_reference_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  items[0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items[0]",
            ),
            (
                "def f\n  self[0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "self[0]",
            ),
            (
                "return items[0]\n",
                Language::Python,
                ".py",
                "subscript",
                "items[0]",
            ),
            (
                "return items[0];\n",
                Language::TypeScript,
                ".ts",
                "subscript_expression",
                "items[0]",
            ),
            (
                "print(items[1])\n",
                Language::Lua,
                ".lua",
                "bracket_index_expression",
                "items[1]",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_element_reference(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_element_reference",
                    kind,
                    text
                ),
                "normalize_element_reference mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_element_reference_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  items[0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items[0]",
            ),
            (
                "def f\n  self[0]\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "self[0]",
            ),
            (
                "def f():\n    items[0]\n",
                Language::Python,
                ".py",
                "block",
                "items[0]",
            ),
            (
                "return items[0]\n",
                Language::Python,
                ".py",
                "subscript",
                "items[0]",
            ),
            (
                "function f() { items[0]; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "items[0];",
            ),
            (
                "return items[0];\n",
                Language::TypeScript,
                ".ts",
                "subscript_expression",
                "items[0]",
            ),
            (
                "return items[1]\n",
                Language::Lua,
                ".lua",
                "expression_list",
                "items[1]",
            ),
            (
                "print(items[1])\n",
                Language::Lua,
                ".lua",
                "bracket_index_expression",
                "items[1]",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_element_reference_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_element_reference_statement",
                    kind,
                    text
                ),
                "normalize_element_reference_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn element_reference_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f\n  items[0]\nend\n", Language::Ruby, ".rb"),
            ("def f():\n    items[0]\n", Language::Python, ".py"),
            ("function f() { items[0]; }\n", Language::TypeScript, ".ts"),
            ("return items[1]\n", Language::Lua, ".lua"),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut calls = Vec::new();
            nodes_of_type(&root, "CALL", &mut calls);
            assert!(
                calls.iter().any(|node| {
                    matches!(node.children.get(1), Some(Child::Symbol(message)) if message == "[]")
                        && node.text.contains("items")
                }),
                "expected element reference CALL for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn hash_literal_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  {a: b}\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "{a: b}",
            ),
            (
                "def f():\n    {\"a\": b}\n",
                Language::Python,
                ".py",
                "block",
                "{\"a\": b}",
            ),
            (
                "function f() { ({a: b}); }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "({a: b});",
            ),
            (
                "return {a: b};\n",
                Language::TypeScript,
                ".ts",
                "object",
                "{a: b}",
            ),
            (
                "function f()\n  {a = b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {a = b}",
            ),
            (
                "function f()\n  {a, b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {a, b}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.hash_literal_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "hash_literal_statement?",
                    kind,
                    text
                ),
                "hash_literal_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_hash_literal_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  {a: b}\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "{a: b}",
            ),
            (
                "def f():\n    {\"a\": b}\n",
                Language::Python,
                ".py",
                "block",
                "{\"a\": b}",
            ),
            (
                "function f() { ({a: b}); }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "({a: b});",
            ),
            (
                "return {a: b};\n",
                Language::TypeScript,
                ".ts",
                "object",
                "{a: b}",
            ),
            (
                "function f()\n  {a = b}\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  {a = b}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_hash_literal_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_hash_literal_statement",
                    kind,
                    text
                ),
                "normalize_hash_literal_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_pair_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  {a: b}\nend\n",
                Language::Ruby,
                ".rb",
                "pair",
                "a: b",
            ),
            (
                "def f\n  {name:}\nend\n",
                Language::Ruby,
                ".rb",
                "pair",
                "name:",
            ),
            (
                "def f\n  {\"a\" => b}\nend\n",
                Language::Ruby,
                ".rb",
                "pair",
                "\"a\" => b",
            ),
            (
                "def f():\n    {\"a\": b}\n",
                Language::Python,
                ".py",
                "pair",
                "\"a\": b",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_pair(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_pair",
                    kind,
                    text
                ),
                "normalize_pair mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn hash_literal_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f\n  {a: b}\nend\n", Language::Ruby, ".rb"),
            ("def f():\n    {\"a\": b}\n", Language::Python, ".py"),
            ("function f() { ({a: b}); }\n", Language::TypeScript, ".ts"),
            ("function f()\n  {a = b}\nend\n", Language::Lua, ".lua"),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut hashes = Vec::new();
            nodes_of_type(&root, "HASH", &mut hashes);
            assert!(
                hashes
                    .iter()
                    .any(|node| node.text.contains('a') && node.text.contains('b')),
                "expected hash literal HASH for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn empty_body_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f():\n    pass\n",
                Language::Python,
                ".py",
                "block",
                "pass",
            ),
            (
                "function f() {}\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{}",
            ),
            (
                "function f() { work(); }\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{ work(); }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.empty_body_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "empty_body_statement?",
                    kind,
                    text
                ),
                "empty_body_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn empty_body_statement_normalization_matches_ruby() {
        for (source, language, suffix) in [
            ("def f():\n    pass\n", Language::Python, ".py"),
            ("function f() {}\n", Language::TypeScript, ".ts"),
        ] {
            let root = parse_language_source(source, language, suffix);
            let mut defns = Vec::new();
            nodes_of_type(&root, "DEFN", &mut defns);
            let scope = child_node(defns[0], 1);
            assert!(
                matches!(scope.children.get(2), Some(Child::Nil)),
                "expected empty body for {language:?} in {root:#?}"
            );
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn heredoc_body_statement_matches_ruby_private_predicate() {
        let ruby_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
        for (source, language, suffix, kind, text) in [
            (
                ruby_source,
                Language::Ruby,
                ".rb",
                "body_statement",
                "puts <<~TXT\n    hi\n  TXT",
            ),
            (ruby_source, Language::Ruby, ".rb", "call", "puts <<~TXT"),
            (
                "def f():\n    value = 1\n",
                Language::Python,
                ".py",
                "block",
                "value = 1",
            ),
            (
                "function f() { value = 1; }\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{ value = 1; }",
            ),
            (
                "function f()\n  value = 1\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "value = 1",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.heredoc_body_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "heredoc_body_statement?",
                    kind,
                    text
                ),
                "heredoc_body_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn heredoc_call_for_body_matches_ruby_private_predicate() {
        let ruby_arg_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
        let ruby_receiver_source = "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n";
        for (source, language, suffix, kind, text) in [
            (
                ruby_arg_source,
                Language::Ruby,
                ".rb",
                "body_statement",
                "puts <<~TXT\n    hi\n  TXT",
            ),
            (
                ruby_arg_source,
                Language::Ruby,
                ".rb",
                "call",
                "puts <<~TXT",
            ),
            (
                ruby_arg_source,
                Language::Ruby,
                ".rb",
                "argument_list",
                "<<~TXT",
            ),
            (
                ruby_arg_source,
                Language::Ruby,
                ".rb",
                "method",
                "def f\n  puts <<~TXT\n    hi\n  TXT\nend",
            ),
            (
                ruby_receiver_source,
                Language::Ruby,
                ".rb",
                "call",
                "<<~ZIG.chomp",
            ),
            (
                ruby_receiver_source,
                Language::Ruby,
                ".rb",
                "heredoc_beginning",
                "<<~ZIG",
            ),
            (
                "def f():\n    value = 1\n",
                Language::Python,
                ".py",
                "block",
                "value = 1",
            ),
            (
                "function f() { value = 1; }\n",
                Language::TypeScript,
                ".ts",
                "statement_block",
                "{ value = 1; }",
            ),
            (
                "function f()\n  value = 1\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "value = 1",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.heredoc_call_for_body(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "heredoc_call_for_body?",
                    kind,
                    text
                ),
                "heredoc_call_for_body? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn with_current_heredoc_body_restores_previous_body() {
        let source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let body = first_raw_node(tree.root_node(), source, "heredoc_body", "\n    hi\n  TXT");
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        normalizer.current_heredoc_body_span = Some([9, 2, 9, 7]);

        let result = normalizer.with_current_heredoc_body(Some(body), |normalizer| {
            assert_eq!(
                normalizer.current_heredoc_body_span,
                Some(super::span(body))
            );
            "result"
        });

        assert_eq!(result, "result");
        assert_eq!(normalizer.current_heredoc_body_span, Some([9, 2, 9, 7]));
    }

    #[test]
    fn normalize_interpolation_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "name = \"#{user}\"\n",
                Language::Ruby,
                ".rb",
                "interpolation",
                "#{user}",
            ),
            (
                "name = \"#{a; b}\"\n",
                Language::Ruby,
                ".rb",
                "interpolation",
                "#{a; b}",
            ),
            (
                "name = f\"hi {user}\"\n",
                Language::Python,
                ".py",
                "interpolation",
                "{user}",
            ),
            (
                "const name = `hi ${user}`;\n",
                Language::TypeScript,
                ".ts",
                "template_substitution",
                "${user}",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_interpolation(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_interpolation",
                    kind,
                    text
                ),
                "normalize_interpolation mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_heredoc_children_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n",
                "heredoc_body",
                "\n    hi\n  TXT",
            ),
            (
                "def f\n  puts <<~TXT\n    hi #{name}\n  TXT\nend\n",
                "heredoc_body",
                "\n    hi #{name}\n  TXT",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = children_value(&normalizer.normalize_heredoc_children(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_heredoc_children",
                    kind,
                    text
                ),
                "normalize_heredoc_children mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_heredoc_beginning_matches_ruby_private_method() {
        for (source, kind, text) in [(
            "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n",
            "heredoc_beginning",
            "<<~ZIG",
        )] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = node_value(&normalizer.normalize_heredoc_beginning(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_heredoc_beginning",
                    kind,
                    text
                ),
                "normalize_heredoc_beginning mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_heredoc_beginning_uses_current_body_for_multiple_heredocs() {
        let source = "def f\n  puts <<~A, <<~B\n    one\n  A\n    two\n  B\nend\n";
        let tree = raw_tree(source, Language::Ruby);
        let beginning = first_raw_node(tree.root_node(), source, "heredoc_beginning", "<<~B");
        let body = first_raw_node(tree.root_node(), source, "heredoc_body", "\n    two\n  B");
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

        let dstr = normalizer.with_current_heredoc_body(Some(body), |normalizer| {
            normalizer.normalize_heredoc_beginning(beginning)
        });

        let content = child_node(&dstr, 0);
        assert_eq!(content.r#type, "STR");
        assert_eq!(
            content.children,
            vec![Child::String("\n    two\n  ".to_string())]
        );
    }

    #[test]
    fn normalize_heredoc_body_statement_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n",
                "body_statement",
                "puts <<~TXT\n    hi\n  TXT",
            ),
            (
                "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n",
                "body_statement",
                "<<~ZIG.chomp\n    hi\n  ZIG",
            ),
            (
                "def f\n  puts <<~A, <<~B\n    one\n  A\n    two\n  B\nend\n",
                "body_statement",
                "puts <<~A, <<~B\n    one\n  A\n    two\n  B",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = normalizer
                .normalize_heredoc_body_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_heredoc_body_statement",
                    kind,
                    text
                ),
                "normalize_heredoc_body_statement mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn interpolated_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  \"hi #{name}\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"hi #{name}\"",
            ),
            (
                "def f():\n    f\"hi {name}\"\n",
                Language::Python,
                ".py",
                "block",
                "f\"hi {name}\"",
            ),
            (
                "function f() { `hi ${name}`; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "`hi ${name}`;",
            ),
            (
                "function f()\n  \"hi\"\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  \"hi\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.interpolated_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "interpolated_statement?",
                    kind,
                    text
                ),
                "interpolated_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn interpolated_statement_normalization_matches_ruby() {
        let source = "def f\n  \"hi #{name}\"\nend\n";
        let root = parse_language_source(source, Language::Ruby, ".rb");
        let dstr = first_node(&root, "DSTR", "\"hi #{name}\"");

        assert_eq!(child_types(dstr), vec!["STR", "EVSTR"]);
        assert_ruby_parity(source, Language::Ruby, ".rb");
    }

    #[test]
    fn normalize_interpolated_statement_matches_ruby_private_method() {
        for (source, kind, text) in [
            (
                "def f\n  \"hi #{name}\"\nend\n",
                "body_statement",
                "\"hi #{name}\"",
            ),
            (
                "def f\n  \"#{first} #{last}\"\nend\n",
                "body_statement",
                "\"#{first} #{last}\"",
            ),
        ] {
            let tree = raw_tree(source, Language::Ruby);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
            let rust = node_value(&normalizer.normalize_interpolated_statement(node));

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    Language::Ruby,
                    ".rb",
                    "normalize_interpolated_statement",
                    kind,
                    text
                ),
                "normalize_interpolated_statement mismatch for {kind} {text:?}"
            );
        }
    }

    #[test]
    fn concatenated_string_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  \"a\" \"b\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b\"",
            ),
            (
                "def f():\n    \"a\" \"b\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" \"b\"",
            ),
            (
                "function f() { \"a\"; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "\"a\";",
            ),
            (
                "function f()\n  \"a\"\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  \"a\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.concatenated_string_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "concatenated_string_statement?",
                    kind,
                    text
                ),
                "concatenated_string_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn concatenated_string_statement_normalization_matches_ruby() {
        for (source, language, suffix, expected_text, expected_types) in [
            (
                "def f\n  \"a\" \"b\"\nend\n",
                Language::Ruby,
                ".rb",
                "\"a\"",
                vec!["STR", "STR"],
            ),
            (
                "def f\n  \"a\" \"b #{name}\"\nend\n",
                Language::Ruby,
                ".rb",
                "\"b #{name}\"",
                vec!["STR", "STR", "EVSTR"],
            ),
            (
                "def f():\n    \"a\" \"b\"\n",
                Language::Python,
                ".py",
                "\"a\"",
                vec!["STR", "STR"],
            ),
            (
                "def f():\n    \"a\" f\"b {name}\"\n",
                Language::Python,
                ".py",
                "f\"b {name}\"",
                vec!["STR", "STRING_START", "STR", "EVSTR", "STRING_END"],
            ),
        ] {
            let root = parse_language_source(source, language, suffix);
            let dstr = first_node(&root, "DSTR", expected_text);

            assert_eq!(child_types(dstr), expected_types);
            assert_ruby_parity(source, language, suffix);
        }
    }

    #[test]
    fn normalize_concatenated_string_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  \"a\" \"b\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b\"",
            ),
            (
                "def f\n  \"a\" \"b #{name}\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b #{name}\"",
            ),
            (
                "def f():\n    \"a\" \"b\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" \"b\"",
            ),
            (
                "def f():\n    \"a\" f\"b {name}\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" f\"b {name}\"",
            ),
            (
                "function f() { \"a\"; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "\"a\";",
            ),
            (
                "function f()\n  \"a\"\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "\n  \"a\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.normalize_concatenated_string_statement(node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_concatenated_string_statement",
                    kind,
                    text
                ),
                "normalize_concatenated_string_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_chained_string_matches_ruby_private_method() {
        for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
            (
                "def f\n  \"a\" \"b\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b\"",
                "chained_string",
                "\"a\" \"b\"",
            ),
            (
                "def f\n  \"a\" \"b #{name}\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b #{name}\"",
                "chained_string",
                "\"a\" \"b #{name}\"",
            ),
            (
                "def f():\n    \"a\" \"b\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" \"b\"",
                "concatenated_string",
                "\"a\" \"b\"",
            ),
            (
                "def f():\n    \"a\" f\"b {name}\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" f\"b {name}\"",
                "concatenated_string",
                "\"a\" f\"b {name}\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.normalize_chained_string(node);

            assert_eq!(
                node_value(&rust),
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_chained_string",
                    ruby_kind,
                    ruby_text
                ),
                "normalize_chained_string mismatch for {language:?} {rust_kind} {rust_text:?}"
            );
        }
    }

    #[test]
    fn dynamic_string_source_matches_ruby_private_method() {
        for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
            (
                "def f\n  \"a\" \"b #{name}\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b #{name}\"",
                "chained_string",
                "\"a\" \"b #{name}\"",
            ),
            (
                "def f\n  \"a\" \"b\"\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "\"a\" \"b\"",
                "chained_string",
                "\"a\" \"b\"",
            ),
            (
                "def f():\n    \"a\" f\"b {name}\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" f\"b {name}\"",
                "concatenated_string",
                "\"a\" f\"b {name}\"",
            ),
            (
                "def f():\n    \"a\" \"b\"\n",
                Language::Python,
                ".py",
                "block",
                "\"a\" \"b\"",
                "concatenated_string",
                "\"a\" \"b\"",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut normalized_children = Vec::new();
            for child in normalizer.named_children(node) {
                let normalized = normalizer.normalize_node(child);
                normalized_children.push((child, normalized));
            }
            let rust = normalizer
                .dynamic_string_source(&normalized_children)
                .map(|node| {
                    (
                        node.kind().to_string(),
                        super::node_text(node, source).to_string(),
                    )
                });
            let ruby = ruby_private_dynamic_string_source_signature(
                source, language, suffix, ruby_kind, ruby_text,
            );

            assert_eq!(
                rust, ruby,
                "dynamic_string_source mismatch for {language:?} {rust_kind} {rust_text:?}"
            );
        }
    }

    #[test]
    fn terminal_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  foo()\nend\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "()",
            ),
            (
                "def f\n  foo\n  foo()\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "foo\n  foo()",
            ),
            (
                "def f():\n    foo()\n",
                Language::Python,
                ".py",
                "argument_list",
                "()",
            ),
            (
                "def f():\n    foo\n",
                Language::Python,
                ".py",
                "block",
                "foo",
            ),
            (
                "function f() { foo(); }\n",
                Language::TypeScript,
                ".ts",
                "arguments",
                "()",
            ),
            (
                "function f()\n  foo()\nend\n",
                Language::Lua,
                ".lua",
                "arguments",
                "()",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.terminal_statement(node),
                ruby_private_predicate(source, language, suffix, "terminal_statement?", kind, text),
                "terminal_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_terminal_statement_matches_ruby_private_method() {
        let cases = vec![
            (
                "yield\n",
                Language::Ruby,
                ".rb",
                "yield",
                "yield",
                "yield",
                Vec::<&str>::new(),
            ),
            (
                "@name\n",
                Language::Ruby,
                ".rb",
                "instance_variable",
                "instance_variable",
                "@name",
                Vec::<&str>::new(),
            ),
            (
                "$1\n$value\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "global_variable",
                "$1",
                Vec::<&str>::new(),
            ),
            (
                "$1\n$value\n",
                Language::Ruby,
                ".rb",
                "global_variable",
                "global_variable",
                "$value",
                Vec::<&str>::new(),
            ),
            (
                "nil\ntrue\nfalse\n",
                Language::Ruby,
                ".rb",
                "nil",
                "nil",
                "nil",
                Vec::<&str>::new(),
            ),
            (
                "nil\ntrue\nfalse\n",
                Language::Ruby,
                ".rb",
                "true",
                "true",
                "true",
                Vec::<&str>::new(),
            ),
            (
                "nil\ntrue\nfalse\n",
                Language::Ruby,
                ".rb",
                "false",
                "false",
                "false",
                Vec::<&str>::new(),
            ),
            (
                ":ready\n",
                Language::Ruby,
                ".rb",
                "simple_symbol",
                "simple_symbol",
                ":ready",
                Vec::<&str>::new(),
            ),
            (
                "-123\n",
                Language::Ruby,
                ".rb",
                "unary",
                "unary",
                "-123",
                Vec::<&str>::new(),
            ),
            (
                "[]\n",
                Language::Ruby,
                ".rb",
                "array",
                "array",
                "[]",
                Vec::<&str>::new(),
            ),
            (
                "foo\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "foo\n",
                Language::Ruby,
                ".rb",
                "identifier",
                "identifier",
                "foo",
                vec!["foo"],
            ),
            (
                "foo\n",
                Language::Python,
                ".py",
                "expression_statement",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "foo;\n",
                Language::TypeScript,
                ".ts",
                "identifier",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "foo()\n",
                Language::Lua,
                ".lua",
                "identifier",
                "identifier",
                "foo",
                Vec::<&str>::new(),
            ),
            (
                "foo()\n",
                Language::Ruby,
                ".rb",
                "argument_list",
                "argument_list",
                "()",
                Vec::<&str>::new(),
            ),
        ];

        for (source, language, suffix, ruby_kind, rust_kind, text, locals) in cases {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, rust_kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            if !locals.is_empty() {
                normalizer
                    .local_stack
                    .push(locals.iter().map(|name| name.to_string()).collect());
            }
            let rust = node_value(&normalizer.normalize_terminal_statement(node));

            assert_eq!(
                rust,
                ruby_private_normalize_terminal_statement_value(
                    source,
                    language,
                    suffix,
                    ruby_kind,
                    text,
                    &locals,
                ),
                "normalize_terminal_statement mismatch for {language:?} ruby={ruby_kind} rust={rust_kind} {text:?} locals={locals:?}"
            );
        }
    }

    #[test]
    fn operator_assignment_statement_parts_matches_ruby_private_method() {
        for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
            (
                "def f\n  x += 1\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x += 1",
                "operator_assignment",
                "x += 1",
            ),
            (
                "def f\n  x ||= y\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x ||= y",
                "operator_assignment",
                "x ||= y",
            ),
            (
                "def f\n  x += 1\n  y += 2\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x += 1\n  y += 2",
                "body_statement",
                "x += 1\n  y += 2",
            ),
            (
                "def f():\n    x += 1\n",
                Language::Python,
                ".py",
                "block",
                "x += 1",
                "augmented_assignment",
                "x += 1",
            ),
            (
                "function f() { obj.x ||= y; }\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "obj.x ||= y",
                "augmented_assignment_expression",
                "obj.x ||= y",
            ),
            (
                "function f() { x += 1; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "x += 1;",
                "expression_statement",
                "x += 1;",
            ),
            (
                "function f()\n  x = x + 1\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "x = x + 1",
                "block",
                "x = x + 1",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer.operator_assignment_statement_parts(node).map(
                |(left, operator, right)| {
                    (
                        left.kind().to_string(),
                        super::node_text(left, source).to_string(),
                        operator,
                        right.kind().to_string(),
                        super::node_text(right, source).to_string(),
                    )
                },
            );
            let ruby = ruby_private_operator_assignment_statement_parts_signature(
                source, language, suffix, ruby_kind, ruby_text,
            );

            assert_eq!(
                rust, ruby,
                "operator_assignment_statement_parts mismatch for {language:?} {rust_kind} {rust_text:?}"
            );
        }
    }

    #[test]
    fn operator_assignment_statement_matches_ruby_private_predicate() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  x += 1\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x += 1",
            ),
            (
                "def f\n  x ||= y\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x ||= y",
            ),
            (
                "def f\n  x = 1\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x = 1",
            ),
            (
                "def f\n  x += 1\n  y += 2\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x += 1\n  y += 2",
            ),
            (
                "def f():\n    x += 1\n",
                Language::Python,
                ".py",
                "block",
                "x += 1",
            ),
            (
                "function f() { x += 1; }\n",
                Language::TypeScript,
                ".ts",
                "expression_statement",
                "x += 1;",
            ),
            (
                "function f()\n  x = x + 1\nend\n",
                Language::Lua,
                ".lua",
                "block",
                "x = x + 1",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.operator_assignment_statement(node),
                ruby_private_predicate(
                    source,
                    language,
                    suffix,
                    "operator_assignment_statement?",
                    kind,
                    text
                ),
                "operator_assignment_statement? mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn normalize_operator_assignment_statement_matches_ruby_private_method() {
        for (source, language, suffix, kind, text) in [
            (
                "def f\n  x += 1\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x += 1",
            ),
            (
                "def f\n  x ||= y\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "x ||= y",
            ),
            (
                "def f\n  items[index] += value\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "items[index] += value",
            ),
            (
                "def f\n  object.value += 1\nend\n",
                Language::Ruby,
                ".rb",
                "body_statement",
                "object.value += 1",
            ),
            (
                "def f():\n    x += 1\n",
                Language::Python,
                ".py",
                "block",
                "x += 1",
            ),
            (
                "function f() { x += 1; }\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "x += 1",
            ),
            (
                "function f() { obj.x ||= y; }\n",
                Language::TypeScript,
                ".ts",
                "augmented_assignment_expression",
                "obj.x ||= y",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let mut normalizer = super::TreeSitterNormalizer::new(source, language);
            let rust = normalizer
                .normalize_operator_assignment_statement(node)
                .map(|node| node_value(&node))
                .unwrap_or(Value::Null);

            assert_eq!(
                rust,
                ruby_private_normalize_method_value(
                    source,
                    language,
                    suffix,
                    "normalize_operator_assignment_statement",
                    kind,
                    text
                ),
                "normalize_operator_assignment_statement mismatch for {language:?} {kind} {text:?}"
            );
        }
    }

    #[test]
    fn python_f_string_interpolation_next_to_equals_is_evstr_not_assignment() {
        let root = parse_language_source(
            r#"
class Tag:
    @property
    def markup(self):
        return f"[{self.name}={self.parameters}]"
"#,
            Language::Python,
            ".py",
        );
        let dstr = first_node(&root, "DSTR", r#"f"[{self.name}={self.parameters}]""#);

        let types = child_types(dstr);
        assert_eq!(
            types,
            vec![
                "STRING_START",
                "STR",
                "EVSTR",
                "STR",
                "EVSTR",
                "STR",
                "STRING_END"
            ],
            "expected Ruby-style f-string interpolation parts in {dstr:#?}"
        );
        assert!(
            !types.contains(&"LASGN"),
            "interpolation next to '=' must not normalize as assignment: {dstr:#?}"
        );
    }

    #[test]
    fn python_relative_import_prefix_only_has_no_children() {
        let root = parse_language_source(
            r#"
if __name__ == "__main__":
    from . import box as box
"#,
            Language::Python,
            ".py",
        );
        let relative_import = first_node(&root, "RELATIVE_IMPORT", ".");

        assert!(
            relative_import.children.is_empty(),
            "Ruby exposes bare relative import prefix as an empty RELATIVE_IMPORT: {relative_import:#?}"
        );
    }

    #[test]
    fn python_annotation_type_wrappers_match_ruby_tree_shape() {
        let root = parse_language_source(
            r#"
from typing import Callable

_is_single_cell_widths: Callable[[str], bool] = value
last_measured_character: str | None = None
fileno: Callable[[], int] | None = value
"#,
            Language::Python,
            ".py",
        );

        let str_list_type = first_node(&root, "TYPE", "[str]");
        assert_eq!(child_types(str_list_type), vec!["LVAR"]);
        assert_eq!(
            child_node(str_list_type, 0).children,
            vec![Child::String("str".to_string())]
        );

        let empty_list_type = first_node(&root, "TYPE", "[]");
        assert!(
            empty_list_type.children.is_empty(),
            "Ruby keeps Callable[[]] list type empty: {empty_list_type:#?}"
        );

        let union_type = first_node(&root, "TYPE", "str | None");
        assert_eq!(child_types(union_type), vec!["LVAR", "NIL"]);
    }

    #[test]
    fn python_docstring_only_class_body_stays_block_wrapped() {
        let root = parse_language_source(
            r#"
class ColorParseError(Exception):
    """The color could not be parsed."""
"#,
            Language::Python,
            ".py",
        );
        let class_node = first_node(
            &root,
            "CLASS",
            "class ColorParseError(Exception):\n    \"\"\"The color could not be parsed.\"\"\"",
        );
        let scope = child_node(class_node, 2);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(
            child_types(body),
            vec!["STRING_START", "STR", "STRING_END"],
            "Ruby exposes docstring-only class body as BLOCK of string parts: {body:#?}"
        );
    }

    #[test]
    fn python_ellipsis_only_function_body_is_empty_scope_with_root_source() {
        assert_ruby_parity(
            r#"def __rich__():
    ...
"#,
            Language::Python,
            ".py",
        );
    }

    #[test]
    fn python_explicit_return_none_is_not_elided_from_function_body() {
        let source = r#"
class Thing:
    def _repr_latex_(self):
        return None
"#;
        let root = parse_language_source(source, Language::Python, ".py");
        let defn = first_node(
            &root,
            "DEFN",
            "def _repr_latex_(self):\n        return None",
        );
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "RETURN");
        assert_eq!(
            child_node(body, 0).r#type,
            "NIL",
            "Ruby only elides implicit nil bodies for Ruby, not explicit Python return None: {scope:#?}"
        );
        assert_ruby_parity(source, Language::Python, ".py");
    }

    #[test]
    fn python_with_attribute_item_uses_ruby_clause_children() {
        let root = parse_language_source(
            r#"
def page(self):
    with self._console._lock:
        buffer = self._console._buffer[:]
"#,
            Language::Python,
            ".py",
        );
        let clause = first_node(&root, "WITH_CLAUSE", "self._console._lock");

        assert_eq!(
            child_types(clause),
            vec!["CALL", "LVAR"],
            "Ruby with_clause exposes attribute receiver and field separately: {clause:#?}"
        );
        assert_eq!(child_node(clause, 0).text, "self._console");
        assert_eq!(child_node(clause, 1).text, "_lock");
    }

    #[test]
    fn python_bare_identifier_expression_statement_has_no_children() {
        let root = parse_language_source(
            r#"
def _is_jupyter():
    try:
        get_ipython  # type: ignore[name-defined]
    except NameError:
        return False
"#,
            Language::Python,
            ".py",
        );
        let expression = first_node(&root, "EXPRESSION_STATEMENT", "get_ipython");

        assert!(
            expression.children.is_empty(),
            "Ruby parser exposes bare identifier expression statements without named children: {expression:#?}"
        );
    }

    #[test]
    fn python_bare_identifier_only_block_has_no_children() {
        assert_ruby_parity(
            r#"
def get_exception():
    try:
        pass
    except:
        foobarbaz
"#,
            Language::Python,
            ".py",
        );
    }

    #[test]
    fn python_bare_dotted_expression_statement_normalizes_as_call() {
        let root = parse_language_source("os.get_terminal_size\n", Language::Python, ".py");
        let call = first_node(&root, "CALL", "os.get_terminal_size");

        assert_eq!(
            child_types(call),
            vec!["LVAR"],
            "bare Python dotted expression statements should normalize as calls: {call:#?}"
        );
    }

    #[test]
    fn python_bare_comparison_expression_statement_keeps_statement_wrapper() {
        let root = parse_language_source(
            r#"
def test_get_style():
    console.get_style("repr.brace") == Style(bold=True)
"#,
            Language::Python,
            ".py",
        );
        let expression = first_node(
            &root,
            "EXPRESSION_STATEMENT",
            r#"console.get_style("repr.brace") == Style(bold=True)"#,
        );

        assert_eq!(
            child_types(expression),
            vec!["CALL", "FCALL"],
            "Ruby exposes bare comparison statements as expression_statement operand children: {expression:#?}"
        );
    }

    #[test]
    fn python_delete_statement_matches_ruby_block_contexts() {
        assert_ruby_parity(
            r#"
def save(self, clear):
    if clear:
        del self._record_buffer[:]
    with self._record_buffer_lock:
        del self._record_buffer[:]
        text = ""
"#,
            Language::Python,
            ".py",
        );
    }

    #[test]
    fn python_single_subscript_expression_block_exposes_subscript_children() {
        assert_ruby_parity(
            r#"
def test_render():
    with pytest.raises(KeyError):
        top["asdasd"]
"#,
            Language::Python,
            ".py",
        );
    }

    #[test]
    fn python_single_if_block_under_try_matches_ruby_if_shape() {
        let root = parse_language_source(
            r#"
def load(args):
    try:
        if args.path == "-":
            json_data = sys.stdin.read()
        else:
            json_data = Path(args.path).read_text()
    except Exception as error:
        sys.exit(-1)
"#,
            Language::Python,
            ".py",
        );
        let if_node = first_node(
            &root,
            "IF",
            "if args.path == \"-\":\n            json_data = sys.stdin.read()\n        else:\n            json_data = Path(args.path).read_text()",
        );

        assert_eq!(
            child_types(if_node),
            vec!["OPCALL", "LASGN", "ELSE_CLAUSE"],
            "Ruby normalizes this Python try-body child as an IF: {if_node:#?}"
        );
        assert_eq!(child_types(child_node(if_node, 2)), vec!["BLOCK"]);
    }

    #[test]
    fn python_single_decorated_definition_block_exposes_decorator_and_function() {
        assert_ruby_parity(
            r#"
def test_inspect_swig_edge_case():
    class Thing:
        @property
        def __class__(self):
            raise AttributeError
"#,
            Language::Python,
            ".py",
        );
    }

    #[test]
    fn python_nested_class_inside_class_body_matches_ruby_iter_shape() {
        let root = parse_language_source(
            r#"
def test_can_handle_special_characters_in_docstrings():
    class Something:
        class Thing:
            pass
"#,
            Language::Python,
            ".py",
        );
        let iter = first_node(&root, "ITER", "class Thing:\n            pass");

        assert_eq!(child_node(iter, 0).r#type, "VCALL");
        assert_eq!(
            child_node(iter, 0).children,
            vec![Child::Symbol("Thing".to_string()), Child::Nil]
        );
        assert_eq!(child_node(iter, 1).r#type, "SCOPE");
    }

    #[test]
    fn lua_local_assignment_call_rhs_matches_ruby_expression_list_shape() {
        let root = parse_language_source(
            r#"local test_env = require("spec.util.test_env")
"#,
            Language::Lua,
            ".lua",
        );
        let expression_list =
            first_node(&root, "EXPRESSION_LIST", r#"require("spec.util.test_env")"#);

        assert_eq!(
            child_types(expression_list),
            vec!["LVAR", "ARGUMENTS"],
            "Ruby exposes a Lua call RHS expression_list as the call function and arguments, without a FUNCTION_CALL wrapper: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_local_assignment_member_rhs_matches_ruby_expression_list_shape() {
        let root = parse_language_source("local run = test_env.run\n", Language::Lua, ".lua");
        let expression_list = first_node(&root, "EXPRESSION_LIST", "test_env.run");

        assert_eq!(
            child_types(expression_list),
            vec!["LVAR", "LVAR"],
            "Ruby exposes a Lua dotted RHS expression_list as receiver and field, without a DOT_INDEX_EXPRESSION wrapper: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_table_string_entry_matches_ruby_field_shape() {
        let root = parse_language_source(
            "local extra_rocks = {\n   \"/luasocket-${LUASOCKET}.src.rock\",\n}\n",
            Language::Lua,
            ".lua",
        );
        let expression_list = first_node(
            &root,
            "EXPRESSION_LIST",
            "{\n   \"/luasocket-${LUASOCKET}.src.rock\",\n}",
        );
        let field = child_node(expression_list, 0);
        let string = child_node(field, 0);

        assert_eq!(
            child_types(expression_list),
            vec!["FIELD"],
            "Ruby exposes a Lua table constructor assignment RHS as its field children: {expression_list:#?}"
        );
        assert_eq!(string.r#type, "STR");
        assert_eq!(
            string.children,
            vec![Child::String("/luasocket-${LUASOCKET}.src.rock".to_string())],
            "Ruby normalizes a Lua table string field from string_content, without quotes: {string:#?}"
        );
    }

    #[test]
    fn lua_table_dollar_string_entry_matches_ruby_str_not_gvar() {
        let root = parse_language_source(
            "local incdirs = { \"$(FOO1_INCDIR)\" }\n",
            Language::Lua,
            ".lua",
        );
        let string = first_node(&root, "STR", "$(FOO1_INCDIR)");
        let mut gvars = Vec::new();
        nodes_of_type(&root, "GVAR", &mut gvars);

        assert_eq!(
            string.children,
            vec![Child::String("$(FOO1_INCDIR)".to_string())],
            "Ruby normalizes Lua table strings starting with $ as STR, not GVAR: {string:#?}"
        );
        assert!(
            gvars.is_empty(),
            "Lua string_content starting with $ must not normalize as GVAR: {gvars:#?}"
        );
    }

    #[test]
    fn lua_table_call_entry_matches_ruby_field_children_shape() {
        assert_ruby_parity(
            "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_table_identifier_entry_matches_ruby_empty_field_shape() {
        assert_ruby_parity(
            "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_single_call_function_body_matches_ruby_block_shape() {
        assert_ruby_parity(
            "before_each(function()\n   test_env.setup_specs(extra_rocks)\nend)\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_single_assignment_function_body_matches_ruby_lasgn_shape() {
        assert_ruby_parity(
            "lazy_setup(function()\n   git = git_repo.start()\nend)\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_single_bare_assignment_function_body_matches_ruby_lasgn_shape() {
        let root = parse_language_source("function()\n   x = y\nend\n", Language::Lua, ".lua");
        let defn = first_node(&root, "DEFN", "function()\n   x = y\nend");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);
        let right = child_node(body, 1);

        assert_eq!(body.r#type, "LASGN");
        assert_eq!(body.children.first(), Some(&Child::String("x".to_string())));
        assert_eq!(right.r#type, "EXPRESSION_LIST");
        assert!(
            right.children.is_empty(),
            "Ruby exposes a bare identifier Lua single-assignment RHS with no children: {right:#?}"
        );
    }

    #[test]
    fn lua_single_dotted_assignment_function_body_normalizes_as_attribute_assignment() {
        let root = parse_language_source(
            "function()\n   package.path = oldpath\nend\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(&root, "DEFN", "function()\n   package.path = oldpath\nend");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);
        let assignment = body;
        let receiver = child_node(assignment, 0);
        let args = child_node(assignment, 2);

        assert_eq!(body.r#type, "ATTRASGN");
        assert_eq!(receiver.r#type, "LVAR");
        assert_eq!(
            receiver.children,
            vec![Child::String("package".to_string())]
        );
        assert_eq!(
            assignment.children.get(1),
            Some(&Child::Symbol("path=".to_string()))
        );
        assert_eq!(args.r#type, "LIST");
    }

    #[test]
    fn lua_single_local_assignment_function_body_matches_ruby_lasgn_shape() {
        assert_ruby_parity(
            "it(function()\n   local output = run.luarocks(\"show --rock-tree luacov\")\nend)\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_assigned_function_expression_matches_ruby_expression_list_shape() {
        assert_ruby_parity(
            "local test_with_location = function(location)\n   lfs.mkdir(location)\nend\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_assigned_function_if_else_matches_fixed_ruby_if_shape() {
        assert_ruby_parity(
            "local make_unreadable = function(path)\n  if is_win then\n    fs.execute(\"x\")\n  else\n    fs.execute(\"y\")\n  end\nend\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_single_return_function_body_matches_ruby_opcall_shape() {
        let source = "function sum.sum(a, b)\n   return a + b\nend\n";
        let root = parse_language_source(source, Language::Lua, ".lua");
        let defn = first_node(
            &root,
            "DEFN",
            "function sum.sum(a, b)\n   return a + b\nend",
        );
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);
        let returned = child_node(body, 0);

        assert_eq!(body.r#type, "RETURN");
        assert_eq!(returned.r#type, "OPCALL");
        assert_eq!(
            returned.children.get(1),
            Some(&Child::Symbol("+".to_string())),
            "Ruby exposes a single Lua return body as RETURN wrapping the returned operator call: {body:#?}"
        );
        assert_ruby_parity(source, Language::Lua, ".lua");
    }

    #[test]
    fn lua_top_level_return_identifier_matches_ruby_empty_expression_list() {
        let root = parse_language_source("return sum\n", Language::Lua, ".lua");
        let return_node = first_node(&root, "RETURN", "return sum");
        let expression_list = child_node(return_node, 0);

        assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
        assert!(
            expression_list.children.is_empty(),
            "Ruby exposes a Lua return of a bare identifier as an empty expression_list: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_top_level_return_scalar_literals_match_ruby_empty_expression_list() {
        for literal in ["true", "false", "nil", "0"] {
            let root = parse_language_source(&format!("return {literal}\n"), Language::Lua, ".lua");
            let return_node = first_node(&root, "RETURN", &format!("return {literal}"));
            let expression_list = child_node(return_node, 0);

            assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
            assert!(
                expression_list.children.is_empty(),
                "Ruby exposes a Lua return of {literal} as an empty expression_list: {expression_list:#?}"
            );
        }
    }

    #[test]
    fn lua_assignment_scalar_literals_match_ruby_empty_expression_list() {
        for literal in ["true", "false", "nil", "0"] {
            let root =
                parse_language_source(&format!("tmpfile = {literal}\n"), Language::Lua, ".lua");
            let assignment = first_node(&root, "LASGN", &format!("tmpfile = {literal}"));
            let expression_list = child_node(assignment, 1);

            assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
            assert!(
                expression_list.children.is_empty(),
                "Ruby exposes a Lua scalar literal assignment RHS as an empty expression_list: {expression_list:#?}"
            );
        }
    }

    #[test]
    fn lua_no_paren_string_argument_matches_ruby_string_content_shape() {
        let root = parse_language_source("V\"foo\"\n", Language::Lua, ".lua");
        let call = first_node(&root, "FUNCTION_CALL", "V\"foo\"");
        let arguments = child_node(call, 1);
        let string = child_node(arguments, 0);

        assert_eq!(arguments.r#type, "ARGUMENTS");
        assert_eq!(arguments.text, "\"foo\"");
        assert_eq!(string.r#type, "STR");
        assert_eq!(string.text, "foo");
        assert_eq!(string.children, vec![Child::String("foo".to_string())]);
    }

    #[test]
    fn lua_long_string_assignment_matches_ruby_expression_list_content_shape() {
        assert_ruby_parity(
            "local c_module_source = [[\n   #include <lua.h>\n]]\n",
            Language::Lua,
            ".lua",
        );
    }

    #[test]
    fn lua_elseif_branch_is_preserved_as_if_alternative() {
        let root = parse_language_source(
            r#"if test_env.LUA_V == "5.1" then
  one()
elseif test_env.LUA_V == "5.2" then
  two()
end
"#,
            Language::Lua,
            ".lua",
        );
        let if_node = first_node(
            &root,
            "IF",
            "if test_env.LUA_V == \"5.1\" then\n  one()\nelseif test_env.LUA_V == \"5.2\" then\n  two()\nend",
        );
        let alternative = child_node(if_node, 2);

        assert_eq!(alternative.r#type, "ELSEIF_STATEMENT");
    }

    #[test]
    fn lua_binary_assignment_rhs_matches_ruby_expression_list_shape() {
        let root = parse_language_source(
            "local rockspec = testing_paths.fixtures_dir .. \"/build_only_deps-0.1-1.rockspec\"\n",
            Language::Lua,
            ".lua",
        );
        let expression_list = first_node(
            &root,
            "EXPRESSION_LIST",
            "testing_paths.fixtures_dir .. \"/build_only_deps-0.1-1.rockspec\"",
        );

        assert_eq!(
            child_types(expression_list),
            vec!["DOT_INDEX_EXPRESSION", "STR"],
            "Ruby exposes a Lua binary RHS expression_list as the binary operands, without a BINARY_EXPRESSION wrapper: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_local_declaration_without_rhs_matches_ruby_empty_variable_list() {
        let root = parse_language_source("local tmpdir\n", Language::Lua, ".lua");
        let variable_list = first_node(&root, "VARIABLE_LIST", "tmpdir");

        assert!(
            variable_list.children.is_empty(),
            "Ruby exposes a Lua local declaration without RHS as an empty VARIABLE_LIST: {variable_list:#?}"
        );
    }

    #[test]
    fn lua_multi_local_declaration_without_rhs_keeps_ruby_variable_list_children() {
        let root = parse_language_source("local cfg, fs\n", Language::Lua, ".lua");
        let variable_list = first_node(&root, "VARIABLE_LIST", "cfg, fs");

        assert_eq!(
            child_types(variable_list),
            vec!["LVAR", "LVAR"],
            "Ruby keeps children for a multi-name Lua local declaration without RHS: {variable_list:#?}"
        );
    }

    #[test]
    fn lua_single_generic_for_variable_matches_ruby_empty_variable_list() {
        let root = parse_language_source(
            "for f in lfs.dir(spec_quick) do end\n",
            Language::Lua,
            ".lua",
        );
        let variable_list = first_node(&root, "VARIABLE_LIST", "f");

        assert!(
            variable_list.children.is_empty(),
            "Ruby exposes a single Lua generic-for variable list as empty: {variable_list:#?}"
        );
    }

    #[test]
    fn lua_multi_generic_for_variable_list_keeps_ruby_children() {
        let root =
            parse_language_source("for _, t in ipairs(tests) do end\n", Language::Lua, ".lua");
        let variable_list = first_node(&root, "VARIABLE_LIST", "_, t");

        assert_eq!(
            child_types(variable_list),
            vec!["LVAR", "LVAR"],
            "Ruby keeps children for a multi-name Lua generic-for variable list: {variable_list:#?}"
        );
    }

    #[test]
    fn normalizes_safe_navigation_inside_multi_statement_else_body() {
        let root = parse_source(
            r#"
def x(cond, node)
  if cond
    node.storage = :stack
  else
    node.storage = :heap
    current_fn_ctx&.record_heap_use!
  end
end
"#,
        );
        let mut qcalls = Vec::new();
        nodes_of_type(&root, "QCALL", &mut qcalls);

        assert!(
            qcalls
                .iter()
                .any(|node| node.text == "current_fn_ctx&.record_heap_use!"),
            "expected normalized QCALL for current_fn_ctx safe navigation, got {qcalls:#?} in {root:#?}"
        );
    }

    #[test]
    fn normalizes_visibility_wrapped_singleton_def() {
        let root = parse_source(
            r#"
private_class_method def self.collect_payload_binding_names(node, names)
  if node.is_a?(AST::Identifier)
    return
  end
  AST.wrapped_children(node).each { |child| collect_payload_binding_names(child, names) if child.is_a?(AST::Locatable) }
end
"#,
        );
        let mut defs = Vec::new();
        nodes_of_type(&root, "DEFS", &mut defs);

        assert!(
            defs.iter().any(|node| node.children.get(1)
                == Some(&Child::Symbol("collect_payload_binding_names".to_string()))),
            "expected normalized DEFS for visibility-wrapped singleton def, got {root:#?}"
        );

        let def = defs
            .into_iter()
            .find(|node| {
                node.children.get(1)
                    == Some(&Child::Symbol("collect_payload_binding_names".to_string()))
            })
            .expect("visibility-wrapped singleton def should normalize to DEFS");
        let mut calls = Vec::new();
        nodes_of_type(def, "CALL", &mut calls);
        nodes_of_type(def, "FCALL", &mut calls);
        calls.sort_by_key(|node| (node.first_lineno, node.first_column));
        let ordered = calls
            .iter()
            .map(|node| (node.first_lineno, node.text.as_str()))
            .collect::<Vec<_>>();

        let first_if_call = ordered
            .iter()
            .position(|(_line, text)| *text == "node.is_a?(AST::Identifier)")
            .expect("expected identifier guard call");
        let recursive_call = ordered
            .iter()
            .position(|(_line, text)| *text == "collect_payload_binding_names(child, names)")
            .expect("expected recursive payload scan call");
        assert!(
            first_if_call < recursive_call,
            "expected method body calls in source order, got {ordered:#?} in {root:#?}"
        );
    }

    #[test]
    fn normalizes_heredoc_beginning_as_dynamic_string_receiver() {
        let root = parse_source(
            r#"
def emit
  <<~ZIG.chomp
    hi
  ZIG
end
"#,
        );
        let mut calls = Vec::new();
        nodes_of_type(&root, "CALL", &mut calls);

        let call = calls
            .iter()
            .find(|node| node.text == "<<~ZIG.chomp")
            .expect("expected heredoc chomp call");
        assert_eq!(
            call.children.get(1),
            Some(&Child::Symbol("chomp".to_string()))
        );
        assert_eq!(
            call.children
                .first()
                .and_then(super::node)
                .map(|node| node.r#type.as_str()),
            Some("DSTR")
        );
    }

    #[test]
    fn flatten_and_matches_ruby_ast_helper() {
        let left = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::String("a".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 1,
            text: "a".to_string(),
        };
        let right = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::String("b".to_string())],
            first_lineno: 1,
            first_column: 5,
            last_lineno: 1,
            last_column: 6,
            text: "b".to_string(),
        };
        let and_node = Node {
            r#type: "AND".to_string(),
            children: vec![Child::Node(Box::new(left)), Child::Node(Box::new(right))],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 6,
            text: "a && b".to_string(),
        };

        assert_eq!(super::flatten_and(&and_node).len(), 2);
    }
}
