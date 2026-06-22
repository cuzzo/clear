use super::{local_flow::MethodSummary, LocalComplexityScore};
use crate::ast::{self, Node};
use std::collections::BTreeMap;

pub(crate) fn local_complexity_scores_from_methods(
    methods: &[MethodSummary],
) -> BTreeMap<String, LocalComplexityScore> {
    methods
        .iter()
        .map(|method| (method.id.clone(), LocalComplexityScorer.score(&method.node)))
        .collect()
}

struct LocalComplexityScorer;

impl LocalComplexityScorer {
    fn score(&self, method_node: &Node) -> LocalComplexityScore {
        let mut signals = BTreeMap::new();
        let score = self.score_node(method_node, 0, &mut signals);
        LocalComplexityScore {
            score: (score * 10.0).round() / 10.0,
            signals,
        }
    }

    fn score_node(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        if skip_nested(node) {
            return 0.0;
        }

        if branch(node) {
            increment(signals, "branches");
            if nesting > 0 {
                increment(signals, "nested");
            }
            return branch_cost(nesting)
                + self.predicate_cost(node, signals)
                + self.score_children(node, nesting + 1, signals);
        }

        if loop_node(node) {
            increment(signals, "loops");
            if normalized_iterator(node) {
                return self.score_children(node, nesting, signals);
            }
            if nesting > 0 {
                increment(signals, "nested");
            }
            return branch_cost(nesting) + self.score_children(node, nesting + 1, signals);
        }

        if case_node(node) {
            increment(signals, "cases");
            return 0.5 + self.score_children(node, nesting + 1, signals);
        }

        if rescue_node(node) {
            increment(signals, "rescues");
            return branch_cost(nesting) + self.score_children(node, nesting + 1, signals);
        }

        if boolean_node(node) {
            increment(signals, "boolean_ops");
            return 0.25 + self.score_children(node, nesting, signals);
        }

        self.score_children(node, nesting, signals)
    }

    fn score_children(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        compensated_sum(
            node.children
                .iter()
                .filter_map(ast::node)
                .map(|child| self.score_node(child, nesting, signals)),
        )
    }

    fn predicate_cost(&self, node: &Node, signals: &mut BTreeMap<String, usize>) -> f64 {
        let condition = node.children.first().and_then(ast::node);
        let Some(condition) = condition else {
            return 0.0;
        };
        let booleans = boolean_count(condition);
        *signals.entry("boolean_ops".to_string()).or_default() += booleans;
        0.5 * booleans as f64
    }
}

fn increment(signals: &mut BTreeMap<String, usize>, key: &str) {
    *signals.entry(key.to_string()).or_default() += 1;
}

fn branch_cost(nesting: usize) -> f64 {
    1.1 + nesting as f64
}

fn skip_nested(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "CLASS" | "MODULE" | "LAMBDA")
}

fn branch(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "IF" | "UNLESS")
}

fn loop_node(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "ITER" | "FOR" | "WHILE" | "UNTIL")
}

fn normalized_iterator(node: &Node) -> bool {
    node.r#type == "ITER"
}

fn case_node(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "CASE" | "CASE2" | "WHEN")
}

fn rescue_node(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "RESCUE" | "RESBODY" | "ENSURE")
}

fn boolean_node(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "AND" | "OR")
}

fn boolean_count(node: &Node) -> usize {
    let self_count = usize::from(boolean_node(node));
    self_count
        + node
            .children
            .iter()
            .filter_map(ast::node)
            .map(boolean_count)
            .sum::<usize>()
}

fn compensated_sum(values: impl IntoIterator<Item = f64>) -> f64 {
    let mut sum = 0.0f64;
    let mut compensation = 0.0f64;
    for value in values {
        let next = sum + value;
        if sum.abs() >= value.abs() {
            compensation += (sum - next) + value;
        } else {
            compensation += (value - next) + sum;
        }
        sum = next;
    }
    sum + compensation
}
