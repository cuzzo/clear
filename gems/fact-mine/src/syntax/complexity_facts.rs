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
    #[serde(default)]
    pub size_domains: Vec<SizeDomainFact>,
    #[serde(default)]
    pub block_invocations: Vec<BlockInvocationFact>,
    #[serde(default)]
    pub deferred_regions: Vec<DeferredRegionFact>,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct SizeDomainFact {
    pub id: String,
    pub name: String,
    pub source_kind: String,
    pub path: String,
    pub span: [usize; 4],
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct ComplexityFactorFact {
    pub domain_id: String,
    pub exponent: usize,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct SymbolicComplexityFact {
    pub factors: Vec<ComplexityFactorFact>,
    #[serde(default)]
    pub logarithmic: bool,
    #[serde(default = "default_true")]
    pub complete: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DeferredRegionFact {
    pub line: usize,
    pub span: [usize; 4],
    pub constructor: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BlockInvocationFact {
    pub parameter: String,
    pub line: usize,
    pub execution_multiplicity: String,
    pub power: usize,
    pub classification: String,
}

#[derive(Clone, Debug, Default)]
struct BlockSummary {
    power: usize,
    unknown: bool,
    invocations: usize,
}

fn is_false(value: &bool) -> bool {
    !*value
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
    /// Iterating a call result can be linear even when that result's size has
    /// no proven relationship to the caller's inputs.
    #[serde(default, skip_serializing_if = "is_false")]
    pub receiver_is_call: bool,
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
    #[serde(default)]
    pub argument_progress: String,
    #[serde(default)]
    pub argument_size_domains: Vec<Vec<String>>,
    #[serde(default)]
    pub receiver_size_domains: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbolic_execution: Option<SymbolicComplexityFact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_time_complexity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_space_complexity: Option<String>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symbolic_time: Option<SymbolicComplexityFact>,
    pub fixed: bool,
    pub amortized: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RecursionFacts {
    pub calls: usize,
    pub shrinking_calls: usize,
    pub halving_calls: usize,
    #[serde(default)]
    pub visited_guarded_calls: usize,
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
    symbolic_factors: BTreeMap<String, usize>,
    symbolic_complete: bool,
}

#[derive(Clone, Debug)]
struct DomainRegistry {
    domains: BTreeMap<String, SizeDomainFact>,
    path: String,
    owner: String,
    function: String,
    function_span: [usize; 4],
}

impl DomainRegistry {
    fn new(path: &str, owner: &str, function: &str, function_span: [usize; 4]) -> Self {
        Self {
            domains: BTreeMap::new(),
            path: path.to_string(),
            owner: owner.to_string(),
            function: function.to_string(),
            function_span,
        }
    }

    fn insert(&mut self, domain: SizeDomainFact) -> String {
        let id = domain.id.clone();
        self.domains.entry(id.clone()).or_insert(domain);
        id
    }

    fn values(&self) -> Vec<SizeDomainFact> {
        self.domains.values().cloned().collect()
    }

    fn parameter(&mut self, name: &str, span: Option<[usize; 4]>) -> String {
        self.insert(SizeDomainFact {
            id: format!("param:{}#{}:{}", self.owner, self.function, name),
            name: name.to_string(),
            source_kind: "parameter".to_string(),
            path: self.path.clone(),
            span: span.unwrap_or(self.function_span),
        })
    }

    fn state(&mut self, name: &str, span: Option<[usize; 4]>) -> String {
        let display = if name.starts_with('@') {
            name.to_string()
        } else {
            format!("@{name}")
        };
        self.insert(SizeDomainFact {
            id: format!("state:{}:{}", self.owner, display),
            name: display,
            source_kind: "state".to_string(),
            path: self.path.clone(),
            span: span.unwrap_or(self.function_span),
        })
    }

    fn local_loop(&mut self, names: &BTreeSet<String>, span: [usize; 4]) -> String {
        let name = if names.is_empty() {
            format!("loop at line {}", span[0])
        } else {
            names.iter().cloned().collect::<Vec<_>>().join(" + ")
        };
        self.insert(SizeDomainFact {
            id: format!("loop:{}:{}:{}", self.path, span[0], span[1]),
            name,
            source_kind: "loop_expression".to_string(),
            path: self.path.clone(),
            span,
        })
    }
}

#[derive(Clone, Debug)]
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
    symbolic_factors: BTreeMap<String, usize>,
    symbolic_complete: bool,
}

impl Default for LoopContext {
    fn default() -> Self {
        Self {
            power: 0,
            params: BTreeSet::new(),
            independent_collection_bindings: BTreeSet::new(),
            partition_locals: BTreeSet::new(),
            cursor: None,
            absorb_next: false,
            root_line: None,
            collapse_direct_child: false,
            unknown: false,
            symbolic_factors: BTreeMap::new(),
            symbolic_complete: true,
        }
    }
}

pub(crate) fn facts(document: &Document) -> Vec<MethodComplexityFacts> {
    let behavior = super::normalized_behavior::behavior(document.language);
    let block_summaries = preliminary_block_summaries(document, behavior);
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
            let callback_params = definition
                .map(|row| row.callback_params.iter().cloned().collect::<BTreeSet<_>>())
                .unwrap_or_default();
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
            let parameter_types = document
                .method_param_types
                .get(&type_key)
                .into_iter()
                .flat_map(|types| types.iter())
                .map(|(name, value)| {
                    (
                        name.clone(),
                        TypeExpr::parse(value, document.language.as_str()),
                    )
                })
                .collect::<BTreeMap<_, _>>();
            let collection_parameters = document
                .method_param_types
                .get(&type_key)
                .into_iter()
                .flat_map(|types| types.iter())
                .filter(|(_, value)| behavior.collection_parameter_type(value))
                .map(|(name, _)| name.clone())
                .collect::<BTreeSet<_>>();
            fact_for_method(
                document,
                &document.file,
                owner,
                &method.name,
                method.line,
                method.span,
                &method.node,
                &params,
                &collection_parameters,
                &parameter_types,
                &callback_params,
                &block_summaries,
                &state_types,
                &scoped_type_aliases,
                document.language.as_str(),
                behavior,
            )
        })
        .collect()
}

fn preliminary_block_summaries(
    document: &Document,
    behavior: &dyn NormalizedLanguageBehavior,
) -> BTreeMap<(String, String), BlockSummary> {
    document
        .local_methods
        .iter()
        .filter_map(|method| {
            let definition = document
                .function_defs
                .iter()
                .find(|row| row.name == method.name && row.line == method.line)?;
            let callback_params = definition
                .callback_params
                .iter()
                .cloned()
                .collect::<BTreeSet<_>>();
            if callback_params.is_empty() {
                return None;
            }
            let mut summary = BlockSummary::default();
            collect_block_invocations(
                &method.node,
                &callback_params,
                0,
                false,
                &mut summary,
                behavior,
            );
            Some(((definition.owner.clone(), method.name.clone()), summary))
        })
        .collect()
}

fn collect_block_invocations(
    node: &Node,
    callback_params: &BTreeSet<String>,
    power: usize,
    unknown: bool,
    summary: &mut BlockSummary,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if deferred_block(node, behavior) {
        return;
    }
    if let Some(message) = direct_call_message(node) {
        if behavior.callback_invocation_message(message) {
            let receiver_names = call_receiver(node).map(local_names).unwrap_or_default();
            if !receiver_names.is_disjoint(callback_params) {
                summary.invocations += 1;
                summary.power = summary.power.max(power);
                summary.unknown |= unknown;
            }
        }
    }

    if loop_node(node, behavior) {
        let semantics = if node.r#type == "ITER" {
            iterator_message(node)
                .map(|message| behavior.block_call_semantics(message))
                .unwrap_or(BlockCallSemantics::Unknown)
        } else {
            BlockCallSemantics::Iteration
        };
        if let Some(control) = loop_control(node) {
            collect_block_invocations(control, callback_params, power, unknown, summary, behavior);
        }
        if let Some(body) = loop_body(node) {
            collect_block_invocations(
                body,
                callback_params,
                power + usize::from(semantics == BlockCallSemantics::Iteration),
                unknown || semantics == BlockCallSemantics::Unknown,
                summary,
                behavior,
            );
        }
        return;
    }

    for child in child_nodes(node) {
        collect_block_invocations(child, callback_params, power, unknown, summary, behavior);
    }
}

fn fact_for_method(
    document: &Document,
    path: &str,
    owner: &str,
    function: &str,
    line: usize,
    span: [usize; 4],
    node: &Node,
    params: &BTreeSet<String>,
    collection_parameters: &BTreeSet<String>,
    parameter_types: &BTreeMap<String, TypeExpr>,
    callback_params: &BTreeSet<String>,
    block_summaries: &BTreeMap<(String, String), BlockSummary>,
    state_types: &BTreeMap<String, TypeExpr>,
    type_aliases: &BTreeMap<String, String>,
    language: &str,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<MethodComplexityFacts> {
    let mut domain_registry = DomainRegistry::new(path, owner, function, span);
    for parameter in params {
        let declaration_span = document
            .places
            .iter()
            .find(|place| {
                place.owner == owner && place.function == function && place.name == *parameter
            })
            .map(|place| place.declaration_span);
        domain_registry.parameter(parameter, declaration_span);
    }
    for state in document
        .state_declarations
        .iter()
        .filter(|state| state.owner == owner)
    {
        domain_registry.state(&state.field, Some(state.span));
    }
    let mut assignments = BTreeMap::<String, Vec<Assignment>>::new();
    collect_assignments(node, &mut assignments, behavior);
    let mut max_power = 0;
    let mut evidence = Vec::new();
    let mut call_contexts = Vec::new();
    let mut block_invocations = Vec::new();
    let mut deferred_regions = Vec::new();
    collect_deferred_regions(node, &mut deferred_regions, behavior);
    let mut collection_growth = BTreeMap::new();
    visit_loops(
        node,
        params,
        &assignments,
        &LoopContext::default(),
        &mut max_power,
        &mut evidence,
        &mut call_contexts,
        &mut block_invocations,
        &mut collection_growth,
        parameter_types,
        owner,
        callback_params,
        block_summaries,
        state_types,
        type_aliases,
        language,
        behavior,
        &mut domain_registry,
    );
    let mut recursion = RecursionFacts::default();
    let visited_guards = visited_guard_parameters(node, params, behavior);
    collect_recursion(
        node,
        function,
        false,
        &assignments,
        &visited_guards,
        &mut recursion,
        behavior,
    );
    recursion.unknown_progress_calls = recursion.calls.saturating_sub(
        recursion.shrinking_calls + recursion.halving_calls + recursion.visited_guarded_calls,
    );
    let mut allocations = Vec::new();
    collect_allocations(node, params, &assignments, &mut allocations, behavior);
    for allocation in &mut allocations {
        if allocation.cardinality_relation != "unknown" || allocation.receiver_is_call {
            continue;
        }
        let matching_iteration = evidence.iter().find(|iteration| {
            iteration.line == allocation.line
                && iteration.message.as_deref() == Some(allocation.kind.as_str())
                && iteration.cardinality_relation != "unknown"
        });
        if let Some(iteration) = matching_iteration {
            allocation.cardinality_relation = "same".to_string();
            allocation.bound_classification = iteration.bound_classification.clone();
            if allocation.parameter_domains.is_empty() {
                allocation.parameter_domains = iteration.parameter_domains.clone();
            }
            if allocation.domain_expression.is_empty() {
                allocation.domain_expression = iteration.domain_expression.clone();
            }
        }
    }
    allocations.sort_by_key(|fact| (fact.line, fact.span[1], fact.kind.clone()));
    allocations.dedup_by(|left, right| left.span == right.span && left.kind == right.kind);

    if evidence.is_empty()
        && recursion.calls == 0
        && allocations.is_empty()
        && call_contexts.is_empty()
        && block_invocations.is_empty()
        && deferred_regions.is_empty()
    {
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
        size_domains: domain_registry.values(),
        block_invocations,
        deferred_regions,
    })
}

fn collect_deferred_regions(
    node: &Node,
    output: &mut Vec<DeferredRegionFact>,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if deferred_block(node, behavior) {
        output.push(DeferredRegionFact {
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            constructor: iterator_message(node).unwrap_or_default().to_string(),
        });
        return;
    }
    for child in child_nodes(node) {
        collect_deferred_regions(child, output, behavior);
    }
}

fn collect_allocations(
    node: &Node,
    params: &BTreeSet<String>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    output: &mut Vec<AllocationFact>,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if deferred_block(node, behavior) {
        return;
    }
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
                matches!(value.r#type.as_str(), "ARRAY" | "HASH" | "LIST")
                    && local_names(value).is_empty()
            });
            let (relation, bound) =
                if semantics == CollectionAllocationSemantics::UnknownSize || receiver_is_call {
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
                receiver_is_call,
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
    block_invocations: &mut Vec<BlockInvocationFact>,
    collection_growth: &mut BTreeMap<String, CollectionGrowth>,
    parameter_types: &BTreeMap<String, TypeExpr>,
    owner: &str,
    callback_params: &BTreeSet<String>,
    block_summaries: &BTreeMap<(String, String), BlockSummary>,
    state_types: &BTreeMap<String, TypeExpr>,
    type_aliases: &BTreeMap<String, String>,
    language: &str,
    behavior: &dyn NormalizedLanguageBehavior,
    domain_registry: &mut DomainRegistry,
) {
    let block_semantics = if node.r#type == "ITER" {
        iterator_message(node)
            .map(|message| {
                let configured = behavior.block_call_semantics(message);
                if configured != BlockCallSemantics::Unknown {
                    configured
                } else {
                    block_summaries
                        .get(&(owner.to_string(), message.to_string()))
                        .map(|summary| {
                            if summary.unknown || summary.invocations == 0 {
                                BlockCallSemantics::Unknown
                            } else if summary.power == 0 {
                                BlockCallSemantics::Once
                            } else {
                                BlockCallSemantics::Iteration
                            }
                        })
                        .unwrap_or(BlockCallSemantics::Unknown)
                }
            })
            .unwrap_or(BlockCallSemantics::Unknown)
    } else {
        BlockCallSemantics::Iteration
    };
    if block_semantics == BlockCallSemantics::Deferred {
        if let Some(control) = loop_control(node) {
            visit_loops(
                control,
                params,
                assignments,
                parent,
                max_power,
                evidence,
                call_contexts,
                block_invocations,
                collection_growth,
                parameter_types,
                owner,
                callback_params,
                block_summaries,
                state_types,
                type_aliases,
                language,
                behavior,
                domain_registry,
            );
        }
        return;
    }
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
                block_invocations,
                collection_growth,
                parameter_types,
                owner,
                callback_params,
                block_summaries,
                state_types,
                type_aliases,
                language,
                behavior,
                domain_registry,
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
        let growth = locals
            .iter()
            .filter_map(|name| collection_growth.get(name))
            .max_by_key(|growth| growth.power)
            .cloned();
        let growth_power = growth.as_ref().map(|growth| growth.power);
        let unknown_iteration =
            node.r#type == "ITER" && block_semantics == BlockCallSemantics::Unknown;
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
        let mut symbolic_refs = refs.clone();
        if let Some(cursor) = &cursor {
            let cursor_names = BTreeSet::from([cursor.clone()]);
            let cursor_domains = parameter_domains(
                &cursor_names,
                params,
                assignments,
                (node.first_lineno, node.first_column),
            );
            symbolic_refs = symbolic_refs.difference(&cursor_domains).cloned().collect();
        }
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
            let inferred_block_power = if node.r#type == "ITER" {
                iterator_message(node)
                    .and_then(|message| {
                        block_summaries.get(&(owner.to_string(), message.to_string()))
                    })
                    .filter(|summary| !summary.unknown)
                    .map(|summary| summary.power.max(1))
                    .unwrap_or(1)
            } else {
                1
            };
            power = if let Some(growth_power) = growth_power {
                parent.power + growth_power
            } else if !locals.is_disjoint(&parent.independent_collection_bindings) {
                parent.power + inferred_block_power
            } else if refs.is_empty() {
                power.max(1)
            } else if amortized {
                power.max(1)
            } else {
                power + inferred_block_power
            };
        }
        let fixpoint = fixpoint_loop(node, control, behavior);
        if fixpoint {
            power = power.max(parent.power + 2);
        }
        let mut symbolic_factors = parent.symbolic_factors.clone();
        let mut symbolic_complete = parent.symbolic_complete && !unknown_iteration;
        let added_power = power.saturating_sub(parent.power);
        if let Some(growth) = growth.filter(|_| added_power > 0 && !fixed) {
            symbolic_factors = growth.symbolic_factors;
            symbolic_complete &= growth.symbolic_complete;
        } else if added_power > 0 && !fixed {
            let mut domains = symbolic_refs
                .iter()
                .map(|name| domain_registry.parameter(name, None))
                .collect::<BTreeSet<_>>();
            domains.extend(states.iter().map(|name| domain_registry.state(name, None)));
            let domain_id = if domains.len() == 1 {
                domains.into_iter().next().unwrap()
            } else {
                if domains.len() > 1 {
                    symbolic_complete = false;
                }
                domain_registry.local_loop(
                    &domain_names,
                    [
                        node.first_lineno,
                        node.first_column,
                        node.last_lineno,
                        node.last_column,
                    ],
                )
            };
            *symbolic_factors.entry(domain_id).or_insert(0) += added_power;
        }
        *max_power = (*max_power).max(power);
        let relation = if unknown_iteration {
            "unknown"
        } else if fixed {
            "fixed"
        } else if !locals.is_disjoint(&parent.independent_collection_bindings) {
            "independent_of"
        } else if amortized
            || parent.collapse_direct_child
            || parent.absorb_next
            || (refs.is_empty() && states.is_empty())
        {
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
            bound_classification: if unknown_iteration {
                "unknown"
            } else if fixed {
                "fixed"
            } else {
                "input"
            }
            .to_string(),
            execution_multiplicity: if unknown_iteration {
                "unknown".to_string()
            } else {
                polynomial(power)
            },
            power,
            symbolic_time: Some(symbolic_complexity(&symbolic_factors, symbolic_complete)),
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
                }) {
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
            symbolic_factors,
            symbolic_complete,
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
                block_invocations,
                collection_growth,
                parameter_types,
                owner,
                callback_params,
                block_summaries,
                state_types,
                type_aliases,
                language,
                behavior,
                domain_registry,
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
                block_invocations,
                collection_growth,
                parameter_types,
                owner,
                callback_params,
                block_summaries,
                state_types,
                type_aliases,
                language,
                behavior,
                domain_registry,
            );
        }
    } else {
        record_collection_growth(node, parent, collection_growth, behavior);
        if let Some(message) = direct_call_message(node) {
            if behavior.callback_invocation_message(message) {
                let receiver_names = call_receiver(node).map(local_names).unwrap_or_default();
                for parameter in receiver_names.intersection(callback_params) {
                    block_invocations.push(BlockInvocationFact {
                        parameter: parameter.clone(),
                        line: node.first_lineno,
                        execution_multiplicity: if parent.unknown {
                            "unknown".to_string()
                        } else {
                            polynomial(parent.power)
                        },
                        power: parent.power,
                        classification: if parent.unknown {
                            "unknown"
                        } else if parent.power == 0 {
                            "constant"
                        } else {
                            "per_iteration"
                        }
                        .to_string(),
                    });
                }
            }
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
            let argument_size_domains = call_argument_nodes(node)
                .into_iter()
                .map(|argument| {
                    let names = local_names(argument);
                    let parameter_sources = parameter_domains(
                        &names,
                        params,
                        assignments,
                        (node.first_lineno, node.first_column),
                    );
                    let mut domains = parameter_sources
                        .iter()
                        .map(|name| domain_registry.parameter(name, None))
                        .collect::<BTreeSet<_>>();
                    domains.extend(
                        state_names(argument)
                            .iter()
                            .map(|name| domain_registry.state(name, None)),
                    );
                    domains.into_iter().collect::<Vec<_>>()
                })
                .collect::<Vec<_>>();
            let receiver_size_domains = call_receiver(node)
                .map(|receiver| {
                    let names = local_names(receiver);
                    let parameter_sources = parameter_domains(
                        &names,
                        params,
                        assignments,
                        (node.first_lineno, node.first_column),
                    );
                    let mut domains = parameter_sources
                        .iter()
                        .map(|name| domain_registry.parameter(name, None))
                        .collect::<BTreeSet<_>>();
                    domains.extend(
                        state_names(receiver)
                            .iter()
                            .map(|name| domain_registry.state(name, None)),
                    );
                    domains.into_iter().collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let argument_cardinality_relation = if parent.power == 0 {
                "same"
            } else if !argument_names.is_disjoint(&parent.partition_locals) {
                "partition_of"
            } else if !argument_domains.is_empty() {
                "independent_of"
            } else {
                "unknown"
            };
            let known_call_complexity = call_receiver_type(
                node,
                parameter_types,
                assignments,
                state_types,
                (node.first_lineno, node.first_column),
                behavior,
            )
            .and_then(|receiver_type| behavior.call_complexity(&receiver_type, message))
            .or_else(|| {
                behavior.intrinsic_call_complexity(
                    call_receiver(node).map(|receiver| receiver.text.trim()),
                    message,
                )
            });
            call_contexts.push(CallContainmentFact {
                line: node.first_lineno,
                span: [
                    node.first_lineno,
                    node.first_column,
                    node.last_lineno,
                    node.last_column,
                ],
                message: message.to_string(),
                execution_multiplicity: if parent.unknown {
                    "unknown".to_string()
                } else {
                    polynomial(parent.power)
                },
                power: parent.power,
                parameter_arguments: local_names(node).intersection(params).cloned().collect(),
                argument_cardinality_relation: argument_cardinality_relation.to_string(),
                argument_progress: call_argument_progress(
                    node,
                    assignments,
                    (node.first_lineno, node.first_column),
                ),
                argument_size_domains,
                receiver_size_domains,
                symbolic_execution: Some(symbolic_complexity(
                    &parent.symbolic_factors,
                    parent.symbolic_complete && !parent.unknown,
                )),
                known_time_complexity: known_call_complexity
                    .map(|complexity| complexity.time.to_string()),
                known_space_complexity: known_call_complexity
                    .map(|complexity| complexity.space.to_string()),
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
                block_invocations,
                collection_growth,
                parameter_types,
                owner,
                callback_params,
                block_summaries,
                state_types,
                type_aliases,
                language,
                behavior,
                domain_registry,
            );
        }
    }
}

fn call_receiver_type(
    node: &Node,
    parameter_types: &BTreeMap<String, TypeExpr>,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    state_types: &BTreeMap<String, TypeExpr>,
    before: (usize, usize),
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<TypeExpr> {
    let receiver = call_receiver(node)?;
    if let Some(literal_type) = behavior.literal_receiver_type(receiver) {
        return Some(literal_type);
    }

    for state in state_names(receiver) {
        if let Some(state_type) = state_types.get(state.trim_start_matches('@')) {
            return Some(state_type.clone());
        }
    }
    let receiver_names = local_names(receiver);
    for name in &receiver_names {
        if let Some(parameter_type) = parameter_types.get(name) {
            return Some(parameter_type.clone());
        }
    }
    let typed_parameters = parameter_types.keys().cloned().collect::<BTreeSet<_>>();
    let domains = parameter_domains(&receiver_names, &typed_parameters, assignments, before);
    domains
        .into_iter()
        .find_map(|name| parameter_types.get(&name).cloned())
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
        if context.power >= entry.power {
            entry.power = context.power;
            entry.symbolic_factors = context.symbolic_factors.clone();
            entry.symbolic_complete = context.symbolic_complete;
        }
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
    if deferred_block(node, behavior) {
        return;
    }
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
                    empty_collection: rhs
                        .is_some_and(|value| empty_collection_expression(value, behavior)),
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
        && symbols
            .iter()
            .any(|symbol| behavior.visited_membership_call(symbol))
        && symbols
            .iter()
            .any(|symbol| behavior.visited_insert_call(symbol));
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

fn cardinality_names(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> BTreeSet<String> {
    if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
        return local_names(node);
    }

    let message = direct_call_message(node);
    let normalized_operator = message.is_some_and(|message| {
        matches!(
            message,
            "+" | "-" | "/" | ">>" | "!" | "&&" | "||" | "and" | "or" | "<" | "<=" | ">" | ">="
        )
    });
    if normalized_operator {
        return local_names(node);
    }
    if let Some(message) = message {
        if behavior.cardinality_call_semantics(message) != CardinalityCallSemantics::Unknown {
            return call_receiver(node)
                .map(local_names)
                .unwrap_or_else(|| local_names(node));
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
        return arguments
            .get(index)
            .map(|argument| local_names(argument))
            .unwrap_or_default();
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

fn call_argument_progress(
    node: &Node,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    before: (usize, usize),
) -> String {
    let arguments = call_argument_nodes(node);
    let symbols = arguments
        .iter()
        .flat_map(|argument| descendant_symbols(argument))
        .collect::<Vec<_>>();
    let assigned_shape = arguments
        .iter()
        .flat_map(|argument| local_names(argument))
        .filter_map(|name| {
            assignments.get(&name).and_then(|rows| {
                rows.iter()
                    .rev()
                    .find(|row| (row.line, row.column) < before)
            })
        })
        .fold((false, false), |shape, row| {
            (shape.0 || row.shrinking, shape.1 || row.halving)
        });
    if symbols
        .iter()
        .any(|symbol| matches!(symbol.as_str(), "/" | ">>"))
        || assigned_shape.1
    {
        "halving".to_string()
    } else if symbols.iter().any(|symbol| symbol == "-") || assigned_shape.0 {
        "shrinking".to_string()
    } else {
        "unknown".to_string()
    }
}

fn collect_recursion(
    node: &Node,
    function: &str,
    inside_loop: bool,
    assignments: &BTreeMap<String, Vec<Assignment>>,
    visited_guards: &BTreeSet<String>,
    out: &mut RecursionFacts,
    behavior: &dyn NormalizedLanguageBehavior,
) {
    if deferred_block(node, behavior) {
        return;
    }
    let now_inside = inside_loop || loop_node(node, behavior);
    if recursive_self_call(node, function) {
        out.calls += 1;
        let guarded = !local_names(node).is_disjoint(visited_guards);
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
        if guarded {
            out.visited_guarded_calls += 1;
        } else if symbols
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
        collect_recursion(
            child,
            function,
            now_inside,
            assignments,
            visited_guards,
            out,
            behavior,
        );
    }
}

fn visited_guard_parameters(
    node: &Node,
    params: &BTreeSet<String>,
    behavior: &dyn NormalizedLanguageBehavior,
) -> BTreeSet<String> {
    fn collect(
        node: &Node,
        params: &BTreeSet<String>,
        membership: &mut BTreeSet<String>,
        insertion: &mut BTreeSet<String>,
        behavior: &dyn NormalizedLanguageBehavior,
    ) {
        if deferred_block(node, behavior) {
            return;
        }
        if let Some(message) = direct_call_message(node) {
            let receiver_params = call_receiver(node)
                .map(local_names)
                .unwrap_or_default()
                .intersection(params)
                .cloned()
                .collect::<BTreeSet<_>>();
            if behavior.visited_membership_call(message) {
                membership.extend(receiver_params.iter().cloned());
            }
            if behavior.visited_insert_call(message) {
                insertion.extend(receiver_params);
            }
        }
        for child in child_nodes(node) {
            collect(child, params, membership, insertion, behavior);
        }
    }

    let mut membership = BTreeSet::new();
    let mut insertion = BTreeSet::new();
    collect(node, params, &mut membership, &mut insertion, behavior);
    membership.intersection(&insertion).cloned().collect()
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
                matches!(
                    behavior.block_call_semantics(message),
                    BlockCallSemantics::Iteration | BlockCallSemantics::Unknown
                )
            }))
}

fn deferred_block(node: &Node, behavior: &dyn NormalizedLanguageBehavior) -> bool {
    node.r#type == "ITER"
        && iterator_message(node).is_some_and(|message| {
            behavior.block_call_semantics(message) == BlockCallSemantics::Deferred
        })
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
        return node
            .children
            .first()
            .and_then(ast::node)
            .map(local_names)
            .unwrap_or_default();
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
    if deferred_block(node, behavior) {
        return false;
    }
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

fn symbolic_complexity(
    factors: &BTreeMap<String, usize>,
    complete: bool,
) -> SymbolicComplexityFact {
    SymbolicComplexityFact {
        factors: factors
            .iter()
            .filter(|(_, exponent)| **exponent > 0)
            .map(|(domain_id, exponent)| ComplexityFactorFact {
                domain_id: domain_id.clone(),
                exponent: *exponent,
            })
            .collect(),
        logarithmic: false,
        complete,
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
        if row
            .iterations
            .iter()
            .any(|fact| fact.cardinality_relation == "unknown")
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

    fn symbolic_factors(rows: &[MethodComplexityFacts], name: &str) -> Vec<(String, usize)> {
        let row = rows.iter().find(|row| row.function == name).unwrap();
        let domains = row
            .size_domains
            .iter()
            .map(|domain| (domain.id.as_str(), domain.name.as_str()))
            .collect::<BTreeMap<_, _>>();
        let term = row
            .iterations
            .iter()
            .max_by_key(|iteration| iteration.power)
            .and_then(|iteration| iteration.symbolic_time.as_ref())
            .unwrap();
        term.factors
            .iter()
            .map(|factor| {
                (
                    domains[factor.domain_id.as_str()].to_string(),
                    factor.exponent,
                )
            })
            .collect()
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
        assert_eq!(
            symbolic_factors(&rows, "cartesian"),
            vec![("xs".into(), 1), ("ys".into(), 1)]
        );
        assert_eq!(
            symbolic_factors(&rows, "independent"),
            vec![("items".into(), 2)]
        );
        assert_eq!(
            symbolic_factors(&rows, "hierarchy"),
            vec![("documents".into(), 1)]
        );
        assert_eq!(complexity(&rows, "callback"), Some("unknown".into()));
        assert_eq!(
            complexity(&rows, "unknown_result_sizes"),
            Some("O(N)".into())
        );
        assert_eq!(complexity(&rows, "indexed_children"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "callback_result"), Some("O(N)".into()));
        let materialize = rows
            .iter()
            .find(|row| row.function == "materialize")
            .unwrap();
        assert_eq!(materialize.allocations[0].cardinality_relation, "same");
        assert_eq!(materialize.allocations[0].parameter_domains, vec!["items"]);
        let fixed = rows
            .iter()
            .find(|row| row.function == "fixed_materialize")
            .unwrap();
        assert!(fixed
            .allocations
            .iter()
            .any(|fact| fact.cardinality_relation == "fixed"));
        let unknown = rows
            .iter()
            .find(|row| row.function == "unknown_materialize")
            .unwrap();
        assert_eq!(unknown.allocations[0].cardinality_relation, "unknown");
        let callback_result = rows
            .iter()
            .find(|row| row.function == "callback_result")
            .unwrap();
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
def guarded_tree(node, seen)
  return if seen.include?(node)
  seen.add(node)
  guarded_tree(node.left, seen)
  guarded_tree(node.right, seen)
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
        let guarded = rows
            .iter()
            .find(|row| row.function == "guarded_tree")
            .unwrap();
        assert_eq!(guarded.recursion.visited_guarded_calls, 2);
        assert_eq!(guarded.recursion.unknown_progress_calls, 0);
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
    fn normalized_call_edges_carry_size_change_progress() {
        let rows = ruby_facts(
            r#"
class Parser
  def even_step(n)
    return if n <= 0
    odd_step(n - 1)
  end

  def odd_step(n)
    return if n <= 0
    even_step(n / 2)
  end

  def opaque_step(node)
    even_step(node.child)
  end
end
"#,
        );
        let even = rows.iter().find(|row| row.function == "even_step").unwrap();
        assert_eq!(
            even.call_contexts
                .iter()
                .find(|call| call.message == "odd_step")
                .unwrap()
                .argument_progress,
            "shrinking"
        );
        let odd = rows.iter().find(|row| row.function == "odd_step").unwrap();
        assert_eq!(
            odd.call_contexts
                .iter()
                .find(|call| call.message == "even_step")
                .unwrap()
                .argument_progress,
            "halving"
        );
        let opaque = rows
            .iter()
            .find(|row| row.function == "opaque_step")
            .unwrap();
        assert_eq!(opaque.call_contexts[0].argument_progress, "unknown");
    }

    #[test]
    fn typed_receiver_calls_carry_language_normalized_costs() {
        let rows = ruby_facts(
            r#"
class Index
  sig { params(items: T::Array[String], table: T::Hash[String, Integer]).void }
  def check(items, table)
    copy = items
    items.include?("x")
    copy.include?("y")
    table.key?("x")
    items.sort
  end

  def literals
    [].sort
    {}.keys
    "value".split
  end
end
"#,
        );
        let row = rows.iter().find(|row| row.function == "check").unwrap();
        let include = row
            .call_contexts
            .iter()
            .find(|call| call.message == "include?")
            .unwrap();
        assert_eq!(include.known_time_complexity.as_deref(), Some("O(N)"));
        assert_eq!(include.known_space_complexity.as_deref(), Some("O(1)"));
        let key = row
            .call_contexts
            .iter()
            .find(|call| call.message == "key?")
            .unwrap();
        assert_eq!(key.known_time_complexity.as_deref(), Some("O(1)"));
        let sort = row
            .call_contexts
            .iter()
            .find(|call| call.message == "sort")
            .unwrap();
        assert_eq!(sort.known_time_complexity.as_deref(), Some("O(N log N)"));
        assert_eq!(sort.known_space_complexity.as_deref(), Some("O(N)"));
        assert_eq!(
            row.call_contexts
                .iter()
                .filter(|call| call.message == "include?")
                .filter(|call| call.known_time_complexity.as_deref() == Some("O(N)"))
                .count(),
            2
        );
        let literals = rows.iter().find(|row| row.function == "literals").unwrap();
        assert!(literals.call_contexts.iter().all(|call| {
            !matches!(call.message.as_str(), "sort" | "keys" | "split")
                || call.known_time_complexity.is_some()
        }));
    }

    #[test]
    fn language_intrinsics_carry_normalized_constant_costs() {
        let rows = ruby_facts(
            r#"
class Worker
  sig { params(value: AST::Node).void }
  def check(value)
    T.let(value, AST::Node)
    T.cast(value, AST::Node)
    value.frozen?
    value.user_defined_predicate?
  end
end
"#,
        );
        let row = rows.iter().find(|row| row.function == "check").unwrap();

        for message in ["let", "cast"] {
            let call = row
                .call_contexts
                .iter()
                .find(|call| call.message == message)
                .unwrap();
            assert_eq!(call.known_time_complexity.as_deref(), Some("O(1)"));
            assert_eq!(call.known_space_complexity.as_deref(), Some("O(1)"));
        }
        for message in ["frozen?", "user_defined_predicate?"] {
            assert!(row
                .call_contexts
                .iter()
                .find(|call| call.message == message)
                .unwrap()
                .known_time_complexity
                .is_none());
        }
    }

    #[test]
    fn allocation_reuses_the_matching_iteration_cardinality() {
        let rows = ruby_facts(
            r#"
class Renderer
  def render
    frame = Snapshot.new
    txn_violations = frame.violations
    txn_violations.map { |violation| violation.to_s }
  end
end
"#,
        );
        let row = rows.iter().find(|row| row.function == "render").unwrap();
        let iteration = row
            .iterations
            .iter()
            .find(|iteration| iteration.message.as_deref() == Some("map"))
            .unwrap();
        assert_ne!(iteration.cardinality_relation, "unknown");
        assert_eq!(iteration.bound_classification, "input");

        let allocation = row
            .allocations
            .iter()
            .find(|allocation| allocation.kind == "map")
            .unwrap();
        assert_ne!(allocation.cardinality_relation, "unknown");
        assert_eq!(allocation.bound_classification, "input");
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
    fn user_block_summaries_distinguish_constant_wrappers_and_traversals() {
        let rows = ruby_facts(
            r#"
class Driver
  def with_scope(&blk)
    blk.call
  end

  def each_item(items, &blk)
    items.each { |item| blk.call(item) }
  end

  def wrapped(items)
    with_scope { items.each { |item| consume(item) } }
  end

  def traversed(items)
    each_item(items) { |item| consume(item) }
  end
end
"#,
        );

        assert_eq!(complexity(&rows, "wrapped"), Some("O(N)".into()));
        assert_eq!(complexity(&rows, "traversed"), Some("O(N)".into()));
        let wrapper = rows
            .iter()
            .find(|row| row.function == "with_scope")
            .unwrap();
        assert_eq!(wrapper.block_invocations[0].classification, "constant");
        let traversal = rows.iter().find(|row| row.function == "each_item").unwrap();
        assert_eq!(
            traversal.block_invocations[0].classification,
            "per_iteration"
        );
        assert_eq!(
            traversal.block_invocations[0].execution_multiplicity,
            "O(N)"
        );
    }

    #[test]
    fn deferred_closure_work_is_not_charged_to_creation() {
        let rows = ruby_facts(
            r#"
def build_callback(items)
  callback = lambda { items.each { |item| consume(item) } }
  callback
end

def invoke_callback(items)
  callback = proc { items.each { |item| consume(item) } }
  callback.call
end
"#,
        );
        for name in ["build_callback", "invoke_callback"] {
            let row = rows.iter().find(|row| row.function == name).unwrap();
            assert!(row.iterations.is_empty());
            assert_eq!(row.deferred_regions.len(), 1);
            assert!(matches!(
                row.deferred_regions[0].constructor.as_str(),
                "lambda" | "proc"
            ));
        }
        let invoked = rows
            .iter()
            .find(|row| row.function == "invoke_callback")
            .unwrap();
        assert!(invoked
            .call_contexts
            .iter()
            .any(|context| context.message == "call"));
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
        assert!(!fixpoint_loop(
            &while_without_control,
            Some(&root),
            behavior
        ));
        let nameless_local = node("LVAR", vec![]);
        assert!(!fixpoint_loop(
            &while_without_control,
            Some(&nameless_local),
            behavior
        ));
        let flag_local = node("LVAR", vec![Child::String("flag".into())]);
        assert!(!fixpoint_loop(
            &while_without_control,
            Some(&flag_local),
            behavior
        ));

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
