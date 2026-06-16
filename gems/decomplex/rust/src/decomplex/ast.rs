use serde::Serialize;
use tree_sitter::Node;

pub type Span = [usize; 4];

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
