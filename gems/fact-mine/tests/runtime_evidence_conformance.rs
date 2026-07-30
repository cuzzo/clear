use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::runtime_evidence;
use fact_mine_rust::runtime_protocol::{
    self, AnchorEvidence, Authority, BuiltTracePlan, CaptureStatus, CaptureSummary,
    CorrelationEvidence, EvidenceKind, ExecutionBucket, MappingEntry, MappingShape, Provenance,
    RecordMember, RecordShape, Run, RunStatus, RuntimeEvidence, RuntimeTarget, RuntimeValue,
    SequenceShape, SourceRole, ToolInfo, TupleShape, ValueSet, WeightedValue,
};
use fact_mine_rust::syntax::{self, Language};
use protobuf::{Enum, EnumOrUnknown, MessageField};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct Catalog {
    version: u32,
    wire_matrix: WireMatrix,
    fixture: Fixture,
    static_closures: Vec<StaticClosure>,
    cases: Vec<Case>,
    boundary_cases: Vec<BoundaryCase>,
    merge_cases: Vec<MergeCase>,
}

#[derive(Debug, Deserialize)]
struct StaticClosure {
    id: String,
    capabilities: Vec<String>,
    anchor: AnchorSelector,
    expect: StaticClosureExpectation,
}

#[derive(Debug, Deserialize)]
struct StaticClosureExpectation {
    target_owner: String,
    target_name: String,
}

#[derive(Debug, Deserialize)]
struct WireMatrix {
    anchor_kinds: Vec<String>,
    planner_anchor_kinds: Vec<String>,
    reserved_anchor_kinds: BTreeMap<String, String>,
    evidence_kinds: Vec<String>,
    capture_statuses: Vec<String>,
    source_roles: Vec<String>,
    value_shapes: Vec<String>,
    negative_controls: Vec<String>,
    request_contracts: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct Fixture {
    language: String,
    source: String,
    driver: String,
    #[serde(default)]
    support: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Case {
    id: String,
    capabilities: Vec<String>,
    anchor: Option<AnchorSelector>,
    #[serde(default)]
    anchors: Vec<AnchorSelector>,
    expect: Expectation,
}

#[derive(Clone, Debug, Deserialize)]
struct AnchorSelector {
    method: String,
    selector: String,
    occurrence: usize,
}

#[derive(Debug, Deserialize)]
struct Expectation {
    required: Vec<String>,
    allowed_status: Option<String>,
    #[serde(default)]
    complete_kinds: Vec<String>,
    #[serde(default)]
    correlation: bool,
    receiver_type: Option<String>,
    #[serde(default)]
    receiver_types: Vec<String>,
    target_owner: Option<String>,
    #[serde(default)]
    target_owners: Vec<String>,
    target_name: Option<String>,
    forbidden_target_name: Option<String>,
    target_kind: Option<String>,
    excluded_target_owner: Option<String>,
    excluded_target_owner_prefix: Option<String>,
    source_role: Option<String>,
    result_type: Option<String>,
    result_element_type: Option<String>,
    result_shape: Option<String>,
    boolean_result: Option<bool>,
    observed_executions: Option<u64>,
    call_time: Option<String>,
    call_space: Option<String>,
    iteration_multiplicity: Option<String>,
    #[serde(default)]
    factmine_infers: Vec<InferredExpectation>,
}

#[derive(Debug, Deserialize)]
struct InferredExpectation {
    method: String,
    selector: String,
    target_owner: String,
}

#[derive(Debug, Deserialize)]
struct MergeCase {
    id: String,
    capabilities: Vec<String>,
    expected_runs: Vec<String>,
    #[serde(default)]
    forbidden_runs: Vec<String>,
    expected_count: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct BoundaryCase {
    id: String,
    capabilities: Vec<String>,
    method: String,
    display_name: String,
    anchor_kind: String,
    evidence_kind: String,
    expected_type: Option<String>,
    allowed_status: Option<String>,
}

fn conformance_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../protocol/runtime-evidence/v1/conformance")
}

fn load_catalog() -> Catalog {
    serde_yaml::from_str(
        &fs::read_to_string(conformance_root().join("capabilities.yml"))
            .expect("shared runtime evidence capability catalog"),
    )
    .expect("valid capability catalog")
}

fn built_fixture() -> (Catalog, PathBuf, profile::ProfileOutput, BuiltTracePlan) {
    let catalog = load_catalog();
    assert_eq!(catalog.version, 1);
    assert_eq!(catalog.fixture.language, "ruby");
    assert!(
        conformance_root().join(&catalog.fixture.driver).is_file(),
        "collector driver named by the shared catalog must exist"
    );
    assert!(catalog
        .fixture
        .support
        .iter()
        .all(|path| conformance_root().join(path).is_file()));
    let source = conformance_root().join(&catalog.fixture.source);
    let document =
        syntax::parse_file(source.clone(), Language::Ruby).expect("parse conformance fixture");
    let plan_profile = profile::extract(&document, Profile::TracePlan);
    let built = runtime_protocol::build_trace_plan_with_bindings(
        &plan_profile,
        std::slice::from_ref(&source),
        &conformance_root(),
    )
    .expect("build conformance trace plan");
    let document =
        syntax::parse_file(source.clone(), Language::Ruby).expect("parse profile fixture");
    let output = profile::extract(&document, Profile::Espalier);
    (catalog, source, output, built)
}

fn request_symbols(
    built: &BuiltTracePlan,
    output: &profile::ProfileOutput,
    selector: &AnchorSelector,
) -> Vec<String> {
    let calls = output
        .calls
        .iter()
        .map(|call| (call.id.as_str(), call))
        .collect::<BTreeMap<_, _>>();
    let methods = output
        .methods
        .iter()
        .map(|method| (method.id.as_str(), method))
        .collect::<BTreeMap<_, _>>();
    let mut matching = built
        .plan
        .requests
        .iter()
        .filter_map(|request| {
            let anchor = request.anchor.as_ref()?;
            let runtime_protocol::AnchorBinding::Call { call_id } =
                built.bindings.get(&anchor.symbol)?
            else {
                return None;
            };
            let call = calls.get(call_id.as_str())?;
            let method = methods.get(call.source.as_str())?;
            (anchor.display_name == selector.selector && method.name == selector.method).then_some(
                (
                    anchor
                        .range
                        .as_ref()
                        .map(|range| {
                            (
                                range.start_line,
                                range.start_character,
                                range.end_line,
                                range.end_character,
                            )
                        })
                        .unwrap_or_default(),
                    anchor.symbol.clone(),
                ),
            )
        })
        .collect::<Vec<_>>();
    matching.sort();
    matching.into_iter().map(|(_, symbol)| symbol).collect()
}

fn selected_symbol(
    built: &BuiltTracePlan,
    output: &profile::ProfileOutput,
    selector: &AnchorSelector,
) -> String {
    let symbols = request_symbols(built, output, selector);
    symbols
        .get(selector.occurrence.saturating_sub(1))
        .unwrap_or_else(|| {
            panic!(
                "missing occurrence {} of {} in {} (found {})",
                selector.occurrence,
                selector.selector,
                selector.method,
                symbols.len()
            )
        })
        .clone()
}

fn selected_call<'a>(
    output: &'a profile::ProfileOutput,
    selector: &AnchorSelector,
) -> &'a profile::CallRecord {
    let methods = output
        .methods
        .iter()
        .map(|method| (method.id.as_str(), method))
        .collect::<BTreeMap<_, _>>();
    let mut matching = output
        .calls
        .iter()
        .filter(|call| {
            call.message == selector.selector
                && methods
                    .get(call.source.as_str())
                    .is_some_and(|method| method.name == selector.method)
        })
        .collect::<Vec<_>>();
    matching.sort_by_key(|call| call.span);
    matching
        .get(selector.occurrence.saturating_sub(1))
        .copied()
        .unwrap_or_else(|| {
            panic!(
                "missing occurrence {} of {} in {} (found {})",
                selector.occurrence,
                selector.selector,
                selector.method,
                matching.len()
            )
        })
}

fn boundary_symbol(
    built: &BuiltTracePlan,
    output: &profile::ProfileOutput,
    boundary: &BoundaryCase,
) -> String {
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
    let mut symbols = built
        .plan
        .requests
        .iter()
        .filter_map(|request| {
            let anchor = request.anchor.as_ref()?;
            if format!("{:?}", anchor.kind.enum_value().ok()?) != boundary.anchor_kind
                || anchor.display_name != boundary.display_name
            {
                return None;
            }
            let method_id = match built.bindings.get(&anchor.symbol)? {
                runtime_protocol::AnchorBinding::Parameter { method_id, .. }
                | runtime_protocol::AnchorBinding::Return { method_id } => method_id,
                runtime_protocol::AnchorBinding::Call { call_id } => {
                    &calls.get(call_id.as_str())?.source
                }
                runtime_protocol::AnchorBinding::State { access_id } => {
                    &accesses.get(access_id.as_str())?.function_id
                }
            };
            (methods.get(method_id.as_str())?.name == boundary.method)
                .then_some(anchor.symbol.clone())
        })
        .collect::<Vec<_>>();
    symbols.sort();
    assert_eq!(
        symbols.len(),
        1,
        "{} must select exactly one planned boundary, got {:?}",
        boundary.id,
        symbols
    );
    symbols.remove(0)
}

fn ruby_type_symbol(name: &str) -> String {
    format!(
        "nil-kill-runtime ruby ruby 3.2.3 {}#",
        descriptor_owner(name)
    )
}

fn descriptor_name(name: &str) -> String {
    if name
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "_+$-".contains(character))
    {
        name.to_string()
    } else {
        format!("`{}`", name.replace('`', "``"))
    }
}

fn descriptor_owner(name: &str) -> String {
    name.split("::")
        .map(descriptor_name)
        .collect::<Vec<_>>()
        .join("/")
}

fn value_set(name: &str, element: Option<&str>, role: SourceRole) -> ValueSet {
    let mut value = RuntimeValue {
        type_symbol: ruby_type_symbol(name),
        source_role: EnumOrUnknown::new(role),
        ..RuntimeValue::default()
    };
    if let Some(element) = element {
        value.shape = Some(runtime_protocol::runtime_value::Shape::Sequence(
            runtime_protocol::SequenceShape {
                elements: MessageField::some(ValueSet {
                    alternatives: vec![WeightedValue {
                        value: MessageField::some(RuntimeValue {
                            type_symbol: ruby_type_symbol(element),
                            source_role: EnumOrUnknown::new(role),
                            ..RuntimeValue::default()
                        }),
                        count: 1,
                        ..WeightedValue::default()
                    }],
                    ..ValueSet::default()
                }),
                ..runtime_protocol::SequenceShape::default()
            },
        ));
    }
    ValueSet {
        alternatives: vec![WeightedValue {
            value: MessageField::some(value),
            count: 1,
            ..WeightedValue::default()
        }],
        ..ValueSet::default()
    }
}

fn shaped_value_set(shape: &str, role: SourceRole) -> ValueSet {
    let child = || RuntimeValue {
        type_symbol: ruby_type_symbol("String"),
        source_role: EnumOrUnknown::new(role),
        ..RuntimeValue::default()
    };
    let child_set = || ValueSet {
        alternatives: vec![WeightedValue {
            value: MessageField::some(child()),
            count: 1,
            ..WeightedValue::default()
        }],
        ..ValueSet::default()
    };
    let shape = match shape {
        "sequence" => runtime_protocol::runtime_value::Shape::Sequence(SequenceShape {
            elements: MessageField::some(child_set()),
            ..SequenceShape::default()
        }),
        "mapping" => runtime_protocol::runtime_value::Shape::Mapping(MappingShape {
            entries: vec![MappingEntry {
                key: MessageField::some(child()),
                value: MessageField::some(child()),
                count: 1,
                ..MappingEntry::default()
            }],
            ..MappingShape::default()
        }),
        "record" => runtime_protocol::runtime_value::Shape::Record(RecordShape {
            members: vec![RecordMember {
                name: "value".to_string(),
                values: MessageField::some(child_set()),
                ..RecordMember::default()
            }],
            ..RecordShape::default()
        }),
        "tuple" => runtime_protocol::runtime_value::Shape::Tuple(TupleShape {
            elements: vec![child_set(), child_set()],
            ..TupleShape::default()
        }),
        other => panic!("unknown catalog value shape {other}"),
    };
    ValueSet {
        alternatives: vec![WeightedValue {
            value: MessageField::some(RuntimeValue {
                type_symbol: ruby_type_symbol("Object"),
                source_role: EnumOrUnknown::new(role),
                shape: Some(shape),
                ..RuntimeValue::default()
            }),
            count: 1,
            ..WeightedValue::default()
        }],
        ..ValueSet::default()
    }
}

fn role(value: Option<&str>, owner: Option<&str>) -> SourceRole {
    match value {
        Some("PRODUCTION") => SourceRole::PRODUCTION,
        Some("NON_PRODUCTION") => SourceRole::NON_PRODUCTION,
        Some("STANDARD_LIBRARY") => SourceRole::STANDARD_LIBRARY,
        Some("DEPENDENCY") => SourceRole::DEPENDENCY,
        _ if matches!(owner, Some("String" | "Hash" | "Array" | "Process::Status")) => {
            SourceRole::STANDARD_LIBRARY
        }
        _ => SourceRole::PRODUCTION,
    }
}

fn target(owner: &str, name: &str, kind: Option<&str>, role: SourceRole) -> RuntimeTarget {
    let (manager, package, version) = if role == SourceRole::STANDARD_LIBRARY {
        ("ruby", "ruby", "3.2.3")
    } else {
        ("workspace", "runtime-evidence-conformance", "workspace")
    };
    RuntimeTarget {
        symbol: format!(
            "nil-kill-runtime {manager} {package} {version} {}{}{}().",
            descriptor_owner(owner),
            if kind == Some("class") { "." } else { "#" },
            descriptor_name(name)
        ),
        source_role: EnumOrUnknown::new(role),
        package_manager: manager.to_string(),
        package_name: package.to_string(),
        package_version: version.to_string(),
        ..RuntimeTarget::default()
    }
}

fn evidence_for_catalog(
    catalog: &Catalog,
    output: &profile::ProfileOutput,
    built: &BuiltTracePlan,
) -> RuntimeEvidence {
    let requests = built
        .plan
        .requests
        .iter()
        .map(|request| {
            let anchor = request.anchor.as_ref().expect("validated plan anchor");
            (anchor.symbol.clone(), request)
        })
        .collect::<BTreeMap<_, _>>();
    let mut exact = BTreeMap::<String, &Case>::new();
    let boundaries = catalog
        .boundary_cases
        .iter()
        .map(|boundary| (boundary_symbol(built, output, boundary), boundary))
        .collect::<BTreeMap<_, _>>();
    let mut correlations = Vec::<(&Case, Vec<String>)>::new();
    for case in &catalog.cases {
        if let Some(selector) = &case.anchor {
            assert!(
                exact
                    .insert(selected_symbol(built, output, selector), case)
                    .is_none(),
                "a conformance anchor must have one owner"
            );
        } else {
            let symbols = case
                .anchors
                .iter()
                .map(|selector| selected_symbol(built, output, selector))
                .collect::<Vec<_>>();
            correlations.push((case, symbols));
        }
    }
    let correlated = correlations
        .iter()
        .flat_map(|(_, symbols)| symbols.iter().cloned())
        .collect::<BTreeSet<_>>();

    let anchors = built
        .plan
        .requests
        .iter()
        .map(|request| {
            let anchor = request.anchor.as_ref().expect("anchor");
            let (status, complete_kinds, executions, reason) = if let Some(case) =
                exact.get(&anchor.symbol)
            {
                let expected = &case.expect;
                let receiver_names = if expected.receiver_types.is_empty() {
                    vec![expected
                        .receiver_type
                        .as_deref()
                        .or(expected.target_owner.as_deref())
                        .unwrap_or("Object")]
                } else {
                    expected
                        .receiver_types
                        .iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                };
                let target_owners = if expected.target_owners.is_empty() {
                    vec![expected
                        .target_owner
                        .as_deref()
                        .unwrap_or(receiver_names[0])]
                } else {
                    expected
                        .target_owners
                        .iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                };
                let target_name = expected
                    .target_name
                    .as_deref()
                    .unwrap_or(&anchor.display_name);
                let required = request
                    .required
                    .iter()
                    .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
                    .collect::<BTreeSet<_>>();
                let complete_kind_names = if expected.allowed_status.as_deref() == Some("PARTIAL") {
                    expected
                        .complete_kinds
                        .iter()
                        .cloned()
                        .collect::<BTreeSet<_>>()
                } else {
                    request
                        .required
                        .iter()
                        .filter_map(|kind| kind.enum_value().ok())
                        .map(|kind| format!("{kind:?}"))
                        .collect::<BTreeSet<_>>()
                };
                let complete_kind =
                    |kind: EvidenceKind| complete_kind_names.contains(format!("{kind:?}").as_str());
                let alternative_count = receiver_names.len().max(target_owners.len());
                assert!(
                    receiver_names.len() == 1 || receiver_names.len() == alternative_count,
                    "{} receiver alternatives do not align with targets",
                    case.id
                );
                assert!(
                    target_owners.len() == 1 || target_owners.len() == alternative_count,
                    "{} target alternatives do not align with receivers",
                    case.id
                );
                let mut executions = (0..alternative_count)
                    .map(|index| {
                        let receiver_name = receiver_names[index.min(receiver_names.len() - 1)];
                        let owner = target_owners[index.min(target_owners.len() - 1)];
                        let source_role = role(expected.source_role.as_deref(), Some(owner));
                        let result = if let Some(shape) = expected.result_shape.as_deref() {
                            shaped_value_set(shape, SourceRole::PRODUCTION)
                        } else {
                            value_set(
                                expected.result_type.as_deref().unwrap_or("Object"),
                                expected.result_element_type.as_deref(),
                                SourceRole::PRODUCTION,
                            )
                        };
                        let mut bucket = ExecutionBucket {
                            count: if alternative_count == 1 {
                                expected.observed_executions.unwrap_or(1)
                            } else {
                                1
                            },
                            receiver: (complete_kind(EvidenceKind::RECEIVER_VALUE)
                                || complete_kind(EvidenceKind::COLLECTION_VALUE))
                            .then(|| value_set(receiver_name, None, source_role))
                            .into(),
                            target: complete_kind(EvidenceKind::CALL_TARGET)
                                .then(|| {
                                    target(
                                        owner,
                                        target_name,
                                        expected.target_kind.as_deref(),
                                        source_role,
                                    )
                                })
                                .into(),
                            result: complete_kind(EvidenceKind::RESULT_VALUE)
                                .then_some(result)
                                .into(),
                            provenance: MessageField::some(Provenance {
                                run_id: "oracle-run".to_string(),
                                provider: "canonical-conformance".to_string(),
                                provider_version: "1".to_string(),
                                ..Provenance::default()
                            }),
                            ..ExecutionBucket::default()
                        };
                        if complete_kind(EvidenceKind::BOOLEAN_RESULT) {
                            bucket.boolean_result = Some(expected.boolean_result.unwrap_or(false));
                        }
                        bucket
                    })
                    .collect::<Vec<_>>();
                if let Some(excluded_owner) = expected.excluded_target_owner.as_deref() {
                    executions.push(ExecutionBucket {
                        count: 1,
                        receiver: required
                            .contains(&EvidenceKind::RECEIVER_VALUE.value())
                            .then(|| value_set(excluded_owner, None, SourceRole::NON_PRODUCTION))
                            .into(),
                        target: required
                            .contains(&EvidenceKind::CALL_TARGET.value())
                            .then(|| {
                                target(
                                    excluded_owner,
                                    target_name,
                                    expected.target_kind.as_deref(),
                                    SourceRole::NON_PRODUCTION,
                                )
                            })
                            .into(),
                        provenance: MessageField::some(Provenance {
                            run_id: "oracle-run".to_string(),
                            provider: "canonical-conformance".to_string(),
                            provider_version: "1".to_string(),
                            ..Provenance::default()
                        }),
                        ..ExecutionBucket::default()
                    });
                }
                if let Some(excluded_prefix) = expected.excluded_target_owner_prefix.as_deref() {
                    let excluded_owner = format!("{excluded_prefix}fixture.rb:1)");
                    executions.push(ExecutionBucket {
                        count: 1,
                        receiver: required
                            .contains(&EvidenceKind::RECEIVER_VALUE.value())
                            .then(|| value_set(&excluded_owner, None, SourceRole::NON_PRODUCTION))
                            .into(),
                        target: required
                            .contains(&EvidenceKind::CALL_TARGET.value())
                            .then(|| {
                                target(
                                    &excluded_owner,
                                    target_name,
                                    expected.target_kind.as_deref(),
                                    SourceRole::NON_PRODUCTION,
                                )
                            })
                            .into(),
                        provenance: MessageField::some(Provenance {
                            run_id: "oracle-run".to_string(),
                            provider: "canonical-conformance".to_string(),
                            provider_version: "1".to_string(),
                            ..Provenance::default()
                        }),
                        ..ExecutionBucket::default()
                    });
                }
                let status = match expected.allowed_status.as_deref() {
                    None | Some("COMPLETE_FOR_RUNS") => CaptureStatus::COMPLETE_FOR_RUNS,
                    Some("PARTIAL") => CaptureStatus::PARTIAL,
                    other => panic!("unsupported case status {other:?}"),
                };
                let completed = request
                    .required
                    .iter()
                    .filter(|kind| kind.enum_value().ok().is_some_and(&complete_kind))
                    .cloned()
                    .collect();
                (
                    status,
                    completed,
                    executions,
                    if status == CaptureStatus::COMPLETE_FOR_RUNS {
                        String::new()
                    } else {
                        "call raised before producing its requested result".to_string()
                    },
                )
            } else if let Some(boundary) = boundaries.get(&anchor.symbol) {
                if boundary.allowed_status.is_some() {
                    let status = match boundary.allowed_status.as_deref() {
                        Some("NOT_EXECUTED") => CaptureStatus::NOT_EXECUTED,
                        Some("NOT_INSTRUMENTED") => CaptureStatus::NOT_INSTRUMENTED,
                        other => panic!("unsupported boundary status {other:?}"),
                    };
                    (
                        status,
                        if status == CaptureStatus::NOT_EXECUTED {
                            request.required.clone()
                        } else {
                            Vec::new()
                        },
                        Vec::new(),
                        "function entered but did not produce a return value".to_string(),
                    )
                } else {
                    (
                        CaptureStatus::COMPLETE_FOR_RUNS,
                        request.required.clone(),
                        vec![ExecutionBucket {
                            count: 1,
                            value: MessageField::some(value_set(
                                boundary
                                    .expected_type
                                    .as_deref()
                                    .expect("complete boundary expected type"),
                                None,
                                SourceRole::PRODUCTION,
                            )),
                            provenance: MessageField::some(Provenance {
                                run_id: "oracle-run".to_string(),
                                provider: "canonical-conformance".to_string(),
                                provider_version: "1".to_string(),
                                ..Provenance::default()
                            }),
                            ..ExecutionBucket::default()
                        }],
                        String::new(),
                    )
                }
            } else if correlated.contains(&anchor.symbol) {
                (
                    CaptureStatus::PARTIAL,
                    Vec::new(),
                    Vec::new(),
                    "execution is represented by an exact candidate correlation".to_string(),
                )
            } else {
                (
                    CaptureStatus::NOT_EXECUTED,
                    request.required.clone(),
                    Vec::new(),
                    "anchor did not execute in the canonical modeled run".to_string(),
                )
            };
            AnchorEvidence {
                anchor_symbol: anchor.symbol.clone(),
                anchor_semantic_digest: anchor.semantic_digest.clone(),
                capture: MessageField::some(CaptureSummary {
                    status: EnumOrUnknown::new(status),
                    run_ids: vec!["oracle-run".to_string()],
                    observed_executions: executions.iter().map(|bucket| bucket.count).sum(),
                    reason,
                    complete_kinds,
                    ..CaptureSummary::default()
                }),
                executions,
                ..AnchorEvidence::default()
            }
        })
        .collect();

    let correlations = correlations
        .into_iter()
        .map(|(case, mut symbols)| {
            symbols.sort();
            let requested = symbols
                .iter()
                .flat_map(|symbol| {
                    requests[symbol]
                        .required
                        .iter()
                        .filter_map(|kind| kind.enum_value().ok().map(|kind| kind.value()))
                })
                .collect::<BTreeSet<_>>();
            let owner = case
                .expect
                .target_owner
                .as_deref()
                .unwrap_or("RuntimeEvidenceConformance::Value");
            let name = case.expect.target_name.as_deref().unwrap_or("normalize");
            CorrelationEvidence {
                group_id: format!("conformance-{}", case.id),
                candidate_anchor_symbols: symbols,
                capture: MessageField::some(CaptureSummary {
                    status: EnumOrUnknown::new(CaptureStatus::COMPLETE_FOR_RUNS),
                    run_ids: vec!["oracle-run".to_string()],
                    observed_executions: 1,
                    complete_kinds: requested
                        .iter()
                        .filter_map(|value| EvidenceKind::from_i32(*value))
                        .map(EnumOrUnknown::new)
                        .collect(),
                    ..CaptureSummary::default()
                }),
                executions: vec![ExecutionBucket {
                    count: 1,
                    receiver: MessageField::some(value_set(
                        case.expect
                            .receiver_type
                            .as_deref()
                            .unwrap_or("RuntimeEvidenceConformance::Value"),
                        None,
                        SourceRole::PRODUCTION,
                    )),
                    target: MessageField::some(target(owner, name, None, SourceRole::PRODUCTION)),
                    provenance: MessageField::some(Provenance {
                        run_id: "oracle-run".to_string(),
                        provider: "canonical-conformance".to_string(),
                        provider_version: "1".to_string(),
                        ..Provenance::default()
                    }),
                    ..ExecutionBucket::default()
                }],
                ..CorrelationEvidence::default()
            }
        })
        .collect();

    RuntimeEvidence {
        protocol_version: runtime_protocol::PROTOCOL_VERSION,
        producer: MessageField::some(ToolInfo {
            name: "runtime-evidence-conformance".to_string(),
            version: "1".to_string(),
            ..ToolInfo::default()
        }),
        authority: EnumOrUnknown::new(Authority::MODELED_RUNS),
        trace_plan_digest: built.plan.plan_digest.clone(),
        runs: vec![Run {
            id: "oracle-run".to_string(),
            status: EnumOrUnknown::new(RunStatus::SUCCEEDED),
            test_ids: catalog.cases.iter().map(|case| case.id.clone()).collect(),
            ..Run::default()
        }],
        anchors,
        correlations,
        ..RuntimeEvidence::default()
    }
}

fn occurrence_symbols(index: &serde_json::Value) -> Vec<String> {
    index["documents"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|document| {
            document["occurrences"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|occurrence| occurrence["symbol"].as_str().map(str::to_string))
        })
        .collect()
}

fn occurrence_symbols_at_anchor(
    index: &serde_json::Value,
    anchor: &runtime_protocol::SourceAnchor,
) -> Vec<String> {
    let range = anchor.range.as_ref().expect("anchor range");
    index["documents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|document| {
            document["relativePath"]
                .as_str()
                .is_some_and(|path| path.ends_with(&anchor.relative_path))
        })
        .flat_map(|document| {
            document["occurrences"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|occurrence| {
                    let occurrence_range = occurrence["range"].as_array()?;
                    let numbers = occurrence_range
                        .iter()
                        .filter_map(serde_json::Value::as_u64)
                        .collect::<Vec<_>>();
                    let (start_line, start_character, end_line, end_character) =
                        match numbers.as_slice() {
                            [line, start, end] => (*line, *start, *line, *end),
                            [start_line, start, end_line, end] => {
                                (*start_line, *start, *end_line, *end)
                            }
                            _ => return None,
                        };
                    let contains = (start_line, start_character)
                        <= (range.start_line as u64, range.start_character as u64)
                        && (end_line, end_character)
                            >= (range.end_line as u64, range.end_character as u64);
                    contains.then(|| occurrence["symbol"].as_str().map(str::to_string))?
                })
        })
        .collect()
}

fn assert_validation_error(
    plan: &runtime_protocol::TracePlan,
    evidence: &RuntimeEvidence,
    expected: &str,
) {
    let error = runtime_protocol::validate_runtime_evidence(plan, evidence)
        .expect_err("negative conformance control must fail")
        .to_string();
    assert!(
        error.contains(expected),
        "expected error containing {expected:?}, got {error:?}"
    );
}

#[test]
fn shared_catalog_covers_the_runtime_evidence_v1_behavior_matrix() {
    let (catalog, _source, _output, built) = built_fixture();
    let capabilities = catalog
        .cases
        .iter()
        .flat_map(|case| case.capabilities.iter().map(String::as_str))
        .chain(
            catalog
                .static_closures
                .iter()
                .flat_map(|case| case.capabilities.iter().map(String::as_str)),
        )
        .chain(
            catalog
                .boundary_cases
                .iter()
                .flat_map(|case| case.capabilities.iter().map(String::as_str)),
        )
        .chain(
            catalog
                .merge_cases
                .iter()
                .flat_map(|case| case.capabilities.iter().map(String::as_str)),
        )
        .collect::<BTreeSet<_>>();
    for required in [
        "exact-anchor",
        "ambiguous-anchor",
        "same-line",
        "exact-execution-range",
        "nested-receiver",
        "chained-call",
        "assignment",
        "destructuring",
        "short-circuit-assignment",
        "short-circuit-call",
        "skipped-execution",
        "native-call",
        "set",
        "chained-index",
        "kernel-conversion",
        "sorbet",
        "typed-record",
        "open-struct",
        "string-builder",
        "module-function",
        "project-call",
        "statically-indexed-target",
        "binary-search",
        "logarithmic-iteration",
        "callback-multiplicity",
        "excluded-source",
        "structural-runtime-identity",
        "generated-accessor",
        "anonymous-class",
        "transparent-wrapper",
        "callback",
        "yield",
        "block-parameter",
        "attached-block-range",
        "nested-attached-blocks",
        "generated-setter",
        "dynamic-dispatch",
        "test-replacement",
        "container-shape",
        "exception",
        "non-returning-call",
        "subprocess",
        "result-object",
        "nonproduction-provenance",
        "dependency-provenance",
        "third-party-target",
        "repeated-run",
        "sharded-run",
        "incremental",
        "replacement",
    ] {
        assert!(
            capabilities.contains(required),
            "shared catalog lacks required capability {required}"
        );
    }
    assert!(catalog
        .cases
        .iter()
        .all(|case| case.anchor.is_some() ^ !case.anchors.is_empty()));
    assert!(catalog
        .merge_cases
        .iter()
        .any(|case| case.id == "repeated_runs_are_additive"
            && case.expected_runs == ["run-a", "run-b"]
            && case.expected_count == Some(2)));
    assert!(catalog
        .merge_cases
        .iter()
        .any(|case| case.id == "changed_shard_replaces_owned_evidence"
            && case.expected_runs == ["run-new"]
            && case.forbidden_runs == ["run-old"]));
    assert_eq!(
        catalog.wire_matrix.anchor_kinds,
        [
            "FUNCTION_ENTRY",
            "FUNCTION_RETURN",
            "CALL_SELECTOR",
            "STATE_READ",
            "STATE_WRITE",
            "CALLBACK_ENTRY",
            "COLLECTION_OPERATION",
            "BRANCH_PREDICATE",
        ]
    );
    let planned = built
        .plan
        .requests
        .iter()
        .filter_map(|request| request.anchor.as_ref())
        .filter_map(|anchor| anchor.kind.enum_value().ok())
        .map(|kind| format!("{kind:?}"))
        .collect::<BTreeSet<_>>();
    assert_eq!(
        planned,
        catalog
            .wire_matrix
            .planner_anchor_kinds
            .iter()
            .cloned()
            .collect(),
        "the real FactMine planner surface must equal its executable contract"
    );
    let reserved = catalog
        .wire_matrix
        .reserved_anchor_kinds
        .keys()
        .cloned()
        .collect::<BTreeSet<_>>();
    assert!(
        reserved.intersection(&planned).next().is_none(),
        "a planner kind cannot remain declared reserved"
    );
    assert_eq!(
        reserved.union(&planned).cloned().collect::<BTreeSet<_>>(),
        catalog.wire_matrix.anchor_kinds.iter().cloned().collect(),
        "every wire anchor kind must be executable or explicitly reserved"
    );
    assert!(catalog
        .wire_matrix
        .reserved_anchor_kinds
        .values()
        .all(|reason| !reason.trim().is_empty()));
    assert_eq!(
        catalog.wire_matrix.evidence_kinds,
        [
            "PARAMETER_VALUE",
            "RETURN_VALUE",
            "RECEIVER_VALUE",
            "CALL_TARGET",
            "RESULT_VALUE",
            "BOOLEAN_RESULT",
            "STATE_VALUE",
            "COLLECTION_VALUE",
        ]
    );
    assert_eq!(catalog.wire_matrix.capture_statuses.len(), 7);
    assert_eq!(catalog.wire_matrix.source_roles.len(), 6);
    assert_eq!(
        catalog.wire_matrix.value_shapes,
        ["sequence", "mapping", "record", "tuple"]
    );
    assert!(catalog.wire_matrix.negative_controls.len() >= 10);
    assert_eq!(
        catalog
            .wire_matrix
            .request_contracts
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>(),
        catalog
            .wire_matrix
            .anchor_kinds
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>()
    );
    let declared_evidence = catalog
        .wire_matrix
        .evidence_kinds
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>();
    assert!(catalog
        .wire_matrix
        .request_contracts
        .values()
        .flatten()
        .all(|kind| declared_evidence.contains(kind)));
    for boundary in &catalog.boundary_cases {
        assert!(!boundary.id.is_empty());
        assert!(!boundary.method.is_empty());
        assert!(!boundary.display_name.is_empty());
        assert!(catalog
            .wire_matrix
            .anchor_kinds
            .contains(&boundary.anchor_kind));
        assert!(catalog
            .wire_matrix
            .evidence_kinds
            .contains(&boundary.evidence_kind));
        if boundary.allowed_status.is_none() {
            assert!(boundary
                .expected_type
                .as_deref()
                .is_some_and(|name| !name.is_empty()));
        }
    }
}

#[test]
fn statically_closed_project_calls_are_exact_and_not_retraced() {
    let (catalog, _source, output, built) = built_fixture();
    let methods = output
        .methods
        .iter()
        .map(|method| (method.id.as_str(), method))
        .collect::<BTreeMap<_, _>>();
    for case in &catalog.static_closures {
        let call = selected_call(&output, &case.anchor);
        let target_id = call
            .target
            .as_deref()
            .unwrap_or_else(|| panic!("{} lacks a static target", case.id));
        let target = methods
            .get(target_id)
            .unwrap_or_else(|| panic!("{} target is outside the analyzed corpus", case.id));
        assert_eq!(target.owner, case.expect.target_owner, "{} owner", case.id);
        assert_eq!(target.name, case.expect.target_name, "{} name", case.id);
        assert!(
            !built.bindings.values().any(
                |binding| matches!(binding, runtime_protocol::AnchorBinding::Call { call_id } if call_id == &call.id)
            ),
            "{} redundantly requested runtime evidence for an exact analyzed target",
            case.id
        );
    }
}

#[test]
fn every_planned_call_has_a_closed_execution_range_owned_by_factmine() {
    let (catalog, _source, output, built) = built_fixture();
    for case in &catalog.cases {
        let Some(selector) = &case.anchor else {
            continue;
        };
        let symbol = selected_symbol(&built, &output, selector);
        let request = built
            .plan
            .requests
            .iter()
            .find(|request| request.anchor.as_ref().unwrap().symbol == symbol)
            .expect("catalog request");
        let anchor = request.anchor.as_ref().unwrap().range.as_ref().unwrap();
        let execution = request
            .execution_range
            .as_ref()
            .unwrap_or_else(|| panic!("{} has no execution range", case.id));
        assert!(
            (execution.start_line, execution.start_character)
                <= (anchor.start_line, anchor.start_character)
                && (execution.end_line, execution.end_character)
                    >= (anchor.end_line, anchor.end_character),
            "{} execution range does not contain its selector",
            case.id
        );
        if case.capabilities.iter().any(|capability| {
            matches!(
                capability.as_str(),
                "attached-block-range" | "nested-attached-blocks"
            )
        }) {
            assert!(
                (execution.end_line, execution.end_character)
                    > (anchor.end_line, anchor.end_character),
                "{} did not retain its attached callback body",
                case.id
            );
        }
    }
}

#[test]
fn factmine_oracle_joins_every_canonical_capability_through_its_cfg_and_dfg() {
    let (catalog, _source, mut output, built) = built_fixture();
    let evidence = evidence_for_catalog(&catalog, &output, &built);
    runtime_protocol::validate_runtime_evidence(&built.plan, &evidence)
        .expect("canonical catalog evidence satisfies protocol");
    let overlay = runtime_evidence::apply_protocol_to_profile(&mut output, &built, &evidence)
        .expect("FactMine consumes canonical catalog evidence");
    let symbols = occurrence_symbols(&overlay.index);

    for case in &catalog.cases {
        let expected = &case.expect;
        let declared = expected.required.iter().collect::<BTreeSet<_>>();
        let selectors = case
            .anchor
            .iter()
            .chain(case.anchors.iter())
            .collect::<Vec<_>>();
        for selector in selectors {
            let symbol = selected_symbol(&built, &output, selector);
            let request = built
                .plan
                .requests
                .iter()
                .find(|request| request.anchor.as_ref().unwrap().symbol == symbol)
                .unwrap();
            let actual = request
                .required
                .iter()
                .filter_map(|kind| kind.enum_value().ok())
                .map(|kind| format!("{kind:?}"))
                .collect::<BTreeSet<_>>();
            assert!(
                declared.iter().all(|kind| actual.contains(kind.as_str())),
                "{} expects {:?}, plan requested {:?}",
                case.id,
                declared,
                actual
            );
            let anchor = request.anchor.as_ref().unwrap();
            let at_anchor = occurrence_symbols_at_anchor(&overlay.index, anchor);
            let expected_owners = expected
                .target_owner
                .iter()
                .map(String::as_str)
                .chain(expected.target_owners.iter().map(String::as_str))
                .collect::<Vec<_>>();
            if let Some(name) = expected.target_name.as_deref() {
                for owner in expected_owners {
                    let expected_suffix = format!(
                        "{}{}{}().",
                        descriptor_owner(owner),
                        if expected.target_kind.as_deref() == Some("class") {
                            "."
                        } else {
                            "#"
                        },
                        descriptor_name(name)
                    );
                    if expected.source_role.as_deref() == Some("NON_PRODUCTION") {
                        assert!(
                            !at_anchor
                                .iter()
                                .any(|symbol| symbol.ends_with(&expected_suffix)),
                            "{} published nonproduction target {} at its callsite",
                            case.id,
                            expected_suffix
                        );
                    } else {
                        assert!(
                            at_anchor
                                .iter()
                                .any(|symbol| symbol.ends_with(&expected_suffix)),
                            "{} did not join target {} at its callsite; emitted {:?}",
                            case.id,
                            expected_suffix,
                            at_anchor
                        );
                    }
                }
            }
            if let (Some(owner), Some(name)) = (
                expected.target_owner.as_deref(),
                expected.forbidden_target_name.as_deref(),
            ) {
                let forbidden_suffix =
                    format!("{}#{}().", descriptor_owner(owner), descriptor_name(name));
                assert!(
                    at_anchor
                        .iter()
                        .all(|symbol| !symbol.ends_with(&forbidden_suffix)),
                    "{} published forbidden same-range target {} at its callsite",
                    case.id,
                    forbidden_suffix
                );
            }
            if expected.call_time.is_some() || expected.call_space.is_some() {
                let runtime_protocol::AnchorBinding::Call { call_id } = built
                    .bindings
                    .get(&symbol)
                    .expect("canonical call anchor binding")
                else {
                    panic!("{} complexity expectation is not a call", case.id);
                };
                let call = output
                    .calls
                    .iter()
                    .find(|call| call.id == *call_id)
                    .unwrap_or_else(|| panic!("{} call disappeared after overlay", case.id));
                assert_eq!(
                    call.known_time_complexity.as_deref(),
                    expected.call_time.as_deref(),
                    "{} time complexity mismatch for {} with semantic target {:?}",
                    case.id,
                    call.message,
                    call.semantic_symbol
                );
                assert_eq!(
                    call.known_space_complexity.as_deref(),
                    expected.call_space.as_deref(),
                    "{} space complexity mismatch for {}",
                    case.id,
                    call.message
                );
            }
            if let Some(excluded) = expected.excluded_target_owner.as_deref() {
                assert!(
                    at_anchor
                        .iter()
                        .all(|symbol| !symbol.contains(&excluded.replace("::", "/"))),
                    "{} published excluded target {} at its callsite",
                    case.id,
                    excluded
                );
            }
            if let Some(excluded) = expected.excluded_target_owner_prefix.as_deref() {
                assert!(
                    at_anchor.iter().all(|symbol| !symbol.contains(excluded)),
                    "{} published excluded anonymous target {} at its callsite",
                    case.id,
                    excluded
                );
            }
        }
        for inferred in &expected.factmine_infers {
            let expected_suffix = format!(
                "{}#{}().",
                inferred.target_owner.replace("::", "/"),
                descriptor_name(&inferred.selector)
            );
            assert!(
                symbols
                    .iter()
                    .any(|symbol| symbol.ends_with(&expected_suffix)),
                "{} did not produce inferred {} in {}",
                case.id,
                expected_suffix,
                inferred.method
            );
        }
        if let Some(multiplicity) = expected.iteration_multiplicity.as_deref() {
            let selector = case.anchor.as_ref().expect("iteration case anchor");
            let fact = output
                .complexity_facts
                .iter()
                .find(|fact| fact.function == selector.method)
                .unwrap_or_else(|| panic!("{} method has no complexity facts", case.id));
            let iteration = fact
                .iterations
                .iter()
                .find(|iteration| iteration.message.as_deref() == Some(&selector.selector))
                .unwrap_or_else(|| panic!("{} has no normalized iteration", case.id));
            assert_eq!(
                iteration.execution_multiplicity, multiplicity,
                "{} callback/iteration multiplicity",
                case.id
            );
            assert!(
                iteration.evidence_gap.is_none(),
                "{} retained iteration evidence gap {:?}",
                case.id,
                iteration.evidence_gap
            );
            assert!(
                fact.call_contexts.iter().any(|context| {
                    context.message != selector.selector
                        && context.execution_multiplicity == multiplicity
                        && context.span[0] >= iteration.span[0]
                        && context.span[2] <= iteration.span[2]
                }),
                "{} did not apply logarithmic multiplicity to its callback body",
                case.id
            );
        }
        assert_eq!(
            case.expect.correlation,
            !case.anchors.is_empty(),
            "{} correlation declaration disagrees with its anchor shape",
            case.id
        );
    }
    for boundary in &catalog.boundary_cases {
        let symbol = boundary_symbol(&built, &output, boundary);
        let row = evidence
            .anchors
            .iter()
            .find(|row| row.anchor_symbol == symbol)
            .expect("canonical boundary evidence");
        let expected_status = match boundary.allowed_status.as_deref() {
            Some("NOT_EXECUTED") => CaptureStatus::NOT_EXECUTED,
            Some("NOT_INSTRUMENTED") => CaptureStatus::NOT_INSTRUMENTED,
            None => CaptureStatus::COMPLETE_FOR_RUNS,
            other => panic!("unsupported boundary status {other:?}"),
        };
        assert_eq!(
            row.capture.as_ref().unwrap().status.enum_value_or_default(),
            expected_status,
            "{} has the wrong canonical status",
            boundary.id
        );
        assert_eq!(
            row.executions.len(),
            usize::from(expected_status == CaptureStatus::COMPLETE_FOR_RUNS),
            "{} retained the wrong number of canonical value buckets",
            boundary.id
        );
    }
}

#[test]
fn shared_negative_controls_fail_closed_at_the_protocol_boundary() {
    let (catalog, _source, output, built) = built_fixture();
    let canonical = evidence_for_catalog(&catalog, &output, &built);
    runtime_protocol::validate_runtime_evidence(&built.plan, &canonical)
        .expect("negative controls start from canonical evidence");
    let mut exercised = BTreeSet::new();

    let json = runtime_protocol::to_json(&canonical).expect("canonical ProtoJSON");
    let unknown = json.replacen('{', "{\"unknown_contract_field\":true,", 1);
    assert!(runtime_protocol::parse_runtime_evidence_json(&unknown).is_err());
    exercised.insert("unknown-field");

    let mut evidence = canonical.clone();
    evidence.anchors.pop();
    assert_validation_error(&built.plan, &evidence, "omits requested anchors");
    exercised.insert("missing-anchor");

    let mut evidence = canonical.clone();
    evidence.anchors.push(evidence.anchors[0].clone());
    assert_validation_error(&built.plan, &evidence, "duplicate evidence");
    exercised.insert("duplicate-anchor");

    let mut evidence = canonical.clone();
    evidence.trace_plan_digest[0] ^= 0xff;
    assert_validation_error(&built.plan, &evidence, "trace_plan_digest");
    exercised.insert("stale-plan-digest");

    let mut evidence = canonical.clone();
    evidence.anchors[0].anchor_semantic_digest[0] ^= 0xff;
    assert_validation_error(&built.plan, &evidence, "semantic digest");
    exercised.insert("stale-anchor-digest");

    let mut evidence = canonical.clone();
    let row = evidence
        .anchors
        .iter_mut()
        .find(|row| {
            row.executions
                .iter()
                .any(|bucket| bucket.receiver.is_some())
        })
        .expect("canonical receiver evidence");
    row.executions[0].receiver = MessageField::none();
    assert_validation_error(&built.plan, &evidence, "lacks required receiver");
    exercised.insert("incomplete-kind-without-field");

    let mut evidence = canonical.clone();
    evidence
        .anchors
        .iter_mut()
        .find(|row| {
            row.capture.as_ref().is_some_and(|capture| {
                capture.status.enum_value_or_default() == CaptureStatus::COMPLETE_FOR_RUNS
            }) && !row.executions.is_empty()
        })
        .expect("canonical complete execution")
        .capture
        .as_mut()
        .unwrap()
        .dropped_executions = 1;
    assert_validation_error(&built.plan, &evidence, "dropped");
    exercised.insert("complete-with-dropped-execution");

    let mut evidence = canonical.clone();
    let row = evidence
        .anchors
        .iter_mut()
        .find(|row| {
            row.executions
                .iter()
                .any(|bucket| bucket.receiver.is_some())
        })
        .expect("canonical receiver evidence");
    row.executions[0].receiver.as_mut().unwrap().truncated = true;
    assert_validation_error(&built.plan, &evidence, "truncated");
    exercised.insert("complete-with-truncated-value");

    let mut evidence = canonical.clone();
    let bucket = evidence
        .anchors
        .iter_mut()
        .flat_map(|row| row.executions.iter_mut())
        .next()
        .expect("canonical execution");
    bucket.provenance.as_mut().unwrap().run_id = "unknown-run".to_string();
    assert_validation_error(&built.plan, &evidence, "outside capture runs");
    exercised.insert("unknown-run-provenance");

    let mut plan = built.plan.clone();
    plan.documents[0].relative_path = "./noncanonical.rb".to_string();
    assert!(runtime_protocol::validate_trace_plan(&plan)
        .unwrap_err()
        .to_string()
        .contains("canonical"));
    exercised.insert("noncanonical-path");

    let mut plan = built.plan.clone();
    let request = plan
        .requests
        .iter_mut()
        .find(|request| request.execution_range.is_some())
        .expect("canonical call request");
    request.execution_range = MessageField::none();
    assert!(runtime_protocol::validate_trace_plan(&plan)
        .unwrap_err()
        .to_string()
        .contains("execution_range is required"));
    exercised.insert("missing-call-execution-range");

    let mut plan = built.plan.clone();
    let request = plan
        .requests
        .iter_mut()
        .find(|request| request.execution_range.is_some())
        .expect("canonical call request");
    let anchor_range = request.anchor.as_ref().unwrap().range.as_ref().unwrap();
    let execution_range = request.execution_range.as_mut().unwrap();
    execution_range.start_line = anchor_range.end_line;
    execution_range.start_character = anchor_range.end_character;
    assert!(runtime_protocol::validate_trace_plan(&plan)
        .unwrap_err()
        .to_string()
        .contains("must contain the complete anchor range"));
    exercised.insert("execution-range-excludes-selector");

    let mut plan = built.plan.clone();
    let request = plan
        .requests
        .iter_mut()
        .find(|request| {
            request
                .anchor
                .as_ref()
                .unwrap()
                .kind
                .enum_value_or_default()
                == runtime_protocol::AnchorKind::FUNCTION_ENTRY
        })
        .expect("canonical function-entry request");
    request.required = vec![EvidenceKind::CALL_TARGET.into()];
    assert!(runtime_protocol::validate_trace_plan(&plan)
        .unwrap_err()
        .to_string()
        .contains("incompatible"));
    exercised.insert("incompatible-anchor-evidence");

    let mut evidence = canonical;
    let target = evidence
        .anchors
        .iter_mut()
        .flat_map(|row| row.executions.iter_mut())
        .find_map(|bucket| bucket.target.as_mut())
        .expect("canonical target");
    target.symbol = "not a canonical SCIP symbol".to_string();
    assert_validation_error(&built.plan, &evidence, "target.symbol");
    exercised.insert("noncanonical-symbol");

    assert_eq!(
        exercised,
        catalog
            .wire_matrix
            .negative_controls
            .iter()
            .map(String::as_str)
            .collect(),
        "every declared negative control must execute"
    );
}

#[test]
fn every_capture_status_is_executable_and_noncomplete_statuses_require_reasons() {
    let (catalog, _source, output, built) = built_fixture();
    let canonical = evidence_for_catalog(&catalog, &output, &built);
    let mut exercised = BTreeSet::new();
    for status_name in &catalog.wire_matrix.capture_statuses {
        let status = match status_name.as_str() {
            "COMPLETE_FOR_RUNS" => CaptureStatus::COMPLETE_FOR_RUNS,
            "NOT_EXECUTED" => CaptureStatus::NOT_EXECUTED,
            "PARTIAL" => CaptureStatus::PARTIAL,
            "NOT_INSTRUMENTED" => CaptureStatus::NOT_INSTRUMENTED,
            "UNSUPPORTED" => CaptureStatus::UNSUPPORTED,
            "STALE" => CaptureStatus::STALE,
            "FAILED_CAPTURE" => CaptureStatus::FAILED_CAPTURE,
            other => panic!("unknown catalog status {other}"),
        };
        let mut evidence = canonical.clone();
        let row_index = evidence
            .anchors
            .iter()
            .position(|row| {
                row.capture.as_ref().is_some_and(|capture| {
                    capture.status.enum_value_or_default() == CaptureStatus::COMPLETE_FOR_RUNS
                }) && !row.executions.is_empty()
            })
            .expect("canonical complete execution");
        {
            let row = &mut evidence.anchors[row_index];
            let capture = row.capture.as_mut().unwrap();
            capture.status = EnumOrUnknown::new(status);
            if status == CaptureStatus::COMPLETE_FOR_RUNS {
                capture.reason.clear();
            } else {
                row.executions.clear();
                capture.observed_executions = 0;
                capture.dropped_executions = 0;
                capture.complete_kinds.clear();
                capture.reason = format!("{status_name} conformance explanation");
            }
        }
        runtime_protocol::validate_runtime_evidence(&built.plan, &evidence)
            .unwrap_or_else(|error| panic!("{status_name} must be valid: {error:#}"));
        exercised.insert(status_name.as_str());

        if status != CaptureStatus::COMPLETE_FOR_RUNS {
            evidence.anchors[row_index]
                .capture
                .as_mut()
                .unwrap()
                .reason
                .clear();
            assert_validation_error(&built.plan, &evidence, "requires a precise reason");
        }
    }
    assert_eq!(
        exercised,
        catalog
            .wire_matrix
            .capture_statuses
            .iter()
            .map(String::as_str)
            .collect()
    );
}

#[test]
fn every_value_shape_and_source_role_validates_and_joins_through_factmine() {
    let (catalog, _source, output, built) = built_fixture();
    let parameter = catalog
        .boundary_cases
        .iter()
        .find(|boundary| boundary.evidence_kind == "PARAMETER_VALUE")
        .expect("parameter boundary");
    let parameter_symbol = boundary_symbol(&built, &output, parameter);
    let roles = catalog
        .wire_matrix
        .source_roles
        .iter()
        .map(|name| {
            (
                name,
                match name.as_str() {
                    "PRODUCTION" => SourceRole::PRODUCTION,
                    "NON_PRODUCTION" => SourceRole::NON_PRODUCTION,
                    "STANDARD_LIBRARY" => SourceRole::STANDARD_LIBRARY,
                    "DEPENDENCY" => SourceRole::DEPENDENCY,
                    "RUNTIME" => SourceRole::RUNTIME,
                    "UNKNOWN_SOURCE" => SourceRole::UNKNOWN_SOURCE,
                    other => panic!("unknown catalog source role {other}"),
                },
            )
        })
        .collect::<Vec<_>>();

    let mut exercised = BTreeSet::new();
    for shape in &catalog.wire_matrix.value_shapes {
        for (role_name, role) in &roles {
            let mut evidence = evidence_for_catalog(&catalog, &output, &built);
            let row = evidence
                .anchors
                .iter_mut()
                .find(|row| row.anchor_symbol == parameter_symbol)
                .expect("parameter evidence");
            row.executions[0].value = MessageField::some(shaped_value_set(shape, *role));
            runtime_protocol::validate_runtime_evidence(&built.plan, &evidence)
                .unwrap_or_else(|error| panic!("{shape}/{role_name} must validate: {error:#}"));
            let mut joined = output.clone();
            runtime_evidence::apply_protocol_to_profile(&mut joined, &built, &evidence)
                .unwrap_or_else(|error| panic!("{shape}/{role_name} must join: {error:#}"));
            exercised.insert((shape.as_str(), role_name.as_str()));
        }
    }
    assert_eq!(
        exercised.len(),
        catalog.wire_matrix.value_shapes.len() * catalog.wire_matrix.source_roles.len()
    );
}
