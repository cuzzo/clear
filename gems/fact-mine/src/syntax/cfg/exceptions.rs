use crate::ast::{self, Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ExceptionRegionKind {
    Rescue,
    Ensure,
}

#[derive(Clone, Debug)]
pub(crate) struct ExceptionRegion<'a> {
    pub(crate) kind: ExceptionRegionKind,
    pub(crate) body: Vec<&'a Node>,
    pub(crate) handlers: Vec<ExceptionHandler<'a>>,
    pub(crate) fallback: Vec<&'a Node>,
    pub(crate) cleanup: Vec<&'a Node>,
}

#[derive(Clone, Debug)]
pub(crate) struct ExceptionHandler<'a> {
    pub(crate) body: Vec<&'a Node>,
}

impl ExceptionRegionKind {
    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::Rescue => "rescue_region",
            Self::Ensure => "ensure_region",
        }
    }
}

pub(crate) fn from_node(node: &Node) -> Option<ExceptionRegion<'_>> {
    match node.r#type.as_str() {
        "RESCUE" => Some(rescue_region(node)),
        "ENSURE" => Some(ensure_region(node)),
        _ => None,
    }
}

fn rescue_region(node: &Node) -> ExceptionRegion<'_> {
    let (handlers, mut fallback) = split_resbody_chain(node.children.get(1).and_then(ast::node));
    if fallback.is_empty() {
        fallback = body_nodes(node.children.get(2).and_then(ast::node));
    }
    ExceptionRegion {
        kind: ExceptionRegionKind::Rescue,
        body: body_nodes(node.children.first().and_then(ast::node)),
        handlers,
        fallback,
        cleanup: Vec::new(),
    }
}

fn ensure_region(node: &Node) -> ExceptionRegion<'_> {
    ExceptionRegion {
        kind: ExceptionRegionKind::Ensure,
        body: body_nodes(node.children.first().and_then(ast::node)),
        handlers: Vec::new(),
        fallback: Vec::new(),
        cleanup: body_nodes(node.children.get(1).and_then(ast::node)),
    }
}

fn split_resbody_chain(mut current: Option<&Node>) -> (Vec<ExceptionHandler<'_>>, Vec<&Node>) {
    let mut handlers = Vec::new();

    while let Some(resbody) = current {
        if resbody.r#type != "RESBODY" {
            return (handlers, body_nodes(Some(resbody)));
        }

        handlers.push(ExceptionHandler {
            body: body_nodes(resbody.children.get(1).and_then(ast::node)),
        });
        current = resbody.children.get(2).and_then(ast::node);
    }

    (handlers, Vec::new())
}

fn body_nodes(body: Option<&Node>) -> Vec<&Node> {
    let Some(body) = body else {
        return Vec::new();
    };
    if matches!(body.r#type.as_str(), "RESCUE" | "ENSURE") {
        return vec![body];
    }
    ast::statement_nodes(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Child;

    #[test]
    fn extracts_rescue_body_handlers_and_fallback() {
        let node = rescue_node(
            vec![call("work()")],
            Some(resbody(
                Some(vec![call("recover()")]),
                Some(block(vec![call("else_body()")])),
            )),
            None,
        );

        let region = from_node(&node).expect("rescue region");

        assert_eq!(region.kind, ExceptionRegionKind::Rescue);
        assert_eq!(region.kind.role(), "rescue_region");
        assert_eq!(region.body[0].text, "work()");
        assert_eq!(region.handlers.len(), 1);
        assert_eq!(region.handlers[0].body[0].text, "recover()");
        assert_eq!(region.fallback[0].text, "else_body()");
        assert!(region.cleanup.is_empty());
    }

    #[test]
    fn empty_rescue_handler_stays_empty() {
        let node = rescue_node(vec![call("work()")], Some(resbody(None, None)), None);

        let region = from_node(&node).expect("rescue region");

        assert_eq!(region.handlers.len(), 1);
        assert!(region.handlers[0].body.is_empty());
    }

    #[test]
    fn extracts_ensure_body_and_cleanup() {
        let node = ensure_node(vec![call("work()")], vec![call("close()")]);

        let region = from_node(&node).expect("ensure region");

        assert_eq!(region.kind, ExceptionRegionKind::Ensure);
        assert_eq!(region.kind.role(), "ensure_region");
        assert_eq!(region.body[0].text, "work()");
        assert_eq!(region.cleanup[0].text, "close()");
        assert!(region.handlers.is_empty());
        assert!(region.fallback.is_empty());
    }

    fn rescue_node(body: Vec<Node>, handler: Option<Node>, fallback: Option<Node>) -> Node {
        node_with_children(
            "RESCUE",
            "begin work() rescue recover() else else_body() end",
            vec![
                optional_node(Some(block(body))),
                optional_node(handler),
                optional_node(fallback),
            ],
        )
    }

    fn ensure_node(body: Vec<Node>, cleanup: Vec<Node>) -> Node {
        node_with_children(
            "ENSURE",
            "begin work() ensure close() end",
            vec![
                optional_node(Some(block(body))),
                optional_node(Some(block(cleanup))),
            ],
        )
    }

    fn resbody(body: Option<Vec<Node>>, tail: Option<Node>) -> Node {
        node_with_children(
            "RESBODY",
            "rescue recover()",
            vec![
                Child::Nil,
                optional_node(body.map(block)),
                optional_node(tail),
            ],
        )
    }

    fn block(children: Vec<Node>) -> Node {
        node(
            "BLOCK",
            "",
            children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
        )
    }

    fn call(source: &str) -> Node {
        node("FCALL", source, Vec::new())
    }

    fn node(kind: &str, text: &str, children: Vec<Child>) -> Node {
        node_with_children(kind, text, children)
    }

    fn node_with_children(kind: &str, text: &str, children: Vec<Child>) -> Node {
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

    fn optional_node(node: Option<Node>) -> Child {
        node.map(|node| Child::Node(Box::new(node)))
            .unwrap_or(Child::Nil)
    }
}
