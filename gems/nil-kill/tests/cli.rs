use serde_json::json;
use std::fs;
use std::path::PathBuf;
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
                    "state": "maybe_null",
                    "complete": true,
                    "place_id": "place:cache:value",
                    "source_definition_ids": ["definition:cache_lookup"]
                }],
                "nullable_refinements": [{
                    "place_id": "place:cache:value",
                    "condition_node_id": "guard:1",
                    "complete": true,
                    "source_definition_ids": ["definition:cache_lookup"]
                }],
                "nullable_summaries": [{
                    "owner": "Cache",
                    "function": "lookup",
                    "return_state": "maybe_null",
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
                    "state_at_operation": "maybe_null",
                    "complete": true,
                    "source_definition_ids": ["definition:cache_lookup"]
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
    assert_eq!(
        action["data"]["root_definition_id"],
        "definition:cache_lookup"
    );
    assert_eq!(action["data"]["pressure"], 3);
    assert_eq!(action["path"], "src/cache.c");
    assert_eq!(action["line"], 22);
}

#[test]
fn binary_reports_primitive_domain_from_canonical_factmine_observations() {
    let bin = env!("CARGO_BIN_EXE_nil-kill-infer-rust");
    let dir = tempfile::tempdir().unwrap();
    let input_path = dir.path().join("input.json");
    let output_path = dir.path().join("output.json");
    fs::write(
        &input_path,
        serde_json::to_vec_pretty(&json!({
            "facts": {
                "hidden_enum_observations": [
                    {
                        "event": "producer", "kind": "state", "key": "state\0workflow",
                        "path": "src/workflow.rb", "line": 2, "slot": "@state",
                        "site": {"path": "src/workflow.rb", "line": 4, "kind": "assignment"},
                        "values": [{"kind": "String", "value": "\"draft\""}]
                    },
                    {
                        "event": "decision", "kind": "state", "key": "state\0workflow",
                        "path": "src/workflow.rb", "line": 2, "slot": "@state",
                        "site": {"path": "src/workflow.rb", "line": 8, "kind": "case"},
                        "values": [
                            {"kind": "String", "value": "\"draft\""},
                            {"kind": "String", "value": "\"sent\""}
                        ]
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
    assert!(run.status.success());

    let output: serde_json::Value =
        serde_json::from_slice(&fs::read(&output_path).unwrap()).unwrap();
    let action = output["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["kind"] == "report_static_primitive_domain")
        .unwrap();
    assert_eq!(action["confidence"], "review");
    assert_eq!(action["path"], "src/workflow.rb");
    assert_eq!(action["data"]["values"], json!(["\"draft\"", "\"sent\""]));
}

#[test]
fn factmine_integer_domain_reaches_nilkill_with_final_review_message() {
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../fact-mine/tests/fixtures/hidden_enum_symbol_integer.rb");
    let document =
        fact_mine_rust::syntax::parse_file(fixture, fact_mine_rust::syntax::Language::Ruby)
            .unwrap();
    let mined =
        fact_mine_rust::profile::extract(&document, fact_mine_rust::profile::Profile::NilKill);
    assert!(mined.hidden_enum_observations.iter().any(|observation| {
        observation["values"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|value| {
                value["kind"] == "Integer" && matches!(value["value"].as_str(), Some("1" | "2"))
            })
    }));

    let bin = env!("CARGO_BIN_EXE_nil-kill-infer-rust");
    let dir = tempfile::tempdir().unwrap();
    let input_path = dir.path().join("input.json");
    let output_path = dir.path().join("output.json");
    fs::write(
        &input_path,
        serde_json::to_vec_pretty(&json!({
            "facts": { "hidden_enum_observations": mined.hidden_enum_observations }
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
    let action = output["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["data"]["slot"] == "@attempt")
        .expect("FactMine integer domain should produce a NilKill review action");
    assert_eq!(action["confidence"], "review");
    assert_eq!(action["data"]["values"], json!(["1", "2"]));
    assert_eq!(
        action["message"],
        "state @attempt has a closed-looking Integer domain across 2 decision sites"
    );
}
