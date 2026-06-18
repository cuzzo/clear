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

struct TreeSitterNormalizer<'source> {
    source: &'source str,
    language: Language,
    local_stack: Vec<BTreeSet<String>>,
    root_span: Option<Span>,
}

impl<'source> TreeSitterNormalizer<'source> {
    fn new(source: &'source str, language: Language) -> Self {
        Self {
            source,
            language,
            local_stack: Vec::new(),
            root_span: None,
        }
    }

    fn normalize(mut self, root: TreeSitterNode<'_>) -> Node {
        self.root_span = Some(span(root));
        let children = if self.language == Language::Ruby {
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
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if if_kind(node.kind()) {
            return self.normalize_if(node);
        }
        if let Some(loop_type) = loop_kind(node.kind()) {
            return self.normalize_loop(node, loop_type);
        }
        if self.case_kind(node.kind()) {
            return self.normalize_case(node);
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
        if self.super_statement(node) {
            return Some(self.normalize_super_statement(node));
        }
        if self.unary_not_statement(node) {
            return self.normalize_unary_not(node);
        }
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
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
        if instance_variable_node(node, self.source) {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            ));
        }
        if global_variable_node(node, self.source) {
            return Some(self.normalize_global_variable(node));
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
            "singleton_method" => self.normalize_singleton_function(node),
            "class" | "class_definition" | "class_declaration" | "class_specifier" => {
                self.normalize_class(node)
            }
            "module" => self.normalize_module(node),
            "lambda" => self.normalize_lambda(node),
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
            "interpolation" => self.normalize_interpolation(node),
            "heredoc_beginning" => Some(self.normalize_heredoc_beginning(node)),
            "chained_string" => Some(self.normalize_chained_string(node)),
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
        let name = self.function_name(node)?;
        let args = self.normalize_parameters(self.parameters_child(node));
        let body = self.with_ruby_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
            normalizer.elide_implicit_nil_body(body)
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "DEFN",
            vec![Child::Symbol(name), Child::Node(Box::new(scope))],
            node,
        ))
    }

    fn normalize_singleton_function(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.function_name(node)?;
        let receiver = self
            .named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "self" | "constant" | "identifier"))
            .and_then(|child| self.normalize_node(child))
            .unwrap_or_else(|| self.wrap("SELF", Vec::new(), node));
        let args = self.normalize_parameters(self.parameters_child(node));
        let body = self.with_ruby_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
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
        let body_node = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .or_else(|| self.named_children(node).into_iter().last())?;
        let body = self.with_ruby_scope(node, false, |normalizer| {
            normalizer.normalize_body(body_node).map(dynamic_scope)
        });
        let scope = self.scope(body, None, node);
        Some(self.wrap("LAMBDA", vec![Child::Node(Box::new(scope))], node))
    }

    fn normalize_yield(&mut self, node: TreeSitterNode<'_>) -> Node {
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
            .unwrap_or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .filter(|child| child.kind() != "yield")
                    .filter_map(|child| self.normalize_node(child))
                    .collect()
            });
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
            .unwrap_or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .filter(|child| child.kind() != "yield")
                    .filter_map(|child| self.normalize_node(child))
                    .collect()
            });
        self.wrap(
            "YIELD",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
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
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if if_kind(node.kind()) {
            return self.normalize_if(node);
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
            return self.normalize_unary_not(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
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
            .or_else(|| self.explicit_alternative(node));
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

    fn normalize_loop(&mut self, node: TreeSitterNode<'_>, node_type: &str) -> Option<Node> {
        if matches!(node.kind(), "while_modifier" | "until_modifier") {
            let named = self.named_children(node);
            let action = *named.first()?;
            let condition = *named.get(1)?;
            let condition = optional_node(self.normalize_node(condition));
            let action = optional_node(self.normalize_modifier_action(action));
            return Some(self.wrap(
                node_type,
                vec![condition, action, Child::String("true".to_string())],
                node,
            ));
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
        let condition = self
            .named_field(if_node, "condition")
            .or_else(|| self.named_field(if_node, "predicate"))
            .or_else(|| self.first_named(if_node))?;
        if self.identifier_kind(condition.kind()) {
            return self.normalize_python_if_statement_as_iter(if_node);
        }
        let consequence = self
            .named_field(if_node, "consequence")
            .or_else(|| self.named_field(if_node, "body"))
            .or_else(|| self.branch_child(if_node, condition, 0));
        let alternative = self.explicit_alternative(if_node);
        let mut children = Vec::new();
        if let Some(condition) = self.normalize_node(condition) {
            children.push(Child::Node(Box::new(condition)));
        }
        if let Some(consequence) = consequence.and_then(|child| {
            self.normalize_python_else_if_block(child)
                .or_else(|| self.normalize_body(child))
        }) {
            children.push(Child::Node(Box::new(consequence)));
        }
        if let Some(alternative) =
            alternative.and_then(|child| self.normalize_else_or_branch(child))
        {
            children.push(Child::Node(Box::new(alternative)));
        }
        Some(self.wrap("BLOCK", children, node))
    }

    fn normalize_python_if_statement_as_iter(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let condition = self
            .named_field(node, "condition")
            .or_else(|| self.named_field(node, "predicate"))
            .or_else(|| self.first_named(node))?;
        let body = self
            .named_field(node, "consequence")
            .or_else(|| self.named_field(node, "body"))
            .or_else(|| self.branch_child(node, condition, 0))?;
        let call_source = self.source_before_child(node, body);
        let call = self.wrap_from_source_node(
            "VCALL",
            vec![
                Child::Symbol(node_text(condition, self.source).to_string()),
                Child::Nil,
            ],
            &call_source,
        );
        let body = self.with_ruby_scope(body, false, |normalizer| {
            normalizer.normalize_body(body).map(dynamic_scope)
        });
        let scope = self.scope(body, None, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
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
        let body = self.when_body(node);
        let mut patterns = Vec::new();
        for child in self.named_children(node) {
            if Some(child) == body
                || self.block_kind(child.kind())
                || self.statement_node(child.kind())
                || self.when_kind(child.kind())
            {
                continue;
            }
            if let Some(pattern) = self.normalize_node(child) {
                patterns.push(pattern);
            }
        }
        patterns
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
        self.named_children(node)
            .into_iter()
            .find(|child| child.kind() == "else")
            .and_then(|else_node| self.normalize_else_or_branch(else_node))
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
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_return_value(child))
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap(return_kind(node.kind()), children, node))
    }

    fn normalize_return_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() != "argument_list" {
            return self.normalize_node(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
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
            Some(self.list(values, node))
        }
    }

    fn normalize_ternary_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let (question_byte, colon_byte) = self.ternary_separator_bytes(node)?;
        let named = self.named_children(node);
        let condition = *named.first()?;
        let positive_nodes = named
            .iter()
            .copied()
            .filter(|child| child.start_byte() > question_byte && child.end_byte() <= colon_byte)
            .collect::<Vec<_>>();
        let negative_nodes = named
            .iter()
            .copied()
            .filter(|child| child.start_byte() > colon_byte)
            .collect::<Vec<_>>();
        let condition = optional_node(self.normalize_node(condition));
        let positive = optional_node(self.normalize_ternary_branch(&positive_nodes));
        let negative = optional_node(self.normalize_ternary_branch(&negative_nodes));
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
        let operands = self.named_children(node);
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
        let left = operands.first().and_then(|left| self.normalize_node(*left));
        let right_raw = operands.get(1).copied()?;
        let right = self.normalize_node(right_raw);
        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(self.binary_operator(node)?),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    fn normalize_infix_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let (left_raw, operator, right_raw) = self.infix_statement_parts(node)?;
        let left = self.normalize_node(left_raw);
        let right = self.normalize_node(right_raw);
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

    fn ternary_separator_bytes(&self, node: TreeSitterNode<'_>) -> Option<(usize, usize)> {
        let mut question = None;
        let mut colon = None;
        for child in node.children(&mut node.walk()) {
            if child.is_named() {
                continue;
            }
            let text = node_text(child, self.source);
            if text == "?" && question.is_none() {
                question = Some(child.start_byte());
            } else if text == ":" && question.is_some() {
                colon = Some(child.start_byte());
                break;
            }
        }
        Some((question?, colon?))
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
                    Child::Nil,
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

        if left.kind() == "instance_variable"
            || left.kind() == "global_variable"
            || node_text(left, self.source).starts_with('@')
            || node_text(left, self.source).starts_with('$')
        {
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
        if left.kind() == "instance_variable" || node_text(left, self.source).starts_with('@') {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(left, self.source).to_string())],
                left,
            ));
        }
        if left.kind() == "global_variable" || node_text(left, self.source).starts_with('$') {
            return Some(self.wrap(
                "GVAR",
                vec![Child::String(node_text(left, self.source).to_string())],
                left,
            ));
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
        if self.call_block(node).is_some() {
            return self.normalize_call_with_block(node);
        }
        if self.visibility_inline_def_call(node) {
            return self.normalize_visibility_inline_def(node);
        }
        self.normalize_call_without_block(node, None)
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
        let call = self.normalize_call_without_block(node, block)?;
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

    fn normalize_statement_call_with_block(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = if self.dotted_call(node) {
            node
        } else {
            self.named_children(node).into_iter().find(|child| {
                Some(*child) != block
                    && (self.call_kind(child.kind()) || self.member_read_node(*child))
            })?
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

    fn normalize_dotted_expression(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let block = self.call_block(node);
        let call = self.normalize_dotted_call_expression(node)?;
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
            let args = list_or_nil(args, node, self);
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
            let node_type = if args.is_empty() { "VCALL" } else { "FCALL" };
            return Some(self.wrap(
                node_type,
                vec![
                    Child::Symbol(node_text(function, self.source).to_string()),
                    list_or_nil(args, node, self),
                ],
                node,
            ));
        }
        if self.language == Language::Ruby && self.const_kind(function.kind()) {
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol(node_text(function, self.source).to_string()),
                    list_or_nil(args, node, self),
                ],
                node,
            ));
        }
        if self.member_read_node(function) {
            let (receiver, method) = self.member_parts(function)?;
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(args, node, self);
            return Some(self.wrap("CALL", vec![receiver, Child::Symbol(method), args], node));
        }
        let function = optional_node(self.normalize_node(function));
        let args = list_or_nil(args, node, self);
        Some(self.wrap(
            "CALL",
            vec![function, Child::Symbol("call".to_string()), args],
            node,
        ))
    }

    fn normalize_element_reference(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let receiver = *named.first()?;
        let args = named
            .iter()
            .skip(1)
            .filter_map(|arg| self.normalize_node(*arg))
            .collect::<Vec<_>>();
        if receiver.kind() == "self" {
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
        if self.dotted_call(node) {
            return self.normalize_dotted_call_expression(node);
        }
        if let Some(call) = self.first_dotted_call_descendant(node) {
            return self.normalize_node(call);
        }
        self.normalize_body_nodes(self.named_children(node), node)
    }

    fn normalize_dotted_call_expression(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let (receiver_raw, method) = self.dotted_call_parts(node, None)?;
        let args = self.call_arguments(node, None);
        let args = list_or_nil(args, node, self);
        let receiver = optional_node(self.normalize_node(receiver_raw));
        let node_type = if self.safe_navigation_call(node) {
            "QCALL"
        } else {
            "CALL"
        };
        let source_end = self
            .named_children(node)
            .into_iter()
            .filter(|child| !matches!(child.kind(), "block" | "do_block"))
            .last()
            .unwrap_or(receiver_raw);
        Some(self.wrap_from_nodes(
            node_type,
            vec![receiver, Child::Symbol(method), args],
            receiver_raw,
            source_end,
        ))
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
            return Some(self.wrap(
                "ENSURE",
                vec![optional_node(body), optional_node(ensure_body)],
                node,
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
        let rescued = self.wrap(
            "RESCUE",
            vec![
                optional_node(body),
                optional_node(self.link_rescue_chain(resbodies)),
                Child::Nil,
            ],
            node,
        );
        let Some(ensure_node) = ensure_node else {
            return Some(rescued);
        };
        let ensure_body = self.normalize_body(ensure_node);
        Some(self.wrap(
            "ENSURE",
            vec![Child::Node(Box::new(rescued)), optional_node(ensure_body)],
            node,
        ))
    }

    fn normalize_rescue_clause(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let exceptions = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exceptions");
        let exception_nodes = exceptions
            .map(|exceptions| {
                self.named_children(exceptions)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let exception_variable = self.rescue_exception_variable(node);
        let handler = self.named_children(node).into_iter().rev().find(|child| {
            !matches!(
                child.kind(),
                "exceptions" | "exception_variable" | "comment"
            )
        });
        let normalized_handler = handler.and_then(|handler| self.normalize_body(handler));
        let body = self.prepend_rescue_exception_assignment(normalized_handler, exception_variable);
        Some(self.wrap(
            "RESBODY",
            vec![
                list_or_nil(exception_nodes, exceptions.unwrap_or(node), self),
                optional_node(body),
                Child::Nil,
            ],
            node,
        ))
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
        let variable = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exception_variable")?;
        let name = self
            .named_children(variable)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))?;
        let errinfo = self.wrap("ERRINFO", Vec::new(), variable);
        Some(self.wrap(
            "LASGN",
            vec![
                Child::String(node_text(name, self.source).to_string()),
                Child::Node(Box::new(errinfo)),
            ],
            variable,
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
            children.extend(body.children);
            body.children = children;
            Some(body)
        } else {
            let first_lineno = assignment.first_lineno;
            let first_column = assignment.first_column;
            let last_lineno = body.last_lineno;
            let last_column = body.last_column;
            let text = if assignment.text.is_empty() {
                body.text.clone()
            } else if body.text.is_empty() {
                assignment.text.clone()
            } else {
                format!("{} {}", assignment.text, body.text)
            };
            Some(Node {
                r#type: "BLOCK".to_string(),
                children: vec![
                    Child::Node(Box::new(assignment)),
                    Child::Node(Box::new(body)),
                ],
                first_lineno,
                first_column,
                last_lineno,
                last_column,
                text,
            })
        }
    }

    fn normalize_modifier_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let action = *named.first()?;
        let condition = *named.last()?;
        let condition = optional_node(self.normalize_node(condition));
        let action = optional_node(self.normalize_node(action));
        Some(self.wrap("IF", vec![condition, action, Child::Nil], node))
    }

    fn normalize_modifier_action(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_node(node)
    }

    fn normalize_command_call_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let function = self.named_children(node).into_iter().next()?;
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
            .named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "argument_list" | "arguments"));
        let args = args_node
            .map(|args| self.command_arguments(args))
            .unwrap_or_default();
        let block = self.call_block(node);
        let call_source = block.map(|block| self.source_before_child(node, block));
        if node_text(function, self.source) == "yield" {
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
        let method = args.and_then(|args| self.inline_def_from_source(args));
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
        if matches!(
            node.kind(),
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
        ) {
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
        if let Some(number) = text
            .strip_prefix('$')
            .and_then(|value| value.parse::<i64>().ok())
        {
            return self.wrap("NTH_REF", vec![Child::String(number.to_string())], node);
        }
        self.wrap("GVAR", vec![Child::String(text)], node)
    }

    fn normalize_array_literal(&mut self, node: TreeSitterNode<'_>) -> Node {
        let values = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect::<Vec<_>>();
        if values.is_empty() {
            self.wrap("ZLIST", Vec::new(), node)
        } else {
            self.list(values, node)
        }
    }

    fn normalize_pair(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let key = *named.first()?;
        let value = named.get(1).and_then(|value| self.normalize_node(*value));
        let key_text = node_text(key, self.source)
            .trim_end_matches(':')
            .trim_start_matches(':')
            .to_string();
        let key_lit = self.wrap("LIT", vec![Child::Symbol(key_text)], key);
        Some(self.wrap(
            "HASH",
            vec![Child::Node(Box::new(key_lit)), optional_node(value)],
            node,
        ))
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
        let mut parts = Vec::new();
        let mut dynamic_source = None;
        let mut first_child = None;
        for child in self.named_children(node) {
            first_child.get_or_insert(child);
            let Some(normalized) = self.normalize_node(child) else {
                continue;
            };
            if normalized.r#type == "DSTR" {
                if dynamic_source.is_none()
                    && normalized
                        .children
                        .iter()
                        .filter_map(self::node)
                        .any(|part| part.r#type == "EVSTR")
                {
                    dynamic_source = Some(child);
                }
                parts.extend(normalized.children);
            } else {
                parts.push(Child::Node(Box::new(normalized)));
            }
        }
        self.wrap(
            "DSTR",
            parts,
            dynamic_source.or(first_child).unwrap_or(node),
        )
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
            Some(self.list(exprs, node))
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

    fn normalize_heredoc_beginning(&mut self, node: TreeSitterNode<'_>) -> Node {
        let heredoc_body =
            node.parent()
                .and_then(|parent| parent.parent())
                .and_then(|body_statement| {
                    self.named_children(body_statement)
                        .into_iter()
                        .find(|child| child.kind() == "heredoc_body")
                });
        let children = heredoc_body
            .map(|body| self.normalize_heredoc_children(body))
            .unwrap_or_default();
        self.wrap("DSTR", children, node)
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
        self.collect_destructured_parameter_targets(param, &mut targets);
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
        } else if let Some(root_span) = self.root_span {
            self.wrap_from_span_text("SCOPE", children, root_span, self.source)
        } else {
            self.wrap("SCOPE", children, source)
        }
    }

    fn list(&self, children: Vec<Node>, source: TreeSitterNode<'_>) -> Node {
        self.wrap(
            "LIST",
            children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            source,
        )
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
        if self.language != Language::Ruby {
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
        if matches!(
            node.kind(),
            "method_parameters"
                | "parameters"
                | "parameter_list"
                | "formal_parameters"
                | "function_value_parameters"
                | "parameter"
                | "block_parameters"
                | "lambda_parameters"
        ) {
            if node.kind() == "parameter" {
                self.collect_parameter_names(node, locals);
            } else {
                for child in self.named_children(node) {
                    if child.kind() == "parameter" {
                        self.collect_parameter_names(child, locals);
                    } else {
                        self.collect_identifier_names(child, locals);
                    }
                }
            }
        }
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            if let Some(left) = self.assignment_left(node) {
                self.collect_assignment_target_names(left, locals);
            }
        }
        for target in self.declaration_entries(node) {
            if let Some(name) = self.declaration_name(target) {
                self.collect_assignment_target_names(name, locals);
            }
        }
        for child in self.named_children(node) {
            if !self.ruby_scope_boundary(child) {
                self.collect_ruby_scope_locals(child, locals, false);
            }
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
                | "pattern"
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
        for child in self.named_children(node) {
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
        if node.kind() == "block"
            && node
                .parent()
                .map(|parent| function_kind(parent.kind()))
                .unwrap_or(false)
        {
            return false;
        }
        if node.kind() == "block"
            && node
                .parent()
                .and_then(|parent| parent.parent())
                .map(|grandparent| function_kind(grandparent.kind()))
                .unwrap_or(false)
        {
            return false;
        }
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
            "method"
                | "function_definition"
                | "function_declaration"
                | "method_definition"
                | "method_declaration"
                | "function_item"
                | "singleton_method"
                | "class"
                | "module"
                | "singleton_class"
                | "lambda"
                | "block"
                | "do_block"
        )
    }

    fn ruby_vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        self.language == Language::Ruby
            && !self.assignment_lhs(node)
            && !self.ruby_definition_identifier(node)
            && !self
                .local_stack
                .iter()
                .rev()
                .any(|scope| scope.contains(name))
    }

    fn vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        if self.language == Language::Ruby
            && self
                .local_stack
                .iter()
                .rev()
                .any(|scope| scope.contains(name))
        {
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
        if self.assignment_lhs(node) || self.assignment_rhs(node) {
            return false;
        }

        if matches!(parent.kind(), "body_statement" | "block_body" | "then")
            && self
                .named_children(parent)
                .into_iter()
                .any(|child| child == node)
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
        let Some(parent) = node.parent() else {
            return false;
        };
        if matches!(parent.kind(), "method" | "singleton_method") {
            return self
                .named_field(parent, "name")
                .map(|name| name == node)
                .unwrap_or(false);
        }
        matches!(
            parent.kind(),
            "method_parameters"
                | "parameters"
                | "parameter_list"
                | "formal_parameters"
                | "function_value_parameters"
                | "block_parameters"
                | "lambda_parameters"
                | "parameter"
                | "optional_parameter"
                | "keyword_parameter"
                | "block_parameter"
        )
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
            .map(|sibling| assignment_operator(node_text(sibling, self.source)))
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

        matches!(
            node.kind(),
            "string_content" | "escape_sequence" | "interpolation"
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

    fn assignment_rhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.lua_single_assignment_block_child(node) {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        node.prev_sibling()
            .map(|sibling| assignment_operator(node_text(sibling, self.source)))
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

    fn has_assignment_operator_child(&self, node: TreeSitterNode<'_>) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && assignment_operator(node_text(child, self.source)))
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
            && named.len() == 2
    }

    fn leading_if_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let first_child = node.children(&mut node.walk()).next();
        let single_named_if_block = matches!(self.language, Language::Python | Language::Lua)
            && node.kind() == "block"
            && self.raw_named_children(node).len() == 1
            && first_child
                .map(|child| child.kind() == "if_statement")
                .unwrap_or(false);
        if single_named_if_block {
            return true;
        }
        matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) && (first_child
            .map(|child| matches!(child.kind(), "if" | "unless"))
            .unwrap_or(false))
            && self.named_children(node).len() >= 2
            && self
                .named_children(node)
                .first()
                .map(|child| !if_kind(child.kind()))
                .unwrap_or(false)
    }

    fn normalize_leading_if_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self.language == Language::Python && node.kind() == "block" {
            if let Some(if_node) = self
                .raw_named_children(node)
                .into_iter()
                .find(|child| child.kind() == "if_statement")
            {
                let condition = self
                    .named_field(if_node, "condition")
                    .or_else(|| self.named_field(if_node, "predicate"))
                    .or_else(|| self.first_named(if_node))?;
                let consequence = self
                    .named_field(if_node, "consequence")
                    .or_else(|| self.named_field(if_node, "body"))
                    .or_else(|| self.branch_child(if_node, condition, 0));
                let condition = optional_node(self.normalize_node(condition));
                let consequence =
                    optional_node(consequence.and_then(|child| self.normalize_body(child)));
                return Some(self.wrap("IF", vec![condition, consequence, Child::Nil], if_node));
            }
        }
        if self.language == Language::Lua && node.kind() == "block" {
            if let Some(if_node) = self
                .raw_named_children(node)
                .into_iter()
                .find(|child| child.kind() == "if_statement")
            {
                return self.normalize_if(if_node);
            }
        }
        let keyword = node
            .children(&mut node.walk())
            .next()
            .map(|child| child.kind().to_string())?;
        let condition = self
            .named_children(node)
            .into_iter()
            .find(|child| !matches!(child.kind(), "comment" | "then" | "elsif" | "else"))?;
        let consequence = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "then")
            .or_else(|| self.branch_child(node, condition, 0));
        let alternative = self.explicit_alternative(node);
        let node_type = if keyword == "unless" { "UNLESS" } else { "IF" };
        let condition = optional_node(self.normalize_node(condition));
        let consequence = optional_node(consequence.and_then(|child| self.normalize_body(child)));
        let alternative =
            optional_node(alternative.and_then(|child| self.normalize_else_or_branch(child)));
        Some(self.wrap(node_type, vec![condition, consequence, alternative], node))
    }

    fn command_call_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) && !self.dotted_call(node)
            && self
                .named_children(node)
                .into_iter()
                .next()
                .map(|child| self.identifier_kind(child.kind()))
                .unwrap_or(false)
            && (self
                .named_children(node)
                .into_iter()
                .any(|child| matches!(child.kind(), "argument_list" | "arguments"))
                || self.call_block(node).is_some())
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
        inline_def_wrapper_mid(node_text(function, self.source))
            && node_text(node, self.source).contains("def ")
    }

    fn inline_def_from_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let source = self
            .named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list")
            .unwrap_or(node);
        self.inline_def_from_source(source)
    }

    fn inline_def_from_source(&mut self, source: TreeSitterNode<'_>) -> Option<Node> {
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
        if !text.contains("def ") || !text.split_whitespace().nth(1).unwrap_or("").contains('.') {
            return None;
        }
        self.named_children(source).into_iter().find(|child| {
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
        let index = children.iter().position(|child| *child == receiver)?;
        children
            .into_iter()
            .skip(index + 1)
            .find(|child| self.identifier_kind(child.kind()))
            .map(|child| node_text(child, self.source).to_string())
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
        None
    }

    fn ternary_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list" | "conditional"
        ) && self.named_children(node).len() >= 3
            && node
                .children(&mut node.walk())
                .any(|child| !child.is_named() && node_text(child, self.source) == "?")
            && node
                .children(&mut node.walk())
                .any(|child| !child.is_named() && node_text(child, self.source) == ":")
    }

    fn boolean_expression(&self, node: TreeSitterNode<'_>) -> bool {
        (matches!(
            node.kind(),
            "binary" | "binary_expression" | "boolean_operator"
        ) || self.boolean_statement(node))
            && matches!(self.boolean_operator(node).as_deref(), Some("and" | "or"))
    }

    fn boolean_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return false;
        }
        if !matches!(
            self.binary_operator(node).as_deref(),
            Some("&&" | "||" | "and" | "or")
        ) {
            return false;
        }
        if self.named_children(node).len() < 2 {
            return false;
        }
        node.children(&mut node.walk()).all(|child| {
            child.is_named()
                || matches!(
                    node_text(child, self.source),
                    "&&" | "||" | "and" | "or" | "(" | ")"
                )
        })
    }

    fn operator_call_expression(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "binary" | "binary_expression")
            && self.named_children(node).len() >= 2
            && self
                .binary_operator(node)
                .map(|operator| OPERATOR_CALL_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn comparison_expression(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "binary" | "binary_expression" | "comparison_operator"
        ) && self.named_children(node).len() >= 2
            && self
                .comparison_operator(node)
                .map(|operator| COMPARISON_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn infix_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.infix_statement_parts(node).is_some()
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
        matches!(node.kind(), "unary" | "unary_expression")
            && node_text(node, self.source).trim_start().starts_with('!')
    }

    fn unary_minus_expression(&self, node: TreeSitterNode<'_>) -> bool {
        if matches!(node.kind(), "unary" | "unary_expression" | "unary_operator")
            && node_text(node, self.source).trim_start().starts_with('-')
        {
            return true;
        }

        if node.kind() != "expression_list" {
            return false;
        }
        let named = self.named_children(node);
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| node_text(child, self.source) == "-")
            .unwrap_or(false)
            && named.len() == 1
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
        self.binary_operator(node)
            .or_else(|| comparison_operator_from_text(node_text(node, self.source)))
    }

    fn binary_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if let Some(operator) = node
            .children(&mut node.walk())
            .find(|child| !child.is_named() && !matches!(node_text(*child, self.source), "(" | ")"))
            .map(|child| node_text(child, self.source).to_string())
        {
            return Some(operator);
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && matches!(
                raw_named[0].kind(),
                "binary"
                    | "binary_expression"
                    | "binary_operator"
                    | "boolean_operator"
                    | "comparison_operator"
            )
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            return self.binary_operator(raw_named[0]);
        }

        None
    }

    fn interpolated_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) && self
            .named_children(node)
            .into_iter()
            .any(|child| child.kind() == "interpolation")
    }

    fn interpolated_string(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "string"
            && self
                .named_children(node)
                .into_iter()
                .any(|child| child.kind() == "interpolation")
    }

    fn statement_call_with_block(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.call_block(node).is_some()
            && (self.dotted_call(node)
                || self
                    .named_children(node)
                    .into_iter()
                    .any(|child| self.call_kind(child.kind()) || self.member_read_node(child)))
    }

    fn yield_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "expression_statement" | "statement"
        ) {
            return false;
        }
        let Some(first) = node.children(&mut node.walk()).next() else {
            return false;
        };
        if node_text(first, self.source) == "yield" {
            return true;
        }

        if matches!(
            node.kind(),
            "body_statement" | "block_body" | "expression_statement" | "statement"
        ) && first.kind() == "yield"
        {
            let Some(keyword) = first.children(&mut first.walk()).next() else {
                return false;
            };
            return node_text(keyword, self.source) == "yield";
        }

        false
    }

    fn super_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "call" | "statement"
        ) {
            return false;
        }
        if node_text(node, self.source).trim() == "super" {
            return true;
        }
        let raw = self.raw_named_children(node);
        let named = if raw.len() == 1 && raw[0].kind() == "call" {
            self.raw_named_children(raw[0])
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
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) && self.dotted_call(node)
    }

    fn dotted_call(&self, node: TreeSitterNode<'_>) -> bool {
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
        callable.len() >= 2
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, self.source) == "&.")
    }

    fn dotted_call_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        block: Option<TreeSitterNode<'tree>>,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
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
            "attribute"
                | "member_expression"
                | "member_access_expression"
                | "field"
                | "field_access"
                | "selector_expression"
                | "field_expression"
                | "navigation_expression"
                | "directly_assignable_expression"
                | "expression_list"
        )
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
        let receiver = self
            .named_field(node, "receiver")
            .or_else(|| self.named_field(node, "object"))
            .or_else(|| self.named_field(node, "operand"))
            .or_else(|| self.named_field(node, "value"))
            .or_else(|| self.named_field(node, "expression"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| child.kind() != "navigation_suffix")
            })?;
        let method = self
            .named_field(node, "method")
            .or_else(|| self.named_field(node, "field"))
            .or_else(|| self.named_field(node, "property"))
            .or_else(|| self.named_field(node, "suffix"))
            .or_else(|| self.named_children(node).into_iter().last())?;
        (receiver != method).then(|| {
            (
                receiver,
                node_text(method, self.source)
                    .trim_start_matches(['.', '?'])
                    .trim_end_matches('=')
                    .to_string(),
            )
        })
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
        self.named_children(args)
            .into_iter()
            .filter(|child| Some(*child) != function)
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    fn command_arguments(&mut self, args: TreeSitterNode<'_>) -> Vec<Node> {
        let children = self.named_children(args);
        if children.is_empty() {
            return self.scalar_argument_list_value(args).into_iter().collect();
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

    fn scalar_argument_list_value(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let text = node_text(node, self.source).trim();
        if text == "yield" {
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
        if bare_identifier_text(text) {
            if !self
                .local_stack
                .iter()
                .rev()
                .any(|scope| scope.contains(text))
            {
                Some(self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node))
            } else {
                Some(self.wrap("LVAR", vec![Child::String(text.to_string())], node))
            }
        } else {
            None
        }
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
        let raw = node
            .children(&mut cursor)
            .find(|child| !child.is_named() && node_text(*child, self.source).ends_with('='))
            .map(|child| node_text(child, self.source))
            .unwrap_or("");
        match raw {
            "||=" => "||".to_string(),
            "&&=" => "&&".to_string(),
            _ => raw.trim_end_matches('=').to_string(),
        }
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
        if left.kind() == "instance_variable" || node_text(left, self.source).starts_with('@') {
            return Some(self.wrap(
                "IASGN",
                vec![
                    Child::String(node_text(left, self.source).to_string()),
                    optional_node(right),
                ],
                source,
            ));
        }
        if left.kind() == "global_variable" || node_text(left, self.source).starts_with('$') {
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
        if self.member_read_node(left) {
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
                    node,
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

    fn block_child<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().find(|child| {
            matches!(
                child.kind(),
                "body_statement"
                    | "block_body"
                    | "block"
                    | "class_body"
                    | "function_body"
                    | "statements"
                    | "control_structure_body"
            )
        })
    }

    fn call_block<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
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
                "assignment_statement"
                    | "function_call"
                    | "return_statement"
                    | "variable_declaration"
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
            .filter(|child| *child != condition)
            .nth(offset)
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().find(|child| {
            matches!(
                child.kind(),
                "elif_clause"
                    | "else"
                    | "else_clause"
                    | "else_statement"
                    | "elsif"
                    | "elseif_statement"
            )
        })
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
            if self.when_kind(child.kind()) {
                arms.push(child);
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
        matches!(
            kind,
            "identifier"
                | "simple_identifier"
                | "property_identifier"
                | "field_identifier"
                | "shorthand_property_identifier"
        )
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
        matches!(
            node.kind(),
            "parenthesized_expression"
                | "parenthesized_statements"
                | "expression_statement"
                | "statement"
                | "case_pattern"
                | "match_pattern"
                | "pattern"
        ) && self.named_children(node).len() == 1
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
            return node.children.into_iter().find_map(child_node);
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
        Child::Node(Box::new(normalizer.list(children, source)))
    }
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

fn assignment_operator(text: &str) -> bool {
    matches!(text, "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=")
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
    match kind {
        "body_statement" | "block_body" | "block" | "statements" => "BLOCK".to_string(),
        other => other
            .chars()
            .map(|ch| {
                if ch.is_ascii_alphanumeric() {
                    ch.to_ascii_uppercase()
                } else {
                    '_'
                }
            })
            .collect(),
    }
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

fn inline_def_wrapper_mid(text: &str) -> bool {
    matches!(
        text,
        "public" | "protected" | "private" | "private_class_method" | "module_function"
    )
}

fn bare_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    chars.all(|ch| ch == '_' || ch == '!' || ch == '?' || ch == '=' || ch.is_ascii_alphanumeric())
}

fn instance_variable_node(node: TreeSitterNode<'_>, source: &str) -> bool {
    let text = node_text(node, source);
    node.kind() == "instance_variable"
        || text
            .strip_prefix('@')
            .map(bare_identifier_text)
            .unwrap_or(false)
}

fn global_variable_node(node: TreeSitterNode<'_>, source: &str) -> bool {
    node.kind() == "global_variable"
        || (!matches!(node.kind(), "string_content" | "escape_sequence")
            && node_text(node, source).starts_with('$'))
}

fn comparison_operator_from_text(text: &str) -> Option<String> {
    for operator in ["===", "!==", "==", "!=", "<=", ">=", "<", ">"] {
        if text.contains(operator) {
            return Some(operator.to_string());
        }
    }
    None
}

pub fn child_to_string(child: Option<&Child>) -> Option<String> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{parse, parse_with_language, Child, Node};
    use crate::decomplex::syntax::Language;
    use serde_json::{json, Value};
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
            Child::Nil => Value::Null,
        }
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
          abort "target node not found" unless target
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
          abort "target node not found" unless target
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
            .trim()
            .to_string()
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
        let root = parse_language_source(
            r#"def __rich__():
    ...
"#,
            Language::Python,
            ".py",
        );
        let defn = first_node(&root, "DEFN", "def __rich__():\n    ...");
        let scope = child_node(defn, 1);

        assert_eq!(scope.r#type, "SCOPE");
        assert!(matches!(scope.children.get(2), Some(Child::Nil)));
        assert_eq!(
            scope.first_lineno, root.first_lineno,
            "Ruby scope(body=nil,args=nil) falls back to document root source"
        );
        assert_eq!(scope.text, root.text);
    }

    #[test]
    fn python_explicit_return_none_is_not_elided_from_function_body() {
        let root = parse_language_source(
            r#"
class Thing:
    def _repr_latex_(self):
        return None
"#,
            Language::Python,
            ".py",
        );
        let iter = first_node(
            &root,
            "ITER",
            "def _repr_latex_(self):\n        return None",
        );
        let scope = child_node(iter, 1);

        assert_eq!(
            child_node(scope, 2).r#type,
            "NIL",
            "Ruby only elides implicit nil bodies for Ruby, not explicit Python return None: {scope:#?}"
        );
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
        let root = parse_language_source(
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
        let block = first_node(&root, "BLOCK", "foobarbaz");

        assert!(
            block.children.is_empty(),
            "Ruby exposes a bare identifier-only block as an empty block: {block:#?}"
        );
    }

    #[test]
    fn python_bare_dotted_expression_statement_keeps_statement_wrapper() {
        let root = parse_language_source("os.get_terminal_size\n", Language::Python, ".py");
        let expression = first_node(&root, "EXPRESSION_STATEMENT", "os.get_terminal_size");

        assert_eq!(
            child_types(expression),
            vec!["LVAR", "LVAR"],
            "Ruby exposes bare dotted expression statements as expression_statement identifier children: {expression:#?}"
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
        let root = parse_language_source(
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
        let if_node = first_node(&root, "IF", "if clear:\n        del self._record_buffer[:]");
        assert_eq!(
            child_node(if_node, 1).r#type,
            "SUBSCRIPT",
            "Ruby unwraps a single delete body to the deleted subscript: {if_node:#?}"
        );

        let delete = first_node(&root, "DELETE_STATEMENT", "del self._record_buffer[:]");
        assert_eq!(
            child_types(delete),
            vec!["SUBSCRIPT"],
            "Ruby keeps delete_statement wrapper in multi-statement bodies: {delete:#?}"
        );
    }

    #[test]
    fn python_single_subscript_expression_block_exposes_subscript_children() {
        let root = parse_language_source(
            r#"
def test_render():
    with pytest.raises(KeyError):
        top["asdasd"]
"#,
            Language::Python,
            ".py",
        );
        let block = first_node(&root, "BLOCK", r#"top["asdasd"]"#);

        assert_eq!(
            child_types(block),
            vec!["LVAR", "STR"],
            "Ruby exposes a single subscript expression block as subscript children: {block:#?}"
        );
    }

    #[test]
    fn python_single_if_block_under_try_exposes_ruby_if_children() {
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
        let block = first_node(
            &root,
            "BLOCK",
            "if args.path == \"-\":\n            json_data = sys.stdin.read()\n        else:\n            json_data = Path(args.path).read_text()",
        );

        assert_eq!(
            child_types(block),
            vec!["OPCALL", "BLOCK", "ELSE_CLAUSE"],
            "Ruby block lacks an if_statement wrapper in this parser shape: {block:#?}"
        );
    }

    #[test]
    fn python_single_decorated_definition_block_exposes_decorator_and_function() {
        let root = parse_language_source(
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
        let block = first_node(
            &root,
            "BLOCK",
            "@property\n        def __class__(self):\n            raise AttributeError",
        );

        assert_eq!(
            child_types(block),
            vec!["IVAR", "DEFN"],
            "Ruby exposes decorated definitions as direct block children: {block:#?}"
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
        let root = parse_language_source(
            "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
            Language::Lua,
            ".lua",
        );
        let field = first_node(&root, "FIELD", "P\"bin/binfile\"");

        assert_eq!(
            child_types(field),
            vec!["LVAR", "ARGUMENTS"],
            "Ruby exposes a Lua table field call as the call children, without FUNCTION_CALL wrapper: {field:#?}"
        );
    }

    #[test]
    fn lua_table_identifier_entry_matches_ruby_empty_field_shape() {
        let root = parse_language_source(
            "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
            Language::Lua,
            ".lua",
        );
        let field = first_node(&root, "FIELD", "rocks_tree");

        assert!(
            field.children.is_empty(),
            "Ruby exposes a bare identifier Lua table field with no normalized children: {field:#?}"
        );
    }

    #[test]
    fn lua_single_call_function_body_matches_ruby_block_shape() {
        let root = parse_language_source(
            "before_each(function()\n   test_env.setup_specs(extra_rocks)\nend)\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(
            &root,
            "DEFN",
            "function()\n   test_env.setup_specs(extra_rocks)\nend",
        );
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(
            child_types(body),
            vec!["DOT_INDEX_EXPRESSION", "ARGUMENTS"],
            "Ruby exposes a single Lua function-call body as a BLOCK of the call target and arguments: {body:#?}"
        );
    }

    #[test]
    fn lua_single_assignment_function_body_matches_ruby_block_shape() {
        let root = parse_language_source(
            "lazy_setup(function()\n   git = git_repo.start()\nend)\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(&root, "DEFN", "function()\n   git = git_repo.start()\nend");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(
            child_types(body),
            vec!["VARIABLE_LIST", "EXPRESSION_LIST"],
            "Ruby exposes a single Lua assignment body as a BLOCK of assignment children, without LASGN: {body:#?}"
        );
    }

    #[test]
    fn lua_single_bare_assignment_function_body_matches_ruby_empty_lists() {
        let root = parse_language_source("function()\n   x = y\nend\n", Language::Lua, ".lua");
        let defn = first_node(&root, "DEFN", "function()\n   x = y\nend");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);
        let variable_list = child_node(body, 0);
        let expression_list = child_node(body, 1);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(variable_list.r#type, "VARIABLE_LIST");
        assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
        assert!(
            variable_list.children.is_empty(),
            "Ruby exposes a bare Lua single-assignment variable_list with no children: {variable_list:#?}"
        );
        assert!(
            expression_list.children.is_empty(),
            "Ruby exposes a bare identifier Lua single-assignment RHS with no children: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_single_dotted_assignment_function_body_keeps_ruby_variable_list_children() {
        let root = parse_language_source(
            "function()\n   package.path = oldpath\nend\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(&root, "DEFN", "function()\n   package.path = oldpath\nend");
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);
        let variable_list = child_node(body, 0);
        let expression_list = child_node(body, 1);

        assert_eq!(body.r#type, "BLOCK");
        assert_eq!(variable_list.r#type, "VARIABLE_LIST");
        assert_eq!(
            child_types(variable_list),
            vec!["LVAR", "LVAR"],
            "Ruby keeps Lua dotted assignment targets as variable_list children: {variable_list:#?}"
        );
        assert!(
            expression_list.children.is_empty(),
            "Ruby exposes a bare identifier Lua dotted-assignment RHS with no children: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_single_local_assignment_function_body_matches_ruby_lasgn_shape() {
        let root = parse_language_source(
            "it(function()\n   local output = run.luarocks(\"show --rock-tree luacov\")\nend)\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(
            &root,
            "DEFN",
            "function()\n   local output = run.luarocks(\"show --rock-tree luacov\")\nend",
        );
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "LASGN");
        assert_eq!(
            body.children.first(),
            Some(&Child::String("output".to_string())),
            "Ruby exposes a single Lua local assignment function body as the inner LASGN: {body:#?}"
        );
    }

    #[test]
    fn lua_assigned_function_expression_matches_ruby_expression_list_shape() {
        let root = parse_language_source(
            "local test_with_location = function(location)\n   lfs.mkdir(location)\nend\n",
            Language::Lua,
            ".lua",
        );
        let assignment = first_node(
            &root,
            "LASGN",
            "test_with_location = function(location)\n   lfs.mkdir(location)\nend",
        );
        let expression_list = child_node(assignment, 1);

        assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
        assert_eq!(
            child_types(expression_list),
            vec!["PARAMETERS", "BLOCK"],
            "Ruby exposes a Lua assigned function expression as PARAMETERS and BLOCK inside the RHS expression_list: {expression_list:#?}"
        );
    }

    #[test]
    fn lua_assigned_function_if_else_matches_fixed_ruby_if_shape() {
        let root = parse_language_source(
            "local make_unreadable = function(path)\n  if is_win then\n    fs.execute(\"x\")\n  else\n    fs.execute(\"y\")\n  end\nend\n",
            Language::Lua,
            ".lua",
        );
        let expression_list = first_node(
            &root,
            "EXPRESSION_LIST",
            "function(path)\n  if is_win then\n    fs.execute(\"x\")\n  else\n    fs.execute(\"y\")\n  end\nend",
        );
        let if_node = child_node(expression_list, 1);
        let mut iters = Vec::new();
        nodes_of_type(&root, "ITER", &mut iters);

        assert_eq!(if_node.r#type, "IF");
        assert_eq!(child_node(if_node, 2).r#type, "ELSE_STATEMENT");
        assert!(
            iters.is_empty(),
            "Ruby no longer misclassifies a Lua if/else in an assigned function expression as ITER: {iters:#?}"
        );
    }

    #[test]
    fn lua_single_return_function_body_matches_ruby_expression_list_shape() {
        let root = parse_language_source(
            "function sum.sum(a, b)\n   return a + b\nend\n",
            Language::Lua,
            ".lua",
        );
        let defn = first_node(
            &root,
            "DEFN",
            "function sum.sum(a, b)\n   return a + b\nend",
        );
        let scope = child_node(defn, 1);
        let body = child_node(scope, 2);

        assert_eq!(body.r#type, "EXPRESSION_LIST");
        assert_eq!(
            child_types(body),
            vec!["LVAR", "LVAR"],
            "Ruby exposes a single Lua return body as the returned expression_list, without RETURN: {body:#?}"
        );
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
        let root = parse_language_source(
            "local c_module_source = [[\n   #include <lua.h>\n]]\n",
            Language::Lua,
            ".lua",
        );
        let expression_list = first_node(&root, "EXPRESSION_LIST", "[[\n   #include <lua.h>\n]]");
        let string = child_node(expression_list, 0);

        assert_eq!(child_types(expression_list), vec!["STR"]);
        assert_eq!(
            string.children,
            vec![Child::String("\n   #include <lua.h>\n".to_string())],
            "Ruby normalizes a Lua long string assignment from string_content, without bracket delimiters: {string:#?}"
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
