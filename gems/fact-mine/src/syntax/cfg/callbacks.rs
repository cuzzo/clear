use super::ControlFlowProfile;
use crate::ast::{self, Child, Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CallbackKind {
    Block,
    Yield,
}

#[derive(Clone, Debug)]
pub(crate) struct CallbackRegion<'a> {
    pub(crate) kind: CallbackKind,
    pub(crate) body: Vec<&'a Node>,
}

impl CallbackKind {
    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::Block => "callback_region",
            Self::Yield => "yield_site",
        }
    }
}

pub(crate) fn from_node<'a>(
    node: &'a Node,
    profile: &ControlFlowProfile,
) -> Option<CallbackRegion<'a>> {
    match node.r#type.as_str() {
        "ITER" if !iterator_like_iter(node, profile) => Some(CallbackRegion {
            kind: CallbackKind::Block,
            body: scope_body(node.children.get(1).and_then(ast::node), profile),
        }),
        "YIELD" => Some(CallbackRegion {
            kind: CallbackKind::Yield,
            body: Vec::new(),
        }),
        "VCALL" | "FCALL" | "CALL" | "QCALL" => {
            callback_call_body(node, profile).map(|body| CallbackRegion {
                kind: CallbackKind::Block,
                body,
            })
        }
        _ => None,
    }
}

pub(crate) fn iterator_like_iter(node: &Node, profile: &ControlFlowProfile) -> bool {
    if node.r#type != "ITER" {
        return false;
    }
    iterator_like_call(node.children.first().and_then(ast::node), profile)
}

fn iterator_like_call(call: Option<&Node>, profile: &ControlFlowProfile) -> bool {
    call.and_then(call_message)
        .is_some_and(|message| profile.iterator_message(&message))
}

fn call_message(call: &Node) -> Option<String> {
    let index = match call.r#type.as_str() {
        "VCALL" | "FCALL" => 0,
        "CALL" | "QCALL" => 1,
        _ => return None,
    };
    match call.children.get(index)? {
        Child::Symbol(value) | Child::String(value) => Some(value.clone()),
        _ => None,
    }
}

fn callback_call_body<'a>(call: &'a Node, profile: &ControlFlowProfile) -> Option<Vec<&'a Node>> {
    let args = match call.r#type.as_str() {
        "FCALL" => call.children.get(1).and_then(ast::node),
        "CALL" | "QCALL" => call.children.get(2).and_then(ast::node),
        _ => None,
    }?;
    lambda_body_in(args, profile)
}

fn lambda_body_in<'a>(node: &'a Node, profile: &ControlFlowProfile) -> Option<Vec<&'a Node>> {
    if node.r#type == "LAMBDA" {
        return Some(scope_body(
            node.children.first().and_then(ast::node),
            profile,
        ));
    }
    node.children
        .iter()
        .filter_map(ast::node)
        .find_map(|child| lambda_body_in(child, profile))
}

fn scope_body<'a>(scope: Option<&'a Node>, profile: &ControlFlowProfile) -> Vec<&'a Node> {
    let Some(scope) = scope else {
        return Vec::new();
    };
    if scope.r#type == "SCOPE" {
        return body_nodes(scope.children.get(2).and_then(ast::node), profile);
    }
    body_nodes(Some(scope), profile)
}

fn body_nodes<'a>(body: Option<&'a Node>, profile: &ControlFlowProfile) -> Vec<&'a Node> {
    body.map(ast::statement_nodes)
        .unwrap_or_default()
        .into_iter()
        .filter(|node| !empty_body_artifact(node, profile))
        .collect()
}

fn empty_body_artifact(node: &Node, profile: &ControlFlowProfile) -> bool {
    let source = ast::normalize_text(&node.text);
    source.is_empty() || profile.ignored_callback_body_source(&source)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_PROFILE: ControlFlowProfile = ControlFlowProfile {
        iterator_messages: &["each"],
        ignored_callback_body_sources: &["do end", "{}"],
    };

    fn from_node(node: &Node) -> Option<CallbackRegion<'_>> {
        super::from_node(node, &TEST_PROFILE)
    }

    fn iterator_like_iter(node: &Node) -> bool {
        super::iterator_like_iter(node, &TEST_PROFILE)
    }

    #[test]
    fn iterator_like_iter_is_not_a_callback() {
        let iter = iter_node(
            call("CALL", "items", "each"),
            vec![call("FCALL", "self", "work")],
        );

        assert!(iterator_like_iter(&iter));
        assert!(from_node(&iter).is_none());
    }

    #[test]
    fn extracts_non_iterator_block_callback_body() {
        let iter = iter_node(
            call("FCALL", "self", "transaction"),
            vec![call("FCALL", "self", "work")],
        );

        let callback = from_node(&iter).expect("callback");

        assert_eq!(callback.kind, CallbackKind::Block);
        assert_eq!(callback.kind.role(), "callback_region");
        assert_eq!(callback.body.len(), 1);
        assert_eq!(callback.body[0].text, "work");
    }

    #[test]
    fn empty_callback_body_stays_empty() {
        let iter = iter_node(call("FCALL", "self", "transaction"), Vec::new());

        let callback = from_node(&iter).expect("callback");

        assert!(callback.body.is_empty());
    }

    #[test]
    fn drops_empty_ruby_do_end_body_artifact() {
        let iter = iter_node(
            call("FCALL", "self", "transaction"),
            vec![node("BLOCK", "do end", Vec::new())],
        );

        let callback = from_node(&iter).expect("callback");

        assert!(callback.body.is_empty());
    }

    #[test]
    fn extracts_yield_site() {
        let node = node("YIELD", "yield value", Vec::new());

        let callback = from_node(&node).expect("yield callback");

        assert_eq!(callback.kind, CallbackKind::Yield);
        assert_eq!(callback.kind.role(), "yield_site");
        assert!(callback.body.is_empty());
    }

    #[test]
    fn extracts_lambda_argument_callback_body() {
        let call = call_with_lambda_arg("callback", vec![call("FCALL", "self", "work")]);

        let callback = from_node(&call).expect("lambda callback");

        assert_eq!(callback.kind, CallbackKind::Block);
        assert_eq!(callback.body.len(), 1);
        assert_eq!(callback.body[0].text, "work");
    }

    #[test]
    fn rejects_non_iter_and_malformed_call_shapes() {
        assert!(!iterator_like_iter(&call("FCALL", "self", "work")));

        let unknown_call = node("LVAR", "items", Vec::new());
        let iter = node(
            "ITER",
            "items { work }",
            vec![
                Child::Node(Box::new(unknown_call)),
                Child::Node(Box::new(node("SCOPE", "", Vec::new()))),
            ],
        );
        assert!(!iterator_like_iter(&iter));

        let nil_message_call = node(
            "CALL",
            "items.?",
            vec![
                Child::Node(Box::new(node("LVAR", "items", Vec::new()))),
                Child::Nil,
                Child::Nil,
            ],
        );
        let iter = node(
            "ITER",
            "items.? { work }",
            vec![
                Child::Node(Box::new(nil_message_call)),
                Child::Node(Box::new(node("SCOPE", "", Vec::new()))),
            ],
        );
        assert!(!iterator_like_iter(&iter));
    }

    #[test]
    fn lambda_callback_handles_missing_or_direct_body_scope() {
        let missing_scope = node(
            "FCALL",
            "callback(lambda)",
            vec![
                Child::Symbol("callback".to_string()),
                Child::Node(Box::new(node(
                    "LIST",
                    "",
                    vec![Child::Node(Box::new(node("LAMBDA", "lambda", Vec::new())))],
                ))),
            ],
        );
        let callback = from_node(&missing_scope).expect("lambda callback");
        assert!(callback.body.is_empty());

        let direct_scope = node(
            "FCALL",
            "callback(lambda)",
            vec![
                Child::Symbol("callback".to_string()),
                Child::Node(Box::new(node(
                    "LIST",
                    "",
                    vec![Child::Node(Box::new(node(
                        "LAMBDA",
                        "lambda",
                        vec![Child::Node(Box::new(node(
                            "BLOCK",
                            "",
                            vec![Child::Node(Box::new(call("FCALL", "self", "work")))],
                        )))],
                    )))],
                ))),
            ],
        );
        let callback = from_node(&direct_scope).expect("lambda callback");
        assert_eq!(callback.body.len(), 1);
        assert_eq!(callback.body[0].text, "work");
    }

    fn iter_node(call: Node, body: Vec<Node>) -> Node {
        node(
            "ITER",
            "transaction { work }",
            vec![
                Child::Node(Box::new(call)),
                Child::Node(Box::new(node(
                    "SCOPE",
                    "",
                    vec![
                        Child::Node(Box::new(node("ARGS", "", Vec::new()))),
                        Child::Node(Box::new(node("BLOCK", "", Vec::new()))),
                        Child::Node(Box::new(node(
                            "BLOCK",
                            "",
                            body.into_iter()
                                .map(|child| Child::Node(Box::new(child)))
                                .collect(),
                        ))),
                    ],
                ))),
            ],
        )
    }

    fn call(kind: &str, receiver: &str, message: &str) -> Node {
        match kind {
            "CALL" => node(
                kind,
                &format!("{receiver}.{message}"),
                vec![
                    Child::Node(Box::new(node(
                        "LVAR",
                        receiver,
                        vec![Child::String(receiver.to_string())],
                    ))),
                    Child::Symbol(message.to_string()),
                    Child::Nil,
                ],
            ),
            _ => node(
                kind,
                message,
                vec![Child::Symbol(message.to_string()), Child::Nil],
            ),
        }
    }

    fn call_with_lambda_arg(message: &str, body: Vec<Node>) -> Node {
        node(
            "FCALL",
            &format!("{message}(lambda)"),
            vec![
                Child::Symbol(message.to_string()),
                Child::Node(Box::new(node(
                    "LIST",
                    "",
                    vec![Child::Node(Box::new(lambda(body)))],
                ))),
            ],
        )
    }

    fn lambda(body: Vec<Node>) -> Node {
        node(
            "LAMBDA",
            "lambda",
            vec![Child::Node(Box::new(node(
                "SCOPE",
                "",
                vec![
                    Child::Node(Box::new(node("ARGS", "", Vec::new()))),
                    Child::Node(Box::new(node("BLOCK", "", Vec::new()))),
                    Child::Node(Box::new(node(
                        "BLOCK",
                        "",
                        body.into_iter()
                            .map(|child| Child::Node(Box::new(child)))
                            .collect(),
                    ))),
                ],
            )))],
        )
    }

    fn node(kind: &str, text: &str, children: Vec<Child>) -> Node {
        Node {
            r#type: kind.to_string(),
            children,
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: text.len(),
            text: text.to_string(),
        }
    }
}
