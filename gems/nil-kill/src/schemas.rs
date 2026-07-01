use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

fn string_or_default<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

fn string_vec_or_default<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let values = Vec::<Option<String>>::deserialize(deserializer)?;
    Ok(values
        .into_iter()
        .map(|value| value.unwrap_or_default())
        .collect())
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct InputState {
    pub methods: Vec<MethodRecord>,
    pub tlets: Vec<Value>,
    pub facts: HashMap<String, Value>,
    pub unused_return_methods_by_location: HashMap<String, Value>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct OutputState {
    pub actions: Vec<Action>,
    pub diagnostics: HashMap<String, Vec<Value>>,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct MethodRecord {
    pub key: Vec<Value>,
    pub calls: i64,
    pub ok_calls: i64,
    pub raised_calls: i64,
    pub params_by_name: HashMap<String, Vec<String>>,
    pub params_ok: HashMap<String, Vec<String>>,
    pub params_raised: HashMap<String, Vec<String>>,
    pub param_elem: HashMap<String, Value>,
    pub param_kv: HashMap<String, Value>,
    pub param_elem_shapes: HashMap<String, Value>,
    pub param_kv_shapes: HashMap<String, Value>,
    pub param_sites: HashMap<String, HashMap<String, i64>>,
    pub param_sites_ok: HashMap<String, HashMap<String, i64>>,
    pub param_sites_raised: HashMap<String, HashMap<String, i64>>,
    pub param_traces: HashMap<String, Value>,
    pub param_traces_ok: HashMap<String, Value>,
    pub param_traces_raised: HashMap<String, Value>,
    #[serde(deserialize_with = "string_vec_or_default")]
    pub returns: Vec<String>,
    pub return_elem: Vec<Value>,
    pub return_kv: Vec<Value>,
    pub return_elem_shapes: Vec<Value>,
    pub return_kv_shapes: Vec<Value>,
    #[serde(deserialize_with = "string_vec_or_default")]
    pub raised: Vec<String>,
    pub source: Option<SourceRecord>,
    pub has_sig: bool,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct SourceRecord {
    #[serde(deserialize_with = "string_or_default")]
    pub path: String,
    pub line: i64,
    pub end_line: Option<i64>,
    #[serde(deserialize_with = "string_or_default")]
    pub class: String,
    #[serde(deserialize_with = "string_or_default")]
    pub method: String,
    #[serde(deserialize_with = "string_or_default")]
    pub kind: String,
    #[serde(deserialize_with = "string_or_default")]
    pub language: String,
    pub has_sig: bool,
    #[serde(deserialize_with = "string_or_default")]
    pub sig: String,
    pub params: Vec<ParamRecord>,
    pub scope: Vec<String>,
    pub non_nil_params: Vec<String>,
    pub uses_yield: bool,
    pub untraceable_params: Vec<String>,
    pub protocols: HashMap<String, Value>,
    pub noreturn_candidate: bool,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct ParamRecord {
    #[serde(deserialize_with = "string_or_default")]
    pub name: String,
    pub nil_default: bool,
    #[serde(default)]
    pub r#type: Option<String>, // 'type' is a reserved keyword in Rust
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
pub struct Action {
    pub kind: String,
    pub confidence: String,
    pub path: String,
    pub line: i64,
    pub message: String,
    pub data: HashMap<String, Value>,
}
