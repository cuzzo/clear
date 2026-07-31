//! Which shards an incremental collect has to rerun.
//!
//! The question is answered by comparing two manifests: what the sources,
//! functions, tests and workload were last time against what they are now. A
//! shard reruns when a test it owns changed or a function it depended on did.
//!
//! Everything that cannot be attributed to a specific shard falls back to a
//! full collect. That is the whole safety property: it is always sound to rerun
//! everything, and never sound to skip a shard whose evidence might be stale.

use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

fn strings(value: &Value) -> Vec<String> {
    value
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, _)| key.clone())
        .collect()
}

fn table<'a>(value: &'a Value, field: &str) -> &'a Value {
    value.get(field).unwrap_or(&Value::Null)
}

fn sorted(mut values: Vec<String>) -> Vec<String> {
    values.sort();
    values.dedup();
    values
}

/// Keys present in `current` whose value differs from `previous`.
fn changed(current: &Value, previous: &Value) -> Vec<String> {
    current
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, value)| previous.get(key.as_str()) != Some(*value))
        .map(|(key, _)| key.clone())
        .collect()
}

fn missing(previous: &Value, current: &Value) -> Vec<String> {
    let present = current.as_object().map(|map| {
        map.keys().cloned().collect::<BTreeSet<_>>()
    }).unwrap_or_default();
    strings(previous).into_iter().filter(|key| !present.contains(key)).collect()
}

pub struct Increment<'a> {
    pub manifest: &'a Value,
    pub current_hashes: &'a Value,
    pub current_environment: &'a Value,
    pub functions: &'a Value,
    pub workload: &'a Value,
    pub trace_plan_digest: &'a str,
}

pub fn select(input: &Increment<'_>) -> Value {
    let manifest = input.manifest;
    let previous_hashes = table(manifest, "source_hashes");
    let changed_files = changed(input.current_hashes, previous_hashes);
    let deleted_files = missing(previous_hashes, input.current_hashes);

    let previous_functions = table(manifest, "functions");
    let previous_workload = table(manifest, "workload");
    let previous_tests = table(previous_workload, "tests");
    let current_tests = table(input.workload, "tests");
    let changed_tests = changed(current_tests, previous_tests);
    let deleted_tests = missing(previous_tests, current_tests);
    let support_changed =
        table(previous_workload, "support_files") != table(input.workload, "support_files");

    let added_functions = missing(input.functions, previous_functions);
    let deleted_functions = missing(previous_functions, input.functions);
    let changed_functions = input
        .functions
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, function)| {
            previous_functions.get(key.as_str()).is_some_and(|before| {
                before["fingerprint"] != function["fingerprint"]
            })
        })
        .map(|(key, _)| key.clone())
        .collect::<Vec<_>>();

    // A source edit that some function already accounts for is not a residual
    // change; one that no function explains means something moved that shard
    // selection cannot see.
    let path_of = |keys: &[String], table: &Value| {
        keys.iter()
            .filter_map(|key| table[key.as_str()]["path"].as_str().map(str::to_string))
            .collect::<Vec<_>>()
    };
    let mut function_changed_paths = path_of(&changed_functions, input.functions);
    function_changed_paths.extend(path_of(&added_functions, input.functions));
    function_changed_paths.extend(path_of(&deleted_functions, previous_functions));
    let residual_source_changes = sorted(
        changed_files
            .iter()
            .chain(&deleted_files)
            .filter(|path| !function_changed_paths.contains(path))
            .cloned()
            .collect(),
    );

    let environment_changed = *input.current_environment != *table(manifest, "environment");
    let command_changed =
        previous_workload["command_digest"] != input.workload["command_digest"];
    let mode_changed = previous_workload["mode"] != input.workload["mode"];
    let trace_plan_changed =
        manifest["trace_plan_digest"].as_str().unwrap_or_default() != input.trace_plan_digest;
    // A source edit necessarily changes FactMine's anchor digests, and function
    // and test selection plus evidence rebasing already cover that. A plan that
    // changed with identical sources is different: the analyzer's demand moved
    // and no source dependency says which shards it touched.
    let unexplained_trace_plan_changed =
        trace_plan_changed && changed_files.is_empty() && deleted_files.is_empty();

    let current_shards = table(input.workload, "shards");
    let deleted_shards = sorted(missing(table(previous_workload, "shards"), current_shards));

    let mut selected: Vec<String> = changed_tests
        .iter()
        .filter_map(|path| {
            current_shards.as_object().into_iter().flatten().find_map(|(id, shard)| {
                (shard["test_path"].as_str() == Some(path.as_str())).then(|| id.clone())
            })
        })
        .collect();
    let dependencies = table(manifest, "dependencies");
    for function_key in &changed_functions {
        for (shard_id, keys) in dependencies.as_object().into_iter().flatten() {
            let depends = keys
                .as_array()
                .into_iter()
                .flatten()
                .any(|key| key.as_str() == Some(function_key.as_str()));
            if depends {
                selected.push(shard_id.clone());
            }
        }
    }

    let uncertain = environment_changed
        || command_changed
        || mode_changed
        || unexplained_trace_plan_changed
        || support_changed
        || !added_functions.is_empty()
        || !deleted_functions.is_empty()
        || !residual_source_changes.is_empty();
    // An opaque workload has no test-to-shard mapping, so any change at all
    // means every shard is suspect.
    let opaque_fallback = input.workload["mode"].as_str() == Some("opaque")
        && (!changed_functions.is_empty()
            || !changed_tests.is_empty()
            || !deleted_tests.is_empty());
    let fallback_full = uncertain || opaque_fallback;
    if fallback_full {
        selected = strings(current_shards);
    }
    let selected = sorted(selected);

    let rebuild = !selected.is_empty()
        || !deleted_shards.is_empty()
        || !changed_functions.is_empty()
        || !added_functions.is_empty()
        || !deleted_functions.is_empty()
        || fallback_full;

    let mut out = Map::new();
    out.insert("selected_shards".into(), json!(selected));
    out.insert("deleted_shards".into(), json!(deleted_shards));
    out.insert("changed_tests".into(), json!(sorted(changed_tests)));
    out.insert("deleted_tests".into(), json!(sorted(deleted_tests)));
    out.insert("changed_functions".into(), json!(sorted(changed_functions)));
    out.insert("added_functions".into(), json!(sorted(added_functions)));
    out.insert("deleted_functions".into(), json!(sorted(deleted_functions)));
    out.insert("changed_files".into(), json!(sorted(changed_files)));
    out.insert("deleted_files".into(), json!(sorted(deleted_files)));
    out.insert("residual_source_changes".into(), json!(residual_source_changes));
    out.insert("support_changed".into(), json!(support_changed));
    out.insert("environment_changed".into(), json!(environment_changed));
    out.insert("command_changed".into(), json!(command_changed));
    out.insert("trace_plan_changed".into(), json!(trace_plan_changed));
    out.insert("unexplained_trace_plan_changed".into(), json!(unexplained_trace_plan_changed));
    out.insert("uncertain_closure".into(), json!(false));
    out.insert("fallback_full".into(), json!(fallback_full));
    out.insert("rebuild".into(), json!(rebuild));
    out.insert("current_hashes".into(), input.current_hashes.clone());
    out.insert("environment".into(), input.current_environment.clone());
    out.insert("functions".into(), input.functions.clone());
    out.insert("workload".into(), input.workload.clone());
    out.insert("trace_plan_digest".into(), json!(input.trace_plan_digest));
    Value::Object(out)
}
