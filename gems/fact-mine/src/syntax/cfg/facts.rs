use crate::syntax::Span;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

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
    pub places: Vec<Place>,
    pub effects: Vec<NodeEffect>,
    pub reachability: Vec<ReachabilityFact>,
    pub dominators: Vec<DominatorFact>,
    pub reaching_definitions: Vec<ReachingDefinitionFact>,
    pub def_use: Vec<DefUseFact>,
    pub liveness: Vec<LivenessFact>,
    pub flow_types: Vec<FlowTypeFact>,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct Place {
    pub id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub kind: String,
    pub name: String,
    pub declaration_span: Span,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct NodeEffect {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub reads: Vec<String>,
    pub writes: Vec<String>,
    pub mutations: Vec<String>,
    pub write_type_hints: BTreeMap<String, String>,
    /// Exact normalized scalar values for direct literal assignments. This is
    /// intentionally bounded; expressions and calls are not guessed.
    #[serde(default)]
    pub write_value_hints: BTreeMap<String, String>,
    /// Direct value-flow edges for assignments such as `destination = source`.
    /// Calls and compound expressions are intentionally excluded.
    pub write_sources: BTreeMap<String, String>,
    pub unknown_call: bool,
    pub complete: bool,
    pub unknown_reasons: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ReachabilityFact {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub reachable: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DominatorFact {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub immediate_dominator: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ReachingDefinitionFact {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub place_id: String,
    pub definitions: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DefUseFact {
    pub definition_node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub place_id: String,
    pub uses: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LivenessFact {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub live_in: Vec<String>,
    pub live_out: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FlowTypeFact {
    pub node_id: String,
    pub file: String,
    pub function: String,
    pub owner: String,
    pub place_id: String,
    pub types: Vec<String>,
    pub complete: bool,
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
