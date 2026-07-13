pub(crate) mod branches;
pub(crate) mod builder;
pub(crate) mod callbacks;
pub(crate) mod cases;
pub(crate) mod cursor;
pub(crate) mod dataflow;
pub(crate) mod effects;
pub(crate) mod exceptions;
pub(crate) mod exits;
pub(crate) mod facts;
pub(crate) mod loops;
pub(crate) mod metrics;
pub(crate) mod projection;
pub(crate) mod short_circuit;
pub(crate) mod statements;
pub(crate) mod validation;
pub(crate) mod worklist;

pub(crate) use cursor::MethodCursor;
pub(crate) use facts::ControlFlowProfile;
pub use facts::{
    ControlFlowEdge, ControlFlowFacts, ControlFlowMetric, ControlFlowNode, DefUseFact,
    DominatorFact, FlowTypeFact, LivenessFact, NodeEffect, Place, ReachabilityFact,
    ReachingDefinitionFact,
};

use crate::syntax::{local_flow::MethodSummary, normalized_behavior::NormalizedLanguageBehavior};

pub(crate) fn build(
    methods: &[MethodSummary],
    behavior: &dyn NormalizedLanguageBehavior,
) -> ControlFlowFacts {
    let mut facts = builder::build(methods, behavior);
    effects::extract(methods, behavior.cfg_profile(), &mut facts);
    dataflow::derive(&mut facts);
    facts
}

pub(crate) fn metrics(facts: &ControlFlowFacts) -> Vec<ControlFlowMetric> {
    metrics::metrics(facts)
}
