use super::{exits, ControlFlowFacts};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn errors(facts: &ControlFlowFacts) -> Vec<String> {
    let node_ids = facts
        .nodes
        .iter()
        .map(|node| node.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut errors = Vec::new();

    for edge in &facts.edges {
        if !node_ids.contains(edge.from.as_str()) {
            errors.push(format!(
                "edge {} -> {} has missing source",
                edge.from, edge.to
            ));
        }
        if !node_ids.contains(edge.to.as_str()) {
            errors.push(format!(
                "edge {} -> {} has missing target",
                edge.from, edge.to
            ));
        }
    }

    let mut terminal_edges = BTreeMap::<(&str, &str), usize>::new();
    for edge in &facts.edges {
        if exits::terminal_edge_kind(&edge.kind) {
            *terminal_edges
                .entry((edge.from.as_str(), edge.kind.as_str()))
                .or_default() += 1;
        }
    }
    for ((from, kind), count) in terminal_edges {
        if count > 1 {
            errors.push(format!(
                "{from} has {count} duplicate {kind} terminal edges"
            ));
        }
    }

    errors
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::cfg::{ControlFlowEdge, ControlFlowNode};

    #[test]
    fn accepts_valid_graph() {
        let facts = facts(
            vec![node("entry"), node("return"), node("exit")],
            vec![
                edge("entry", "return", "entry"),
                edge("return", "exit", "return"),
            ],
        );

        assert!(errors(&facts).is_empty());
    }

    #[test]
    fn rejects_missing_edge_endpoints() {
        let facts = facts(
            vec![node("entry")],
            vec![edge("missing-source", "missing-target", "fallthrough")],
        );

        let errors = errors(&facts);

        assert_eq!(errors.len(), 2);
        assert!(errors[0].contains("missing source"));
        assert!(errors[1].contains("missing target"));
    }

    #[test]
    fn rejects_duplicate_terminal_edges_from_same_source() {
        let facts = facts(
            vec![node("return"), node("exit")],
            vec![
                edge("return", "exit", "return"),
                edge("return", "exit", "return"),
            ],
        );

        let errors = errors(&facts);

        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("duplicate return terminal edges"));
    }

    fn facts(nodes: Vec<ControlFlowNode>, edges: Vec<ControlFlowEdge>) -> ControlFlowFacts {
        ControlFlowFacts { nodes, edges }
    }

    fn node(id: &str) -> ControlFlowNode {
        ControlFlowNode {
            id: id.to_string(),
            file: "test.rb".to_string(),
            function: "run".to_string(),
            owner: "Example".to_string(),
            kind: "statement".to_string(),
            role: "linear_statement".to_string(),
            line: 1,
            span: [1, 0, 1, 1],
            source: String::new(),
        }
    }

    fn edge(from: &str, to: &str, kind: &str) -> ControlFlowEdge {
        ControlFlowEdge {
            file: "test.rb".to_string(),
            function: "run".to_string(),
            owner: "Example".to_string(),
            from: from.to_string(),
            to: to.to_string(),
            kind: kind.to_string(),
            line: 1,
            span: [1, 0, 1, 1],
        }
    }
}
