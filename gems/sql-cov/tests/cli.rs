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

#[test]
fn cli_analyze_command() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = tempfile::NamedTempFile::new().unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "analyze",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--format",
            "json",
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());

    let report = std::fs::read_to_string(output.path()).unwrap();
    assert!(report.contains("raw_expression"));
}

#[test]
fn cli_hazards_command() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = tempfile::NamedTempFile::new().unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "sarif",
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());

    let report = std::fs::read_to_string(output.path()).unwrap();
    assert!(report.contains("https://json.schemastore.org/sarif-2.1.0.json"));
}

#[test]
fn cli_error_handling() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // Invalid subcommand
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args(["invalid_command"])
        .status()
        .unwrap();
    assert!(!status.success());

    // Invalid dialect
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "analyze",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--dialect",
            "invalid_dialect",
        ])
        .status()
        .unwrap();
    assert!(!status.success());

    // Invalid format
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "analyze",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--format",
            "invalid_format",
        ])
        .status()
        .unwrap();
    assert!(!status.success());
}

#[test]
fn cli_writes_to_stdout_when_no_output_file() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "analyze",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--format",
            "json",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("raw_expression"));
}

#[test]
fn cli_postgres_mysql_failures() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    // Postgres run failure
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "run",
            "--input",
            root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
            "--dialect",
            "postgres",
            "--database",
            "postgres://127.0.0.1:9999/dummy",
        ])
        .status()
        .unwrap();
    assert!(!status.success());

    // Mysql run failure
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "run",
            "--input",
            root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
            "--dialect",
            "mysql",
            "--database",
            "mysql://127.0.0.1:9999/dummy",
        ])
        .status()
        .unwrap();
    assert!(!status.success());

    // Postgres hazards failure
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
            "--dialect",
            "postgres",
            "--database",
            "postgres://127.0.0.1:9999/dummy",
        ])
        .status()
        .unwrap();
    assert!(!status.success());

    // Mysql hazards failure
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
            "--dialect",
            "mysql",
            "--database",
            "mysql://127.0.0.1:9999/dummy",
        ])
        .status()
        .unwrap();
    assert!(!status.success());
}
