use serde_json::Value;

pub fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object()?.get(key)
}

pub fn string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(number)) => number.to_string(),
        Some(Value::Bool(true)) => "true".to_string(),
        Some(Value::Bool(false)) => "false".to_string(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

pub fn field(value: &Value, key: &str) -> String {
    string(get(value, key))
}

pub fn field_i64(value: &Value, key: &str) -> i64 {
    match get(value, key) {
        Some(Value::Number(number)) => number
            .as_i64()
            .or_else(|| number.as_u64().map(|n| n as i64))
            .unwrap_or(0),
        Some(Value::String(text)) => text.parse().unwrap_or(0),
        _ => 0,
    }
}

pub fn field_usize(value: &Value, key: &str) -> usize {
    field_i64(value, key).max(0) as usize
}

pub fn field_bool(value: &Value, key: &str) -> bool {
    match get(value, key) {
        Some(Value::Bool(value)) => *value,
        Some(Value::String(text)) => text == "true",
        _ => false,
    }
}

pub fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    get(value, key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

pub fn array_from(value: Option<&Value>) -> &[Value] {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

pub fn array_strings(value: Option<&Value>) -> Vec<String> {
    array_from(value)
        .iter()
        .map(|item| string(Some(item)))
        .collect()
}

pub fn field_array_strings(value: &Value, key: &str) -> Vec<String> {
    array_strings(get(value, key))
}

pub fn join(values: &[String], separator: &str) -> String {
    values.join(separator)
}

pub fn join_field(value: &Value, key: &str, separator: &str) -> String {
    field_array_strings(value, key).join(separator)
}

pub fn array_len(value: &Value, key: &str) -> usize {
    array(value, key).len()
}

pub fn positive(value: &Value, key: &str) -> bool {
    field_i64(value, key) > 0
}

pub fn kind_is(value: &Value, key: &str, expected: &str) -> bool {
    field(value, key) == expected
}

pub fn ruby_inspect_array(value: Option<&Value>) -> String {
    let parts = array_from(value)
        .iter()
        .map(ruby_inspect_value)
        .collect::<Vec<_>>();
    format!("[{}]", parts.join(", "))
}

fn ruby_inspect_value(value: &Value) -> String {
    match value {
        Value::String(text) => format!("{text:?}"),
        Value::Number(number) => number.to_string(),
        Value::Bool(true) => "true".to_string(),
        Value::Bool(false) => "false".to_string(),
        Value::Null => "nil".to_string(),
        Value::Array(items) => {
            let parts = items.iter().map(ruby_inspect_value).collect::<Vec<_>>();
            format!("[{}]", parts.join(", "))
        }
        Value::Object(_) => value.to_string(),
    }
}
