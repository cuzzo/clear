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

#[cfg(test)]
mod tests {
    use super::*;

    fn method(owner: &str, name: &str, line: i64, source: &str) -> Value {
        json!({
            "language": "ruby",
            "path": "lib/app.rb",
            "owner": owner,
            "name": name,
            "kind": "instance",
            "line": line,
            "span": [line, 0, line + 2, 0],
            "normalized_source": source,
        })
    }

    fn root() -> &'static Path {
        Path::new("/repo")
    }

    #[test]
    fn two_definitions_with_one_identity_stay_distinct() {
        // A file may define the same method twice. Keying on the identity
        // alone would collapse them and lose one of the two fingerprints, so
        // an edit to the second would look like no change at all.
        let methods = vec![
            method("App", "value", 2, "def value; 1; end"),
            method("App", "value", 6, "def value; 2; end"),
        ];

        let built = build(&methods, &json!({}), root());

        assert_eq!(built.len(), 2);
        let occurrences: Vec<i64> =
            built.values().filter_map(|f| f["occurrence"].as_i64()).collect();
        assert_eq!(occurrences, vec![0, 1]);
        let fingerprints: Vec<&str> =
            built.values().filter_map(|f| f["fingerprint"].as_str()).collect();
        assert_ne!(fingerprints[0], fingerprints[1]);
    }

    #[test]
    fn a_reformat_above_a_function_is_not_a_change_to_it() {
        // Identity is the (language, path, owner, name, kind) tuple plus its
        // occurrence, never the line -- every edit above a function moves that.
        let before = build(&[method("App", "value", 2, "def value; 1; end")], &json!({}), root());
        let after = build(&[method("App", "value", 40, "def value; 1; end")], &json!({}), root());

        assert_eq!(before.keys().collect::<Vec<_>>(), after.keys().collect::<Vec<_>>());
        let fingerprint = |set: &BTreeMap<String, Value>| {
            set.values().next().unwrap()["fingerprint"].as_str().unwrap().to_string()
        };
        assert_eq!(fingerprint(&before), fingerprint(&after));
        // The line still moves; it is recorded, just not part of identity.
        assert_eq!(after.values().next().unwrap()["line"], json!(40));
    }

    #[test]
    fn an_absolute_path_is_recorded_relative_to_the_root() {
        let mut method = method("App", "value", 2, "def value; end");
        method["path"] = json!("/repo/lib/app.rb");

        let built = build(&[method], &json!({}), root());

        assert_eq!(built.values().next().unwrap()["path"], json!("lib/app.rb"));
    }

    #[test]
    fn demand_follows_the_plan_and_not_the_source() {
        let plain = method("App", "value", 2, "def value; end");
        let unwatched = build(&[plain.clone()], &json!({}), root());
        assert_eq!(unwatched.values().next().unwrap()["runtime_demand"], json!(false));

        // Asked for by name: the plan keys methods on the absolute path.
        let key = ["App", "value", "instance", "/repo/lib/app.rb", "2"].join("\u{0}");
        let by_name = build(&[plain.clone()], &json!({"methods": {key: {"sample": true}}}), root());
        assert_eq!(by_name.values().next().unwrap()["runtime_demand"], json!(true));

        // Asked for by coordinate: a watched line inside the function's span.
        let inside = format!("/repo/lib/app.rb\u{0}3\u{0}call");
        let by_site =
            build(&[plain.clone()], &json!({"runtime_call_sites": {inside: {}}}), root());
        assert_eq!(by_site.values().next().unwrap()["runtime_demand"], json!(true));

        // A coordinate past the end of the span is some other function's.
        let outside = format!("/repo/lib/app.rb\u{0}99\u{0}call");
        let beyond =
            build(&[plain], &json!({"runtime_call_sites": {outside: {}}}), root());
        assert_eq!(beyond.values().next().unwrap()["runtime_demand"], json!(false));
    }

    #[test]
    fn a_recorded_entry_resolves_to_the_definition_its_line_falls_in() {
        let methods = vec![
            method("App", "value", 2, "def value; 1; end"),
            method("App", "value", 6, "def value; 2; end"),
        ];
        let built = build(&methods, &json!({}), root());
        let expected = |occurrence: i64| {
            built
                .values()
                .find(|f| f["occurrence"] == json!(occurrence))
                .and_then(|f| f["key"].as_str())
                .map(str::to_string)
        };

        // Exactly on the definition line.
        assert_eq!(
            key_for_entry(&built, "lib/app.rb", "App", "value", "instance", Some(6), root()),
            expected(1)
        );
        // Inside the second definition's span but not on its first line.
        assert_eq!(
            key_for_entry(&built, "lib/app.rb", "App", "value", "instance", Some(7), root()),
            expected(1)
        );
        assert_eq!(
            key_for_entry(&built, "lib/app.rb", "App", "value", "instance", Some(2), root()),
            expected(0)
        );
        assert_eq!(
            key_for_entry(&built, "lib/app.rb", "Other", "value", "instance", Some(2), root()),
            None
        );
    }

    #[test]
    fn coverage_attributes_an_executed_line_to_every_function_spanning_it() {
        let methods = vec![
            method("App", "first", 2, "def first; end"),
            method("App", "second", 10, "def second; end"),
        ];
        let built = build(&methods, &json!({}), root());

        let covered = keys_for_coverage(&built, "/repo/lib/app.rb", &[3], root());

        assert_eq!(covered.len(), 1);
        assert!(covered[0].contains("first"), "{covered:?}");
        assert!(keys_for_coverage(&built, "/repo/lib/app.rb", &[100], root()).is_empty());
    }
}
