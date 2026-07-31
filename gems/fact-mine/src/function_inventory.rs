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

// ------------------------------------------------------------- bookkeeping

/// Which functions a shard exercised, and which callsites it reached.
///
/// An incremental collect reruns a shard when a function it depended on
/// changed, so "depended on" has to be answered from what the shard actually
/// executed -- its function entries where it recorded them, and its line
/// coverage where it did not.
pub fn shard_bookkeeping(
    inventory: &BTreeMap<String, Value>,
    runtime_dir: &Path,
    root: &Path,
) -> (Vec<String>, Vec<Value>) {
    let mut keys: Vec<String> = Vec::new();

    let entries = crate::trace_document::read_rows(runtime_dir, "function-entries");
    if entries.is_empty() {
        for row in crate::trace_document::read_rows(runtime_dir, "coverage") {
            let path = row["path"].as_str().unwrap_or_default();
            let lines = row["lines"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_i64)
                .collect::<Vec<_>>();
            for key in keys_for_coverage(inventory, path, &lines, root) {
                push_unique(&mut keys, key);
            }
        }
    } else {
        for row in entries {
            let found = key_for_entry(
                inventory,
                row["path"].as_str().unwrap_or_default(),
                row["owner"].as_str().unwrap_or_default(),
                row["name"].as_str().unwrap_or_default(),
                row["kind"].as_str().unwrap_or_default(),
                row["line"].as_i64(),
                root,
            );
            if let Some(key) = found {
                push_unique(&mut keys, key);
            }
        }
    }
    keys.sort();

    // Executed callsites where the shard recorded them, the calls themselves
    // where it did not.
    let mut rows = crate::trace_document::read_rows(runtime_dir, "executed-callsites");
    if rows.is_empty() {
        rows = crate::trace_document::read_rows(runtime_dir, "runtime-calls");
    }
    let mut sites: Vec<Value> = Vec::new();
    for row in rows {
        let callsite = if row.get("callsite").is_some() { &row["callsite"] } else { &row };
        let site = json!([
            relative(callsite["path"].as_str().unwrap_or_default(), root),
            callsite["line"].as_i64().unwrap_or_default(),
            callsite["selector"].as_str().unwrap_or_default(),
        ]);
        if !sites.contains(&site) {
            sites.push(site);
        }
    }
    // Path, then line as a number, then selector -- a line sorts before a
    // longer one, which sorting by text would get backwards.
    sites.sort_by_cached_key(|site| {
        (
            site[0].as_str().unwrap_or_default().to_string(),
            site[1].as_i64().unwrap_or_default(),
            site[2].as_str().unwrap_or_default().to_string(),
        )
    });
    (keys, sites)
}

fn push_unique(keys: &mut Vec<String>, key: String) {
    if !keys.contains(&key) {
        keys.push(key);
    }
}

/// The functions whose span covers any executed line.
fn keys_for_coverage(
    inventory: &BTreeMap<String, Value>,
    path: &str,
    lines: &[i64],
    root: &Path,
) -> Vec<String> {
    let relative_path = relative(path, root);
    inventory
        .values()
        .filter(|function| function["path"].as_str() == Some(relative_path.as_str()))
        .filter_map(|function| {
            let span = function["span"].as_array().cloned().unwrap_or_default();
            let (first, last) = bounds(&span);
            lines
                .iter()
                .any(|line| *line >= first && *line <= last)
                .then(|| function["key"].as_str().unwrap_or_default().to_string())
        })
        .collect()
}

/// The function a recorded entry belongs to. Where a file holds more than one
/// with the same identity, the entry's line decides -- exactly, then by span.
fn key_for_entry(
    inventory: &BTreeMap<String, Value>,
    path: &str,
    owner: &str,
    name: &str,
    kind: &str,
    line: Option<i64>,
    root: &Path,
) -> Option<String> {
    let relative_path = relative(path, root);
    let candidates = inventory
        .values()
        .filter(|function| {
            function["path"].as_str() == Some(relative_path.as_str())
                && function["owner"].as_str() == Some(owner)
                && function["name"].as_str() == Some(name)
                && function["kind"].as_str() == Some(kind)
        })
        .collect::<Vec<_>>();
    if candidates.len() < 2 {
        return candidates
            .first()
            .and_then(|function| function["key"].as_str())
            .map(str::to_string);
    }
    let entry_line = line.unwrap_or_default();
    candidates
        .iter()
        .find(|function| function["line"].as_i64() == Some(entry_line))
        .or_else(|| {
            candidates.iter().find(|function| {
                let (first, last) = bounds(&function["span"].as_array().cloned().unwrap_or_default());
                entry_line >= first && entry_line <= last
            })
        })
        .and_then(|function| function["key"].as_str())
        .map(str::to_string)
}
