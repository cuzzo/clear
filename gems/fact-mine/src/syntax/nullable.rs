use crate::ast::Span;
use crate::syntax::cfg::ControlFlowFacts;
use crate::syntax::redundant_nil_guard::NullableRefinementSeed;
use std::collections::{BTreeMap, BTreeSet};

/// A branch-local nullability proof. The state applies only to the selected
/// outgoing branch; consumers must invalidate it when the subject is written.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NullableRefinement {
    pub place_id: String,
    pub condition_node_id: String,
    pub edge: String,
    pub state_on_edge: String,
    pub proof_kind: String,
    pub source_span: Span,
    pub complete: bool,
}

/// Projects normalized guard semantics onto stable CFG places. The guard
/// extractor owns predicate interpretation; this module only joins its seeds
/// to already-built CFG identities.
pub(crate) fn project_refinements(
    seeds: &[NullableRefinementSeed],
    facts: &ControlFlowFacts,
) -> Vec<NullableRefinement> {
    let place_names = facts
        .places
        .iter()
        .map(|place| (place.id.clone(), place.name.clone()))
        .collect::<BTreeMap<_, _>>();
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();

    let mut rows = BTreeSet::new();
    for seed in seeds {
        let candidate_nodes = facts
            .nodes
            .iter()
            .filter(|node| {
                node.function == seed.function
                    && span_contains(node.span, seed.condition_span)
                    && node.role.ends_with("condition")
            })
            .collect::<Vec<_>>();
        for node in candidate_nodes {
            let Some(effect) = effects.get(node.id.as_str()) else {
                continue;
            };
            let places = effect
                .reads
                .iter()
                .chain(effect.writes.iter())
                .filter(|place_id| place_names.get(*place_id) == Some(&seed.subject))
                .cloned()
                .collect::<BTreeSet<_>>();
            for place_id in places {
                rows.insert((
                    place_id,
                    node.id.clone(),
                    seed.edge.clone(),
                    seed.state_on_edge.clone(),
                    seed.proof_kind.clone(),
                    seed.condition_span,
                    effect.complete,
                ));
            }
        }
    }

    rows.into_iter()
        .map(|(
            place_id,
            condition_node_id,
            edge,
            state_on_edge,
            proof_kind,
            source_span,
            complete,
        )| {
            NullableRefinement {
                place_id,
                condition_node_id,
                edge,
                state_on_edge,
                proof_kind,
                source_span,
                complete,
            }
        })
        .collect()
}

fn span_contains(outer: Span, inner: Span) -> bool {
    (outer[0], outer[1]) <= (inner[0], inner[1]) && (outer[2], outer[3]) >= (inner[2], inner[3])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::cfg::{ControlFlowNode, NodeEffect, Place};

    #[test]
    fn projects_only_a_subject_read_by_the_matching_condition() {
        let facts = ControlFlowFacts {
            nodes: vec![ControlFlowNode {
                id: "branch".to_string(),
                file: "demo.c".to_string(),
                function: "use_value".to_string(),
                owner: "".to_string(),
                kind: "branch".to_string(),
                role: "if_condition".to_string(),
                line: 2,
                span: [2, 0, 2, 14],
                source: "if (value != 0)".to_string(),
            }],
            places: vec![Place {
                id: "place:value".to_string(),
                file: "demo.c".to_string(),
                function: "use_value".to_string(),
                owner: "".to_string(),
                kind: "local".to_string(),
                name: "value".to_string(),
                declaration_span: [1, 0, 1, 1],
            }],
            effects: vec![NodeEffect {
                node_id: "branch".to_string(),
                file: "demo.c".to_string(),
                function: "use_value".to_string(),
                owner: "".to_string(),
                reads: vec!["place:value".to_string()],
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_refinements(
            &[NullableRefinementSeed {
                function: "use_value".to_string(),
                subject: "value".to_string(),
                condition_span: [2, 0, 2, 14],
                edge: "then".to_string(),
                state_on_edge: "definitely_non_null".to_string(),
                proof_kind: "nil_comparison".to_string(),
            }],
            &facts,
        );

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].place_id, "place:value");
        assert_eq!(rows[0].state_on_edge, "definitely_non_null");
    }
}
