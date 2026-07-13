use crate::syntax::Span;
use serde::{Deserialize, Serialize};

/// Language-owned vocabulary needed to interpret normalized callback regions.
/// The CFG algorithms consume this profile without knowing which language
/// supplied it. Concrete values live only in `syntax/<language>.rs`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ControlFlowProfile {
    pub(crate) iterator_messages: &'static [&'static str],
    pub(crate) ignored_callback_body_sources: &'static [&'static str],
}

impl ControlFlowProfile {
    pub(crate) const fn neutral() -> Self {
        Self {
            iterator_messages: &[],
            ignored_callback_body_sources: &[],
        }
    }

    pub(crate) fn neutral_ref() -> &'static Self {
        static NEUTRAL: ControlFlowProfile = ControlFlowProfile::neutral();
        &NEUTRAL
    }

    pub(crate) fn iterator_message(&self, message: &str) -> bool {
        self.iterator_messages.contains(&message)
    }

    pub(crate) fn ignored_callback_body_source(&self, source: &str) -> bool {
        self.ignored_callback_body_sources.contains(&source)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ControlFlowFacts {
    pub nodes: Vec<ControlFlowNode>,
    pub edges: Vec<ControlFlowEdge>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ControlFlowNode {
    pub id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub kind: String,
    pub role: String,
    pub line: usize,
    pub span: Span,
    pub source: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ControlFlowEdge {
    pub file: String,
    pub function: String,
    pub owner: String,
    pub from: String,
    pub to: String,
    pub kind: String,
    pub line: usize,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ControlFlowMetric {
    pub file: String,
    pub function: String,
    pub owner: String,
    pub line: usize,
    pub span: Span,
    pub cyclomatic_complexity: usize,
    pub path_pressure: usize,
    pub decision_points: usize,
    pub branch_points: usize,
    pub loop_points: usize,
    pub case_points: usize,
    pub exception_points: usize,
    pub callback_points: usize,
    pub terminal_edges: usize,
    pub disconnected_nodes: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_facts_are_empty() {
        let facts = ControlFlowFacts::default();
        assert!(facts.nodes.is_empty());
        assert!(facts.edges.is_empty());
    }
}
