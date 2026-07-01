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
