use super::fact_helpers;
use crate::schemas::{Action, InputState};
use std::collections::{BTreeMap, BTreeSet, HashMap};

#[derive(Default)]
struct PrimitiveDomain {
    values: BTreeSet<String>,
    decision_sites: BTreeSet<String>,
    producer_sites: BTreeSet<String>,
    path: String,
    line: i64,
    kind: String,
    literal_kind: String,
    slot: String,
    blocked: bool,
    strong_decision: bool,
}

fn is_closed(domain: &PrimitiveDomain) -> bool {
    !domain.blocked && (2..=10).contains(&domain.values.len())
}

fn has_sufficient_evidence(domain: &PrimitiveDomain) -> bool {
    domain.decision_sites.len() >= 2
        || (domain.strong_decision && !domain.producer_sites.is_empty())
}

/// Reports closed-looking primitive state domains from FactMine's normalized
/// hidden-enum observations. Parameters are deliberately excluded: without a
/// proven caller contract they are open-world inputs rather than candidates.
pub(super) fn report(input: &InputState) -> Vec<Action> {
    let mut domains = BTreeMap::<String, PrimitiveDomain>::new();
    for observation in fact_helpers::objects(input, "hidden_enum_observations") {
        // Keep each stable FactMine identity separate rather than grouping
        // conditions by spelling or literal set.
        if !matches!(
            fact_helpers::string(observation, "kind"),
            Some("state" | "local")
        ) {
            continue;
        }
        let Some(key) = fact_helpers::string(observation, "key") else {
            continue;
        };
        let domain = domains.entry(key.to_string()).or_default();
        domain.path = fact_helpers::string(observation, "path")
            .unwrap_or("")
            .to_string();
        domain.line = fact_helpers::i64(observation, "line").unwrap_or(0);
        domain.kind = fact_helpers::string(observation, "kind")
            .unwrap_or("state")
            .to_string();
        domain.slot = fact_helpers::string(observation, "slot")
            .unwrap_or("")
            .to_string();
        let site = observation
            .get("site")
            .and_then(serde_json::Value::as_object);
        let site_id = site.map(|site| {
            let line = fact_helpers::i64(site, "line").unwrap_or(0);
            format!(
                "{}:{line}",
                fact_helpers::string(site, "path").unwrap_or("")
            )
        });
        match fact_helpers::string(observation, "event") {
            Some("decision") => {
                if let Some(site_id) = site_id {
                    domain.decision_sites.insert(site_id);
                }
                domain.strong_decision |= site
                    .and_then(|site| fact_helpers::string(site, "kind"))
                    .is_some_and(|kind| matches!(kind, "case" | "switch"));
                add_values(domain, observation);
            }
            Some("producer") => {
                if let Some(site_id) = site_id {
                    domain.producer_sites.insert(site_id);
                }
                add_values(domain, observation);
            }
            Some("blocker") => domain.blocked = true,
            _ => {}
        }
    }
    domains
        .into_values()
        .filter(|domain| is_closed(domain) && has_sufficient_evidence(domain))
        .map(|domain| Action {
            kind: "report_static_primitive_domain".to_string(),
            confidence: "review".to_string(),
            path: domain.path,
            line: domain.line,
            message: format!(
                "{} {} has a closed-looking {} domain across {} decision sites",
                domain.kind,
                domain.slot,
                domain.literal_kind,
                domain.decision_sites.len()
            ),
            data: HashMap::from([
                ("slot".to_string(), serde_json::Value::String(domain.slot)),
                (
                    "values".to_string(),
                    fact_helpers::json_strings(domain.values),
                ),
                (
                    "decision_sites".to_string(),
                    fact_helpers::json_strings(domain.decision_sites),
                ),
            ]),
        })
        .collect()
}

fn add_values(
    domain: &mut PrimitiveDomain,
    observation: &serde_json::Map<String, serde_json::Value>,
) {
    let Some(values) = observation
        .get("values")
        .and_then(serde_json::Value::as_array)
    else {
        domain.blocked = true;
        return;
    };
    if values.is_empty() {
        domain.blocked = true;
        return;
    }
    for value in values {
        let Some(kind) = value.get("kind").and_then(serde_json::Value::as_str) else {
            domain.blocked = true;
            return;
        };
        if !matches!(kind, "String" | "Symbol" | "Integer")
            || (!domain.literal_kind.is_empty() && domain.literal_kind != kind)
        {
            domain.blocked = true;
            return;
        }
        let Some(value) = value.get("value").and_then(serde_json::Value::as_str) else {
            domain.blocked = true;
            return;
        };
        domain.literal_kind = kind.to_string();
        domain.values.insert(value.to_string());
    }
}
