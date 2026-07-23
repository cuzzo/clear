use super::fact_helpers;
use crate::schemas::{Action, InputState};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Produces a review-only causal report from FactMine's public nullable
/// facts. NilKill deliberately receives no source text, normalized AST, or
/// CFG here: FactMine has already joined each obligation to its exact nullable
/// reaching-definition IDs.
pub(super) fn report(input: &InputState) -> Vec<Action> {
    let mut roots = roots(&fact_helpers::objects(input, "nullable_states"));
    attach_guards(
        &mut roots,
        &fact_helpers::objects(input, "nullable_refinements"),
    );
    attach_returns(
        &mut roots,
        &fact_helpers::objects(input, "nullable_summaries"),
    );
    attach_operations(
        &mut roots,
        &fact_helpers::objects(input, "nullable_operations"),
    );
    actions(roots)
}

fn roots(states: &[&serde_json::Map<String, serde_json::Value>]) -> BTreeMap<String, Evidence> {
    let mut roots = BTreeMap::<String, Evidence>::new();
    for state in states {
        if !is_nullable(fact_helpers::string(state, "state"))
            || !fact_helpers::bool(state, "complete")
        {
            continue;
        }
        for root in fact_helpers::strings(state, "source_definition_ids") {
            roots.entry(root.to_string()).or_default();
        }
    }
    roots
}

fn attach_guards(
    roots: &mut BTreeMap<String, Evidence>,
    refinements: &[&serde_json::Map<String, serde_json::Value>],
) {
    for refinement in refinements {
        if !fact_helpers::bool(refinement, "complete") {
            continue;
        }
        let (Some(place_id), Some(condition)) = (
            fact_helpers::string(refinement, "place_id"),
            fact_helpers::string(refinement, "condition_node_id"),
        ) else {
            continue;
        };
        if condition.is_empty() {
            continue;
        }
        for root in fact_helpers::strings(refinement, "source_definition_ids") {
            if let Some(evidence) = roots.get_mut(root) {
                evidence.guards.insert(format!("{place_id}:{condition}"));
            }
        }
    }
}

fn attach_returns(
    roots: &mut BTreeMap<String, Evidence>,
    summaries: &[&serde_json::Map<String, serde_json::Value>],
) {
    for (root, evidence) in roots {
        for summary in summaries {
            if is_nullable(fact_helpers::string(summary, "return_state"))
                && fact_helpers::bool(summary, "complete")
                && fact_helpers::strings(summary, "source_definition_ids").contains(&root.as_str())
            {
                let owner = fact_helpers::string(summary, "owner").unwrap_or("");
                let function = fact_helpers::string(summary, "function").unwrap_or("");
                evidence.returns.insert(format!("{owner}#{function}"));
            }
        }
    }
}

fn attach_operations(
    roots: &mut BTreeMap<String, Evidence>,
    operations: &[&serde_json::Map<String, serde_json::Value>],
) {
    for operation in operations {
        let behavior = fact_helpers::string(operation, "nil_behavior").unwrap_or("unknown");
        if matches!(behavior, "safe" | "unknown") || !fact_helpers::bool(operation, "complete") {
            continue;
        }
        let location = OperationLocation {
            path: fact_helpers::string(operation, "path")
                .unwrap_or("")
                .to_string(),
            line: fact_helpers::span_line(operation),
        };
        if !location.is_real_source_location() {
            continue;
        }
        let node = fact_helpers::string(operation, "node_id").unwrap_or("");
        let kind = fact_helpers::string(operation, "operation_kind").unwrap_or("");
        for root in fact_helpers::strings(operation, "source_definition_ids") {
            if let Some(evidence) = roots.get_mut(root) {
                evidence
                    .operations
                    .insert(format!("{kind}:{node}"), location.clone());
            }
        }
    }
}

fn is_nullable(state: Option<&str>) -> bool {
    matches!(state, Some("definitely_null" | "maybe_null"))
}

fn actions(roots: BTreeMap<String, Evidence>) -> Vec<Action> {
    roots
        .into_iter()
        .filter_map(|(root, evidence)| {
            let pressure =
                evidence.guards.len() + evidence.returns.len() + evidence.operations.len();
            let location = evidence.operations.values().next().cloned()?;
            (pressure > 0).then(|| Action {
                kind: "report_static_nil_pressure".to_string(),
                confidence: "review".to_string(),
                path: location.path,
                line: location.line,
                message: format!(
                    "nullable root {root} creates {pressure} independently necessary obligations"
                ),
                data: HashMap::from([
                    (
                        "root_definition_id".to_string(),
                        serde_json::Value::String(root),
                    ),
                    (
                        "pressure".to_string(),
                        serde_json::Value::Number(serde_json::Number::from(pressure)),
                    ),
                    (
                        "guard_clusters".to_string(),
                        fact_helpers::json_strings(evidence.guards),
                    ),
                    (
                        "nullable_returns".to_string(),
                        fact_helpers::json_strings(evidence.returns),
                    ),
                    (
                        "unsafe_operations".to_string(),
                        fact_helpers::json_strings(evidence.operations.into_keys().collect()),
                    ),
                ]),
            })
        })
        .collect()
}

#[derive(Default)]
struct Evidence {
    guards: BTreeSet<String>,
    returns: BTreeSet<String>,
    operations: BTreeMap<String, OperationLocation>,
}

#[derive(Clone, Default)]
struct OperationLocation {
    path: String,
    line: i64,
}

impl OperationLocation {
    fn is_real_source_location(&self) -> bool {
        !self.path.is_empty() && self.line > 0
    }
}
