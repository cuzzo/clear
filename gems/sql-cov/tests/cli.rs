use std::path::PathBuf;
use std::process::Command;

#[test]
fn cli_writes_standard_lcov_branch_records() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = tempfile::NamedTempFile::new().unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "run",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "lcov",
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());

    let report = std::fs::read_to_string(output.path()).unwrap();
    assert!(report.contains("BRDA:"));
    assert!(report.contains("BRF:9"));
    assert!(report.contains("BRH:9"));
    assert!(report.ends_with("end_of_record\n"));
}
