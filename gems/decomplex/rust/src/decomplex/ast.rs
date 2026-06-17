use serde::Serialize;
use anyhow::{Context, Result};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use tree_sitter::{Node as TreeSitterNode, Parser};

pub type Span = [usize; 4];
const COMPARISON_OPERATORS: &[&str] = &["==", "!=", "===", "!==", "<", "<=", ">", ">="];
const OPERATOR_CALL_OPERATORS: &[&str] = &["+", "-", "*", "/", "%", "**", "|", "&", "^", "<<", ">>", "=~", "!~"];

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

        if node.kind() == "pattern"
            && children.len() == 1
            && children[0].kind == "scope_resolution"
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
        if node.kind() == "body_statement" && children.len() == 1 && children[0].kind == "conditional" {
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
            && matches!(children[0].kind.as_str(), "array" | "binary" | "string" | "unary")
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
    let source = fs::read_to_string(file)
        .with_context(|| format!("failed to read {}", file.display()))?;
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_ruby::LANGUAGE.into())
        .with_context(|| "failed to initialize tree-sitter ruby parser")?;
    let tree = parser
        .parse(&source, None)
        .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
    let root = TreeSitterNormalizer::new(&source).normalize(tree.root_node());
    let lines = source.lines().map(ToString::to_string).collect();
    Ok((root, lines))
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
    local_stack: Vec<BTreeSet<String>>,
}

impl<'source> TreeSitterNormalizer<'source> {
    fn new(source: &'source str) -> Self {
        Self {
            source,
            local_stack: Vec::new(),
        }
    }

    fn normalize(mut self, root: TreeSitterNode<'_>) -> Node {
        let children = self.with_ruby_scope(root, true, |normalizer| {
            normalizer.normalize_children(root)
        });
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
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
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

        match node.kind() {
            "program" => {
                let children = self.normalize_children(node);
                Some(self.wrap("ROOT", children, node))
            }
            "method" => self.normalize_function(node),
            "singleton_method" => self.normalize_singleton_function(node),
            "class" | "class_definition" | "class_declaration" | "class_specifier" => {
                self.normalize_class(node)
            }
            "module" => self.normalize_module(node),
            "lambda" => self.normalize_lambda(node),
            "body_statement" | "block_body" | "block" => self.normalize_body(node),
            "ensure" => self.normalize_ensure_clause(node),
            "begin" => self.normalize_begin(node),
            "assignment" | "assignment_expression" | "assignment_statement" => {
                self.normalize_assignment(node)
            }
            "call" | "call_expression" | "method_call" | "method_call_expression" => {
                self.normalize_call(node)
            }
            "element_reference" => self.normalize_element_reference(node),
            "rescue_modifier" => self.normalize_rescue_modifier(node),
            "super" => Some(self.normalize_super(node)),
            "return" | "return_statement" | "return_expression" | "break" | "break_statement"
            | "break_expression" | "next" | "continue_statement" => self.normalize_return(node),
            "nil" => Some(self.wrap("NIL", Vec::new(), node)),
            "true" => Some(self.wrap("TRUE", Vec::new(), node)),
            "false" => Some(self.wrap("FALSE", Vec::new(), node)),
            "instance_variable" => Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            )),
            "identifier" | "simple_identifier" | "property_identifier" | "field_identifier" => {
                Some(self.normalize_identifier(node))
            }
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier" => {
                Some(self.normalize_const(node))
            }
            "self" | "this" => Some(self.wrap("SELF", Vec::new(), node)),
            "global_variable" => Some(self.normalize_global_variable(node)),
            "array" => Some(self.normalize_array_literal(node)),
            "interpolation" => self.normalize_interpolation(node),
            "heredoc_beginning" => Some(self.normalize_heredoc_beginning(node)),
            "string" | "string_content" | "string_literal" | "interpreted_string_literal"
            | "raw_string_literal" => {
                if self.interpolated_string(node) {
                    Some(self.normalize_interpolated_string(node))
                } else {
                    Some(self.wrap(
                        "STR",
                        vec![Child::String(node_text(node, self.source).to_string())],
                        node,
                    ))
                }
            }
            "integer" => Some(self.wrap(
                "INTEGER",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            )),
            "float" | "float_literal" => Some(self.wrap(
                "FLOAT",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            )),
            "pair" | "keyword_argument" => self.normalize_pair(node),
            "simple_symbol" | "symbol" => Some(self.wrap(
                "LIT",
                vec![Child::Symbol(
                    node_text(node, self.source).trim_start_matches(':').to_string(),
                )],
                node,
            )),
            _ => {
                let children = self.normalize_children(node);
                if children.is_empty() {
                    None
                } else {
                    Some(self.wrap(kind_type(node.kind()), children, node))
                }
            }
        }
    }

    fn normalize_function(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.function_name(node)?;
        let args = self.normalize_parameters(self.named_field(node, "parameters"));
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
        let args = self.normalize_parameters(self.named_field(node, "parameters"));
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

    fn normalize_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
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
            .or_else(|| self.named_children(node).into_iter().find(|child| child.kind() == "then"))
            .or_else(|| self.branch_child(node, condition_raw, 0));
        let negative_raw = self
            .named_field(node, "alternative")
            .or_else(|| self.explicit_alternative(node));
        let positive = optional_node(positive_raw.and_then(|child| self.normalize_body(child)));
        let negative = optional_node(negative_raw.and_then(|child| self.normalize_else_or_branch(child)));
        let node_type = if node.kind().starts_with("unless") {
            "UNLESS"
        } else {
            "IF"
        };
        Some(self.wrap(node_type, vec![condition, positive, negative], node))
    }

    fn normalize_else_or_branch(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
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
        self.wrap("SUPER", vec![list_or_nil(args, args_node.unwrap_or(node), self)], node)
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
        let right_raw = operands.get(1).copied().unwrap_or(node);
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
        let right_raw = operands.get(1).copied().unwrap_or(node);
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
        let right = self.assignment_right(node).and_then(|right| self.normalize_node(right));
        if let Some(target) = self.assignment_target(left, right.clone(), node) {
            return Some(target);
        }
        Some(self.wrap(
            "LASGN",
            vec![Child::String(self.target_name(left)), optional_node(right)],
            node,
        ))
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
            self.named_children(node)
                .into_iter()
                .find(|child| {
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
            return Some(self.wrap(
                node_type,
                vec![receiver, Child::Symbol(method), args],
                node,
            ));
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
        if self.member_read_node(function) {
            let (receiver, method) = self.member_parts(function)?;
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(args, node, self);
            return Some(self.wrap(
                "CALL",
                vec![receiver, Child::Symbol(method), args],
                node,
            ));
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
                vec![Child::Symbol("[]".to_string()), list_or_nil(args, node, self)],
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
        let handler = named.get(1).and_then(|handler| self.normalize_node(*handler));
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
            let body = self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
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
        let body = self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
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
            !matches!(child.kind(), "exceptions" | "exception_variable" | "comment")
        });
        let normalized_handler = handler.and_then(|handler| self.normalize_body(handler));
        let body = self.prepend_rescue_exception_assignment(normalized_handler, exception_variable);
        Some(self.wrap(
            "RESBODY",
            vec![list_or_nil(exception_nodes, exceptions.unwrap_or(node), self), optional_node(body), Child::Nil],
            node,
        ))
    }

    fn link_rescue_chain(&self, mut resbodies: Vec<Node>) -> Option<Node> {
        let mut next = None;
        while let Some(mut current) = resbodies.pop() {
            if current.children.len() > 2 {
                current.children[2] = optional_node(next);
            }
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
                children: vec![Child::Node(Box::new(assignment)), Child::Node(Box::new(body))],
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
        Some(self.wrap(
            "IF",
            vec![condition, action, Child::Nil],
            node,
        ))
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
        if node_text(function, self.source) == "yield" {
            return Some(self.wrap(
                "YIELD",
                vec![list_or_nil(args, args_node.unwrap_or(node), self)],
                node,
            ));
        }
        let call_type = if args.is_empty() { "VCALL" } else { "FCALL" };
        let call = self.wrap(
            call_type,
            vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                list_or_nil(args, args_node.unwrap_or(node), self),
            ],
            node,
        );
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
        let message = node_text(self.named_children(node).into_iter().next()?, self.source).to_string();
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
        if let Some(number) = text.strip_prefix('$').and_then(|value| value.parse::<i64>().ok()) {
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

    fn normalize_interpolated_string(&mut self, node: TreeSitterNode<'_>) -> Node {
        let children = self.normalize_children(node);
        self.wrap("DSTR", children, node)
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
        Some(self.wrap("EVSTR", body.into_iter().map(|node| Child::Node(Box::new(node))).collect(), node))
    }

    fn normalize_heredoc_beginning(&mut self, node: TreeSitterNode<'_>) -> Node {
        let heredoc_body = node
            .parent()
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
        if self.ruby_vcall_identifier(node, &name) {
            self.wrap("VCALL", vec![Child::Symbol(name)], node)
        } else {
            self.wrap("LVAR", vec![Child::String(name)], node)
        }
    }

    fn normalize_parameters(&mut self, node: Option<TreeSitterNode<'_>>) -> Option<Node> {
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
                    vec![Child::Symbol(node_text(name, self.source).to_string()), value],
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

    fn normalize_block_parameters(&mut self, _block: Option<TreeSitterNode<'_>>) -> Option<Node> {
        None
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
        self.wrap(
            "SCOPE",
            vec![Child::Nil, optional_node(args), optional_node(body)],
            source,
        )
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

    fn with_ruby_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
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
            "method_parameters" | "block_parameters" | "lambda_parameters"
        ) {
            for child in self.named_children(node) {
                self.collect_identifier_names(child, locals);
            }
        }
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            if let Some(left) = self.assignment_left(node) {
                self.collect_assignment_target_names(left, locals);
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
            locals.insert(node_text(node, self.source).trim_start_matches('*').to_string());
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
            locals.insert(node_text(node, self.source).trim_start_matches('*').to_string());
        }
        for child in self.named_children(node) {
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
        !self.assignment_lhs(node)
            && !self.ruby_definition_identifier(node)
            && !self
                .local_stack
                .iter()
                .rev()
                .any(|scope| scope.contains(name))
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
                | "block_parameters"
                | "lambda_parameters"
                | "optional_parameter"
                | "keyword_parameter"
                | "block_parameter"
        )
    }

    fn assignment_lhs(&self, node: TreeSitterNode<'_>) -> bool {
        if node
            .prev_sibling()
            .map(|sibling| node_text(sibling, self.source) == ":")
            .unwrap_or(false)
        {
            return false;
        }
        node.next_sibling()
            .map(|sibling| assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    fn assignment_rhs(&self, node: TreeSitterNode<'_>) -> bool {
        node.prev_sibling()
            .map(|sibling| assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    fn modifier_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let named = self.named_children(node);
        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.modifier_keyword(node).is_some()
            && named.len() == 2
    }

    fn leading_if_statement(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) && node
            .children(&mut node.walk())
            .next()
            .map(|child| matches!(child.kind(), "if" | "unless"))
            .unwrap_or(false)
            && self.named_children(node).len() >= 2
            && self
                .named_children(node)
                .first()
                .map(|child| !if_kind(child.kind()))
                .unwrap_or(false)
    }

    fn normalize_leading_if_statement(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
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
        let alternative = optional_node(alternative.and_then(|child| self.normalize_else_or_branch(child)));
        Some(self.wrap(
            node_type,
            vec![condition, consequence, alternative],
            node,
        ))
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
            .map(|args| node_text(args, self.source).trim_start().starts_with("def "))
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
        self.named_children(source)
            .into_iter()
            .find(|child| matches!(child.kind(), "self" | "this" | "constant" | "scope_resolution"))
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
        let mut stack = self.named_children(node).into_iter().rev().collect::<Vec<_>>();
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
        (matches!(node.kind(), "binary" | "binary_expression" | "boolean_operator")
            || self.boolean_statement(node))
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
                || matches!(node_text(child, self.source), "&&" | "||" | "and" | "or" | "(" | ")")
        })
    }

    fn operator_call_expression(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "binary" | "binary_expression")
            && self
                .binary_operator(node)
                .map(|operator| OPERATOR_CALL_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn comparison_expression(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "binary" | "binary_expression" | "comparison_operator")
            && self
                .comparison_operator(node)
                .map(|operator| COMPARISON_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn infix_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.infix_statement_parts(node).is_some()
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
        let mut named_index = 0usize;
        let mut left = None;
        let mut right = None;
        let mut operator = None;
        for child in node.children(&mut node.walk()) {
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
        node.children(&mut node.walk())
            .find(|child| !child.is_named() && !matches!(node_text(*child, self.source), "(" | ")"))
            .map(|child| node_text(child, self.source).to_string())
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
                || self.named_children(node).into_iter().any(|child| {
                    self.call_kind(child.kind()) || self.member_read_node(child)
                }))
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
            return self
                .scalar_argument_list_value(args)
                .into_iter()
                .collect();
        }
        if self.dotted_expression(args) {
            return self.normalize_dotted_expression(args).into_iter().collect();
        }
        if children.len() == 1
            && self.call_kind(children[0].kind())
            && self.call_block(children[0]).is_some()
        {
            return self.normalize_call_with_block(children[0]).into_iter().collect();
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

    fn assignment_right<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "right")
            .or_else(|| self.named_children(node).into_iter().nth(1))
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
        self.assignment_target(node, right.clone(), source).or_else(|| {
            Some(self.wrap(
                "LASGN",
                vec![Child::String(self.target_name(node)), optional_node(right)],
                node,
            ))
        })
    }

    fn target_name(&self, node: TreeSitterNode<'_>) -> String {
        node_text(node, self.source)
            .trim_start_matches('*')
            .to_string()
    }

    fn function_name(&self, node: TreeSitterNode<'_>) -> Option<String> {
        self.named_field(node, "name")
            .or_else(|| {
                self.named_children(node).into_iter().find(|child| {
                    self.identifier_kind(child.kind()) || child.kind() == "constant"
                })
            })
            .map(|name| node_text(name, self.source).to_string())
    }

    fn block_child<'tree>(&self, node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "body_statement" | "block_body" | "block"))
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
        node.child_by_field_name(name)
    }

    fn named_children<'tree>(&self, node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
        node.children(&mut node.walk())
            .filter(|child| child.is_named())
            .collect()
    }

    fn source_before_child(
        &self,
        node: TreeSitterNode<'_>,
        child: TreeSitterNode<'_>,
    ) -> Node {
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
        self.named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "else" | "elsif"))
    }

    fn identifier_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "identifier" | "simple_identifier" | "property_identifier" | "field_identifier"
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
        )
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
                    if let Some(elided) = child_node(child).and_then(|body| self.elide_tail_returns(Some(body))) {
                        node.children[2] = Child::Node(Box::new(elided));
                    }
                }
            }
            "IF" | "UNLESS" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) = child_node(child).and_then(|body| self.elide_tail_returns(Some(body))) {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "CASE" | "CASE2" => {
                let index = if node.r#type == "CASE" { 1 } else { 0 };
                if node.children.len() > index {
                    let child = std::mem::replace(&mut node.children[index], Child::Nil);
                    if let Some(elided) = child_node(child).and_then(|body| self.elide_tail_returns(Some(body))) {
                        node.children[index] = Child::Node(Box::new(elided));
                    }
                }
            }
            "WHEN" | "RESBODY" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) = child_node(child).and_then(|body| self.elide_tail_returns(Some(body))) {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "RESCUE" => {
                for index in [0usize, 1usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) = child_node(child).and_then(|body| self.elide_tail_returns(Some(body))) {
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
    matches!(
        text,
        "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||="
    )
}

fn kind_type(kind: &str) -> &str {
    match kind {
        "body_statement" | "block_body" | "block" => "BLOCK",
        other => other,
    }
}

fn if_kind(kind: &str) -> bool {
    matches!(
        kind,
        "if" | "if_statement" | "if_modifier" | "unless" | "unless_modifier" | "if_expression" | "conditional"
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
    use super::{parse, Child, Node};
    use std::io::Write;

    fn parse_source(source: &str) -> Node {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("create temp ruby file");
        file.write_all(source.as_bytes())
            .expect("write temp ruby file");
        parse(file.path()).expect("parse temp ruby file").0
    }

    fn nodes_of_type<'a>(node: &'a Node, node_type: &str, out: &mut Vec<&'a Node>) {
        if node.r#type == node_type {
            out.push(node);
        }
        for child in node.children.iter().filter_map(super::node) {
            nodes_of_type(child, node_type, out);
        }
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
            defs.iter()
                .any(|node| node.children.get(1) == Some(&Child::Symbol("collect_payload_binding_names".to_string()))),
            "expected normalized DEFS for visibility-wrapped singleton def, got {root:#?}"
        );

        let def = defs
            .into_iter()
            .find(|node| node.children.get(1) == Some(&Child::Symbol("collect_payload_binding_names".to_string())))
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
        assert_eq!(call.children.get(1), Some(&Child::Symbol("chomp".to_string())));
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
            children: vec![
                Child::Node(Box::new(left)),
                Child::Node(Box::new(right)),
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 6,
            text: "a && b".to_string(),
        };

        assert_eq!(super::flatten_and(&and_node).len(), 2);
    }
}
