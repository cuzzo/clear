use crate::ast::{self, Child, Node};
use crate::type_inference::TypeExpr;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

use super::{
    normalized_behavior::{
        BlockCallSemantics, CardinalityCallSemantics, CollectionAllocationSemantics,
        NormalizedLanguageBehavior,
    },
    Document,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MethodComplexityFacts {
    pub path: String,
    pub owner: String,
    pub function: String,
    pub line: usize,
    pub span: [usize; 4],
    pub parameters: Vec<String>,
    pub collection_parameters: Vec<String>,
    pub iterations: Vec<IterationFact>,
    pub recursion: RecursionFacts,
    pub allocations: Vec<AllocationFact>,
    pub call_contexts: Vec<CallContainmentFact>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AllocationFact {
    pub line: usize,
    pub span: [usize; 4],
    pub kind: String,
    pub parameter_domains: Vec<String>,
    pub domain_expression: Vec<String>,
    pub cardinality_relation: String,
    pub bound_classification: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CallContainmentFact {
    pub line: usize,
    pub span: [usize; 4],
    pub message: String,
    pub execution_multiplicity: String,
    pub power: usize,
    pub parameter_arguments: Vec<String>,
    pub argument_cardinality_relation: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IterationFact {
    pub line: usize,
    pub span: [usize; 4],
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub parameter_domains: Vec<String>,
    #[serde(default)]
    pub state_domains: Vec<String>,
    pub domain_expression: Vec<String>,
    pub cardinality_relation: String,
    pub bound_classification: String,
    pub execution_multiplicity: String,
    pub power: usize,
    pub fixed: bool,
    pub amortized: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RecursionFacts {
    pub calls: usize,
    pub shrinking_calls: usize,
    pub halving_calls: usize,
    pub loop_contained_shrinking_calls: usize,
    pub unknown_progress_calls: usize,
}

#[derive(Clone, Debug)]
struct Assignment {
    line: usize,
    column: usize,
    dependencies: BTreeSet<String>,
    cardinality_dependencies: BTreeSet<String>,
    shrinking: bool,
    halving: bool,
    empty_collection: bool,
}

#[derive(Clone, Debug, Default)]
struct CollectionGrowth {
    power: usize,
}

#[derive(Clone, Debug, Default)]
struct LoopContext {
    power: usize,
    params: BTreeSet<String>,
    independent_collection_bindings: BTreeSet<String>,
    partition_locals: BTreeSet<String>,
    cursor: Option<String>,
    absorb_next: bool,
    root_line: Option<usize>,
    collapse_direct_child: bool,
    unknown: bool,
}

pub(crate) fn facts(document: &Document) -> Vec<MethodComplexityFacts> {
    let behavior = super::normalized_behavior::behavior(document.language);
    document
        .local_methods
        .iter()
        .filter_map(|method| {
            let definition = document
                .function_defs
                .iter()
                .find(|row| row.name == method.name && row.line == method.line);
            let params = definition
                .map(|row| row.params.iter().cloned().collect::<BTreeSet<_>>())
                .unwrap_or_default();
            let owner = definition
                .map(|row| row.owner.as_str())
                .unwrap_or(&method.owner);
            let state_types = document
                .state_declarations
                .iter()
                .filter(|state| state.owner == owner)
                .filter_map(|state| {
                    state.r#type.as_deref().map(|declared_type| {
                        (
                            state.field.trim_start_matches('@').to_string(),
                            TypeExpr::parse(declared_type, document.language.as_str()),
                        )
                    })
                })
                .collect::<BTreeMap<_, _>>();
            let mut scoped_type_aliases = document.type_aliases.clone();
            for (name, target) in &document.type_aliases {
                if name.starts_with(&format!("{owner}::")) {
                    if let Some(short) = name.rsplit("::").next() {
                        scoped_type_aliases
                            .entry(short.to_string())
                            .or_insert_with(|| target.clone());
                    }
                }
            }
            let type_key = format!("{}\u{0}{}", owner, method.name);
            let collection_parameters = document
                .method_param_types
                .get(&type_key)
                .into_iter()
                .flat_map(|types| types.iter())
                .filter(|(_, value)| behavior.collection_parameter_type(value))
                .map(|(name, _)| name.clone())
                .collect::<BTreeSet<_>>();
            fact_for_method(
                &document.file,
                owner,
                &method.name,
                method.line,
                method.span,
                &method.node,
                &params,
                &collection_parameters,
                &state_types,
                &scoped_type_aliases,
                document.language.as_str(),
                behavior,
            )
        })
        .collect()
}

fn fact_for_method(
    path: &str,
    owner: &str,
    function: &str,
    line: usize,
    span: [usize; 4],
    node: &Node,
    params: &BTreeSet<String>,
    collection_parameters: &BTreeSet<String>,
    state_types: &BTreeMap<String, TypeExpr>,
    type_aliases: &BTreeMap<String, String>,
    language: &str,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<MethodComplexityFacts> {
    let mut assignments = BTreeMap::<String, Vec<Assignment>>::new();
    collect_assignments(node, &mut assignments, behavior);
    let mut max_power = 0;
    let mut evidence = Vec::new();
    let mut call_contexts = Vec::new();
    let mut collection_growth = BTreeMap::new();
    visit_loops(
        node,
        params,
        &assignments,
        &LoopContext::default(),
        &mut max_power,
        &mut evidence,
        &mut call_contexts,
        &mut collection_growth,
        state_types,
        type_aliases,
        language,
        behavior,
    );
    let mut recursion = RecursionFacts::default();
    collect_recursion(node, function, false, &assignments, &mut recursion, behavior);
    recursion.unknown_progress_calls = recursion
        .calls
        .saturating_sub(recursion.shrinking_calls + recursion.halving_calls);
    let mut allocations = Vec::new();
    collect_allocations(node, params, &assignments, &mut allocations, behavior);
    allocations.sort_by_key(|fact| (fact.line, fact.span[1], fact.kind.clone()));
    allocations.dedup_by(|left, right| left.span == right.span && left.kind == right.kind);

    if evidence.is_empty() && recursion.calls == 0 && allocations.is_empty() && call_contexts.is_empty() {
        return None;
    }

    Some(MethodComplexityFacts {
        path: path.to_string(),
        owner: owner.to_string(),
        function: function.to_string(),
        line,
        span,
        parameters: params.iter().cloned().collect(),
        collection_parameters: collection_parameters.iter().cloned().collect(),
        iterations: evidence,
        recursion,
        allocations,
        call_contexts,
    })
}

fn collect_allocations(
    node: &Node,
    params: &BTreeSet<String>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    output: &mut Vec<AllocationFact>,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if let Some(message) = direct_call_message(node) {
        let semantics = behavior.collection_allocation_semantics(message);
        if semantics != CollectionAllocationSemantics::None {
            let domain_expression = call_receiver(node).map(local_names).unwrap_or_default();
            let parameter_domains = parameter_domains(
                &domain_expression,
                params,
                assignments,
                (node.first_lineno, node.first_column),
            );
            let receiver = call_receiver(node);
            let receiver_is_call = receiver.is_some_and(call_has_arguments);
            let fixed_receiver = receiver.is_some_and(|value| {
                matches!(value.r#type.as_str(), "ARRAY" | "HASH" | "LIST") && local_names(value).is_empty()
            });
            let (relation, bound) = if semantics == CollectionAllocationSemantics::UnknownSize || receiver_is_call {
                ("unknown", "unknown")
            } else if !parameter_domains.is_empty() {
                ("same", "input")
            } else if fixed_receiver {
                ("fixed", "fixed")
            } else {
                ("unknown", "unknown")
            };
            output.push(AllocationFact {
                line: node.first_lineno,
                span: [
                    node.first_lineno,
                    node.first_column,
                    node.last_lineno,
                    node.last_column,
                ],
                kind: message.to_string(),
                parameter_domains: parameter_domains.into_iter().collect(),
                domain_expression: domain_expression.into_iter().collect(),
                cardinality_relation: relation.to_string(),
                bound_classification: bound.to_string(),
            });
        }
    }
    for child in child_nodes(node) {
        collect_allocations(child, params, assignments, output, behavior);
    }
}

fn visit_loops(
    node: &Node,
    params: &BTreeSet<String>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    parent: &LoopContext,
    max_power: &mut usize,
    evidence: &mut Vec<IterationFact>,
    call_contexts: &mut Vec<CallContainmentFact>,
    collection_growth: &mut BTreeMap<String, CollectionGrowth>,
    state_types: &BTreeMap<String, TypeExpr>,
    type_aliases: &BTreeMap<String, String>,
    language: &str,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    let block_semantics = if node.r#type == "ITER" {
        iterator_message(node)
            .map(|message| behavior.block_call_semantics(message))
            .unwrap_or(BlockCallSemantics::Unknown)
    } else {
        BlockCallSemantics::Iteration
    };
    if node.r#type == "ITER" && block_semantics == BlockCallSemantics::Once {
        for child in child_nodes(node) {
            visit_loops(
                child,
                params,
                assignments,
                parent,
                max_power,
                evidence,
                call_contexts,
                collection_growth,
                state_types,
                type_aliases,
                language,
                behavior,
            );
        }
        return;
    }
    if loop_node(node, behavior) {
        let control = loop_control(node);
        let growth_control = control.and_then(|control| {
            if matches!(node.r#type.as_str(), "WHILE" | "UNTIL") {
                comparison_control(control).or(Some(control))
            } else {
                Some(control)
            }
        });
        let locals = growth_control
            .map(|control| iteration_local_names(control, behavior))
            .unwrap_or_default();
        let domain_names = growth_control
            .map(|control| iteration_domain_names(control, behavior))
            .unwrap_or_default();
        let refs = parameter_domains(
            &domain_names,
            params,
            assignments,
            (node.first_lineno, node.first_column),
        );
        let states = state_names(growth_control.unwrap_or(node));
        let growth_power = locals
            .iter()
            .filter_map(|name| collection_growth.get(name).map(|growth| growth.power))
            .max();
        let unknown_iteration = node.r#type == "ITER" && block_semantics == BlockCallSemantics::Unknown;
        let fixed = !unknown_iteration
            && refs.is_empty()
            && states.is_empty()
            && locals.is_empty()
            && growth_power.is_none();
        let cursor = growth_control.and_then(|row| {
            local_names(row)
                .into_iter()
                .find(|name| !params.contains(name))
        });
        let amortized = matches!(node.r#type.as_str(), "WHILE" | "UNTIL")
            && !refs.is_empty()
            && refs.is_subset(&parent.params)
            && cursor.as_ref().is_some_and(|cursor| {
                parent.cursor.as_ref().is_some_and(|outer| {
                    derived_from(
                        cursor,
                        outer,
                        (node.first_lineno, node.first_column),
                        assignments,
                    )
                })
            });
        let mut power = parent.power;
        if parent.collapse_direct_child && !refs.is_empty() {
            power = parent.power;
        } else if parent.absorb_next {
            power = parent.power;
        } else if !fixed {
            power = if let Some(growth_power) = growth_power {
                parent.power + growth_power
            } else if !locals.is_disjoint(&parent.independent_collection_bindings) {
                parent.power + 1
            } else if refs.is_empty() {
                power.max(1)
            } else if amortized {
                power.max(1)
            } else {
                power + 1
            };
        }
        let fixpoint = fixpoint_loop(node, control, behavior);
        if fixpoint {
            power = power.max(parent.power + 2);
        }
        *max_power = (*max_power).max(power);
        let relation = if unknown_iteration {
            "unknown"
        } else if fixed {
            "fixed"
        } else if !locals.is_disjoint(&parent.independent_collection_bindings) {
            "independent_of"
        } else if amortized || parent.collapse_direct_child || parent.absorb_next || (refs.is_empty() && states.is_empty()) {
            "partition_of"
        } else {
            "independent_of"
        };
        evidence.push(IterationFact {
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            kind: node.r#type.clone(),
            message: iterator_message(node).map(ToString::to_string),
            parameter_domains: refs.iter().cloned().collect(),
            state_domains: states.iter().cloned().collect(),
            domain_expression: domain_names.iter().cloned().collect(),
            cardinality_relation: relation.to_string(),
            bound_classification: if unknown_iteration { "unknown" } else if fixed { "fixed" } else { "input" }.to_string(),
            execution_multiplicity: if unknown_iteration { "unknown".to_string() } else { polynomial(power) },
            power,
            fixed,
            amortized,
        });
        let root_line = parent.root_line.or(Some(node.first_lineno));
        let bindings = loop_binding_names(node);
        let independent_collection_bindings = if iterator_message(node)
            .is_some_and(|message| behavior.iteration_yields_collection_value(message))
            && states.len() == 1
            && states
                .iter()
                .next()
                .and_then(|state| state_types.get(state.trim_start_matches('@')))
                .is_some_and(|state_type| {
                    iteration_yields_collection_value(state_type, type_aliases, language)
                })
        {
            bindings.clone()
        } else {
            BTreeSet::new()
        };
        let context = LoopContext {
            power,
            params: refs,
            independent_collection_bindings,
            partition_locals: bindings,
            cursor,
            absorb_next: fixpoint,
            root_line,
            collapse_direct_child: linear_worklist(node, assignments, root_line, params, behavior),
            unknown: parent.unknown || unknown_iteration,
        };
        // Iterator receiver/control expressions are evaluated before the loop;
        // only the normalized body is loop-contained. Treating a chained
        // `sort_by(...).map(...)` receiver as a nested loop fabricated powers.
        if let Some(control) = control {
            visit_loops(
                control,
                params,
                assignments,
                parent,
                max_power,
                evidence,
                call_contexts,
                collection_growth,
                state_types,
                type_aliases,
                language,
                behavior,
            );
        }
        if let Some(body) = loop_body(node) {
            visit_loops(
                body,
                params,
                assignments,
                &context,
                max_power,
                evidence,
                call_contexts,
                collection_growth,
                state_types,
                type_aliases,
                language,
                behavior,
            );
        }
    } else {
        record_collection_growth(node, parent, collection_growth, behavior);
        if let Some(message) = direct_call_message(node) {
            let argument_names = call_argument_nodes(node)
                .into_iter()
                .flat_map(local_names)
                .collect::<BTreeSet<_>>();
            let argument_domains = parameter_domains(
                &argument_names,
                params,
                assignments,
                (node.first_lineno, node.first_column),
            );
            let argument_cardinality_relation = if parent.power == 0 {
                "same"
            } else if !argument_names.is_disjoint(&parent.partition_locals) {
                "partition_of"
            } else if !argument_domains.is_empty() {
                "independent_of"
            } else {
                "unknown"
            };
            call_contexts.push(CallContainmentFact {
                    line: node.first_lineno,
                    span: [
                        node.first_lineno,
                        node.first_column,
                        node.last_lineno,
                        node.last_column,
                    ],
                    message: message.to_string(),
                    execution_multiplicity: if parent.unknown { "unknown".to_string() } else { polynomial(parent.power) },
                    power: parent.power,
                    parameter_arguments: local_names(node)
                        .intersection(params)
                        .cloned()
                        .collect(),
                    argument_cardinality_relation: argument_cardinality_relation.to_string(),
            });
        }
        for child in child_nodes(node) {
            visit_loops(
                child,
                params,
                assignments,
                parent,
                max_power,
                evidence,
                call_contexts,
                collection_growth,
                state_types,
                type_aliases,
                language,
                behavior,
            );
        }
    }
}

fn record_collection_growth(
    node: &Node,
    context: &LoopContext,
    growth: &mut BTreeMap<String, CollectionGrowth>,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if context.power == 0 {
        return;
    }
    let receiver = if matches!(node.r#type.as_str(), "OP_ASGN1" | "ATTRASGN") {
        node.children.first().and_then(ast::node)
    } else if direct_call_message(node)
        .is_some_and(|message| behavior.mutating_receiver_message(message))
    {
        call_receiver(node)
    } else {
        None
    };
    let Some(receiver) = receiver else {
        return;
    };
    for name in local_names(receiver) {
        let entry = growth.entry(name).or_default();
        entry.power = entry.power.max(context.power);
    }
}

fn comparison_control(node: &Node) -> Option<&Node> {
    if direct_call_message(node).is_some_and(|message| matches!(message, "<" | "<=" | ">" | ">=")) {
        return Some(node);
    }
    child_nodes(node).into_iter().find_map(comparison_control)
}

fn fixpoint_loop(
    node: &Node,
    control: Option<&Node>,
    behavior: &dyn NormalizedLanguageBehavior,
) -> bool {
    if !matches!(node.r#type.as_str(), "WHILE" | "UNTIL") {
        return false;
    }
    let Some(control) = control else {
        return false;
    };
    if !matches!(control.r#type.as_str(), "LVAR" | "DVAR") {
        return false;
    }
    let Some(flag) = first_local_name(control) else {
        return false;
    };
    let Some(body) = loop_body(node) else {
        return false;
    };
    contains_boolean_assignment(body, &flag, true)
        && contains_boolean_assignment(body, &flag, false)
        && contains_loop(body, behavior)
}

fn collect_assignments(
    node: &Node,
    output: &mut BTreeMap<String, Vec<Assignment>>,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if matches!(node.r#type.as_str(), "LASGN" | "DASGN") {
        if let Some(name) = child_string(node.children.first()) {
            let dependencies = node
                .children
                .get(1)
                .and_then(ast::node)
                .map(local_names)
                .unwrap_or_default();
            let rhs = node.children.get(1).and_then(ast::node);
            let symbols = rhs.map(descendant_symbols).unwrap_or_default();
            output
                .entry(name.to_string())
                .or_default()
                .push(Assignment {
                    line: node.first_lineno,
                    column: node.first_column,
                    dependencies,
                    cardinality_dependencies: rhs
                        .map(|value| cardinality_names(value, behavior))
                        .unwrap_or_default(),
                    shrinking: symbols.iter().any(|symbol| symbol == "-"),
                    halving: symbols
                        .iter()
                        .any(|symbol| matches!(symbol.as_str(), "/" | ">>")),
                    empty_collection: rhs.is_some_and(|value| empty_collection_expression(value, behavior)),
                });
        }
    }
    for child in child_nodes(node) {
        collect_assignments(child, output, behavior);
    }
}

fn linear_worklist(
    node: &Node,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    root_line: Option<usize>,
    params: &BTreeSet<String>,
    behavior: &dyn NormalizedLanguageBehavior,
) -> bool {
    if !matches!(node.r#type.as_str(), "WHILE" | "UNTIL") {
        return false;
    }
    let Some(control) = loop_control(node) else {
        return false;
    };
    if !descendant_symbols(control)
        .iter()
        .any(|symbol| behavior.empty_check_call(symbol))
    {
        return false;
    }
    let Some(body) = loop_body(node) else {
        return false;
    };
    let body_locals = local_names(body);
    let symbols = descendant_symbols(body);
    let parameter_visited_set = body_locals.intersection(params).count() >= 2
        && symbols.iter().any(|symbol| behavior.visited_membership_call(symbol))
        && symbols.iter().any(|symbol| behavior.visited_insert_call(symbol));
    if parameter_visited_set {
        return true;
    }
    let before = root_line.unwrap_or(node.first_lineno);
    assignments.iter().any(|(name, rows)| {
        body_locals.contains(name)
            && rows
                .iter()
                .any(|row| row.line < before && row.empty_collection)
    })
}

fn empty_collection_expression(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> bool {
    matches!(node.r#type.as_str(), "ARRAY" | "HASH")
        || (matches!(node.r#type.as_str(), "CALL" | "VCALL" | "FCALL")
            && descendant_symbols(node)
                .iter()
                .any(|symbol| behavior.empty_collection_constructor(symbol)))
}

fn derived_from(
    variable: &str,
    target: &str,
    before: (usize, usize),
    assignments: &BTreeMap<String, Vec<Assignment>>,
) -> bool {
    if variable == target {
        return true;
    }
    let Some(row) = assignments.get(variable).and_then(|rows| {
        rows.iter()
            .rev()
            .find(|row| (row.line, row.column) < before)
    }) else {
        return false;
    };
    row.dependencies
        .iter()
        .any(|dep| derived_from(dep, target, (row.line, row.column), assignments))
}

fn parameter_domains(
    names: &BTreeSet<String>,
    params: &BTreeSet<String>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    before: (usize, usize),
) -> BTreeSet<String> {
    let mut output = BTreeSet::new();
    for local in names {
        collect_parameter_dependencies(local, params, assignments, before, &mut output);
    }
    output
}

fn collect_parameter_dependencies(
    variable: &str,
    params: &BTreeSet<String>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    before: (usize, usize),
    output: &mut BTreeSet<String>,
) {
    if params.contains(variable) {
        output.insert(variable.to_string());
        return;
    }
    let Some(row) = assignments.get(variable).and_then(|rows| {
        rows.iter()
            .rev()
            .find(|row| (row.line, row.column) < before)
    }) else {
        return;
    };
    for dependency in &row.cardinality_dependencies {
        collect_parameter_dependencies(
            dependency,
            params,
            assignments,
            (row.line, row.column),
            output,
        );
    }
}

fn cardinality_names(
    node: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> BTreeSet<String> {
    if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
        return local_names(node);
    }

    let message = direct_call_message(node);
    let normalized_operator = message.is_some_and(|message| {
        matches!(
            message,
            "+" | "-"
                | "/"
                | ">>"
                | "!"
                | "&&"
                | "||"
                | "and"
                | "or"
                | "<"
                | "<="
                | ">"
                | ">="
        )
    });
    if normalized_operator {
        return local_names(node);
    }
    if let Some(message) = message {
        if behavior.cardinality_call_semantics(message) != CardinalityCallSemantics::Unknown {
            return call_receiver(node).map(local_names).unwrap_or_else(|| local_names(node));
        }
    }
    if message.is_some() {
        return BTreeSet::new();
    }

    child_nodes(node)
        .into_iter()
        .flat_map(|child| cardinality_names(child, behavior))
        .collect()
}

fn iteration_domain_names(
    node: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> BTreeSet<String> {
    let arguments = call_argument_nodes(node);
    if let Some(index) = direct_call_message(node)
        .and_then(|message| behavior.iteration_bound_argument(message, arguments.len()))
    {
        return arguments
            .get(index)
            .map(|argument| cardinality_names(argument, behavior))
            .unwrap_or_default();
    }
    if direct_call_message(node).is_some() {
        let Some(receiver) = call_receiver(node) else {
            return local_names(node);
        };
        if contains_index_access(receiver) || call_has_arguments(receiver) {
            return BTreeSet::new();
        }
        return local_names(receiver);
    }
    cardinality_names(node, behavior)
}

fn iteration_local_names(
    node: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> BTreeSet<String> {
    let arguments = call_argument_nodes(node);
    if let Some(index) = direct_call_message(node)
        .and_then(|message| behavior.iteration_bound_argument(message, arguments.len()))
    {
        return arguments.get(index).map(|argument| local_names(argument)).unwrap_or_default();
    }
    local_names(node)
}

fn call_argument_nodes(node: &Node) -> Vec<&Node> {
    node.children
        .iter()
        .filter_map(ast::node)
        .find(|child| matches!(child.r#type.as_str(), "LIST" | "ARGS" | "ARGUMENT_LIST"))
        .map(child_nodes)
        .unwrap_or_default()
}

fn call_receiver(node: &Node) -> Option<&Node> {
    if node.r#type != "CALL" {
        return None;
    }
    node.children.first().and_then(ast::node)
}

fn contains_index_access(node: &Node) -> bool {
    direct_call_message(node) == Some("[]")
        || child_nodes(node).into_iter().any(contains_index_access)
}

fn call_has_arguments(node: &Node) -> bool {
    child_nodes(node).into_iter().any(|child| {
        (matches!(child.r#type.as_str(), "LIST" | "ARGS" | "ARGUMENT_LIST")
            && child
                .children
                .iter()
                .any(|argument| !matches!(argument, Child::Nil)))
            || call_has_arguments(child)
    })
}

fn collect_recursion(
    node: &Node,
    function: &str,
    inside_loop: bool,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    out: &mut RecursionFacts,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    let now_inside = inside_loop || loop_node(node, behavior);
    if recursive_self_call(node, function) {
        out.calls += 1;
        let symbols = descendant_symbols(node);
        let assigned_shape = local_names(node)
            .iter()
            .filter_map(|name| {
                assignments
                    .get(name)
                    .and_then(|rows| rows.iter().rev().find(|row| row.line < node.first_lineno))
            })
            .fold((false, false), |shape, row| {
                (shape.0 || row.shrinking, shape.1 || row.halving)
            });
        if symbols
            .iter()
            .any(|symbol| matches!(symbol.as_str(), "/" | ">>"))
            || assigned_shape.1
        {
            out.halving_calls += 1;
        } else if symbols.iter().any(|symbol| symbol == "-") || assigned_shape.0 {
            out.shrinking_calls += 1;
            if now_inside {
                out.loop_contained_shrinking_calls += 1;
            }
        }
    }
    for child in child_nodes(node) {
        collect_recursion(child, function, now_inside, assignments, out, behavior);
    }
}

fn recursive_self_call(node: &Node, function: &str) -> bool {
    if direct_call_message(node) != Some(function) {
        return false;
    }
    match node.r#type.as_str() {
        "VCALL" | "FCALL" => true,
        "CALL" => call_receiver(node).is_some_and(|receiver| receiver.r#type == "SELF"),
        _ => false,
    }
}

fn direct_call_message(node: &Node) -> Option<&str> {
    if !matches!(node.r#type.as_str(), "CALL" | "VCALL" | "FCALL" | "OPCALL") {
        return None;
    }
    node.children.iter().find_map(|child| match child {
        Child::Symbol(value) => Some(value.as_str()),
        _ => None,
    })
}

fn descendant_symbols(node: &Node) -> Vec<String> {
    let mut output = Vec::new();
    for child in &node.children {
        match child {
            Child::Symbol(value) => output.push(value.clone()),
            Child::Node(child) => output.extend(descendant_symbols(child)),
            _ => {}
        }
    }
    output
}

fn loop_node(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> bool {
    matches!(node.r#type.as_str(), "FOR" | "WHILE" | "UNTIL")
        || (node.r#type == "ITER"
            && iterator_message(node).is_some_and(|message| {
                behavior.block_call_semantics(message) != BlockCallSemantics::Once
            }))
}

fn iterator_message(node: &Node) -> Option<&str> {
    node.children
        .first()
        .and_then(ast::node)
        .and_then(direct_call_message)
}

fn loop_control(node: &Node) -> Option<&Node> {
    let index = if node.r#type == "FOR" && node.children.len() >= 3 {
        1
    } else {
        0
    };
    node.children.get(index).and_then(ast::node)
}

fn loop_body(node: &Node) -> Option<&Node> {
    node.children
        .get(match node.r#type.as_str() {
            "FOR" if node.children.len() >= 3 => 2,
            "FOR" | "ITER" | "WHILE" | "UNTIL" => 1,
            _ => return None,
        })
        .and_then(ast::node)
}

fn loop_binding_names(node: &Node) -> BTreeSet<String> {
    if node.r#type == "FOR" {
        return node.children.first().and_then(ast::node).map(local_names).unwrap_or_default();
    }
    if node.r#type != "ITER" {
        return BTreeSet::new();
    }

    loop_body(node)
        .and_then(|body| {
            child_nodes(body)
                .into_iter()
                .find(|child| matches!(child.r#type.as_str(), "ARGS" | "ARGUMENT_LIST"))
        })
        .map(binding_names)
        .unwrap_or_default()
}

fn binding_names(node: &Node) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for child in &node.children {
        match child {
            Child::String(value) | Child::Symbol(value) => {
                names.insert(value.clone());
            }
            Child::Node(child) => names.extend(binding_names(child)),
            _ => {}
        }
    }
    names
}

fn contains_loop(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> bool {
    child_nodes(node)
        .into_iter()
        .any(|child| loop_node(child, behavior) || contains_loop(child, behavior))
}

fn contains_boolean_assignment(node: &Node, name: &str, value: bool) -> bool {
    let matches = matches!(node.r#type.as_str(), "LASGN" | "DASGN")
        && child_string(node.children.first()) == Some(name)
        && node.children.get(1).is_some_and(|child| match child {
            Child::Bool(actual) => *actual == value,
            Child::Node(rhs) => rhs.r#type == if value { "TRUE" } else { "FALSE" },
            _ => false,
        });
    matches
        || child_nodes(node)
            .into_iter()
            .any(|child| contains_boolean_assignment(child, name, value))
}

fn first_local_name(node: &Node) -> Option<String> {
    if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
        return child_string(node.children.first()).map(ToString::to_string);
    }
    child_nodes(node).into_iter().find_map(first_local_name)
}

fn local_names(node: &Node) -> BTreeSet<String> {
    let mut output = BTreeSet::new();
    if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
        if let Some(name) = child_string(node.children.first()) {
            output.insert(name.to_string());
        }
    }
    for child in child_nodes(node) {
        output.extend(local_names(child));
    }
    output
}

fn state_names(node: &Node) -> BTreeSet<String> {
    let mut output = BTreeSet::new();
    if matches!(node.r#type.as_str(), "IVAR" | "CVAR" | "GVAR") {
        if let Some(name) = child_string(node.children.first()) {
            output.insert(name.to_string());
        } else if !node.text.trim().is_empty() {
            output.insert(node.text.trim().to_string());
        }
    }
    for child in child_nodes(node) {
        output.extend(state_names(child));
    }
    output
}

fn iteration_yields_collection_value(
    receiver_type: &TypeExpr,
    aliases: &BTreeMap<String, String>,
    language: &str,
) -> bool {
    let mut seen = BTreeSet::new();
    let receiver_type = resolve_alias_type(receiver_type, aliases, language, &mut seen);
    let yielded = match &receiver_type {
        TypeExpr::Hash { value, .. } => Some(value.as_ref()),
        _ => None,
    };
    yielded.is_some_and(|yielded| {
        let mut seen = BTreeSet::new();
        matches!(
            resolve_alias_type(yielded, aliases, language, &mut seen),
            TypeExpr::Array(_) | TypeExpr::Hash { .. } | TypeExpr::Set(_)
        )
    })
}

fn resolve_alias_type(
    value: &TypeExpr,
    aliases: &BTreeMap<String, String>,
    language: &str,
    seen: &mut BTreeSet<String>,
) -> TypeExpr {
    match value {
        TypeExpr::Nilable(inner) => resolve_alias_type(inner, aliases, language, seen),
        TypeExpr::Primitive(name) => {
            let short = name.split("::").last().unwrap_or(name);
            let Some(target) = aliases.get(name).or_else(|| aliases.get(short)) else {
                return value.clone();
            };
            if !seen.insert(name.clone()) {
                return value.clone();
            }
            resolve_alias_type(&TypeExpr::parse(target, language), aliases, language, seen)
        }
        _ => value.clone(),
    }
}

fn child_nodes(node: &Node) -> Vec<&Node> {
    node.children.iter().filter_map(ast::node).collect()
}

fn child_string(child: Option<&Child>) -> Option<&str> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value),
        _ => None,
    }
}

fn polynomial(power: usize) -> String {
    if power == 0 {
        "O(1)".to_string()
    } else if power == 1 {
        "O(N)".to_string()
    } else {
        format!("O(N^{power})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::{self, Language};
    use std::io::Write;

    fn ruby_facts(source: &str) -> Vec<MethodComplexityFacts> {
        let mut file = tempfile::Builder::new().suffix(".rb").tempfile().unwrap();
        file.write_all(source.as_bytes()).unwrap();
        let document = syntax::parse_file(file.path().to_path_buf(), Language::Ruby).unwrap();
        facts(&document)
    }

    fn complexity(rows: &[MethodComplexityFacts], name: &str) -> Option<String> {
        let row = rows.iter().find(|row| row.function == name)?;
        let recursion = &row.recursion;
        if row.iterations.iter().any(|fact| fact.cardinality_relation == "unknown")
            || recursion.unknown_progress_calls > 0
        {
            return Some("unknown".to_string());
        }
        if row.parameters.len() == 1 && recursion.loop_contained_shrinking_calls > 0 {
            return Some("O(N!)".to_string());
        }
        if row.parameters.len() == 1 && recursion.shrinking_calls >= 2 {
            return Some("O(2^N)".to_string());
        }
        if row.parameters.len() == 1 && recursion.halving_calls >= 2 {
            return Some("O(N)".to_string());
        }
        if row.parameters.len() == 1 && recursion.halving_calls == 1 {
            return Some("O(log N)".to_string());
        }
        if row.parameters.len() == 1 && recursion.shrinking_calls == 1 {
            return Some("O(N)".to_string());
        }
        row.iterations
            .iter()
            .max_by_key(|fact| fact.power)
            .map(|fact| fact.execution_multiplicity.clone())
    }

    #[test]
    fn normalized_loops_distinguish_fixed_hierarchical_cartesian_and_amortized_work() {
        let rows = ruby_facts(
            r#"
def fixed
  4.times { 8.times { consume } }
end

def hierarchy(documents)
  documents.each { |document| document.functions.each { |function| function.statements.each { consume } } }
end

def cartesian(xs, ys)
  xs.each { |x| ys.each { |y| consume(x, y) } }
end

def amortized(items)
  i = 0
  while i < items.length
    j = i + 1
    j += 1 while j < items.length
    i = j
  end
end

def independent(items)
  i = 0
  while i < items.length
    j = 0
    j += 1 while j < items.length
    i += 1
  end
end

def callback(items)
  with_context { items.each { consume } }
end

def unknown_result_sizes(paths, input)
  paths.each do |path|
    rows = lookup(path, input)
    rows.each do |row|
      edits = choose(row, input)
      edits.each { |edit| consume(edit) }
    end
  end
end


def indexed_children(buckets)
  buckets.each_key { |key| buckets[key].each { |item| consume(item) } }
end


def callback_result(paths, input)
  paths.each { |path| classify(path, input).map { |row| consume(row) } }
end

def materialize(items)
  items.map { |item| consume(item) }
end

def fixed_materialize
  [3, 1, 2].sort
end

def unknown_materialize
  local_items = lookup
  local_items.sort
end


sig { params(items: Array).returns(Array) }
def looped_call(items)
  items.each { expensive(items) }
end


def once_block(items)
  items.tap { consume(items) }
end

def no_complexity_fact
  1
end
"#,
        );
        assert_eq!(complexity(&rows, "fixed"), Some("O(1)".into()));
        assert_eq!(complexity(&rows, "hierarchy"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "cartesian"), Some("O(N^2)".into()));
        assert_eq!(complexity(&rows, "amortized"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "independent"), Some("O(N^2)".into()));
        assert_eq!(complexity(&rows, "callback"), Some("unknown".into()));
        assert_eq!(
            complexity(&rows, "unknown_result_sizes"),
            Some("O(N)".into())
        );
        assert_eq!(complexity(&rows, "indexed_children"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "callback_result"), Some("O(N)".into()));
        let materialize = rows.iter().find(|row| row.function == "materialize").unwrap();
        assert_eq!(materialize.allocations[0].cardinality_relation, "same");
        assert_eq!(materialize.allocations[0].parameter_domains, vec!["items"]);
        let fixed = rows.iter().find(|row| row.function == "fixed_materialize").unwrap();
        assert!(fixed.allocations.iter().any(|fact| fact.cardinality_relation == "fixed"));
        let unknown = rows.iter().find(|row| row.function == "unknown_materialize").unwrap();
        assert_eq!(unknown.allocations[0].cardinality_relation, "unknown");
        let callback_result = rows.iter().find(|row| row.function == "callback_result").unwrap();
        assert!(callback_result
            .allocations
            .iter()
            .any(|fact| fact.cardinality_relation == "unknown"));
        let looped = rows
            .iter()
            .find(|row| row.function == "looped_call")
            .unwrap();
        assert_eq!(looped.collection_parameters, vec!["items"]);
        assert!(looped.call_contexts.iter().any(|context| {
            context.message == "expensive" && context.execution_multiplicity == "O(N)"
        }));
        assert_eq!(complexity(&rows, "once_block"), None);
        assert_eq!(complexity(&rows, "no_complexity_fact"), None);
    }

    #[test]
    fn normalized_recursion_and_fixpoints_use_ast_call_and_assignment_facts() {
        let rows = ruby_facts(
            r#"
def linear(n)
  return if n <= 1
  linear(n - 1)
end
def binary(n)
  return if n <= 1
  binary(n / 2)
end
def split(n)
  return if n <= 1
  split(n / 2)
  split(n / 2)
end
def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end
def permute(items)
  items.each { |item| permute(items - [item]) }
end
def tree(node, seen)
  tree(node.left, seen)
  tree(node.right, seen)
end
class Accessor
  def ownership
    resolved.ownership
  end
end
def settle(items)
  changed = true
  while changed
    changed = false
    items.each { |item| changed = true if resolve(item) }
  end
end

def settle_groups(groups)
  groups.each do |items|
    changed = true
    while changed
      changed = false
      items.each { |item| changed = true if resolve(item) }
    end
  end
end

def settle_groups_with_object(groups)
  groups.each_with_object({}) do |items, output|
    changed = true
    while changed
      changed = false
      items.each { |item| changed = true if resolve(item) }
    end
  end
end
"#,
        );
        assert_eq!(complexity(&rows, "linear"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "binary"), Some("O(log N)".into()));
        assert_eq!(complexity(&rows, "split"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "fib"), Some("O(2^N)".into()));
        assert_eq!(complexity(&rows, "permute"), Some("O(N!)".into()));
        assert_eq!(complexity(&rows, "tree"), Some("unknown".into()));
        assert_eq!(
            rows.iter()
                .find(|row| row.function == "ownership")
                .unwrap()
                .recursion
                .calls,
            0
        );
        assert_eq!(complexity(&rows, "settle"), Some("O(N^2)".into()));
        assert_eq!(complexity(&rows, "settle_groups"), Some("O(N^3)".into()));
        assert_eq!(
            complexity(&rows, "settle_groups_with_object"),
            Some("O(N^3)".into())
        );
    }

    #[test]
    fn normalized_worklists_collapse_only_with_visited_set_evidence() {
        let rows = ruby_facts(
            r#"
def local_worklist(root)
  queue = [root]
  visited = {}
  while !queue.empty?
    queue.each do |node|
      next if visited.include?(node)
      visited.add(node)
      queue << node.child
    end
  end
end
def parameter_worklist(queue, visited)
  while !queue.empty?
    queue.each do |node|
      next if visited.include?(node)
      visited.add(node)
      queue << node.child
    end
  end
end
def repeated(queue)
  while !queue.empty?
    queue.each { |node| consume(node) }
  end
end
"#,
        );
        assert_eq!(complexity(&rows, "local_worklist"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "parameter_worklist"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "repeated"), Some("O(N^2)".into()));
    }

    #[test]
    fn fact_payload_preserves_normalized_evidence_and_owner() {
        let rows = ruby_facts(
            "class Box\n  def each_pair(xs, ys)\n    xs.each { ys.each { consume } }\n  end\nend\n",
        );
        let row = rows.iter().find(|row| row.function == "each_pair").unwrap();
        assert_eq!(row.owner, "Box");
        assert_eq!(row.iterations.len(), 2);
        assert_eq!(row.iterations[1].cardinality_relation, "independent_of");
        assert!(!row.call_contexts.is_empty());
    }

    #[test]
    fn normalized_node_helpers_cover_malformed_and_cycle_safe_fallbacks() {
        fn node(kind: &str, children: Vec<Child>) -> Node {
            Node {
                r#type: kind.to_string(),
                children,
                first_lineno: 1,
                first_column: 0,
                last_lineno: 1,
                last_column: 1,
                text: String::new(),
            }
        }
        let behavior = crate::syntax::ruby::behavior();

        let malformed_assignment = node("LASGN", vec![Child::Integer(1)]);
        let mut assignments = BTreeMap::new();
        collect_assignments(&malformed_assignment, &mut assignments, behavior);
        assert!(assignments.is_empty());

        assignments.insert(
            "a".into(),
            vec![Assignment {
                line: 1,
                column: 0,
                dependencies: BTreeSet::from(["b".into()]),
                cardinality_dependencies: BTreeSet::from(["b".into()]),
                shrinking: false,
                halving: false,
                empty_collection: false,
            }],
        );
        assignments.insert(
            "b".into(),
            vec![Assignment {
                line: 2,
                column: 0,
                dependencies: BTreeSet::from(["a".into()]),
                cardinality_dependencies: BTreeSet::from(["a".into()]),
                shrinking: false,
                halving: false,
                empty_collection: false,
            }],
        );
        let mut output = BTreeSet::new();
        collect_parameter_dependencies("a", &BTreeSet::new(), &assignments, (3, 0), &mut output);
        assert!(output.is_empty());

        let root = node(
            "ROOT",
            vec![Child::Node(Box::new(node(
                "LVAR",
                vec![Child::String("flag".into())],
            )))],
        );
        assert!(loop_body(&root).is_none());
        assert_eq!(first_local_name(&root).as_deref(), Some("flag"));
        assert!(first_local_name(&node("LVAR", vec![])).is_none());
        assert!(contains_boolean_assignment(
            &node(
                "LASGN",
                vec![Child::String("flag".into()), Child::Bool(true)]
            ),
            "flag",
            true,
        ));
        assert!(!contains_boolean_assignment(
            &node(
                "LASGN",
                vec![Child::String("flag".into()), Child::Integer(1)]
            ),
            "flag",
            true,
        ));

        assert!(!fixpoint_loop(&root, None, behavior));
        let while_without_control = node("WHILE", vec![]);
        assert!(!fixpoint_loop(&while_without_control, None, behavior));
        assert!(!fixpoint_loop(&while_without_control, Some(&root), behavior));
        let nameless_local = node("LVAR", vec![]);
        assert!(!fixpoint_loop(
            &while_without_control,
            Some(&nameless_local),
            behavior
        ));
        let flag_local = node("LVAR", vec![Child::String("flag".into())]);
        assert!(!fixpoint_loop(&while_without_control, Some(&flag_local), behavior));

        assert!(!linear_worklist(
            &root,
            &assignments,
            None,
            &BTreeSet::new(),
            behavior
        ));
        assert!(!linear_worklist(
            &while_without_control,
            &assignments,
            None,
            &BTreeSet::new(),
            behavior
        ));
        let ordinary_while = node("WHILE", vec![Child::Node(Box::new(flag_local.clone()))]);
        assert!(!linear_worklist(
            &ordinary_while,
            &assignments,
            None,
            &BTreeSet::new(),
            behavior
        ));
        let empty_call = node("CALL", vec![Child::Symbol("empty?".into())]);
        let bodyless_worklist = node("WHILE", vec![Child::Node(Box::new(empty_call))]);
        assert!(!linear_worklist(
            &bodyless_worklist,
            &assignments,
            None,
            &BTreeSet::new(),
            behavior
        ));

        assert!(!derived_from("missing", "target", (3, 0), &assignments));
        assert!(!derived_from("a", "target", (3, 0), &assignments));
        assert!(iterator_message(&node("ITER", vec![])).is_none());
        let for_node = node(
            "FOR",
            vec![Child::Nil, Child::Node(Box::new(root.clone())), Child::Nil],
        );
        assert_eq!(
            loop_control(&for_node).map(|row| row.r#type.as_str()),
            Some("ROOT")
        );

        let local = || node("LVAR", vec![Child::String("limit".into())]);
        let one_arg_range = node(
            "FCALL",
            vec![
                Child::Symbol("range".into()),
                Child::Node(Box::new(node("LIST", vec![Child::Node(Box::new(local()))]))),
            ],
        );
        let limit = BTreeSet::from(["limit".to_string()]);
        let python = crate::syntax::python::behavior();
        assert_eq!(iteration_domain_names(&one_arg_range, python), limit);
        assert_eq!(iteration_local_names(&one_arg_range, python), limit);

        let receiverless_each = node(
            "FCALL",
            vec![
                Child::Symbol("each".into()),
                Child::Node(Box::new(node(
                    "LIST",
                    vec![Child::Node(Box::new(node(
                        "LVAR",
                        vec![Child::String("items".into())],
                    )))],
                ))),
            ],
        );
        assert_eq!(
            iteration_domain_names(&receiverless_each, behavior),
            BTreeSet::from(["items".to_string()])
        );
        assert!(call_receiver(&root).is_none());
    }

    #[test]
    fn python_range_step_is_not_an_independent_iteration_domain() {
        let mut file = tempfile::Builder::new().suffix(".py").tempfile().unwrap();
        file.write_all(b"def scan(eligible, block_size):\n    for path, ids in eligible.items():\n        for start in range(0, len(ids), block_size):\n            consume(path, start)\n").unwrap();
        let document = syntax::parse_file(file.path().to_path_buf(), Language::Python).unwrap();
        assert_eq!(complexity(&facts(&document), "scan"), Some("O(N)".into()));
    }
}
