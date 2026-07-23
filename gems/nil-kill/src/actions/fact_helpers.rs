use crate::schemas::InputState;
use std::collections::BTreeSet;

pub(super) fn objects<'a>(
    input: &'a InputState,
    key: &str,
) -> Vec<&'a serde_json::Map<String, serde_json::Value>> {
    input
        .facts
        .get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .collect()
}

pub(super) fn string<'a>(
    fact: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Option<&'a str> {
    fact.get(key).and_then(serde_json::Value::as_str)
}

pub(super) fn i64(fact: &serde_json::Map<String, serde_json::Value>, key: &str) -> Option<i64> {
    fact.get(key).and_then(serde_json::Value::as_i64)
}

pub(super) fn strings<'a>(
    fact: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Vec<&'a str> {
    fact.get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .collect()
}

pub(super) fn bool(fact: &serde_json::Map<String, serde_json::Value>, key: &str) -> bool {
    fact.get(key)
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

pub(super) fn span_line(fact: &serde_json::Map<String, serde_json::Value>) -> i64 {
    fact.get("span")
        .and_then(serde_json::Value::as_array)
        .and_then(|span| span.first())
        .and_then(serde_json::Value::as_u64)
        .and_then(|line| i64::try_from(line).ok())
        .unwrap_or(0)
}

pub(super) fn json_strings(values: BTreeSet<String>) -> serde_json::Value {
    serde_json::Value::Array(values.into_iter().map(serde_json::Value::String).collect())
}
