use crate::hazard::HazardReport;
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn sqlfluff_policy(rule_id: &str) -> (&'static str, &'static str) {
    match rule_id {
        // SQLFluff uses these pseudo-rules when it cannot reliably analyze the
        // file at all. They are integration/correctness failures, not style.
        "LXR" | "PRS" | "TMP" => ("T1", "error"),
        // These rules identify semantic ambiguity with plausible correctness
        // consequences. They remain advisory because intent is contextual.
        "AL04" | "AL08" | "AM01" | "AM02" | "AM07" | "AM08" | "AM09" | "RF01" | "ST03" | "ST10"
        | "ST11" => ("T2", "warning"),
        // Formatting, capitalization, alias preferences, and every unreviewed
        // SQLFluff rule must never inherit SQLFluff's blanket SARIF error level.
        _ => ("T3", "note"),
    }
}

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
        let fluff_val = serde_json::from_str::<Value>(fluff_sarif_str)?;
        if let Some(runs) = fluff_val.get("runs").and_then(|r| r.as_array()) {
            for run in runs {
                // Extract rules defined by SQLFluff
                if let Some(fluff_rules) = run
                    .get("tool")
                    .and_then(|t| t.get("driver"))
                    .and_then(|d| d.get("rules"))
                    .and_then(|r| r.as_array())
                {
                    for rule in fluff_rules {
                        let Some(id) = rule.get("id").and_then(|i| i.as_str()) else {
                            continue;
                        };
                        let (tier, level) = sqlfluff_policy(id);
                        let mut merged_rule = rule.clone();
                        if let Some(obj) = merged_rule.as_object_mut() {
                            obj.insert(
                                "defaultConfiguration".to_string(),
                                json!({ "level": level }),
                            );
                            let props = obj.entry("properties").or_insert_with(|| json!({}));
                            if let Some(props_obj) = props.as_object_mut() {
                                props_obj.insert("tier".to_string(), json!(tier));
                            }
                        }
                        rules.insert(id.to_string(), merged_rule);
                    }
                }

                // Extract results reported by SQLFluff
                if let Some(fluff_results) = run.get("results").and_then(|r| r.as_array()) {
                    for result in fluff_results {
                        let Some(rule_id) = result.get("ruleId").and_then(|r| r.as_str()) else {
                            continue;
                        };
                        let (tier, level) = sqlfluff_policy(rule_id);
                        let mut merged_result = result.clone();
                        if let Some(obj) = merged_result.as_object_mut() {
                            obj.insert("level".to_string(), json!(level));
                            let props = obj.entry("properties").or_insert_with(|| json!({}));
                            if let Some(props_obj) = props.as_object_mut() {
                                props_obj.insert("tier".to_string(), json!(tier));
                            }
                        }
                        results.push(merged_result);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_sarif_without_properties() {
        let fluff_sarif = json!({
            "version": "2.1.0",
            "runs": [{
                "tool": {
                    "driver": {
                        "name": "sqlfluff",
                        "rules": [
                            {
                                "id": "AM05"
                                // No properties object
                            },
                            {
                                "id": "PRS"
                            }
                        ]
                    }
                },
                "results": [
                    {
                        "ruleId": "AM05",
                        "message": { "text": "something" }
                        // No properties object
                    },
                    {
                        "ruleId": "PRS",
                        "message": { "text": "cannot parse" }
                    }
                ]
            }]
        });
        let fluff_content = serde_json::to_string(&fluff_sarif).unwrap();

        let report = HazardReport {
            format: "json".to_string(),
            file_path: "test.sql".to_string(),
            dialect: "sqlite".to_string(),
            findings: vec![],
            unresolved_schema_facts: vec![],
        };

        let merged = hazard_sarif(&report, Some(&fluff_content)).unwrap();
        let val: serde_json::Value = serde_json::from_str(&merged).unwrap();

        // AM05 is a style preference, not a correctness failure.
        let run = &val["runs"][0];
        let rules = run["tool"]["driver"]["rules"].as_array().unwrap();
        let style_rule = rules.iter().find(|rule| rule["id"] == "AM05").unwrap();
        assert_eq!(style_rule["properties"]["tier"], "T3");
        assert_eq!(style_rule["defaultConfiguration"]["level"], "note");
        let parser_rule = rules.iter().find(|rule| rule["id"] == "PRS").unwrap();
        assert_eq!(parser_rule["properties"]["tier"], "T1");
        assert_eq!(parser_rule["defaultConfiguration"]["level"], "error");

        let results = run["results"].as_array().unwrap();
        let style_result = results
            .iter()
            .find(|result| result["ruleId"] == "AM05")
            .unwrap();
        assert_eq!(style_result["properties"]["tier"], "T3");
        assert_eq!(style_result["level"], "note");
        let parser_result = results
            .iter()
            .find(|result| result["ruleId"] == "PRS")
            .unwrap();
        assert_eq!(parser_result["properties"]["tier"], "T1");
        assert_eq!(parser_result["level"], "error");
    }
}
