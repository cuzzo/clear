#[test]
fn run_all_syntax_and_profile_helpers_unit_tests_as_integration() {
    fact_mine_rust::test_helpers::run_all();
}

#[test]
fn test_cli_error_paths_and_variations() {
    use std::process::Command;
    let bin_path = env!("CARGO_BIN_EXE_fact-mine-rust");

    // 1. Invalid command
    let out = Command::new(bin_path).arg("invalid-command").output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("usage: fact-mine-rust"));

    // 2. syntax-facts requires at least one file
    let out = Command::new(bin_path).arg("syntax-facts").output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("requires at least one file"));

    // 3. profile requires at least one file
    let out = Command::new(bin_path).args(&["profile", "espalier"]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("requires at least one file"));

    // 4. unsupported profile
    let out = Command::new(bin_path).args(&["profile", "invalid-profile", "Cargo.toml"]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unsupported profile:"));

    // 5. unsupported option in syntax-facts
    let out = Command::new(bin_path).args(&["syntax-facts", "--invalid-flag", "Cargo.toml"]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unsupported option:"));

    // 6. unsupported option in profile
    let out = Command::new(bin_path).args(&["profile", "espalier", "--invalid-flag", "Cargo.toml"]).output().unwrap();
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unsupported option:"));

    // 7. run profile to stdout (no --output flag)
    let out = Command::new(bin_path).args(&["profile", "espalier", "src/lib.rs"]).output().unwrap();
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"methods\""));

    // 8. run profile with --output=xxx
    let temp_dir = std::env::temp_dir();
    let temp_file = temp_dir.join("test_out.json");
    let out = Command::new(bin_path)
        .args(&[
            "profile",
            "espalier",
            &format!("--output={}", temp_file.display()),
            "src/lib.rs",
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(temp_file.exists());
    let _ = std::fs::remove_file(temp_file);

    // 9. run profile with --language=rust
    let out = Command::new(bin_path)
        .args(&["profile", "espalier", "--language=rust", "src/lib.rs"])
        .output()
        .unwrap();
    assert!(out.status.success());

    // 10. run profile --language without value (error)
    let out = Command::new(bin_path)
        .args(&["profile", "espalier", "--language", "src/lib.rs"])
        .output()
        .unwrap();
    assert!(!out.status.success());
}

#[test]
fn trace_plan_cli_is_deterministic_across_worker_counts() {
    use std::io::Write;
    use std::process::Command;

    let bin_path = env!("CARGO_BIN_EXE_fact-mine-rust");
    let mut first = tempfile::Builder::new().suffix(".rb").tempfile().unwrap();
    let mut second = tempfile::Builder::new().suffix(".rb").tempfile().unwrap();
    first
        .write_all(b"class A\n  def one(value)\n    value\n  end\nend\n")
        .unwrap();
    second
        .write_all(b"class B\n  def two(value)\n    value\n  end\nend\n")
        .unwrap();

    let run = |jobs: &str| {
        Command::new(bin_path)
            .env("FACT_MINE_JOBS", jobs)
            .args([
                "profile",
                "trace-plan",
                first.path().to_str().unwrap(),
                second.path().to_str().unwrap(),
            ])
            .output()
            .unwrap()
    };
    let sequential = run("1");
    let parallel = run("4");

    assert!(sequential.status.success());
    assert!(parallel.status.success());
    assert_eq!(sequential.stdout, parallel.stdout);
}
