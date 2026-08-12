use super::{worklist, AliasFact, AllocationFact, ControlFlowFacts, EscapeFact, NodeEffect, Place};
use crate::ast::Node;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct NormalizedAliasEffects {
    pub(crate) allocations: Vec<NormalizedAllocation>,
    pub(crate) aliases: Vec<NormalizedAlias>,
    pub(crate) escapes: Vec<NormalizedEscape>,
    pub(crate) terminal_escapes: Vec<NormalizedEscape>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedAllocation {
    pub(crate) place: String,
    pub(crate) kind: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedAlias {
    pub(crate) destination: String,
    pub(crate) source: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedEscape {
    pub(crate) place: String,
    pub(crate) sink: String,
}

/// Language adapters only normalize syntax into these three operations. The
/// fixed-point implementation below deliberately has no concrete-language
/// vocabulary.
pub(crate) trait AliasNormalizer: Sync {
    fn effects(&self, _node: &Node, _role: &str) -> NormalizedAliasEffects {
        NormalizedAliasEffects::default()
    }
}

struct NeutralAliasNormalizer;

impl AliasNormalizer for NeutralAliasNormalizer {}

pub(crate) fn neutral_normalizer() -> &'static dyn AliasNormalizer {
    static NORMALIZER: NeutralAliasNormalizer = NeutralAliasNormalizer;
    &NORMALIZER
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct IdentitySet {
    ids: BTreeSet<String>,
    complete: bool,
    evidence_nodes: BTreeSet<String>,
}

type PointsToState = BTreeMap<String, IdentitySet>;

pub(crate) fn derive(facts: &mut ControlFlowFacts) {
    let functions = facts
        .nodes
        .iter()
        .map(|node| (node.file.clone(), node.owner.clone(), node.function.clone()))
        .collect::<BTreeSet<_>>();
    for (file, owner, function) in functions {
        derive_function(facts, &file, &owner, &function);
    }
    facts.allocations.sort();
    facts.aliases.sort();
    facts.escapes.sort();
}

fn derive_function(facts: &mut ControlFlowFacts, file: &str, owner: &str, function: &str) {
    let nodes = facts
        .nodes
        .iter()
        .filter(|node| node.file == file && node.owner == owner && node.function == function)
        .cloned()
        .collect::<Vec<_>>();
    let node_ids = nodes.iter().map(|node| node.id.clone()).collect::<Vec<_>>();
    let entry = nodes
        .iter()
        .find(|node| node.kind == "entry")
        .map(|node| node.id.clone());
    let places = facts
        .places
        .iter()
        .filter(|place| place.file == file && place.owner == owner && place.function == function)
        .cloned()
        .collect::<Vec<_>>();
    let effects = facts
        .effects
        .iter()
        .filter(|effect| {
            effect.file == file && effect.owner == owner && effect.function == function
        })
        .map(|effect| (effect.node_id.clone(), effect.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut predecessors = node_ids
        .iter()
        .map(|id| (id.clone(), BTreeSet::new()))
        .collect::<BTreeMap<_, _>>();
    for edge in facts
        .edges
        .iter()
        .filter(|edge| edge.file == file && edge.owner == owner && edge.function == function)
    {
        predecessors
            .entry(edge.to.clone())
            .or_default()
            .insert(edge.from.clone());
    }

    let roots = root_state(&places, entry.as_deref().unwrap_or("entry"));
    for place in &places {
        facts
            .allocations
            .push(root_allocation(place, entry.as_deref().unwrap_or("entry")));
    }
    append_explicit_allocations(facts, &effects);

    let mut states = node_ids
        .iter()
        .map(|id| (id.clone(), PointsToState::new()))
        .collect::<BTreeMap<_, _>>();
    worklist::solve(&node_ids, &mut states, |id, values| {
        let mut incoming = if Some(id.as_str()) == entry.as_deref() {
            roots.clone()
        } else {
            join_predecessors(predecessors.get(id), values)
        };
        if let Some(effect) = effects.get(id) {
            apply_effect(&mut incoming, effect);
        }
        incoming
    });

    append_unknown_allocations(facts, file, owner, function, &effects, &states);
    for node in &nodes {
        let Some(effect) = effects.get(&node.id) else {
            continue;
        };
        let state = states.get(&node.id).cloned().unwrap_or_default();
        let touched = effect
            .reads
            .iter()
            .chain(effect.writes.iter())
            .chain(
                effect
                    .escape_transfers
                    .iter()
                    .map(|escape| &escape.place_id),
            )
            .cloned()
            .collect::<BTreeSet<_>>();
        for place_id in touched {
            let identity = state.get(&place_id).cloned().unwrap_or_default();
            facts.aliases.push(AliasFact {
                node_id: node.id.clone(),
                file: file.to_string(),
                function: function.to_string(),
                owner: owner.to_string(),
                place_id,
                allocation_ids: identity.ids.iter().cloned().collect(),
                relationship: if identity.complete && identity.ids.len() == 1 {
                    "must".to_string()
                } else {
                    "may".to_string()
                },
                complete: identity.complete && !identity.ids.is_empty(),
                evidence_nodes: identity.evidence_nodes.iter().cloned().collect(),
            });
        }
        for escape in &effect.escape_transfers {
            let identity = state.get(&escape.place_id).cloned().unwrap_or_default();
            let ids = if identity.ids.is_empty() {
                vec![unknown_id(&node.id, &escape.place_id)]
            } else {
                identity.ids.iter().cloned().collect()
            };
            for allocation_id in ids {
                facts.escapes.push(EscapeFact {
                    allocation_id,
                    sink_node_id: node.id.clone(),
                    file: file.to_string(),
                    function: function.to_string(),
                    owner: owner.to_string(),
                    via_place_id: escape.place_id.clone(),
                    sink: escape.sink.clone(),
                    complete: identity.complete && !identity.ids.is_empty(),
                    evidence_nodes: identity.evidence_nodes.iter().cloned().collect(),
                });
            }
        }
    }
}

fn root_state(places: &[Place], entry: &str) -> PointsToState {
    places
        .iter()
        .map(|place| {
            (
                place.id.clone(),
                IdentitySet {
                    ids: BTreeSet::from([root_id(&place.id)]),
                    complete: true,
                    evidence_nodes: BTreeSet::from([entry.to_string()]),
                },
            )
        })
        .collect()
}

fn root_allocation(place: &Place, entry: &str) -> AllocationFact {
    AllocationFact {
        id: root_id(&place.id),
        node_id: entry.to_string(),
        file: place.file.clone(),
        function: place.function.clone(),
        owner: place.owner.clone(),
        place_id: place.id.clone(),
        kind: format!("external_{}", place.kind),
        fresh: false,
    }
}

fn append_explicit_allocations(
    facts: &mut ControlFlowFacts,
    effects: &BTreeMap<String, NodeEffect>,
) {
    for effect in effects.values() {
        for transfer in &effect.allocation_transfers {
            facts.allocations.push(AllocationFact {
                id: allocation_id(&effect.node_id, &transfer.place_id),
                node_id: effect.node_id.clone(),
                file: effect.file.clone(),
                function: effect.function.clone(),
                owner: effect.owner.clone(),
                place_id: transfer.place_id.clone(),
                kind: transfer.kind.clone(),
                fresh: true,
            });
        }
    }
}

fn append_unknown_allocations(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    effects: &BTreeMap<String, NodeEffect>,
    states: &BTreeMap<String, PointsToState>,
) {
    for effect in effects.values() {
        for place_id in &effect.writes {
            let Some(identity) = states
                .get(&effect.node_id)
                .and_then(|state| state.get(place_id))
            else {
                continue;
            };
            let id = unknown_id(&effect.node_id, place_id);
            if !identity.ids.contains(&id) {
                continue;
            }
            facts.allocations.push(AllocationFact {
                id,
                node_id: effect.node_id.clone(),
                file: file.to_string(),
                function: function.to_string(),
                owner: owner.to_string(),
                place_id: place_id.clone(),
                kind: "unknown".to_string(),
                fresh: false,
            });
        }
    }
}

fn join_predecessors(
    predecessors: Option<&BTreeSet<String>>,
    states: &BTreeMap<String, PointsToState>,
) -> PointsToState {
    let incoming = predecessors
        .into_iter()
        .flatten()
        .filter_map(|predecessor| states.get(predecessor))
        .collect::<Vec<_>>();
    let places = incoming
        .iter()
        .flat_map(|state| state.keys().cloned())
        .collect::<BTreeSet<_>>();
    places
        .into_iter()
        .map(|place| {
            let mut joined = IdentitySet {
                complete: !incoming.is_empty(),
                ..IdentitySet::default()
            };
            for state in &incoming {
                let Some(identity) = state.get(&place) else {
                    joined.complete = false;
                    continue;
                };
                joined.ids.extend(identity.ids.iter().cloned());
                joined
                    .evidence_nodes
                    .extend(identity.evidence_nodes.iter().cloned());
                joined.complete &= identity.complete;
            }
            (place, joined)
        })
        .collect()
}

fn apply_effect(state: &mut PointsToState, effect: &NodeEffect) {
    let normalized_destinations = effect
        .allocation_transfers
        .iter()
        .map(|transfer| transfer.place_id.clone())
        .chain(
            effect
                .alias_transfers
                .iter()
                .map(|transfer| transfer.destination_place_id.clone()),
        )
        .collect::<BTreeSet<_>>();
    for place_id in &effect.writes {
        if !normalized_destinations.contains(place_id) {
            state.insert(
                place_id.clone(),
                IdentitySet {
                    ids: BTreeSet::from([unknown_id(&effect.node_id, place_id)]),
                    complete: false,
                    evidence_nodes: BTreeSet::from([effect.node_id.clone()]),
                },
            );
        }
    }
    for transfer in &effect.allocation_transfers {
        state.insert(
            transfer.place_id.clone(),
            IdentitySet {
                ids: BTreeSet::from([allocation_id(&effect.node_id, &transfer.place_id)]),
                complete: true,
                evidence_nodes: BTreeSet::from([effect.node_id.clone()]),
            },
        );
    }
    for transfer in &effect.alias_transfers {
        let mut identity = state
            .get(&transfer.source_place_id)
            .cloned()
            .unwrap_or_else(|| IdentitySet {
                ids: BTreeSet::from([root_id(&transfer.source_place_id)]),
                complete: true,
                evidence_nodes: BTreeSet::new(),
            });
        identity.evidence_nodes.insert(effect.node_id.clone());
        state.insert(transfer.destination_place_id.clone(), identity);
    }
}

fn root_id(place_id: &str) -> String {
    format!("origin:{place_id}")
}

fn allocation_id(node_id: &str, place_id: &str) -> String {
    format!("allocation:{node_id}:{place_id}")
}

fn unknown_id(node_id: &str, place_id: &str) -> String {
    format!("unknown:{node_id}:{place_id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::cfg::{
        AliasTransfer, AllocationTransfer, ControlFlowEdge, ControlFlowNode, EscapeTransfer,
    };

    fn node(id: &str, kind: &str) -> ControlFlowNode {
        ControlFlowNode {
            id: id.to_string(),
            file: "fixture.rb".to_string(),
            function: "choose".to_string(),
            owner: "Fixture".to_string(),
            kind: kind.to_string(),
            role: kind.to_string(),
            line: 1,
            span: [1, 0, 1, 1],
            source: String::new(),
        }
    }

    fn effect(id: &str) -> NodeEffect {
        NodeEffect {
            node_id: id.to_string(),
            file: "fixture.rb".to_string(),
            function: "choose".to_string(),
            owner: "Fixture".to_string(),
            complete: true,
            ..NodeEffect::default()
        }
    }

    fn edge(from: &str, to: &str) -> ControlFlowEdge {
        ControlFlowEdge {
            file: "fixture.rb".to_string(),
            function: "choose".to_string(),
            owner: "Fixture".to_string(),
            from: from.to_string(),
            to: to.to_string(),
            kind: "flow".to_string(),
            line: 1,
            span: [1, 0, 1, 1],
        }
    }

    #[test]
    fn joins_distinct_identities_as_may_alias_and_preserves_escape_evidence() {
        let source = "place:Fixture#choose:local:source".to_string();
        let value = "place:Fixture#choose:local:value".to_string();
        let mut left = effect("left");
        left.writes.push(value.clone());
        left.allocation_transfers.push(AllocationTransfer {
            place_id: value.clone(),
            kind: "array".to_string(),
        });
        let mut right = effect("right");
        right.writes.push(value.clone());
        right.alias_transfers.push(AliasTransfer {
            destination_place_id: value.clone(),
            source_place_id: source.clone(),
        });
        let mut join = effect("join");
        join.reads.push(value.clone());
        join.escape_transfers.push(EscapeTransfer {
            place_id: value.clone(),
            sink: "return".to_string(),
        });
        let mut facts = ControlFlowFacts {
            nodes: vec![
                node("entry", "entry"),
                node("left", "statement"),
                node("right", "statement"),
                node("join", "statement"),
                node("exit", "exit"),
            ],
            edges: vec![
                edge("entry", "left"),
                edge("entry", "right"),
                edge("left", "join"),
                edge("right", "join"),
                edge("join", "exit"),
            ],
            places: vec![
                Place {
                    id: source,
                    file: "fixture.rb".to_string(),
                    function: "choose".to_string(),
                    owner: "Fixture".to_string(),
                    kind: "local".to_string(),
                    name: "source".to_string(),
                    declaration_span: [1, 0, 1, 1],
                },
                Place {
                    id: value.clone(),
                    file: "fixture.rb".to_string(),
                    function: "choose".to_string(),
                    owner: "Fixture".to_string(),
                    kind: "local".to_string(),
                    name: "value".to_string(),
                    declaration_span: [1, 0, 1, 1],
                },
            ],
            effects: vec![effect("entry"), left, right, join, effect("exit")],
            ..ControlFlowFacts::default()
        };

        derive(&mut facts);

        let joined = facts
            .aliases
            .iter()
            .find(|fact| fact.node_id == "join" && fact.place_id == value)
            .expect("joined alias fact");
        assert_eq!(joined.relationship, "may");
        assert!(joined.complete);
        assert_eq!(joined.allocation_ids.len(), 2);
        assert_eq!(facts.escapes.len(), 2);
        assert!(facts.escapes.iter().all(|fact| fact.complete));
    }
}
