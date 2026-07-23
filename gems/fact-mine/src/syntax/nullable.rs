use crate::ast::Span;
use crate::syntax::cfg::{ControlFlowEdge, ControlFlowFacts, ControlFlowNode, NodeEffect};
use crate::syntax::redundant_nil_guard::NullableRefinementSeed;
use std::collections::{BTreeMap, BTreeSet};

/// A branch-local nullability proof. The state applies only to the selected
/// outgoing branch; consumers must invalidate it when the subject is written.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NullableRefinement {
    pub place_id: String,
    pub condition_node_id: String,
    /// Exact nullable reaching definitions at the condition node. Consumers
    /// must join obligations through these IDs, never by place spelling.
    pub source_definition_ids: Vec<String>,
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
/// state. Every explicit return participates; a return without an effect or
/// tracked read is emitted as incomplete rather than silently omitted.
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
    /// Exact nullable reaching definitions at this operation node.
    pub source_definition_ids: Vec<String>,
    pub complete: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct PresenceCorrelation {
    pub group_id: String,
    pub path: String,
    pub span: Span,
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
    states: &[NullableState],
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
    let states_by_node = states
        .iter()
        .map(|state| ((state.node_id.as_str(), state.place_id.as_str()), state))
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
                let state = states_by_node
                    .get(&(node.id.as_str(), place_id.as_str()))
                    .copied();
                rows.insert((
                    place_id,
                    node.id.clone(),
                    seed.edge.clone(),
                    seed.state_on_edge.clone(),
                    seed.proof_kind.clone(),
                    seed.condition_span,
                    state
                        .map(|state| state.source_definition_ids.clone())
                        .unwrap_or_default(),
                    effect.complete && state.is_some_and(|state| state.complete),
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
                source_definition_ids,
                complete,
            )| {
                NullableRefinement {
                    place_id,
                    condition_node_id,
                    source_definition_ids,
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

/// Applies complete branch proofs to successor states while their exact
/// reaching definitions remain unchanged. A refinement is an *edge* fact: it
/// is valid only until the selected edge meets a node also reachable from an
/// unselected edge of the same decision. A write to the refined place also
/// ends propagation, so a later reassignment cannot inherit an earlier guard.
///
/// This deliberately does not mutate the base reaching-definition result at a
/// join. At a join the unselected path is another input to the nullable state,
/// so retaining an edge-local `definitely_non_null` result would be unsound.
pub(crate) fn apply_refinements(
    states: &[NullableState],
    refinements: &[NullableRefinement],
    facts: &ControlFlowFacts,
) -> Vec<NullableState> {
    let mut output = states
        .iter()
        .cloned()
        .map(|state| ((state.node_id.clone(), state.place_id.clone()), state))
        .collect::<BTreeMap<_, _>>();
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();
    let outgoing = facts
        .edges
        .iter()
        .fold(BTreeMap::<&str, Vec<_>>::new(), |mut rows, edge| {
            rows.entry(edge.from.as_str()).or_default().push(edge);
            rows
        });

    for refinement in refinements.iter().filter(|row| {
        row.complete
            && !row.source_definition_ids.is_empty()
            && matches!(
                row.state_on_edge.as_str(),
                "definitely_non_null" | "definitely_null"
            )
    }) {
        let roots = refinement
            .source_definition_ids
            .iter()
            .collect::<BTreeSet<_>>();
        let selected_successors = outgoing
            .get(refinement.condition_node_id.as_str())
            .into_iter()
            .flatten()
            .filter(|edge| refinement_edge_matches(&refinement.edge, &edge.kind))
            .map(|edge| edge.to.clone())
            .collect::<BTreeSet<_>>();
        let unselected_successors = outgoing
            .get(refinement.condition_node_id.as_str())
            .into_iter()
            .flatten()
            .filter(|edge| !refinement_edge_matches(&refinement.edge, &edge.kind))
            .map(|edge| edge.to.clone())
            .collect::<BTreeSet<_>>();
        // A node reachable from any unselected successor is a control-flow
        // join for this proof. Do not apply the selected-edge state at or
        // beyond it; the base state already joins both incoming paths.
        let joins = reachable_nodes(&unselected_successors, &outgoing);
        let mut pending = selected_successors.into_iter().collect::<Vec<_>>();
        let mut visited = BTreeSet::new();
        while let Some(node_id) = pending.pop() {
            if !visited.insert(node_id.clone()) {
                continue;
            }
            if joins.contains(&node_id) {
                continue;
            }
            let state_key = (node_id.clone(), refinement.place_id.clone());
            let unchanged = output.get(&state_key).is_some_and(|state| {
                state.complete
                    && state.source_definition_ids.iter().collect::<BTreeSet<_>>() == roots
            });
            if !unchanged {
                continue;
            }
            if let Some(state) = output.get_mut(&state_key) {
                state.state = refinement.state_on_edge.clone();
            }
            if effects
                .get(node_id.as_str())
                .is_some_and(|effect| effect.writes.contains(&refinement.place_id))
            {
                continue;
            }
            pending.extend(
                outgoing
                    .get(node_id.as_str())
                    .into_iter()
                    .flatten()
                    .map(|edge| edge.to.clone()),
            );
        }
    }
    output.into_values().collect()
}

fn reachable_nodes(
    starts: &BTreeSet<String>,
    outgoing: &BTreeMap<&str, Vec<&ControlFlowEdge>>,
) -> BTreeSet<String> {
    let mut reachable = BTreeSet::new();
    let mut pending = starts.iter().cloned().collect::<Vec<_>>();
    while let Some(node_id) = pending.pop() {
        if !reachable.insert(node_id.clone()) {
            continue;
        }
        pending.extend(
            outgoing
                .get(node_id.as_str())
                .into_iter()
                .flatten()
                .map(|edge| edge.to.clone()),
        );
    }
    reachable
}

fn refinement_edge_matches(edge: &str, cfg_kind: &str) -> bool {
    matches!(
        (edge, cfg_kind),
        ("then", "branch_true") | ("else", "branch_false")
    )
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
    let mut return_nodes = BTreeMap::<(String, String), Vec<&ControlFlowNode>>::new();
    let mut return_effects = BTreeMap::<(String, String), Vec<&NodeEffect>>::new();

    for node in facts.nodes.iter().filter(|node| node.role == "return") {
        let key = (node.owner.clone(), node.function.clone());
        return_nodes.entry(key.clone()).or_default().push(node);
        let Some(effect) = effects.get(node.id.as_str()) else {
            continue;
        };
        return_effects.entry(key.clone()).or_default().push(*effect);
        for place_id in &effect.reads {
            if let Some(state) = states_by_node.get(&(node.id.as_str(), place_id.as_str())) {
                returns.entry(key.clone()).or_default().push(state);
            }
        }
    }

    return_nodes
        .into_iter()
        .map(|((owner, function), nodes)| {
            let states = returns
                .remove(&(owner.clone(), function.clone()))
                .unwrap_or_default();
            let effects = return_effects
                .remove(&(owner.clone(), function.clone()))
                .unwrap_or_default();
            let state = join_projected_states(
                states.iter().map(|state| state.state.as_str()).chain(
                    effects
                        .iter()
                        .filter_map(|effect| effect.return_state_hint.as_deref()),
                ),
            );
            let every_return_has_effect = nodes
                .iter()
                .all(|node| effects.iter().any(|effect| effect.node_id == node.id));
            let every_return_has_modeled_value = effects
                .iter()
                .all(|effect| !effect.reads.is_empty() || effect.return_state_hint.is_some());
            let every_read_modeled = effects.iter().all(|effect| {
                effect.reads.iter().all(|place_id| {
                    states_by_node.contains_key(&(effect.node_id.as_str(), place_id.as_str()))
                })
            });
            let complete = every_return_has_effect
                && every_return_has_modeled_value
                && every_read_modeled
                && effects
                    .iter()
                    .all(|effect| effect.complete && !effect.unknown_call)
                && states.iter().all(|state| state.complete)
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
                .chain(
                    effects
                        .iter()
                        .flat_map(|effect| effect.unknown_reasons.iter().cloned()),
                )
                .chain((!every_read_modeled).then_some("unmodeled_return_read".to_string()))
                .chain((!every_return_has_effect).then_some("return_without_effect".to_string()))
                .chain(
                    (!every_return_has_modeled_value)
                        .then_some("return_without_tracked_read".to_string()),
                )
                .chain(
                    effects
                        .iter()
                        .filter(|effect| !effect.complete)
                        .map(|_| "incomplete_return_effect".to_string()),
                )
                .chain(
                    effects
                        .iter()
                        .filter(|effect| effect.unknown_call)
                        .map(|_| "unknown_return_call".to_string()),
                )
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
                    Vec::new(),
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
                state
                    .map(|state| state.source_definition_ids.clone())
                    .unwrap_or_default(),
                state.is_some_and(|state| state.complete) && effect.complete,
            ));
        }
    }

    rows.into_iter()
        .map(
            |(
                node_id,
                path,
                span,
                place_id,
                operation_kind,
                nil_behavior,
                state_at_operation,
                source_definition_ids,
                complete,
            )| {
                NullableOperation {
                    node_id,
                    path,
                    span,
                    place_id,
                    operation_kind,
                    nil_behavior,
                    state_at_operation,
                    source_definition_ids,
                    complete,
                }
            },
        )
        .collect()
}

pub(crate) fn project_presence_correlations(
    seeds: &[PresenceCorrelationSeed],
    facts: &ControlFlowFacts,
) -> Vec<PresenceCorrelation> {
    let places = facts
        .places
        .iter()
        .map(|place| (place.id.as_str(), place.name.as_str()))
        .collect::<BTreeMap<_, _>>();
    let effects = facts
        .effects
        .iter()
        .map(|effect| (effect.node_id.as_str(), effect))
        .collect::<BTreeMap<_, _>>();
    let mut rows = BTreeSet::new();
    for seed in seeds {
        for node in facts
            .nodes
            .iter()
            .filter(|node| node.function == seed.function && span_contains(node.span, seed.span))
        {
            let Some(effect) = effects.get(node.id.as_str()) else {
                continue;
            };
            let place_for = |subject: &str| {
                effect
                    .reads
                    .iter()
                    .chain(effect.writes.iter())
                    .find(|place_id| places.get(place_id.as_str()) == Some(&subject))
                    .cloned()
            };
            let (Some(value_place_id), Some(presence_place_id)) = (
                place_for(&seed.value_subject),
                place_for(&seed.presence_subject),
            ) else {
                continue;
            };
            rows.insert((
                format!("presence:{}:{value_place_id}:{presence_place_id}", node.id),
                node.file.clone(),
                // The CFG node can be a synthetic returned-closure wrapper;
                // retain the extractor's exact comma-ok declaration span for
                // downstream SARIF locations.
                seed.span,
                value_place_id,
                presence_place_id,
                seed.semantics.clone(),
                "presence_on_true".to_string(),
                effect.complete,
            ));
        }
    }
    rows.into_iter()
        .map(
            |(
                group_id,
                path,
                span,
                value_place_id,
                presence_place_id,
                semantics,
                branch_refinement,
                complete,
            )| PresenceCorrelation {
                group_id,
                path,
                span,
                value_place_id,
                presence_place_id,
                semantics,
                branch_refinement,
                complete,
            },
        )
        .collect()
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
    use crate::syntax::cfg::{ControlFlowEdge, ControlFlowNode, NodeEffect, Place};

    fn edge(from: &str, to: &str, kind: &str) -> ControlFlowEdge {
        ControlFlowEdge {
            file: "flow.rb".to_string(),
            function: "use".to_string(),
            owner: "".to_string(),
            from: from.to_string(),
            to: to.to_string(),
            kind: kind.to_string(),
            line: 1,
            span: [1, 0, 1, 1],
        }
    }

    fn nullable_state(node_id: &str) -> NullableState {
        NullableState {
            node_id: node_id.to_string(),
            place_id: "place:value".to_string(),
            state: "maybe_null".to_string(),
            source_definition_ids: vec!["root:value".to_string()],
            complete: true,
            unknown_reasons: Vec::new(),
        }
    }

    fn non_null_then_refinement() -> NullableRefinement {
        NullableRefinement {
            place_id: "place:value".to_string(),
            condition_node_id: "branch".to_string(),
            source_definition_ids: vec!["root:value".to_string()],
            edge: "then".to_string(),
            state_on_edge: "definitely_non_null".to_string(),
            proof_kind: "nil_comparison".to_string(),
            source_span: [1, 0, 1, 1],
            complete: true,
        }
    }

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
            &[],
        );

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].place_id, "place:value");
        assert_eq!(rows[0].state_on_edge, "definitely_non_null");
        assert!(rows[0].source_definition_ids.is_empty());
        assert!(!rows[0].complete);
    }

    #[test]
    fn complete_branch_refinement_reaches_successors_and_stops_at_writes() {
        let facts = ControlFlowFacts {
            edges: vec![
                ControlFlowEdge {
                    file: "guard.c".to_string(),
                    function: "use".to_string(),
                    owner: "".to_string(),
                    from: "guard".to_string(),
                    to: "operation".to_string(),
                    kind: "branch_false".to_string(),
                    line: 2,
                    span: [2, 0, 2, 8],
                },
                ControlFlowEdge {
                    file: "guard.c".to_string(),
                    function: "use".to_string(),
                    owner: "".to_string(),
                    from: "operation".to_string(),
                    to: "write".to_string(),
                    kind: "fallthrough".to_string(),
                    line: 3,
                    span: [3, 0, 3, 8],
                },
                ControlFlowEdge {
                    file: "guard.c".to_string(),
                    function: "use".to_string(),
                    owner: "".to_string(),
                    from: "write".to_string(),
                    to: "after_write".to_string(),
                    kind: "fallthrough".to_string(),
                    line: 4,
                    span: [4, 0, 4, 8],
                },
            ],
            effects: vec![
                NodeEffect {
                    node_id: "operation".to_string(),
                    reads: vec!["place:value".to_string()],
                    complete: true,
                    ..NodeEffect::default()
                },
                NodeEffect {
                    node_id: "write".to_string(),
                    writes: vec!["place:value".to_string()],
                    complete: true,
                    ..NodeEffect::default()
                },
            ],
            ..ControlFlowFacts::default()
        };
        let states = vec![
            NullableState {
                node_id: "operation".to_string(),
                place_id: "place:value".to_string(),
                state: "maybe_null".to_string(),
                source_definition_ids: vec!["root:a".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            },
            NullableState {
                node_id: "write".to_string(),
                place_id: "place:value".to_string(),
                state: "maybe_null".to_string(),
                source_definition_ids: vec!["root:a".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            },
            NullableState {
                node_id: "after_write".to_string(),
                place_id: "place:value".to_string(),
                state: "maybe_null".to_string(),
                source_definition_ids: vec!["root:b".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            },
        ];
        let refinements = vec![NullableRefinement {
            place_id: "place:value".to_string(),
            condition_node_id: "guard".to_string(),
            source_definition_ids: vec!["root:a".to_string()],
            edge: "else".to_string(),
            state_on_edge: "definitely_non_null".to_string(),
            proof_kind: "nil_comparison".to_string(),
            source_span: [2, 0, 2, 8],
            complete: true,
        }];
        let states = apply_refinements(&states, &refinements, &facts);
        let state = |node: &str| {
            states
                .iter()
                .find(|row| row.node_id == node)
                .unwrap()
                .state
                .as_str()
        };
        assert_eq!(state("operation"), "definitely_non_null");
        assert_eq!(state("write"), "definitely_non_null");
        assert_eq!(state("after_write"), "maybe_null");
    }

    #[test]
    fn branch_refinements_are_edge_local_across_joins_and_loops() {
        let cases = [
            // `if value != nil; use(value); end; use(value)`: the implicit
            // false edge joins after the guarded use.
            (
                "implicit_else_join",
                vec![
                    edge("branch", "guarded", "branch_true"),
                    edge("branch", "join", "branch_false"),
                    edge("guarded", "join", "fallthrough"),
                ],
                vec![("guarded", "definitely_non_null"), ("join", "maybe_null")],
            ),
            // Both explicit branches can reach the join; neither branch's
            // proof may leak into the post-conditional operation.
            (
                "two_branch_join",
                vec![
                    edge("branch", "then", "branch_true"),
                    edge("branch", "else", "branch_false"),
                    edge("then", "join", "fallthrough"),
                    edge("else", "join", "fallthrough"),
                ],
                vec![("then", "definitely_non_null"), ("join", "maybe_null")],
            ),
            // A guard clause has no false-path route to `after`, so the
            // selected non-null edge remains valid after the early return.
            (
                "guard_clause",
                vec![
                    edge("branch", "after", "branch_true"),
                    edge("branch", "return", "branch_false"),
                ],
                vec![("after", "definitely_non_null")],
            ),
            // A nested condition retains the outer refinement inside the
            // selected region, but not at its outer join.
            (
                "nested_condition",
                vec![
                    edge("branch", "nested", "branch_true"),
                    edge("branch", "join", "branch_false"),
                    edge("nested", "guarded", "branch_true"),
                    edge("nested", "join", "branch_false"),
                    edge("guarded", "join", "fallthrough"),
                ],
                vec![
                    ("nested", "definitely_non_null"),
                    ("guarded", "definitely_non_null"),
                    ("join", "maybe_null"),
                ],
            ),
            // Backedges must neither make the traversal loop forever nor let
            // the refinement survive the loop's exit join.
            (
                "loop_backedge",
                vec![
                    edge("branch", "body", "branch_true"),
                    edge("branch", "join", "branch_false"),
                    edge("body", "body", "fallthrough"),
                    edge("body", "join", "fallthrough"),
                ],
                vec![("body", "definitely_non_null"), ("join", "maybe_null")],
            ),
            // A write on only the selected branch terminates the refinement;
            // its sibling still prevents a post-conditional leak.
            (
                "reassignment_on_selected_branch",
                vec![
                    edge("branch", "write", "branch_true"),
                    edge("branch", "join", "branch_false"),
                    edge("write", "join", "fallthrough"),
                ],
                vec![("write", "definitely_non_null"), ("join", "maybe_null")],
            ),
        ];

        for (name, edges, expected) in cases {
            let mut facts = ControlFlowFacts {
                edges,
                ..ControlFlowFacts::default()
            };
            if name == "reassignment_on_selected_branch" {
                facts.effects.push(NodeEffect {
                    node_id: "write".to_string(),
                    writes: vec!["place:value".to_string()],
                    complete: true,
                    ..NodeEffect::default()
                });
            }
            let states = expected
                .iter()
                .map(|(node, _)| nullable_state(node))
                .collect::<Vec<_>>();
            let output = apply_refinements(&states, &[non_null_then_refinement()], &facts);
            for (node, state) in expected {
                let actual = output
                    .iter()
                    .find(|row| row.node_id == node)
                    .map(|row| row.state.as_str());
                assert_eq!(actual, Some(state), "{name}: {node}");
            }
        }
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
        nullable_annotation
            .write_nullable_contracts
            .insert("nullable".to_string(), "nullable_declared_type".to_string());
        let mut non_null_annotation = effect("non-null-annotation", "non-null");
        non_null_annotation
            .write_nullable_contracts
            .insert("non-null".to_string(), "non_null_declared_type".to_string());
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
                complete: true,
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
        assert!(!rows[0].complete);
        assert!(rows[0]
            .unknown_reasons
            .contains(&"unmodeled_return_read".to_string()));
        assert_eq!(
            rows[0].source_definition_ids,
            ["null-write", "present-write"]
        );
        assert_eq!(definition_state_from_name("not-a-state"), None);
    }

    #[test]
    fn summary_is_incomplete_when_any_return_has_no_effect_or_tracked_read() {
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
            nodes: vec![return_node("modeled"), return_node("missing-effect")],
            effects: vec![NodeEffect {
                node_id: "modeled".to_string(),
                reads: vec!["value".to_string()],
                complete: true,
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_summaries(
            &facts,
            &[NullableState {
                node_id: "modeled".to_string(),
                place_id: "value".to_string(),
                state: "definitely_non_null".to_string(),
                source_definition_ids: vec!["value-write".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            }],
        );

        assert_eq!(rows.len(), 1);
        assert!(!rows[0].complete);
        assert!(rows[0]
            .unknown_reasons
            .contains(&"return_without_effect".to_string()));

        let no_read_facts = ControlFlowFacts {
            nodes: vec![return_node("literal-return")],
            effects: vec![NodeEffect {
                node_id: "literal-return".to_string(),
                complete: true,
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_summaries(&no_read_facts, &[]);
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].complete);
        assert!(rows[0]
            .unknown_reasons
            .contains(&"return_without_tracked_read".to_string()));

        let literal_return_facts = ControlFlowFacts {
            nodes: vec![return_node("literal-return")],
            effects: vec![NodeEffect {
                node_id: "literal-return".to_string(),
                return_state_hint: Some("definitely_null".to_string()),
                complete: true,
                ..NodeEffect::default()
            }],
            ..ControlFlowFacts::default()
        };
        let rows = project_summaries(&literal_return_facts, &[]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].return_state, "definitely_null");
        assert!(rows[0].complete);
        assert!(rows[0].unknown_reasons.is_empty());
    }

    #[test]
    fn operations_keep_reassigned_reaching_roots_distinct() {
        let facts = ControlFlowFacts {
            nodes: vec![
                ControlFlowNode {
                    id: "op_a".to_string(),
                    file: "reassign.c".to_string(),
                    function: "use".to_string(),
                    owner: "".to_string(),
                    kind: "statement".to_string(),
                    role: "statement".to_string(),
                    line: 4,
                    span: [4, 0, 4, 8],
                    source: "*value".to_string(),
                },
                ControlFlowNode {
                    id: "op_b".to_string(),
                    file: "reassign.c".to_string(),
                    function: "use".to_string(),
                    owner: "".to_string(),
                    kind: "statement".to_string(),
                    role: "statement".to_string(),
                    line: 8,
                    span: [8, 0, 8, 8],
                    source: "*value".to_string(),
                },
            ],
            places: vec![Place {
                id: "place:value".to_string(),
                file: "reassign.c".to_string(),
                function: "use".to_string(),
                owner: "".to_string(),
                kind: "local".to_string(),
                name: "value".to_string(),
                declaration_span: [1, 0, 1, 5],
            }],
            effects: vec![
                NodeEffect {
                    node_id: "op_a".to_string(),
                    reads: vec!["place:value".to_string()],
                    complete: true,
                    ..NodeEffect::default()
                },
                NodeEffect {
                    node_id: "op_b".to_string(),
                    reads: vec!["place:value".to_string()],
                    complete: true,
                    ..NodeEffect::default()
                },
            ],
            ..ControlFlowFacts::default()
        };
        let states = vec![
            NullableState {
                node_id: "op_a".to_string(),
                place_id: "place:value".to_string(),
                state: "maybe_null".to_string(),
                source_definition_ids: vec!["definition:a".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            },
            NullableState {
                node_id: "op_b".to_string(),
                place_id: "place:value".to_string(),
                state: "maybe_null".to_string(),
                source_definition_ids: vec!["definition:b".to_string()],
                complete: true,
                unknown_reasons: Vec::new(),
            },
        ];
        let rows = project_operations(
            &[
                NullableOperationSeed {
                    function: "use".to_string(),
                    span: [4, 0, 4, 8],
                    subject: "value".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
                NullableOperationSeed {
                    function: "use".to_string(),
                    span: [8, 0, 8, 8],
                    subject: "value".to_string(),
                    operation_kind: "pointer_dereference".to_string(),
                    nil_behavior: "undefined_behavior".to_string(),
                },
            ],
            &facts,
            &states,
        );
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].source_definition_ids, vec!["definition:a"]);
        assert_eq!(rows[1].source_definition_ids, vec!["definition:b"]);
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
