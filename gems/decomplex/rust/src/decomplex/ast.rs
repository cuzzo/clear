use crate::decomplex::syntax::Language;
use serde::Serialize;
use tree_sitter::Node;

pub type Span = [usize; 4];
const OPERATOR_CALL_OPERATORS: &[&str] = &[
    "+", "-", "*", "/", "%", "**", "|", "&", "^", "<<", ">>", "=~", "!~",
];

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TreeSitterNormalizationAdapter {
    Ruby,
    Python,
    Lua,
    TypeScript,
}

impl TreeSitterNormalizationAdapter {
    fn for_language(language: Language) -> Self {
        match language {
            Language::Ruby => Self::Ruby,
            Language::Python => Self::Python,
            Language::Lua => Self::Lua,
            Language::TypeScript | Language::JavaScript => Self::TypeScript,
        }
    }

    fn binary_operator(self, node: Node<'_>, source: &str) -> Option<String> {
        if let Some(operator) = direct_binary_operator(node, source) {
            return Some(operator.to_string());
        }

        if self != Self::Lua {
            return None;
        }

        let children = named_children(node);
        if children.len() == 1
            && matches!(
                children[0].kind(),
                "binary"
                    | "binary_expression"
                    | "binary_operator"
                    | "boolean_operator"
                    | "comparison_operator"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            return self.binary_operator(children[0], source);
        }

        None
    }

    fn operator_call_expression(self, node: Node<'_>, source: &str) -> bool {
        self.operator_call_expression_kind(node.kind())
            && self.operator_call_operand_count(node, source) >= 2
            && self
                .binary_operator(node, source)
                .map(|operator| OPERATOR_CALL_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    fn operator_call_operand_count(self, node: Node<'_>, source: &str) -> usize {
        if self == Self::Lua {
            let children = named_children(node);
            if children.len() == 1
                && matches!(
                    children[0].kind(),
                    "binary"
                        | "binary_expression"
                        | "binary_operator"
                        | "boolean_operator"
                        | "comparison_operator"
                )
                && node_text(node, source) == node_text(children[0], source)
            {
                return named_children(children[0]).len();
            }
        }

        named_children(node).len()
    }

    fn operator_call_expression_kind(self, kind: &str) -> bool {
        match self {
            Self::Python => matches!(kind, "binary" | "binary_expression" | "binary_operator"),
            Self::Lua => matches!(kind, "binary" | "binary_expression" | "expression_list"),
            _ => matches!(kind, "binary" | "binary_expression"),
        }
    }
}

pub fn binary_operator(node: Node<'_>, source: &str) -> Option<String> {
    TreeSitterNormalizationAdapter::Ruby.binary_operator(node, source)
}

pub fn operator_call_expression(node: Node<'_>, source: &str, language: Language) -> bool {
    TreeSitterNormalizationAdapter::for_language(language).operator_call_expression(node, source)
}

fn direct_binary_operator<'source>(node: Node<'_>, source: &'source str) -> Option<&'source str> {
    all_children(node)
        .into_iter()
        .find(|child| !child.is_named() && !matches!(node_text(*child, source), "(" | ")"))
        .map(|child| node_text(child, source))
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

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::{Language as TreeSitterLanguage, Parser, Tree};

    fn language_grammar(language: Language) -> TreeSitterLanguage {
        match language {
            Language::Ruby => tree_sitter_ruby::LANGUAGE.into(),
            Language::Python => tree_sitter_python::LANGUAGE.into(),
            Language::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Language::JavaScript => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Language::Lua => tree_sitter_lua::LANGUAGE.into(),
        }
    }

    fn raw_tree(source: &str, language: Language) -> Tree {
        let mut parser = Parser::new();
        parser
            .set_language(&language_grammar(language))
            .expect("set language");
        parser.parse(source, None).expect("parse source")
    }

    fn first_raw_node<'tree>(
        node: Node<'tree>,
        source: &str,
        kind: &str,
        text: &str,
    ) -> Node<'tree> {
        find_raw_node(node, source, kind, text)
            .unwrap_or_else(|| panic!("missing {kind} node with text {text:?}"))
    }

    fn find_raw_node<'tree>(
        node: Node<'tree>,
        source: &str,
        kind: &str,
        text: &str,
    ) -> Option<Node<'tree>> {
        if node.kind() == kind && node_text(node, source) == text {
            return Some(node);
        }

        for child in all_children(node) {
            if let Some(found) = find_raw_node(child, source, kind, text) {
                return Some(found);
            }
        }

        None
    }

    #[test]
    fn operator_call_expression_matches_ruby_adapter_behavior() {
        for (source, language, kind, text, expected) in [
            (
                "def calc\n  left + right\n  left && right\nend\n",
                Language::Ruby,
                "binary",
                "left + right",
                true,
            ),
            (
                "def calc\n  left + right\n  left && right\nend\n",
                Language::Ruby,
                "binary",
                "left && right",
                false,
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                "binary_expression",
                "left + right",
                true,
            ),
            (
                "const value = left + right && other;\n",
                Language::TypeScript,
                "binary_expression",
                "left + right && other",
                false,
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                "binary_operator",
                "left + right",
                true,
            ),
            (
                "value = left + right and other\n",
                Language::Python,
                "boolean_operator",
                "left + right and other",
                false,
            ),
            (
                "local value = left + right\nlocal other = left and right\n",
                Language::Lua,
                "expression_list",
                "left + right",
                true,
            ),
            (
                "local value = left + right\nlocal other = left and right\n",
                Language::Lua,
                "expression_list",
                "left and right",
                false,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);

            assert_eq!(
                operator_call_expression(node, source, language),
                expected,
                "operator_call_expression mismatch for {language:?} {kind} {text:?}"
            );
        }
    }
}
