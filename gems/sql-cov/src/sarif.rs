use crate::hazard::HazardReport;
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub fn hazard_json(report: &HazardReport) -> Result<String> {
    Ok(serde_json::to_string_pretty(report)?)
}

pub fn hazard_sarif(report: &HazardReport) -> Result<String> {
    let mut rules = BTreeMap::<String, Value>::new();
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
                    "tags": ["correctness", "sql", "null", "unknown"]
                }
            })
        });
    }
    let results = report
        .findings
        .iter()
        .map(|finding| {
            json!({
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
                    "kind": finding.kind,
                    "nullabilityEvidence": finding.evidence,
                    "recommendation": finding.recommendation,
                    "schemaValidated": true
                }
            })
        })
        .collect::<Vec<_>>();
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
