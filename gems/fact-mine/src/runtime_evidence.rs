//! Language-neutral runtime value evidence.
//!
//! Tracers own observation. FactMine owns every relation between an observed
//! value and normalized source/CFG/DFG facts. In particular, this schema must
//! never grow assignments, AST nodes, block-binding rules, or source-language
//! expressions: those would duplicate FactMine's analysis in each tracer.

use anyhow::{bail, Context, Result};
#[cfg(test)]
use flate2::read::GzDecoder;
use protobuf::Enum;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
#[cfg(test)]
use std::io::Read;
use std::path::Path;

use crate::profile::{CallRecord, MethodRecord, ProfileOutput};
#[cfg(test)]
use crate::runtime_protocol::CaptureStatus;
use crate::runtime_protocol::{self, runtime_value, AnchorBinding, BuiltTracePlan, EvidenceKind};
use crate::type_inference::TypeExpr;

// Private normalized facts used by the CFG/DFG overlay. This is deliberately
// not a wire schema: the only public runtime contract is runtime_protocol.
const INTERNAL_FACTS_SCHEMA: &str = "fact-mine.normalized-runtime-facts";
#[cfg(test)]
const SCHEMA: &str = INTERNAL_FACTS_SCHEMA;
const RUNTIME_RECORD_ACCESSOR_SYMBOL_PREFIX: &str = "fact-mine-runtime runtime-contract v1 Record#";

fn runtime_record_accessor_symbol(member: &str) -> String {
    format!("{RUNTIME_RECORD_ACCESSOR_SYMBOL_PREFIX}{member}().")
}

pub(crate) fn is_runtime_record_accessor_symbol(symbol: &str, member: &str) -> bool {
    symbol == runtime_record_accessor_symbol(member)
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct RuntimeValueEvidence {
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
    /// Runtime dispatch facts whose exact normalized callsite is not known.
    ///
    /// A correlation group can still prove that a receiver type and selector
    /// dispatched to a particular semantic target even when a native tracer
    /// cannot distinguish two same-line source calls. FactMine may use that
    /// fact as a target catalog entry, but only its CFG/DFG may join it back
    /// to a normalized call.
    #[serde(default)]
    pub target_catalog: Vec<RuntimeTargetObservation>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct MethodLocator {
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
struct ValueScope {
    pub language: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub function: String,
    #[serde(default)]
    pub line: usize,
    /// FactMine-only exact binding. Runtime collectors never serialize
    /// normalized profile IDs.
    #[serde(skip)]
    pub method_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct SourceAnchor {
    pub path: String,
    pub line: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<[usize; 4]>,
    #[serde(default)]
    pub selector: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct ValueDomain {
    #[serde(default)]
    pub types: BTreeSet<String>,
    /// Exact identities of module/class/function singleton values. These are
    /// refinements of a nominal runtime type such as `Module`, not additional
    /// union alternatives.
    #[serde(default)]
    pub singletons: BTreeSet<String>,
    #[serde(default)]
    pub elements: BTreeSet<String>,
    #[serde(default)]
    pub keys: BTreeSet<String>,
    #[serde(default)]
    pub values: BTreeSet<String>,
    #[serde(default)]
    pub shapes: Vec<ValueShape>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct ValueShape {
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
    fn is_empty(&self) -> bool {
        self.types.is_empty()
            && self.singletons.is_empty()
            && self.elements.is_empty()
            && self.keys.is_empty()
            && self.values.is_empty()
            && self.shapes.is_empty()
    }

    fn validate(&self, context: &str) -> Result<()> {
        for value in self
            .types
            .iter()
            .chain(&self.singletons)
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
struct ValueObservation {
    pub kind: String,
    pub scope: ValueScope,
    #[serde(default)]
    pub slot: String,
    #[serde(default)]
    pub slot_kind: String,
    pub domain: ValueDomain,
    #[serde(default)]
    pub count: u64,
    /// FactMine-only exact state-access binding.
    #[serde(skip)]
    pub state_access_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct SemanticTarget {
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
struct ObservedCall {
    pub language: String,
    pub caller: MethodLocator,
    pub callsite: SourceAnchor,
    pub targets: Vec<SemanticTarget>,
    #[serde(default = "default_true")]
    pub target_observation_complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receiver_domain: Option<ValueDomain>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_domain: Option<ValueDomain>,
    /// Truth values observed for this call's result. This is intentionally a
    /// language-neutral runtime fact: providers decide whether a native value
    /// is Boolean, while FactMine joins it to normalized branch predicates.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub result_truths: BTreeSet<bool>,
    #[serde(default)]
    pub count: u64,
    /// FactMine-only exact call binding regenerated from the validated plan.
    #[serde(skip)]
    pub call_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
struct RuntimeTargetObservation {
    pub language: String,
    pub selector: String,
    pub targets: Vec<SemanticTarget>,
    pub receiver_domain: ValueDomain,
}

fn default_true() -> bool {
    true
}

impl RuntimeValueEvidence {
    #[cfg(test)]
    fn from_path(path: &Path) -> Result<Self> {
        let bytes = fs::read(path)
            .with_context(|| format!("failed to read runtime evidence {}", path.display()))?;
        let mut json = String::new();
        if bytes.starts_with(&[0x1f, 0x8b]) {
            GzDecoder::new(bytes.as_slice())
                .read_to_string(&mut json)
                .with_context(|| {
                    format!("failed to decompress runtime evidence {}", path.display())
                })?;
        } else {
            json = String::from_utf8(bytes).with_context(|| {
                format!("runtime evidence {} is not valid UTF-8", path.display())
            })?;
        }
        Self::from_json(&json)
            .with_context(|| format!("invalid runtime evidence {}", path.display()))
    }

    #[cfg(test)]
    fn from_json(json: &str) -> Result<Self> {
        let evidence: Self = serde_json::from_str(json)?;
        evidence.validate()?;
        Ok(evidence)
    }

    fn validate(&self) -> Result<()> {
        if self.schema != INTERNAL_FACTS_SCHEMA {
            bail!("invalid normalized runtime facts schema {:?}", self.schema);
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
            if call.targets.is_empty()
                && (call.target_observation_complete
                    || call
                        .receiver_domain
                        .as_ref()
                        .is_none_or(ValueDomain::is_empty)
                        && call
                            .result_domain
                            .as_ref()
                            .is_none_or(ValueDomain::is_empty)
                        && call.result_truths.is_empty())
            {
                bail!(
                    "calls[{index}] without targets requires an incomplete target observation and exact receiver/result evidence"
                );
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
        for (index, observation) in self.target_catalog.iter().enumerate() {
            if observation.language.is_empty() || observation.selector.is_empty() {
                bail!("target_catalog[{index}] requires a language and selector");
            }
            if observation.targets.is_empty() || observation.receiver_domain.is_empty() {
                bail!("target_catalog[{index}] requires targets and a receiver domain");
            }
            observation
                .receiver_domain
                .validate(&format!("target_catalog[{index}].receiver_domain"))?;
            for (target_index, target) in observation.targets.iter().enumerate() {
                if target.symbol.is_empty() || target.name.is_empty() {
                    bail!(
                        "target_catalog[{index}].targets[{target_index}] requires symbol and name"
                    );
                }
                if target.name != observation.selector {
                    bail!(
                        "target_catalog[{index}].targets[{target_index}] selector does not match"
                    );
                }
                if let Some(definition) = &target.definition {
                    validate_method(
                        definition,
                        &format!("target_catalog[{index}].targets[{target_index}].definition"),
                    )?;
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

/// Validate and overlay canonical runtime evidence through FactMine's exact
/// trace-plan bindings.
///
/// The collector supplies only SCIP-like source/value/target identities. This
/// conversion deliberately introduces normalized profile IDs *after*
/// validation, from the binding table FactMine regenerated from the current
/// source snapshot. No path/name/line fallback is available on this path.
pub fn apply_protocol_to_profile(
    output: &mut ProfileOutput,
    built: &BuiltTracePlan,
    evidence: &runtime_protocol::RuntimeEvidence,
) -> Result<RuntimeScipOverlay> {
    runtime_protocol::validate_runtime_evidence(&built.plan, evidence)?;
    let internal = protocol_evidence(output, built, evidence)?;
    apply_to_profile(output, &internal)
}

fn protocol_evidence(
    output: &ProfileOutput,
    built: &BuiltTracePlan,
    evidence: &runtime_protocol::RuntimeEvidence,
) -> Result<RuntimeValueEvidence> {
    let methods = output
        .methods
        .iter()
        .map(|method| (method.id.as_str(), method))
        .collect::<BTreeMap<_, _>>();
    let calls = output
        .calls
        .iter()
        .map(|call| (call.id.as_str(), call))
        .collect::<BTreeMap<_, _>>();
    let accesses = output
        .state_accesses
        .iter()
        .map(|access| (access.id.as_str(), access))
        .collect::<BTreeMap<_, _>>();
    let anchor_methods = built
        .bindings
        .iter()
        .filter_map(|(anchor, binding)| {
            let method_id = match binding {
                AnchorBinding::Parameter { method_id, .. }
                | AnchorBinding::Return { method_id } => method_id,
                AnchorBinding::Call { call_id } => &calls.get(call_id.as_str())?.source,
                AnchorBinding::State { access_id } => {
                    &accesses.get(access_id.as_str())?.function_id
                }
            };
            Some((anchor.as_str(), method_id.as_str()))
        })
        .collect::<BTreeMap<_, _>>();

    let mut internal = RuntimeValueEvidence {
        schema: INTERNAL_FACTS_SCHEMA.to_string(),
        authority: "modeled-runs".to_string(),
        environment: evidence
            .environment
            .iter()
            .map(|claim| (claim.key.clone(), claim.value.clone()))
            .collect(),
        runs: evidence.runs.iter().map(|run| run.id.clone()).collect(),
        ..RuntimeValueEvidence::default()
    };

    for row in &evidence.anchors {
        let Some(capture) = row.capture.as_ref() else {
            continue;
        };
        let complete = capture
            .complete_kinds
            .iter()
            .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
            .collect::<BTreeSet<_>>();
        if complete.is_empty() {
            continue;
        }
        let binding = built.bindings.get(&row.anchor_symbol).with_context(|| {
            format!(
                "validated anchor {:?} lacks a FactMine binding",
                row.anchor_symbol
            )
        })?;
        match binding {
            AnchorBinding::Parameter {
                method_id,
                ordinal: _,
                name,
            } => {
                if !complete.contains(&EvidenceKind::PARAMETER_VALUE.value()) {
                    continue;
                }
                let method = methods.get(method_id.as_str()).with_context(|| {
                    format!("parameter anchor refers to missing method {method_id:?}")
                })?;
                for bucket in &row.executions {
                    let value = bucket.value.as_ref().with_context(|| {
                        format!("parameter anchor {:?} lacks its value", row.anchor_symbol)
                    })?;
                    let domain = protocol_value_set_domain(value, &method.language)?;
                    if domain.is_empty() {
                        continue;
                    }
                    internal.observations.push(protocol_observation(
                        "parameter",
                        method,
                        name,
                        domain,
                        bucket.count,
                        Some(method_id.clone()),
                        None,
                    ));
                }
            }
            AnchorBinding::Return { method_id } => {
                if !complete.contains(&EvidenceKind::RETURN_VALUE.value()) {
                    continue;
                }
                let method = methods.get(method_id.as_str()).with_context(|| {
                    format!("return anchor refers to missing method {method_id:?}")
                })?;
                for bucket in &row.executions {
                    let value = bucket.value.as_ref().with_context(|| {
                        format!("return anchor {:?} lacks its value", row.anchor_symbol)
                    })?;
                    let domain = protocol_value_set_domain(value, &method.language)?;
                    if domain.is_empty() {
                        continue;
                    }
                    internal.observations.push(protocol_observation(
                        "return",
                        method,
                        "",
                        domain,
                        bucket.count,
                        Some(method_id.clone()),
                        None,
                    ));
                }
            }
            AnchorBinding::State { access_id } => {
                if !complete.contains(&EvidenceKind::STATE_VALUE.value()) {
                    continue;
                }
                let access = accesses.get(access_id.as_str()).with_context(|| {
                    format!("state anchor refers to missing access {access_id:?}")
                })?;
                let method = methods.get(access.function_id.as_str()).with_context(|| {
                    format!(
                        "state access refers to missing method {:?}",
                        access.function_id
                    )
                })?;
                for bucket in &row.executions {
                    let value = bucket.value.as_ref().with_context(|| {
                        format!("state anchor {:?} lacks its value", row.anchor_symbol)
                    })?;
                    let domain = protocol_value_set_domain(value, &method.language)?;
                    if domain.is_empty() {
                        continue;
                    }
                    internal.observations.push(protocol_observation(
                        "state",
                        method,
                        &access.field,
                        domain,
                        bucket.count,
                        Some(method.id.clone()),
                        Some(access_id.clone()),
                    ));
                }
            }
            AnchorBinding::Call { call_id } => {
                let call = calls
                    .get(call_id.as_str())
                    .with_context(|| format!("call anchor refers to missing call {call_id:?}"))?;
                let method = methods
                    .get(call.source.as_str())
                    .with_context(|| format!("call refers to missing method {:?}", call.source))?;
                for bucket in &row.executions {
                    if let Some(observation) = protocol_call_observation(
                        call,
                        method,
                        call_id,
                        bucket,
                        &complete,
                        &methods,
                        &built.bindings,
                        &anchor_methods,
                    )? {
                        internal.calls.push(observation);
                    }
                }
            }
        }
    }
    let method_index = MethodIndex::new(&output.methods);
    let points = flow_points(output, &method_index);
    let requests = built
        .plan
        .requests
        .iter()
        .filter_map(|request| {
            Some((
                request.anchor.as_ref()?.symbol.as_str(),
                request
                    .required
                    .iter()
                    .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
                    .collect::<BTreeSet<_>>(),
            ))
        })
        .collect::<BTreeMap<_, _>>();
    for correlation in &evidence.correlations {
        let Some(capture) = correlation.capture.as_ref() else {
            continue;
        };
        let complete = capture
            .complete_kinds
            .iter()
            .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
            .collect::<BTreeSet<_>>();
        let candidates = correlation
            .candidate_anchor_symbols
            .iter()
            .filter_map(|anchor| match built.bindings.get(anchor) {
                Some(AnchorBinding::Call { call_id }) => {
                    let call = calls.get(call_id.as_str()).copied()?;
                    let method = methods.get(call.source.as_str()).copied()?;
                    Some((anchor.as_str(), call_id, call, method))
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        if candidates.len() != correlation.candidate_anchor_symbols.len() {
            bail!(
                "validated correlation {:?} lacks an exact FactMine call binding",
                correlation.group_id
            );
        }
        for bucket in &correlation.executions {
            // Candidate ownership is intentionally unresolved here. The
            // receiver/selector/target dispatch fact itself is nevertheless
            // exact and can seed FactMine's generic target catalog. Only the
            // normalized CFG/DFG overlay below may connect this catalog fact
            // to one or more source calls.
            if complete.contains(&EvidenceKind::RECEIVER_VALUE.value())
                && complete.contains(&EvidenceKind::CALL_TARGET.value())
            {
                let (_, _, representative_call, representative_method) = candidates[0];
                if let (Some(receiver), Some(target)) =
                    (bucket.receiver.as_ref(), bucket.target.as_ref())
                {
                    let receiver_domain =
                        protocol_value_set_domain(receiver, &representative_method.language)?;
                    if !receiver_domain.is_empty() {
                        if let Some(target) = protocol_target(
                            target,
                            representative_call,
                            representative_method,
                            &methods,
                            &built.bindings,
                            &anchor_methods,
                            Some(receiver),
                        )? {
                            internal.target_catalog.push(RuntimeTargetObservation {
                                language: representative_method.language.clone(),
                                selector: representative_call.message.clone(),
                                targets: vec![target],
                                receiver_domain,
                            });
                        }
                    }
                }
            }
            let resolved = protocol_correlation_candidates(&candidates, bucket, &points)?;
            for (anchor, call_id, call, method) in resolved {
                let candidate_complete = complete
                    .intersection(requests.get(anchor).with_context(|| {
                        format!("correlation candidate {anchor:?} lacks a trace-plan request")
                    })?)
                    .copied()
                    .collect::<BTreeSet<_>>();
                if candidate_complete.is_empty() {
                    continue;
                }
                if let Some(observation) = protocol_call_observation(
                    call,
                    method,
                    call_id,
                    bucket,
                    &candidate_complete,
                    &methods,
                    &built.bindings,
                    &anchor_methods,
                )? {
                    internal.calls.push(observation);
                }
            }
        }
    }
    Ok(internal)
}

fn protocol_call_observation(
    call: &CallRecord,
    method: &MethodRecord,
    call_id: &str,
    bucket: &runtime_protocol::ExecutionBucket,
    complete: &BTreeSet<i32>,
    methods: &BTreeMap<&str, &MethodRecord>,
    bindings: &BTreeMap<String, AnchorBinding>,
    anchor_methods: &BTreeMap<&str, &str>,
) -> Result<Option<ObservedCall>> {
    let target = if complete.contains(&EvidenceKind::CALL_TARGET.value()) {
        bucket
            .target
            .as_ref()
            .map(|target| {
                protocol_target(
                    target,
                    call,
                    method,
                    methods,
                    bindings,
                    anchor_methods,
                    bucket.receiver.as_ref(),
                )
            })
            .transpose()?
            .flatten()
    } else {
        None
    };
    // A completely captured runtime target may still be unusable as a
    // production target (for example, a test double). Keep the receiver
    // evidence, but do not close production dispatch with the filtered target.
    let target_observation_complete = target.is_some();
    let receiver_domain = if complete.contains(&EvidenceKind::RECEIVER_VALUE.value())
        || complete.contains(&EvidenceKind::COLLECTION_VALUE.value())
    {
        bucket
            .receiver
            .as_ref()
            .map(|value| protocol_value_set_domain(value, &method.language))
            .transpose()?
            .filter(|domain| !domain.is_empty())
    } else {
        None
    };
    let result_domain = if complete.contains(&EvidenceKind::RESULT_VALUE.value()) {
        bucket
            .result
            .as_ref()
            .map(|value| protocol_value_set_domain(value, &method.language))
            .transpose()?
            .filter(|domain| !domain.is_empty())
    } else {
        None
    };
    let result_truths = if complete.contains(&EvidenceKind::BOOLEAN_RESULT.value()) {
        bucket.boolean_result.into_iter().collect()
    } else {
        BTreeSet::new()
    };
    // A canonical bucket can be complete for a requested field yet contain
    // no usable production fact after provenance filtering (for example, a
    // test-double target with no captured receiver/result). Preserve no
    // synthetic call row: the exact anchor remains represented by its
    // capture status, and an empty normalized row cannot inform CFG/DFG.
    if target.is_none()
        && receiver_domain.is_none()
        && result_domain.is_none()
        && result_truths.is_empty()
    {
        return Ok(None);
    }
    Ok(Some(ObservedCall {
        language: method.language.clone(),
        caller: method_locator(method),
        callsite: SourceAnchor {
            path: call.path.clone(),
            line: call.line,
            range: Some(call.span),
            selector: call.message.clone(),
        },
        targets: target.into_iter().collect(),
        target_observation_complete,
        receiver_domain,
        result_domain,
        result_truths,
        count: bucket.count,
        call_id: Some(call_id.to_string()),
    }))
}

fn protocol_correlation_candidates<'a>(
    candidates: &'a [(&str, &String, &'a CallRecord, &'a MethodRecord)],
    bucket: &runtime_protocol::ExecutionBucket,
    points: &[FlowPoint],
) -> Result<Vec<(&'a str, &'a String, &'a CallRecord, &'a MethodRecord)>> {
    if correlation_candidates_share_reaching_value(candidates, points) {
        return Ok(candidates.to_vec());
    }
    let Some(receiver) = bucket.receiver.as_ref() else {
        return Ok(Vec::new());
    };
    let observed = protocol_value_set_domain(receiver, &candidates[0].3.language)?;
    let mut compatible = Vec::new();
    for candidate in candidates {
        let source_type = candidate
            .2
            .receiver_type
            .as_deref()
            .or(candidate.2.receiver_symbol.as_deref());
        let Some(source_type) = source_type else {
            return Ok(Vec::new());
        };
        let domain = domain_from_type_source(source_type, &candidate.3.language);
        if domain.types.is_empty() {
            return Ok(Vec::new());
        }
        if !domain.types.is_disjoint(&observed.types) {
            compatible.push(*candidate);
        }
    }
    Ok((compatible.len() == 1)
        .then_some(compatible)
        .unwrap_or_default())
}

fn correlation_candidates_share_reaching_value(
    candidates: &[(&str, &String, &CallRecord, &MethodRecord)],
    points: &[FlowPoint],
) -> bool {
    correlation_calls_share_reaching_value(
        &candidates
            .iter()
            .map(|(_, _, call, _)| *call)
            .collect::<Vec<_>>(),
        points,
    )
}

fn correlation_calls_share_reaching_value(calls: &[&CallRecord], points: &[FlowPoint]) -> bool {
    let identities = calls
        .iter()
        .map(|call| {
            points
                .iter()
                .filter(|point| point.source == call.source && point.name == call.receiver)
                .filter(|point| {
                    span_contains(call.span, point.span) || span_contains(point.span, call.span)
                })
                .map(|point| {
                    (
                        point.place_id.clone(),
                        point
                            .reaching_definitions
                            .iter()
                            .cloned()
                            .collect::<BTreeSet<_>>(),
                    )
                })
                .collect::<BTreeSet<_>>()
        })
        .collect::<Vec<_>>();
    identities.first().is_some_and(|first| {
        !first.is_empty() && identities.iter().all(|identity| identity == first)
    })
}

fn protocol_observation(
    kind: &str,
    method: &MethodRecord,
    slot: &str,
    domain: ValueDomain,
    count: u64,
    method_id: Option<String>,
    state_access_id: Option<String>,
) -> ValueObservation {
    ValueObservation {
        kind: kind.to_string(),
        scope: ValueScope {
            language: method.language.clone(),
            path: method.path.clone(),
            owner: method.owner.clone(),
            function: method.name.clone(),
            line: method.line,
            method_id,
        },
        slot: slot.to_string(),
        slot_kind: String::new(),
        domain,
        count,
        state_access_id,
    }
}

fn method_locator(method: &MethodRecord) -> MethodLocator {
    MethodLocator {
        language: method.language.clone(),
        path: method.path.clone(),
        owner: method.owner.clone(),
        name: method.name.clone(),
        kind: method.kind.clone(),
        line: method.line,
    }
}

fn protocol_target(
    target: &runtime_protocol::RuntimeTarget,
    call: &CallRecord,
    caller: &MethodRecord,
    methods: &BTreeMap<&str, &MethodRecord>,
    bindings: &BTreeMap<String, AnchorBinding>,
    anchor_methods: &BTreeMap<&str, &str>,
    receiver: Option<&runtime_protocol::ValueSet>,
) -> Result<Option<SemanticTarget>> {
    if target.source_role.enum_value_or_default() == runtime_protocol::SourceRole::NON_PRODUCTION {
        return Ok(None);
    }
    let definition_method = target.definition.as_ref().and_then(|definition| {
        (!definition.anchor_symbol.is_empty())
            .then(|| {
                anchor_methods
                    .get(definition.anchor_symbol.as_str())
                    .copied()
            })
            .flatten()
            .or_else(|| {
                bindings
                    .get(&definition.anchor_symbol)
                    .and_then(|binding| match binding {
                        AnchorBinding::Parameter { method_id, .. }
                        | AnchorBinding::Return { method_id } => Some(method_id.as_str()),
                        _ => None,
                    })
            })
            .and_then(|method_id| methods.get(method_id).copied())
            .or_else(|| protocol_definition_method(definition, methods))
    });
    let receiver_type = receiver
        .map(|value| protocol_value_set_domain(value, &caller.language))
        .transpose()?
        .and_then(|domain| {
            let language = crate::syntax::Language::parse(&caller.language).ok()?;
            let behavior = crate::syntax::normalized_behavior::behavior(language);
            behavior.runtime_value_domain_type(
                &domain.types.into_iter().collect::<Vec<_>>(),
                &domain.elements.into_iter().collect::<Vec<_>>(),
                &domain.keys.into_iter().collect::<Vec<_>>(),
                &domain.values.into_iter().collect::<Vec<_>>(),
            )
        })
        .unwrap_or_default();
    Ok(Some(SemanticTarget {
        symbol: target.symbol.clone(),
        owner: definition_method
            .map(|method| method.owner.clone())
            .unwrap_or_default(),
        name: call.message.clone(),
        kind: definition_method
            .map(|method| method.kind.clone())
            .unwrap_or_else(|| {
                if call.receiver_kind == "type" {
                    "class".to_string()
                } else {
                    "instance".to_string()
                }
            }),
        receiver_type,
        definition: definition_method.map(method_locator),
    }))
}

fn protocol_definition_method<'a>(
    definition: &runtime_protocol::RuntimeDefinition,
    methods: &'a BTreeMap<&str, &MethodRecord>,
) -> Option<&'a MethodRecord> {
    if definition.relative_path.is_empty() {
        return None;
    }
    let relative = definition.relative_path.replace('\\', "/");
    let line = definition.range.as_ref()?.start_line as usize + 1;
    let candidates = methods
        .values()
        .copied()
        .filter(|method| {
            let path = method.path.replace('\\', "/");
            (path == relative || path.ends_with(&format!("/{relative}")))
                && (method.line == line
                    || method
                        .span
                        .is_some_and(|span| span[0] <= line && line <= span[2]))
        })
        .collect::<Vec<_>>();
    if candidates.len() == 1 {
        candidates.into_iter().next()
    } else {
        None
    }
}

fn protocol_runtime_type(value: &runtime_protocol::RuntimeValue, language: &str) -> Result<String> {
    let language = crate::syntax::Language::parse(language)?;
    let behavior = crate::syntax::normalized_behavior::behavior(language);
    behavior
        .runtime_value_type_from_symbol(&value.type_symbol)
        .with_context(|| {
            format!(
                "{language:?} runtime adapter cannot decode type SCIP symbol {:?}",
                value.type_symbol
            )
        })
}

fn protocol_value_domain(
    value: &runtime_protocol::RuntimeValue,
    language: &str,
) -> Result<ValueDomain> {
    let owner = protocol_runtime_type(value, language)?;
    let mut domain = ValueDomain {
        types: BTreeSet::from([owner.clone()]),
        singletons: if value.singleton_symbol.is_empty() {
            BTreeSet::new()
        } else {
            let language = crate::syntax::Language::parse(language)?;
            let behavior = crate::syntax::normalized_behavior::behavior(language);
            BTreeSet::from([behavior
                .runtime_value_singleton_from_symbol(&value.singleton_symbol)
                .with_context(|| {
                    format!(
                        "{language:?} runtime adapter cannot decode singleton SCIP symbol {:?}",
                        value.singleton_symbol
                    )
                })?])
        },
        ..ValueDomain::default()
    };
    match value.shape.as_ref() {
        Some(runtime_value::Shape::Sequence(shape)) => {
            merge_protocol_value_set(&mut domain.elements, shape.elements.as_ref(), language)?;
            domain.shapes.push(ValueShape {
                kind: "array".to_string(),
                elements: protocol_value_set_shapes(shape.elements.as_ref(), language)?,
                ..ValueShape::default()
            });
        }
        Some(runtime_value::Shape::Mapping(shape)) => {
            let mut keys = Vec::new();
            let mut values = Vec::new();
            for entry in &shape.entries {
                if let Some(key) = entry.key.as_ref() {
                    domain.keys.insert(protocol_runtime_type(key, language)?);
                    keys.push(protocol_value_shape(key, language)?);
                }
                if let Some(value) = entry.value.as_ref() {
                    domain
                        .values
                        .insert(protocol_runtime_type(value, language)?);
                    values.push(protocol_value_shape(value, language)?);
                }
            }
            keys.sort();
            keys.dedup();
            values.sort();
            values.dedup();
            domain.shapes.push(ValueShape {
                kind: "hash".to_string(),
                keys,
                values,
                ..ValueShape::default()
            });
        }
        Some(runtime_value::Shape::Record(shape)) => {
            let mut members = BTreeMap::new();
            for member in &shape.members {
                let alternatives = protocol_value_set_shapes(member.values.as_ref(), language)?;
                members.insert(
                    member.name.clone(),
                    alternatives.into_iter().next().unwrap_or(ValueShape {
                        kind: "unknown".to_string(),
                        ..ValueShape::default()
                    }),
                );
            }
            domain.shapes.push(ValueShape {
                kind: "record".to_string(),
                name: owner,
                members,
                ..ValueShape::default()
            });
        }
        Some(runtime_value::Shape::Tuple(shape)) => {
            let elements = shape
                .elements
                .iter()
                .flat_map(|set| protocol_value_set_shapes(Some(set), language))
                .flatten()
                .collect();
            domain.shapes.push(ValueShape {
                kind: "tuple".to_string(),
                elements,
                ..ValueShape::default()
            });
        }
        None => {}
    }
    Ok(domain)
}

fn protocol_value_set_domain(
    values: &runtime_protocol::ValueSet,
    language: &str,
) -> Result<ValueDomain> {
    let mut domain = ValueDomain::default();
    for alternative in &values.alternatives {
        let value = alternative
            .value
            .as_ref()
            .context("validated runtime value alternative is missing")?;
        if value.source_role.enum_value_or_default() == runtime_protocol::SourceRole::NON_PRODUCTION
        {
            continue;
        }
        merge_domain(&mut domain, &protocol_value_domain(value, language)?);
    }
    Ok(domain)
}

fn merge_protocol_value_set(
    destination: &mut BTreeSet<String>,
    values: Option<&runtime_protocol::ValueSet>,
    language: &str,
) -> Result<()> {
    for weighted in values.into_iter().flat_map(|set| &set.alternatives) {
        if let Some(value) = weighted.value.as_ref() {
            if value.source_role.enum_value_or_default()
                == runtime_protocol::SourceRole::NON_PRODUCTION
            {
                continue;
            }
            destination.insert(protocol_runtime_type(value, language)?);
        }
    }
    Ok(())
}

fn protocol_value_set_shapes(
    values: Option<&runtime_protocol::ValueSet>,
    language: &str,
) -> Result<Vec<ValueShape>> {
    values
        .into_iter()
        .flat_map(|set| &set.alternatives)
        .filter_map(|weighted| weighted.value.as_ref())
        .filter(|value| {
            value.source_role.enum_value_or_default()
                != runtime_protocol::SourceRole::NON_PRODUCTION
        })
        .map(|value| protocol_value_shape(value, language))
        .collect()
}

fn protocol_value_shape(
    value: &runtime_protocol::RuntimeValue,
    language: &str,
) -> Result<ValueShape> {
    let name = protocol_runtime_type(value, language)?;
    Ok(match value.shape.as_ref() {
        Some(runtime_value::Shape::Sequence(shape)) => ValueShape {
            kind: "array".to_string(),
            name,
            elements: protocol_value_set_shapes(shape.elements.as_ref(), language)?,
            ..ValueShape::default()
        },
        Some(runtime_value::Shape::Mapping(shape)) => {
            let mut keys = shape
                .entries
                .iter()
                .filter_map(|entry| entry.key.as_ref())
                .map(|key| protocol_value_shape(key, language))
                .collect::<Result<Vec<_>>>()?;
            let mut values = shape
                .entries
                .iter()
                .filter_map(|entry| entry.value.as_ref())
                .map(|value| protocol_value_shape(value, language))
                .collect::<Result<Vec<_>>>()?;
            keys.sort();
            keys.dedup();
            values.sort();
            values.dedup();
            ValueShape {
                kind: "hash".to_string(),
                name,
                keys,
                values,
                ..ValueShape::default()
            }
        }
        Some(runtime_value::Shape::Record(shape)) => {
            let mut members = BTreeMap::new();
            for member in &shape.members {
                let alternatives = protocol_value_set_shapes(member.values.as_ref(), language)?;
                members.insert(
                    member.name.clone(),
                    alternatives.into_iter().next().unwrap_or(ValueShape {
                        kind: "unknown".to_string(),
                        ..ValueShape::default()
                    }),
                );
            }
            ValueShape {
                kind: "record".to_string(),
                name,
                members,
                ..ValueShape::default()
            }
        }
        Some(runtime_value::Shape::Tuple(shape)) => ValueShape {
            kind: "tuple".to_string(),
            name,
            elements: shape
                .elements
                .iter()
                .flat_map(|set| protocol_value_set_shapes(Some(set), language))
                .flatten()
                .collect(),
            ..ValueShape::default()
        },
        None => ValueShape {
            kind: "class".to_string(),
            name,
            ..ValueShape::default()
        },
    })
}

/// Overlay runtime observations on FactMine's normalized source/CFG/DFG facts
/// and emit the resulting identities as an ordinary runtime-authority SCIP
/// index. All propagation in this function operates on normalized facts; it
/// never parses a source-language expression.
fn apply_to_profile(
    output: &mut ProfileOutput,
    evidence: &RuntimeValueEvidence,
) -> Result<RuntimeScipOverlay> {
    evidence.validate()?;
    let method_index = MethodIndex::new(&output.methods);
    let call_index = CallIndex::new(&output.calls);
    let return_domains = observed_return_domains(evidence, &method_index);
    let mut receiver_domains =
        observed_receiver_domains(output, &call_index, evidence, &method_index);
    seed_fact_mine_receiver_domains(output, &method_index, &mut receiver_domains);
    let (exact_receiver_domains, exact_result_domains) =
        matched_observed_value_domains(&call_index, evidence, &method_index);
    for (call_id, domain) in exact_receiver_domains {
        merge_domain(receiver_domains.entry(call_id).or_default(), &domain);
    }
    let observed = match_observed_calls(&call_index, evidence, &method_index);
    let flow = flow_points(output, &method_index);
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
            &flow,
            &return_domains,
            &exact_result_domains,
            &selected,
            &mut receiver_domains,
        );
        let capability_narrowed =
            runtime_capability_narrowed_domains(
                output,
                &call_index,
                evidence,
                &method_index,
                &receiver_domains,
            );
        let narrowed_receiver_domains =
            runtime_truthiness_narrowed_domains(output, &method_index, &capability_narrowed);
        infer_runtime_receiver_targets(
            output,
            &method_index,
            &narrowed_receiver_domains,
            &mut selected,
        );
        infer_targets(
            output,
            &method_index,
            &catalog,
            &narrowed_receiver_domains,
            &mut selected,
        );
        infer_runtime_stdlib_targets(
            output,
            evidence,
            &method_index,
            &narrowed_receiver_domains,
            &mut selected,
        );
        if receiver_domains == before_domains && selected == before_selected {
            break;
        }
    }
    let capability_narrowed = runtime_capability_narrowed_domains(
        output,
        &call_index,
        evidence,
        &method_index,
        &receiver_domains,
    );
    let narrowed_receiver_domains =
        runtime_truthiness_narrowed_domains(output, &method_index, &capability_narrowed);
    infer_runtime_record_accessors(output, &narrowed_receiver_domains, &mut selected);
    let mut stats = OverlayStats {
        observed_call_sites: observed.len(),
        inferred_call_sites: selected
            .keys()
            .filter(|id| !observed.contains_key(*id))
            .count(),
        ..OverlayStats::default()
    };
    for call in &mut output.calls {
        call.runtime_evidence_observed |= observed.contains_key(&call.id);
        let Some(domain) = narrowed_receiver_domains.get(&call.id) else {
            continue;
        };
        if call.receiver_type.is_none() && domain.types.len() == 1 {
            call.receiver_type = domain.types.iter().next().cloned();
            call.receiver_type_origin = Some("runtime_value_evidence_cfg_dfg".to_string());
            stats.typed_receivers += 1;
        }
    }

    let index = build_scip_index(
        output,
        evidence,
        &observed,
        &selected,
        &method_index,
        &mut stats,
    )?;
    if !selected.is_empty() {
        crate::scip::apply_json(output, &serde_json::to_string(&index)?)?;
    }
    Ok(RuntimeScipOverlay { index, stats })
}

/// A `record` value-shape is a tracer-owned structural observation. When every
/// observed receiver alternative is a record exposing the same member, emit an
/// ordinary synthetic SCIP target for that constant-time accessor. The target
/// is intentionally language-neutral: language providers only serialize the
/// observed shape, while FactMine owns the join to a normalized call and the
/// portable SCIP export.
fn infer_runtime_record_accessors(
    output: &ProfileOutput,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    selected: &mut BTreeMap<String, Vec<SemanticTarget>>,
) {
    for call in &output.calls {
        if call.target.is_some() || selected.contains_key(&call.id) {
            continue;
        }
        let Some(domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        if !runtime_record_domain_exposes(domain, &call.message) {
            continue;
        }
        selected.insert(
            call.id.clone(),
            vec![runtime_record_accessor_target(&call.message)],
        );
    }
}

/// Return true only when every observed runtime type is represented by one or
/// more record shapes, and that member occurs on every such shape. This keeps
/// a heterogeneous observed domain closed and avoids treating an unshaped
/// dynamic receiver as a record merely because another receiver was one.
fn runtime_record_domain_exposes(domain: &ValueDomain, member: &str) -> bool {
    if domain.types.is_empty() {
        return false;
    }
    domain
        .types
        .iter()
        .all(|runtime_type| runtime_record_type_exposes(domain, runtime_type, member))
}

fn runtime_record_type_exposes(domain: &ValueDomain, runtime_type: &str, member: &str) -> bool {
    let shapes = domain
        .shapes
        .iter()
        .filter(|shape| shape.kind == "record" && shape.name == runtime_type)
        .collect::<Vec<_>>();
    !shapes.is_empty()
        && shapes
            .iter()
            .all(|shape| shape.members.contains_key(member))
}

/// What a flow node holds, keyed by (method, CFG node, place). The key borrows
/// from the flow points rather than owning three copies of each string.
type FlowNodeDomains<'p> = HashMap<(&'p str, &'p str, &'p str), ValueDomain>;

/// Whether `qualified` names `suffix` nested inside some enclosing scope --
/// what `qualified.ends_with(&format!("::{suffix}"))` said, without the
/// allocation it charged for every method compared.
fn nested_under(qualified: &str, suffix: &str) -> bool {
    qualified.len() >= suffix.len() + 2
        && qualified.ends_with(suffix)
        && qualified.as_bytes()[qualified.len() - suffix.len() - 2..][..2] == *b"::"
}

/// The calls, grouped by the keys every join actually uses. Each join used to
/// rescan the whole call list, so a corpus cost `calls * observations` where
/// `calls + observations` is enough.
struct CallIndex<'a> {
    by_id: HashMap<&'a str, Vec<&'a CallRecord>>,
    by_source: HashMap<&'a str, Vec<&'a CallRecord>>,
    by_message: HashMap<&'a str, Vec<&'a CallRecord>>,
}

impl<'a> CallIndex<'a> {
    fn new(calls: &'a [CallRecord]) -> Self {
        let mut by_id: HashMap<&'a str, Vec<&'a CallRecord>> = HashMap::new();
        let mut by_source: HashMap<&'a str, Vec<&'a CallRecord>> = HashMap::new();
        let mut by_message: HashMap<&'a str, Vec<&'a CallRecord>> = HashMap::new();
        for call in calls {
            by_id.entry(call.id.as_str()).or_default().push(call);
            by_source.entry(call.source.as_str()).or_default().push(call);
            by_message.entry(call.message.as_str()).or_default().push(call);
        }
        Self { by_id, by_source, by_message }
    }

    fn with_id(&self, id: &str) -> &[&'a CallRecord] {
        self.by_id.get(id).map_or(&[][..], Vec::as_slice)
    }

    fn from_source(&self, source: &str) -> &[&'a CallRecord] {
        self.by_source.get(source).map_or(&[][..], Vec::as_slice)
    }

    fn with_message(&self, message: &str) -> &[&'a CallRecord] {
        self.by_message.get(message).map_or(&[][..], Vec::as_slice)
    }
}

struct MethodIndex<'a> {
    methods: &'a [MethodRecord],
    by_id: BTreeMap<&'a str, &'a MethodRecord>,
    // Both spellings a locator may arrive under, so a lookup by name does not
    // have to walk every method in the corpus.
    by_name: HashMap<&'a str, Vec<&'a MethodRecord>>,
}

impl<'a> MethodIndex<'a> {
    fn new(methods: &'a [MethodRecord]) -> Self {
        Self {
            methods,
            by_id: methods
                .iter()
                .map(|method| (method.id.as_str(), method))
                .collect(),
            by_name: {
                let mut by_name: HashMap<&'a str, Vec<&'a MethodRecord>> = HashMap::new();
                for method in methods {
                    by_name.entry(method.name.as_str()).or_default().push(method);
                    if method.dispatch_name != method.name {
                        by_name
                            .entry(method.dispatch_name.as_str())
                            .or_default()
                            .push(method);
                    }
                }
                by_name
            },
        }
    }

    /// Every method spelled `name`, in corpus order. Each method is filed
    /// under its source spelling and, when they differ, its dispatch selector,
    /// so no bucket repeats a method.
    fn named(&self, name: &str) -> &[&'a MethodRecord] {
        self.by_name.get(name).map_or(&[][..], Vec::as_slice)
    }

    fn locate(&self, locator: &MethodLocator) -> Vec<&'a MethodRecord> {
        let named = self.named(&locator.name);
        let scoped = named
            .iter()
            .copied()
            .filter(|method| method.language == locator.language)
            // A method record preserves its source spelling for reporting
            // (`self.render` in Ruby, qualified declarations in other
            // languages), while runtime tracers report the dispatch selector
            // (`render`).  `dispatch_name` is the language-normalized bridge
            // between those two representations; retain `name` for sources
            // that already use the selector spelling.
            .filter(|method| method.name == locator.name || method.dispatch_name == locator.name)
            .filter(|method| locator.line == 0 || method.line == locator.line)
            .filter(|method| {
                locator.owner.is_empty()
                    || method.owner == locator.owner
                    || nested_under(&method.owner, &locator.owner)
                    || nested_under(&locator.owner, &method.owner)
            })
            .filter(|method| path_matches(&method.path, &locator.path))
            .collect::<Vec<_>>();
        if !scoped.is_empty() {
            return scoped;
        }
        let unscoped = named
            .iter()
            .copied()
            .filter(|method| method.language == locator.language)
            .filter(|method| method.name == locator.name || method.dispatch_name == locator.name)
            .filter(|method| locator.line == 0 || method.line == locator.line)
            .filter(|method| path_matches(&method.path, &locator.path))
            .collect::<Vec<_>>();
        (unscoped.len() == 1)
            .then_some(unscoped)
            .unwrap_or_default()
    }

    fn locate_scope(&self, scope: &ValueScope) -> Vec<&'a MethodRecord> {
        if let Some(method_id) = scope.method_id.as_deref() {
            return self.by_id.get(method_id).copied().into_iter().collect();
        }
        let candidates = if scope.function.is_empty() {
            self.methods.iter().collect::<Vec<_>>()
        } else {
            self.named(&scope.function).to_vec()
        };
        candidates
            .into_iter()
            .filter(|method| method.language == scope.language)
            .filter(|method| scope.line == 0 || method.line == scope.line)
            .filter(|method| {
                scope.owner.is_empty()
                    || method.owner == scope.owner
                    || nested_under(&method.owner, &scope.owner)
                    || nested_under(&scope.owner, &method.owner)
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
            .or_else(|| {
                matches!(call.receiver.as_str(), "" | "self" | "this")
                    .then_some(method.owner.as_str())
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
    definition_call_sources: BTreeMap<String, Vec<[usize; 4]>>,
    definition_sequence_projections: BTreeMap<String, usize>,
    callback_binding_position: Option<usize>,
    static_domain: ValueDomain,
    span: [usize; 4],
}

fn propagate_cfg_dfg_domains(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
    points: &[FlowPoint],
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &mut BTreeMap<String, ValueDomain>,
) {
    if points.is_empty() {
        return;
    }
    let mut node_domains = FlowNodeDomains::new();
    for point in points {
        if !point.static_domain.is_empty() {
            merge_domain(
                node_domains
                    .entry((
                        point.source.as_str(),
                        point.node_id.as_str(),
                        point.place_id.as_str(),
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
                                point.source.as_str(),
                                definition.as_str(),
                                point.place_id.as_str(),
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
    seed_flow_nodes_from_calls(output, points, receiver_domains, &mut node_domains);

    // A normalized iteration relation binds collection value domains to block
    // locals. The source-language adapter decides whether a call is an
    // iteration; this layer only projects the already-normalized relation.
    seed_collection_callback_nodes(
        output,
        methods,
        points,
        receiver_domains,
        &mut node_domains,
    );
    seed_call_result_definitions(
        output,
        methods,
        points,
        return_domains,
        exact_result_domains,
        selected,
        receiver_domains,
        &mut node_domains,
    );

    loop {
        let mut changed = false;
        for point in points {
            let reaching = point
                .reaching_definitions
                .iter()
                .filter_map(|definition| {
                    node_domains.get(&(
                        point.source.as_str(),
                        definition.as_str(),
                        point.place_id.as_str(),
                    ))
                })
                .collect::<Vec<_>>();
            if let Some(domain) = joined_domain(&reaching) {
                changed |= merge_domain(
                    node_domains
                        .entry((
                            point.source.as_str(),
                            point.node_id.as_str(),
                            point.place_id.as_str(),
                        ))
                        .or_default(),
                    &domain,
                );
            }
        }
        if !changed {
            break;
        }
    }

    let mut points_by_slot: HashMap<(&str, &str), Vec<&FlowPoint>> = HashMap::new();
    for point in points {
        points_by_slot
            .entry((point.source.as_str(), point.name.as_str()))
            .or_default()
            .push(point);
    }
    for call in &output.calls {
        let domains = points_by_slot
            .get(&(call.source.as_str(), call.receiver.as_str()))
            .map_or(&[][..], Vec::as_slice)
            .iter()
            .filter(|point| span_contains_line(point.span, call.line))
            .filter_map(|point| {
                node_domains.get(&(
                    point.source.as_str(),
                    point.node_id.as_str(),
                    point.place_id.as_str(),
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
            let reaching_definitions = flow["reaching_definitions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>();
            let definition_sequence_projections =
                serde_json::from_value::<BTreeMap<String, usize>>(
                    flow["definition_sequence_projections"].clone(),
                )
                .unwrap_or_default();
            let mut static_domain = ValueDomain::default();
            for value in flow["resolved_types"].as_array().into_iter().flatten() {
                if let Ok(value) = serde_json::from_value::<TypeExpr>(value.clone()) {
                    merge_domain(
                        &mut static_domain,
                        &domain_from_type_expr_source_language(&value, &method.language),
                    );
                }
            }
            if static_domain.is_empty() {
                for hint in flow["types"].as_array().into_iter().flatten() {
                    if let Some(hint) = hint.as_str() {
                        merge_domain(
                            &mut static_domain,
                            &domain_from_type_source(hint, &method.language),
                        );
                    }
                }
            }
            let projections = reaching_definitions
                .iter()
                .filter_map(|definition| definition_sequence_projections.get(definition))
                .copied()
                .collect::<BTreeSet<_>>();
            if !reaching_definitions.is_empty()
                && definition_sequence_projections.len() == reaching_definitions.len()
                && projections.len() == 1
            {
                static_domain = sequence_position_domain(
                    &static_domain,
                    *projections.iter().next().expect("one sequence projection"),
                );
            }
            Some(FlowPoint {
                source: method.id.clone(),
                name: name.to_string(),
                node_id: node_id.to_string(),
                place_id: place_id.to_string(),
                reaching_definitions,
                definition_call_sources: serde_json::from_value(
                    flow["definition_call_sources"].clone(),
                )
                .unwrap_or_default(),
                definition_sequence_projections,
                callback_binding_position: flow["callback_binding_position"]
                    .as_u64()
                    .map(|position| position as usize),
                static_domain,
                span,
            })
        })
        .collect()
}

fn seed_flow_nodes_from_calls<'p>(
    output: &ProfileOutput,
    points: &'p [FlowPoint],
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut FlowNodeDomains<'p>,
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
                        point.source.as_str(),
                        point.node_id.as_str(),
                        point.place_id.as_str(),
                    ))
                    .or_default(),
                domain,
            );
        }
    }
}

fn seed_collection_callback_nodes<'p>(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    points: &'p [FlowPoint],
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut FlowNodeDomains<'p>,
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
        let static_receiver_type = call
            .receiver_type
            .as_deref()
            .map(|value| TypeExpr::parse(value, &method.language));
        // An untyped source parameter frequently becomes a concrete runtime
        // collection only after observation. Ask the language adapter about
        // that normalized runtime identity before deciding whether its block
        // binds collection values; otherwise an `each` call can never seed
        // its callback local merely because the source declaration was open.
        let runtime_receiver_type = behavior.runtime_value_domain_type(
            &receiver_domain.types.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.elements.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.keys.iter().cloned().collect::<Vec<_>>(),
            &receiver_domain.values.iter().cloned().collect::<Vec<_>>(),
        );
        let receiver_type = runtime_receiver_type
            .as_deref()
            .map(|value| TypeExpr::parse(value, &method.language))
            .or(static_receiver_type);
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
        let nested_iteration_spans = iteration_span
            .map(|outer| {
                normalized_iteration_spans(output, method)
                    .into_iter()
                    .filter(|inner| *inner != outer && span_contains(outer, *inner))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let mut callback_points = points
            .iter()
            .filter(|point| {
                point.source == call.source
                    && point.name != call.receiver
                    && point.callback_binding_position.is_some()
                    && iteration_span
                        .map(|span| {
                            span_contains(span, point.span)
                                && !nested_iteration_spans
                                    .iter()
                                    .any(|nested| span_contains(*nested, point.span))
                        })
                        .unwrap_or(point.span[0] == call.line)
            })
            .collect::<Vec<_>>();
        callback_points.sort_by_key(|point| point.callback_binding_position);
        if callback_points.is_empty() {
            continue;
        }
        let projections = behavior.runtime_collection_callback_projections(
            runtime_receiver_type.as_deref(),
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
                        point.source.as_str(),
                        point.node_id.as_str(),
                        point.place_id.as_str(),
                    ))
                    .or_default(),
                &callback_domain,
            );
            // A callback parameter is a fresh definition for its normalized
            // callback region. Compound CFG nodes can contain multiple
            // chained callbacks, so seed same-named uses in this exact region
            // instead of conflating sibling bindings through one place.
            for use_point in points.iter().filter(|use_point| {
                use_point.source == point.source
                    && use_point.name == point.name
                    && span_contains(point.span, use_point.span)
                    && !points.iter().any(|shadow| {
                        shadow.source == point.source
                            && shadow.name == point.name
                            && shadow.callback_binding_position.is_some()
                            && shadow.span != point.span
                            && span_contains(point.span, shadow.span)
                            && span_contains(shadow.span, use_point.span)
                    })
            }) {
                merge_domain(
                    node_domains
                        .entry((
                            use_point.source.as_str(),
                            use_point.node_id.as_str(),
                            use_point.place_id.as_str(),
                        ))
                        .or_default(),
                    &callback_domain,
                );
            }
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

fn normalized_iteration_spans(output: &ProfileOutput, method: &MethodRecord) -> Vec<[usize; 4]> {
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
        .map(|iteration| iteration.span)
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn seed_call_result_definitions<'p>(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    points: &'p [FlowPoint],
    return_domains: &BTreeMap<String, ValueDomain>,
    exact_result_domains: &BTreeMap<String, ValueDomain>,
    selected: &BTreeMap<String, Vec<SemanticTarget>>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    node_domains: &mut FlowNodeDomains<'p>,
) {
    let calls = output
        .calls
        .iter()
        .map(|call| ((call.source.as_str(), call.span), call))
        .collect::<BTreeMap<_, _>>();
    for point in points {
        for (definition, spans) in &point.definition_call_sources {
            let domains = spans
                .iter()
                .filter_map(|span| {
                    let call = calls.get(&(point.source.as_str(), *span)).copied()?;
                    call_result_domain(
                        call,
                        methods,
                        return_domains,
                        exact_result_domains,
                        selected,
                        receiver_domains,
                    )
                })
                .collect::<Vec<_>>();
            // A producer set is sound only if every value-producing branch
            // is resolved. Joining a known branch with an unknown one would
            // silently erase a dynamic alternative.
            if spans.is_empty() || domains.len() != spans.len() {
                continue;
            }
            let domain_refs = domains.iter().collect::<Vec<_>>();
            let Some(domain) = joined_domain(&domain_refs) else {
                continue;
            };
            let domain = point
                .definition_sequence_projections
                .get(definition)
                .map(|position| sequence_position_domain(&domain, *position))
                .unwrap_or(domain);
            if domain.is_empty() {
                continue;
            }
            merge_domain(
                node_domains
                    .entry((
                        point.source.as_str(),
                        definition.as_str(),
                        point.place_id.as_str(),
                    ))
                    .or_default(),
                &domain,
            );
        }
    }
}

fn sequence_position_domain(sequence: &ValueDomain, position: usize) -> ValueDomain {
    let mut projected = collection_element_domain(sequence);
    for shape in &sequence.shapes {
        if shape.kind != "tuple" {
            continue;
        }
        let Some(element) = shape.elements.get(position) else {
            continue;
        };
        merge_domain(&mut projected, &value_shape_domain(element));
    }
    projected
}

fn value_shape_domain(shape: &ValueShape) -> ValueDomain {
    let mut domain = ValueDomain::default();
    if !shape.name.is_empty() {
        domain.types.insert(shape.name.clone());
    }
    domain.shapes.push(shape.clone());
    domain
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

    let method = methods.by_id.get(call.source.as_str())?;
    let language = crate::syntax::Language::parse(&method.language).ok()?;
    let behavior = crate::syntax::normalized_behavior::behavior(language);
    let Some(receiver_domain) = receiver_domains.get(&call.id) else {
        let result_type = behavior
            .static_return_type(&call.message, None)
            .or_else(|| behavior.known_return_type(&call.message))?;
        let domain = domain_from_type_source(&result_type, &method.language);
        return (!domain.is_empty()).then_some(domain);
    };
    if selected.get(&call.id).is_some_and(|targets| {
        !targets.is_empty()
            && targets.iter().all(|target| {
                is_runtime_record_accessor_symbol(&target.symbol, &call.message)
                    || runtime_target_is_generated_accessor(target, &call.message, methods)
            })
    }) {
        if let Some(domain) = runtime_record_accessor_result_domain(receiver_domain, &call.message)
        {
            return Some(domain);
        }
    }
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

fn runtime_target_is_generated_accessor(
    target: &SemanticTarget,
    message: &str,
    methods: &MethodIndex<'_>,
) -> bool {
    let Some(definition) = &target.definition else {
        return false;
    };
    let candidates = methods.locate(definition);
    !candidates.is_empty()
        && candidates.iter().all(|method| {
            method.generated_declaration
                && (method.name == message || method.dispatch_name == message)
        })
}

// Generated readers are not universally observable as runtime call events
// (Ruby Struct readers are one example). A record shape already proves both
// the member's existence and the value observed in that slot, so use that
// evidence to continue the generic CFG/DFG value flow after the synthetic
// constant-time accessor target has been selected. The join is deliberately
// closed: every runtime alternative must be a record exposing this member.
fn runtime_record_accessor_result_domain(
    receiver: &ValueDomain,
    member: &str,
) -> Option<ValueDomain> {
    if !runtime_record_domain_exposes(receiver, member) {
        return None;
    }
    let domains = receiver
        .types
        .iter()
        .flat_map(|runtime_type| {
            receiver
                .shapes
                .iter()
                .filter(move |shape| shape.kind == "record" && shape.name == *runtime_type)
                .filter_map(|shape| shape.members.get(member))
                .map(value_domain_from_shape)
        })
        .collect::<Vec<_>>();
    (!domains.is_empty()).then(|| joined_domain(&domains.iter().collect::<Vec<_>>()))?
}

fn value_domain_from_shape(shape: &ValueShape) -> ValueDomain {
    let mut domain = ValueDomain::default();
    match shape.kind.as_str() {
        "class" => {
            if !shape.name.is_empty() {
                domain.types.insert(shape.name.clone());
            }
        }
        "record" => {
            if !shape.name.is_empty() {
                domain.types.insert(shape.name.clone());
                domain.shapes.push(shape.clone());
            }
        }
        "array" | "set" => {
            domain.types.insert(if shape.kind == "array" {
                "Array".to_string()
            } else {
                "Set".to_string()
            });
            for element in &shape.elements {
                let child = value_domain_from_shape(element);
                domain.elements.extend(child.types);
            }
            domain.shapes.push(shape.clone());
        }
        "hash" => {
            domain.types.insert("Hash".to_string());
            for key in &shape.keys {
                domain.keys.extend(value_domain_from_shape(key).types);
            }
            for value in &shape.values {
                domain.values.extend(value_domain_from_shape(value).types);
            }
            domain.shapes.push(shape.clone());
        }
        "tuple" | "unknown" | _ => {}
    }
    domain
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
            shapes: receiver
                .shapes
                .iter()
                .flat_map(|shape| shape.values.iter().cloned())
                .collect(),
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
    calls: &CallIndex<'_>,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> BTreeMap<String, ValueDomain> {
    let mut domains = BTreeMap::new();
    for observation in &evidence.observations {
        match observation.kind.as_str() {
            "parameter" => {
                for method in methods.locate_scope(&observation.scope) {
                    seed_method_slot(
                        calls,
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
                        calls,
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
                            calls,
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
                            || nested_under(&call.owner, &observation.scope.owner))
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
    calls: &CallIndex<'_>,
    method: &MethodRecord,
    slot: &str,
    domain: &ValueDomain,
    domains: &mut BTreeMap<String, ValueDomain>,
) {
    for call in calls
        .from_source(&method.id)
        .iter()
        .filter(|call| call.receiver == slot)
    {
        merge_domain(domains.entry(call.id.clone()).or_default(), domain);
    }
}

fn match_observed_calls(
    calls: &CallIndex<'_>,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> BTreeMap<String, Vec<SemanticTarget>> {
    let mut selected = BTreeMap::<String, Vec<SemanticTarget>>::new();
    for observed in &evidence.calls {
        if observed.targets.is_empty() {
            continue;
        }
        for call in matched_profile_calls(calls, methods, observed) {
            let entry = selected.entry(call.id.clone()).or_default();
            entry.extend(observed.targets.clone());
            sort_dedup_targets(entry);
        }
    }
    selected
}

fn matched_observed_value_domains(
    calls: &CallIndex<'_>,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
) -> (BTreeMap<String, ValueDomain>, BTreeMap<String, ValueDomain>) {
    let mut receivers = BTreeMap::<String, ValueDomain>::new();
    let mut results = BTreeMap::<String, ValueDomain>::new();
    for observed in &evidence.calls {
        for call in matched_profile_calls(calls, methods, observed) {
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

/// Narrow a runtime receiver domain only where a normalized capability guard
/// and a tracer-observed Boolean result jointly prove the branch alternative.
/// The evidence is partitioned by observed receiver type, so a dynamic type
/// that produced both results stays unclassified rather than being guessed.
fn runtime_capability_narrowed_domains(
    output: &ProfileOutput,
    calls: &CallIndex<'_>,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
) -> BTreeMap<String, ValueDomain> {
    let mut domains = receiver_domains.clone();
    for guard in &output.runtime_capability_guards {
        let mut present = BTreeSet::new();
        let mut absent = BTreeSet::new();
        for observed in &evidence.calls {
            if observed.result_truths.len() != 1 {
                continue;
            }
            if !matched_profile_calls(calls, methods, observed)
                .iter()
                .any(|call| call.id == guard.condition_call_id)
            {
                continue;
            }
            let Some(receiver_domain) = observed.receiver_domain.as_ref() else {
                continue;
            };
            let truth = *observed.result_truths.iter().next().expect("single truth");
            let destination = if truth { &mut present } else { &mut absent };
            destination.extend(receiver_domain.types.iter().cloned());
        }
        if present.is_empty() && absent.is_empty() {
            continue;
        }
        for call in output
            .calls
            .iter()
            .filter(|call| call.source == guard.source && call.receiver == guard.subject)
        {
            let allowed = if guard
                .member_available_span
                .is_some_and(|span| span_contains(span, call.span))
            {
                &present
            } else if guard
                .member_unavailable_span
                .is_some_and(|span| span_contains(span, call.span))
            {
                &absent
            } else {
                continue;
            };
            let Some(domain) = domains.get_mut(&call.id) else {
                continue;
            };
            // Every observed alternative must have one unambiguous predicate
            // result. Otherwise a type may be state-dependent and filtering
            // it would turn a runtime sample into an unsound closed world.
            if domain.types.is_empty()
                || !domain
                    .types
                    .iter()
                    .all(|ty| present.contains(ty) ^ absent.contains(ty))
            {
                continue;
            }
            domain.types.retain(|ty| allowed.contains(ty));
            domain.shapes.retain(|shape| {
                shape.kind != "record" || shape.name.is_empty() || allowed.contains(&shape.name)
            });
        }
    }
    domains
}

/// Apply a language-adapter truthiness fact only when the same CFG reaching
/// definitions flow from the condition into the guarded call. That prevents a
/// later assignment in the branch from inheriting the old value's runtime
/// type, while allowing a tracer-observed `NilClass | Record` result to close
/// a record reader on the branch where Ruby has proved the value truthy.
fn runtime_truthiness_narrowed_domains(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
) -> BTreeMap<String, ValueDomain> {
    let mut domains = receiver_domains.clone();
    let points = flow_points(output, methods);
    for guard in &output.runtime_truthiness_guards {
        let guard_definitions = points
            .iter()
            .filter(|point| {
                point.source == guard.source
                    && point.name == guard.subject
                    && span_contains(point.span, guard.condition_span)
            })
            .map(|point| {
                point
                    .reaching_definitions
                    .iter()
                    .cloned()
                    .collect::<BTreeSet<_>>()
            })
            .filter(|definitions| !definitions.is_empty())
            .collect::<BTreeSet<_>>();
        if guard_definitions.is_empty() {
            continue;
        }
        let Some(truthy_span) = guard.truthy_span else {
            continue;
        };
        for call in output.calls.iter().filter(|call| {
            call.source == guard.source
                && call.receiver == guard.subject
                && span_contains(truthy_span, call.span)
        }) {
            let same_definition = points.iter().any(|point| {
                point.source == call.source
                    && point.name == call.receiver
                    && span_contains(point.span, call.span)
                    && guard_definitions.contains(
                        &point
                            .reaching_definitions
                            .iter()
                            .cloned()
                            .collect::<BTreeSet<_>>(),
                    )
            });
            if !same_definition {
                continue;
            }
            let Some(domain) = domains.get_mut(&call.id) else {
                continue;
            };
            let truthy_types = domain
                .types
                .iter()
                .filter(|ty| ty.as_str() != "NilClass" && ty.as_str() != "FalseClass")
                .cloned()
                .collect::<BTreeSet<_>>();
            if truthy_types.is_empty() {
                continue;
            }
            domain.types = truthy_types.clone();
            domain.shapes.retain(|shape| {
                shape.kind != "record"
                    || shape.name.is_empty()
                    || truthy_types.contains(&shape.name)
            });
        }
    }
    domains
}

fn matched_profile_calls<'a>(
    calls: &CallIndex<'a>,
    methods: &MethodIndex<'_>,
    observed: &ObservedCall,
) -> Vec<&'a CallRecord> {
    if let Some(call_id) = observed.call_id.as_deref() {
        return calls.with_id(call_id).to_vec();
    }
    let mut candidates = methods
        .locate(&observed.caller)
        .into_iter()
        .flat_map(|caller| calls.from_source(&caller.id).iter().copied())
        .filter(|call| call.message == observed.callsite.selector)
        .filter(|call| path_matches(&call.path, &observed.callsite.path))
        .collect::<Vec<_>>();
    if let Some(range) = observed.callsite.range {
        candidates.retain(|call| zero_based(call.span) == range);
    } else {
        // A caller match alone is not enough: native/runtime implementation
        // frames can report a selector at the active source line even when
        // that selector is not spelled there. Joining it to another call in
        // the same method (which merely shares the selector) corrupts the
        // CFG/DFG value domain. Keep the runtime source anchor exact; the
        // source-anchor fallback below handles genuinely synthetic callers.
        candidates.retain(|call| call.line == observed.callsite.line);
    }
    if !candidates.is_empty() {
        return candidates;
    }

    // Runtime tracers necessarily see implementation frames. A callback can
    // therefore execute under a synthetic/native frame (`Kernel#tap` in Ruby
    // is one example) even though its source anchor still points at the
    // lexical application call. The source anchor is an exact observation;
    // recover it only after the method-locator match failed, and retain a
    // statically-known receiver when it conflicts with the observed runtime
    // domain. This is generic CFG/DFG joining, not a language-specific stack
    // heuristic.
    let mut fallback = calls
        .with_message(&observed.callsite.selector)
        .iter()
        .copied()
        .filter(|call| path_matches(&call.path, &observed.callsite.path))
        .collect::<Vec<_>>();
    if let Some(range) = observed.callsite.range {
        fallback.retain(|call| zero_based(call.span) == range);
    } else {
        fallback.retain(|call| call.line == observed.callsite.line);
    }
    fallback.retain(|call| runtime_receiver_domain_compatible(call, methods, observed));
    fallback
}

fn runtime_receiver_domain_compatible(
    call: &CallRecord,
    methods: &MethodIndex<'_>,
    observed: &ObservedCall,
) -> bool {
    let observed_types = observed
        .receiver_domain
        .as_ref()
        .map(|domain| domain.types.clone())
        .filter(|types| !types.is_empty())
        .unwrap_or_else(|| {
            observed
                .targets
                .iter()
                .filter_map(|target| {
                    (!target.receiver_type.is_empty()).then(|| target.receiver_type.clone())
                })
                .collect()
        });
    if observed_types.is_empty() {
        return true;
    }
    let Some(method) = methods.by_id.get(call.source.as_str()) else {
        return false;
    };
    let Some(static_type) = call
        .receiver_type
        .as_deref()
        .or(call.receiver_symbol.as_deref())
    else {
        return true;
    };
    let static_domain = domain_from_type_source(static_type, &method.language);
    static_domain.types.is_empty() || !static_domain.types.is_disjoint(&observed_types)
}

#[derive(Clone)]
struct CatalogTarget {
    target: SemanticTarget,
    receiver_domain: Option<ValueDomain>,
}

fn target_catalog(evidence: &RuntimeValueEvidence) -> BTreeMap<String, Vec<CatalogTarget>> {
    let mut catalog = BTreeMap::<String, Vec<CatalogTarget>>::new();
    for call in &evidence.calls {
        let entry = catalog.entry(call.callsite.selector.clone()).or_default();
        entry.extend(call.targets.iter().cloned().map(|target| CatalogTarget {
            target,
            receiver_domain: call.receiver_domain.clone(),
        }));
        entry.sort_by(|left, right| {
            left.target
                .symbol
                .cmp(&right.target.symbol)
                .then_with(|| left.receiver_domain.cmp(&right.receiver_domain))
        });
        entry.dedup_by(|left, right| {
            left.target == right.target && left.receiver_domain == right.receiver_domain
        });
    }
    for observation in &evidence.target_catalog {
        let entry = catalog.entry(observation.selector.clone()).or_default();
        entry.extend(
            observation
                .targets
                .iter()
                .cloned()
                .map(|target| CatalogTarget {
                    target,
                    receiver_domain: Some(observation.receiver_domain.clone()),
                }),
        );
        entry.sort_by(|left, right| {
            left.target
                .symbol
                .cmp(&right.target.symbol)
                .then_with(|| left.receiver_domain.cmp(&right.receiver_domain))
        });
        entry.dedup_by(|left, right| {
            left.target == right.target && left.receiver_domain == right.receiver_domain
        });
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
        if let Some(mut domain) = joined_domain(&domains) {
            if let Some(position) = call.receiver_definition_sequence_projection {
                domain = sequence_position_domain(&domain, position);
            }
            if domain.is_empty() {
                continue;
            }
            merge_domain(
                receiver_domains.entry(call.id.clone()).or_default(),
                &domain,
            );
        }
    }
}

fn infer_targets(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    catalog: &BTreeMap<String, Vec<CatalogTarget>>,
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
                call.receiver_kind != "type"
                    || target.target.kind == "class"
                    || target.target.kind == "static"
            })
            .cloned()
            .collect::<Vec<_>>();
        let Some(domain) = receiver_domains.get(&call.id) else {
            let owners = catalog_candidates
                .iter()
                .filter_map(|target| {
                    (!target.target.owner.is_empty())
                        .then_some(target.target.owner.as_str())
                        .or_else(|| {
                            (!target.target.receiver_type.is_empty())
                                .then_some(target.target.receiver_type.as_str())
                        })
                })
                .collect::<BTreeSet<_>>();
            if owners.len() == 1 && !catalog_candidates.is_empty() {
                selected.insert(
                    call.id.clone(),
                    catalog_candidates
                        .into_iter()
                        .map(|candidate| candidate.target)
                        .collect(),
                );
            }
            continue;
        };
        let behavior = methods
            .by_id
            .get(call.source.as_str())
            .and_then(|method| crate::syntax::Language::parse(&method.language).ok())
            .map(crate::syntax::normalized_behavior::behavior);
        let identities = if domain.singletons.is_empty() {
            domain
                .types
                .iter()
                .map(|identity| (identity.as_str(), false))
                .collect::<Vec<_>>()
        } else {
            domain
                .singletons
                .iter()
                .map(|identity| (identity.as_str(), true))
                .collect::<Vec<_>>()
        };
        let mut candidates = Vec::new();
        let mut closed = !identities.is_empty();
        for (identity, singleton) in identities {
            let mut matching = catalog_candidates
                .iter()
                .filter(|candidate| {
                    if singleton {
                        return candidate
                            .receiver_domain
                            .as_ref()
                            .is_some_and(|observed| observed.singletons.contains(identity));
                    }
                    runtime_owner_matches(&candidate.target.receiver_type, identity)
                        || runtime_owner_matches(&candidate.target.owner, identity)
                        || behavior.is_some_and(|behavior| {
                            behavior
                                .runtime_dispatch_owner_matches(&candidate.target.owner, identity)
                        })
                        || candidate
                            .receiver_domain
                            .as_ref()
                            .is_some_and(|observed| observed.types.contains(identity))
                })
                .map(|candidate| candidate.target.clone())
                .collect::<Vec<_>>();
            if matching.is_empty()
                && !singleton
                && runtime_record_type_exposes(domain, identity, &call.message)
            {
                matching.push(runtime_record_accessor_target(&call.message));
            }
            if matching.is_empty() {
                closed = false;
                break;
            }
            candidates.extend(matching);
        }
        if closed {
            sort_dedup_targets(&mut candidates);
            selected.insert(call.id.clone(), candidates);
        }
    }
}

// A runtime type observation is enough to connect a normalized receiver call
// to a source declaration already extracted by FactMine.  This is deliberately
// language-neutral: adapters own emitted method facts and tracers own runtime
// type identities; the join only requires exact normalized owner/name/kind
// agreement.  It notably covers generated source declarations (Ruby
// `attr_reader`, Kotlin properties, and similar compiler-visible accessors)
// that a VM callback tracer may not report as ordinary calls.
fn infer_runtime_receiver_targets(
    output: &ProfileOutput,
    methods: &MethodIndex<'_>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    selected: &mut BTreeMap<String, Vec<SemanticTarget>>,
) {
    for call in &output.calls {
        if selected.contains_key(&call.id) || call.target.is_some() {
            continue;
        }
        let Some(domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        if domain.types.is_empty() && domain.singletons.is_empty() {
            continue;
        }
        let Some(caller) = methods.by_id.get(call.source.as_str()) else {
            continue;
        };
        let mut targets = Vec::new();
        let mut closed = true;
        let runtime_identities = if domain.singletons.is_empty() {
            domain
                .types
                .iter()
                .map(|identity| (identity, false))
                .collect::<Vec<_>>()
        } else {
            domain
                .singletons
                .iter()
                .map(|identity| (identity, true))
                .collect::<Vec<_>>()
        };
        for (runtime_type, singleton) in runtime_identities {
            let mut type_targets = methods
                .methods
                .iter()
                .filter(|method| method.language == caller.language)
                .filter(|method| {
                    method.name == call.message || method.dispatch_name == call.message
                })
                .filter(|method| runtime_owner_matches(&method.owner, runtime_type))
                .filter(|method| {
                    if singleton {
                        matches!(method.kind.as_str(), "class" | "static")
                    } else {
                        project_method_kind_matches_call(method, call)
                    }
                })
                .map(runtime_project_semantic_target)
                .collect::<Vec<_>>();
            // A language-neutral `record` shape is a second closed target
            // form. A heterogeneous runtime union is complete when every
            // alternative proves this selector, even if some alternatives use
            // generated project readers and others are runtime records.
            if type_targets.is_empty()
                && runtime_record_type_exposes(domain, runtime_type, &call.message)
            {
                type_targets.push(runtime_record_accessor_target(&call.message));
            }
            if type_targets.is_empty() {
                closed = false;
                break;
            }
            targets.extend(type_targets);
        }
        if closed && !targets.is_empty() {
            sort_dedup_targets(&mut targets);
            selected.insert(call.id.clone(), targets);
        }
    }
}

fn infer_runtime_stdlib_targets(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    methods: &MethodIndex<'_>,
    receiver_domains: &BTreeMap<String, ValueDomain>,
    selected: &mut BTreeMap<String, Vec<SemanticTarget>>,
) {
    for call in &output.calls {
        if selected.contains_key(&call.id) || call.target.is_some() {
            continue;
        }
        let Some(domain) = receiver_domains.get(&call.id) else {
            continue;
        };
        let Some(method) = methods.by_id.get(call.source.as_str()) else {
            continue;
        };
        let Ok(language) = crate::syntax::Language::parse(&method.language) else {
            continue;
        };
        let behavior = crate::syntax::normalized_behavior::behavior(language);
        let identities = if domain.singletons.is_empty() {
            domain
                .types
                .iter()
                .map(|receiver_type| (receiver_type.as_str(), None))
                .collect::<Vec<_>>()
        } else {
            domain
                .singletons
                .iter()
                .map(|singleton| {
                    let receiver_type = domain
                        .types
                        .iter()
                        .next()
                        .map(String::as_str)
                        .unwrap_or("T.untyped");
                    (receiver_type, Some(singleton.as_str()))
                })
                .collect::<Vec<_>>()
        };
        if identities.is_empty() {
            continue;
        }
        let targets = identities
            .into_iter()
            .map(|(receiver_type, singleton)| {
                behavior.runtime_value_semantic_target(
                    receiver_type,
                    singleton,
                    &call.message,
                    &evidence.environment,
                )
            })
            .collect::<Option<Vec<_>>>();
        let Some(targets) = targets else {
            continue;
        };
        let mut targets = targets
            .into_iter()
            .map(|target| SemanticTarget {
                symbol: target.symbol,
                owner: target.owner,
                name: call.message.clone(),
                kind: target.kind,
                receiver_type: target.receiver_type,
                definition: None,
            })
            .collect::<Vec<_>>();
        sort_dedup_targets(&mut targets);
        selected.insert(call.id.clone(), targets);
    }
}

fn runtime_record_accessor_target(member: &str) -> SemanticTarget {
    SemanticTarget {
        symbol: runtime_record_accessor_symbol(member),
        owner: "Record".to_string(),
        name: member.to_string(),
        kind: "instance".to_string(),
        receiver_type: "Record".to_string(),
        definition: None,
    }
}

fn project_method_kind_matches_call(method: &MethodRecord, call: &CallRecord) -> bool {
    if call.receiver_kind == "type" {
        matches!(method.kind.as_str(), "class" | "static")
    } else {
        !matches!(method.kind.as_str(), "class" | "static")
    }
}

fn runtime_project_semantic_target(method: &MethodRecord) -> SemanticTarget {
    SemanticTarget {
        // Use a FactMine-owned, method-id keyed symbol when the source did
        // not provide compiler SCIP.  Both the definition and reference are
        // emitted in the same runtime overlay, so SCIP's normal exact-symbol
        // join—not a path or short-name heuristic—remains the authority.
        symbol: method
            .semantic_symbol
            .clone()
            .unwrap_or_else(|| runtime_project_method_symbol(&method.id)),
        owner: method.owner.clone(),
        name: method.name.clone(),
        kind: method.kind.clone(),
        receiver_type: method.owner.clone(),
        definition: Some(MethodLocator {
            language: method.language.clone(),
            path: method.path.clone(),
            owner: method.owner.clone(),
            name: method.name.clone(),
            kind: method.kind.clone(),
            line: method.line,
        }),
    }
}

fn runtime_project_method_symbol(method_id: &str) -> String {
    format!(
        "fact-mine-runtime runtime-project v1 Method#`{}`().",
        method_id.replace('`', "``")
    )
}

fn build_scip_index(
    output: &ProfileOutput,
    evidence: &RuntimeValueEvidence,
    observed: &BTreeMap<String, Vec<SemanticTarget>>,
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
    // An observed runtime target can be weaker than an exact static project
    // target, in which case the consumer correctly retains the static target.
    // Preserve the independently useful coverage provenance nonetheless so
    // downstream diagnostics do not misclassify that source callsite as
    // unexecuted. These anchors are emitted only after the generic normalized
    // caller/callsite join above, never directly from tracer frames.
    let observed_call_sites = observed
        .keys()
        .filter_map(|call_id| calls.get(call_id.as_str()).copied())
        .map(|call| {
            json!({
                "relativePath": normalized_document_path(&call.path),
                "range": compact_range(zero_based(call.span))
            })
        })
        .collect::<Vec<_>>();

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
            "observedCallsiteAnchors": observed_call_sites,
            "inferredCallSites": stats.inferred_call_sites,
            "typedReceivers": stats.typed_receivers,
            "emittedOccurrences": stats.emitted_occurrences
        }
    }))
}

fn selector_range(call: &CallRecord) -> Option<[usize; 4]> {
    if let Some(span) = call.selector_span {
        return Some(zero_based(span));
    }
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

/// Path comparison treats the two separators as one. Every join filter runs
/// through here, so it reads the bytes in place rather than building four
/// normalized copies per comparison.
fn separator_normalized(byte: u8) -> u8 {
    if byte == b'\\' {
        b'/'
    } else {
        byte
    }
}

fn path_bytes_eq(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .all(|(left, right)| separator_normalized(*left) == separator_normalized(*right))
}

/// Whether `whole` ends with a separator followed by `tail`.
fn path_ends_with_segment(whole: &[u8], tail: &[u8]) -> bool {
    whole.len() > tail.len()
        && separator_normalized(whole[whole.len() - tail.len() - 1]) == b'/'
        && path_bytes_eq(&whole[whole.len() - tail.len()..], tail)
}

fn path_matches(left: &str, right: &str) -> bool {
    let (left, right) = (left.as_bytes(), right.as_bytes());
    path_bytes_eq(left, right)
        || path_ends_with_segment(left, right)
        || path_ends_with_segment(right, left)
}

fn runtime_owner_matches(observed: &str, expected: &str) -> bool {
    !observed.is_empty()
        && !expected.is_empty()
        && (observed == expected
            || nested_under(observed, expected)
            || nested_under(expected, observed))
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

/// Reports whether the target grew. A merge only ever adds alternatives, so
/// counting them is an exact change test -- which lets a fixpoint stop on "no
/// alternative was added" instead of cloning and comparing the whole map on
/// every round.
fn merge_domain(target: &mut ValueDomain, source: &ValueDomain) -> bool {
    let before = target.types.len()
        + target.singletons.len()
        + target.elements.len()
        + target.keys.len()
        + target.values.len()
        + target.shapes.len();
    target.types.extend(source.types.iter().cloned());
    target.singletons.extend(source.singletons.iter().cloned());
    target.elements.extend(source.elements.iter().cloned());
    target.keys.extend(source.keys.iter().cloned());
    target.values.extend(source.values.iter().cloned());
    for shape in &source.shapes {
        if !target.shapes.contains(shape) {
            target.shapes.push(shape.clone());
        }
    }
    before
        != target.types.len()
            + target.singletons.len()
            + target.elements.len()
            + target.keys.len()
            + target.values.len()
            + target.shapes.len()
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
    use protobuf::{EnumOrUnknown, MessageField};
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn canonical_protocol_preserves_nested_collection_shapes() {
        let runtime_value = |name: &str| runtime_protocol::RuntimeValue {
            type_symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {name}#"),
            ..runtime_protocol::RuntimeValue::default()
        };
        let integer = runtime_value("Integer");
        let mut nested_array = runtime_value("Array");
        nested_array.shape = Some(runtime_value::Shape::Sequence(
            runtime_protocol::SequenceShape {
                elements: MessageField::some(runtime_protocol::ValueSet {
                    alternatives: vec![runtime_protocol::WeightedValue {
                        value: MessageField::some(integer),
                        count: 1,
                        ..runtime_protocol::WeightedValue::default()
                    }],
                    ..runtime_protocol::ValueSet::default()
                }),
                ..runtime_protocol::SequenceShape::default()
            },
        ));
        let mut hash = runtime_value("Hash");
        hash.shape = Some(runtime_value::Shape::Mapping(
            runtime_protocol::MappingShape {
                entries: vec![runtime_protocol::MappingEntry {
                    key: MessageField::some(runtime_value("String")),
                    value: MessageField::some(nested_array),
                    count: 1,
                    ..runtime_protocol::MappingEntry::default()
                }],
                ..runtime_protocol::MappingShape::default()
            },
        ));
        let mut outer = runtime_value("Array");
        outer.shape = Some(runtime_value::Shape::Sequence(
            runtime_protocol::SequenceShape {
                elements: MessageField::some(runtime_protocol::ValueSet {
                    alternatives: vec![runtime_protocol::WeightedValue {
                        value: MessageField::some(hash),
                        count: 1,
                        ..runtime_protocol::WeightedValue::default()
                    }],
                    ..runtime_protocol::ValueSet::default()
                }),
                ..runtime_protocol::SequenceShape::default()
            },
        ));

        let domain = protocol_value_domain(&outer, "ruby").expect("canonical value domain");
        let outer_shape = domain.shapes.first().expect("outer sequence");
        let hash_shape = outer_shape.elements.first().expect("hash element");
        let value_shape = hash_shape.values.first().expect("hash value");
        let integer_shape = value_shape.elements.first().expect("nested array element");

        assert_eq!(outer_shape.kind, "array");
        assert_eq!(hash_shape.kind, "hash");
        assert_eq!(hash_shape.keys[0].name, "String");
        assert_eq!(value_shape.kind, "array");
        assert_eq!(integer_shape.name, "Integer");
    }

    #[test]
    fn canonical_protocol_excludes_nonproduction_runtime_values_from_inference() {
        let runtime_value = |name: &str, source_role| runtime_protocol::RuntimeValue {
            type_symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {name}#"),
            source_role: EnumOrUnknown::new(source_role),
            ..runtime_protocol::RuntimeValue::default()
        };
        let values = runtime_protocol::ValueSet {
            alternatives: vec![
                runtime_protocol::WeightedValue {
                    value: MessageField::some(runtime_value(
                        "ProductionRow",
                        runtime_protocol::SourceRole::PRODUCTION,
                    )),
                    count: 1,
                    ..runtime_protocol::WeightedValue::default()
                },
                runtime_protocol::WeightedValue {
                    value: MessageField::some(runtime_value(
                        "TestDouble",
                        runtime_protocol::SourceRole::NON_PRODUCTION,
                    )),
                    count: 1,
                    ..runtime_protocol::WeightedValue::default()
                },
            ],
            ..runtime_protocol::ValueSet::default()
        };

        let domain = protocol_value_set_domain(&values, "ruby").expect("runtime value domain");
        assert_eq!(domain.types, BTreeSet::from(["ProductionRow".to_string()]));
        assert_eq!(
            protocol_value_set_shapes(Some(&values), "ruby")
                .expect("runtime value shapes")
                .into_iter()
                .map(|shape| shape.name)
                .collect::<Vec<_>>(),
            vec!["ProductionRow"]
        );
    }

    #[test]
    fn canonical_workspace_definition_locator_binds_an_out_of_plan_method() {
        let directory = tempfile::tempdir().expect("directory");
        let helper = directory.path().join("helper.rb");
        std::fs::write(
            &helper,
            "module Helper\n  def self.size\n    1\n  end\nend\n",
        )
        .expect("helper source");
        let document = syntax::parse_file(helper.clone(), Language::Ruby).expect("parse helper");
        let profile = profile::extract(&document, Profile::Espalier);
        let methods = profile
            .methods
            .iter()
            .map(|method| (method.id.as_str(), method))
            .collect::<BTreeMap<_, _>>();
        let expected = profile
            .methods
            .iter()
            .find(|method| method.dispatch_name == "size")
            .expect("helper method");
        let definition = runtime_protocol::RuntimeDefinition {
            symbol: "nil-kill-runtime workspace fixture workspace Helper.size().".to_string(),
            relative_path: "helper.rb".to_string(),
            range: MessageField::some(runtime_protocol::SourceRange {
                start_line: (expected.line - 1) as u32,
                end_line: (expected.line - 1) as u32,
                ..runtime_protocol::SourceRange::default()
            }),
            ..runtime_protocol::RuntimeDefinition::default()
        };

        assert_eq!(
            protocol_definition_method(&definition, &methods).map(|method| method.id.as_str()),
            Some(expected.id.as_str())
        );

        let missing = runtime_protocol::RuntimeDefinition {
            relative_path: "missing.rb".to_string(),
            range: definition.range.clone(),
            ..runtime_protocol::RuntimeDefinition::default()
        };
        assert!(protocol_definition_method(&missing, &methods).is_none());
    }

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
    fn reads_gzip_runtime_evidence_emitted_by_default_collects() {
        let file = tempfile::Builder::new()
            .suffix(".json.gz")
            .tempfile()
            .expect("compressed evidence");
        let mut encoder = flate2::write::GzEncoder::new(
            file.reopen().expect("writer"),
            flate2::Compression::fast(),
        );
        encoder
            .write_all(valid_evidence().to_string().as_bytes())
            .expect("write evidence");
        encoder.finish().expect("finish gzip");

        let evidence = RuntimeValueEvidence::from_path(file.path()).expect("read gzip evidence");
        assert_eq!(evidence.authority, "runtime-modeled-world");
        assert_eq!(evidence.calls[0].targets[0].owner, "Row");
    }

    #[test]
    fn cfg_dfg_overlay_exports_shared_runtime_record_accessors_as_portable_scip() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def label(value)
    value.kind
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
                        "owner": "Worker", "function": "label", "line": 2
                    },
                    "slot": "value",
                    "domain": {
                        "types": ["NamedRecord", "T.untyped"],
                        "shapes": [
                            {"kind": "record", "name": "NamedRecord", "members": {"kind": {"kind": "unknown"}}},
                            {"kind": "record", "name": "T.untyped", "members": {"kind": {"kind": "unknown"}}}
                        ]
                    },
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        let overlay = apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "label" && call.message == "kind")
            .expect("record accessor");
        assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#kind().")
        );
        assert_eq!(
            accessor.complexity_provenance.as_deref(),
            Some("runtime_scip_modeled:conservative_external_candidate_max")
        );
        assert_eq!(overlay.stats.inferred_call_sites, 1);
        assert!(overlay.index.to_string().contains("Record#kind"));
    }

    #[test]
    fn cfg_dfg_overlay_projects_container_record_shapes_into_ruby_callback_values() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def labels(rows)
    rows.map { |row| row.kind }
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
                        "owner": "Worker", "function": "labels", "line": 2
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Array"],
                        "elements": ["ObservedRow"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "ObservedRow",
                                "members": {"kind": {"kind": "unknown"}}
                            }]
                        }]
                    },
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "labels" && call.message == "kind")
            .expect("record accessor");
        assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_projects_observed_iterator_receiver_shapes_into_ruby_callbacks() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def labels(rows)
    rows.each do |row|
      row.kind.upcase
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
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "labels",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "each"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Array#each().",
                        "owner": "Array", "name": "each", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {
                        "types": ["Array"], "elements": ["ObservedRow"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "ObservedRow",
                                "members": {"kind": {"kind": "class", "name": "String"}}
                            }]
                        }]
                    },
                    "count": 1
                }, {
                    // Ruby's C-backed `sort_by` may internally enumerate the
                    // receiver. TracePoint attributes that native `each` to
                    // the active source line even though no `each` call is
                    // spelled there. It must not be joined to the earlier
                    // source `rows.each` merely because the selector matches.
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "labels",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 4, "selector": "each"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Array#each().",
                        "owner": "Array", "name": "each", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {
                        "types": ["Array"], "elements": ["UnrelatedRow"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "UnrelatedRow",
                                "members": {"other": {"kind": "class", "name": "String"}}
                            }]
                        }]
                    },
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "labels" && call.message == "kind")
            .expect("record accessor");
        assert_eq!(accessor.receiver_type.as_deref(), Some("ObservedRow"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#kind().")
        );
        let upcase = output
            .calls
            .iter()
            .find(|call| call.function == "labels" && call.message == "upcase")
            .expect("record member operation");
        assert_eq!(upcase.receiver_type.as_deref(), Some("String"));
    }

    #[test]
    fn cfg_dfg_overlay_joins_runtime_receiver_types_to_generated_project_methods() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class BranchArm
  attr_reader :kind
end

class Worker
  def labels(rows)
    rows.map { |row| row.kind }
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
                        "owner": "Worker", "function": "labels", "line": 6
                    },
                    "slot": "rows",
                    "domain": {"types": ["Array"], "elements": ["BranchArm"]},
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "labels" && call.message == "kind")
            .expect("generated accessor");
        assert!(accessor.target.is_some());
        assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        assert_eq!(
            accessor.complexity_provenance.as_deref(),
            Some("generated_callable_declaration")
        );
    }

    #[test]
    fn cfg_dfg_overlay_closes_mixed_generated_and_record_receiver_domains() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class BranchArm
  attr_reader :kind
end

class Worker
  def labels(rows)
    rows.map { |row| row.kind }
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
                        "owner": "Worker", "function": "labels", "line": 6
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Array"], "elements": ["BranchArm", "ObservedArm"],
                        "shapes": [{"kind": "array", "elements": [{
                            "kind": "record", "name": "ObservedArm",
                            "members": {"kind": {"kind": "unknown"}}
                        }]}]
                    },
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "labels" && call.message == "kind")
            .expect("mixed accessor");
        assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        assert_eq!(
            accessor.complexity_provenance.as_deref(),
            Some("runtime_scip_modeled:mixed_project_external_candidate_max+generated_accessor")
        );
        assert!(accessor.consumer_closed_candidate_set);
        assert!(accessor.target.is_none());
        assert!(!accessor.candidate_targets.is_empty());
    }

    #[test]
    fn cfg_dfg_overlay_narrows_runtime_record_domains_through_capability_guards() {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("source");
        file.write_all(
            br#"class Worker
  def label(arm)
    arm.respond_to?(:detail) ? arm.detail : arm.fallback
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        assert_eq!(output.runtime_capability_guards.len(), 1);
        let trace_plan = profile::extract(&document, Profile::TracePlan);
        assert!(trace_plan
            .runtime_result_call_sites
            .iter()
            .any(|site| site.span[0] == 3));
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "label", "line": 2
                    },
                    "slot": "arm",
                    "domain": {
                        "types": ["DetailArm", "FallbackArm"],
                        "shapes": [
                            {"kind": "record", "name": "DetailArm", "members": {"detail": {"kind": "unknown"}}},
                            {"kind": "record", "name": "FallbackArm", "members": {"fallback": {"kind": "unknown"}}}
                        ]
                    },
                    "count": 2
                }],
                "calls": [
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "label", "kind": "instance", "line": 2
                        },
                        "callsite": {"path": path, "line": 3, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Object#respond_to?().",
                            "owner": "Object", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "DetailArm"
                        }],
                        "receiver_domain": {"types": ["DetailArm"]},
                        "result_truths": [true],
                        "count": 1
                    },
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "label", "kind": "instance", "line": 2
                        },
                        "callsite": {"path": path, "line": 3, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Object#respond_to?().",
                            "owner": "Object", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "FallbackArm"
                        }],
                        "receiver_domain": {"types": ["FallbackArm"]},
                        "result_truths": [false],
                        "count": 1
                    }
                ]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        for member in ["detail", "fallback"] {
            let accessor = output
                .calls
                .iter()
                .find(|call| call.function == "label" && call.message == member)
                .expect("guarded accessor");
            assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
            assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
            let expected_symbol =
                format!("fact-mine-runtime runtime-contract v1 Record#{member}().");
            assert_eq!(
                accessor.semantic_symbol.as_deref(),
                Some(expected_symbol.as_str())
            );
        }
    }

    #[test]
    fn cfg_dfg_overlay_closes_mixed_generated_records_inside_capability_ternaries() {
        let mut file = tempfile::Builder::new()
            .suffix(".rb")
            .tempfile()
            .expect("source");
        file.write_all(
            br#"NativeArm = Struct.new(:kind, :member, :decision_span, :arm_span)

module Worker
  module_function

  def signature(arm)
    [
      arm.kind,
      (arm.respond_to?(:member) ? arm.member : nil),
      Array(arm.decision_span).map(&:to_i),
      Array(arm.respond_to?(:arm_span) ? arm.arm_span : arm.span).map(&:to_i)
    ]
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        assert_eq!(output.runtime_capability_guards.len(), 2);
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "environment": {"runtime.version": "3.2.3"},
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "signature", "line": 6
                    },
                    "slot": "arm",
                    "domain": {
                        "types": ["NativeArm", "AnonymousArm"],
                        "shapes": [
                            {
                                "kind": "record", "name": "NativeArm",
                                "members": {
                                    "kind": {"kind": "class", "name": "String"},
                                    "member": {"kind": "class", "name": "String"},
                                    "decision_span": {
                                        "kind": "array",
                                        "elements": [{"kind": "class", "name": "Integer"}]
                                    },
                                    "arm_span": {
                                        "kind": "array",
                                        "elements": [{"kind": "class", "name": "Integer"}]
                                    }
                                }
                            },
                            {
                                "kind": "record", "name": "AnonymousArm",
                                "members": {
                                    "kind": {"kind": "class", "name": "Symbol"},
                                    "member": {"kind": "class", "name": "String"},
                                    "decision_span": {
                                        "kind": "array",
                                        "elements": [{"kind": "class", "name": "Integer"}]
                                    },
                                    "span": {
                                        "kind": "array",
                                        "elements": [{"kind": "class", "name": "Integer"}]
                                    }
                                }
                            }
                        ]
                    },
                    "count": 2
                }],
                "calls": [
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "signature",
                            "kind": "class", "line": 6
                        },
                        "callsite": {"path": path, "line": 9, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#respond_to?().",
                            "owner": "Kernel", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "NativeArm"
                        }],
                        "receiver_domain": {"types": ["NativeArm"]},
                        "result_truths": [true],
                        "count": 1
                    },
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "signature",
                            "kind": "class", "line": 6
                        },
                        "callsite": {"path": path, "line": 9, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#respond_to?().",
                            "owner": "Kernel", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "AnonymousArm"
                        }],
                        "receiver_domain": {"types": ["AnonymousArm"]},
                        "result_truths": [true],
                        "count": 1
                    },
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "signature",
                            "kind": "class", "line": 6
                        },
                        "callsite": {"path": path, "line": 11, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#respond_to?().",
                            "owner": "Kernel", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "NativeArm"
                        }],
                        "receiver_domain": {"types": ["NativeArm"]},
                        "result_truths": [true],
                        "count": 1
                    },
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "signature",
                            "kind": "class", "line": 6
                        },
                        "callsite": {"path": path, "line": 11, "selector": "respond_to?"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#respond_to?().",
                            "owner": "Kernel", "name": "respond_to?", "kind": "instance",
                            "receiver_type": "AnonymousArm"
                        }],
                        "receiver_domain": {"types": ["AnonymousArm"]},
                        "result_truths": [false],
                        "count": 1
                    }
                ]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        for member in ["kind", "member", "decision_span", "arm_span", "span"] {
            let accessor = output
                .calls
                .iter()
                .find(|call| call.message == member)
                .unwrap_or_else(|| panic!("{member} accessor"));
            assert_eq!(
                accessor.known_time_complexity.as_deref(),
                Some("O(1)"),
                "{member} remained unresolved: {accessor:#?}"
            );
            assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        }
    }

    #[test]
    fn cfg_dfg_overlay_rejects_record_accessors_when_any_observed_type_lacks_the_member() {
        let domain = ValueDomain {
            types: BTreeSet::from(["Left".to_string(), "Right".to_string()]),
            shapes: vec![
                ValueShape {
                    kind: "record".to_string(),
                    name: "Left".to_string(),
                    members: BTreeMap::from([(
                        "kind".to_string(),
                        ValueShape {
                            kind: "unknown".to_string(),
                            ..ValueShape::default()
                        },
                    )]),
                    ..ValueShape::default()
                },
                ValueShape {
                    kind: "record".to_string(),
                    name: "Right".to_string(),
                    members: BTreeMap::new(),
                    ..ValueShape::default()
                },
            ],
            ..ValueDomain::default()
        };
        assert!(!runtime_record_domain_exposes(&domain, "kind"));
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

        let mut evidence = valid_evidence();
        evidence["calls"][0]["targets"] = json!([]);
        assert!(RuntimeValueEvidence::from_json(&evidence.to_string())
            .unwrap_err()
            .to_string()
            .contains("without targets"));
        evidence["calls"][0]["target_observation_complete"] = json!(false);
        evidence["calls"][0]["receiver_domain"] = json!({"types": ["Worker"]});
        assert!(RuntimeValueEvidence::from_json(&evidence.to_string()).is_ok());

        let mut evidence = valid_evidence();
        evidence["calls"][0]["targets"] = json!([]);
        evidence["calls"][0]["target_observation_complete"] = json!(false);
        evidence["calls"][0]
            .as_object_mut()
            .unwrap()
            .remove("receiver_domain");
        evidence["calls"][0]["result_domain"] = json!({"types": ["String"]});
        assert!(
            RuntimeValueEvidence::from_json(&evidence.to_string()).is_ok(),
            "an exact result observation remains useful without inventing a receiver or target"
        );
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
        assert!(
            inferred.semantic_symbol.as_deref().is_some_and(
                |symbol| symbol.starts_with("fact-mine-runtime runtime-project v1 Method#")
            ),
            "the normalized Struct reader should resolve to its generated project declaration"
        );
        assert_eq!(inferred.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(inferred.known_space_complexity.as_deref(), Some("O(1)"));
        assert_eq!(overlay.stats.observed_call_sites, 1);
        assert!(
            overlay.stats.inferred_call_sites >= 1,
            "the generated block-reader target must be inferred"
        );
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
    fn cfg_dfg_overlay_propagates_block_call_results_to_chained_receivers() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(rows)
    rows.map { |row| row }
  end

  def run(rows)
    rows.select do
      true
    end.map do |row|
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
                        "types": ["Array"], "elements": ["Row"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "Row",
                                "members": {"kind": {"kind": "unknown"}}
                            }]
                        }]
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
                    "callsite": {"path": path, "line": 3, "selector": "map"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Array#map().",
                        "owner": "Array", "name": "map", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let map = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "map")
            .expect("chained map");
        assert_eq!(map.receiver_type.as_deref(), Some("Array"));
        assert_eq!(
            map.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 Array#map().")
        );
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("chained callback accessor");
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#kind().")
        );
    }

    #[test]
    fn cfg_dfg_overlay_binds_each_chained_iterator_to_its_own_callback_scope() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(rows)
    rows.map do |row|
      build(row)
    end.sort_by do |row|
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
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "map"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Enumerable#map().",
                        "owner": "Enumerable", "name": "map", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {
                        "types": ["Array"], "elements": ["Hash"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{"kind": "hash"}]
                        }]
                    },
                    "result_domain": {
                        "types": ["Array"], "elements": ["AnonymousResult"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "AnonymousResult",
                                "members": {
                                    "kind": {"kind": "class", "name": "String"}
                                }
                            }]
                        }]
                    },
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "kind")
            .expect("outer iterator callback accessor");
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#kind()."),
            "the outer sort callback must receive the mapped anonymous record domain"
        );
        assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
    }

    #[test]
    fn cfg_dfg_overlay_reaches_a_fixed_point_through_nested_generated_accessors() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(rows)
    rows.map { |row| row.arm.function }
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
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Array"], "elements": ["ArmCoverage"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "ArmCoverage",
                                "members": {
                                    "arm": {
                                        "kind": "record", "name": "T.untyped",
                                        "members": {
                                            "function": {"kind": "class", "name": "String"}
                                        }
                                    }
                                }
                            }]
                        }]
                    },
                    "count": 1
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        for message in ["arm", "function"] {
            let accessor = output
                .calls
                .iter()
                .find(|call| call.function == "run" && call.message == message)
                .unwrap_or_else(|| panic!("{message} accessor"));
            let expected = format!("fact-mine-runtime runtime-contract v1 Record#{message}().");
            assert_eq!(accessor.semantic_symbol.as_deref(), Some(expected.as_str()));
            assert_eq!(accessor.known_time_complexity.as_deref(), Some("O(1)"));
            assert_eq!(accessor.known_space_complexity.as_deref(), Some("O(1)"));
        }
    }

    #[test]
    fn cfg_dfg_overlay_propagates_a_generated_accessor_result_through_assignment() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(rows)
    rows.map do |wrapper|
      item = wrapper.item
      item.kind
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
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "rows",
                    "domain": {
                        "types": ["Array"], "elements": ["Wrapper"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [{
                                "kind": "record", "name": "Wrapper",
                                "members": {
                                    "item": {
                                        "kind": "record", "name": "Item",
                                        "members": {
                                            "kind": {"kind": "class", "name": "String"}
                                        }
                                    }
                                }
                            }]
                        }]
                    },
                    "count": 1
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        for message in ["item", "kind"] {
            let accessor = output
                .calls
                .iter()
                .find(|call| call.function == "run" && call.message == message)
                .unwrap_or_else(|| panic!("{message} accessor"));
            let expected = format!("fact-mine-runtime runtime-contract v1 Record#{message}().");
            assert_eq!(accessor.semantic_symbol.as_deref(), Some(expected.as_str()));
        }
    }

    #[test]
    fn cfg_dfg_overlay_propagates_nested_record_accessors_after_a_callback_guard() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"RowCoverage = Struct.new(:row, :covered)

class Worker
  def run(rows)
    rows.filter_map do |row_cov|
      next if row_cov.covered
      row = row_cov.row
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
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 4
                    },
                    "callsite": {"path": path, "line": 5, "selector": "filter_map"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Enumerable#filter_map().",
                        "owner": "Enumerable", "name": "filter_map", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {
                        "types": ["Array"], "elements": ["RowCoverage", "AnonymousCoverage"],
                        "shapes": [{
                            "kind": "array",
                            "elements": [
                                {
                                    "kind": "record", "name": "RowCoverage",
                                    "members": {
                                        "covered": {"kind": "class", "name": "FalseClass"},
                                        "row": {
                                            "kind": "record", "name": "Row",
                                            "members": {
                                                "kind": {"kind": "class", "name": "String"}
                                            }
                                        }
                                    }
                                },
                                {
                                    "kind": "record", "name": "AnonymousCoverage",
                                    "members": {
                                        "covered": {"kind": "class", "name": "FalseClass"},
                                        "row": {
                                            "kind": "record", "name": "Row",
                                            "members": {
                                                "kind": {"kind": "class", "name": "String"}
                                            }
                                        }
                                    }
                                }
                            ]
                        }]
                    },
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        for message in ["covered", "row", "kind"] {
            let accessor = output
                .calls
                .iter()
                .find(|call| call.function == "run" && call.message == message)
                .unwrap_or_else(|| panic!("{message} accessor"));
            let expected = format!("fact-mine-runtime runtime-contract v1 Record#{message}().");
            assert_eq!(accessor.semantic_symbol.as_deref(), Some(expected.as_str()));
        }
    }

    #[test]
    fn cfg_dfg_overlay_joins_value_preserving_alternative_call_results() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(index)
    existing = index[:left] || index[:right]
    existing.hits.to_s
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let row_domain = json!({
            "types": ["Row"],
            "shapes": [{
                "kind": "record", "name": "Row",
                "members": {"hits": {"kind": "class", "name": "Integer"}}
            }]
        });
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "index",
                    "domain": {"types": ["Hash"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "[]"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Hash#`[]`().",
                        "owner": "Hash", "name": "[]", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {"types": ["Hash"]},
                    "result_domain": row_domain,
                    "count": 2
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "hits")
            .expect("alternative result accessor");
        assert_eq!(accessor.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#hits().")
        );
        let conversion = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "to_s")
            .expect("record member conversion");
        assert_eq!(conversion.receiver_type.as_deref(), Some("Integer"));
    }

    #[test]
    fn cfg_dfg_overlay_preserves_record_shapes_projected_from_hash_values() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(table)
    entry = table[:entry]
    entry.name
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
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "table",
                    "domain": {"types": ["Hash"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "[]"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Hash#`[]`().",
                        "owner": "Hash", "name": "[]", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {
                        "types": ["Hash"], "values": ["Row"],
                        "shapes": [{
                            "kind": "hash",
                            "values": [{
                                "kind": "record", "name": "Row",
                                "members": {"name": {"kind": "class", "name": "String"}}
                            }]
                        }]
                    },
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "name")
            .expect("projected record accessor");
        assert_eq!(accessor.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#name().")
        );
    }

    #[test]
    fn runtime_evidence_uses_a_unique_source_callsite_when_the_runtime_block_frame_is_synthetic() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(items)
    items.each { |item| item.upcase }
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
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "items",
                    "domain": {
                        "types": ["Array"], "elements": ["String"],
                        "shapes": [{"kind": "array", "elements": [{"kind": "class", "name": "String"}]}]
                    },
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": "<internal:kernel>",
                        "owner": "Kernel", "name": "tap",
                        "kind": "instance", "line": 0
                    },
                    "callsite": {"path": path, "line": 3, "selector": "each"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Array#each().",
                        "owner": "Array", "name": "each", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {
                        "types": ["Array"], "elements": ["String"],
                        "shapes": [{"kind": "array", "elements": [{"kind": "class", "name": "String"}]}]
                    },
                    "count": 1
                }, {
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": "<internal:kernel>",
                        "owner": "Kernel", "name": "tap",
                        "kind": "instance", "line": 0
                    },
                    "callsite": {"path": path, "line": 3, "selector": "upcase"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 String#upcase().",
                        "owner": "String", "name": "upcase", "kind": "instance",
                        "receiver_type": "String"
                    }],
                    "receiver_domain": {"types": ["String"]},
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let upcase = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "upcase")
            .expect("callback operation");
        assert_eq!(upcase.receiver_type.as_deref(), Some("String"));
        assert_eq!(
            upcase.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 String#upcase().")
        );
        assert!(upcase.runtime_evidence_observed);
    }

    #[test]
    fn cfg_dfg_overlay_refines_a_truthy_runtime_record_result_through_cfg_definitions() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(index)
    existing = index[:left] || index[:right]
    if existing
      existing.hits
    end
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        assert_eq!(output.runtime_truthiness_guards.len(), 1);
        let path = file.path().to_string_lossy();
        let row_domain = json!({
            "types": ["NilClass", "Row"],
            "shapes": [{
                "kind": "record", "name": "Row",
                "members": {"hits": {"kind": "class", "name": "Integer"}}
            }]
        });
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "index",
                    "domain": {"types": ["Hash"]},
                    "count": 1
                }],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "[]"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Hash#`[]`().",
                        "owner": "Hash", "name": "[]", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {"types": ["Hash"]},
                    "result_domain": row_domain,
                    "count": 2
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let accessor = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "hits")
            .expect("truthy record accessor");
        assert_eq!(accessor.receiver_type.as_deref(), Some("Row"));
        assert_eq!(
            accessor.semantic_symbol.as_deref(),
            Some("fact-mine-runtime runtime-contract v1 Record#hits().")
        );
    }

    #[test]
    fn runtime_scip_uses_the_exact_ruby_fcall_selector_inside_nested_arguments() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(arm)
    Array(arm.respond_to?(:arm_span) ? arm.arm_span : arm.span)
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
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "Array"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#Array().",
                        "owner": "Kernel", "name": "Array", "kind": "instance",
                        "receiver_type": "Module"
                    }],
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        let overlay = apply_to_profile(&mut output, &evidence).expect("overlay");
        let array = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "Array")
            .expect("Array conversion");
        assert_eq!(array.selector_span, Some([3, 4, 3, 9]));
        assert_eq!(
            array.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 Kernel#Array().")
        );
        assert_eq!(
            overlay.index["_runtimeEvidence"]["observedCallsiteAnchors"]
                .as_array()
                .map(Vec::len),
            Some(1)
        );
    }

    #[test]
    fn runtime_scip_matches_a_class_method_by_its_normalized_dispatch_name() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def self.render(value)
    value.to_s
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
                        "owner": "Worker", "name": "render", "kind": "class", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "to_s"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 String#to_s().",
                        "owner": "String", "name": "to_s", "kind": "instance",
                        "receiver_type": "String"
                    }],
                    "receiver_domain": {"types": ["String"]},
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let call = output
            .calls
            .iter()
            .find(|call| call.function == "self.render" && call.message == "to_s")
            .expect("class method call");
        assert_eq!(call.receiver_type.as_deref(), Some("String"));
        assert_eq!(
            call.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 String#to_s().")
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
    fn cfg_dfg_overlay_prices_runtime_typed_stdlib_calls_without_a_second_trace() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(payload)
    payload.fetch("kind").to_sym
  end

  def launch(command)
    system(command)
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
                "environment": {"runtime.version": "3.2.3"},
                "observations": [],
                "calls": [{
                    "language": "ruby",
                    "caller": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "name": "run",
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "fetch"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Hash#fetch().",
                        "owner": "Hash", "name": "fetch", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {"types": ["Hash"]},
                    "result_domain": {"types": ["String"]},
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let to_sym = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "to_sym")
            .expect("String#to_sym");
        assert_eq!(to_sym.receiver_type.as_deref(), Some("String"));
        assert_eq!(
            to_sym.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 String#to_sym().")
        );
        assert_eq!(to_sym.known_time_complexity.as_deref(), Some("O(N)"));
        assert_eq!(to_sym.known_space_complexity.as_deref(), Some("O(N)"));

        let system = output
            .calls
            .iter()
            .find(|call| call.function == "launch" && call.message == "system")
            .expect("Kernel#system");
        assert_eq!(
            system.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 Kernel#system().")
        );
        assert!(system.known_time_complexity.is_some());
        assert!(system.known_space_complexity.is_some());
    }

    #[test]
    fn cfg_dfg_overlay_uses_language_mixin_ownership_for_runtime_receivers() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed(rows)
    rows.sort_by { |row| row }
  end

  def run(weights)
    weights.sort_by { |_, weight| -weight }
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
                "environment": {"runtime.version": "3.2.3"},
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 6
                    },
                    "slot": "weights",
                    "domain": {
                        "types": ["Hash"], "keys": ["String"], "values": ["Float"]
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
                    "callsite": {"path": path, "line": 3, "selector": "sort_by"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Enumerable#sort_by().",
                        "owner": "Enumerable", "name": "sort_by", "kind": "instance",
                        "receiver_type": "Array"
                    }],
                    "receiver_domain": {"types": ["Array"]},
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let sort = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "sort_by")
            .expect("Hash Enumerable#sort_by");
        assert!(sort.known_time_complexity.is_some());
        assert!(sort.known_space_complexity.is_some());
    }

    #[test]
    fn cfg_dfg_overlay_refines_the_bare_subject_of_a_short_circuit_guard() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def run(existing)
    if existing && existing.active?
      existing.hits
    end
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        assert!(
            output
                .runtime_truthiness_guards
                .iter()
                .any(|guard| guard.subject == "existing"),
            "the true branch of `a && b` proves the bare left subject truthy"
        );
        let path = file.path().to_string_lossy();
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "existing",
                    "domain": {
                        "types": ["NilClass", "Row"],
                        "shapes": [{
                            "kind": "record", "name": "Row",
                            "members": {
                                "active?": {"kind": "class", "name": "TrueClass"},
                                "hits": {"kind": "class", "name": "Integer"}
                            }
                        }]
                    },
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let hits = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "hits")
            .expect("truthy branch accessor");
        assert_eq!(hits.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(hits.known_space_complexity.as_deref(), Some("O(1)"));
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
    fn cfg_dfg_overlay_closes_provider_dispatch_from_exact_runtime_module_identities() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"module FirstProvider
  def self.rule_id_for
    "first"
  end
end

module SecondProvider
  def self.rule_id_for
    "second"
  end
end

class Worker
  def run(provider)
    provider.rule_id_for
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let run_line = output
            .methods
            .iter()
            .find(|method| method.owner == "Worker" && method.name == "run")
            .expect("run method")
            .line;
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": run_line
                    },
                    "slot": "provider",
                    "domain": {
                        "types": ["Module"],
                        "singletons": ["FirstProvider", "SecondProvider"]
                    },
                    "count": 2
                }],
                "calls": []
            })
            .to_string(),
        )
        .expect("evidence");

        let methods = MethodIndex::new(&output.methods);
        let call_index = CallIndex::new(&output.calls);
        let seeded = observed_receiver_domains(&output, &call_index, &evidence, &methods);
        let provider_call = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "rule_id_for")
            .expect("provider call before overlay");
        assert_eq!(
            seeded
                .get(&provider_call.id)
                .map(|domain| domain.singletons.clone()),
            Some(BTreeSet::from([
                "FirstProvider".to_string(),
                "SecondProvider".to_string()
            ]))
        );
        apply_to_profile(&mut output, &evidence).expect("overlay");
        let dispatch = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "rule_id_for")
            .expect("provider dispatch");

        assert!(
            dispatch.consumer_closed_candidate_set,
            "provider dispatch remained open: {dispatch:#?}"
        );
        assert_eq!(dispatch.candidate_targets.len(), 2);
        assert_eq!(
            dispatch
                .candidate_targets
                .iter()
                .filter_map(|target| output
                    .methods
                    .iter()
                    .find(|method| method.id == *target)
                    .map(|method| method.owner.as_str()))
                .collect::<BTreeSet<_>>(),
            BTreeSet::from(["FirstProvider", "SecondProvider"])
        );
    }

    #[test]
    fn cfg_dfg_overlay_reuses_a_production_target_for_a_test_replaced_call() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  def observed
    File.read("first")
  end

  def replaced
    File.read("second")
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
                "calls": [
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "observed",
                            "kind": "instance", "line": 2
                        },
                        "callsite": {"path": path, "line": 3, "selector": "read"},
                        "targets": [{
                            "symbol": "nil-kill-runtime ruby ruby 3.2.3 IO.read().",
                            "owner": "IO", "name": "read", "kind": "class",
                            "receiver_type": "Class"
                        }],
                        "receiver_domain": {
                            "types": ["Class"], "singletons": ["File"]
                        },
                        "count": 1
                    },
                    {
                        "language": "ruby",
                        "caller": {
                            "language": "ruby", "path": path,
                            "owner": "Worker", "name": "replaced",
                            "kind": "instance", "line": 6
                        },
                        "callsite": {"path": path, "line": 7, "selector": "read"},
                        "targets": [],
                        "target_observation_complete": false,
                        "receiver_domain": {
                            "types": ["Class"], "singletons": ["File"]
                        },
                        "count": 1
                    }
                ]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let replaced = output
            .calls
            .iter()
            .find(|call| call.function == "replaced" && call.message == "read")
            .expect("replaced File.read");

        assert_eq!(
            replaced.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 IO.read().")
        );
        assert_eq!(replaced.known_time_complexity.as_deref(), Some("O(N+C)"));
        assert_eq!(replaced.known_space_complexity.as_deref(), Some("O(N+S)"));
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

    #[test]
    fn cfg_dfg_overlay_propagates_a_project_return_through_value_preserving_assignment() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Worker
  Fact = Struct.new(:score) do
    def strong?
      score.to_i > 0
    end
  end

  def self.missing
    Fact.new(0)
  end

  def self.run(fact)
    fact ||= missing
    fact.strong?
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
                        "owner": "Worker", "function": "missing", "line": 8
                    },
                    "domain": {
                        "types": ["Worker::Fact"],
                        "shapes": [{
                            "kind": "record", "name": "Worker::Fact",
                            "members": {"score": {"kind": "class", "name": "Integer"}}
                        }]
                    },
                    "count": 1
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let predicate = output
            .calls
            .iter()
            .find(|call| call.function == "self.run" && call.message == "strong?")
            .expect("predicate");
        assert_eq!(predicate.receiver_type.as_deref(), Some("Worker::Fact"));
        assert!(
            predicate.target.is_some() || predicate.semantic_symbol.is_some(),
            "{predicate:#?}"
        );
    }

    #[test]
    fn method_index_matches_runtime_scope_to_a_class_method_dispatch_name() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            br#"class Producer
  def self.build_rows
    []
  end
end
"#,
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let producer_line = output
            .methods
            .iter()
            .find(|method| method.dispatch_name == "build_rows")
            .expect("producer")
            .line;
        let index = MethodIndex::new(&output.methods);
        let located = index.locate_scope(&ValueScope {
            language: "ruby".to_string(),
            path: path.to_string(),
            owner: "Producer".to_string(),
            function: "build_rows".to_string(),
            line: producer_line,
            method_id: None,
        });

        assert_eq!(located.len(), 1);
        assert_eq!(located[0].dispatch_name, "build_rows");
    }

    #[test]
    fn canonical_partial_evidence_joins_complete_fields_only_to_the_exact_anchor() {
        let directory = tempfile::tempdir().expect("directory");
        let file = directory.path().join("worker.rb");
        std::fs::write(
            &file,
            "class Worker\n  def run(left, right)\n    left.size + right.size\n  end\nend\n",
        )
        .expect("source");
        let document = syntax::parse_file(file.clone(), Language::Ruby).expect("parse");
        let mut overlay_profile = profile::extract(&document, Profile::Espalier);
        let plan_profile = profile::extract(&document, Profile::TracePlan);
        let built = runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            std::slice::from_ref(&file),
            directory.path(),
        )
        .expect("plan");
        let selected = built
            .bindings
            .iter()
            .find_map(|(anchor, binding)| match binding {
                AnchorBinding::Call { call_id }
                    if overlay_profile
                        .calls
                        .iter()
                        .find(|call| call.id == *call_id)
                        .is_some_and(|call| call.message == "size" && call.receiver == "left") =>
                {
                    Some((anchor.clone(), call_id.clone()))
                }
                _ => None,
            })
            .expect("left.size anchor");
        let run_id = "run-1".to_string();
        let runtime_value = |name: &str| runtime_protocol::RuntimeValue {
            type_symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {name}#"),
            source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::PRODUCTION),
            ..runtime_protocol::RuntimeValue::default()
        };
        let runtime_values = |name: &str| runtime_protocol::ValueSet {
            alternatives: vec![runtime_protocol::WeightedValue {
                value: MessageField::some(runtime_value(name)),
                count: 1,
                ..runtime_protocol::WeightedValue::default()
            }],
            ..runtime_protocol::ValueSet::default()
        };
        let anchors = built
            .plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                let selected_anchor = anchor.symbol == selected.0;
                runtime_protocol::AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(runtime_protocol::CaptureSummary {
                        status: EnumOrUnknown::new(if selected_anchor {
                            CaptureStatus::PARTIAL
                        } else {
                            CaptureStatus::NOT_EXECUTED
                        }),
                        run_ids: vec![run_id.clone()],
                        observed_executions: u64::from(selected_anchor),
                        reason: if selected_anchor {
                            "result value was not captured".to_string()
                        } else {
                            "anchor did not execute in the modeled run".to_string()
                        },
                        complete_kinds: if selected_anchor {
                            vec![
                                EnumOrUnknown::new(EvidenceKind::RECEIVER_VALUE),
                                EnumOrUnknown::new(EvidenceKind::CALL_TARGET),
                            ]
                        } else {
                            request.required.clone()
                        },
                        ..runtime_protocol::CaptureSummary::default()
                    }),
                    executions: selected_anchor
                        .then(|| runtime_protocol::ExecutionBucket {
                            count: 1,
                            receiver: MessageField::some(runtime_values("String")),
                            target: MessageField::some(runtime_protocol::RuntimeTarget {
                                symbol: "nil-kill-runtime ruby ruby 3.2.3 String#size()."
                                    .to_string(),
                                source_role: EnumOrUnknown::new(
                                    runtime_protocol::SourceRole::STANDARD_LIBRARY,
                                ),
                                package_manager: "ruby".to_string(),
                                package_name: "ruby".to_string(),
                                package_version: "3.2.3".to_string(),
                                ..runtime_protocol::RuntimeTarget::default()
                            }),
                            provenance: MessageField::some(runtime_protocol::Provenance {
                                run_id: run_id.clone(),
                                provider: "ruby-tracepoint".to_string(),
                                provider_version: "1".to_string(),
                                ..runtime_protocol::Provenance::default()
                            }),
                            ..runtime_protocol::ExecutionBucket::default()
                        })
                        .into_iter()
                        .collect(),
                    ..runtime_protocol::AnchorEvidence::default()
                }
            })
            .collect();
        let evidence = runtime_protocol::RuntimeEvidence {
            protocol_version: runtime_protocol::PROTOCOL_VERSION,
            producer: MessageField::some(runtime_protocol::ToolInfo {
                name: "nil-kill".to_string(),
                version: "1".to_string(),
                ..runtime_protocol::ToolInfo::default()
            }),
            authority: EnumOrUnknown::new(runtime_protocol::Authority::MODELED_RUNS),
            trace_plan_digest: built.plan.plan_digest.clone(),
            runs: vec![runtime_protocol::Run {
                id: run_id,
                status: EnumOrUnknown::new(runtime_protocol::RunStatus::SUCCEEDED),
                ..runtime_protocol::Run::default()
            }],
            anchors,
            ..runtime_protocol::RuntimeEvidence::default()
        };

        apply_protocol_to_profile(&mut overlay_profile, &built, &evidence).expect("overlay");
        let selected_call = overlay_profile
            .calls
            .iter()
            .find(|call| call.id == selected.1)
            .expect("selected call");
        assert!(selected_call.runtime_evidence_observed);
        assert_eq!(
            selected_call.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 String#size().")
        );
        let other = overlay_profile
            .calls
            .iter()
            .find(|call| call.message == "size" && call.receiver == "right")
            .expect("other same-selector call");
        assert!(!other.runtime_evidence_observed);
    }

    #[test]
    fn canonical_call_normalization_keeps_exact_results_and_drops_empty_filtered_buckets() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(b"class Worker\n  def run(value)\n    value.to_s\n  end\nend\n")
            .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let output = profile::extract(&document, Profile::Espalier);
        let call = output
            .calls
            .iter()
            .find(|call| call.message == "to_s")
            .expect("call");
        let method = output
            .methods
            .iter()
            .find(|method| method.id == call.source)
            .expect("method");
        let methods = output
            .methods
            .iter()
            .map(|method| (method.id.as_str(), method))
            .collect::<BTreeMap<_, _>>();
        let bindings = BTreeMap::new();
        let anchor_methods = BTreeMap::new();
        let filtered_target = runtime_protocol::ExecutionBucket {
            count: 1,
            target: MessageField::some(runtime_protocol::RuntimeTarget {
                symbol: "nil-kill-runtime ruby minitest 5 Mock#to_s().".to_string(),
                source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::NON_PRODUCTION),
                ..runtime_protocol::RuntimeTarget::default()
            }),
            ..runtime_protocol::ExecutionBucket::default()
        };
        assert!(
            protocol_call_observation(
                call,
                method,
                &call.id,
                &filtered_target,
                &BTreeSet::from([EvidenceKind::CALL_TARGET.value()]),
                &methods,
                &bindings,
                &anchor_methods,
            )
            .expect("filtered target")
            .is_none(),
            "a filtered test-double target with no value fact must not become an empty call row"
        );

        let result_only = runtime_protocol::ExecutionBucket {
            count: 1,
            result: MessageField::some(runtime_protocol::ValueSet {
                alternatives: vec![runtime_protocol::WeightedValue {
                    value: MessageField::some(runtime_protocol::RuntimeValue {
                        type_symbol: "nil-kill-runtime ruby ruby 3.2.3 String#".to_string(),
                        source_role: EnumOrUnknown::new(
                            runtime_protocol::SourceRole::STANDARD_LIBRARY,
                        ),
                        ..runtime_protocol::RuntimeValue::default()
                    }),
                    count: 1,
                    ..runtime_protocol::WeightedValue::default()
                }],
                ..runtime_protocol::ValueSet::default()
            }),
            ..runtime_protocol::ExecutionBucket::default()
        };
        let observation = protocol_call_observation(
            call,
            method,
            &call.id,
            &result_only,
            &BTreeSet::from([EvidenceKind::RESULT_VALUE.value()]),
            &methods,
            &bindings,
            &anchor_methods,
        )
        .expect("result-only observation")
        .expect("useful exact result");
        assert!(observation.targets.is_empty());
        assert!(observation.receiver_domain.is_none());
        assert_eq!(
            observation.result_domain.expect("result domain").types,
            BTreeSet::from(["String".to_string()])
        );
    }

    #[test]
    fn canonical_candidate_group_uses_fact_mine_dfg_to_join_shared_receivers() {
        let directory = tempfile::tempdir().expect("directory");
        let file = directory.path().join("worker.rb");
        std::fs::write(
            &file,
            "class Worker\n  def run(row)\n    row.size + row.size\n  end\nend\n",
        )
        .expect("source");
        let document = syntax::parse_file(file.clone(), Language::Ruby).expect("parse");
        let mut overlay_profile = profile::extract(&document, Profile::Espalier);
        let plan_profile = profile::extract(&document, Profile::TracePlan);
        let built = runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            std::slice::from_ref(&file),
            directory.path(),
        )
        .expect("plan");
        let candidates = built
            .bindings
            .iter()
            .filter_map(|(anchor, binding)| match binding {
                AnchorBinding::Call { call_id }
                    if overlay_profile
                        .calls
                        .iter()
                        .find(|call| call.id == *call_id)
                        .is_some_and(|call| call.message == "size") =>
                {
                    Some(anchor.clone())
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(candidates.len(), 2);
        let run_id = "run-1".to_string();
        let anchors = built
            .plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                let candidate = candidates.contains(&anchor.symbol);
                runtime_protocol::AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(runtime_protocol::CaptureSummary {
                        status: EnumOrUnknown::new(if candidate {
                            CaptureStatus::PARTIAL
                        } else {
                            CaptureStatus::NOT_EXECUTED
                        }),
                        run_ids: vec![run_id.clone()],
                        reason: if candidate {
                            "execution is represented by a candidate group".to_string()
                        } else {
                            "anchor did not execute in the modeled run".to_string()
                        },
                        complete_kinds: if candidate {
                            Vec::new()
                        } else {
                            request.required.clone()
                        },
                        ..runtime_protocol::CaptureSummary::default()
                    }),
                    ..runtime_protocol::AnchorEvidence::default()
                }
            })
            .collect();
        let runtime_values = runtime_protocol::ValueSet {
            alternatives: vec![runtime_protocol::WeightedValue {
                value: MessageField::some(runtime_protocol::RuntimeValue {
                    type_symbol: "nil-kill-runtime ruby ruby 3.2.3 String#".to_string(),
                    source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::PRODUCTION),
                    ..runtime_protocol::RuntimeValue::default()
                }),
                count: 1,
                ..runtime_protocol::WeightedValue::default()
            }],
            ..runtime_protocol::ValueSet::default()
        };
        let evidence = runtime_protocol::RuntimeEvidence {
            protocol_version: runtime_protocol::PROTOCOL_VERSION,
            producer: MessageField::some(runtime_protocol::ToolInfo {
                name: "nil-kill".to_string(),
                version: "1".to_string(),
                ..runtime_protocol::ToolInfo::default()
            }),
            authority: EnumOrUnknown::new(runtime_protocol::Authority::MODELED_RUNS),
            trace_plan_digest: built.plan.plan_digest.clone(),
            runs: vec![runtime_protocol::Run {
                id: run_id.clone(),
                status: EnumOrUnknown::new(runtime_protocol::RunStatus::SUCCEEDED),
                ..runtime_protocol::Run::default()
            }],
            anchors,
            correlations: vec![runtime_protocol::CorrelationEvidence {
                group_id: "same-value-size-calls".to_string(),
                candidate_anchor_symbols: candidates,
                capture: MessageField::some(runtime_protocol::CaptureSummary {
                    status: EnumOrUnknown::new(CaptureStatus::COMPLETE_FOR_RUNS),
                    run_ids: vec![run_id.clone()],
                    observed_executions: 2,
                    complete_kinds: vec![
                        EnumOrUnknown::new(EvidenceKind::RECEIVER_VALUE),
                        EnumOrUnknown::new(EvidenceKind::CALL_TARGET),
                    ],
                    ..runtime_protocol::CaptureSummary::default()
                }),
                executions: vec![runtime_protocol::ExecutionBucket {
                    count: 2,
                    receiver: MessageField::some(runtime_values),
                    target: MessageField::some(runtime_protocol::RuntimeTarget {
                        symbol: "nil-kill-runtime ruby ruby 3.2.3 String#size().".to_string(),
                        source_role: EnumOrUnknown::new(
                            runtime_protocol::SourceRole::STANDARD_LIBRARY,
                        ),
                        package_manager: "ruby".to_string(),
                        package_name: "ruby".to_string(),
                        package_version: "3.2.3".to_string(),
                        ..runtime_protocol::RuntimeTarget::default()
                    }),
                    provenance: MessageField::some(runtime_protocol::Provenance {
                        run_id,
                        provider: "ruby-tracepoint".to_string(),
                        provider_version: "1".to_string(),
                        ..runtime_protocol::Provenance::default()
                    }),
                    ..runtime_protocol::ExecutionBucket::default()
                }],
                ..runtime_protocol::CorrelationEvidence::default()
            }],
            ..runtime_protocol::RuntimeEvidence::default()
        };

        apply_protocol_to_profile(&mut overlay_profile, &built, &evidence).expect("overlay");
        let size_calls = overlay_profile
            .calls
            .iter()
            .filter(|call| call.message == "size")
            .collect::<Vec<_>>();
        assert_eq!(size_calls.len(), 2);
        assert!(size_calls.iter().all(|call| call.runtime_evidence_observed));
        assert!(size_calls.iter().all(|call| {
            call.semantic_symbol.as_deref()
                == Some("nil-kill-runtime ruby ruby 3.2.3 String#size().")
        }));
    }

    #[test]
    fn candidate_group_dfg_does_not_equate_distinct_same_line_receivers() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            b"class Worker\n  def run(left, right)\n    left.size + right.size\n  end\nend\n",
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let output = profile::extract(&document, Profile::Espalier);
        let methods = MethodIndex::new(&output.methods);
        let points = flow_points(&output, &methods);
        let calls = output
            .calls
            .iter()
            .filter(|call| call.message == "size")
            .collect::<Vec<_>>();

        assert_eq!(calls.len(), 2);
        assert!(!correlation_calls_share_reaching_value(&calls, &points));
    }

    #[test]
    fn canonical_candidate_group_seeds_dispatch_catalog_for_cfg_dfg_inference() {
        let directory = tempfile::tempdir().expect("directory");
        let file = directory.path().join("worker.rb");
        std::fs::write(
            &file,
            "class Worker\n  def run(left, right)\n    left.to_s + right.to_s\n  end\nend\n",
        )
        .expect("source");
        let document = syntax::parse_file(file.clone(), Language::Ruby).expect("parse");
        let mut overlay_profile = profile::extract(&document, Profile::Espalier);
        let plan_profile = profile::extract(&document, Profile::TracePlan);
        let built = runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            std::slice::from_ref(&file),
            directory.path(),
        )
        .expect("plan");
        let candidates = built
            .bindings
            .iter()
            .filter_map(|(anchor, binding)| match binding {
                AnchorBinding::Call { call_id }
                    if overlay_profile
                        .calls
                        .iter()
                        .find(|call| call.id == *call_id)
                        .is_some_and(|call| call.message == "to_s") =>
                {
                    Some(anchor.clone())
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(candidates.len(), 2);
        let run_id = "run-1".to_string();
        let runtime_values = runtime_protocol::ValueSet {
            alternatives: vec![runtime_protocol::WeightedValue {
                value: MessageField::some(runtime_protocol::RuntimeValue {
                    type_symbol: "nil-kill-runtime ruby ruby 3.2.3 String#".to_string(),
                    source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::PRODUCTION),
                    ..runtime_protocol::RuntimeValue::default()
                }),
                count: 1,
                ..runtime_protocol::WeightedValue::default()
            }],
            ..runtime_protocol::ValueSet::default()
        };
        let anchors = built
            .plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                let candidate = candidates.contains(&anchor.symbol);
                let parameter = matches!(
                    built.bindings.get(&anchor.symbol),
                    Some(AnchorBinding::Parameter { .. })
                );
                runtime_protocol::AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(runtime_protocol::CaptureSummary {
                        status: EnumOrUnknown::new(if candidate {
                            CaptureStatus::PARTIAL
                        } else if parameter {
                            CaptureStatus::COMPLETE_FOR_RUNS
                        } else {
                            CaptureStatus::NOT_EXECUTED
                        }),
                        run_ids: vec![run_id.clone()],
                        observed_executions: u64::from(parameter),
                        reason: if candidate {
                            "execution is represented by a candidate group".to_string()
                        } else if parameter {
                            String::new()
                        } else {
                            "anchor did not execute in the modeled run".to_string()
                        },
                        complete_kinds: if candidate {
                            Vec::new()
                        } else {
                            request.required.clone()
                        },
                        ..runtime_protocol::CaptureSummary::default()
                    }),
                    executions: parameter
                        .then(|| runtime_protocol::ExecutionBucket {
                            count: 1,
                            value: MessageField::some(runtime_values.clone()),
                            provenance: MessageField::some(runtime_protocol::Provenance {
                                run_id: run_id.clone(),
                                provider: "ruby-tracepoint".to_string(),
                                provider_version: "1".to_string(),
                                ..runtime_protocol::Provenance::default()
                            }),
                            ..runtime_protocol::ExecutionBucket::default()
                        })
                        .into_iter()
                        .collect(),
                    ..runtime_protocol::AnchorEvidence::default()
                }
            })
            .collect();
        let evidence = runtime_protocol::RuntimeEvidence {
            protocol_version: runtime_protocol::PROTOCOL_VERSION,
            producer: MessageField::some(runtime_protocol::ToolInfo {
                name: "nil-kill".to_string(),
                version: "1".to_string(),
                ..runtime_protocol::ToolInfo::default()
            }),
            authority: EnumOrUnknown::new(runtime_protocol::Authority::MODELED_RUNS),
            trace_plan_digest: built.plan.plan_digest.clone(),
            runs: vec![runtime_protocol::Run {
                id: run_id.clone(),
                status: EnumOrUnknown::new(runtime_protocol::RunStatus::SUCCEEDED),
                ..runtime_protocol::Run::default()
            }],
            anchors,
            correlations: vec![runtime_protocol::CorrelationEvidence {
                group_id: "distinct-parameter-to-s".to_string(),
                candidate_anchor_symbols: candidates,
                capture: MessageField::some(runtime_protocol::CaptureSummary {
                    status: EnumOrUnknown::new(CaptureStatus::COMPLETE_FOR_RUNS),
                    run_ids: vec![run_id.clone()],
                    observed_executions: 2,
                    complete_kinds: vec![
                        EnumOrUnknown::new(EvidenceKind::RECEIVER_VALUE),
                        EnumOrUnknown::new(EvidenceKind::CALL_TARGET),
                    ],
                    ..runtime_protocol::CaptureSummary::default()
                }),
                executions: vec![runtime_protocol::ExecutionBucket {
                    count: 2,
                    receiver: MessageField::some(runtime_values),
                    target: MessageField::some(runtime_protocol::RuntimeTarget {
                        symbol: "nil-kill-runtime ruby ruby 3.2.3 String#to_s().".to_string(),
                        source_role: EnumOrUnknown::new(
                            runtime_protocol::SourceRole::STANDARD_LIBRARY,
                        ),
                        package_manager: "ruby".to_string(),
                        package_name: "ruby".to_string(),
                        package_version: "3.2.3".to_string(),
                        ..runtime_protocol::RuntimeTarget::default()
                    }),
                    provenance: MessageField::some(runtime_protocol::Provenance {
                        run_id,
                        provider: "ruby-tracepoint".to_string(),
                        provider_version: "1".to_string(),
                        ..runtime_protocol::Provenance::default()
                    }),
                    ..runtime_protocol::ExecutionBucket::default()
                }],
                ..runtime_protocol::CorrelationEvidence::default()
            }],
            ..runtime_protocol::RuntimeEvidence::default()
        };

        apply_protocol_to_profile(&mut overlay_profile, &built, &evidence).expect("overlay");
        let calls = overlay_profile
            .calls
            .iter()
            .filter(|call| call.message == "to_s")
            .collect::<Vec<_>>();
        assert_eq!(calls.len(), 2);
        assert!(calls.iter().all(|call| {
            call.receiver_type.as_deref() == Some("String")
                && call.semantic_symbol.as_deref()
                    == Some("nil-kill-runtime ruby ruby 3.2.3 String#to_s().")
                && !call.runtime_evidence_observed
        }));
    }

    #[test]
    fn cfg_dfg_projects_an_exact_parser_result_through_nested_hash_dispatch() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            b"class Worker\n  def run(payload)\n    data = JSON.parse(payload)\n    data[\"coverage\"].is_a?(Hash)\n  end\nend\n",
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
                        "kind": "instance", "line": 2
                    },
                    "callsite": {"path": path, "line": 3, "selector": "parse"},
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby json 2 JSON.parse().",
                        "owner": "JSON", "name": "parse", "kind": "class",
                        "receiver_type": "JSON"
                    }],
                    "result_domain": {
                        "types": ["Hash"],
                        "keys": ["String"],
                        "values": ["Hash"],
                        "shapes": [{
                            "kind": "hash",
                            "keys": [{"kind": "class", "name": "String"}],
                            "values": [{"kind": "class", "name": "Hash"}]
                        }]
                    },
                    "count": 1
                }],
                "target_catalog": [{
                    "language": "ruby",
                    "selector": "[]",
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Hash#`[]`().",
                        "owner": "Hash", "name": "[]", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {"types": ["Hash"]}
                }, {
                    "language": "ruby",
                    "selector": "is_a?",
                    "targets": [{
                        "symbol": "nil-kill-runtime ruby ruby 3.2.3 Kernel#`is_a?`().",
                        "owner": "Kernel", "name": "is_a?", "kind": "instance",
                        "receiver_type": "Hash"
                    }],
                    "receiver_domain": {"types": ["Hash"]}
                }]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let index = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "[]")
            .expect("hash index");
        assert_eq!(
            index.receiver_type.as_deref(),
            Some("Hash"),
            "calls={:#?}\nflow={:#?}",
            output.calls,
            output.flow_local_types
        );
        assert_eq!(
            index.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 Hash#`[]`().")
        );
        let type_check = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "is_a?")
            .expect("nested type check");
        assert_eq!(type_check.receiver_type.as_deref(), Some("Hash"));
        assert_eq!(
            type_check.semantic_symbol.as_deref(),
            Some("nil-kill-runtime ruby ruby 3.2.3 Kernel#`is_a?`().")
        );
    }

    #[test]
    fn cfg_dfg_projects_call_results_through_destructured_assignments() {
        let mut file = tempfile::NamedTempFile::new().expect("source");
        file.write_all(
            b"class Worker\n  def run(spec)\n    left, right = spec.to_s.split(\":\", 2)\n    left.to_s + right.to_s\n  end\nend\n",
        )
        .expect("write");
        let document =
            syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("parse");
        let mut output = profile::extract(&document, Profile::Espalier);
        let path = file.path().to_string_lossy();
        let target = |name: &str, receiver_type: &str| {
            json!({
                "symbol": format!(
                    "nil-kill-runtime ruby ruby 3.2.3 {receiver_type}#{name}()."
                ),
                "owner": receiver_type,
                "name": name,
                "kind": "instance",
                "receiver_type": receiver_type
            })
        };
        let evidence = RuntimeValueEvidence::from_json(
            &json!({
                "schema": SCHEMA,
                "authority": "runtime-modeled-world",
                "observations": [{
                    "kind": "parameter",
                    "scope": {
                        "language": "ruby", "path": path,
                        "owner": "Worker", "function": "run", "line": 2
                    },
                    "slot": "spec",
                    "domain": {"types": ["String"]},
                    "count": 1
                }],
                "target_catalog": [
                    {
                        "language": "ruby",
                        "selector": "to_s",
                        "targets": [target("to_s", "String")],
                        "receiver_domain": {"types": ["String"]}
                    },
                    {
                        "language": "ruby",
                        "selector": "split",
                        "targets": [target("split", "String")],
                        "receiver_domain": {"types": ["String"]}
                    }
                ]
            })
            .to_string(),
        )
        .expect("evidence");

        apply_to_profile(&mut output, &evidence).expect("overlay");
        let destructured_calls = output
            .calls
            .iter()
            .filter(|call| {
                call.line == 4
                    && call.message == "to_s"
                    && matches!(call.receiver.as_str(), "left" | "right")
            })
            .collect::<Vec<_>>();
        assert_eq!(destructured_calls.len(), 2);
        assert!(
            destructured_calls.iter().all(|call| {
                call.receiver_type.as_deref() == Some("String")
                    && call.semantic_symbol.as_deref()
                        == Some("nil-kill-runtime ruby ruby 3.2.3 String#to_s().")
            }),
            "{destructured_calls:#?}"
        );
    }

    #[test]
    fn canonical_parameter_shape_costs_a_callback_hash_writer() {
        let directory = tempfile::tempdir().expect("directory");
        let file = directory.path().join("worker.rb");
        std::fs::write(
            &file,
            "class Worker\n  def run(rows)\n    rows.each { |row| row[\"seen\"] = true }\n  end\nend\n",
        )
        .expect("source");
        let document = syntax::parse_file(file.clone(), Language::Ruby).expect("parse");
        let mut overlay_profile = profile::extract(&document, Profile::Espalier);
        let plan_profile = profile::extract(&document, Profile::TracePlan);
        let built = runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            std::slice::from_ref(&file),
            directory.path(),
        )
        .expect("plan");
        let parameter_anchor = built
            .bindings
            .iter()
            .find_map(|(anchor, binding)| match binding {
                AnchorBinding::Parameter { name, .. } if name == "rows" => Some(anchor.clone()),
                _ => None,
            })
            .expect("rows parameter anchor");
        let runtime_value = |name: &str| runtime_protocol::RuntimeValue {
            type_symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {name}#"),
            source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::PRODUCTION),
            ..runtime_protocol::RuntimeValue::default()
        };
        let mut array = runtime_value("Array");
        array.shape = Some(runtime_value::Shape::Sequence(
            runtime_protocol::SequenceShape {
                elements: MessageField::some(runtime_protocol::ValueSet {
                    alternatives: vec![runtime_protocol::WeightedValue {
                        value: MessageField::some(runtime_value("Hash")),
                        count: 1,
                        ..runtime_protocol::WeightedValue::default()
                    }],
                    ..runtime_protocol::ValueSet::default()
                }),
                ..runtime_protocol::SequenceShape::default()
            },
        ));
        let run_id = "run-1".to_string();
        let anchors = built
            .plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                let selected = anchor.symbol == parameter_anchor;
                runtime_protocol::AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(runtime_protocol::CaptureSummary {
                        status: EnumOrUnknown::new(if selected {
                            CaptureStatus::COMPLETE_FOR_RUNS
                        } else {
                            CaptureStatus::NOT_EXECUTED
                        }),
                        run_ids: vec![run_id.clone()],
                        observed_executions: u64::from(selected),
                        reason: (!selected)
                            .then(|| "anchor did not execute in the modeled run".to_string())
                            .unwrap_or_default(),
                        complete_kinds: request.required.clone(),
                        ..runtime_protocol::CaptureSummary::default()
                    }),
                    executions: selected
                        .then(|| runtime_protocol::ExecutionBucket {
                            count: 1,
                            value: MessageField::some(runtime_protocol::ValueSet {
                                alternatives: vec![runtime_protocol::WeightedValue {
                                    value: MessageField::some(array.clone()),
                                    count: 1,
                                    ..runtime_protocol::WeightedValue::default()
                                }],
                                ..runtime_protocol::ValueSet::default()
                            }),
                            provenance: MessageField::some(runtime_protocol::Provenance {
                                run_id: run_id.clone(),
                                provider: "ruby-tracepoint".to_string(),
                                provider_version: "1".to_string(),
                                ..runtime_protocol::Provenance::default()
                            }),
                            ..runtime_protocol::ExecutionBucket::default()
                        })
                        .into_iter()
                        .collect(),
                    ..runtime_protocol::AnchorEvidence::default()
                }
            })
            .collect();
        let evidence = runtime_protocol::RuntimeEvidence {
            protocol_version: runtime_protocol::PROTOCOL_VERSION,
            producer: MessageField::some(runtime_protocol::ToolInfo {
                name: "nil-kill".to_string(),
                version: "1".to_string(),
                ..runtime_protocol::ToolInfo::default()
            }),
            authority: EnumOrUnknown::new(runtime_protocol::Authority::MODELED_RUNS),
            trace_plan_digest: built.plan.plan_digest.clone(),
            runs: vec![runtime_protocol::Run {
                id: run_id,
                status: EnumOrUnknown::new(runtime_protocol::RunStatus::SUCCEEDED),
                ..runtime_protocol::Run::default()
            }],
            anchors,
            ..runtime_protocol::RuntimeEvidence::default()
        };

        apply_protocol_to_profile(&mut overlay_profile, &built, &evidence).expect("overlay");
        let writer = overlay_profile
            .calls
            .iter()
            .find(|call| call.receiver == "row" && call.message == "[]=")
            .expect("callback hash writer");
        assert_eq!(writer.receiver_type.as_deref(), Some("Hash"));
        assert_eq!(writer.known_time_complexity.as_deref(), Some("O(1)"));
        assert_eq!(writer.known_space_complexity.as_deref(), Some("O(1)"));
    }

    #[test]
    fn canonical_execution_buckets_preserve_receiver_target_correlation() {
        let directory = tempfile::tempdir().expect("directory");
        let file = directory.path().join("worker.rb");
        std::fs::write(
            &file,
            "class Worker\n  def run(value)\n    value.size\n  end\nend\n",
        )
        .expect("source");
        let document = syntax::parse_file(file.clone(), Language::Ruby).expect("parse");
        let profile = profile::extract(&document, Profile::TracePlan);
        let built = runtime_protocol::build_trace_plan_with_bindings(
            &profile,
            std::slice::from_ref(&file),
            directory.path(),
        )
        .expect("plan");
        let call_anchor = built
            .bindings
            .iter()
            .find_map(|(anchor, binding)| {
                matches!(binding, AnchorBinding::Call { .. }).then(|| anchor.clone())
            })
            .expect("call anchor");
        let value_set = |name: &str| runtime_protocol::ValueSet {
            alternatives: vec![runtime_protocol::WeightedValue {
                value: MessageField::some(runtime_protocol::RuntimeValue {
                    type_symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {name}#"),
                    source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::PRODUCTION),
                    ..runtime_protocol::RuntimeValue::default()
                }),
                count: 1,
                ..runtime_protocol::WeightedValue::default()
            }],
            ..runtime_protocol::ValueSet::default()
        };
        let bucket = |receiver: &str| runtime_protocol::ExecutionBucket {
            count: 1,
            receiver: MessageField::some(value_set(receiver)),
            target: MessageField::some(runtime_protocol::RuntimeTarget {
                symbol: format!("nil-kill-runtime ruby ruby 3.2.3 {receiver}#size()."),
                source_role: EnumOrUnknown::new(runtime_protocol::SourceRole::STANDARD_LIBRARY),
                package_manager: "ruby".to_string(),
                package_name: "ruby".to_string(),
                package_version: "3.2.3".to_string(),
                ..runtime_protocol::RuntimeTarget::default()
            }),
            provenance: MessageField::some(runtime_protocol::Provenance {
                run_id: "run-1".to_string(),
                provider: "ruby-tracepoint".to_string(),
                provider_version: "1".to_string(),
                ..runtime_protocol::Provenance::default()
            }),
            ..runtime_protocol::ExecutionBucket::default()
        };
        let anchors = built
            .plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                let selected = anchor.symbol == call_anchor;
                runtime_protocol::AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(runtime_protocol::CaptureSummary {
                        status: EnumOrUnknown::new(if selected {
                            CaptureStatus::COMPLETE_FOR_RUNS
                        } else {
                            CaptureStatus::NOT_EXECUTED
                        }),
                        run_ids: vec!["run-1".to_string()],
                        observed_executions: if selected { 2 } else { 0 },
                        reason: (!selected)
                            .then(|| "anchor did not execute in the modeled run".to_string())
                            .unwrap_or_default(),
                        complete_kinds: request.required.clone(),
                        ..runtime_protocol::CaptureSummary::default()
                    }),
                    executions: if selected {
                        vec![bucket("String"), bucket("Array")]
                    } else {
                        Vec::new()
                    },
                    ..runtime_protocol::AnchorEvidence::default()
                }
            })
            .collect();
        let evidence = runtime_protocol::RuntimeEvidence {
            protocol_version: runtime_protocol::PROTOCOL_VERSION,
            producer: MessageField::some(runtime_protocol::ToolInfo {
                name: "nil-kill".to_string(),
                version: "1".to_string(),
                ..runtime_protocol::ToolInfo::default()
            }),
            authority: EnumOrUnknown::new(runtime_protocol::Authority::MODELED_RUNS),
            trace_plan_digest: built.plan.plan_digest.clone(),
            runs: vec![runtime_protocol::Run {
                id: "run-1".to_string(),
                status: EnumOrUnknown::new(runtime_protocol::RunStatus::SUCCEEDED),
                ..runtime_protocol::Run::default()
            }],
            anchors,
            ..runtime_protocol::RuntimeEvidence::default()
        };
        runtime_protocol::validate_runtime_evidence(&built.plan, &evidence).expect("valid");
        let facts = protocol_evidence(&profile, &built, &evidence).expect("facts");
        let correlated = facts
            .calls
            .iter()
            .map(|call| {
                (
                    call.receiver_domain
                        .as_ref()
                        .expect("receiver")
                        .types
                        .iter()
                        .next()
                        .expect("type")
                        .clone(),
                    call.targets[0].symbol.clone(),
                )
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(
            correlated,
            BTreeSet::from([
                (
                    "Array".to_string(),
                    "nil-kill-runtime ruby ruby 3.2.3 Array#size().".to_string(),
                ),
                (
                    "String".to_string(),
                    "nil-kill-runtime ruby ruby 3.2.3 String#size().".to_string(),
                ),
            ])
        );
    }
}
