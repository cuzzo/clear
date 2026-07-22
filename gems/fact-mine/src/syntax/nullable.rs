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

/// A callable-level result proven from return-node reads and nullable CFG
/// state. A summary is emitted only for an explicit return of a tracked
/// place; unknown return expressions stay outside this contract.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NullableSummary {
    pub function: String,
    pub owner: String,
    pub return_state: String,
    pub source_definition_ids: Vec<String>,
    pub complete: bool,
    pub unknown_reasons: Vec<String>,
}

/// A normalized nullable-sensitive operation before it is joined to CFG place
/// identities and the current nullable state.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct NullableOperationSeed {
    pub(crate) function: String,
    pub(crate) span: Span,
    pub(crate) subject: String,
    pub(crate) operation_kind: String,
    pub(crate) nil_behavior: String,
}

/// A nil-sensitive operation joined to its stable CFG place and state.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NullableOperation {
    pub node_id: String,
    pub path: String,
    pub span: Span,
    pub place_id: String,
    pub operation_kind: String,
    pub nil_behavior: String,
    pub state_at_operation: String,
    pub complete: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct PresenceCorrelation {
    pub group_id: String,
    pub value_place_id: String,
    pub presence_place_id: String,
    pub semantics: String,
    pub branch_refinement: String,
    pub complete: bool,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(crate) struct PresenceCorrelationSeed {
    pub(crate) function: String,
    pub(crate) span: Span,
    pub(crate) value_subject: String,
    pub(crate) presence_subject: String,
    pub(crate) semantics: String,
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
        .map(
            |(
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
            },
        )
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
        .map(|fact| {
            (
                (fact.node_id.as_str(), fact.place_id.as_str()),
                &fact.definitions,
            )
        })
        .collect::<BTreeMap<_, _>>();
    let reachable = facts
        .reachability
        .iter()
        .map(|fact| (fact.node_id.as_str(), fact.reachable))
        .collect::<BTreeMap<_, _>>();
    let mut cache = BTreeMap::new();
    let mut states = BTreeMap::new();

    for ((node_id, place_id), definitions) in &reaching {
        let result = if reachable.get(node_id) == Some(&false) {
            DefinitionResult::unreachable()
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
        let complete = result.complete();
        let unknown_reasons = result.unknown_reasons();
        states.insert(
            (node_id.to_string(), place_id.to_string()),
            NullableState {
                node_id: node_id.to_string(),
                place_id: place_id.to_string(),
                state: result.state.name().to_string(),
                source_definition_ids: result.roots.into_iter().collect(),
                complete,
                unknown_reasons,
            },
        );
    }

    states.into_values().collect()
}

/// Collapses the already-projected return-node states into one conservative
/// summary per callable. This is a pure public-fact projection: no source,
/// AST, or call-graph traversal is replayed here.
pub(crate) fn project_summaries(
    facts: &ControlFlowFacts,
    states: &[NullableState],
) -> Vec<NullableSummary> {
    let states_by_node = states
        .iter()
        .map(|state| ((state.node_id.as_str(), state.place_id.as_str()), state))
        .collect::<BTreeMap<_, _>>();
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();
    let mut returns = BTreeMap::<(String, String), Vec<&NullableState>>::new();

    for node in facts.nodes.iter().filter(|node| node.role == "return") {
        let Some(effect) = effects.get(node.id.as_str()) else {
            continue;
        };
        for place_id in &effect.reads {
            if let Some(state) = states_by_node.get(&(node.id.as_str(), place_id.as_str())) {
                returns
                    .entry((node.owner.clone(), node.function.clone()))
                    .or_default()
                    .push(state);
            }
        }
    }

    returns
        .into_iter()
        .map(|((owner, function), states)| {
            let state = join_projected_states(states.iter().map(|state| state.state.as_str()));
            let complete = states.iter().all(|state| state.complete)
                && !matches!(state, DefinitionState::Unknown);
            let source_definition_ids = states
                .iter()
                .flat_map(|state| state.source_definition_ids.iter().cloned())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
            let unknown_reasons = states
                .iter()
                .flat_map(|state| state.unknown_reasons.iter().cloned())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
            NullableSummary {
                function,
                owner,
                return_state: state.name().to_string(),
                source_definition_ids,
                complete,
                unknown_reasons,
            }
        })
        .collect()
}

/// Joins language-owned normalized operation descriptors to existing CFG reads
/// and state facts. A descriptor whose subject cannot be resolved to the
/// exact CFG place is retained as an incomplete unknown boundary.
pub(crate) fn project_operations(
    seeds: &[NullableOperationSeed],
    facts: &ControlFlowFacts,
    states: &[NullableState],
) -> Vec<NullableOperation> {
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();
    let places = facts
        .places
        .iter()
        .map(|place| (place.id.as_str(), place.name.as_str()))
        .collect::<BTreeMap<_, _>>();
    let state_by_place = states
        .iter()
        .map(|state| ((state.node_id.as_str(), state.place_id.as_str()), state))
        .collect::<BTreeMap<_, _>>();
    let mut rows = BTreeSet::new();

    for seed in seeds {
        let nodes = facts
            .nodes
            .iter()
            .filter(|node| node.function == seed.function)
            .filter(|node| node.role != "function_entry" && node.role != "function_exit")
            .filter(|node| span_contains(node.span, seed.span))
            .collect::<Vec<_>>();
        for node in nodes {
            let Some(effect) = effects.get(node.id.as_str()) else {
                continue;
            };
            let place_id = effect
                .reads
                .iter()
                .find(|place_id| places.get(place_id.as_str()) == Some(&seed.subject.as_str()));
            let Some(place_id) = place_id else {
                rows.insert((
                    node.id.clone(),
                    node.file.clone(),
                    node.span,
                    String::new(),
                    seed.operation_kind.clone(),
                    "unknown".to_string(),
                    "unknown".to_string(),
                    false,
                ));
                continue;
            };
            // C/C++ normalize both a local function-pointer invocation and a
            // direct bare function call as VCALL.  Only the former has a
            // definition for the callee's local place at this node.  Do not
            // reinterpret an unresolved direct function as a nullable value
            // invocation merely because its syntactic call form is bare.
            if seed.operation_kind == "function_pointer_call"
                && !facts.reaching_definitions.iter().any(|fact| {
                    fact.node_id == node.id
                        && fact.place_id == *place_id
                        && !fact.definitions.is_empty()
                })
            {
                continue;
            }
            let state = state_by_place
                .get(&(node.id.as_str(), place_id.as_str()))
                .copied();
            rows.insert((
                node.id.clone(),
                node.file.clone(),
                node.span,
                place_id.clone(),
                seed.operation_kind.clone(),
                seed.nil_behavior.clone(),
                state
                    .map(|state| state.state.clone())
                    .unwrap_or_else(|| "unknown".to_string()),
                state.is_some_and(|state| state.complete) && effect.complete,
            ));
        }
    }

    rows.into_iter()
        .map(
            |(node_id, path, span, place_id, operation_kind, nil_behavior, state_at_operation, complete)| {
                NullableOperation {
                    node_id,
                    path,
                    span,
                    place_id,
                    operation_kind,
                    nil_behavior,
                    state_at_operation,
                    complete,
                }
            },
        )
        .collect()
}

pub(crate) fn project_presence_correlations(seeds: &[PresenceCorrelationSeed], facts: &ControlFlowFacts) -> Vec<PresenceCorrelation> {
    let places = facts.places.iter().map(|place| (place.id.as_str(), place.name.as_str())).collect::<BTreeMap<_, _>>();
    let effects = facts.effects.iter().map(|effect| (effect.node_id.as_str(), effect)).collect::<BTreeMap<_, _>>();
    let mut rows = BTreeSet::new();
    for seed in seeds {
        for node in facts.nodes.iter().filter(|node| node.function == seed.function && span_contains(node.span, seed.span)) {
            let Some(effect) = effects.get(node.id.as_str()) else { continue; };
            let place_for = |subject: &str| effect.reads.iter().chain(effect.writes.iter())
                .find(|place_id| places.get(place_id.as_str()) == Some(&subject)).cloned();
            let (Some(value_place_id), Some(presence_place_id)) = (place_for(&seed.value_subject), place_for(&seed.presence_subject)) else { continue; };
            rows.insert((format!("presence:{}:{value_place_id}:{presence_place_id}", node.id), value_place_id, presence_place_id, seed.semantics.clone(), "presence_on_true".to_string(), effect.complete));
        }
    }
    rows.into_iter().map(|(group_id, value_place_id, presence_place_id, semantics, branch_refinement, complete)| PresenceCorrelation { group_id, value_place_id, presence_place_id, semantics, branch_refinement, complete }).collect()
}

fn join_projected_states<'a>(states: impl Iterator<Item = &'a str>) -> DefinitionState {
    let states = states
        .filter_map(definition_state_from_name)
        .collect::<BTreeSet<_>>();
    if states.contains(&DefinitionState::Unknown) || states.is_empty() {
        DefinitionState::Unknown
    } else if states.len() == 1 {
        *states.iter().next().expect("non-empty projected state set")
    } else {
        DefinitionState::MaybeNull
    }
}

fn definition_state_from_name(name: &str) -> Option<DefinitionState> {
    match name {
        "unreachable" => Some(DefinitionState::Unreachable),
        "definitely_null" => Some(DefinitionState::DefinitelyNull),
        "definitely_non_null" => Some(DefinitionState::DefinitelyNonNull),
        "maybe_null" => Some(DefinitionState::MaybeNull),
        "unknown" => Some(DefinitionState::Unknown),
        _ => None,
    }
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct DefinitionResult {
    state: DefinitionState,
    roots: BTreeSet<String>,
}

impl DefinitionResult {
    fn new(state: DefinitionState, roots: BTreeSet<String>) -> Self {
        Self { state, roots }
    }

    fn unknown() -> Self {
        Self::new(DefinitionState::Unknown, BTreeSet::new())
    }

    fn unreachable() -> Self {
        Self::new(DefinitionState::Unreachable, BTreeSet::new())
    }

    fn complete(&self) -> bool {
        self.state.complete()
    }

    fn unknown_reasons(&self) -> Vec<String> {
        self.state.unknown_reasons()
    }
}

fn join_definitions(
    definitions: &[String],
    place_id: &str,
    effects: &BTreeMap<&str, &NodeEffect>,
    reaching: &BTreeMap<(&str, &str), &Vec<String>>,
    cache: &mut BTreeMap<(String, String), DefinitionResult>,
    visiting: &mut BTreeSet<(String, String)>,
) -> DefinitionResult {
    if definitions.is_empty() {
        return DefinitionResult::unknown();
    }

    let results = definitions
        .iter()
        .map(|node_id| definition_state(node_id, place_id, effects, reaching, cache, visiting))
        .collect::<Vec<_>>();
    let states = results
        .iter()
        .map(|result| result.state)
        .collect::<BTreeSet<_>>();
    let roots = results
        .iter()
        .flat_map(|result| result.roots.iter().cloned())
        .collect();
    if states.contains(&DefinitionState::Unknown) {
        DefinitionResult::new(DefinitionState::Unknown, roots)
    } else if states.len() == 1 {
        DefinitionResult::new(
            *states
                .iter()
                .next()
                .expect("non-empty definition state set"),
            roots,
        )
    } else {
        DefinitionResult::new(DefinitionState::MaybeNull, roots)
    }
}

fn definition_state(
    node_id: &str,
    place_id: &str,
    effects: &BTreeMap<&str, &NodeEffect>,
    reaching: &BTreeMap<(&str, &str), &Vec<String>>,
    cache: &mut BTreeMap<(String, String), DefinitionResult>,
    visiting: &mut BTreeSet<(String, String)>,
) -> DefinitionResult {
    let Some(effect) = effects.get(node_id) else {
        return DefinitionResult::unknown();
    };
    if !effect.writes.iter().any(|written| written == place_id) {
        return DefinitionResult::unknown();
    }
    let key = (node_id.to_string(), place_id.to_string());
    if let Some(state) = cache.get(&key) {
        return state.clone();
    }
    if !visiting.insert(key.clone()) {
        return DefinitionResult::unknown();
    }
    let state = if effect
        .write_value_hints
        .get(place_id)
        .is_some_and(|value| value == "nil" || value == "null")
    {
        DefinitionResult::new(
            DefinitionState::DefinitelyNull,
            BTreeSet::from([node_id.to_string()]),
        )
    } else if let Some(contract) = effect.write_nullable_contracts.get(place_id) {
        let state = if contract == "non_null_declared_type" {
            DefinitionState::DefinitelyNonNull
        } else {
            DefinitionState::MaybeNull
        };
        DefinitionResult::new(state, BTreeSet::from([node_id.to_string()]))
    } else if !effect.complete || effect.unknown_call {
        DefinitionResult::unknown()
    } else if effect
        .write_value_hints
        .get(place_id)
        .is_some_and(|value| definitely_non_null_literal(value))
    {
        DefinitionResult::new(DefinitionState::DefinitelyNonNull, BTreeSet::new())
    } else if let Some(source_id) = effect.write_sources.get(place_id) {
        let definitions = reaching
            .get(&(node_id, source_id.as_str()))
            .map(|definitions| definitions.as_slice())
            .unwrap_or_default();
        join_definitions(definitions, source_id, effects, reaching, cache, visiting)
    } else {
        DefinitionResult::unknown()
    };
    visiting.remove(&key);
    cache.insert(key, state.clone());
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
        let mut nullable_annotation = effect("nullable-annotation", "nullable");
        nullable_annotation.write_nullable_contracts.insert(
            "nullable".to_string(),
            "nullable_declared_type".to_string(),
        );
        let mut non_null_annotation = effect("non-null-annotation", "non-null");
        non_null_annotation.write_nullable_contracts.insert(
            "non-null".to_string(),
            "non_null_declared_type".to_string(),
        );
        let facts = ControlFlowFacts {
            effects: vec![
                null_write,
                non_null_write,
                alias_write,
                wrong_write,
                cycle_write,
                nullable_annotation,
                non_null_annotation,
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
                reachable("read-nullable-annotation", true),
                reachable("read-non-null-annotation", true),
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
                reaching(
                    "read-nullable-annotation",
                    "nullable",
                    &["nullable-annotation"],
                ),
                reaching(
                    "read-non-null-annotation",
                    "non-null",
                    &["non-null-annotation"],
                ),
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
        assert_eq!(
            states[&key("read-alias", "q")].source_definition_ids,
            ["null-write"]
        );
        assert_eq!(states[&key("read-unknown", "p")].state, "unknown");
        assert!(!states[&key("read-unknown", "p")].complete);
        assert_eq!(states[&key("read-dead", "p")].state, "unreachable");
        assert_eq!(states[&key("read-missing", "p")].state, "unknown");
        assert_eq!(states[&key("read-wrong", "p")].state, "unknown");
        assert_eq!(states[&key("read-cycle", "cycle")].state, "unknown");
        assert_eq!(
            states[&key("read-nullable-annotation", "nullable")].state,
            "maybe_null"
        );
        assert_eq!(
            states[&key("read-non-null-annotation", "non-null")].state,
            "definitely_non_null"
        );
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
            definitions: definitions
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        }
    }

    #[test]
    fn summarizes_return_states_without_replaying_local_flow() {
        let facts = ControlFlowFacts {
            nodes: vec![ControlFlowNode {
                id: "return".to_string(),
                file: "demo.c".to_string(),
                function: "load".to_string(),
                owner: "Cache".to_string(),
                kind: "jump".to_string(),
                role: "return".to_string(),
                line: 1,
                span: [1, 0, 1, 1],
                source: "return value;".to_string(),
            }],
            effects: vec![NodeEffect {
                node_id: "return".to_string(),
                reads: vec!["value".to_string()],
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_summaries(
            &facts,
            &[NullableState {
                node_id: "return".to_string(),
                place_id: "value".to_string(),
                state: "definitely_null".to_string(),
                source_definition_ids: vec!["null-write".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            }],
        );

        assert_eq!(
            rows,
            vec![NullableSummary {
                function: "load".to_string(),
                owner: "Cache".to_string(),
                return_state: "definitely_null".to_string(),
                source_definition_ids: vec!["null-write".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            }]
        );
    }

    #[test]
    fn summary_projection_discards_incomplete_rows_and_joins_known_states() {
        let return_node = |id: &str| ControlFlowNode {
            id: id.to_string(),
            file: "demo.c".to_string(),
            function: "load".to_string(),
            owner: "Cache".to_string(),
            kind: "jump".to_string(),
            role: "return".to_string(),
            line: 1,
            span: [1, 0, 1, 1],
            source: "return value;".to_string(),
        };
        let facts = ControlFlowFacts {
            nodes: vec![return_node("missing-effect"), return_node("return")],
            effects: vec![NodeEffect {
                node_id: "return".to_string(),
                reads: vec![
                    "null".to_string(),
                    "present".to_string(),
                    "unmapped".to_string(),
                ],
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_summaries(
            &facts,
            &[
                NullableState {
                    node_id: "return".to_string(),
                    place_id: "null".to_string(),
                    state: "definitely_null".to_string(),
                    source_definition_ids: vec!["null-write".to_string()],
                    complete: true,
                    unknown_reasons: Vec::new(),
                },
                NullableState {
                    node_id: "return".to_string(),
                    place_id: "present".to_string(),
                    state: "definitely_non_null".to_string(),
                    source_definition_ids: vec!["present-write".to_string()],
                    complete: true,
                    unknown_reasons: Vec::new(),
                },
            ],
        );

        assert_eq!(rows[0].return_state, "maybe_null");
        assert_eq!(
            rows[0].source_definition_ids,
            ["null-write", "present-write"]
        );
        assert_eq!(definition_state_from_name("not-a-state"), None);
    }

    #[test]
    fn operation_projection_joins_exact_places_and_preserves_unknown_boundaries() {
        let facts = ControlFlowFacts {
            nodes: vec![
                ControlFlowNode {
                    id: "return".to_string(),
                    file: "demo.c".to_string(),
                    function: "load".to_string(),
                    owner: "Cache".to_string(),
                    kind: "jump".to_string(),
                    role: "return".to_string(),
                    line: 1,
                    span: [1, 0, 1, 14],
                    source: "return *value;".to_string(),
                },
                ControlFlowNode {
                    id: "orphan".to_string(),
                    file: "demo.c".to_string(),
                    function: "orphan".to_string(),
                    owner: "Cache".to_string(),
                    kind: "jump".to_string(),
                    role: "return".to_string(),
                    line: 2,
                    span: [2, 0, 2, 14],
                    source: "return *value;".to_string(),
                },
            ],
            places: vec![Place {
                id: "place:value".to_string(),
                file: "demo.c".to_string(),
                function: "load".to_string(),
                owner: "Cache".to_string(),
                kind: "local".to_string(),
                name: "value".to_string(),
                declaration_span: [1, 0, 1, 1],
            }],
            effects: vec![NodeEffect {
                node_id: "return".to_string(),
                reads: vec!["place:value".to_string()],
                complete: true,
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_operations(
            &[
                NullableOperationSeed {
                    function: "load".to_string(),
                    span: [1, 7, 1, 13],
                    subject: "value".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
                NullableOperationSeed {
                    function: "load".to_string(),
                    span: [1, 7, 1, 13],
                    subject: "missing".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
                NullableOperationSeed {
                    function: "other".to_string(),
                    span: [1, 0, 1, 1],
                    subject: "value".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
                NullableOperationSeed {
                    function: "orphan".to_string(),
                    span: [2, 7, 2, 13],
                    subject: "value".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
            ],
            &facts,
            &[NullableState {
                node_id: "return".to_string(),
                place_id: "place:value".to_string(),
                state: "definitely_null".to_string(),
                source_definition_ids: vec!["null-write".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            }],
        );

        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| {
            row.place_id == "place:value"
                && row.state_at_operation == "definitely_null"
                && row.complete
        }));
        assert!(rows.iter().any(|row| {
            row.place_id.is_empty()
                && row.nil_behavior == "unknown"
                && row.state_at_operation == "unknown"
                && !row.complete
        }));
    }
}
