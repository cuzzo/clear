use super::{callbacks, ControlFlowProfile};
use crate::ast::{self, Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LoopKind {
    While,
    Until,
    For,
    Iter,
}

#[derive(Clone, Debug)]
pub(crate) struct Loop<'a> {
    pub(crate) kind: LoopKind,
    pub(crate) condition: Option<&'a Node>,
    pub(crate) body: Vec<&'a Node>,
}

impl LoopKind {
    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::While => "while_loop",
            Self::Until => "until_loop",
            Self::For => "for_loop",
            Self::Iter => "iterator_loop",
        }
    }
}

pub(crate) fn from_node<'a>(node: &'a Node, profile: &ControlFlowProfile) -> Option<Loop<'a>> {
    match node.r#type.as_str() {
        "WHILE" => Some(Loop {
            kind: LoopKind::While,
            condition: node.children.first().and_then(ast::node),
            body: body_nodes(node.children.get(1).and_then(ast::node)),
        }),
        "UNTIL" => Some(Loop {
            kind: LoopKind::Until,
            condition: node.children.first().and_then(ast::node),
            body: body_nodes(node.children.get(1).and_then(ast::node)),
        }),
        "FOR" => Some(Loop {
            kind: LoopKind::For,
            condition: node.children.get(1).and_then(ast::node),
            body: body_nodes(node.children.get(2).and_then(ast::node)),
        }),
        "ITER" if callbacks::iterator_like_iter(node, profile) => Some(Loop {
            kind: LoopKind::Iter,
            condition: node.children.first().and_then(ast::node),
            body: scope_body(node.children.get(1).and_then(ast::node)),
        }),
        _ => None,
    }
}

fn body_nodes(body: Option<&Node>) -> Vec<&Node> {
    body.map(ast::statement_nodes).unwrap_or_default()
}

fn scope_body(scope: Option<&Node>) -> Vec<&Node> {
    let Some(scope) = scope else {
        return Vec::new();
    };
    if scope.r#type == "SCOPE" {
        return body_nodes(scope.children.get(2).and_then(ast::node));
    }
    body_nodes(Some(scope))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Child;

    const TEST_PROFILE: ControlFlowProfile = ControlFlowProfile {
        iterator_messages: &["each"],
        ignored_callback_body_sources: &[],
    };

    fn from_node(node: &Node) -> Option<Loop<'_>> {
        super::from_node(node, &TEST_PROFILE)
    }

    #[test]
    fn while_loop_uses_condition_and_body() {
        let node = loop_node("WHILE");
        let cfg_loop = from_node(&node).expect("while loop");

        assert_eq!(cfg_loop.kind, LoopKind::While);
        assert_eq!(cfg_loop.condition.expect("condition").text, "ready?");
        assert_eq!(cfg_loop.body.len(), 1);
        assert_eq!(cfg_loop.body[0].text, "work()");
    }

    #[test]
    fn iter_loop_extracts_scope_body() {
        let node = node(
            "ITER",
            "items.each { work() }",
            vec![
                call_node("items", "each"),
                node(
                    "SCOPE",
                    "",
                    vec![
                        node("ARGS", "", Vec::new()),
                        node("BLOCK", "", Vec::new()),
                        node("BLOCK", "work()", vec![node("FCALL", "work()", Vec::new())]),
                    ],
                ),
            ],
        );
        let cfg_loop = from_node(&node).expect("iter loop");

        assert_eq!(cfg_loop.kind, LoopKind::Iter);
        assert_eq!(cfg_loop.body.len(), 1);
        assert_eq!(cfg_loop.body[0].text, "work()");
    }

    #[test]
    fn non_iterator_iter_is_not_a_loop() {
        let node = node(
            "ITER",
            "transaction { work() }",
            vec![
                call_node("self", "transaction"),
                node(
                    "SCOPE",
                    "",
                    vec![
                        node("ARGS", "", Vec::new()),
                        node("BLOCK", "", Vec::new()),
                        node("BLOCK", "work()", vec![node("FCALL", "work()", Vec::new())]),
                    ],
                ),
            ],
        );

        assert!(from_node(&node).is_none());
    }

    #[test]
    fn iter_loop_handles_missing_or_direct_body_scope() {
        let missing_scope = node("ITER", "items.each", vec![call_node("items", "each")]);
        let cfg_loop = from_node(&missing_scope).expect("iter loop");
        assert_eq!(cfg_loop.kind, LoopKind::Iter);
        assert!(cfg_loop.body.is_empty());

        let direct_body = node(
            "ITER",
            "items.each { work() }",
            vec![
                call_node("items", "each"),
                node("BLOCK", "work()", vec![node("FCALL", "work()", Vec::new())]),
            ],
        );
        let cfg_loop = from_node(&direct_body).expect("iter loop");
        assert_eq!(cfg_loop.body.len(), 1);
        assert_eq!(cfg_loop.body[0].text, "work()");
    }

    fn loop_node(kind: &str) -> Node {
        node(
            kind,
            "while ready? work() end",
            vec![
                node("VCALL", "ready?", Vec::new()),
                node("BLOCK", "work()", vec![node("FCALL", "work()", Vec::new())]),
            ],
        )
    }

    fn call_node(receiver: &str, message: &str) -> Node {
        Node {
            r#type: "CALL".to_string(),
            children: vec![
                Child::Node(Box::new(node("LVAR", receiver, Vec::new()))),
                Child::Symbol(message.to_string()),
                Child::Nil,
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: format!("{receiver}.{message}").len(),
            text: format!("{receiver}.{message}"),
        }
    }

    fn node(kind: &str, text: &str, children: Vec<Node>) -> Node {
        Node {
            r#type: kind.to_string(),
            children: children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: text.len(),
            text: text.to_string(),
        }
    }
}
