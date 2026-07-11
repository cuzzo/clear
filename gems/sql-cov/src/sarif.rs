use crate::hazard::HazardReport;
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub fn hazard_json(report: &HazardReport) -> Result<String> {
    Ok(serde_json::to_string_pretty(report)?)
}

pub fn hazard_sarif(report: &HazardReport, sqlfluff_sarif: Option<&str>) -> Result<String> {
    let mut rules = BTreeMap::<String, Value>::new();
    let mut results = Vec::new();

    // 1. Add SQL-cov rules and results (Tier 1 by default)
    for finding in &report.findings {
        rules.entry(finding.rule_id.clone()).or_insert_with(|| {
            json!({
                "id": finding.rule_id,
                "name": format!("{:?}", finding.kind),
                "shortDescription": { "text": finding.message },
                "help": { "text": finding.recommendation },
                "properties": {
                    "category": "SQL three-valued logic",
                    "precision": "high",
                    "tags": ["correctness", "sql", "null", "unknown"],
                    "tier": "T1"
                }
            })
        });

        results.push(json!({
            "ruleId": finding.rule_id,
            "level": "warning",
            "message": {
                "text": format!("{}. {}", finding.message, finding.evidence.join("; "))
            },
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": { "uri": report.file_path },
                    "region": {
                        "startLine": finding.span.start_line,
                        "startColumn": finding.span.start_column,
                        "endLine": finding.span.end_line,
                        "endColumn": finding.span.end_column,
                        "snippet": { "text": finding.span.raw_expression }
                    }
                }
            }],
            "properties": {
                "findingId": finding.id,
                "kind": finding.kind,
                "nullabilityEvidence": finding.evidence,
                "recommendation": finding.recommendation,
                "schemaValidated": true,
                "tier": "T1"
            }
        }));
    }

    // 2. Parse and merge SQLFluff findings if provided
    if let Some(fluff_sarif_str) = sqlfluff_sarif {
        if let Ok(fluff_val) = serde_json::from_str::<Value>(fluff_sarif_str) {
            if let Some(runs) = fluff_val.get("runs").and_then(|r| r.as_array()) {
                for run in runs {
                    // Extract rules defined by SQLFluff
                    if let Some(fluff_rules) = run.get("tool").and_then(|t| t.get("driver")).and_then(|d| d.get("rules")).and_then(|r| r.as_array()) {
                        for rule in fluff_rules {
                            if let Some(id) = rule.get("id").and_then(|i| i.as_str()) {
                                let tier = match id {
                                    "AM05" => "T1",
                                    "CV02" | "CV01" => "T2",
                                    _ => "T3",
                                };
                                let mut merged_rule = rule.clone();
                                if let Some(props) = merged_rule.get_mut("properties").and_then(|p| p.as_object_mut()) {
                                    props.insert("tier".to_string(), json!(tier));
                                } else {
                                    merged_rule["properties"] = json!({ "tier": tier });
                                }
                                rules.insert(id.to_string(), merged_rule);
                            }
                        }
                    }

                    // Extract results reported by SQLFluff
                    if let Some(fluff_results) = run.get("results").and_then(|r| r.as_array()) {
                        for result in fluff_results {
                            if let Some(rule_id) = result.get("ruleId").and_then(|r| r.as_str()) {
                                let tier = match rule_id {
                                    "AM05" => "T1",
                                    "CV02" | "CV01" => "T2",
                                    _ => "T3",
                                };
                                let mut merged_result = result.clone();
                                if let Some(props) = merged_result.get_mut("properties").and_then(|p| p.as_object_mut()) {
                                    props.insert("tier".to_string(), json!(tier));
                                } else {
                                    merged_result["properties"] = json!({ "tier": tier });
                                }
                                results.push(merged_result);
                            }
                        }
                    }
                }
            }
        }
    }

    let document = json!({
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {
                "driver": {
                    "name": "sql-cov-hazards",
                    "informationUri": "https://cuzzo.github.io/clear/blog/an-ode-to-sql/",
                    "semanticVersion": env!("CARGO_PKG_VERSION"),
                    "rules": rules.into_values().collect::<Vec<_>>()
                }
            },
            "results": results,
            "properties": {
                "format": report.format,
                "dialect": report.dialect,
                "unresolvedSchemaFacts": report.unresolved_schema_facts
            }
        }]
    });
    Ok(serde_json::to_string_pretty(&document)?)
}
