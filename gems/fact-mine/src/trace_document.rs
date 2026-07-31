//! The single artifact a trace run produces.
//!
//! Everything in it is an observation: what ran, what values were seen, where.
//! Nothing in it is a decision about which planned anchor an observation
//! satisfies -- that join is the consumer's, and doing it in two places is how
//! two implementations drift apart.
//!
//! Minting a protocol value from an observed one needs the language's own
//! type-symbol rules, so values travel already encoded and the consumer only
//! decides which anchor each belongs to.

use anyhow::{Context, Result};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::Path;

pub const VERSION: i64 = 1;
pub const PRODUCER: &str = "nil-kill";
pub const PRODUCER_VERSION: &str = "1";
const UNTYPED: &str = "T.untyped";

/// What the runtime was when it observed something. The orchestrator has to
/// repeat these claims from outside the traced program and a trace whose claims
/// disagree is rejected at merge, so they come from the VM that observed.
pub fn environment_claims(runtime: &Runtime, root: &Path) -> Vec<(String, String)> {
    let mut claims = vec![
        ("runtime.language".to_string(), "ruby".to_string()),
        ("runtime.version".to_string(), runtime.version.clone()),
        ("runtime.engine".to_string(), runtime.engine.clone()),
        ("runtime.engine_version".to_string(), runtime.engine_version.clone()),
    ];
    let lockfile = root.join("Gemfile.lock");
    if let Ok(bytes) = std::fs::read(&lockfile) {
        use sha2::{Digest, Sha256};
        claims.push((
            "runtime.lockfile.Gemfile.lock.sha256".to_string(),
            format!("sha256:{:x}", Sha256::digest(&bytes)),
        ));
    }
    claims
}

/// The interpreter that did the observing, as it reported itself.
#[derive(Debug, Clone, Default)]
pub struct Runtime {
    pub version: String,
    pub engine: String,
    pub engine_version: String,
}

pub fn provenance(run_id: &str) -> Value {
    json!({"provider": "ruby-tracepoint", "provider_version": "1", "run_id": run_id})
}

// ------------------------------------------------------------ value encoding

fn type_symbol(runtime: &Runtime, name: &str) -> String {
    format!("nil-kill-runtime ruby ruby {} {}#", runtime.version, descriptor_owner(name))
}

fn singleton_symbol(runtime: &Runtime, name: &str) -> String {
    format!("nil-kill-runtime ruby ruby {} {}.", runtime.version, descriptor_owner(name))
}

/// A SCIP descriptor for a type name: `A::B` becomes `A/B`, empty segments
/// dropped, and a segment needing escaping backtick-quoted.
fn descriptor_owner(value: &str) -> String {
    value
        .split("::")
        .filter(|part| !part.is_empty())
        .map(descriptor_name)
        .collect::<Vec<_>>()
        .join("/")
}

/// SCIP's canonical descriptor escaping exactly: question marks, bangs,
/// equality signs, slashes and most Ruby operators must be backtick-escaped;
/// only ASCII alphanumerics and these four punctuation characters are bare.
fn descriptor_name(value: &str) -> String {
    let simple = !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '+' || c == '-' || c == '$');
    if simple {
        value.to_string()
    } else {
        format!("`{}`", value.replace('`', "``"))
    }
}

pub fn normalize_source_role(role: &str) -> &'static str {
    match role.to_ascii_uppercase().as_str() {
        "NONPRODUCTION" | "NON_PRODUCTION" => "NON_PRODUCTION",
        "STDLIB" | "STANDARD_LIBRARY" => "STANDARD_LIBRARY",
        "PRODUCTION" => "PRODUCTION",
        "DEPENDENCY" => "DEPENDENCY",
        "RUNTIME" => "RUNTIME",
        _ => "UNKNOWN_SOURCE",
    }
}

fn simple_value(runtime: &Runtime, name: &str, source_role: &str) -> Value {
    json!({
        "type_symbol": type_symbol(runtime, name),
        "source_role": normalize_source_role(source_role),
    })
}

/// The whole point of a shape: an alternative that is itself structured says
/// what it contains, so a declared type can name `Array<String>` rather than
/// `Array`.
fn wire_shape(shape: &Value, runtime: &Runtime, source_role: &str) -> Option<Value> {
    let kind = shape["kind"].as_str().unwrap_or_default();
    let children = |field: &str| -> Vec<Value> {
        shape[field].as_array().cloned().unwrap_or_default()
    };
    match kind {
        "array" | "set" => {
            let values = child_value_set(&children("elements"), runtime, source_role)?;
            Some(json!({"sequence": {"elements": values}}))
        }
        "hash" => {
            let keys = children("keys");
            let values = children("values");
            let mut entries = Vec::new();
            for key in &keys {
                for child in &values {
                    let (Some(key), Some(child)) = (
                        value_from_shape(key, runtime, source_role),
                        value_from_shape(child, runtime, source_role),
                    ) else {
                        continue;
                    };
                    entries.push(json!({"key": key, "value": child, "count": 1}));
                }
            }
            (!entries.is_empty()).then(|| json!({"mapping": {"entries": entries}}))
        }
        "record" => {
            let mut members = shape["members"]
                .as_object()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .collect::<Vec<_>>();
            members.sort_by(|(left, _), (right, _)| left.cmp(right));
            let members = members
                .into_iter()
                .filter_map(|(name, child)| {
                    let values = child_value_set(&[child], runtime, source_role)?;
                    Some(json!({"name": name, "values": values}))
                })
                .collect::<Vec<_>>();
            Some(json!({"record": {"members": members}}))
        }
        "tuple" => {
            let elements = children("elements")
                .iter()
                .filter_map(|child| child_value_set(&[child.clone()], runtime, source_role))
                .collect::<Vec<_>>();
            Some(json!({"tuple": {"elements": elements}}))
        }
        _ => None,
    }
}

fn child_value_set(values: &[Value], runtime: &Runtime, source_role: &str) -> Option<Value> {
    let mut alternatives: Vec<Value> = Vec::new();
    for value in values {
        let Some(encoded) = value_from_shape(value, runtime, source_role) else { continue };
        let alternative = json!({"value": encoded, "count": 1});
        if !alternatives.contains(&alternative) {
            alternatives.push(alternative);
        }
    }
    (!alternatives.is_empty()).then(|| json!({"alternatives": alternatives}))
}

fn value_from_shape(value: &Value, runtime: &Runtime, source_role: &str) -> Option<Value> {
    let Some(shape) = value.as_object() else {
        return Some(simple_value(runtime, value.as_str()?, source_role));
    };
    let kind = shape.get("kind").and_then(Value::as_str).unwrap_or_default();
    let name = shape.get("name").and_then(Value::as_str).unwrap_or_default();
    let type_name = if !name.is_empty() {
        name
    } else {
        match kind {
            "array" | "tuple" => "Array",
            "set" => "Set",
            "hash" => "Hash",
            _ => return None,
        }
    };
    let mut encoded = simple_value(runtime, type_name, source_role);
    if let Some(Value::Object(nested)) = wire_shape(value, runtime, source_role) {
        if let Some(object) = encoded.as_object_mut() {
            object.extend(nested);
        }
    }
    Some(encoded)
}

/// The alternatives a domain names. Support sets, not frequencies: one
/// alternative is an exact positive witness and the bucket's count carries the
/// observed execution count.
pub fn value_set(
    domain: &Value,
    runtime: &Runtime,
    source_role: &str,
) -> Option<Value> {
    let mut types = domain["types"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    types.sort();
    types.dedup();
    if types.is_empty() {
        return None;
    }
    let roles = domain["source_roles"].as_object().cloned().unwrap_or_default();
    let singletons = domain["singletons"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|name| !name.is_empty())
        .collect::<Vec<_>>();

    let alternatives = types
        .iter()
        .map(|name| {
            let role = roles
                .get(name)
                .and_then(Value::as_str)
                .unwrap_or(source_role);
            let mut value = simple_value(runtime, name, role);
            if singletons.len() == 1 {
                value["singleton_symbol"] = json!(singleton_symbol(runtime, singletons[0]));
            }
            if let Some(shape) = shape_for(domain, name) {
                if let Some(Value::Object(nested)) = wire_shape(&shape, runtime, role) {
                    if let Some(object) = value.as_object_mut() {
                        object.extend(nested);
                    }
                }
            }
            json!({"value": value, "count": 1})
        })
        .collect::<Vec<_>>();
    Some(json!({"alternatives": alternatives}))
}

/// The shape describing this alternative: the one that names it, else the
/// first, with the domain's own element and key classes filled in where the
/// shape does not carry them.
fn shape_for(domain: &Value, name: &str) -> Option<Value> {
    let shapes = domain["shapes"].as_array()?;
    let mut shape = shapes
        .iter()
        .find(|shape| shape["name"].as_str() == Some(name))
        .or_else(|| shapes.first())
        .cloned()
        .unwrap_or_else(|| json!({}));
    let object = shape.as_object_mut()?;
    for field in ["elements", "keys", "values"] {
        if !object.contains_key(field) {
            if let Some(values) = domain.get(field) {
                object.insert(field.to_string(), values.clone());
            }
        }
    }
    Some(shape)
}

pub fn target(row: &Value) -> Option<Value> {
    let target = row.get("target")?;
    Some(json!({
        "symbol": target["symbol"],
        "source_role": normalize_source_role(target["source_role"].as_str().unwrap_or_default()),
        "package_manager": target["package_manager"],
        "package_name": target["package_name"],
        "package_version": target["package_version"],
    }))
}

// -------------------------------------------------------------- observations

/// A value the collector saw in a named slot, and where that slot was.
fn observation(
    kind: &str,
    scope: Value,
    slot: &str,
    domain: Value,
    count: i64,
    slot_kind: &str,
) -> Value {
    json!({
        "kind": kind, "scope": scope, "slot": slot,
        "slot_kind": slot_kind, "domain": domain, "count": count,
    })
}

fn strings(values: Option<&Value>) -> Vec<String> {
    let mut out = values
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    out.sort();
    out.dedup();
    out
}

fn normalize_shape(shape: &Value) -> Option<Value> {
    if let Some(name) = shape.as_str() {
        return Some(json!({"kind": "class", "name": name}));
    }
    let object = shape.as_object()?;
    let kind = object.get("kind").and_then(Value::as_str).unwrap_or_default();
    if kind.is_empty() {
        return Some(json!({"kind": "unknown"}));
    }
    let mut out = Map::new();
    out.insert("kind".to_string(), json!(kind));
    if let Some(name) = object.get("name").and_then(Value::as_str).filter(|n| !n.is_empty()) {
        out.insert("name".to_string(), json!(name));
    }
    for field in ["elements", "keys", "values"] {
        let children = object
            .get(field)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(normalize_shape)
            .collect::<Vec<_>>();
        if !children.is_empty() {
            out.insert(field.to_string(), json!(children));
        }
    }
    let members = object
        .get("members")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .filter_map(|(name, child)| normalize_shape(child).map(|child| (name.clone(), child)))
        .collect::<Map<_, _>>();
    if !members.is_empty() {
        out.insert("members".to_string(), Value::Object(members));
    }
    Some(Value::Object(out))
}

/// `T.untyped` is an absence-of-identity marker, not a runtime alternative.
/// Where a shape supplies an exact record identity, it replaces the marker.
fn reconcile_record_identities(domain: &mut Map<String, Value>) {
    let shapes = domain["shapes"].as_array().cloned().unwrap_or_default();
    let nested = |field: &str| -> Vec<Value> {
        shapes
            .iter()
            .flat_map(|shape| shape[field].as_array().cloned().unwrap_or_default())
            .collect()
    };
    let slots: [(&str, Vec<Value>); 4] = [
        ("types", shapes.clone()),
        ("elements", nested("elements")),
        ("keys", nested("keys")),
        ("values", nested("values")),
    ];
    for (slot, candidates) in slots {
        let mut names = strings(domain.get(slot));
        if !names.iter().any(|name| name == UNTYPED) {
            continue;
        }
        let records = candidates
            .iter()
            .filter(|shape| shape["kind"].as_str() == Some("record"))
            .filter_map(|shape| shape["name"].as_str())
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        if records.is_empty() {
            continue;
        }
        names.retain(|name| name != UNTYPED);
        for record in records {
            if !names.contains(&record) {
                names.push(record);
            }
        }
        names.sort();
        domain.insert(slot.to_string(), json!(names));
    }
}

fn domain(fields: &[(&str, Option<&Value>)], shapes: Vec<Value>) -> Value {
    let mut normalized_shapes: Vec<Value> = Vec::new();
    for shape in shapes.iter().filter_map(normalize_shape) {
        if !normalized_shapes.contains(&shape) {
            normalized_shapes.push(shape);
        }
    }
    let mut out = Map::new();
    for field in ["types", "singletons", "elements", "keys", "values"] {
        let values = fields.iter().find(|(name, _)| *name == field).and_then(|(_, v)| *v);
        out.insert(field.to_string(), json!(strings(values)));
    }
    out.insert("shapes".to_string(), json!(normalized_shapes));
    reconcile_record_identities(&mut out);
    Value::Object(out)
}

/// The recorder stores raw shape samples per container edge: a
/// `param_elem_shapes` record describes an element of `items`, not `items`.
/// That ownership is preserved at the schema boundary.
fn container_shapes(
    types: &[String],
    kinds: &[String],
    elements: &[Value],
    keys: &[Value],
    values: &[Value],
) -> Vec<Value> {
    let mut seen: Vec<String> = Vec::new();
    let mut shapes = Vec::new();
    for name in types.iter().chain(kinds) {
        if seen.contains(name) {
            continue;
        }
        seen.push(name.clone());
        match name.to_ascii_lowercase().as_str() {
            "array" if !elements.is_empty() => {
                shapes.push(json!({"kind": "array", "elements": elements}));
            }
            "set" if !elements.is_empty() => {
                shapes.push(json!({"kind": "set", "elements": elements}));
            }
            "hash" if !(keys.is_empty() && values.is_empty()) => {
                shapes.push(json!({"kind": "hash", "keys": keys, "values": values}));
            }
            _ => {}
        }
    }
    shapes
}

fn scope(language: &str, path: &str, owner: &str, function: &str, line: i64) -> Value {
    json!({
        "language": language, "path": path, "owner": owner,
        "function": function, "line": line,
    })
}

fn relative(path: &str, root: &Path) -> String {
    if path.is_empty() {
        return String::new();
    }
    let absolute = if path.starts_with('/') {
        std::path::PathBuf::from(path)
    } else {
        root.join(path)
    };
    absolute
        .strip_prefix(root)
        .map(|rest| rest.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string())
}

fn array_at(row: &Value, field: &str) -> Vec<Value> {
    row[field].as_array().cloned().unwrap_or_default()
}

fn pair_at(row: &Value, field: &str) -> (Vec<Value>, Vec<Value>) {
    let values = array_at(row, field);
    (
        values.first().and_then(Value::as_array).cloned().unwrap_or_default(),
        values.get(1).and_then(Value::as_array).cloned().unwrap_or_default(),
    )
}

/// Everything the collector observed about a named slot, from the row files it
/// wrote. Duplicates across files describing the same slot are merged.
pub fn observations(rows: &ShardRows, root: &Path) -> Vec<Value> {
    let mut out = Vec::new();

    for method in &rows.methods {
        let at = scope(
            "ruby",
            &relative(method["path"].as_str().unwrap_or_default(), root),
            method["class"].as_str().unwrap_or_default(),
            method["method"].as_str().unwrap_or_default(),
            method["line"].as_i64().unwrap_or_default(),
        );
        for (name, types) in method["params_by_name"].as_object().into_iter().flatten() {
            let field = |group: &str| method[group].get(name);
            let (key_shapes, value_shapes) = {
                let raw = method["param_kv_shapes"].get(name).cloned().unwrap_or(json!([]));
                pair_at(&json!({"kv": raw}), "kv")
            };
            let (keys, values) = {
                let raw = method["param_kv"].get(name).cloned().unwrap_or(json!([]));
                pair_at(&json!({"kv": raw}), "kv")
            };
            let mut shapes = field("param_value_shapes")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            shapes.extend(container_shapes(
                &strings(Some(types)),
                &[],
                &field("param_elem_shapes").and_then(Value::as_array).cloned().unwrap_or_default(),
                &key_shapes,
                &value_shapes,
            ));
            let keys = json!(keys);
            let values = json!(values);
            out.push(observation(
                "parameter",
                at.clone(),
                name,
                domain(
                    &[
                        ("types", Some(types)),
                        ("singletons", field("param_singleton_types")),
                        ("elements", field("param_elem")),
                        ("keys", Some(&keys)),
                        ("values", Some(&values)),
                    ],
                    shapes,
                ),
                method["calls"].as_i64().unwrap_or_default(),
                "",
            ));
        }
        let (return_keys, return_values) = pair_at(method, "return_kv");
        let returns_empty = strings(method.get("returns")).is_empty()
            && strings(method.get("return_elem")).is_empty()
            && return_keys.is_empty()
            && return_values.is_empty();
        if !returns_empty {
            let (key_shapes, value_shapes) = pair_at(method, "return_kv_shapes");
            let mut shapes = array_at(method, "return_value_shapes");
            shapes.extend(container_shapes(
                &strings(method.get("returns")),
                &[],
                &array_at(method, "return_elem_shapes"),
                &key_shapes,
                &value_shapes,
            ));
            let keys = json!(return_keys);
            let values = json!(return_values);
            out.push(observation(
                "return",
                at.clone(),
                "",
                domain(
                    &[
                        ("types", method.get("returns")),
                        ("singletons", method.get("return_singleton_types")),
                        ("elements", method.get("return_elem")),
                        ("keys", Some(&keys)),
                        ("values", Some(&values)),
                    ],
                    shapes,
                ),
                method["ok_calls"].as_i64().unwrap_or_default(),
                "",
            ));
        }
    }

    for field in &rows.ivars {
        out.push(observation(
            "state",
            scope("ruby", "", field["class"].as_str().unwrap_or_default(), "", 0),
            field["name"].as_str().unwrap_or_default(),
            domain(&[("types", field.get("classes"))], vec![]),
            field["calls"].as_i64().unwrap_or_default(),
            "",
        ));
    }

    for field in &rows.state_values {
        out.push(observation(
            "state",
            scope(
                "ruby",
                &relative(field["path"].as_str().unwrap_or_default(), root),
                field["class"].as_str().unwrap_or_default(),
                "",
                field["line"].as_i64().unwrap_or_default(),
            ),
            field["name"].as_str().unwrap_or_default(),
            domain(&[("types", field.get("classes"))], vec![]),
            field["calls"].as_i64().unwrap_or_default(),
            "",
        ));
    }

    for field in &rows.structs {
        out.push(observation(
            "state",
            scope(
                "ruby",
                &relative(field["path"].as_str().unwrap_or_default(), root),
                field["class"].as_str().unwrap_or_default(),
                "",
                field["line"].as_i64().unwrap_or_default(),
            ),
            field["field"].as_str().unwrap_or_default(),
            domain(
                &[
                    ("types", field.get("classes")),
                    ("elements", field.get("elem_classes")),
                    ("keys", field.get("key_classes")),
                    ("values", field.get("value_classes")),
                ],
                vec![],
            ),
            field["calls"].as_i64().unwrap_or_default(),
            "",
        ));
    }

    for collection in &rows.collections {
        let kind = collection["kind"].as_str().unwrap_or_default().to_string();
        let shapes = container_shapes(
            &[],
            &[kind],
            &array_at(collection, "elem_shapes"),
            &array_at(collection, "key_shapes"),
            &array_at(collection, "value_shapes"),
        );
        out.push(observation(
            "collection",
            scope(
                "ruby",
                &relative(collection["path"].as_str().unwrap_or_default(), root),
                "",
                "",
                collection["line"].as_i64().unwrap_or_default(),
            ),
            collection["name"].as_str().unwrap_or_default(),
            domain(
                &[
                    ("types", collection.get("classes")),
                    ("elements", collection.get("elem_classes")),
                    ("keys", collection.get("key_classes")),
                    ("values", collection.get("value_classes")),
                ],
                shapes,
            ),
            collection["calls"].as_i64().unwrap_or_default(),
            collection["owner_kind"].as_str().unwrap_or_default(),
        ));
    }

    merge_observations(out)
}

/// Two files can describe the same slot -- a struct field is both a record
/// member and a state write. One slot, one observation.
fn merge_observations(rows: Vec<Value>) -> Vec<Value> {
    let mut merged: Vec<Value> = Vec::new();
    let identity = |row: &Value| {
        (
            row["kind"].clone(),
            row["scope"].clone(),
            row["slot"].clone(),
            row["slot_kind"].clone(),
        )
    };
    for row in rows {
        match merged.iter_mut().find(|existing| identity(existing) == identity(&row)) {
            Some(existing) => {
                for field in ["types", "singletons", "elements", "keys", "values", "shapes"] {
                    let mut values = existing["domain"][field].as_array().cloned().unwrap_or_default();
                    for value in row["domain"][field].as_array().into_iter().flatten() {
                        if !values.contains(value) {
                            values.push(value.clone());
                        }
                    }
                    existing["domain"][field] = json!(values);
                }
                let total = existing["count"].as_i64().unwrap_or_default()
                    + row["count"].as_i64().unwrap_or_default();
                existing["count"] = json!(total);
            }
            None => merged.push(row),
        }
    }
    merged.sort_by_cached_key(|row| {
        let at = &row["scope"];
        (
            at["language"].as_str().unwrap_or_default().to_string(),
            at["path"].as_str().unwrap_or_default().to_string(),
            at["owner"].as_str().unwrap_or_default().to_string(),
            at["function"].as_str().unwrap_or_default().to_string(),
            at["line"].as_i64().unwrap_or_default(),
            row["kind"].as_str().unwrap_or_default().to_string(),
            row["slot"].as_str().unwrap_or_default().to_string(),
        )
    });
    merged
}

// ------------------------------------------------------------------ document

/// The row files a shard directory holds.
#[derive(Debug, Default)]
pub struct ShardRows {
    pub calls: Vec<Value>,
    pub invalid_calls: usize,
    pub methods: Vec<Value>,
    pub ivars: Vec<Value>,
    pub state_values: Vec<Value>,
    pub structs: Vec<Value>,
    pub collections: Vec<Value>,
    pub executed_callsites: Vec<Value>,
    pub exact_anchor_executions: Vec<Value>,
    pub function_entries: Vec<Value>,
    pub coverage: Vec<Value>,
}

/// Rows are written plain and gzipped in place afterwards, so both forms occur
/// -- and within one shard directory, both can occur at once.
fn read_jsonl(runtime_dir: &Path, name: &str) -> Vec<Value> {
    let mut paths = std::fs::read_dir(runtime_dir)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name().is_some_and(|file| {
                let file = file.to_string_lossy();
                file.starts_with(&format!("{name}-"))
                    && (file.ends_with(".jsonl") || file.ends_with(".jsonl.gz"))
            })
        })
        .collect::<Vec<_>>();
    paths.sort();
    // A plain file and its own gzipped copy are the same rows twice.
    paths.dedup_by_key(|path| path.to_string_lossy().trim_end_matches(".gz").to_string());
    paths
        .iter()
        .filter_map(|path| read_text(path))
        .flat_map(|text| {
            text.lines()
                .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                .collect::<Vec<_>>()
        })
        .collect()
}

fn read_text(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    if path.extension().is_some_and(|extension| extension == "gz") {
        use std::io::Read;
        let mut text = String::new();
        flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut text).ok()?;
        return Some(text);
    }
    String::from_utf8(bytes).ok()
}

/// A call event is only usable when it names where it happened and what it
/// reached; anything else is counted and dropped.
fn valid_call(event: &Value) -> bool {
    event["event"].as_str() == Some("runtime_call")
        && !event["language"].as_str().unwrap_or_default().is_empty()
        && event["caller"].is_object()
        && event["callee"].is_object()
        && event["callsite"].is_object()
        && !event["caller"]["path"].as_str().unwrap_or_default().is_empty()
        && !event["callee"]["name"].as_str().unwrap_or_default().is_empty()
        && !event["callsite"]["path"].as_str().unwrap_or_default().is_empty()
        && event["callsite"]["line"].as_i64().unwrap_or_default() > 0
}

pub fn read_shard(runtime_dir: &Path) -> ShardRows {
    let raw_calls = read_jsonl(runtime_dir, "runtime-calls");
    let total = raw_calls.len();
    let calls = raw_calls.into_iter().filter(valid_call).collect::<Vec<_>>();
    ShardRows {
        invalid_calls: total - calls.len(),
        calls,
        methods: read_jsonl(runtime_dir, "methods"),
        ivars: read_jsonl(runtime_dir, "ivars"),
        state_values: read_jsonl(runtime_dir, "state-values"),
        structs: read_jsonl(runtime_dir, "structs"),
        collections: read_jsonl(runtime_dir, "collections"),
        executed_callsites: read_jsonl(runtime_dir, "executed-callsites"),
        exact_anchor_executions: read_jsonl(runtime_dir, "exact-anchor-executions"),
        function_entries: read_jsonl(runtime_dir, "function-entries"),
        coverage: read_jsonl(runtime_dir, "coverage"),
    }
}

fn call_bucket(row: &Value, event: &Value, runtime: &Runtime) -> Option<Value> {
    let count = row["count"].as_i64().unwrap_or(1).max(1);
    let receiver = value_set(
        &row["receiver_domain"],
        runtime,
        row["receiver_source_role"].as_str().unwrap_or("UNKNOWN_SOURCE"),
    )?;
    let mut bucket = Map::new();
    bucket.insert("count".to_string(), json!(count));
    bucket.insert("receiver".to_string(), receiver);
    if let Some(target) = target(row) {
        bucket.insert("target".to_string(), target);
    }
    // The declaration the collector observed. Which planned function it
    // corresponds to is a question about the plan, so the locator travels raw.
    bucket.insert(
        "target_definition".to_string(),
        row["target"].get("definition").cloned().unwrap_or(Value::Null),
    );
    bucket.insert(
        "provenance".to_string(),
        provenance(event["run_id"].as_str().unwrap_or_default()),
    );
    if let Some(result) = value_set(&row["result_domain"], runtime, "UNKNOWN_SOURCE") {
        bucket.insert("result".to_string(), result);
    }
    // One observed truth is a fact about the call; two is a call that went both
    // ways and says nothing about either.
    let mut truths: Vec<&Value> = Vec::new();
    for truth in row["result_truths"].as_array().into_iter().flatten() {
        if !truths.contains(&truth) {
            truths.push(truth);
        }
    }
    if truths.len() == 1 {
        bucket.insert("boolean_result".to_string(), truths[0].clone());
    }
    Some(Value::Object(bucket))
}

fn value_bucket(row: &Value, runtime: &Runtime) -> Option<Value> {
    let count = row["count"].as_i64().unwrap_or(1).max(1);
    let values = value_set(&row["domain"], runtime, "UNKNOWN_SOURCE")?;
    Some(json!({"count": count, "value": values, "provenance": provenance("")}))
}

pub fn build(
    root: &Path,
    runtime_dir: &Path,
    plan_digest: &str,
    runtime: &Runtime,
    run_ids: &[String],
) -> Result<Value> {
    let rows = read_shard(runtime_dir);
    // The translation from what a VM saw into what SCIP names renames and
    // regroups and infers nothing, so it happens with the rest of the join.
    let decoded = rows
        .calls
        .iter()
        .map(|event| crate::runtime_decode::call(event, root))
        .collect::<Vec<_>>();
    let calls = decoded
        .iter()
        .zip(&rows.calls)
        .map(|(row, event)| {
            let mut entry = Map::new();
            entry.insert("row".to_string(), row.clone());
            if let Some(bucket) = call_bucket(row, event, runtime) {
                entry.insert("bucket".to_string(), bucket);
            }
            Value::Object(entry)
        })
        .collect::<Vec<_>>();

    let observations = observations(&rows, root)
        .into_iter()
        .map(|row| {
            let mut row = row;
            if let Some(bucket) = value_bucket(&row, runtime) {
                row["bucket"] = bucket;
            }
            row
        })
        .collect::<Vec<_>>();

    let mut run_ids = run_ids.iter().filter(|id| !id.is_empty()).cloned().collect::<Vec<_>>();
    run_ids.sort();
    run_ids.dedup();

    let mut claims = environment_claims(runtime, root);
    claims.sort();
    claims.dedup();

    Ok(json!({
        "trace_version": VERSION,
        "producer": {"name": PRODUCER, "version": PRODUCER_VERSION},
        "trace_plan_digest": plan_digest,
        "languages": ["ruby"],
        "environment": claims
            .into_iter()
            .map(|(key, value)| json!({"key": key, "value": value}))
            .collect::<Vec<_>>(),
        "run_ids": run_ids,
        "invalid_events": rows.invalid_calls,
        "observations": observations,
        "calls": calls,
        "executed_callsites": rows.executed_callsites,
        "exact_anchor_executions": rows.exact_anchor_executions,
        "function_entries": rows.function_entries,
        "coverage": rows.coverage,
    }))
}

pub fn write(
    root: &Path,
    runtime_dir: &Path,
    plan_digest: &str,
    runtime: &Runtime,
    run_ids: &[String],
) -> Result<()> {
    let document = build(root, runtime_dir, plan_digest, runtime, run_ids)?;
    crate::runtime_trace::write_json(
        &runtime_dir.join("runtime-trace.json.gz"),
        &serde_json::to_string(&document)?,
    )
    .with_context(|| format!("failed to write the trace document for {}", runtime_dir.display()))
}

/// The runtime facts a shard's collector document reports about itself.
pub fn runtime_of(runtime_dir: &Path) -> Result<(Runtime, String)> {
    let mut documents = std::fs::read_dir(runtime_dir)
        .with_context(|| format!("unreadable shard {}", runtime_dir.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name().is_some_and(|name| {
                let name = name.to_string_lossy();
                name.starts_with("collector-raw-") && name.ends_with(".json.gz")
            })
        })
        .collect::<Vec<_>>();
    documents.sort();
    let Some(path) = documents.first() else {
        return Ok((Runtime::default(), String::new()));
    };
    let raw = crate::runtime_protocol::read_json(path)?;
    let document: BTreeMap<String, Value> = serde_json::from_str(&raw)?;
    let text = |field: &str| {
        document.get(field).and_then(Value::as_str).unwrap_or_default().to_string()
    };
    Ok((
        Runtime {
            version: text("ruby_version"),
            engine: text("ruby_engine"),
            engine_version: text("ruby_engine_version"),
        },
        text("run_id"),
    ))
}
