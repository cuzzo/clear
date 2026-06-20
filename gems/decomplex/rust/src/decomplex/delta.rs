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
