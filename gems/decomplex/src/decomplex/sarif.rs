use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

const SCHEMA: &str = "https://json.schemastore.org/sarif-2.1.0.json";
pub const PROOF_BOUNDARY_PROPERTY: &str = "fact_mine.proof_boundary";
pub const PROOF_BOUNDARY_SUMMARY_PROPERTY: &str = "fact_mine.proof_boundary_summary";
pub const PROOF_BOUNDARY_SCHEMA: &str = "fact-mine.proof-boundary.v1";

/// Records the narrowest completeness claim that supports one SARIF result.
///
/// This deliberately describes the facts used by the result, rather than the
/// completeness of the entire scan.  A local syntax finding can therefore be
/// complete even when an unrelated project-wide analysis is partial.
pub fn proof_boundary(tier: &str, authority: &[&str], scope: &str, blockers: Vec<String>) -> Value {
    debug_assert!(matches!(tier, "complete" | "partial" | "review"));
    json!({
        "schema": PROOF_BOUNDARY_SCHEMA,
        "tier": tier,
        "authority": authority,
        "scope": scope,
        "blockers": blockers,
    })
}

/// Summarizes only results that declare a proof boundary.  Consumers can use
/// this to disclose the partial-data rate without treating every result in a
/// scan as unknown.
pub fn proof_boundary_summary(results: &[Value]) -> Value {
    let mut complete = 0usize;
    let mut partial = 0usize;
    let mut review = 0usize;
    for result in results {
        let Some(tier) = result
            .pointer(&format!("/properties/{PROOF_BOUNDARY_PROPERTY}"))
            .and_then(Value::as_object)
            .and_then(|boundary| boundary.get("tier"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        match tier {
            "complete" => complete += 1,
            "partial" => partial += 1,
            "review" => review += 1,
            _ => {}
        }
    }
    let results_with_boundary = complete + partial + review;
    let partial_or_review = partial + review;
    let partial_or_review_percent = if results_with_boundary == 0 {
        0.0
    } else {
        (partial_or_review as f64 * 100.0) / results_with_boundary as f64
    };
    json!({
        "schema": PROOF_BOUNDARY_SCHEMA,
        "result_count": results.len(),
        "results_with_boundary": results_with_boundary,
        "tiers": {
            "complete": complete,
            "partial": partial,
            "review": review,
        },
        "partial_or_review_results": partial_or_review,
        "partial_or_review_percent": partial_or_review_percent,
    })
}

pub fn document(
    tool_name: &str,
    rules: Vec<Value>,
    results: Vec<Value>,
    information_uri: Option<&str>,
    properties: Value,
) -> Value {
    let normalized_rules = unique_rules(rules);
    let mut rule_index = Map::new();
    for (index, rule) in normalized_rules.iter().enumerate() {
        if let Some(id) = rule.get("id").and_then(Value::as_str) {
            rule_index.insert(id.to_string(), json!(index));
        }
    }
    let normalized_results = results
        .into_iter()
        .map(|result| {
            let mut result = compact_value(json_safe_value(result));
            if let Some(rule_id) = result.get("ruleId").and_then(Value::as_str) {
                if let Some(index) = rule_index.get(rule_id) {
                    if let Some(object) = result.as_object_mut() {
                        object.insert("ruleIndex".to_string(), index.clone());
                    }
                }
            }
            result
        })
        .collect::<Vec<_>>();

    let mut driver = Map::new();
    driver.insert("name".to_string(), Value::String(tool_name.to_string()));
    if let Some(uri) = information_uri {
        driver.insert("informationUri".to_string(), Value::String(uri.to_string()));
    }
    driver.insert("rules".to_string(), Value::Array(normalized_rules));
    let driver = compact_object(driver);

    let run = compact_value(json!({
        "tool": { "driver": driver },
        "results": normalized_results,
        "properties": json_safe_value(properties),
    }));

    compact_value(json!({
        "version": "2.1.0",
        "$schema": SCHEMA,
        "runs": [run],
    }))
}

pub fn rule(
    id: &str,
    name: Option<&str>,
    short_description: Option<&str>,
    full_description: Option<&str>,
    default_level: &str,
    help_uri: Option<&str>,
    properties: Value,
) -> Value {
    compact_value(json!({
        "id": id,
        "name": name.unwrap_or(id),
        "shortDescription": { "text": short_description.or(name).unwrap_or(id) },
        "fullDescription": full_description.map(|text| json!({ "text": text })),
        "defaultConfiguration": { "level": default_level },
        "helpUri": help_uri,
        "properties": json_safe_value(properties),
    }))
}

pub fn result(
    rule_id: &str,
    message: &str,
    path: Option<&str>,
    line: Option<i64>,
    start_column: Option<i64>,
    end_line: Option<i64>,
    end_column: Option<i64>,
    level: &str,
    properties: Value,
    partial_fingerprints: Value,
) -> Value {
    compact_value(json!({
        "ruleId": rule_id,
        "level": level,
        "message": { "text": message },
        "locations": sarif_locations(path, line, start_column, end_line, end_column),
        "partialFingerprints": json_safe_value(partial_fingerprints),
        "properties": json_safe_value(properties),
    }))
}

fn sarif_locations(
    path: Option<&str>,
    line: Option<i64>,
    start_column: Option<i64>,
    end_line: Option<i64>,
    end_column: Option<i64>,
) -> Value {
    let Some(path) = path.filter(|path| !path.is_empty()) else {
        return Value::Array(Vec::new());
    };
    Value::Array(vec![compact_value(json!({
        "physicalLocation": compact_value(json!({
            "artifactLocation": { "uri": normalize_path(path) },
            "region": compact_value(json!({
                "startLine": positive_int(line, Some(1)),
                "startColumn": positive_int(start_column, None),
                "endLine": positive_int(end_line, None),
                "endColumn": positive_int(end_column, None),
            }))
        }))
    }))])
}

pub fn normalize_path(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches("./").to_string()
}

pub fn slug(value: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in value.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

fn positive_int(value: Option<i64>, fallback: Option<i64>) -> Option<i64> {
    let number = value.or(fallback)?;
    (number > 0).then_some(number).or(fallback)
}

pub fn json_safe_value(value: Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.into_iter().map(json_safe_value).collect()),
        Value::Object(object) => {
            let mut out = Map::new();
            for (key, value) in object {
                out.insert(key, json_safe_value(value));
            }
            Value::Object(out)
        }
        other => other,
    }
}

fn compact_value(value: Value) -> Value {
    enum State {
        Pending(Value),
        PostObject { keys: Vec<String> },
        PostArray { len: usize },
    }

    let mut state_stack = vec![State::Pending(value)];
    let mut results = Vec::new();

    while let Some(state) = state_stack.pop() {
        match state {
            State::Pending(val) => match val {
                Value::Object(obj) => {
                    let mut keys = Vec::new();
                    let mut vals = Vec::new();
                    for (k, v) in obj {
                        keys.push(k);
                        vals.push(v);
                    }
                    state_stack.push(State::PostObject { keys });
                    for v in vals.into_iter().rev() {
                        state_stack.push(State::Pending(v));
                    }
                }
                Value::Array(arr) => {
                    let len = arr.len();
                    state_stack.push(State::PostArray { len });
                    for v in arr.into_iter().rev() {
                        state_stack.push(State::Pending(v));
                    }
                }
                other => {
                    results.push(other);
                }
            },
            State::PostObject { keys } => {
                let mut out = Map::new();
                for key in keys.into_iter().rev() {
                    let val = results.pop().unwrap();
                    if !is_empty_value(&val) {
                        out.insert(key, val);
                    }
                }
                results.push(Value::Object(out));
            }
            State::PostArray { len } => {
                let mut items = Vec::new();
                for _ in 0..len {
                    items.push(results.pop().unwrap());
                }
                items.reverse();
                results.push(Value::Array(items));
            }
        }
    }

    results.pop().unwrap_or(Value::Null)
}

fn is_empty_value(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Array(items) => items.is_empty(),
        Value::Object(object) => object.is_empty(),
        Value::String(text) => text.is_empty(),
        _ => false,
    }
}

fn compact_object(object: Map<String, Value>) -> Value {
    compact_value(Value::Object(object))
}

fn unique_rules(rules: Vec<Value>) -> Vec<Value> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for rule in rules {
        let rule = json_safe_value(rule);
        let id = rule
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if id.is_empty() || !seen.insert(id) {
            continue;
        }
        out.push(compact_value(rule));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn slug_matches_ruby_sarif_slug() {
        assert_eq!(
            slug("Structural Similarity (Type-2/3)"),
            "structural-similarity-type-2-3"
        );
    }

    #[test]
    fn test_sarif_edge_cases() {
        let rules = vec![
            json!({"id": "rule1"}),
            json!({"id": "rule1"}),
            json!({"id": ""}),
        ];
        let uniq = unique_rules(rules);
        assert_eq!(uniq.len(), 1);
        assert_eq!(uniq[0].get("id").and_then(Value::as_str), Some("rule1"));

        let doc = document(
            "mytool",
            vec![json!({"id": "rule1"})],
            vec![json!({"ruleId": "rule2"}), json!({})],
            None,
            json!({}),
        );
        let runs = doc.get("runs").unwrap().as_array().unwrap();
        let results = runs[0].get("results").unwrap().as_array().unwrap();
        assert_eq!(results.len(), 2);

        let empty_locs = sarif_locations(None, None, None, None, None);
        assert_eq!(empty_locs, Value::Array(vec![]));
        let empty_locs2 = sarif_locations(Some(""), None, None, None, None);
        assert_eq!(empty_locs2, Value::Array(vec![]));
    }

    #[test]
    fn proof_boundary_summary_counts_only_annotated_results() {
        let results = vec![
            json!({
                "properties": {
                    PROOF_BOUNDARY_PROPERTY: proof_boundary(
                        "complete",
                        &["fact_mine_normalized_ast"],
                        "local",
                        vec![],
                    )
                }
            }),
            json!({
                "properties": {
                    PROOF_BOUNDARY_PROPERTY: proof_boundary(
                        "partial",
                        &["fact_mine_normalized_ast"],
                        "local",
                        vec!["unresolved_call".to_string()],
                    )
                }
            }),
            json!({"ruleId": "unannotated"}),
        ];

        let summary = proof_boundary_summary(&results);
        assert_eq!(summary.pointer("/result_count"), Some(&json!(3)));
        assert_eq!(summary.pointer("/results_with_boundary"), Some(&json!(2)));
        assert_eq!(summary.pointer("/tiers/complete"), Some(&json!(1)));
        assert_eq!(summary.pointer("/tiers/partial"), Some(&json!(1)));
        assert_eq!(
            summary.pointer("/partial_or_review_percent"),
            Some(&json!(50.0))
        );
    }
}
