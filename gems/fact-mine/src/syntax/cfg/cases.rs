use crate::ast::{self, Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CaseKind {
    Case,
    Case2,
}

#[derive(Clone, Debug)]
pub(crate) struct Case<'a> {
    pub(crate) kind: CaseKind,
    pub(crate) arms: Vec<CaseArm<'a>>,
    pub(crate) fallback: Vec<&'a Node>,
}

#[derive(Clone, Debug)]
pub(crate) struct CaseArm<'a> {
    pub(crate) body: Vec<&'a Node>,
}

impl CaseKind {
    pub(crate) fn role(self) -> &'static str {
        match self {
            Self::Case => "case_dispatch",
            Self::Case2 => "case_match",
        }
    }
}

pub(crate) fn from_node(node: &Node) -> Option<Case<'_>> {
    let kind = match node.r#type.as_str() {
        "CASE" => CaseKind::Case,
        "CASE2" => CaseKind::Case2,
        _ => return None,
    };
    let chain = node.children.get(chain_index(kind)).and_then(ast::node);
    let (arms, fallback) = split_when_chain(chain);

    Some(Case {
        kind,
        arms,
        fallback,
    })
}

fn split_when_chain(mut current: Option<&Node>) -> (Vec<CaseArm<'_>>, Vec<&Node>) {
    let mut arms = Vec::new();

    while let Some(when) = current {
        if when.r#type != "WHEN" {
            return (arms, body_nodes(Some(when)));
        }

        arms.push(CaseArm {
            body: body_nodes(when.children.get(1).and_then(ast::node)),
        });
        current = when.children.get(2).and_then(ast::node);
    }

    (arms, Vec::new())
}

fn body_nodes(body: Option<&Node>) -> Vec<&Node> {
    body.map(ast::statement_nodes).unwrap_or_default()
}

fn chain_index(kind: CaseKind) -> usize {
    match kind {
        CaseKind::Case => 1,
        CaseKind::Case2 => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Child;

    #[test]
    fn extracts_case_arms_and_fallback_from_when_chain() {
        let node = case_node(
            "CASE",
            Some(value("role")),
            when_chain(vec![
                when(vec![call("publish(user)")]),
                when(vec![call("escalate(user)")]),
            ])
            .with_fallback(block(vec![call("ignore(user)")])),
        );

        let cfg_case = from_node(&node).expect("case");

        assert_eq!(cfg_case.kind, CaseKind::Case);
        assert_eq!(cfg_case.kind.role(), "case_dispatch");
        assert_eq!(cfg_case.arms.len(), 2);
        assert_eq!(cfg_case.arms[0].body[0].text, "publish(user)");
        assert_eq!(cfg_case.arms[1].body[0].text, "escalate(user)");
        assert_eq!(cfg_case.fallback[0].text, "ignore(user)");
    }

    #[test]
    fn extracts_case2_chain_without_subject() {
        let node = case_node(
            "CASE2",
            None,
            when_chain(vec![when(vec![call("ready()")])]).into_node(),
        );

        let cfg_case = from_node(&node).expect("case2");

        assert_eq!(cfg_case.kind, CaseKind::Case2);
        assert_eq!(cfg_case.kind.role(), "case_match");
        assert_eq!(cfg_case.arms.len(), 1);
        assert!(cfg_case.fallback.is_empty());
    }

    #[test]
    fn empty_arm_stays_empty() {
        let node = case_node(
            "CASE",
            Some(value("role")),
            when_chain(vec![when(Vec::new())]).into_node(),
        );

        let cfg_case = from_node(&node).expect("case");

        assert_eq!(cfg_case.arms.len(), 1);
        assert!(cfg_case.arms[0].body.is_empty());
    }

    #[test]
    fn fallback_only_case_uses_chain_as_default_body() {
        let node = case_node(
            "CASE",
            Some(value("role")),
            block(vec![call("ignore(user)")]),
        );

        let cfg_case = from_node(&node).expect("case");

        assert!(cfg_case.arms.is_empty());
        assert_eq!(cfg_case.fallback[0].text, "ignore(user)");
    }

    struct Chain(Node);

    impl Chain {
        fn with_fallback(mut self, fallback: Node) -> Node {
            set_fallback(&mut self.0, fallback);
            self.0
        }

        fn into_node(self) -> Node {
            self.0
        }
    }

    fn when_chain(mut whens: Vec<Node>) -> Chain {
        let mut chain = whens.pop().expect("at least one when");
        set_tail(&mut chain, None);
        while let Some(mut when) = whens.pop() {
            set_tail(&mut when, Some(chain));
            chain = when;
        }
        Chain(chain)
    }

    fn set_tail(when: &mut Node, tail: Option<Node>) {
        while when.children.len() <= 2 {
            when.children.push(Child::Nil);
        }
        when.children[2] = optional_node(tail);
    }

    fn set_fallback(when: &mut Node, fallback: Node) {
        let Some(Child::Node(next)) = when.children.get_mut(2) else {
            set_tail(when, Some(fallback));
            return;
        };
        if next.r#type == "WHEN" {
            set_fallback(next, fallback);
        } else {
            when.children[2] = optional_node(Some(fallback));
        }
    }

    fn case_node(kind: &str, subject: Option<Node>, chain: Node) -> Node {
        let mut children = Vec::new();
        if kind == "CASE" {
            children.push(optional_node(subject));
        }
        children.push(optional_node(Some(chain)));
        node(kind, "case role", children)
    }

    fn when(body: Vec<Node>) -> Node {
        node(
            "WHEN",
            "when :value",
            vec![
                optional_node(Some(node("LIST", ":value", Vec::new()))),
                optional_node(Some(block(body))),
                Child::Nil,
            ],
        )
    }

    fn block(children: Vec<Node>) -> Node {
        node(
            "BLOCK",
            "",
            children
                .into_iter()
                .map(|child| optional_node(Some(child)))
                .collect(),
        )
    }

    fn value(source: &str) -> Node {
        node("LVAR", source, Vec::new())
    }

    fn call(source: &str) -> Node {
        node("FCALL", source, Vec::new())
    }

    fn optional_node(node: Option<Node>) -> Child {
        node.map(|node| Child::Node(Box::new(node)))
            .unwrap_or(Child::Nil)
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
