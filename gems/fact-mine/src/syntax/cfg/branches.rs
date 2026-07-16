use crate::ast::{self, Node};
use crate::syntax::Span;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BranchKind {
    If,
    Unless,
}

#[derive(Clone, Debug)]
pub(crate) struct Branch<'a> {
    pub(crate) kind: BranchKind,
    pub(crate) condition: Option<&'a Node>,
    pub(crate) then_body: Vec<&'a Node>,
    pub(crate) else_body: Vec<&'a Node>,
}

impl BranchKind {
    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::If => "if",
            Self::Unless => "unless",
        }
    }

    pub(crate) fn then_edge_kind(self) -> &'static str {
        match self {
            Self::If => "branch_true",
            Self::Unless => "branch_false",
        }
    }

    pub(crate) fn else_edge_kind(self) -> &'static str {
        match self {
            Self::If => "branch_false",
            Self::Unless => "branch_true",
        }
    }

    pub(crate) fn edge_for_condition_outcome(self, condition_truth: bool) -> &'static str {
        match (self, condition_truth) {
            (Self::If, true) | (Self::Unless, false) => self.then_edge_kind(),
            (Self::If, false) | (Self::Unless, true) => self.else_edge_kind(),
        }
    }
}

pub(crate) fn from_node(node: &Node) -> Option<Branch<'_>> {
    let kind = match node.r#type.as_str() {
        "IF" => BranchKind::If,
        "UNLESS" => BranchKind::Unless,
        _ => return None,
    };
    Some(Branch {
        kind,
        condition: node.children.first().and_then(ast::node),
        then_body: body_nodes(node.children.get(1).and_then(ast::node)),
        else_body: body_nodes(node.children.get(2).and_then(ast::node)),
    })
}

pub(crate) fn find_by_span(node: &Node, target: Span) -> Option<&Node> {
    if span(node) == target {
        return Some(node);
    }

    node.children
        .iter()
        .filter_map(ast::node)
        .find_map(|child| find_by_span(child, target))
}

fn body_nodes(body: Option<&Node>) -> Vec<&Node> {
    body.map(ast::statement_nodes).unwrap_or_default()
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Child;

    #[test]
    fn extracts_if_arms_from_normalized_children() {
        let node = branch_node("IF");
        let branch = from_node(&node).expect("if branch");

        assert_eq!(branch.kind, BranchKind::If);
        assert_eq!(branch.then_body.len(), 1);
        assert_eq!(branch.else_body.len(), 1);
        assert_eq!(branch.kind.then_edge_kind(), "branch_true");
        assert_eq!(branch.kind.else_edge_kind(), "branch_false");
    }

    #[test]
    fn unless_edges_are_inverted() {
        let node = branch_node("UNLESS");
        let branch = from_node(&node).expect("unless branch");

        assert_eq!(branch.kind, BranchKind::Unless);
        assert_eq!(branch.kind.then_edge_kind(), "branch_false");
        assert_eq!(branch.kind.else_edge_kind(), "branch_true");
    }

    fn branch_node(kind: &str) -> Node {
        node(
            kind,
            4,
            4,
            8,
            7,
            "if ready? then work else skip end",
            vec![
                node("VCALL", 4, 7, 4, 13, "ready?", Vec::new()),
                node(
                    "BLOCK",
                    5,
                    6,
                    5,
                    12,
                    "work",
                    vec![node("VCALL", 5, 6, 5, 12, "work", Vec::new())],
                ),
                node(
                    "BLOCK",
                    7,
                    6,
                    7,
                    12,
                    "skip",
                    vec![node("VCALL", 7, 6, 7, 12, "skip", Vec::new())],
                ),
            ],
        )
    }

    fn node(
        kind: &str,
        first_line: usize,
        first_column: usize,
        last_line: usize,
        last_column: usize,
        text: &str,
        children: Vec<Node>,
    ) -> Node {
        Node {
            r#type: kind.to_string(),
            children: children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            first_lineno: first_line,
            first_column,
            last_lineno: last_line,
            last_column,
            text: text.to_string(),
        }
    }
}
