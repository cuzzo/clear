//! Canonical Runtime Semantic Evidence protocol.
//!
//! The generated messages are the only accepted wire contract shared with
//! runtime collectors. Semantic validation lives here; source/CFG inference
//! belongs to the runtime evidence overlay.

#[allow(
    dead_code,
    missing_docs,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    trivial_casts,
    unused_attributes,
    unused_mut,
    unused_results
)]
mod generated {
    include!(concat!(
        env!("OUT_DIR"),
        "/runtime_evidence_protocol_embedded.rs"
    ));
}

pub use generated::*;

use anyhow::{bail, Context, Result};
use flate2::read::GzDecoder;
use protobuf::{Enum, Message, MessageField};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Read;
use std::path::{Component, Path};

pub const PROTOCOL_VERSION: u32 = 1;

/// The exact normalized entity named by a trace-plan anchor.
///
/// This table is deliberately not serialized. FactMine regenerates it from
/// the same source snapshot before consuming evidence and refuses evidence
/// whose plan digest differs. Runtime collectors therefore never need to
/// reproduce FactMine IDs or source matching rules.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AnchorBinding {
    Parameter {
        method_id: String,
        ordinal: usize,
        name: String,
    },
    Return {
        method_id: String,
    },
    Call {
        call_id: String,
    },
    State {
        access_id: String,
    },
}

#[derive(Clone, Debug)]
pub struct BuiltTracePlan {
    pub plan: TracePlan,
    pub bindings: BTreeMap<String, AnchorBinding>,
}

pub fn build_trace_plan(
    profile: &crate::profile::ProfileOutput,
    files: &[std::path::PathBuf],
    root: &Path,
) -> Result<TracePlan> {
    Ok(build_trace_plan_with_bindings(profile, files, root)?.plan)
}

pub fn build_trace_plan_with_bindings(
    profile: &crate::profile::ProfileOutput,
    files: &[std::path::PathBuf],
    root: &Path,
) -> Result<BuiltTracePlan> {
    let root = root
        .canonicalize()
        .with_context(|| format!("failed to canonicalize trace-plan root {}", root.display()))?;
    let mut documents = Vec::new();
    let mut path_lookup = BTreeMap::<String, String>::new();
    for file in files {
        let absolute = if file.is_absolute() {
            file.clone()
        } else {
            root.join(file)
        }
        .canonicalize()
        .with_context(|| format!("failed to canonicalize trace-plan input {}", file.display()))?;
        let relative = absolute
            .strip_prefix(&root)
            .with_context(|| {
                format!(
                    "trace-plan input {} is outside project root {}",
                    absolute.display(),
                    root.display()
                )
            })?
            .to_string_lossy()
            .replace('\\', "/");
        validate_relative_path(&relative, "trace-plan input")?;
        let bytes = fs::read(&absolute)
            .with_context(|| format!("failed to read trace-plan input {}", absolute.display()))?;
        let language = crate::syntax::Language::for_path(&absolute)
            .with_context(|| format!("cannot detect language for {}", absolute.display()))?;
        documents.push(PlannedDocument {
            relative_path: relative.clone(),
            language: language.as_str().to_string(),
            position_encoding: PositionEncoding::UTF8_CODE_UNIT_OFFSET_FROM_LINE_START.into(),
            content_sha256: Sha256::digest(bytes).to_vec(),
            ..PlannedDocument::default()
        });
        path_lookup.insert(normalize_profile_path(file), relative.clone());
        path_lookup.insert(normalize_profile_path(&absolute), relative);
    }
    documents.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    documents.dedup_by(|left, right| left.relative_path == right.relative_path);

    let methods = profile
        .methods
        .iter()
        .map(|method| (method.id.as_str(), method))
        .collect::<BTreeMap<_, _>>();
    let result_sites = profile
        .runtime_result_call_sites
        .iter()
        .map(|site| (normalized_plan_path(&site.path, &path_lookup), site.span))
        .collect::<BTreeSet<_>>();
    let collection_sites = profile
        .runtime_collection_receiver_sites
        .iter()
        .map(|site| (normalized_plan_path(&site.path, &path_lookup), site.span))
        .collect::<BTreeSet<_>>();
    let predicate_calls = profile
        .runtime_capability_guards
        .iter()
        .map(|guard| guard.condition_call_id.as_str())
        .collect::<BTreeSet<_>>();
    let call_ordinals = stable_ordinals(
        profile
            .calls
            .iter()
            .map(|call| (call.source.as_str(), call.id.as_str(), call.span)),
    );
    let state_ordinals = stable_ordinals(
        profile
            .state_accesses
            .iter()
            .map(|access| (access.function_id.as_str(), access.id.as_str(), access.span)),
    );

    let mut requests = Vec::new();
    let mut bindings = BTreeMap::new();
    for method in profile
        .methods
        .iter()
        .filter(|method| method.source_export_eligible && !method.generated_declaration)
    {
        let relative_path = normalized_plan_path(&method.path, &path_lookup);
        let span = method.span.unwrap_or([method.line, 0, method.line, 0]);
        let enclosing_symbol = plan_method_symbol(method, &relative_path);
        let method_anchor_id = stable_id(&format!(
            "{}\0{}\0{}\0{}",
            relative_path, method.owner, method.name, method.kind
        ));
        for (ordinal, parameter) in method.params.iter().enumerate() {
            let anchor = plan_anchor(
                &format!("param-{method_anchor_id}-{ordinal}"),
                &relative_path,
                span,
                AnchorKind::FUNCTION_ENTRY,
                &enclosing_symbol,
                &format!(
                    "{}\0parameter\0{ordinal}\0{parameter}",
                    method.normalized_source
                ),
                parameter,
            );
            bindings.insert(
                anchor.symbol.clone(),
                AnchorBinding::Parameter {
                    method_id: method.id.clone(),
                    ordinal,
                    name: parameter.clone(),
                },
            );
            requests.push(EvidenceRequest {
                anchor: MessageField::some(anchor),
                required: vec![EvidenceKind::PARAMETER_VALUE.into()],
                parameter_ordinal: Some(ordinal as u32),
                ..EvidenceRequest::default()
            });
        }
        let anchor = plan_anchor(
            &format!("return-{method_anchor_id}"),
            &relative_path,
            span,
            AnchorKind::FUNCTION_RETURN,
            &enclosing_symbol,
            &format!("{}\0return", method.normalized_source),
            "return",
        );
        bindings.insert(
            anchor.symbol.clone(),
            AnchorBinding::Return {
                method_id: method.id.clone(),
            },
        );
        requests.push(EvidenceRequest {
            anchor: MessageField::some(anchor),
            required: vec![EvidenceKind::RETURN_VALUE.into()],
            ..EvidenceRequest::default()
        });
    }

    for call in &profile.calls {
        let Some(method) = methods.get(call.source.as_str()) else {
            continue;
        };
        let relative_path = normalized_plan_path(&call.path, &path_lookup);
        let needs_result = result_sites.contains(&(relative_path.clone(), call.span));
        let needs_collection = collection_sites.contains(&(relative_path.clone(), call.span));
        let needs_predicate = predicate_calls.contains(call.id.as_str());
        let unresolved = call.target.is_none() && call.semantic_symbol.is_none();
        if !unresolved && !needs_result && !needs_collection && !needs_predicate {
            continue;
        }
        let mut required = vec![EvidenceKind::RECEIVER_VALUE, EvidenceKind::CALL_TARGET];
        if needs_result {
            required.push(EvidenceKind::RESULT_VALUE);
        }
        if needs_collection {
            required.push(EvidenceKind::COLLECTION_VALUE);
        }
        if needs_predicate {
            required.push(EvidenceKind::BOOLEAN_RESULT);
        }
        required.sort_by_key(|kind| kind.value());
        required.dedup();
        let selector_span = call.selector_span.unwrap_or(call.span);
        let enclosing_symbol = plan_method_symbol(method, &relative_path);
        let ordinal = call_ordinals.get(call.id.as_str()).copied().unwrap_or(0);
        let method_anchor_id = stable_id(&format!(
            "{}\0{}\0{}\0{}",
            relative_path, method.owner, method.name, method.kind
        ));
        let anchor = plan_anchor(
            &format!("call-{method_anchor_id}-{ordinal}"),
            &relative_path,
            selector_span,
            if needs_predicate {
                AnchorKind::BRANCH_PREDICATE
            } else if needs_collection {
                AnchorKind::COLLECTION_OPERATION
            } else {
                AnchorKind::CALL_SELECTOR
            },
            &enclosing_symbol,
            &format!(
                "{}\0call\0{ordinal}\0{}\0{}",
                method.normalized_source, call.receiver, call.message
            ),
            &call.message,
        );
        bindings.insert(
            anchor.symbol.clone(),
            AnchorBinding::Call {
                call_id: call.id.clone(),
            },
        );
        requests.push(EvidenceRequest {
            anchor: MessageField::some(anchor),
            required: required.into_iter().map(Into::into).collect(),
            execution_range: MessageField::some(plan_source_range(
                call.execution_span.unwrap_or(call.span),
            )),
            ..EvidenceRequest::default()
        });
    }

    for access in profile
        .state_accesses
        .iter()
        .filter(|access| access.kind.contains("write"))
    {
        let Some(method) = methods.get(access.function_id.as_str()) else {
            continue;
        };
        let relative_path = normalized_plan_path(&access.path, &path_lookup);
        let ordinal = state_ordinals.get(access.id.as_str()).copied().unwrap_or(0);
        let method_anchor_id = stable_id(&format!(
            "{}\0{}\0{}\0{}",
            relative_path, method.owner, method.name, method.kind
        ));
        let anchor = plan_anchor(
            &format!("state-{method_anchor_id}-{ordinal}"),
            &relative_path,
            access.span,
            AnchorKind::STATE_WRITE,
            &plan_method_symbol(method, &relative_path),
            &format!(
                "{}\0state\0{ordinal}\0{}",
                method.normalized_source, access.field
            ),
            &access.field,
        );
        bindings.insert(
            anchor.symbol.clone(),
            AnchorBinding::State {
                access_id: access.id.clone(),
            },
        );
        requests.push(EvidenceRequest {
            anchor: MessageField::some(anchor),
            required: vec![EvidenceKind::STATE_VALUE.into()],
            ..EvidenceRequest::default()
        });
    }

    requests.sort_by(|left, right| {
        let left = left.anchor.as_ref().expect("constructed anchor");
        let right = right.anchor.as_ref().expect("constructed anchor");
        (&left.relative_path, &left.symbol).cmp(&(&right.relative_path, &right.symbol))
    });
    let mut plan = TracePlan {
        protocol_version: PROTOCOL_VERSION,
        producer: MessageField::some(ToolInfo {
            name: "fact-mine-rust".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            arguments: vec!["runtime-plan".to_string()],
            ..ToolInfo::default()
        }),
        project_root: format!("file://{}", root.to_string_lossy()),
        documents,
        requests,
        ..TracePlan::default()
    };
    plan.plan_digest = trace_plan_digest(&plan)?;
    validate_trace_plan(&plan)?;
    if plan.requests.len() != bindings.len() {
        bail!(
            "trace plan contains {} requests but {} exact bindings",
            plan.requests.len(),
            bindings.len()
        );
    }
    Ok(BuiltTracePlan { plan, bindings })
}

fn plan_anchor(
    id: &str,
    relative_path: &str,
    span: [usize; 4],
    kind: AnchorKind,
    enclosing_symbol: &str,
    semantic_source: &str,
    display_name: &str,
) -> SourceAnchor {
    SourceAnchor {
        symbol: format!("local {id}"),
        relative_path: relative_path.to_string(),
        range: MessageField::some(plan_source_range(span)),
        kind: kind.into(),
        enclosing_symbol: enclosing_symbol.to_string(),
        semantic_digest: Sha256::digest(semantic_source.as_bytes()).to_vec(),
        display_name: display_name.to_string(),
        ..SourceAnchor::default()
    }
}

fn plan_source_range(span: [usize; 4]) -> SourceRange {
    SourceRange {
        start_line: span[0].saturating_sub(1) as u32,
        start_character: span[1] as u32,
        end_line: span[2].saturating_sub(1) as u32,
        end_character: span[3] as u32,
        ..SourceRange::default()
    }
}

fn plan_method_symbol(method: &crate::profile::MethodRecord, relative_path: &str) -> String {
    method.semantic_symbol.clone().unwrap_or_else(|| {
        format!(
            "fact-mine workspace project . Method#{}().",
            stable_id(&format!(
                "{}\0{}\0{}\0{}",
                relative_path, method.owner, method.name, method.kind
            ))
        )
    })
}

fn stable_id(value: &str) -> String {
    Sha256::digest(value.as_bytes())[..12]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn stable_ordinals<'a>(
    rows: impl Iterator<Item = (&'a str, &'a str, [usize; 4])>,
) -> BTreeMap<&'a str, usize> {
    let mut grouped = BTreeMap::<&str, Vec<(&str, [usize; 4])>>::new();
    for (source, id, span) in rows {
        grouped.entry(source).or_default().push((id, span));
    }
    let mut ordinals = BTreeMap::new();
    for rows in grouped.values_mut() {
        rows.sort_by_key(|(_, span)| *span);
        for (ordinal, (id, _)) in rows.iter().enumerate() {
            ordinals.insert(*id, ordinal);
        }
    }
    ordinals
}

fn normalize_profile_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn normalized_plan_path(path: &str, lookup: &BTreeMap<String, String>) -> String {
    lookup
        .get(&path.replace('\\', "/"))
        .cloned()
        .unwrap_or_else(|| path.replace('\\', "/").trim_start_matches("./").to_string())
}

pub fn parse_trace_plan_json(json: &str) -> Result<TracePlan> {
    let plan = protobuf_json_mapping::parse_from_str(json)
        .context("trace plan is not valid canonical ProtoJSON")?;
    validate_trace_plan(&plan)?;
    Ok(plan)
}

pub fn parse_runtime_evidence_json(json: &str) -> Result<RuntimeEvidence> {
    let evidence = protobuf_json_mapping::parse_from_str(json)
        .context("runtime evidence is not valid canonical ProtoJSON")?;
    validate_runtime_evidence_shape(&evidence)?;
    Ok(evidence)
}

pub fn read_trace_plan(path: &Path) -> Result<TracePlan> {
    parse_trace_plan_json(&read_json(path)?)
        .with_context(|| format!("invalid trace plan {}", path.display()))
}

pub fn read_runtime_evidence(path: &Path) -> Result<RuntimeEvidence> {
    parse_runtime_evidence_json(&read_json(path)?)
        .with_context(|| format!("invalid runtime evidence {}", path.display()))
}

/// The producer's encoding: every field present, including defaults, so a
/// consumer never has to distinguish "absent" from "zero".
pub fn to_json_with_defaults(message: &dyn protobuf::MessageDyn) -> Result<String> {
    protobuf_json_mapping::print_to_string_with_options(
        message,
        &protobuf_json_mapping::PrintOptions {
            enum_values_int: false,
            proto_field_name: true,
            always_output_default_values: true,
            _future_options: (),
        },
    )
    .context("failed to encode canonical ProtoJSON")
}

pub fn to_json(message: &dyn protobuf::MessageDyn) -> Result<String> {
    protobuf_json_mapping::print_to_string_with_options(
        message,
        &protobuf_json_mapping::PrintOptions {
            enum_values_int: false,
            proto_field_name: true,
            always_output_default_values: false,
            _future_options: (),
        },
    )
    .context("failed to encode canonical ProtoJSON")
}

pub fn read_json(path: &Path) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    if bytes.starts_with(&[0x1f, 0x8b]) {
        let mut decoded = String::new();
        GzDecoder::new(bytes.as_slice())
            .read_to_string(&mut decoded)
            .with_context(|| format!("failed to decompress {}", path.display()))?;
        Ok(decoded)
    } else {
        String::from_utf8(bytes)
            .with_context(|| format!("{} is not valid UTF-8 ProtoJSON", path.display()))
    }
}

pub fn trace_plan_digest(plan: &TracePlan) -> Result<Vec<u8>> {
    let mut canonical = plan.clone();
    canonical.plan_digest.clear();
    Ok(Sha256::digest(canonical.write_to_bytes()?).to_vec())
}

pub fn validate_trace_plan(plan: &TracePlan) -> Result<()> {
    if plan.protocol_version != PROTOCOL_VERSION {
        bail!(
            "trace plan protocol_version must be {PROTOCOL_VERSION}, got {}",
            plan.protocol_version
        );
    }
    validate_tool(plan.producer.as_ref(), "trace plan producer")?;
    if plan.project_root.is_empty() {
        bail!("trace plan project_root must not be empty");
    }
    if plan.documents.is_empty() {
        bail!("trace plan must contain at least one document");
    }

    let mut documents = BTreeMap::new();
    for (index, document) in plan.documents.iter().enumerate() {
        validate_relative_path(
            &document.relative_path,
            &format!("documents[{index}].relative_path"),
        )?;
        if document.language.is_empty() {
            bail!("documents[{index}].language must not be empty");
        }
        if document.position_encoding.enum_value_or_default()
            == PositionEncoding::POSITION_ENCODING_UNSPECIFIED
        {
            bail!("documents[{index}].position_encoding must be explicit");
        }
        if document.content_sha256.len() != 32 {
            bail!("documents[{index}].content_sha256 must contain 32 bytes");
        }
        if documents
            .insert(document.relative_path.as_str(), document)
            .is_some()
        {
            bail!("duplicate trace-plan document {:?}", document.relative_path);
        }
    }

    let mut anchors = BTreeSet::new();
    for (index, request) in plan.requests.iter().enumerate() {
        let anchor = request
            .anchor
            .as_ref()
            .with_context(|| format!("requests[{index}] requires an anchor"))?;
        validate_anchor(anchor, &documents, &format!("requests[{index}].anchor"))?;
        let call_anchor = matches!(
            anchor.kind.enum_value_or_default(),
            AnchorKind::CALL_SELECTOR
                | AnchorKind::COLLECTION_OPERATION
                | AnchorKind::BRANCH_PREDICATE
        );
        if call_anchor && request.execution_range.is_none() {
            bail!("requests[{index}].execution_range is required for a call anchor");
        }
        if let Some(execution_range) = request.execution_range.as_ref() {
            validate_range(
                Some(execution_range),
                &format!("requests[{index}].execution_range"),
            )?;
            let selector_range = anchor.range.as_ref().expect("validated anchor range");
            if (execution_range.start_line, execution_range.start_character)
                > (selector_range.start_line, selector_range.start_character)
                || (execution_range.end_line, execution_range.end_character)
                    < (selector_range.end_line, selector_range.end_character)
            {
                bail!("requests[{index}].execution_range must contain the complete anchor range");
            }
        }
        if !anchors.insert(anchor.symbol.as_str()) {
            bail!("duplicate trace-plan anchor {:?}", anchor.symbol);
        }
        if request.required.is_empty() {
            bail!("requests[{index}] must request at least one evidence kind");
        }
        let mut kinds = BTreeSet::new();
        for kind in &request.required {
            let kind = kind.enum_value().map_err(|value| {
                anyhow::anyhow!("requests[{index}] has unknown evidence kind {value}")
            })?;
            if kind == EvidenceKind::EVIDENCE_KIND_UNSPECIFIED {
                bail!("requests[{index}] contains an unspecified evidence kind");
            }
            if !kinds.insert(kind.value()) {
                bail!("requests[{index}] contains duplicate evidence kind {kind:?}");
            }
        }
        let allowed_kinds = allowed_evidence_kinds(anchor.kind.enum_value_or_default());
        if !kinds.iter().all(|kind| allowed_kinds.contains(kind)) {
            bail!(
                "requests[{index}] requests evidence incompatible with {:?}",
                anchor.kind.enum_value_or_default()
            );
        }
        if request.parameter_ordinal.is_some()
            && !kinds.contains(&EvidenceKind::PARAMETER_VALUE.value())
        {
            bail!("requests[{index}] has parameter_ordinal without PARAMETER_VALUE");
        }
        if let Some(activation) = request.activation_anchor.as_ref() {
            validate_anchor(
                activation,
                &documents,
                &format!("requests[{index}].activation_anchor"),
            )?;
        }
    }

    if plan.plan_digest.len() != 32 {
        bail!("trace plan plan_digest must contain 32 bytes");
    }
    if trace_plan_digest(plan)? != plan.plan_digest {
        bail!("trace plan plan_digest does not match its canonical contents");
    }
    Ok(())
}

fn allowed_evidence_kinds(kind: AnchorKind) -> BTreeSet<i32> {
    let kinds: &[EvidenceKind] = match kind {
        AnchorKind::FUNCTION_ENTRY | AnchorKind::CALLBACK_ENTRY => &[EvidenceKind::PARAMETER_VALUE],
        AnchorKind::FUNCTION_RETURN => &[EvidenceKind::RETURN_VALUE],
        AnchorKind::CALL_SELECTOR => &[
            EvidenceKind::RECEIVER_VALUE,
            EvidenceKind::CALL_TARGET,
            EvidenceKind::RESULT_VALUE,
        ],
        AnchorKind::STATE_READ | AnchorKind::STATE_WRITE => &[EvidenceKind::STATE_VALUE],
        AnchorKind::COLLECTION_OPERATION => &[
            EvidenceKind::RECEIVER_VALUE,
            EvidenceKind::CALL_TARGET,
            EvidenceKind::RESULT_VALUE,
            EvidenceKind::COLLECTION_VALUE,
        ],
        AnchorKind::BRANCH_PREDICATE => &[
            EvidenceKind::RECEIVER_VALUE,
            EvidenceKind::CALL_TARGET,
            EvidenceKind::RESULT_VALUE,
            EvidenceKind::BOOLEAN_RESULT,
        ],
        AnchorKind::ANCHOR_KIND_UNSPECIFIED => &[],
    };
    kinds.iter().map(|kind| kind.value()).collect()
}

pub fn validate_runtime_evidence(plan: &TracePlan, evidence: &RuntimeEvidence) -> Result<()> {
    validate_trace_plan(plan)?;
    validate_runtime_evidence_shape(evidence)?;
    if evidence.trace_plan_digest != plan.plan_digest {
        bail!("runtime evidence trace_plan_digest does not match the supplied trace plan");
    }

    let requests = plan
        .requests
        .iter()
        .map(|request| {
            let anchor = request.anchor.as_ref().expect("validated anchor");
            (anchor.symbol.as_str(), (request, anchor))
        })
        .collect::<BTreeMap<_, _>>();
    let mut observed = BTreeSet::new();
    for (index, anchor_evidence) in evidence.anchors.iter().enumerate() {
        let Some((request, anchor)) = requests.get(anchor_evidence.anchor_symbol.as_str()) else {
            bail!(
                "anchors[{index}] references unknown plan anchor {:?}",
                anchor_evidence.anchor_symbol
            );
        };
        if !observed.insert(anchor_evidence.anchor_symbol.as_str()) {
            bail!(
                "duplicate evidence for plan anchor {:?}",
                anchor_evidence.anchor_symbol
            );
        }
        if anchor_evidence.anchor_semantic_digest != anchor.semantic_digest {
            bail!(
                "anchors[{index}] semantic digest does not match {:?}",
                anchor_evidence.anchor_symbol
            );
        }
        validate_anchor_evidence(index, request, anchor_evidence, evidence)?;
    }
    let mut correlation_ids = BTreeSet::new();
    for (index, correlation) in evidence.correlations.iter().enumerate() {
        if !correlation_ids.insert(correlation.group_id.as_str()) {
            bail!(
                "duplicate runtime correlation group {:?}",
                correlation.group_id
            );
        }
        validate_correlation_evidence(index, correlation, &requests, evidence)?;
    }
    // An anchor with no entry was not executed in these runs. Requiring an
    // explicit entry for every planned anchor made a shard's evidence
    // proportional to the plan rather than to what it observed: a 682-byte
    // trace produced a 4.6MB document, almost all of it saying "nothing
    // happened here", and every stage downstream paid to write, read and merge
    // it. Absence carries the same claim at no cost.
    Ok(())
}

fn validate_runtime_evidence_shape(evidence: &RuntimeEvidence) -> Result<()> {
    if evidence.protocol_version != PROTOCOL_VERSION {
        bail!(
            "runtime evidence protocol_version must be {PROTOCOL_VERSION}, got {}",
            evidence.protocol_version
        );
    }
    validate_tool(evidence.producer.as_ref(), "runtime evidence producer")?;
    if evidence.authority.enum_value_or_default() != Authority::MODELED_RUNS {
        bail!("runtime evidence authority must be MODELED_RUNS");
    }
    if evidence.trace_plan_digest.len() != 32 {
        bail!("runtime evidence trace_plan_digest must contain 32 bytes");
    }
    let mut environment = BTreeSet::new();
    for (index, claim) in evidence.environment.iter().enumerate() {
        if claim.key.is_empty() || claim.value.is_empty() {
            bail!("environment[{index}] requires a non-empty key and value");
        }
        if !environment.insert(claim.key.as_str()) {
            bail!("duplicate runtime environment claim {:?}", claim.key);
        }
    }
    let mut runs = BTreeSet::new();
    for (index, run) in evidence.runs.iter().enumerate() {
        if run.id.is_empty() {
            bail!("runs[{index}].id must not be empty");
        }
        if !runs.insert(run.id.as_str()) {
            bail!("duplicate runtime run {:?}", run.id);
        }
        if run.status.enum_value_or_default() == RunStatus::RUN_STATUS_UNSPECIFIED {
            bail!("runs[{index}].status must be explicit");
        }
    }
    if evidence.runs.is_empty()
        && (!evidence.anchors.is_empty() || !evidence.correlations.is_empty())
    {
        bail!("runtime evidence with observations must declare at least one run");
    }
    Ok(())
}

fn validate_anchor_evidence(
    index: usize,
    request: &EvidenceRequest,
    evidence: &AnchorEvidence,
    bundle: &RuntimeEvidence,
) -> Result<()> {
    let context = format!("anchors[{index}]");
    let capture = evidence
        .capture
        .as_ref()
        .with_context(|| format!("{context} requires capture metadata"))?;
    let required = request
        .required
        .iter()
        .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
        .collect::<BTreeSet<_>>();
    validate_capture_and_buckets(&context, capture, &evidence.executions, &required, bundle)
}

fn validate_correlation_evidence(
    index: usize,
    evidence: &CorrelationEvidence,
    requests: &BTreeMap<&str, (&EvidenceRequest, &SourceAnchor)>,
    bundle: &RuntimeEvidence,
) -> Result<()> {
    let context = format!("correlations[{index}]");
    if evidence.group_id.is_empty() {
        bail!("{context} group_id must not be empty");
    }
    if evidence.candidate_anchor_symbols.len() < 2 {
        bail!("{context} requires at least two candidate anchors");
    }
    if evidence
        .candidate_anchor_symbols
        .windows(2)
        .any(|pair| pair[0] >= pair[1])
    {
        bail!("{context} candidate anchors must be unique and sorted");
    }
    let mut candidates = Vec::new();
    let mut required = BTreeSet::new();
    for symbol in &evidence.candidate_anchor_symbols {
        let Some((request, anchor)) = requests.get(symbol.as_str()) else {
            bail!("{context} references unknown plan anchor {symbol:?}");
        };
        if !matches!(
            anchor.kind.enum_value_or_default(),
            AnchorKind::CALL_SELECTOR
                | AnchorKind::COLLECTION_OPERATION
                | AnchorKind::BRANCH_PREDICATE
        ) {
            bail!("{context} candidate {symbol:?} is not a call anchor");
        }
        required.extend(
            request
                .required
                .iter()
                .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value())),
        );
        candidates.push(*anchor);
    }
    let first = candidates[0];
    if candidates.iter().any(|anchor| {
        anchor.relative_path != first.relative_path || anchor.display_name != first.display_name
    }) {
        bail!("{context} candidates must share a document and observed selector");
    }
    let latest_start = candidates
        .iter()
        .filter_map(|anchor| anchor.range.as_ref().map(|range| range.start_line))
        .max()
        .context("validated correlation candidate is missing a range")?;
    let earliest_end = candidates
        .iter()
        .filter_map(|anchor| anchor.range.as_ref().map(|range| range.end_line))
        .min()
        .context("validated correlation candidate is missing a range")?;
    if latest_start > earliest_end {
        bail!("{context} candidate source ranges do not overlap");
    }
    let capture = evidence
        .capture
        .as_ref()
        .with_context(|| format!("{context} requires capture metadata"))?;
    let status = capture
        .status
        .enum_value()
        .map_err(|value| anyhow::anyhow!("{context} has unknown capture status {value}"))?;
    if !matches!(
        status,
        CaptureStatus::COMPLETE_FOR_RUNS | CaptureStatus::PARTIAL
    ) || evidence.executions.is_empty()
    {
        bail!("{context} must contain a complete or partial observed execution");
    }
    validate_capture_and_buckets(&context, capture, &evidence.executions, &required, bundle)
}

fn validate_capture_and_buckets(
    context: &str,
    capture: &CaptureSummary,
    executions: &[ExecutionBucket],
    allowed_kinds: &BTreeSet<i32>,
    bundle: &RuntimeEvidence,
) -> Result<()> {
    let status = capture
        .status
        .enum_value()
        .map_err(|value| anyhow::anyhow!("{context} has unknown capture status {value}"))?;
    if status == CaptureStatus::CAPTURE_STATUS_UNSPECIFIED {
        bail!("{context} capture status must be explicit");
    }
    if status != CaptureStatus::COMPLETE_FOR_RUNS && capture.reason.trim().is_empty() {
        bail!("{context} non-complete capture requires a precise reason");
    }
    let known_runs = bundle
        .runs
        .iter()
        .map(|run| run.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut capture_runs = BTreeSet::new();
    for run in &capture.run_ids {
        if !known_runs.contains(run.as_str()) {
            bail!("{context} references unknown run {run:?}");
        }
        if !capture_runs.insert(run.as_str()) {
            bail!("{context} contains duplicate run {run:?}");
        }
    }
    if capture.run_ids.is_empty() {
        bail!("{context} must identify its contributing runs");
    }
    let bucket_count = executions
        .iter()
        .try_fold(0u64, |total, bucket| total.checked_add(bucket.count))
        .with_context(|| format!("{context} execution count overflow"))?;
    if bucket_count != capture.observed_executions {
        bail!(
            "{context} observed_executions {} does not equal bucket count {bucket_count}",
            capture.observed_executions
        );
    }
    match status {
        CaptureStatus::COMPLETE_FOR_RUNS => {
            if capture.dropped_executions != 0 {
                bail!("{context} complete capture cannot contain dropped executions");
            }
            if capture.observed_executions == 0 {
                bail!("{context} COMPLETE_FOR_RUNS requires an execution");
            }
        }
        CaptureStatus::NOT_EXECUTED => {
            if capture.observed_executions != 0
                || capture.dropped_executions != 0
                || !executions.is_empty()
            {
                bail!("{context} NOT_EXECUTED must have no executions");
            }
        }
        _ => {}
    }
    let complete = capture
        .complete_kinds
        .iter()
        .map(|kind| {
            kind.enum_value()
                .map(|kind| kind.value())
                .map_err(|value| anyhow::anyhow!("{context} has unknown complete kind {value}"))
        })
        .collect::<Result<BTreeSet<_>>>()?;
    if complete.contains(&EvidenceKind::EVIDENCE_KIND_UNSPECIFIED.value()) {
        bail!("{context} complete_kinds must be explicit");
    }
    if complete.len() != capture.complete_kinds.len() {
        bail!("{context} contains duplicate complete_kinds");
    }
    if !complete.iter().all(|kind| allowed_kinds.contains(kind)) {
        bail!("{context} completes evidence that the trace plan did not request");
    }
    if status == CaptureStatus::COMPLETE_FOR_RUNS && complete != *allowed_kinds {
        bail!("{context} COMPLETE_FOR_RUNS must complete every requested evidence kind");
    }
    for (bucket_index, bucket) in executions.iter().enumerate() {
        if bucket.count == 0 {
            bail!("{context}.executions[{bucket_index}].count must be positive");
        }
        if (complete.contains(&EvidenceKind::RECEIVER_VALUE.value())
            || complete.contains(&EvidenceKind::COLLECTION_VALUE.value()))
            && bucket.receiver.is_none()
        {
            bail!("{context}.executions[{bucket_index}] lacks required receiver");
        }
        if complete.contains(&EvidenceKind::CALL_TARGET.value()) && bucket.target.is_none() {
            bail!("{context}.executions[{bucket_index}] lacks required target");
        }
        if complete.contains(&EvidenceKind::RESULT_VALUE.value()) && bucket.result.is_none() {
            bail!("{context}.executions[{bucket_index}] lacks required result");
        }
        if complete.contains(&EvidenceKind::BOOLEAN_RESULT.value())
            && bucket.boolean_result.is_none()
        {
            bail!("{context}.executions[{bucket_index}] lacks required Boolean result");
        }
        if complete.iter().any(|kind| {
            *kind == EvidenceKind::PARAMETER_VALUE.value()
                || *kind == EvidenceKind::RETURN_VALUE.value()
                || *kind == EvidenceKind::STATE_VALUE.value()
        }) && bucket.value.is_none()
        {
            bail!("{context}.executions[{bucket_index}] lacks required boundary value");
        }
        if let Some(receiver) = bucket.receiver.as_ref() {
            validate_value_set(
                Some(receiver),
                &format!("{context}.executions[{bucket_index}].receiver"),
            )?;
        }
        if let Some(result) = bucket.result.as_ref() {
            validate_value_set(
                Some(result),
                &format!("{context}.executions[{bucket_index}].result"),
            )?;
        }
        if let Some(value) = bucket.value.as_ref() {
            validate_value_set(
                Some(value),
                &format!("{context}.executions[{bucket_index}].value"),
            )?;
        }
        if let Some(target) = bucket.target.as_ref() {
            validate_runtime_target(
                target,
                &format!("{context}.executions[{bucket_index}].target"),
            )?;
        }
        let provenance = bucket
            .provenance
            .as_ref()
            .with_context(|| format!("{context}.executions[{bucket_index}] requires provenance"))?;
        if provenance.run_id.is_empty()
            || provenance.provider.is_empty()
            || provenance.provider_version.is_empty()
        {
            bail!("{context}.executions[{bucket_index}] provenance is incomplete");
        }
        if !capture_runs.contains(provenance.run_id.as_str()) {
            bail!("{context}.executions[{bucket_index}] provenance run is outside capture runs");
        }
        if ((complete.contains(&EvidenceKind::RECEIVER_VALUE.value())
            || complete.contains(&EvidenceKind::COLLECTION_VALUE.value()))
            && bucket.receiver.as_ref().is_some_and(value_set_is_truncated))
            || (complete.contains(&EvidenceKind::RESULT_VALUE.value())
                && bucket.result.as_ref().is_some_and(value_set_is_truncated))
            || (complete.iter().any(|kind| {
                *kind == EvidenceKind::PARAMETER_VALUE.value()
                    || *kind == EvidenceKind::RETURN_VALUE.value()
                    || *kind == EvidenceKind::STATE_VALUE.value()
            }) && bucket.value.as_ref().is_some_and(value_set_is_truncated))
        {
            bail!("{context} complete evidence kind cannot contain truncated values");
        }
    }
    Ok(())
}

fn validate_runtime_target(target: &RuntimeTarget, context: &str) -> Result<()> {
    validate_global_symbol(&target.symbol, &format!("{context}.symbol"))?;
    if target.source_role.enum_value_or_default() == SourceRole::SOURCE_ROLE_UNSPECIFIED {
        bail!("{context}.source_role must be explicit");
    }
    if target.package_manager.is_empty()
        || target.package_name.is_empty()
        || target.package_version.is_empty()
    {
        bail!("{context} requires package manager, name, and version");
    }
    if let Some(definition) = target.definition.as_ref() {
        if !definition.symbol.is_empty() {
            validate_global_symbol(&definition.symbol, &format!("{context}.definition.symbol"))?;
        }
        if !definition.anchor_symbol.is_empty() {
            validate_local_symbol(
                &definition.anchor_symbol,
                &format!("{context}.definition.anchor_symbol"),
            )?;
        }
        if !definition.relative_path.is_empty() {
            validate_relative_path(
                &definition.relative_path,
                &format!("{context}.definition.relative_path"),
            )?;
        }
    }
    Ok(())
}

fn validate_runtime_value(value: &RuntimeValue, context: &str) -> Result<()> {
    validate_global_symbol(&value.type_symbol, &format!("{context}.type_symbol"))?;
    if !value.singleton_symbol.is_empty() {
        validate_global_symbol(
            &value.singleton_symbol,
            &format!("{context}.singleton_symbol"),
        )?;
    }
    if value.source_role.enum_value_or_default() == SourceRole::SOURCE_ROLE_UNSPECIFIED {
        bail!("{context}.source_role must be explicit");
    }
    match value.shape.as_ref() {
        Some(runtime_value::Shape::Sequence(shape)) => validate_value_set(
            shape.elements.as_ref(),
            &format!("{context}.sequence.elements"),
        )?,
        Some(runtime_value::Shape::Mapping(shape)) => {
            for (index, entry) in shape.entries.iter().enumerate() {
                let key = entry
                    .key
                    .as_ref()
                    .with_context(|| format!("{context}.mapping.entries[{index}] lacks key"))?;
                let value = entry
                    .value
                    .as_ref()
                    .with_context(|| format!("{context}.mapping.entries[{index}] lacks value"))?;
                validate_runtime_value(key, &format!("{context}.mapping.entries[{index}].key"))?;
                validate_runtime_value(
                    value,
                    &format!("{context}.mapping.entries[{index}].value"),
                )?;
                if entry.count == 0 {
                    bail!("{context}.mapping.entries[{index}].count must be positive");
                }
            }
        }
        Some(runtime_value::Shape::Record(shape)) => {
            let mut members = BTreeSet::new();
            for (index, member) in shape.members.iter().enumerate() {
                if member.name.is_empty() || !members.insert(member.name.as_str()) {
                    bail!("{context}.record.members[{index}] has an empty or duplicate name");
                }
                validate_value_set(
                    member.values.as_ref(),
                    &format!("{context}.record.members[{index}].values"),
                )?;
            }
        }
        Some(runtime_value::Shape::Tuple(shape)) => {
            for (index, element) in shape.elements.iter().enumerate() {
                validate_value_set(Some(element), &format!("{context}.tuple.elements[{index}]"))?;
            }
        }
        None => {}
    }
    Ok(())
}

fn validate_value_set(values: Option<&ValueSet>, context: &str) -> Result<()> {
    let values = values.with_context(|| format!("{context} is missing"))?;
    if values.alternatives.is_empty() && !values.truncated {
        bail!("{context} must contain an alternative or be marked truncated");
    }
    for (index, alternative) in values.alternatives.iter().enumerate() {
        if alternative.count == 0 {
            bail!("{context}.alternatives[{index}].count must be positive");
        }
        let value = alternative
            .value
            .as_ref()
            .with_context(|| format!("{context}.alternatives[{index}] lacks a value"))?;
        validate_runtime_value(value, &format!("{context}.alternatives[{index}].value"))?;
    }
    Ok(())
}

fn runtime_value_is_truncated(value: &RuntimeValue) -> bool {
    value.truncated
        || match value.shape.as_ref() {
            Some(runtime_value::Shape::Sequence(shape)) => shape
                .elements
                .as_ref()
                .is_some_and(|values| values.truncated),
            Some(runtime_value::Shape::Mapping(shape)) => shape.truncated,
            Some(runtime_value::Shape::Record(shape)) => shape.truncated,
            Some(runtime_value::Shape::Tuple(shape)) => shape.truncated,
            None => false,
        }
}

fn value_set_is_truncated(values: &ValueSet) -> bool {
    values.truncated
        || values.alternatives.iter().any(|alternative| {
            alternative
                .value
                .as_ref()
                .is_some_and(runtime_value_is_truncated)
        })
}

fn validate_tool(tool: Option<&ToolInfo>, context: &str) -> Result<()> {
    let tool = tool.with_context(|| format!("{context} is required"))?;
    if tool.name.is_empty() || tool.version.is_empty() {
        bail!("{context} requires a name and version");
    }
    Ok(())
}

fn validate_anchor(
    anchor: &SourceAnchor,
    documents: &BTreeMap<&str, &PlannedDocument>,
    context: &str,
) -> Result<()> {
    validate_local_symbol(&anchor.symbol, &format!("{context}.symbol"))?;
    let document = documents
        .get(anchor.relative_path.as_str())
        .with_context(|| format!("{context} references an unknown document"))?;
    validate_range(anchor.range.as_ref(), &format!("{context}.range"))?;
    if anchor.kind.enum_value_or_default() == AnchorKind::ANCHOR_KIND_UNSPECIFIED {
        bail!("{context}.kind must be explicit");
    }
    validate_global_symbol(
        &anchor.enclosing_symbol,
        &format!("{context}.enclosing_symbol"),
    )?;
    if anchor.semantic_digest.len() != 32 {
        bail!("{context}.semantic_digest must contain 32 bytes");
    }
    if document.position_encoding.enum_value_or_default()
        == PositionEncoding::POSITION_ENCODING_UNSPECIFIED
    {
        bail!("{context} document position encoding is unspecified");
    }
    Ok(())
}

fn validate_range(range: Option<&SourceRange>, context: &str) -> Result<()> {
    let range = range.with_context(|| format!("{context} is required"))?;
    if (range.end_line, range.end_character) < (range.start_line, range.start_character) {
        bail!("{context} must be a non-negative half-open range");
    }
    Ok(())
}

fn validate_relative_path(path: &str, context: &str) -> Result<()> {
    if path.is_empty() || path.contains('\\') {
        bail!("{context} must be a non-empty canonical '/'-separated path");
    }
    let parsed = Path::new(path);
    if parsed.is_absolute()
        || parsed.components().any(|component| {
            matches!(
                component,
                Component::RootDir
                    | Component::ParentDir
                    | Component::CurDir
                    | Component::Prefix(_)
            )
        })
    {
        bail!("{context} must be canonical and project-relative");
    }
    Ok(())
}

fn validate_local_symbol(symbol: &str, context: &str) -> Result<()> {
    match scip::symbol::try_parse_local_symbol(symbol) {
        Ok(Some(_)) => Ok(()),
        _ => bail!("{context} must be a valid document-local SCIP symbol"),
    }
}

fn validate_global_symbol(symbol: &str, context: &str) -> Result<()> {
    if symbol.is_empty() || scip::symbol::is_local_symbol(symbol) {
        bail!("{context} must be a canonical global SCIP symbol");
    }
    let parsed = scip::symbol::parse_symbol(symbol)
        .map_err(|error| anyhow::anyhow!("{context}: {error:?}"))?;
    if scip::symbol::format_symbol(parsed) != symbol {
        bail!("{context} is not in canonical SCIP symbol form");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use protobuf::{EnumOrUnknown, MessageField};
    use std::io::Write;

    fn conformance_fixture(name: &str) -> String {
        fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../protocol/runtime-evidence/v1/conformance")
                .join(name),
        )
        .expect("shared runtime protocol conformance fixture")
    }

    fn tool(name: &str) -> ToolInfo {
        ToolInfo {
            name: name.to_string(),
            version: "1".to_string(),
            ..ToolInfo::default()
        }
    }

    fn plan() -> TracePlan {
        let digest = Sha256::digest(b"source").to_vec();
        let anchor = SourceAnchor {
            symbol: "local call-1".to_string(),
            relative_path: "lib/worker.rb".to_string(),
            range: MessageField::some(SourceRange {
                start_line: 2,
                start_character: 8,
                end_line: 2,
                end_character: 12,
                ..SourceRange::default()
            }),
            kind: EnumOrUnknown::new(AnchorKind::CALL_SELECTOR),
            enclosing_symbol: "fact-mine workspace fixture . Worker#run().".to_string(),
            semantic_digest: Sha256::digest(b"call").to_vec(),
            display_name: "work".to_string(),
            ..SourceAnchor::default()
        };
        let mut plan = TracePlan {
            protocol_version: PROTOCOL_VERSION,
            producer: MessageField::some(tool("fact-mine")),
            project_root: "file:///workspace".to_string(),
            documents: vec![PlannedDocument {
                relative_path: "lib/worker.rb".to_string(),
                language: "ruby".to_string(),
                position_encoding: EnumOrUnknown::new(
                    PositionEncoding::UTF8_CODE_UNIT_OFFSET_FROM_LINE_START,
                ),
                content_sha256: digest,
                ..PlannedDocument::default()
            }],
            requests: vec![EvidenceRequest {
                anchor: MessageField::some(anchor),
                required: vec![
                    EnumOrUnknown::new(EvidenceKind::RECEIVER_VALUE),
                    EnumOrUnknown::new(EvidenceKind::CALL_TARGET),
                    EnumOrUnknown::new(EvidenceKind::RESULT_VALUE),
                ],
                execution_range: MessageField::some(SourceRange {
                    start_line: 2,
                    start_character: 0,
                    end_line: 2,
                    end_character: 13,
                    ..SourceRange::default()
                }),
                ..EvidenceRequest::default()
            }],
            ..TracePlan::default()
        };
        plan.plan_digest = trace_plan_digest(&plan).expect("digest");
        plan
    }

    fn runtime_value(symbol: &str) -> RuntimeValue {
        RuntimeValue {
            type_symbol: symbol.to_string(),
            source_role: EnumOrUnknown::new(SourceRole::PRODUCTION),
            ..RuntimeValue::default()
        }
    }

    fn value_set(symbol: &str) -> ValueSet {
        ValueSet {
            alternatives: vec![WeightedValue {
                value: MessageField::some(runtime_value(symbol)),
                count: 1,
                ..WeightedValue::default()
            }],
            ..ValueSet::default()
        }
    }

    fn evidence(plan: &TracePlan) -> RuntimeEvidence {
        let request = &plan.requests[0];
        let anchor = request.anchor.as_ref().expect("anchor");
        RuntimeEvidence {
            protocol_version: PROTOCOL_VERSION,
            producer: MessageField::some(tool("nil-kill")),
            authority: EnumOrUnknown::new(Authority::MODELED_RUNS),
            trace_plan_digest: plan.plan_digest.clone(),
            runs: vec![Run {
                id: "run-1".to_string(),
                status: EnumOrUnknown::new(RunStatus::SUCCEEDED),
                ..Run::default()
            }],
            anchors: vec![AnchorEvidence {
                anchor_symbol: anchor.symbol.clone(),
                anchor_semantic_digest: anchor.semantic_digest.clone(),
                capture: MessageField::some(CaptureSummary {
                    status: EnumOrUnknown::new(CaptureStatus::COMPLETE_FOR_RUNS),
                    run_ids: vec!["run-1".to_string()],
                    observed_executions: 1,
                    complete_kinds: request.required.clone(),
                    ..CaptureSummary::default()
                }),
                executions: vec![ExecutionBucket {
                    count: 1,
                    receiver: MessageField::some(value_set(
                        "nil-kill-runtime ruby ruby 3.2.3 String#",
                    )),
                    target: MessageField::some(RuntimeTarget {
                        symbol: "nil-kill-runtime ruby ruby 3.2.3 String#size().".to_string(),
                        source_role: EnumOrUnknown::new(SourceRole::STANDARD_LIBRARY),
                        package_manager: "ruby".to_string(),
                        package_name: "ruby".to_string(),
                        package_version: "3.2.3".to_string(),
                        ..RuntimeTarget::default()
                    }),
                    result: MessageField::some(value_set(
                        "nil-kill-runtime ruby ruby 3.2.3 Integer#",
                    )),
                    provenance: MessageField::some(Provenance {
                        run_id: "run-1".to_string(),
                        provider: "ruby".to_string(),
                        provider_version: "1".to_string(),
                        ..Provenance::default()
                    }),
                    ..ExecutionBucket::default()
                }],
                ..AnchorEvidence::default()
            }],
            ..RuntimeEvidence::default()
        }
    }

    fn correlation_evidence() -> (TracePlan, RuntimeEvidence) {
        let mut plan = plan();
        let mut second = plan.requests[0].clone();
        let second_anchor = second.anchor.as_mut().expect("anchor");
        second_anchor.symbol = "local call-2".to_string();
        second_anchor.semantic_digest = Sha256::digest(b"second call").to_vec();
        second_anchor.range.as_mut().expect("range").start_character = 20;
        second_anchor.range.as_mut().expect("range").end_character = 24;
        second.execution_range = MessageField::some(SourceRange {
            start_line: 2,
            start_character: 14,
            end_line: 2,
            end_character: 25,
            ..SourceRange::default()
        });
        plan.requests.push(second);
        plan.plan_digest = trace_plan_digest(&plan).expect("digest");

        let execution = evidence(&plan).anchors[0].executions[0].clone();
        let anchors = plan
            .requests
            .iter()
            .map(|request| {
                let anchor = request.anchor.as_ref().expect("anchor");
                AnchorEvidence {
                    anchor_symbol: anchor.symbol.clone(),
                    anchor_semantic_digest: anchor.semantic_digest.clone(),
                    capture: MessageField::some(CaptureSummary {
                        status: EnumOrUnknown::new(CaptureStatus::PARTIAL),
                        run_ids: vec!["run-1".to_string()],
                        reason: "execution is represented by a candidate group".to_string(),
                        ..CaptureSummary::default()
                    }),
                    ..AnchorEvidence::default()
                }
            })
            .collect();
        let bundle = RuntimeEvidence {
            protocol_version: PROTOCOL_VERSION,
            producer: MessageField::some(tool("nil-kill")),
            authority: EnumOrUnknown::new(Authority::MODELED_RUNS),
            trace_plan_digest: plan.plan_digest.clone(),
            runs: vec![Run {
                id: "run-1".to_string(),
                status: EnumOrUnknown::new(RunStatus::SUCCEEDED),
                ..Run::default()
            }],
            anchors,
            correlations: vec![CorrelationEvidence {
                group_id: "candidate-group-1".to_string(),
                candidate_anchor_symbols: vec![
                    "local call-1".to_string(),
                    "local call-2".to_string(),
                ],
                capture: MessageField::some(CaptureSummary {
                    status: EnumOrUnknown::new(CaptureStatus::COMPLETE_FOR_RUNS),
                    run_ids: vec!["run-1".to_string()],
                    observed_executions: 1,
                    complete_kinds: plan.requests[0].required.clone(),
                    ..CaptureSummary::default()
                }),
                executions: vec![execution],
                ..CorrelationEvidence::default()
            }],
            ..RuntimeEvidence::default()
        };
        (plan, bundle)
    }

    #[test]
    fn canonical_plan_and_correlated_evidence_validate() {
        let plan = plan();
        let evidence = evidence(&plan);
        validate_trace_plan(&plan).expect("plan");
        validate_runtime_evidence(&plan, &evidence).expect("evidence");
        let json = to_json(&evidence).expect("json");
        let decoded = parse_runtime_evidence_json(&json).expect("decode");
        assert_eq!(decoded, evidence);
    }

    #[test]
    fn candidate_correlations_are_strict_raw_evidence_not_guessed_anchors() {
        let (plan, bundle) = correlation_evidence();
        validate_runtime_evidence(&plan, &bundle).expect("candidate correlation");

        let mut one_candidate = bundle.clone();
        one_candidate.correlations[0].candidate_anchor_symbols.pop();
        assert!(validate_runtime_evidence(&plan, &one_candidate)
            .unwrap_err()
            .to_string()
            .contains("at least two"));

        let mut missing_target = bundle;
        missing_target.correlations[0].executions[0].target = MessageField::none();
        assert!(validate_runtime_evidence(&plan, &missing_target)
            .unwrap_err()
            .to_string()
            .contains("lacks required target"));
    }

    #[test]
    fn shared_conformance_corpus_is_accepted_and_rejected_consistently() {
        let plan =
            parse_trace_plan_json(&conformance_fixture("trace-plan.valid.json")).expect("plan");
        let evidence =
            parse_runtime_evidence_json(&conformance_fixture("runtime-evidence.valid.json"))
                .expect("evidence shape");
        validate_runtime_evidence(&plan, &evidence).expect("valid shared evidence");
        let correlation_plan =
            parse_trace_plan_json(&conformance_fixture("trace-plan.valid-correlation.json"))
                .expect("correlation plan");
        let correlation_evidence = parse_runtime_evidence_json(&conformance_fixture(
            "runtime-evidence.valid-correlation.json",
        ))
        .expect("correlation evidence shape");
        validate_runtime_evidence(&correlation_plan, &correlation_evidence)
            .expect("valid shared candidate correlation");

        assert!(parse_runtime_evidence_json(&conformance_fixture(
            "runtime-evidence.invalid-unknown-field.json"
        ))
        .is_err());
        let missing = parse_runtime_evidence_json(&conformance_fixture(
            "runtime-evidence.invalid-missing-anchor.json",
        ))
        .expect("schema-valid semantic failure");
        assert!(validate_runtime_evidence(&plan, &missing)
            .unwrap_err()
            .to_string()
            .contains("omits requested anchors"));
    }

    #[test]
    fn protojson_rejects_unknown_fields() {
        let json = to_json(&plan()).expect("json");
        let mutated = json.replacen('{', "{\"unknownContractField\":true,", 1);
        assert!(parse_trace_plan_json(&mutated)
            .unwrap_err()
            .to_string()
            .contains("ProtoJSON"));
    }

    #[test]
    fn canonical_runtime_symbols_cover_operator_descriptors() {
        for symbol in [
            "nil-kill-runtime ruby ruby 3.2.3 Integer#+().",
            "nil-kill-runtime ruby ruby 3.2.3 Integer#-().",
            "nil-kill-runtime ruby ruby 3.2.3 Array#`[]`().",
        ] {
            validate_global_symbol(symbol, "operator target").expect(symbol);
        }
    }

    #[test]
    fn evidence_must_cover_every_requested_anchor_exactly_once() {
        let plan = plan();
        let mut bundle = evidence(&plan);
        bundle.anchors.clear();
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("omits requested anchors"));

        let row = evidence(&plan).anchors.remove(0);
        bundle.anchors = vec![row.clone(), row];
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("duplicate evidence"));
    }

    #[test]
    fn stale_plan_and_anchor_digests_fail_closed() {
        let plan = plan();
        let mut bundle = evidence(&plan);
        bundle.trace_plan_digest[0] ^= 0xff;
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("trace_plan_digest"));

        let mut bundle = evidence(&plan);
        bundle.anchors[0].anchor_semantic_digest[0] ^= 0xff;
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("semantic digest"));
    }

    #[test]
    fn complete_capture_rejects_drops_and_truncation() {
        let plan = plan();
        let mut bundle = evidence(&plan);
        bundle.anchors[0]
            .capture
            .as_mut()
            .expect("capture")
            .dropped_executions = 1;
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("dropped"));

        let mut bundle = evidence(&plan);
        bundle.anchors[0].executions[0]
            .receiver
            .as_mut()
            .expect("receiver")
            .truncated = true;
        assert!(validate_runtime_evidence(&plan, &bundle)
            .unwrap_err()
            .to_string()
            .contains("truncated"));
    }

    #[test]
    fn not_executed_is_explicit_valid_evidence() {
        let plan = plan();
        let anchor = plan.requests[0].anchor.as_ref().expect("anchor");
        let mut bundle = evidence(&plan);
        bundle.anchors = vec![AnchorEvidence {
            anchor_symbol: anchor.symbol.clone(),
            anchor_semantic_digest: anchor.semantic_digest.clone(),
            capture: MessageField::some(CaptureSummary {
                status: EnumOrUnknown::new(CaptureStatus::NOT_EXECUTED),
                run_ids: vec!["run-1".to_string()],
                reason: "anchor did not execute in the modeled run".to_string(),
                complete_kinds: plan.requests[0].required.clone(),
                ..CaptureSummary::default()
            }),
            ..AnchorEvidence::default()
        }];
        validate_runtime_evidence(&plan, &bundle).expect("not executed");
    }

    #[test]
    fn fact_mine_emits_exact_relocatable_trace_plan_anchors() {
        let directory = tempfile::tempdir().expect("directory");
        let source = directory.path().join("worker.rb");
        let ruby = "class Worker\n  def run(value)\n    value.size\n  end\nend\n";
        fs::write(&source, ruby).expect("source");
        let document = crate::syntax::parse_file(source.clone(), crate::syntax::Language::Ruby)
            .expect("parse");
        let profile = crate::profile::extract(&document, crate::profile::Profile::TracePlan);
        let first = build_trace_plan(&profile, std::slice::from_ref(&source), directory.path())
            .expect("plan");

        let call = first
            .requests
            .iter()
            .find_map(|request| {
                let anchor = request.anchor.as_ref()?;
                (anchor.display_name == "size").then_some(anchor)
            })
            .expect("call anchor");
        assert_eq!(call.relative_path, "worker.rb");
        assert_eq!(call.range.as_ref().expect("range").start_line, 2);
        assert!(first.requests.iter().any(|request| {
            request.parameter_ordinal == Some(0)
                && request
                    .required
                    .iter()
                    .any(|kind| kind.enum_value_or_default() == EvidenceKind::PARAMETER_VALUE)
        }));

        let mut shifted = fs::File::create(&source).expect("rewrite");
        shifted
            .write_all(format!("\n{ruby}").as_bytes())
            .expect("shift");
        let document = crate::syntax::parse_file(source.clone(), crate::syntax::Language::Ruby)
            .expect("parse shifted");
        let profile = crate::profile::extract(&document, crate::profile::Profile::TracePlan);
        let second = build_trace_plan(&profile, &[source], directory.path()).expect("shifted plan");
        let shifted_call = second
            .requests
            .iter()
            .find_map(|request| {
                let anchor = request.anchor.as_ref()?;
                (anchor.display_name == "size").then_some(anchor)
            })
            .expect("shifted call anchor");

        assert_eq!(shifted_call.symbol, call.symbol);
        assert_eq!(shifted_call.semantic_digest, call.semantic_digest);
        assert_eq!(
            shifted_call
                .range
                .as_ref()
                .expect("shifted range")
                .start_line,
            call.range.as_ref().expect("range").start_line + 1
        );
        assert_ne!(second.plan_digest, first.plan_digest);
    }

    #[test]
    fn trace_plan_enclosing_symbols_ignore_absolute_profile_path_form() {
        let directory = tempfile::tempdir().expect("directory");
        let source = directory.path().join("worker.rb");
        fs::write(&source, "class Worker\n  def run\n    1\n  end\nend\n").expect("source");
        let document =
            crate::syntax::parse_file(source, crate::syntax::Language::Ruby).expect("parse");
        let profile = crate::profile::extract(&document, crate::profile::Profile::TracePlan);
        let mut relative = profile
            .methods
            .iter()
            .find(|method| method.name == "run")
            .expect("method")
            .clone();
        relative.path = "gems/demo/lib/worker.rb".to_string();
        let mut absolute = relative.clone();
        absolute.path = "/checkout/gems/demo/lib/worker.rb".to_string();

        assert_eq!(
            plan_method_symbol(&relative, "gems/demo/lib/worker.rb"),
            plan_method_symbol(&absolute, "gems/demo/lib/worker.rb")
        );
    }
}
