use serde::Serialize;
use tree_sitter::Node;

pub type Span = [usize; 4];

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, PartialOrd, Ord)]
pub enum NormKind {
    Program,
    Statements,
    Class,
    Module,
    Def,
    Parameters,
    Block,
    Call,
    Array,
    Hash,
    KeywordHash,
    Pair,
    String,
    InterpolatedString,
    Symbol,
    Integer,
    Float,
    True,
    False,
    Nil,
    Range,
    Return,
    Yield,
    If,
    Unless,
    While,
    Until,
    Case,
    When,
    Else,
    Begin,
    Rescue,
    Parentheses,
    SelfNode,
    ConstRead,
    ConstPath,
    ConstWrite,
    LocalRead,
    LocalWrite,
    IvarRead,
    IvarWrite,
    ClassVarRead,
    ClassVarWrite,
    GlobalVarRead,
    GlobalVarWrite,
    Or,
    HiddenOr,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RawNode {
    pub kind: String,
    pub text: String,
    pub span: Span,
    pub named: bool,
    pub children: Vec<RawNode>,
}

impl RawNode {
    pub fn from_tree_sitter(node: Node<'_>, source: &str) -> Self {
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

pub fn normalized_kind(node: Node<'_>, source: &str) -> NormKind {
    match node.kind() {
        "program" => NormKind::Program,
        "body_statement" | "block_body" | "then" => body_statement_kind(node, source),
        "class" => NormKind::Class,
        "module" => NormKind::Module,
        "method" | "singleton_method" => NormKind::Def,
        "method_parameters" => NormKind::Parameters,
        "block" | "do_block" => NormKind::Block,
        "assignment" | "operator_assignment" => assignment_kind(node),
        "call" | "command" | "method_call" => NormKind::Call,
        "element_reference" | "binary" | "unary" => {
            if node.kind() == "binary" && binary_operator(node, source).is_some_and(|op| matches!(op.as_str(), "||" | "or")) {
                NormKind::Or
            } else {
                NormKind::Call
            }
        }
        "array" => NormKind::Array,
        "hash" => NormKind::Hash,
        "pair" => NormKind::Pair,
        "string" | "string_content" | "bare_string" | "heredoc_body" => NormKind::String,
        "interpolation" => NormKind::InterpolatedString,
        "symbol" | "hash_key_symbol" => NormKind::Symbol,
        "integer" => NormKind::Integer,
        "float" => NormKind::Float,
        "true" => NormKind::True,
        "false" => NormKind::False,
        "nil" => NormKind::Nil,
        "range" => NormKind::Range,
        "return" => NormKind::Return,
        "yield" => NormKind::Yield,
        "if" | "if_modifier" => NormKind::If,
        "unless" | "unless_modifier" => NormKind::Unless,
        "while" | "while_modifier" => NormKind::While,
        "until" | "until_modifier" => NormKind::Until,
        "case" => NormKind::Case,
        "when" => NormKind::When,
        "else" => NormKind::Else,
        "begin" => NormKind::Begin,
        "rescue" | "rescue_modifier" => NormKind::Rescue,
        "parenthesized_statements" | "parenthesized_expression" => NormKind::Parentheses,
        "self" => NormKind::SelfNode,
        "constant" => NormKind::ConstRead,
        "scope_resolution" => NormKind::ConstPath,
        "instance_variable" => {
            if assignment_lhs_node(node) {
                NormKind::IvarWrite
            } else {
                NormKind::IvarRead
            }
        }
        "class_variable" => {
            if assignment_lhs_node(node) {
                NormKind::ClassVarWrite
            } else {
                NormKind::ClassVarRead
            }
        }
        "global_variable" => {
            if assignment_lhs_node(node) {
                NormKind::GlobalVarWrite
            } else {
                NormKind::GlobalVarRead
            }
        }
        "identifier" => {
            if assignment_lhs_node(node) {
                NormKind::LocalWrite
            } else {
                NormKind::LocalRead
            }
        }
        _ => NormKind::Other,
    }
}

fn body_statement_kind(node: Node<'_>, source: &str) -> NormKind {
    if hidden_or_body_statement(node, source) {
        return NormKind::HiddenOr;
    }
    let first = all_children(node).first().copied();
    match first.map(|child| child.kind()) {
        Some("def") => NormKind::Def,
        Some("class") => NormKind::Class,
        Some("module") => NormKind::Module,
        Some("return") => NormKind::Return,
        Some("if") => NormKind::If,
        Some("unless") => NormKind::Unless,
        Some("while") => NormKind::While,
        Some("until") => NormKind::Until,
        Some("case") => NormKind::Case,
        Some("begin") => NormKind::Begin,
        _ => NormKind::Statements,
    }
}

fn hidden_or_body_statement(node: Node<'_>, source: &str) -> bool {
    if node.kind() != "body_statement" {
        return false;
    }
    let texts: Vec<String> = all_children(node)
        .into_iter()
        .map(|child| node_text(child, source).to_string())
        .collect();
    texts.contains(&"||".to_string()) || texts.contains(&"or".to_string())
}

fn assignment_kind(node: Node<'_>) -> NormKind {
    if let Some(lhs) = assignment_lhs(node) {
        if lhs.kind() == "element_reference" {
            return NormKind::Call;
        }
    }
    NormKind::Other
}

pub fn assignment_lhs<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    node.child_by_field_name("left")
        .or_else(|| named_children(node).first().copied())
}

fn assignment_lhs_node(node: Node<'_>) -> bool {
    node.parent().is_some_and(|parent| {
        matches!(parent.kind(), "assignment" | "operator_assignment")
            && assignment_lhs(parent) == Some(node)
    })
}

pub fn binary_operator(node: Node<'_>, source: &str) -> Option<String> {
    all_children(node)
        .into_iter()
        .find(|child| !child.is_named() && !matches!(node_text(*child, source), "(" | ")"))
        .map(|child| node_text(child, source).to_string())
}

pub fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

pub fn all_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.children(&mut cursor).collect()
}

pub fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn span(node: Node<'_>) -> Span {
    let start = node.start_position();
    let end = node.end_position();
    [start.row + 1, start.column, end.row + 1, end.column]
}

pub fn line(node: Node<'_>) -> usize {
    node.start_position().row + 1
}

pub fn node_text<'a>(node: Node<'_>, source: &'a str) -> &'a str {
    node.utf8_text(source.as_bytes()).unwrap_or("")
}

pub fn walk_raw(node: Node<'_>, f: &mut impl FnMut(Node<'_>)) {
    f(node);
    for child in named_children(node) {
        walk_raw(child, f);
    }
}
