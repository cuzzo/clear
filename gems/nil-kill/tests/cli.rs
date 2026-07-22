use serde_json::json;
use std::fs;
use std::process::Command;

#[test]
fn binary_reports_usage_and_round_trips_actions() {
    let bin = env!("CARGO_BIN_EXE_nil-kill-infer-rust");

    let usage = Command::new(bin).output().unwrap();
    assert!(!usage.status.success());
    assert!(String::from_utf8_lossy(&usage.stderr).contains("Usage: nil-kill-infer-rust"));

    let dir = tempfile::tempdir().unwrap();
    let input_path = dir.path().join("input.json");
    let output_path = dir.path().join("output.json");
    fs::write(
        &input_path,
        serde_json::to_vec_pretty(&json!({
            "methods": [],
            "facts": {
                "dead_nil_checks": [
                    {
                        "kind": "nil_check",
                        "path": "src/user.rb",
                        "line": 7,
                        "code": "user.nil?",
                        "reason": "runtime evidence proves user is non-nil"
                    }
                ]
            }
        }))
        .unwrap(),
    )
    .unwrap();

    let run = Command::new(bin)
        .arg(&input_path)
        .arg(&output_path)
        .output()
        .unwrap();
    assert!(
        run.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&run.stderr)
    );

    let output: serde_json::Value =
        serde_json::from_slice(&fs::read(&output_path).unwrap()).unwrap();
    assert_eq!(output["actions"][0]["kind"], "replace_dead_nil_check");
    assert_eq!(output["diagnostics"].as_object().unwrap().len(), 0);
}

#[test]
fn binary_reports_causal_nullable_pressure_from_public_facts() {
    let bin = env!("CARGO_BIN_EXE_nil-kill-infer-rust");
    let dir = tempfile::tempdir().unwrap();
    let input_path = dir.path().join("input.json");
    let output_path = dir.path().join("output.json");
    fs::write(
        &input_path,
        serde_json::to_vec_pretty(&json!({
            "facts": {
                "nullable_states": [{
                    "state": "definitely_null",
                    "complete": true,
                    "place_id": "place:cache:value",
                    "source_definition_ids": ["definition:cache_lookup"]
                }],
                "nullable_refinements": [{
                    "place_id": "place:cache:value",
                    "condition_node_id": "guard:1"
                }],
                "nullable_summaries": [{
                    "owner": "Cache",
                    "function": "lookup",
                    "return_state": "definitely_null",
                    "complete": true,
                    "source_definition_ids": ["definition:cache_lookup"]
                }],
                "nullable_operations": [{
                    "place_id": "place:cache:value",
                    "node_id": "deref:1",
                    "path": "src/cache.c",
                    "span": [22, 4, 22, 10],
                    "operation_kind": "pointer_dereference",
                    "nil_behavior": "undefined_behavior",
                    "complete": true
                }]
            }
        }))
        .unwrap(),
    )
    .unwrap();

    let run = Command::new(bin)
        .arg(&input_path)
        .arg(&output_path)
        .output()
        .unwrap();
    assert!(run.status.success());

    let output: serde_json::Value =
        serde_json::from_slice(&fs::read(&output_path).unwrap()).unwrap();
    let action = output["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["kind"] == "report_static_nil_pressure")
        .unwrap();
    assert_eq!(action["data"]["root_definition_id"], "definition:cache_lookup");
    assert_eq!(action["data"]["pressure"], 3);
    assert_eq!(action["path"], "src/cache.c");
    assert_eq!(action["line"], 22);
}
