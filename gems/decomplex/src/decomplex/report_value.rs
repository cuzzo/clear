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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_report_value() {
        let val = json!({
            "str": "hello",
            "num": 42,
            "bool_t": true,
            "bool_f": false,
            "null": null,
            "arr_str": ["a", "b"],
            "arr_mix": ["a", 42, true, null, ["nested"]],
            "obj": {"x": 1}
        });

        assert_eq!(get(&val, "str"), Some(&Value::String("hello".to_string())));
        assert_eq!(get(&val, "nonexistent"), None);

        assert_eq!(string(Some(&json!("abc"))), "abc");
        assert_eq!(string(Some(&json!(123))), "123");
        assert_eq!(string(Some(&json!(true))), "true");
        assert_eq!(string(Some(&json!(false))), "false");
        assert_eq!(string(Some(&json!(null))), "");
        assert_eq!(string(None), "");
        assert_eq!(string(Some(&json!({"x": 1}))), "{\"x\":1}");

        assert_eq!(field(&val, "str"), "hello");
        assert_eq!(field(&val, "num"), "42");

        assert_eq!(field_i64(&val, "num"), 42);
        assert_eq!(field_i64(&val, "str"), 0); // "hello" is not parseable i64
        let float_val = json!({"num": 4.2, "num_str": "42"});
        assert_eq!(field_i64(&float_val, "num_str"), 42);
        assert_eq!(field_i64(&float_val, "num"), 0);

        assert_eq!(field_usize(&val, "num"), 42);

        assert_eq!(field_bool(&val, "bool_t"), true);
        assert_eq!(field_bool(&val, "bool_f"), false);
        assert_eq!(field_bool(&val, "nonexistent"), false);
        assert_eq!(field_bool(&val, "null"), false);
        let bool_str_val = json!({"b_t": "true", "b_f": "false"});
        assert_eq!(field_bool(&bool_str_val, "b_t"), true);
        assert_eq!(field_bool(&bool_str_val, "b_f"), false);

        assert_eq!(array(&val, "arr_str").len(), 2);
        assert_eq!(array(&val, "nonexistent"), &[] as &[Value]);

        assert_eq!(array_from(Some(&json!([1, 2]))).len(), 2);
        assert_eq!(array_from(None), &[] as &[Value]);

        assert_eq!(array_strings(Some(&json!(["a", 123]))), vec!["a".to_string(), "123".to_string()]);

        assert_eq!(field_array_strings(&val, "arr_str"), vec!["a", "b"]);

        assert_eq!(join(&vec!["x".to_string(), "y".to_string()], "-"), "x-y");

        assert_eq!(join_field(&val, "arr_str", "|"), "a|b");

        assert_eq!(array_len(&val, "arr_str"), 2);

        assert_eq!(positive(&val, "num"), true);
        assert_eq!(positive(&val, "bool_t"), false);

        assert_eq!(kind_is(&val, "str", "hello"), true);

        assert_eq!(ruby_inspect_array(Some(&json!(["a", 42, true, false, null, [1]]))), r#"["a", 42, true, false, nil, [1]]"#);
        assert_eq!(ruby_inspect_value(&json!({"x": 1})), r#"{"x":1}"#);
    }
}
