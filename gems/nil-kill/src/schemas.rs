use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Serialize, Deserialize)]
pub struct InputState {
    pub methods: Vec<MethodRecord>,
    pub tlets: Vec<Value>,
    pub facts: HashMap<String, Value>,
    pub unused_return_methods_by_location: HashMap<String, Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OutputState {
    pub actions: Vec<Action>,
    pub diagnostics: HashMap<String, Vec<Value>>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
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
    pub returns: Vec<String>,
    pub return_elem: Vec<Value>,
    pub return_kv: Vec<Value>,
    pub return_elem_shapes: Vec<Value>,
    pub return_kv_shapes: Vec<Value>,
    pub raised: Vec<String>,
    pub source: Option<SourceRecord>,
    pub has_sig: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SourceRecord {
    pub path: String,
    pub line: i64,
    pub end_line: Option<i64>,
    pub class: String,
    pub method: String,
    pub kind: String,
    pub language: String,
    pub has_sig: bool,
    pub sig: String,
    pub params: Vec<ParamRecord>,
    pub scope: Vec<String>,
    pub non_nil_params: Vec<String>,
    pub uses_yield: bool,
    pub untraceable_params: Vec<String>,
    pub protocols: HashMap<String, Value>,
    pub noreturn_candidate: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ParamRecord {
    pub name: String,
    pub nil_default: bool,
    pub r#type: String, // 'type' is a reserved keyword in Rust
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

pub const REVIEW: &str = "review";
pub const HIGH: &str = "high";
pub const GAP: &str = "gap";
