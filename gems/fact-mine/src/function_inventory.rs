//! Stable function identities and semantic fingerprints.
//!
//! An incremental collect asks two questions of a function: is it the same
//! function it was last time, and does the plan want anything observed inside
//! it. The first is a fingerprint of its normalized source, so reformatting is
//! not a change; the second is a lookup into the plan.
//!
//! Identity has to survive a file being edited around it, so it is the
//! (language, path, owner, name, kind) tuple plus how many identical ones
//! preceded it -- not a line number, which every edit above it moves.

use anyhow::Result;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::Path;

/// Plan fields that name a source coordinate the collector was asked to watch.
const DEMAND_FIELDS: [&str; 5] = [
    "runtime_call_sites",
    "runtime_result_call_sites",
    "runtime_collection_receiver_sites",
    "loop_sites",
    "state_write_sites",
];

pub fn build(methods: &[Value], plan: &Value, root: &Path) -> BTreeMap<String, Value> {
    let mut occurrences: BTreeMap<Vec<String>, usize> = BTreeMap::new();
    let mut functions = BTreeMap::new();
    for method in methods {
        let path = relative(method["path"].as_str().unwrap_or_default(), root);
        let span = method["span"].as_array().cloned().unwrap_or_default();
        let identity = ["language", "path", "owner", "name", "kind"]
            .iter()
            .map(|field| match *field {
                "path" => path.clone(),
                other => method[other].as_str().unwrap_or_default().to_string(),
            })
            .collect::<Vec<_>>();
        let occurrence = *occurrences.entry(identity.clone()).or_insert(0);
        *occurrences.get_mut(&identity).expect("counted") += 1;

        let key = identity
            .iter()
            .cloned()
            .chain(std::iter::once(occurrence.to_string()))
            .collect::<Vec<_>>()
            .join("\u{0}");
        // Normalized source where there is any, so a reformat is not an edit.
        let normalized = match method["normalized_source"].as_str() {
            Some(source) if !source.is_empty() => source,
            _ => method["raw_source"].as_str().unwrap_or_default(),
        };
        let mut entry = Map::new();
        entry.insert("key".into(), json!(key));
        entry.insert("language".into(), json!(identity[0]));
        entry.insert("path".into(), json!(path));
        entry.insert("owner".into(), json!(identity[2]));
        entry.insert("name".into(), json!(identity[3]));
        entry.insert("kind".into(), json!(identity[4]));
        entry.insert("occurrence".into(), json!(occurrence));
        entry.insert("line".into(), json!(method["line"].as_i64().unwrap_or_default()));
        entry.insert("span".into(), json!(span));
        entry.insert("fingerprint".into(), json!(fingerprint(normalized)));
        entry.insert("runtime_demand".into(), json!(demanded(method, &span, plan, root)));
        functions.insert(key, Value::Object(entry));
    }
    functions
}

fn fingerprint(source: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(source.as_bytes()))
}

fn bounds(span: &[Value]) -> (i64, i64) {
    let first = span.first().and_then(Value::as_i64).unwrap_or_default();
    let last = span.get(2).and_then(Value::as_i64).unwrap_or_default();
    (first.min(last), first.max(last))
}

/// Whether the plan wants anything observed in this function: its own entry
/// asks for a sample or a frame, or some watched coordinate falls inside it.
fn demanded(method: &Value, span: &[Value], plan: &Value, root: &Path) -> bool {
    let absolute = absolute(method["path"].as_str().unwrap_or_default(), root);
    let method_key = [
        method["owner"].as_str().unwrap_or_default().to_string(),
        method["name"].as_str().unwrap_or_default().to_string(),
        method["kind"].as_str().unwrap_or_default().to_string(),
        absolute.clone(),
        method["line"].as_i64().unwrap_or_default().to_string(),
    ]
    .join("\u{0}");
    if let Some(entry) = plan["methods"].get(&method_key) {
        if entry["sample"].as_bool().unwrap_or(false) || entry["frame"].as_bool().unwrap_or(false) {
            return true;
        }
    }
    let (first, last) = bounds(span);
    DEMAND_FIELDS.iter().any(|field| {
        plan[*field].as_object().into_iter().flatten().any(|(key, _)| {
            let mut parts = key.splitn(3, '\u{0}');
            let path = parts.next().unwrap_or_default();
            let line = parts.next().and_then(|line| line.parse::<i64>().ok()).unwrap_or_default();
            path == absolute && line >= first && line <= last
        })
    })
}

fn absolute(path: &str, root: &Path) -> String {
    if path.starts_with('/') {
        path.to_string()
    } else {
        root.join(path).to_string_lossy().to_string()
    }
}

fn relative(path: &str, root: &Path) -> String {
    let absolute = absolute(path, root);
    Path::new(&absolute)
        .strip_prefix(root)
        .map(|rest| rest.to_string_lossy().to_string())
        .unwrap_or(absolute)
}

pub fn write(methods: &[Value], plan: &Value, root: &Path, output: &Path) -> Result<usize> {
    let functions = build(methods, plan, root);
    std::fs::write(output, serde_json::to_string(&functions)?)?;
    Ok(functions.len())
}
