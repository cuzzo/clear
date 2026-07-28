//! Language-neutral runtime value evidence.
//!
//! Tracers own observation. FactMine owns every relation between an observed
//! value and normalized source/CFG/DFG facts. In particular, this schema must
//! never grow assignments, AST nodes, block-binding rules, or source-language
//! expressions: those would duplicate FactMine's analysis in each tracer.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use crate::profile::{CallRecord, MethodRecord, ProfileOutput};
use crate::type_inference::TypeExpr;

pub const SCHEMA: &str = "fact-mine.runtime-value-evidence.v1";

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RuntimeValueEvidence {
    pub schema: String,
    #[serde(default)]
    pub authority: String,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    #[serde(default)]
    pub runs: Vec<String>,
    #[serde(default)]
    pub observations: Vec<ValueObservation>,
    #[serde(default)]
    pub calls: Vec<ObservedCall>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct MethodLocator {
    pub language: String,
    pub path: String,
    #[serde(default)]
    pub owner: String,
    pub name: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub line: usize,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ValueScope {
    pub language: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub function: String,
    #[serde(default)]
    pub line: usize,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct SourceAnchor {
    pub path: String,
    pub line: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<[usize; 4]>,
    #[serde(default)]
    pub selector: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ValueDomain {
    #[serde(default)]
    pub types: BTreeSet<String>,
    #[serde(default)]
    pub elements: BTreeSet<String>,
    #[serde(default)]
    pub keys: BTreeSet<String>,
    #[serde(default)]
    pub values: BTreeSet<String>,
    #[serde(default)]
    pub shapes: Vec<ValueShape>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ValueShape {
    pub kind: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub elements: Vec<ValueShape>,
    #[serde(default)]
    pub keys: Vec<ValueShape>,
    #[serde(default)]
    pub values: Vec<ValueShape>,
    #[serde(default)]
    pub members: BTreeMap<String, ValueShape>,
}

impl ValueDomain {
    pub fn is_empty(&self) -> bool {
        self.types.is_empty()
            && self.elements.is_empty()
            && self.keys.is_empty()
            && self.values.is_empty()
            && self.shapes.is_empty()
    }

    fn validate(&self, context: &str) -> Result<()> {
        for value in self
            .types
            .iter()
            .chain(&self.elements)
            .chain(&self.keys)
            .chain(&self.values)
        {
            if value.trim().is_empty() {
                bail!("{context} contains an empty runtime type identity");
            }
        }
        for shape in &self.shapes {
            shape.validate(context)?;
        }
        Ok(())
    }
}

impl ValueShape {
    fn validate(&self, context: &str) -> Result<()> {
        if !matches!(
            self.kind.as_str(),
            "class" | "array" | "hash" | "set" | "tuple" | "record" | "unknown"
        ) {
            bail!("{context} contains unsupported value shape {:?}", self.kind);
        }
        if self.kind == "class" && self.name.is_empty() {
            bail!("{context} contains a class shape without a name");
        }
        for child in self
            .elements
            .iter()
            .chain(&self.keys)
            .chain(&self.values)
            .chain(self.members.values())
        {
            child.validate(context)?;
        }
        Ok(())
    }
}

/// A value observation attached to a semantic storage boundary.
///
/// Supported kinds are deliberately storage-oriented rather than
/// language-oriented:
/// - `parameter`: method `scope` + `slot`
/// - `return`: method `scope`
/// - `state`: `scope.language` + `scope.owner` + `slot`
/// - `collection`: `scope` + `slot`, where `slot_kind` identifies parameter,
///   return, state, or another tracer-addressable boundary.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ValueObservation {
    pub kind: String,
    pub scope: ValueScope,
    #[serde(default)]
    pub slot: String,
    #[serde(default)]
    pub slot_kind: String,
    pub domain: ValueDomain,
    #[serde(default)]
    pub count: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct SemanticTarget {
    /// Canonical SCIP symbol. Keeping the symbol in evidence means FactMine
    /// never needs to understand a tracer or package manager's identity
    /// grammar.
    pub symbol: String,
    #[serde(default)]
    pub owner: String,
    pub name: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub receiver_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub definition: Option<MethodLocator>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ObservedCall {
    pub language: String,
    pub caller: MethodLocator,
    pub callsite: SourceAnchor,
    pub targets: Vec<SemanticTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receiver_domain: Option<ValueDomain>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_domain: Option<ValueDomain>,
    #[serde(default)]
    pub count: u64,
}

impl RuntimeValueEvidence {
    pub fn from_path(path: &Path) -> Result<Self> {
        let json = fs::read_to_string(path)
            .with_context(|| format!("failed to read runtime evidence {}", path.display()))?;
        Self::from_json(&json)
            .with_context(|| format!("invalid runtime evidence {}", path.display()))
    }

    pub fn from_json(json: &str) -> Result<Self> {
        let evidence: Self = serde_json::from_str(json)?;
        evidence.validate()?;
        Ok(evidence)
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema != SCHEMA {
            bail!(
                "unsupported runtime evidence schema {:?}; expected {SCHEMA}",
                self.schema
            );
        }
        if self.authority.is_empty() {
            bail!("runtime evidence authority must not be empty");
        }
        for (index, observation) in self.observations.iter().enumerate() {
            if observation.scope.language.is_empty() {
                bail!("observations[{index}].scope requires language");
            }
            if !matches!(
                observation.kind.as_str(),
                "parameter" | "return" | "state" | "collection"
            ) {
                bail!(
                    "observations[{index}] has unsupported kind {:?}",
                    observation.kind
                );
            }
            if matches!(
                observation.kind.as_str(),
                "parameter" | "state" | "collection"
            ) && observation.slot.is_empty()
            {
                bail!("observations[{index}] requires a slot");
            }
            if matches!(observation.kind.as_str(), "parameter" | "return")
                && (observation.scope.path.is_empty()
                    || observation.scope.function.is_empty()
                    || observation.scope.line == 0)
            {
                bail!("observations[{index}] requires a path, function, and positive line");
            }
            if observation.kind == "state" && observation.scope.owner.is_empty() {
                bail!("observations[{index}] state evidence requires an owner");
            }
            observation
                .domain
                .validate(&format!("observations[{index}].domain"))?;
            if observation.domain.is_empty() {
                bail!("observations[{index}] has an empty value domain");
            }
        }
        for (index, call) in self.calls.iter().enumerate() {
            if call.language.is_empty() {
                bail!("calls[{index}].language must not be empty");
            }
            validate_method(&call.caller, &format!("calls[{index}].caller"))?;
            if call.callsite.path.is_empty() || call.callsite.line == 0 {
                bail!("calls[{index}].callsite requires path and positive line");
            }
            if call.targets.is_empty() {
                bail!("calls[{index}] must contain at least one semantic target");
            }
            for (target_index, target) in call.targets.iter().enumerate() {
                if target.symbol.is_empty() || target.name.is_empty() {
                    bail!("calls[{index}].targets[{target_index}] requires symbol and name");
                }
                if let Some(definition) = &target.definition {
                    validate_method(
                        definition,
                        &format!("calls[{index}].targets[{target_index}].definition"),
                    )?;
                }
            }
            if let Some(domain) = &call.receiver_domain {
                domain.validate(&format!("calls[{index}].receiver_domain"))?;
                if domain.is_empty() {
                    bail!("calls[{index}].receiver_domain must not be empty");
                }
            }
            if let Some(domain) = &call.result_domain {
                domain.validate(&format!("calls[{index}].result_domain"))?;
                if domain.is_empty() {
                    bail!("calls[{index}].result_domain must not be empty");
                }
            }
        }
        Ok(())
    }
}

fn validate_method(method: &MethodLocator, context: &str) -> Result<()> {
    if method.language.is_empty() || method.path.is_empty() || method.name.is_empty() {
        bail!("{context} requires language, path, and name");
    }
    Ok(())
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OverlayStats {
    pub observed_call_sites: usize,
    pub inferred_call_sites: usize,
    pub typed_receivers: usize,
    pub emitted_occurrences: usize,
}

#[derive(Clone, Debug)]
pub struct RuntimeScipOverlay {
    pub index: Value,
    pub stats: OverlayStats,
}

/// Overlay runtime observations on FactMine's normalized source/CFG/DFG facts
/// and emit the resulting identities as an ordinary runtime-authority SCIP
/// index. All propagation in this function operates on normalized facts; it
/// never parses a source-language expression.
pub fn apply_to_profile(
    output: &mut ProfileOutput,
    evidence: &RuntimeValueEvidence,
) -> Result<RuntimeScipOverlay> {
    evidence.validate()?;
    let method_index = MethodIndex::new(&output.methods);
    let return_domains = observed_return_domains(evidence, &method_index);
    let mut receiver_domains = observed_receiver_domains(output, evidence, &method_index);
    seed_fact_mine_receiver_domains(output, &method_index, &mut receiver_domains);
    let (exact_receiver_domains, exact_result_domains) =
        matched_observed_value_domains(output, evidence, &method_index);
    for (call_id, domain) in exact_receiver_domains {
        merge_domain(receiver_domains.entry(call_id).or_default(), &domain);
    }
    let observed = match_observed_calls(output, evidence, &method_index);
    seed_observed_call_receivers(&observed, &mut receiver_domains);
    let mut selected = observed.clone();
    let catalog = target_catalog(evidence);

    loop {
        let before_domains = receiver_domains.clone();
        let before_selected = selected.clone();
        propagate_call_results(
            output,
            &method_index,
            &return_domains,
            &exact_result_domains,
            &selected,
            &mut receiver_domains,
        );
        propagate_cfg_dfg_domains(
            output,
            evidence,
            &method_index,
            &return_domains,
            &exact_result_domains,
            &selected,
            &mut receiver_domains,
        );
        infer_targets(output, &catalog, &receiver_domains, &mut selected);
        if receiver_domains == before_domains && selected == before_selected {
            break;
        }
    }

    let mut stats = OverlayStats {
        observed_call_sites: observed.len(),
        inferred_call_sites: selected
            .keys()
            .filter(|id| !observed.contains_key(*id))
            .count(),
        ..OverlayStats::default()
    };
    for call in &mut output.calls {
        let Some(domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        if call.receiver_type.is_none() && domain.types.len() == 1 {
            call.receiver_type = domain.types.iter().next().cloned();
            call.receiver_type_origin = Some("runtime_value_evidence_cfg_dfg".to_string());
            stats.typed_receivers += 1;
        }
    }

    let index = build_scip_index(output, evidence, &selected, &method_index, &mut stats)?;
    if !selected.is_empty() {
        crate::scip::apply_json(output, &serde_json::to_string(&index)?)?;
    }
    Ok(RuntimeScipOverlay { index, stats })
}

struct MethodIndex<'a> {
    methods: &'a [MethodRecord],
    by_id: BTreeMap<&'a str, &'a MethodRecord>,
}

impl<'a> MethodIndex<'a> {
    fn new(methods: &'a [MethodRecord]) -> Self {
        Self {
            methods,
            by_id: methods
                .iter()
                .map(|method| (method.id.as_str(), method))
                .collect(),
        }
    }

    fn locate(&self, locator: &MethodLocator) -> Vec<&'a MethodRecord> {
        let scoped = self
            .methods
            .iter()
            .filter(|method| method.language == locator.language)
            .filter(|method| method.name == locator.name)
            .filter(|method| locator.line == 0 || method.line == locator.line)
            .filter(|method| {
                locator.owner.is_empty()
                    || method.owner == locator.owner
                    || method.owner.ends_with(&format!("::{}", locator.owner))
                    || locator.owner.ends_with(&format!("::{}", method.owner))
            })
            .filter(|method| path_matches(&method.path, &locator.path))
            .collect::<Vec<_>>();
        if !scoped.is_empty() {
            return scoped;
        }
        let unscoped = self
            .methods
            .iter()
            .filter(|method| method.language == locator.language)
            .filter(|method| method.name == locator.name)
            .filter(|method| locator.line == 0 || method.line == locator.line)
            .filter(|method| path_matches(&method.path, &locator.path))
            .collect::<Vec<_>>();
        (unscoped.len() == 1)
            .then_some(unscoped)
            .unwrap_or_default()
    }

    fn locate_scope(&self, scope: &ValueScope) -> Vec<&'a MethodRecord> {
        self.methods
            .iter()
            .filter(|method| method.language == scope.language)
            .filter(|method| scope.function.is_empty() || method.name == scope.function)
            .filter(|method| scope.line == 0 || method.line == scope.line)
            .filter(|method| {
                scope.owner.is_empty()
                    || method.owner == scope.owner
                    || method.owner.ends_with(&format!("::{}", scope.owner))
                    || scope.owner.ends_with(&format!("::{}", method.owner))
            })
            .filter(|method| scope.path.is_empty() || path_matches(&method.path, &scope.path))
            .collect()
    }
}

fn seed_observed_call_receivers(
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &mut BTreeMap<String, ValueDomain>,
) {
    for (call_id, targets) in selected {
        let types = targets
            .iter()
            .filter_map(|target| {
                (!target.receiver_type.is_empty())
                    .then_some(target.receiver_type.clone())
                    .or_else(|| (!target.owner.is_empty()).then_some(target.owner.clone()))
            })
            .collect::<BTreeSet<_>>();
        if !types.is_empty() {
            receiver_domains
                .entry(call_id.clone())
                .or_default()
                .types
                .extend(types);
        }
    }
}

fn seed_fact_mine_receiver_domains(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    receiver_domains: &mut BTreeMap<String, ValueDomain>,
) {
    for call in &output.calls {
        let Some(method) = methods.by_id.get(call.source.as_str()) else {
            continue;
        };
        let Some(source_type) = call
            .receiver_type
            .as_deref()
            .or(call.receiver_symbol.as_deref())
            .or_else(|| {
                (call.receiver_kind == "type" && !call.receiver.is_empty())
                    .then_some(call.receiver.as_str())
            })
        else {
            continue;
        };
        let domain = domain_from_type_source(source_type, &method.language);
        if !domain.is_empty() {
            merge_domain(
                receiver_domains.entry(call.id.clone()).or_default(),
                &domain,
            );
        }
    }
}

#[derive(Clone, Debug)]
struct FlowPoint {
    source: String,
    name: String,
    node_id: String,
    place_id: String,
    reaching_definitions: Vec<String>,
    definition_call_sources: BTreeMap<String, [usize; 4]>,
    callback_binding_position: Option<usize>,
    static_domain: ValueDomain,
    span: [usize; 4],
}

fn propagate_cfg_dfg_domains(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &mut BTreeMap<String, ValueDomain>,
) {
    let points = flow_points(output, methods);
    if points.is_empty() {
        return;
    }
    let mut node_domains = BTreeMap::<(String, String, String), ValueDomain>::new();
    for point in &points {
        if !point.static_domain.is_empty() {
            merge_domain(
                node_domains
                    .entry((
                        point.source.clone(),
                        point.node_id.clone(),
                        point.place_id.clone(),
                    ))
                    .or_default(),
                &point.static_domain,
            );
        }
    }

    // Runtime parameter observations seed the CFG entry definition, rather
    // than every same-spelled local. Reaching definitions then decide which
    // uses may inherit the observed domain.
    for observation in evidence.observations.iter().filter(|row| {
        row.kind == "parameter" || (row.kind == "collection" && row.slot_kind == "method_param")
    }) {
        for method in methods.locate_scope(&observation.scope) {
            for point in points
                .iter()
                .filter(|point| point.source == method.id && point.name == observation.slot)
            {
                for definition in point
                    .reaching_definitions
                    .iter()
                    .filter(|definition| definition.contains(":entry:"))
                {
                    merge_domain(
                        node_domains
                            .entry((
                                point.source.clone(),
                                definition.clone(),
                                point.place_id.clone(),
                            ))
                            .or_default(),
                        &observation.domain,
                    );
                }
            }
        }
    }

    // Existing call domains are facts at their CFG use sites. This includes
    // runtime state observations and compiler/type-analyzer receiver facts.
    seed_flow_nodes_from_calls(output, &points, receiver_domains, &mut node_domains);

    // A normalized iteration relation binds collection value domains to block
    // locals. The source-language adapter decides whether a call is an
    // iteration; this layer only projects the already-normalized relation.
    seed_collection_callback_nodes(
        output,
        methods,
        &points,
        receiver_domains,
        &mut node_domains,
    );
    seed_call_result_definitions(
        output,
        methods,
        &points,
        return_domains,
        exact_result_domains,
        selected,
        receiver_domains,
        &mut node_domains,
    );

    loop {
        let before = node_domains.clone();
        for point in &points {
            let reaching = point
                .reaching_definitions
                .iter()
                .filter_map(|definition| {
                    node_domains.get(&(
                        point.source.clone(),
                        definition.clone(),
                        point.place_id.clone(),
                    ))
                })
                .collect::<Vec<_>>();
            if let Some(domain) = joined_domain(&reaching) {
                merge_domain(
                    node_domains
                        .entry((
                            point.source.clone(),
                            point.node_id.clone(),
                            point.place_id.clone(),
                        ))
                        .or_default(),
                    &domain,
                );
            }
        }
        if node_domains == before {
            break;
        }
    }

    for call in &output.calls {
        let domains = points
            .iter()
            .filter(|point| {
                point.source == call.source
                    && point.name == call.receiver
                    && span_contains_line(point.span, call.line)
            })
            .filter_map(|point| {
                node_domains.get(&(
                    point.source.clone(),
                    point.node_id.clone(),
                    point.place_id.clone(),
                ))
            })
            .collect::<Vec<_>>();
        if let Some(domain) = joined_domain(&domains) {
            merge_domain(
                receiver_domains.entry(call.id.clone()).or_default(),
                &domain,
            );
        }
    }
}

fn flow_points(output: &ProfileOutput, methods: &MethodIndex<'_>) -> Vec<FlowPoint> {
    output
        .flow_local_types
        .iter()
        .filter_map(|flow| {
            let file = flow["file"].as_str()?;
            let owner = flow["owner"].as_str()?;
            let function = flow["function"].as_str()?;
            let name = flow["name"].as_str()?;
            let node_id = flow["node_id"].as_str()?;
            let place_id = flow["place_id"].as_str()?;
            let span = serde_json::from_value::<[usize; 4]>(flow["span"].clone()).ok()?;
            let candidates = methods
                .methods
                .iter()
                .filter(|method| method.name == function && path_matches(&method.path, file))
                .collect::<Vec<_>>();
            let owner_candidates = candidates
                .iter()
                .copied()
                .filter(|method| method.owner == owner)
                .collect::<Vec<_>>();
            let method = if owner_candidates.len() == 1 {
                owner_candidates[0]
            } else if owner_candidates.is_empty() && candidates.len() == 1 {
                candidates[0]
            } else {
                return None;
            };
            Some(FlowPoint {
                source: method.id.clone(),
                name: name.to_string(),
                node_id: node_id.to_string(),
                place_id: place_id.to_string(),
                reaching_definitions: flow["reaching_definitions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect(),
                definition_call_sources: serde_json::from_value(
                    flow["definition_call_sources"].clone(),
                )
                .unwrap_or_default(),
                callback_binding_position: flow["callback_binding_position"]
                    .as_u64()
                    .map(|position| position as usize),
                static_domain: {
                    let mut domain = ValueDomain::default();
                    for value in flow["resolved_types"].as_array().into_iter().flatten() {
                        if let Ok(value) = serde_json::from_value::<TypeExpr>(value.clone()) {
                            merge_domain(
                                &mut domain,
                                &domain_from_type_expr_source_language(&value, &method.language),
                            );
                        }
                    }
                    if domain.is_empty() {
                        for hint in flow["types"].as_array().into_iter().flatten() {
                            if let Some(hint) = hint.as_str() {
                                merge_domain(
                                    &mut domain,
                                    &domain_from_type_source(hint, &method.language),
                                );
                            }
                        }
                    }
                    domain
                },
                span,
            })
        })
        .collect()
}

fn seed_flow_nodes_from_calls(
    output: &ProfileOutput,
    points: &[FlowPoint],
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut BTreeMap<(String, String, String), ValueDomain>,
) {
    for call in &output.calls {
        let Some(domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        for point in points.iter().filter(|point| {
            point.source == call.source
                && point.name == call.receiver
                && span_contains_line(point.span, call.line)
        }) {
            merge_domain(
                node_domains
                    .entry((
                        point.source.clone(),
                        point.node_id.clone(),
                        point.place_id.clone(),
                    ))
                    .or_default(),
                domain,
            );
        }
    }
}

fn seed_collection_callback_nodes(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    points: &[FlowPoint],
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut BTreeMap<(String, String, String), ValueDomain>,
) {
    for call in &output.calls {
        let Some(receiver_domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        let Some(method) = methods.by_id.get(call.source.as_str()) else {
            continue;
        };
        let Ok(language) = crate::syntax::Language::parse(&method.language) else {
            continue;
        };
        let behavior = crate::syntax::normalized_behavior::behavior(language);
        let receiver_type = call
            .receiver_type
            .as_deref()
            .map(|value| TypeExpr::parse(value, &method.language));
        let iteration = behavior.collection_callback_parameter(&call.message)
            || behavior.block_call_semantics_with_receiver(
                Some(&call.receiver),
                receiver_type.as_ref(),
                &call.message,
            ) == crate::syntax::normalized_behavior::BlockCallSemantics::Iteration;
        if !iteration {
            continue;
        }
        let iteration_span = normalized_iteration_span(output, method, call);
        let mut callback_points = points
            .iter()
            .filter(|point| {
                point.source == call.source
                    && point.name != call.receiver
                    && point.callback_binding_position.is_some()
                    && iteration_span
                        .map(|span| {
                            span_contains_line(span, point.span[0]) && point.span[2] <= span[2]
                        })
                        .unwrap_or(point.span[0] == call.line)
            })
            .collect::<Vec<_>>();
        callback_points.sort_by_key(|point| point.callback_binding_position);
        if callback_points.is_empty() {
            continue;
        }
        let receiver_type = behavior.runtime_value_domain_type(
            &receiver_domain.types.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.elements.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.keys.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.values.iter().cloned().collect::<Vec<_>>(),
        );
        let projections = behavior.runtime_collection_callback_projections(
            receiver_type.as_deref(),
            &call.message,
            callback_points.len(),
        );
        for (point, projection) in callback_points.into_iter().zip(projections) {
            let callback_domain = projected_collection_domain(receiver_domain, projection);
            if callback_domain.is_empty() {
                continue;
            }
            merge_domain(
                node_domains
                    .entry((
                        point.source.clone(),
                        point.node_id.clone(),
                        point.place_id.clone(),
                    ))
                    .or_default(),
                &callback_domain,
            );
        }
    }
}

fn normalized_iteration_span(
    output: &ProfileOutput,
    method: &MethodRecord,
    call: &CallRecord,
) -> Option<[usize; 4]> {
    output
        .complexity_facts
        .iter()
        .filter(|fact| {
            path_matches(&fact.path, &method.path)
                && fact.owner == method.owner
                && fact.function == method.name
                && fact.line == method.line
        })
        .flat_map(|fact| &fact.iterations)
        .filter(|iteration| {
            iteration.message.as_deref() == Some(call.message.as_str())
                && iteration.line == call.line
        })
        .map(|iteration| iteration.span)
        .filter(|span| span_contains(*span, call.span))
        .min_by_key(|span| {
            (
                span[2].saturating_sub(span[0]),
                span[3].saturating_sub(span[1]),
            )
        })
}

#[allow(clippy::too_many_arguments)]
fn seed_call_result_definitions(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    points: &[FlowPoint],
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut BTreeMap<(String, String, String), ValueDomain>,
) {
    let calls = output
        .calls
        .iter()
        .map(|call| ((call.source.as_str(), call.span), call))
        .collect::<BTreeMap<_, _>>();
    for point in points {
        for (definition, span) in &point.definition_call_sources {
            let Some(call) = calls.get(&(point.source.as_str(), *span)).copied() else {
                continue;
            };
            let Some(domain) = call_result_domain(
                call,
                methods,
                return_domains,
                exact_result_domains,
                selected,
                receiver_domains,
            ) else {
                continue;
            };
            merge_domain(
                node_domains
                    .entry((
                        point.source.clone(),
                        definition.clone(),
                        point.place_id.clone(),
                    ))
                    .or_default(),
                &domain,
            );
        }
    }
}

fn call_result_domain(
    call: &CallRecord,
    methods: &MethodIndex<'_>,
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
) -> Option<ValueDomain> {
    if let Some(domain) = exact_result_domains.get(&call.id) {
        return Some(domain.clone());
    }
    let mut observed = Vec::new();
    if let Some(domain) = call
        .target
        .as_deref()
        .and_then(|target| return_domains.get(target))
    {
        observed.push(domain);
    }
    if let Some(targets) = selected.get(&call.id) {
        for target in targets {
            let Some(definition) = &target.definition else {
                continue;
            };
            for method in methods.locate(definition) {
                if let Some(domain) = return_domains.get(&method.id) {
                    observed.push(domain);
                }
            }
        }
    }
    if let Some(domain) = joined_domain(&observed) {
        return Some(domain);
    }

    let receiver_domain = receiver_domains.get(&call.id)?;
    let method = methods.by_id.get(call.source.as_str())?;
    let language = crate::syntax::Language::parse(&method.language).ok()?;
    let behavior = crate::syntax::normalized_behavior::behavior(language);
    let receiver_type = behavior.runtime_value_domain_type(
        &receiver_domain.types.iter().cloned().collect::<Vec<_>>(),
        &receiver_domain.elements.iter().cloned().collect::<Vec<_>>(),
        &receiver_domain.keys.iter().cloned().collect::<Vec<_>>(),
        &receiver_domain.values.iter().cloned().collect::<Vec<_>>(),
    )?;
    if let Some(projection) = behavior.runtime_call_result_projection(
        Some(&receiver_type),
        &call.message,
        &call.arguments,
    ) {
        let domain = projected_call_result_domain(receiver_domain, projection);
        if !domain.is_empty() {
            return Some(domain);
        }
    }
    let result_type = behavior
        .static_return_type(&call.message, Some(&receiver_type))
        .or_else(|| {
            behavior.propagated_collection_return_type(&call.message, Some(&receiver_type))
        })?;
    let domain = domain_from_type_source(&result_type, &method.language);
    (!domain.is_empty()).then_some(domain)
}

fn projected_call_result_domain(
    receiver: &ValueDomain,
    projection: crate::syntax::normalized_behavior::RuntimeCallResultProjection,
) -> ValueDomain {
    use crate::syntax::normalized_behavior::RuntimeCallResultProjection;
    match projection {
        RuntimeCallResultProjection::Receiver => receiver.clone(),
        RuntimeCallResultProjection::Element => collection_element_domain(receiver),
        RuntimeCallResultProjection::Value => ValueDomain {
            types: receiver.values.clone(),
            ..ValueDomain::default()
        },
        RuntimeCallResultProjection::Keys { collection_type } => ValueDomain {
            types: BTreeSet::from([collection_type.to_string()]),
            elements: receiver.keys.clone(),
            ..ValueDomain::default()
        },
        RuntimeCallResultProjection::Values { collection_type } => ValueDomain {
            types: BTreeSet::from([collection_type.to_string()]),
            elements: receiver.values.clone(),
            ..ValueDomain::default()
        },
    }
}

fn collection_element_domain(collection: &ValueDomain) -> ValueDomain {
    ValueDomain {
        types: collection.elements.clone(),
        shapes: collection
            .shapes
            .iter()
            .flat_map(|shape| shape.elements.iter().cloned())
            .collect(),
        ..ValueDomain::default()
    }
}

fn projected_collection_domain(
    collection: &ValueDomain,
    projection: crate::syntax::normalized_behavior::RuntimeValueProjection,
) -> ValueDomain {
    use crate::syntax::normalized_behavior::RuntimeValueProjection;
    match projection {
        RuntimeValueProjection::Element => collection_element_domain(collection),
        RuntimeValueProjection::Key => ValueDomain {
            types: collection.keys.clone(),
            ..ValueDomain::default()
        },
        RuntimeValueProjection::Value => ValueDomain {
            types: collection.values.clone(),
            ..ValueDomain::default()
        },
        RuntimeValueProjection::Entry { collection_type } => ValueDomain {
            types: BTreeSet::from([collection_type.to_string()]),
            elements: collection.keys.union(&collection.values).cloned().collect(),
            ..ValueDomain::default()
        },
        RuntimeValueProjection::Index { type_name } => ValueDomain {
            types: BTreeSet::from([type_name.to_string()]),
            ..ValueDomain::default()
        },
    }
}

fn span_contains_line(span: [usize; 4], line: usize) -> bool {
    span[0] <= line && line <= span[2]
}

fn span_contains(outer: [usize; 4], inner: [usize; 4]) -> bool {
    (outer[0], outer[1]) <= (inner[0], inner[1]) && (outer[2], outer[3]) >= (inner[2], inner[3])
}

fn observed_return_domains(
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> BTreeMap<String, ValueDomain> {
    let mut domains = BTreeMap::new();
    for observation in evidence
        .observations
        .iter()
        .filter(|observation| observation.kind == "return")
    {
        for method in methods.locate_scope(&observation.scope) {
            merge_domain(
                domains.entry(method.id.clone()).or_default(),
                &observation.domain,
            );
        }
    }
    domains
}

fn observed_receiver_domains(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> BTreeMap<String, ValueDomain> {
    let mut domains = BTreeMap::new();
    for observation in &evidence.observations {
        match observation.kind.as_str() {
            "parameter" => {
                for method in methods.locate_scope(&observation.scope) {
                    seed_method_slot(
                        output,
                        method,
                        &observation.slot,
                        &observation.domain,
                        &mut domains,
                    );
                }
            }
            "collection" if observation.slot_kind == "method_param" => {
                let candidates = methods.locate_scope(&observation.scope);
                for method in candidates {
                    seed_method_slot(
                        output,
                        method,
                        &observation.slot,
                        &observation.domain,
                        &mut domains,
                    );
                }
                // Legacy tracers may identify a parameter collection by path,
                // declaration line, and slot without repeating the method name.
                if observation.scope.function.is_empty() {
                    for method in methods
                        .methods
                        .iter()
                        .filter(|method| method.language == observation.scope.language)
                        .filter(|method| {
                            path_matches(&method.path, &observation.scope.path)
                                && method.line == observation.scope.line
                                && method.params.contains(&observation.slot)
                        })
                    {
                        seed_method_slot(
                            output,
                            method,
                            &observation.slot,
                            &observation.domain,
                            &mut domains,
                        );
                    }
                }
            }
            "state" => {
                let slot = observation.slot.trim_start_matches('@');
                for call in output.calls.iter().filter(|call| {
                    call.state_receiver
                        && call.receiver.trim_start_matches('@') == slot
                        && (observation.scope.owner.is_empty()
                            || call.owner == observation.scope.owner
                            || call
                                .owner
                                .ends_with(&format!("::{}", observation.scope.owner)))
                }) {
                    merge_domain(
                        domains.entry(call.id.clone()).or_default(),
                        &observation.domain,
                    );
                }
            }
            _ => {}
        }
    }
    domains
}

fn seed_method_slot(
    output: &ProfileOutput,
    method: &MethodRecord,
    slot: &str,
    domain: &ValueDomain,
    domains: &mut BTreeMap<String, ValueDomain>,
) {
    for call in output
        .calls
        .iter()
        .filter(|call| call.source == method.id && call.receiver == slot)
    {
        merge_domain(domains.entry(call.id.clone()).or_default(), domain);
    }
}

fn match_observed_calls(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> BTreeMap<String, Vec<SemanticTarget>> {
    let mut selected = BTreeMap::<String, Vec<SemanticTarget>>::new();
    for observed in &evidence.calls {
        for call in matched_profile_calls(output, methods, observed) {
            let entry = selected.entry(call.id.clone()).or_default();
            entry.extend(observed.targets.clone());
            sort_dedup_targets(entry);
        }
    }
    selected
}

fn matched_observed_value_domains(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> (BTreeMap<String, ValueDomain>, BTreeMap<String, ValueDomain>) {
    let mut receivers = BTreeMap::<String, ValueDomain>::new();
    let mut results = BTreeMap::<String, ValueDomain>::new();
    for observed in &evidence.calls {
        for call in matched_profile_calls(output, methods, observed) {
            if let Some(domain) = &observed.receiver_domain {
                merge_domain(receivers.entry(call.id.clone()).or_default(), domain);
            }
            if let Some(domain) = &observed.result_domain {
                merge_domain(results.entry(call.id.clone()).or_default(), domain);
            }
        }
    }
    (receivers, results)
}

fn matched_profile_calls<'a>(
    output: &'a ProfileOutput,
    methods: &MethodIndex<'_>,
    observed: &ObservedCall,
) -> Vec<&'a CallRecord> {
    let mut candidates = methods
        .locate(&observed.caller)
        .into_iter()
        .flat_map(|caller| {
            output
                .calls
                .iter()
                .filter(move |call| call.source == caller.id)
        })
        .filter(|call| call.message == observed.callsite.selector)
        .filter(|call| path_matches(&call.path, &observed.callsite.path))
        .collect::<Vec<_>>();
    if let Some(range) = observed.callsite.range {
        candidates.retain(|call| zero_based(call.span) == range);
    } else {
        let same_line = candidates
            .iter()
            .copied()
            .filter(|call| call.line == observed.callsite.line)
            .collect::<Vec<_>>();
        if !same_line.is_empty() {
            candidates = same_line;
        }
    }
    candidates
}

fn target_catalog(evidence: &RuntimeValueEvidence) -> BTreeMap<String, Vec<SemanticTarget>> {
    let mut catalog = BTreeMap::<String, Vec<SemanticTarget>>::new();
    for call in &evidence.calls {
        let entry = catalog.entry(call.callsite.selector.clone()).or_default();
        entry.extend(call.targets.clone());
        sort_dedup_targets(entry);
    }
    catalog
}

fn propagate_call_results(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &mut BTreeMap<String, ValueDomain>,
) {
    let mut producer_domains = BTreeMap::<(String, String, [usize; 4]), ValueDomain>::new();
    for producer in &output.calls {
        let Some(domain) = call_result_domain(
            producer,
            methods,
            return_domains,
            exact_result_domains,
            selected,
            receiver_domains,
        ) else {
            continue;
        };
        producer_domains.insert(
            (
                producer.source.clone(),
                producer.path.clone(),
                producer.span,
            ),
            domain,
        );
    }
    for call in &output.calls {
        let spans = call
            .receiver_call_span
            .into_iter()
            .chain(call.receiver_definition_call_spans.iter().copied());
        let domains = spans
            .filter_map(|span| {
                producer_domains.get(&(call.source.clone(), call.path.clone(), span))
            })
            .collect::<Vec<_>>();
        if let Some(domain) = joined_domain(&domains) {
            merge_domain(
                receiver_domains.entry(call.id.clone()).or_default(),
                &domain,
            );
        }
    }
}

fn infer_targets(
    output: &ProfileOutput,
    catalog: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    selected: &mut BTreeMap<String, Vec<SemanticTarget>>,
) {
    for call in &output.calls {
        if selected.contains_key(&call.id) || call.target.is_some() {
            continue;
        }
        let catalog_candidates = catalog
            .get(&call.message)
            .into_iter()
            .flatten()
            .filter(|target| {
                call.receiver_kind != "type" || target.kind == "class" || target.kind == "static"
            })
            .cloned()
            .collect::<Vec<_>>();
        let Some(domain) = receiver_domains.get(&call.id) else {
            let owners = catalog_candidates
                .iter()
                .filter_map(|target| {
                    (!target.owner.is_empty())
                        .then_some(target.owner.as_str())
                        .or_else(|| {
                            (!target.receiver_type.is_empty())
                                .then_some(target.receiver_type.as_str())
                        })
                })
                .collect::<BTreeSet<_>>();
            if owners.len() == 1 && !catalog_candidates.is_empty() {
                selected.insert(call.id.clone(), catalog_candidates);
            }
            continue;
        };
        let candidates = catalog_candidates
            .into_iter()
            .filter(|target| {
                domain.types.iter().any(|ty| {
                    runtime_owner_matches(&target.receiver_type, ty)
                        || runtime_owner_matches(&target.owner, ty)
                })
            })
            .collect::<Vec<_>>();
        if !candidates.is_empty() {
            selected.insert(call.id.clone(), candidates);
        }
    }
}

fn build_scip_index(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    methods: &MethodIndex<'_>,
    stats: &mut OverlayStats,
) -> Result<Value> {
    let project_root = std::env::current_dir()
        .map(|root| crate::lsp_scip::path_to_file_uri(&root))
        .unwrap_or_default();
    let mut occurrences = BTreeMap::<String, Vec<Value>>::new();
    let mut symbols = BTreeMap::<String, BTreeMap<String, Value>>::new();
    let mut languages = BTreeMap::<String, String>::new();
    let calls = output
        .calls
        .iter()
        .map(|call| (call.id.as_str(), call))
        .collect::<BTreeMap<_, _>>();

    for (call_id, targets) in selected {
        let Some(call) = calls.get(call_id.as_str()).copied() else {
            continue;
        };
        let path = normalized_document_path(&call.path);
        let range = selector_range(call).unwrap_or_else(|| zero_based(call.span));
        let scip_range = compact_range(range);
        let language = methods
            .by_id
            .get(call.source.as_str())
            .map(|method| method.language.clone())
            .unwrap_or_default();
        languages.insert(path.clone(), language);
        for target in targets {
            occurrences.entry(path.clone()).or_default().push(json!({
                "range": scip_range,
                "symbol": target.symbol,
                "symbolRoles": 0
            }));
            stats.emitted_occurrences += 1;
            let Some(definition) = &target.definition else {
                continue;
            };
            for method in methods.locate(definition) {
                let definition_path = normalized_document_path(&method.path);
                let definition_range = definition_name_range(method).unwrap_or_else(|| {
                    zero_based(method.span.unwrap_or([
                        method.line,
                        0,
                        method.line,
                        method.name.len(),
                    ]))
                });
                occurrences
                    .entry(definition_path.clone())
                    .or_default()
                    .push(json!({
                        "range": compact_range(definition_range),
                        "symbol": target.symbol,
                        "symbolRoles": 1
                    }));
                symbols
                    .entry(definition_path.clone())
                    .or_default()
                    .entry(target.symbol.clone())
                    .or_insert_with(|| json!({"symbol": target.symbol}));
                languages.insert(definition_path, method.language.clone());
            }
        }
    }

    let documents = occurrences
        .into_iter()
        .map(|(path, mut rows)| {
            rows.sort_by_key(|row| serde_json::to_string(row).unwrap_or_default());
            rows.dedup();
            json!({
                "language": languages.get(&path).cloned().unwrap_or_default(),
                "relativePath": path,
                "occurrences": rows,
                "symbols": symbols.remove(&path).unwrap_or_default().into_values().collect::<Vec<_>>()
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "metadata": {
            "version": 0,
            "toolInfo": {
                "name": "nil-kill-runtime",
                "version": "2",
                "arguments": ["--fact-mine-index-authority=runtime-modeled-world"]
            },
            "projectRoot": project_root,
            "textDocumentEncoding": 1
        },
        "documents": documents,
        "externalSymbols": [],
        "_runtimeEvidence": {
            "schema": evidence.schema,
            "runs": evidence.runs,
            "observedCallSites": stats.observed_call_sites,
            "inferredCallSites": stats.inferred_call_sites,
            "typedReceivers": stats.typed_receivers,
            "emittedOccurrences": stats.emitted_occurrences
        }
    }))
}

fn selector_range(call: &CallRecord) -> Option<[usize; 4]> {
    if call.span[0] != call.span[2] {
        return None;
    }
    let line = fs::read_to_string(&call.path)
        .ok()?
        .lines()
        .nth(call.span[0].saturating_sub(1))?
        .to_string();
    let start = call.span[1].min(line.len());
    let end = call.span[3].min(line.len());
    let source = line.get(start..end)?;
    let message = call
        .message
        .trim()
        .trim_start_matches("self.")
        .trim_start_matches("this.");
    if matches!(message, "[]" | "[]=") {
        let offset = source.find('[')?;
        return Some([
            call.span[0].saturating_sub(1),
            start + offset,
            call.span[0].saturating_sub(1),
            start + offset + 1,
        ]);
    }
    let offset = source.rfind(message)?;
    let selector_length = if source
        .get(offset + message.len()..)
        .is_some_and(|suffix| suffix.starts_with('='))
        && matches!(
            message,
            "+" | "-" | "*" | "/" | "%" | "**" | "<<" | ">>" | "&" | "|" | "^"
        ) {
        message.len() + 1
    } else {
        message.len()
    };
    Some([
        call.span[0].saturating_sub(1),
        start + offset,
        call.span[0].saturating_sub(1),
        start + offset + selector_length,
    ])
}

fn definition_name_range(method: &MethodRecord) -> Option<[usize; 4]> {
    let span = method.span?;
    let source = fs::read_to_string(&method.path).ok()?;
    for (offset, line) in source
        .lines()
        .skip(span[0].saturating_sub(1))
        .take(span[2].saturating_sub(span[0]) + 1)
        .enumerate()
    {
        if let Some(column) = line.find(&method.name) {
            let zero_line = span[0].saturating_sub(1) + offset;
            return Some([zero_line, column, zero_line, column + method.name.len()]);
        }
    }
    None
}

fn compact_range(range: [usize; 4]) -> Vec<usize> {
    if range[0] == range[2] {
        vec![range[0], range[1], range[3]]
    } else {
        range.to_vec()
    }
}

fn zero_based(span: [usize; 4]) -> [usize; 4] {
    [
        span[0].saturating_sub(1),
        span[1],
        span[2].saturating_sub(1),
        span[3],
    ]
}

fn normalized_document_path(path: &str) -> String {
    let path = path.replace('\\', "/");
    std::env::current_dir()
        .ok()
        .and_then(|root| {
            Path::new(&path)
                .strip_prefix(root)
                .ok()
                .map(|relative| relative.to_string_lossy().replace('\\', "/"))
        })
        .unwrap_or(path)
}

fn path_matches(left: &str, right: &str) -> bool {
    let left = left.replace('\\', "/");
    let right = right.replace('\\', "/");
    left == right || left.ends_with(&format!("/{right}")) || right.ends_with(&format!("/{left}"))
}

fn runtime_owner_matches(observed: &str, expected: &str) -> bool {
    !observed.is_empty()
        && !expected.is_empty()
        && (observed == expected
            || observed.ends_with(&format!("::{expected}"))
            || expected.ends_with(&format!("::{observed}")))
}

fn domain_from_type_source(source: &str, language: &str) -> ValueDomain {
    let parsed = TypeExpr::from_flow_hint(source, language)
        .unwrap_or_else(|| TypeExpr::parse(source, language));
    domain_from_type_expr_source_language(&parsed, language)
}

fn domain_from_type_expr_source_language(value: &TypeExpr, language: &str) -> ValueDomain {
    let Some(language) = crate::syntax::Language::parse(language).ok() else {
        return ValueDomain::default();
    };
    domain_from_type_expr(
        value,
        crate::syntax::normalized_behavior::behavior(language),
    )
}

fn domain_from_type_expr(
    value: &TypeExpr,
    behavior: &dyn crate::syntax::normalized_behavior::NormalizedLanguageBehavior,
) -> ValueDomain {
    match value {
        TypeExpr::Untyped => ValueDomain::default(),
        TypeExpr::NilClass => behavior
            .runtime_nil_type_name()
            .map(|name| ValueDomain {
                types: BTreeSet::from([name.to_string()]),
                ..ValueDomain::default()
            })
            .unwrap_or_default(),
        TypeExpr::Primitive(name) => ValueDomain {
            types: BTreeSet::from([name.clone()]),
            ..ValueDomain::default()
        },
        TypeExpr::Nilable(inner) => {
            let mut domain = domain_from_type_expr(inner, behavior);
            if let Some(name) = behavior.runtime_nil_type_name() {
                domain.types.insert(name.to_string());
            }
            domain
        }
        TypeExpr::Array(inner) => {
            let mut domain = ValueDomain {
                elements: domain_from_type_expr(inner, behavior).types,
                ..ValueDomain::default()
            };
            if let Some(name) = behavior.runtime_array_type_name() {
                domain.types.insert(name.to_string());
            }
            domain
        }
        TypeExpr::Hash { key, value } => ValueDomain {
            types: behavior
                .runtime_hash_type_name()
                .map(|name| BTreeSet::from([name.to_string()]))
                .unwrap_or_default(),
            keys: domain_from_type_expr(key, behavior).types,
            values: domain_from_type_expr(value, behavior).types,
            ..ValueDomain::default()
        },
        TypeExpr::Set(inner) => ValueDomain {
            types: behavior
                .runtime_set_type_name()
                .map(|name| BTreeSet::from([name.to_string()]))
                .unwrap_or_default(),
            elements: domain_from_type_expr(inner, behavior).types,
            ..ValueDomain::default()
        },
        TypeExpr::Union(parts) => {
            let mut domain = ValueDomain::default();
            for part in parts {
                merge_domain(&mut domain, &domain_from_type_expr(part, behavior));
            }
            domain
        }
    }
}

fn merge_domain(target: &mut ValueDomain, source: &ValueDomain) {
    target.types.extend(source.types.iter().cloned());
    target.elements.extend(source.elements.iter().cloned());
    target.keys.extend(source.keys.iter().cloned());
    target.values.extend(source.values.iter().cloned());
    for shape in &source.shapes {
        if !target.shapes.contains(shape) {
            target.shapes.push(shape.clone());
        }
    }
}

fn joined_domain(domains: &[&ValueDomain]) -> Option<ValueDomain> {
    let mut joined = ValueDomain::default();
    for domain in domains {
        merge_domain(&mut joined, domain);
    }
    (!joined.is_empty()).then_some(joined)
}

fn sort_dedup_targets(targets: &mut Vec<SemanticTarget>) {
    targets.sort_by(|left, right| left.symbol.cmp(&right.symbol));
    targets.dedup();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::{self, Profile};
    use crate::syntax::{self, Language};
    use serde_json::json;
    use std::io::Write;

    fn valid_evidence() -> serde_json::Value {
        json!({
            "schema": SCHEMA,
            "authority": "runtime-modeled-world",
            "environment": {"runtime.version": "3.2.3"},
            "runs": ["run-1"],
            "observations": [{
                "kind": "parameter",
                "scope": {
                    "language": "ruby",
                    "path": "lib/worker.rb",
                    "owner": "Worker",
                    "function": "run",
                    "line": 2
                },
                "slot": "rows",
                "domain": {
                    "types": ["Array"],
                    "elements": ["Row"]
                },
                "count": 3
            }],
            "calls": [{
                "language": "ruby",
                "caller": {
                    "language": "ruby",
                    "path": "lib/worker.rb",
                    "owner": "Worker",
                    "name": "run",
                    "kind": "instance",
                    "line": 2
                },
                "callsite": {
                    "path": "lib/worker.rb",
                    "line": 3,
                    "selector": "kind"
                },
                "targets": [{
                    "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                    "owner": "Row",
                    "name": "kind",
                    "kind": "instance",
                    "receiver_type": "Row"
                }],
                "count": 3
            }]
        })
    }

    #[test]
    fn accepts_language_neutral_value_and_call_evidence() {
        let evidence =
            RuntimeValueEvidence::from_json(&valid_evidence().to_string()).expect("evidence");
        assert_eq!(evidence.observations[0].domain.elements.len(), 1);
        assert_eq!(evidence.calls[0].targets[0].owner, "Row");
    }

    #[test]
    fn rejects_analysis_rules_and_empty_domains_at_the_contract_boundary() {
        let mut evidence = valid_evidence();
        evidence["observations"][0]["kind"] = json!("assignment");
        assert!(RuntimeValueEvidence::from_json(&evidence.to_string())
            .unwrap_err()
            .to_string()
            .contains("unsupported kind"));

        let mut evidence = valid_evidence();
        evidence["observations"][0]["domain"] = json!({});
        assert!(RuntimeValueEvidence::from_json(&evidence.to_string())
            .unwrap_err()
            .to_string()
            .contains("empty value domain"));
    }

    #[test]
    fn cfg_dfg_overlay_propagates_parameter_elements_to_block_receivers() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"Row = Struct.new(:kind)
class Worker
  def observed(row)
    row.kind
  end

  def run(rows)
    rows.each { |row| row.kind }
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 7
                    },
                    "slot": "rows",
                    "domain": {"types": ["Array"], "elements": ["Row"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 3
                    },
                    "callsite": {"path": path, "line": 4, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        let overlay = apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred block call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
        assert_eq!(overlay.stats.observed_call_sites, 1);
        assert_eq!(overlay.stats.inferred_call_sites, 1);
    }

    #[test]
    fn cfg_dfg_overlay_follows_block_binding_reaching_definitions_across_statements() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(row)
    row.kind
  end

  def run(rows)
    selected = rows.select do |row|
      row.active?
    end
    selected.map do |row|
      row.kind
    end
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 6
                    },
                    "slot": "rows",
                    "domain": {"types": ["Array"], "elements": ["Row"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred block call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_uses_language_normalized_hash_callback_bindings() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(row)
    row.kind
  end

  def run(rows)
    rows.each do |key, row|
      row.kind
    end
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 6
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Hash"], "keys": ["String"], "values": ["Row"]
                    },
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred hash value call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_projects_normalized_collection_call_results() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(row)
    row.kind
  end

  def run(rows)
    rows[:first].kind
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 6
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Hash"], "keys": ["Symbol"], "values": ["Row"]
                    },
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred hash result call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_propagates_exact_observed_call_results() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(row)
    row.kind
  end

  def run(payload)
    rows = payload.fetch("rows", [])
    rows.each { |row| row.kind }
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 6
                    },
                    "callsite": {"path": path, "line": 7, "selector": "fetch"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3 Hash#fetch().",
                        "owner": "Hash", "name": "fetch", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {
                        "types": ["Hash"], "keys": ["String"], "values": ["Array"]
                    },
                    "result_domain": {
                        "types": ["Array"], "elements": ["Row"]
                    },
                    "count": 1
                }, {
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred exact-result callback call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_uses_fact_mine_proven_receiver_types() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(value)
    value.render
  end

  def run
    value = "preview"
    value.render
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "render"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc String#render().",
                        "owner": "String", "name": "render", "kind": "instance",
                        "receiver_type": "String"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "render")
            .expect("inferred statically typed call");

        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc String#render().")
        );
    }

    #[test]
    fn modeled_world_infers_an_untyped_call_only_when_observed_owners_converge() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(value)
    value.render
  end

  def run(value)
    value.render
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "render"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Renderer#render().",
                        "owner": "Renderer", "name": "render", "kind": "instance",
                        "receiver_type": "Renderer"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "render")
            .expect("inferred modeled-world call");

        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Renderer#render().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_propagates_observed_project_returns_through_direct_calls() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(row)
    row.kind
  end

  def rows
    []
  end

  def run
    rows.each { |row| row.kind }
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "return",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "rows", "line": 6
                    },
                    "domain": {"types": ["Array"], "elements": ["Row"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "observed",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "kind"},
                    "targets": [{
                        "symbol": "nil-kill-runtime workspace demo abc Row#kind().",
                        "owner": "Row", "name": "kind", "kind": "instance",
                        "receiver_type": "Row"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let inferred = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("inferred block call");

        assert_eq!(inferred.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            inferred.semantic_symbol.as_deref(),
            Some("nil-kill-runtime workspace demo abc Row#kind().")
        );
    }
}
