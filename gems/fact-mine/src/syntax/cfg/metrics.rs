use super::{exits, ControlFlowEdge, ControlFlowFacts, ControlFlowMetric, ControlFlowNode};
use crate::syntax::Span;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

const PATH_PRESSURE_CAP: usize = 1_000_000;

pub(crate) fn metrics(facts: &ControlFlowFacts) -> Vec<ControlFlowMetric> {
    let mut groups = BTreeMap::<FunctionKey, FunctionGraph<'_>>::new();

    for node in &facts.nodes {
        groups
            .entry(FunctionKey::from_node(node))
            .or_default()
            .nodes
            .push(node);
    }
    for edge in &facts.edges {
        groups
            .entry(FunctionKey::from_edge(edge))
            .or_default()
            .edges
            .push(edge);
    }

    groups
        .into_values()
        .filter(|graph| !graph.nodes.is_empty())
        .map(metric_for_graph)
        .collect()
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct FunctionKey {
    file: String,
    owner: String,
    function: String,
}

impl FunctionKey {
    fn from_node(node: &ControlFlowNode) -> Self {
        Self {
            file: node.file.clone(),
            owner: node.owner.clone(),
            function: node.function.clone(),
        }
    }

    fn from_edge(edge: &ControlFlowEdge) -> Self {
        Self {
            file: edge.file.clone(),
            owner: edge.owner.clone(),
            function: edge.function.clone(),
        }
    }
}

#[derive(Default)]
struct FunctionGraph<'a> {
    nodes: Vec<&'a ControlFlowNode>,
    edges: Vec<&'a ControlFlowEdge>,
}

fn metric_for_graph(graph: FunctionGraph<'_>) -> ControlFlowMetric {
    let identity = graph
        .nodes
        .iter()
        .find(|node| node.kind == "entry")
        .copied()
        .or_else(|| graph.nodes.iter().min_by_key(|node| node.line).copied())
        .expect("metric graph has at least one node");
    let node_count = graph.nodes.len();
    let edge_count = graph.edges.len();
    let components = undirected_component_count(&graph).max(1);
    let disconnected_nodes = disconnected_nodes(&graph);
    let branch_points = count_kind(&graph, "branch");
    let loop_points = count_kind(&graph, "loop");
    let case_points = count_kind(&graph, "case");
    let exception_points = count_kind(&graph, "exception");
    let callback_points = count_kind(&graph, "callback");
    let terminal_edges = graph
        .edges
        .iter()
        .filter(|edge| exits::terminal_edge_kind(&edge.kind))
        .count();

    ControlFlowMetric {
        file: identity.file.clone(),
        function: identity.function.clone(),
        owner: identity.owner.clone(),
        line: identity.line,
        span: metric_span(&graph, identity.span),
        cyclomatic_complexity: cyclomatic_complexity(node_count, edge_count, components),
        path_pressure: path_pressure(&graph),
        decision_points: branch_points
            + loop_points
            + case_points
            + exception_points
            + callback_points,
        branch_points,
        loop_points,
        case_points,
        exception_points,
        callback_points,
        terminal_edges,
        disconnected_nodes,
    }
}

fn cyclomatic_complexity(node_count: usize, edge_count: usize, components: usize) -> usize {
    let value = edge_count as isize - node_count as isize + (2 * components) as isize;
    value.max(1) as usize
}

fn path_pressure(graph: &FunctionGraph<'_>) -> usize {
    let mut outgoing = BTreeMap::<&str, Vec<&ControlFlowEdge>>::new();
    for edge in &graph.edges {
        outgoing.entry(edge.from.as_str()).or_default().push(*edge);
    }

    graph
        .nodes
        .iter()
        .filter_map(|node| pressure_choices(outgoing.get(node.id.as_str()).map(Vec::as_slice)))
        .fold(1usize, |acc, choices| {
            acc.saturating_mul(choices).min(PATH_PRESSURE_CAP)
        })
}

fn pressure_choices(edges: Option<&[&ControlFlowEdge]>) -> Option<usize> {
    let mut choices = BTreeSet::new();
    for edge in edges.unwrap_or_default() {
        if path_choice_edge(&edge.kind) {
            choices.insert((edge.kind.as_str(), edge.to.as_str()));
        }
    }
    (choices.len() > 1).then_some(choices.len())
}

fn path_choice_edge(kind: &str) -> bool {
    matches!(
        kind,
        "branch_true"
            | "branch_false"
            | "case_arm"
            | "case_default"
            | "loop_body"
            | "loop_exit"
            | "try_body"
            | "rescue_handler"
            | "rescue_else"
    )
}

fn count_kind(graph: &FunctionGraph<'_>, kind: &str) -> usize {
    graph.nodes.iter().filter(|node| node.kind == kind).count()
}

fn disconnected_nodes(graph: &FunctionGraph<'_>) -> usize {
    let Some(entry) = graph.nodes.iter().find(|node| node.kind == "entry") else {
        return 0;
    };
    let mut outgoing = BTreeMap::<&str, Vec<&str>>::new();
    for edge in &graph.edges {
        outgoing
            .entry(edge.from.as_str())
            .or_default()
            .push(edge.to.as_str());
    }

    let mut seen = BTreeSet::new();
    let mut queue = VecDeque::from([entry.id.as_str()]);
    while let Some(id) = queue.pop_front() {
        if !seen.insert(id) {
            continue;
        }
        for target in outgoing.get(id).into_iter().flatten() {
            queue.push_back(target);
        }
    }

    graph
        .nodes
        .iter()
        .filter(|node| !seen.contains(node.id.as_str()))
        .count()
}

fn undirected_component_count(graph: &FunctionGraph<'_>) -> usize {
    let node_ids = graph
        .nodes
        .iter()
        .map(|node| node.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut adjacency = BTreeMap::<&str, Vec<&str>>::new();
    for edge in &graph.edges {
        if node_ids.contains(edge.from.as_str()) && node_ids.contains(edge.to.as_str()) {
            adjacency
                .entry(edge.from.as_str())
                .or_default()
                .push(edge.to.as_str());
            adjacency
                .entry(edge.to.as_str())
                .or_default()
                .push(edge.from.as_str());
        }
    }

    let mut seen = BTreeSet::new();
    let mut components = 0usize;
    for id in node_ids {
        if seen.contains(id) {
            continue;
        }
        components += 1;
        let mut queue = VecDeque::from([id]);
        while let Some(current) = queue.pop_front() {
            if !seen.insert(current) {
                continue;
            }
            for next in adjacency.get(current).into_iter().flatten() {
                queue.push_back(next);
            }
        }
    }
    components
}

fn metric_span(graph: &FunctionGraph<'_>, fallback: Span) -> Span {
    graph
        .nodes
        .iter()
        .find(|node| node.kind == "entry")
        .map(|node| node.span)
        .unwrap_or(fallback)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linear_graph_has_base_complexity() {
        let facts = facts(
            vec![
                node("entry", "entry"),
                node("stmt", "statement"),
                node("exit", "exit"),
            ],
            vec![
                edge("entry", "stmt", "entry"),
                edge("stmt", "exit", "fallthrough"),
            ],
        );

        let metric = only_metric(&facts);

        assert_eq!(metric.cyclomatic_complexity, 1);
        assert_eq!(metric.path_pressure, 1);
        assert_eq!(metric.decision_points, 0);
    }

    #[test]
    fn branch_graph_counts_cyclomatic_and_pressure() {
        let facts = facts(
            vec![
                node("entry", "entry"),
                node("branch", "branch"),
                node("then", "statement"),
                node("else", "statement"),
                node("exit", "exit"),
            ],
            vec![
                edge("entry", "branch", "entry"),
                edge("branch", "then", "branch_true"),
                edge("branch", "else", "branch_false"),
                edge("then", "exit", "fallthrough"),
                edge("else", "exit", "fallthrough"),
            ],
        );

        let metric = only_metric(&facts);

        assert_eq!(metric.cyclomatic_complexity, 2);
        assert_eq!(metric.path_pressure, 2);
        assert_eq!(metric.decision_points, 1);
        assert_eq!(metric.branch_points, 1);
    }

    #[test]
    fn exception_and_callback_nodes_are_reported_as_signals() {
        let facts = facts(
            vec![
                node("entry", "entry"),
                node("rescue", "exception"),
                node("callback", "callback"),
                node("exit", "exit"),
            ],
            vec![
                edge("entry", "rescue", "entry"),
                edge("rescue", "callback", "try_body"),
                edge("rescue", "exit", "rescue_handler"),
                edge("callback", "exit", "callback_return"),
            ],
        );

        let metric = only_metric(&facts);

        assert_eq!(metric.exception_points, 1);
        assert_eq!(metric.callback_points, 1);
        assert_eq!(metric.path_pressure, 2);
    }

    #[test]
    fn disconnected_nodes_are_reported() {
        let facts = facts(
            vec![
                node("entry", "entry"),
                node("exit", "exit"),
                node("orphan", "statement"),
            ],
            vec![edge("entry", "exit", "fallthrough")],
        );

        let metric = only_metric(&facts);

        assert_eq!(metric.disconnected_nodes, 1);
        assert_eq!(metric.cyclomatic_complexity, 2);
    }

    #[test]
    fn terminal_edges_are_counted() {
        let facts = facts(
            vec![
                node("entry", "entry"),
                node("return", "jump"),
                node("exit", "exit"),
            ],
            vec![
                edge("entry", "return", "entry"),
                edge("return", "exit", "return"),
            ],
        );

        let metric = only_metric(&facts);

        assert_eq!(metric.terminal_edges, 1);
    }

    fn only_metric(facts: &ControlFlowFacts) -> ControlFlowMetric {
        let metrics = super::metrics(facts);
        assert_eq!(metrics.len(), 1);
        metrics.into_iter().next().unwrap()
    }

    fn facts(nodes: Vec<ControlFlowNode>, edges: Vec<ControlFlowEdge>) -> ControlFlowFacts {
        ControlFlowFacts { nodes, edges }
    }

    fn node(id: &str, kind: &str) -> ControlFlowNode {
        ControlFlowNode {
            id: id.to_string(),
            file: "test.rb".to_string(),
            function: "run".to_string(),
            owner: "Example".to_string(),
            kind: kind.to_string(),
            role: String::new(),
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
