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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn function(path: &str, fingerprint: &str) -> Value {
        json!({"path": path, "fingerprint": fingerprint})
    }

    fn manifest(digest: &str) -> Value {
        json!({
            "source_hashes": {"lib/app.rb": "a"},
            "functions": {"f": function("lib/app.rb", "1")},
            "dependencies": {"shard-a": ["f"]},
            "environment": {},
            "trace_plan_digest": digest,
            "workload": {
                "mode": "test_files",
                "command_digest": "w",
                "tests": {"test/app_test.rb": "t"},
                "support_files": {},
                "shards": {"shard-a": {"test_path": "test/app_test.rb"}},
            },
        })
    }

    fn select_with(manifest: &Value, hashes: Value, functions: Value, digest: &str) -> Value {
        select(&Increment {
            manifest,
            current_hashes: &hashes,
            current_environment: &json!({}),
            functions: &functions,
            workload: &manifest["workload"],
            trace_plan_digest: digest,
        })
    }

    #[test]
    fn nothing_changed_means_nothing_to_rerun() {
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "a"}),
            json!({"f": function("lib/app.rb", "1")}),
            "plan",
        );

        assert_eq!(out["rebuild"], json!(false));
        assert_eq!(out["selected_shards"], json!([]));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_changed_function_reruns_only_the_shards_that_depended_on_it() {
        let mut stored = manifest("plan");
        stored["workload"]["shards"]["shard-b"] = json!({"test_path": "test/other_test.rb"});
        stored["dependencies"]["shard-b"] = json!(["other"]);

        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "plan",
        );

        // The source edit is explained by the function whose fingerprint moved,
        // so it is not a residual change and does not force a full collect.
        assert_eq!(out["changed_functions"], json!(["f"]));
        assert_eq!(out["residual_source_changes"], json!([]));
        assert_eq!(out["fallback_full"], json!(false));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_plan_that_moved_with_no_source_change_reruns_everything() {
        // The analyzer's demand moved and no source dependency says which
        // shards it touched, so none of them can be trusted.
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "a"}),
            json!({"f": function("lib/app.rb", "1")}),
            "different-plan",
        );

        assert_eq!(out["trace_plan_changed"], json!(true));
        assert_eq!(out["unexplained_trace_plan_changed"], json!(true));
        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_plan_change_a_source_edit_explains_is_not_a_full_retrace() {
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "source-updated-plan",
        );

        assert_eq!(out["trace_plan_changed"], json!(true));
        assert_eq!(out["unexplained_trace_plan_changed"], json!(false));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_source_edit_no_function_explains_forces_a_full_collect() {
        // Something moved that shard selection cannot attribute -- a constant,
        // a require, top-level code -- so every shard is suspect.
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "1")}),
            "plan",
        );

        assert_eq!(out["residual_source_changes"], json!(["lib/app.rb"]));
        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_changed_test_reruns_its_own_shard() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["tests"]["test/app_test.rb"] = json!("t2");
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["changed_tests"], json!(["test/app_test.rb"]));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_changed_support_file_reruns_every_shard() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["support_files"] = json!({"test/test_helper.rb": "h"});
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["support_changed"], json!(true));
        assert_eq!(out["fallback_full"], json!(true));
    }

    #[test]
    fn a_deleted_test_drops_its_shard_without_rerunning_it() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["tests"] = json!({});
        workload["shards"] = json!({});
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["deleted_tests"], json!(["test/app_test.rb"]));
        assert_eq!(out["deleted_shards"], json!(["shard-a"]));
        assert_eq!(out["selected_shards"], json!([]));
        assert_eq!(out["rebuild"], json!(true));
    }

    #[test]
    fn an_opaque_workload_reruns_everything_any_change_touches() {
        // No test-to-shard mapping exists, so nothing says a change missed a
        // given command.
        let mut stored = manifest("plan");
        stored["workload"]["mode"] = json!("opaque");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "plan",
        );

        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }
}
