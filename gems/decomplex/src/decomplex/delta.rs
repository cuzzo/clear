use crate::decomplex::report::ReportSection;
use crate::decomplex::root_cause::{self, Cluster};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

const SEP: &str = "\t";

pub fn snapshot(sections: &[ReportSection], clusters: &[Cluster]) -> Value {
    let mut findings: BTreeMap<String, i64> = BTreeMap::new();
    let mut details: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for section in sections {
        for finding in &section.findings {
            let fp = fingerprint(&section.title, finding);
            *findings.entry(fp.clone()).or_insert(0) += 1;
            details
                .entry(fp)
                .or_default()
                .push(json_safe_finding(&section.title, finding));
        }
    }

    let mut site: BTreeMap<String, i64> = BTreeMap::new();
    let mut site_details: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for section in sections {
        for finding in &section.findings {
            let detail = json_safe_finding(&section.title, finding);
            for sfp in site_fingerprints(&section.title, finding) {
                *site.entry(sfp.clone()).or_insert(0) += 1;
                site_details.entry(sfp).or_default().push(detail.clone());
            }
        }
    }

    let mut cluster_values = Map::new();
    for cluster in clusters {
        cluster_values.insert(
            format!("{}{}{}", cluster.kind, SEP, cluster.token),
            json!({
                "n": cluster.n_detectors,
                "s": cluster.support,
                "fat": cluster.fat_union,
            }),
        );
    }
    let total = findings.values().sum::<i64>();
    json!({
        "findings": findings,
        "site_findings": site,
        "details": details,
        "site_details": site_details,
        "clusters": cluster_values,
        "total": total,
    })
}

pub fn fingerprint(detector: &str, finding: &Value) -> String {
    let mut entities = root_cause::entities(finding)
        .into_iter()
        .map(|entity| format!("{}:{}", entity.kind, entity.token))
        .collect::<Vec<_>>();
    entities.sort();
    let mut units = root_cause::finding_units(finding)
        .into_iter()
        .map(|(file, method)| format!("{file}#{method}"))
        .collect::<Vec<_>>();
    units.sort();
    units.dedup();
    [detector.to_string(), entities.join(","), units.join(",")].join(SEP)
}

pub fn site_fingerprints(detector: &str, finding: &Value) -> Vec<String> {
    let mut entities = root_cause::entities(finding)
        .into_iter()
        .map(|entity| format!("{}:{}", entity.kind, entity.token))
        .collect::<Vec<_>>();
    entities.sort();
    let entity_text = entities.join(",");
    let mut units = root_cause::finding_units(finding)
        .into_iter()
        .map(|(file, method)| format!("{file}#{method}"))
        .collect::<Vec<_>>();
    units.sort();
    units.dedup();
    units
        .into_iter()
        .map(|unit| [detector.to_string(), entity_text.clone(), unit].join(SEP))
        .collect()
}

pub fn json_safe_finding(detector: &str, finding: &Value) -> Value {
    let mut object = finding.as_object().cloned().unwrap_or_default();
    object.insert("detector".to_string(), Value::String(detector.to_string()));
    Value::Object(object)
}

pub fn diff(baseline: &Value, head: &Value) -> Value {
    let baseline = embedded_snapshot(baseline);
    let head = embedded_snapshot(head);
    let before = count_map(baseline, "site_findings");
    let after = count_map(head, "site_findings");
    let keys = before
        .keys()
        .chain(after.keys())
        .cloned()
        .collect::<std::collections::BTreeSet<_>>();

    let mut introduced = Vec::new();
    let mut resolved = Vec::new();
    let mut persisted = Vec::new();
    for fingerprint in keys {
        let old = before.get(&fingerprint).copied().unwrap_or(0);
        let new = after.get(&fingerprint).copied().unwrap_or(0);
        if new > old {
            introduced.push(delta_entry(head, &fingerprint, new - old));
        }
        if old > new {
            resolved.push(delta_entry(baseline, &fingerprint, old - new));
        }
        if old.min(new) > 0 {
            persisted.push(delta_entry(head, &fingerprint, old.min(new)));
        }
    }

    let introduced_total = delta_total(&introduced);
    let resolved_total = delta_total(&resolved);
    let persisted_total = delta_total(&persisted);
    json!({
        "introduced": { "total": introduced_total, "findings": introduced },
        "resolved": { "total": resolved_total, "findings": resolved },
        "persisted": { "total": persisted_total, "findings": persisted },
        "net": introduced_total - resolved_total,
    })
}

pub fn to_markdown(delta: &Value) -> String {
    let introduced = delta
        .pointer("/introduced/total")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let resolved = delta
        .pointer("/resolved/total")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let persisted = delta
        .pointer("/persisted/total")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let net = delta.get("net").and_then(Value::as_i64).unwrap_or(0);
    let mut out = format!(
        "# Decomplex Delta\n\n- Introduced: **{introduced}**\n- Resolved: **{resolved}**\n- Persisted: **{persisted}**\n- Net: **{net:+}**\n\n"
    );
    render_delta_section(
        &mut out,
        "Resolved structural findings",
        delta.pointer("/resolved/findings"),
    );
    render_delta_section(
        &mut out,
        "Introduced structural findings",
        delta.pointer("/introduced/findings"),
    );
    out
}

fn embedded_snapshot(value: &Value) -> &Value {
    value
        .pointer("/runs/0/properties/decomplex.snapshot")
        .unwrap_or(value)
}

fn count_map(snapshot: &Value, field: &str) -> BTreeMap<String, i64> {
    snapshot
        .get(field)
        .or_else(|| snapshot.get("findings"))
        .and_then(Value::as_object)
        .map(|values| {
            values
                .iter()
                .filter_map(|(key, value)| value.as_i64().map(|count| (key.clone(), count)))
                .collect()
        })
        .unwrap_or_default()
}

fn delta_entry(snapshot: &Value, fingerprint: &str, count: i64) -> Value {
    let details = snapshot
        .get("site_details")
        .or_else(|| snapshot.get("details"))
        .and_then(Value::as_object)
        .and_then(|values| values.get(fingerprint))
        .cloned()
        .unwrap_or_else(|| json!([]));
    json!({ "fingerprint": fingerprint, "count": count, "details": details })
}

fn delta_total(entries: &[Value]) -> i64 {
    entries
        .iter()
        .filter_map(|entry| entry.get("count").and_then(Value::as_i64))
        .sum()
}

fn render_delta_section(out: &mut String, title: &str, findings: Option<&Value>) {
    out.push_str(&format!("## {title}\n\n"));
    let findings = findings
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if findings.is_empty() {
        out.push_str("None.\n\n");
        return;
    }
    for finding in findings {
        let count = finding.get("count").and_then(Value::as_i64).unwrap_or(0);
        let fingerprint = finding
            .get("fingerprint")
            .and_then(Value::as_str)
            .unwrap_or("");
        let detail = finding
            .get("details")
            .and_then(Value::as_array)
            .and_then(|values| values.first())
            .and_then(Value::as_object)
            .and_then(|object| object.get("at").or_else(|| object.get("detail")))
            .and_then(Value::as_str)
            .unwrap_or(fingerprint);
        out.push_str(&format!("- `{detail}` — {count}\n"));
    }
    out.push('\n');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delta_credits_resolved_and_consolidated_findings() {
        let baseline = json!({
            "site_findings": { "tuple": 1, "grammar": 2 },
            "site_details": {
                "tuple": [{ "detail": "semantic tuple pressure" }],
                "grammar": [{ "detail": "duplicated grammar branch" }]
            }
        });
        let head = json!({
            "site_findings": { "grammar": 1, "record": 1 },
            "site_details": {
                "grammar": [{ "detail": "duplicated grammar branch" }],
                "record": [{ "detail": "new record issue" }]
            }
        });

        let result = diff(&baseline, &head);
        assert_eq!(
            result.pointer("/resolved/total").and_then(Value::as_i64),
            Some(2)
        );
        assert_eq!(
            result.pointer("/introduced/total").and_then(Value::as_i64),
            Some(1)
        );
        assert_eq!(
            result.pointer("/persisted/total").and_then(Value::as_i64),
            Some(1)
        );
        assert_eq!(result.get("net").and_then(Value::as_i64), Some(-1));
        let markdown = to_markdown(&result);
        assert!(markdown.contains("semantic tuple pressure"));
        assert!(markdown.contains("duplicated grammar branch"));
    }

    #[test]
    fn delta_reads_snapshots_embedded_in_sarif() {
        let sarif = json!({ "runs": [{ "properties": { "decomplex.snapshot": {
            "site_findings": { "old": 1 }
        } } }] });
        let result = diff(&sarif, &json!({ "site_findings": {} }));
        assert_eq!(
            result.pointer("/resolved/total").and_then(Value::as_i64),
            Some(1)
        );
    }
}
