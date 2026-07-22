use crate::ast::Span;
use crate::syntax::cfg::{ControlFlowFacts, NodeEffect};
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

/// The proven nullability of one place at one CFG node. `unknown` is an
/// analysis boundary, not a synonym for `maybe_null`, which requires both a
/// null and non-null reaching definition.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NullableState {
    pub node_id: String,
    pub place_id: String,
    pub state: String,
    pub source_definition_ids: Vec<String>,
    pub complete: bool,
    pub unknown_reasons: Vec<String>,
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

/// Projects nullable state from CFG reaching definitions. This deliberately
/// recognizes only exact normalized null writes and direct assignment flow;
/// unresolved expressions remain `unknown` instead of being guessed nullable.
pub(crate) fn project_states(facts: &ControlFlowFacts) -> Vec<NullableState> {
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();
    let reaching = facts
        .reaching_definitions
        .iter()
        .map(|fact| ((fact.node_id.as_str(), fact.place_id.as_str()), &fact.definitions))
        .collect::<BTreeMap<_, _>>();
    let reachable = facts
        .reachability
        .iter()
        .map(|fact| (fact.node_id.as_str(), fact.reachable))
        .collect::<BTreeMap<_, _>>();
    let mut cache = BTreeMap::new();
    let mut states = BTreeMap::new();

    for ((node_id, place_id), definitions) in &reaching {
        let state = if reachable.get(node_id) == Some(&false) {
            DefinitionState::Unreachable
        } else {
            join_definitions(
                definitions,
                place_id,
                &effects,
                &reaching,
                &mut cache,
                &mut BTreeSet::new(),
            )
        };
        states.insert(
            (node_id.to_string(), place_id.to_string()),
            NullableState {
                node_id: node_id.to_string(),
                place_id: place_id.to_string(),
                state: state.name().to_string(),
                source_definition_ids: (*definitions).clone(),
                complete: state.complete(),
                unknown_reasons: state.unknown_reasons(),
            },
        );
    }

    states.into_values().collect()
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum DefinitionState {
    Unreachable,
    DefinitelyNull,
    DefinitelyNonNull,
    MaybeNull,
    Unknown,
}

impl DefinitionState {
    fn name(self) -> &'static str {
        match self {
            Self::Unreachable => "unreachable",
            Self::DefinitelyNull => "definitely_null",
            Self::DefinitelyNonNull => "definitely_non_null",
            Self::MaybeNull => "maybe_null",
            Self::Unknown => "unknown",
        }
    }

    fn complete(self) -> bool {
        !matches!(self, Self::Unknown)
    }

    fn unknown_reasons(self) -> Vec<String> {
        matches!(self, Self::Unknown)
            .then(|| vec!["unresolved_nullable_producer".to_string()])
            .unwrap_or_default()
    }
}

fn join_definitions(
    definitions: &[String],
    place_id: &str,
    effects: &BTreeMap<&str, &NodeEffect>,
    reaching: &BTreeMap<(&str, &str), &Vec<String>>,
    cache: &mut BTreeMap<(String, String), DefinitionState>,
    visiting: &mut BTreeSet<(String, String)>,
) -> DefinitionState {
    if definitions.is_empty() {
        return DefinitionState::Unknown;
    }

    let states = definitions
        .iter()
        .map(|node_id| definition_state(node_id, place_id, effects, reaching, cache, visiting))
        .collect::<BTreeSet<_>>();
    if states.contains(&DefinitionState::Unknown) {
        DefinitionState::Unknown
    } else if states.len() == 1 {
        *states.iter().next().expect("non-empty definition state set")
    } else {
        DefinitionState::MaybeNull
    }
}

fn definition_state(
    node_id: &str,
    place_id: &str,
    effects: &BTreeMap<&str, &NodeEffect>,
    reaching: &BTreeMap<(&str, &str), &Vec<String>>,
    cache: &mut BTreeMap<(String, String), DefinitionState>,
    visiting: &mut BTreeSet<(String, String)>,
) -> DefinitionState {
    let Some(effect) = effects.get(node_id) else {
        return DefinitionState::Unknown;
    };
    if !effect.writes.iter().any(|written| written == place_id) {
        return DefinitionState::Unknown;
    }
    let key = (node_id.to_string(), place_id.to_string());
    if let Some(state) = cache.get(&key) {
        return *state;
    }
    if !visiting.insert(key.clone()) {
        return DefinitionState::Unknown;
    }
    let state = if !effect.complete || effect.unknown_call {
        DefinitionState::Unknown
    } else if effect
        .write_value_hints
        .get(place_id)
        .is_some_and(|value| value == "nil" || value == "null")
    {
        DefinitionState::DefinitelyNull
    } else if effect
        .write_value_hints
        .get(place_id)
        .is_some_and(|value| definitely_non_null_literal(value))
    {
        DefinitionState::DefinitelyNonNull
    } else if let Some(source_id) = effect.write_sources.get(place_id) {
        let definitions = reaching
            .get(&(node_id, source_id.as_str()))
            .map(|definitions| definitions.as_slice())
            .unwrap_or_default();
        join_definitions(definitions, source_id, effects, reaching, cache, visiting)
    } else {
        DefinitionState::Unknown
    };
    visiting.remove(&key);
    cache.insert(key, state);
    state
}

fn definitely_non_null_literal(value: &str) -> bool {
    value == "true" || value == "false" || value.starts_with('"') || value.starts_with('\'')
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

    #[test]
    fn projects_exact_null_alias_join_unknown_and_unreachable_states() {
        let effect = |node_id: &str, place_id: &str| NodeEffect {
            node_id: node_id.to_string(),
            writes: vec![place_id.to_string()],
            complete: true,
            ..NodeEffect::default()
        };
        let mut null_write = effect("null-write", "p");
        null_write
            .write_value_hints
            .insert("p".to_string(), "nil".to_string());
        let mut non_null_write = effect("value-write", "p");
        non_null_write
            .write_value_hints
            .insert("p".to_string(), "\"present\"".to_string());
        let mut alias_write = effect("alias-write", "q");
        alias_write
            .write_sources
            .insert("q".to_string(), "p".to_string());
        let wrong_write = effect("wrong-write", "q");
        let mut cycle_write = effect("cycle-write", "cycle");
        cycle_write
            .write_sources
            .insert("cycle".to_string(), "cycle".to_string());
        let facts = ControlFlowFacts {
            effects: vec![
                null_write,
                non_null_write,
                alias_write,
                wrong_write,
                cycle_write,
            ],
            reachability: vec![
                reachable("read-null", true),
                reachable("read-maybe", true),
                reachable("read-alias", true),
                reachable("read-unknown", true),
                reachable("read-dead", false),
                reachable("read-non-null", true),
                reachable("read-missing", true),
                reachable("read-wrong", true),
                reachable("read-cycle", true),
            ],
            reaching_definitions: vec![
                reaching("read-null", "p", &["null-write"]),
                reaching("read-maybe", "p", &["null-write", "value-write"]),
                reaching("alias-write", "p", &["null-write"]),
                reaching("read-alias", "q", &["alias-write"]),
                reaching("read-unknown", "p", &[]),
                reaching("read-dead", "p", &["null-write"]),
                reaching("read-non-null", "p", &["value-write"]),
                reaching("read-missing", "p", &["missing-write"]),
                reaching("read-wrong", "p", &["wrong-write"]),
                reaching("cycle-write", "cycle", &["cycle-write"]),
                reaching("read-cycle", "cycle", &["cycle-write"]),
            ],
            ..ControlFlowFacts::default()
        };

        let states = project_states(&facts)
            .into_iter()
            .map(|state| ((state.node_id.clone(), state.place_id.clone()), state))
            .collect::<BTreeMap<_, _>>();

        assert_eq!(states[&key("read-null", "p")].state, "definitely_null");
        assert_eq!(states[&key("read-maybe", "p")].state, "maybe_null");
        assert_eq!(
            states[&key("read-non-null", "p")].state,
            "definitely_non_null"
        );
        assert_eq!(states[&key("read-alias", "q")].state, "definitely_null");
        assert_eq!(states[&key("read-unknown", "p")].state, "unknown");
        assert!(!states[&key("read-unknown", "p")].complete);
        assert_eq!(states[&key("read-dead", "p")].state, "unreachable");
        assert_eq!(states[&key("read-missing", "p")].state, "unknown");
        assert_eq!(states[&key("read-wrong", "p")].state, "unknown");
        assert_eq!(states[&key("read-cycle", "cycle")].state, "unknown");
    }

    fn key(node_id: &str, place_id: &str) -> (String, String) {
        (node_id.to_string(), place_id.to_string())
    }

    fn reachable(node_id: &str, value: bool) -> crate::syntax::cfg::ReachabilityFact {
        crate::syntax::cfg::ReachabilityFact {
            node_id: node_id.to_string(),
            file: String::new(),
            function: String::new(),
            owner: String::new(),
            reachable: value,
        }
    }

    fn reaching(
        node_id: &str,
        place_id: &str,
        definitions: &[&str],
    ) -> crate::syntax::cfg::ReachingDefinitionFact {
        crate::syntax::cfg::ReachingDefinitionFact {
            node_id: node_id.to_string(),
            file: String::new(),
            function: String::new(),
            owner: String::new(),
            place_id: place_id.to_string(),
            definitions: definitions.iter().map(|value| (*value).to_string()).collect(),
        }
    }
}
