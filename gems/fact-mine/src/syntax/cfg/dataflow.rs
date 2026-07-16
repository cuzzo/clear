use super::{
    worklist, ControlFlowFacts, DefUseFact, DominatorFact, FlowTypeFact, LivenessFact,
    ReachabilityFact, ReachingDefinitionFact,
};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

type DefinitionState = BTreeMap<String, BTreeSet<String>>;

pub(crate) fn derive(facts: &mut ControlFlowFacts) {
    let graphs = method_graphs(facts);
    for (file, owner, function, entry, node_ids) in graphs {
        derive_graph(facts, &file, &owner, &function, &entry, &node_ids);
    }
    facts.reachability.sort_by(|a, b| a.node_id.cmp(&b.node_id));
    facts.dominators.sort_by(|a, b| a.node_id.cmp(&b.node_id));
    facts.reaching_definitions.sort_by(|a, b| {
        a.node_id
            .cmp(&b.node_id)
            .then_with(|| a.place_id.cmp(&b.place_id))
    });
    facts.def_use.sort_by(|a, b| {
        a.definition_node_id
            .cmp(&b.definition_node_id)
            .then_with(|| a.place_id.cmp(&b.place_id))
    });
    facts.liveness.sort_by(|a, b| a.node_id.cmp(&b.node_id));
    facts.flow_types.sort_by(|a, b| {
        a.node_id
            .cmp(&b.node_id)
            .then_with(|| a.place_id.cmp(&b.place_id))
    });
}

type MethodGraph = (String, String, String, String, Vec<String>);

fn method_graphs(facts: &ControlFlowFacts) -> Vec<MethodGraph> {
    let mut adjacency = facts
        .nodes
        .iter()
        .map(|node| (node.id.clone(), BTreeSet::new()))
        .collect::<BTreeMap<_, _>>();
    for edge in &facts.edges {
        if adjacency.contains_key(&edge.from) && adjacency.contains_key(&edge.to) {
            adjacency
                .entry(edge.from.clone())
                .or_default()
                .insert(edge.to.clone());
            adjacency
                .entry(edge.to.clone())
                .or_default()
                .insert(edge.from.clone());
        }
    }
    let nodes = facts
        .nodes
        .iter()
        .map(|node| (node.id.as_str(), node))
        .collect::<BTreeMap<_, _>>();
    let mut assigned = BTreeSet::new();
    let mut graphs = Vec::new();
    for entry in facts.nodes.iter().filter(|node| node.kind == "entry") {
        if assigned.contains(&entry.id) {
            continue;
        }
        let mut component = BTreeSet::new();
        let mut queue = VecDeque::from([entry.id.clone()]);
        while let Some(node_id) = queue.pop_front() {
            if !component.insert(node_id.clone()) {
                continue;
            }
            queue.extend(adjacency.get(&node_id).into_iter().flatten().cloned());
        }
        assigned.extend(component.iter().cloned());
        graphs.push((
            entry.file.clone(),
            entry.owner.clone(),
            entry.function.clone(),
            entry.id.clone(),
            component.into_iter().collect(),
        ));
    }
    debug_assert_eq!(
        assigned.len(),
        nodes.len(),
        "every CFG node must belong to exactly one method graph"
    );
    graphs
}

fn derive_graph(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    entry: &str,
    node_ids: &[String],
) {
    let node_set = node_ids.iter().cloned().collect::<BTreeSet<_>>();
    let edges = facts
        .edges
        .iter()
        .filter(|edge| node_set.contains(&edge.from) && node_set.contains(&edge.to))
        .collect::<Vec<_>>();
    let mut successors = empty_adjacency(node_ids);
    let mut predecessors = empty_adjacency(node_ids);
    for edge in edges {
        if node_set.contains(&edge.from) && node_set.contains(&edge.to) {
            successors
                .entry(edge.from.clone())
                .or_default()
                .insert(edge.to.clone());
            predecessors
                .entry(edge.to.clone())
                .or_default()
                .insert(edge.from.clone());
        }
    }
    let reachable = reachable_nodes(Some(entry), &successors);
    for node_id in node_ids {
        facts.reachability.push(ReachabilityFact {
            node_id: node_id.clone(),
            file: file.to_string(),
            function: function.to_string(),
            owner: owner.to_string(),
            reachable: reachable.contains(node_id),
        });
    }

    append_dominators(
        facts,
        file,
        owner,
        function,
        node_ids,
        Some(entry),
        &predecessors,
        &reachable,
    );

    let effects = facts
        .effects
        .iter()
        .filter(|effect| node_set.contains(&effect.node_id))
        .map(|effect| (effect.node_id.clone(), effect.clone()))
        .collect::<BTreeMap<_, _>>();
    let reaching = reaching_definitions(node_ids, &predecessors, &reachable, &effects);
    append_reaching_and_def_use(facts, file, owner, function, node_ids, &effects, &reaching);
    append_liveness(
        facts,
        file,
        owner,
        function,
        node_ids,
        &successors,
        &reachable,
        &effects,
    );
    append_flow_types(facts, file, owner, function, &node_set, &effects);
}

fn empty_adjacency(node_ids: &[String]) -> BTreeMap<String, BTreeSet<String>> {
    node_ids
        .iter()
        .map(|id| (id.clone(), BTreeSet::new()))
        .collect()
}

fn reachable_nodes(
    entry: Option<&str>,
    successors: &BTreeMap<String, BTreeSet<String>>,
) -> BTreeSet<String> {
    let mut reachable = BTreeSet::new();
    let mut queue = VecDeque::new();
    if let Some(entry) = entry {
        queue.push_back(entry.to_string());
    }
    while let Some(node) = queue.pop_front() {
        if !reachable.insert(node.clone()) {
            continue;
        }
        queue.extend(successors.get(&node).into_iter().flatten().cloned());
    }
    reachable
}

fn append_dominators(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    node_ids: &[String],
    entry: Option<&str>,
    predecessors: &BTreeMap<String, BTreeSet<String>>,
    reachable: &BTreeSet<String>,
) {
    let all = reachable.clone();
    let mut state = node_ids
        .iter()
        .map(|id| {
            let initial = if Some(id.as_str()) == entry {
                BTreeSet::from([id.clone()])
            } else if reachable.contains(id) {
                all.clone()
            } else {
                BTreeSet::new()
            };
            (id.clone(), initial)
        })
        .collect::<BTreeMap<_, _>>();
    worklist::solve(node_ids, &mut state, |id, values| {
        if Some(id.as_str()) == entry {
            return BTreeSet::from([id.clone()]);
        }
        if !reachable.contains(id) {
            return BTreeSet::new();
        }
        let incoming = predecessors
            .get(id)
            .into_iter()
            .flatten()
            .filter(|pred| reachable.contains(*pred))
            .collect::<Vec<_>>();
        let mut intersection = incoming
            .first()
            .and_then(|pred| values.get(*pred))
            .cloned()
            .unwrap_or_default();
        for pred in incoming.iter().skip(1) {
            intersection = intersection
                .intersection(values.get(*pred).unwrap_or(&BTreeSet::new()))
                .cloned()
                .collect();
        }
        intersection.insert(id.clone());
        intersection
    });

    for id in node_ids {
        let immediate_dominator = if Some(id.as_str()) == entry || !reachable.contains(id) {
            None
        } else {
            state[id]
                .iter()
                .filter(|candidate| *candidate != id)
                .max_by_key(|candidate| state.get(*candidate).map_or(0, BTreeSet::len))
                .cloned()
        };
        facts.dominators.push(DominatorFact {
            node_id: id.clone(),
            file: file.to_string(),
            function: function.to_string(),
            owner: owner.to_string(),
            immediate_dominator,
        });
    }
}

fn reaching_definitions(
    node_ids: &[String],
    predecessors: &BTreeMap<String, BTreeSet<String>>,
    reachable: &BTreeSet<String>,
    effects: &BTreeMap<String, super::NodeEffect>,
) -> BTreeMap<String, DefinitionState> {
    let mut state = node_ids
        .iter()
        .map(|id| (id.clone(), DefinitionState::new()))
        .collect::<BTreeMap<_, _>>();
    worklist::solve(node_ids, &mut state, |id, values| {
        if !reachable.contains(id) {
            return DefinitionState::new();
        }
        let mut joined = DefinitionState::new();
        for pred in predecessors.get(id).into_iter().flatten() {
            if !reachable.contains(pred) {
                continue;
            }
            for (place, definitions) in values.get(pred).into_iter().flatten() {
                joined
                    .entry(place.clone())
                    .or_default()
                    .extend(definitions.iter().cloned());
            }
        }
        if let Some(effect) = effects.get(id) {
            for place in &effect.writes {
                joined.insert(place.clone(), BTreeSet::from([id.clone()]));
            }
        }
        joined
    });
    state
}

fn append_reaching_and_def_use(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    node_ids: &[String],
    effects: &BTreeMap<String, super::NodeEffect>,
    reaching_out: &BTreeMap<String, DefinitionState>,
) {
    let predecessor_map = facts
        .edges
        .iter()
        .filter(|edge| edge.file == file && edge.owner == owner && edge.function == function)
        .fold(
            BTreeMap::<String, BTreeSet<String>>::new(),
            |mut map, edge| {
                map.entry(edge.to.clone())
                    .or_default()
                    .insert(edge.from.clone());
                map
            },
        );
    let mut uses_by_definition = BTreeMap::<(String, String), BTreeSet<String>>::new();
    for id in node_ids {
        let mut incoming = DefinitionState::new();
        for pred in predecessor_map.get(id).into_iter().flatten() {
            for (place, definitions) in reaching_out.get(pred).into_iter().flatten() {
                incoming
                    .entry(place.clone())
                    .or_default()
                    .extend(definitions.iter().cloned());
            }
        }
        for place in effects.get(id).into_iter().flat_map(|effect| &effect.reads) {
            let definitions = incoming.get(place).cloned().unwrap_or_default();
            for definition in &definitions {
                uses_by_definition
                    .entry((definition.clone(), place.clone()))
                    .or_default()
                    .insert(id.clone());
            }
            facts.reaching_definitions.push(ReachingDefinitionFact {
                node_id: id.clone(),
                file: file.to_string(),
                function: function.to_string(),
                owner: owner.to_string(),
                place_id: place.clone(),
                definitions: definitions.into_iter().collect(),
            });
        }
    }
    for ((definition_node_id, place_id), uses) in uses_by_definition {
        facts.def_use.push(DefUseFact {
            definition_node_id,
            file: file.to_string(),
            function: function.to_string(),
            owner: owner.to_string(),
            place_id,
            uses: uses.into_iter().collect(),
        });
    }
}

fn append_liveness(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    node_ids: &[String],
    successors: &BTreeMap<String, BTreeSet<String>>,
    reachable: &BTreeSet<String>,
    effects: &BTreeMap<String, super::NodeEffect>,
) {
    let mut order = node_ids.to_vec();
    order.reverse();
    let mut live_in = node_ids
        .iter()
        .map(|id| (id.clone(), BTreeSet::new()))
        .collect::<BTreeMap<_, _>>();
    worklist::solve(&order, &mut live_in, |id, values| {
        if !reachable.contains(id) {
            return BTreeSet::new();
        }
        let mut out = BTreeSet::new();
        for successor in successors.get(id).into_iter().flatten() {
            if reachable.contains(successor) {
                out.extend(values.get(successor).into_iter().flatten().cloned());
            }
        }
        let effect = effects.get(id);
        for write in effect.into_iter().flat_map(|effect| &effect.writes) {
            out.remove(write);
        }
        out.extend(effect.into_iter().flat_map(|effect| &effect.reads).cloned());
        out
    });

    for id in node_ids {
        let mut live_out = BTreeSet::new();
        if reachable.contains(id) {
            for successor in successors.get(id).into_iter().flatten() {
                if reachable.contains(successor) {
                    live_out.extend(live_in.get(successor).into_iter().flatten().cloned());
                }
            }
        }
        facts.liveness.push(LivenessFact {
            node_id: id.clone(),
            file: file.to_string(),
            function: function.to_string(),
            owner: owner.to_string(),
            live_in: live_in.remove(id).unwrap_or_default().into_iter().collect(),
            live_out: live_out.into_iter().collect(),
        });
    }
}

fn append_flow_types(
    facts: &mut ControlFlowFacts,
    file: &str,
    owner: &str,
    function: &str,
    node_set: &BTreeSet<String>,
    effects: &BTreeMap<String, super::NodeEffect>,
) {
    let definition_types = definition_type_hints(facts, node_set, effects);
    let reaching = facts
        .reaching_definitions
        .iter()
        .filter(|fact| node_set.contains(&fact.node_id))
        .cloned()
        .collect::<Vec<_>>();
    for fact in reaching {
        let hinted = fact
            .definitions
            .iter()
            .filter_map(|definition| {
                definition_types.get(&(definition.clone(), fact.place_id.clone()))
            })
            .collect::<Vec<_>>();
        let complete = !fact.definitions.is_empty()
            && hinted.len() == fact.definitions.len()
            && hinted
                .iter()
                .all(|hint| hint.complete && !hint.types.is_empty());
        let hints = hinted
            .into_iter()
            .flat_map(|hint| hint.types.iter().cloned())
            .collect::<BTreeSet<_>>();
        facts.flow_types.push(FlowTypeFact {
            node_id: fact.node_id,
            file: file.to_string(),
            function: function.to_string(),
            owner: owner.to_string(),
            place_id: fact.place_id,
            types: hints.into_iter().collect(),
            complete,
        });
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct DefinitionTypeHint {
    types: BTreeSet<String>,
    complete: bool,
}

fn definition_type_hints(
    facts: &ControlFlowFacts,
    node_set: &BTreeSet<String>,
    effects: &BTreeMap<String, super::NodeEffect>,
) -> BTreeMap<(String, String), DefinitionTypeHint> {
    let reaching = facts
        .reaching_definitions
        .iter()
        .filter(|fact| node_set.contains(&fact.node_id))
        .map(|fact| {
            (
                (fact.node_id.clone(), fact.place_id.clone()),
                fact.definitions.clone(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut state = BTreeMap::new();

    for (node_id, effect) in effects {
        for (place, hint) in &effect.write_type_hints {
            state.insert(
                (node_id.clone(), place.clone()),
                DefinitionTypeHint {
                    types: BTreeSet::from([hint.clone()]),
                    complete: true,
                },
            );
        }
        for place in effect.write_sources.keys() {
            state.entry((node_id.clone(), place.clone())).or_default();
        }
    }

    loop {
        let previous = state.clone();
        let mut changed = false;
        for (node_id, effect) in effects {
            for (target, source) in &effect.write_sources {
                let definitions = reaching
                    .get(&(node_id.clone(), source.clone()))
                    .cloned()
                    .unwrap_or_default();
                let source_hints = definitions
                    .iter()
                    .filter_map(|definition| previous.get(&(definition.clone(), source.clone())))
                    .collect::<Vec<_>>();
                let next = DefinitionTypeHint {
                    types: source_hints
                        .iter()
                        .flat_map(|hint| hint.types.iter().cloned())
                        .collect(),
                    complete: !definitions.is_empty()
                        && source_hints.len() == definitions.len()
                        && source_hints
                            .iter()
                            .all(|hint| hint.complete && !hint.types.is_empty()),
                };
                let key = (node_id.clone(), target.clone());
                if previous.get(&key) != Some(&next) {
                    state.insert(key, next);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    state
}
