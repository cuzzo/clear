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
fn cli_plan_command_emits_canonical_sarif() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output = tempfile::NamedTempFile::new().unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args(["plan", "--input", root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
            "--setup", root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--output", output.path().to_str().unwrap()])
        .status().unwrap();
    assert!(result.success());
    let report: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(output.path()).unwrap()).unwrap();
    assert_eq!(report["runs"][0]["tool"]["driver"]["name"], "SQL-COV");
    assert_eq!(report["runs"][0]["properties"]["format"], "sql-cov.plan.sarif.v1");
    assert!(report["runs"][0]["results"].as_array().unwrap().iter()
        .any(|result| result["ruleId"] == "complexity.observation"));
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

#[test]
fn cli_run_html_and_json_formats() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let output_html = tempfile::NamedTempFile::new().unwrap();
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
            "html",
            "--output",
            output_html.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());

    let report_html = std::fs::read_to_string(output_html.path()).unwrap();
    assert!(report_html.contains("<!doctype html>"));

    let output_json = tempfile::NamedTempFile::new().unwrap();
    let result_json = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "run",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "json",
            "--output",
            output_json.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result_json.success());

    let report_json = std::fs::read_to_string(output_json.path()).unwrap();
    assert!(report_json.contains("metrics"));
}

#[test]
fn cli_hazards_json_and_invalid_formats() {
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
            "json",
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());

    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "invalid",
        ])
        .status()
        .unwrap();
    assert!(!status.success());
}

#[test]
fn cli_hazards_with_looker_and_sqlfluff_sarif() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let lookml_file = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(
        lookml_file.path(),
        r#"
explore: companies {
  join: employees {
    relationship: one_to_many
    sql_on: ${companies.company_id} = ${employees.company_id} ;;
  }
}
"#,
    )
    .unwrap();

    let sqlfluff_sarif_file = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(sqlfluff_sarif_file.path(), "{}").unwrap();

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
            "--looker-hazards",
            lookml_file.path().to_str().unwrap(),
            "--sqlfluff-sarif",
            sqlfluff_sarif_file.path().to_str().unwrap(),
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());
}

#[test]
fn cli_generate_check_commands() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    
    // First run hazards to output json to find a real ID, or use generate-check directly
    // Let's run generate-check with a non-existent ID first
    let output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "generate-check",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--id",
            "nonexistent_finding_id",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());

    // Let's get the JSON output from hazards to extract a real finding ID
    let hazards_output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql")
                .to_str()
                .unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "json",
        ])
        .output()
        .unwrap();
    assert!(hazards_output.status.success());
    let hazards_str = String::from_utf8(hazards_output.stdout).unwrap();
    
    // Let's parse the JSON to get the first finding ID
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&hazards_str) {
        if let Some(findings) = val.get("findings").and_then(|f| f.as_array()) {
            if let Some(finding) = findings.first() {
                if let Some(id) = finding.get("id").and_then(|i| i.as_str()) {
                    let gen_output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
                        .args([
                            "generate-check",
                            "--input",
                            root.join("tests/fixtures/users_query.sql")
                                .to_str()
                                .unwrap(),
                            "--setup",
                            root.join("tests/fixtures/users.sql").to_str().unwrap(),
                            "--id",
                            id,
                        ])
                        .output()
                        .unwrap();
                    assert!(gen_output.status.success());
                }
            }
        }
    }
}

#[test]
fn cli_hazards_empty_schema_bail() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let status = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            root.join("tests/fixtures/users_query.sql").to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(!status.success());
}

#[test]
fn cli_hazards_with_sqlfluff_integration() {
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
            "--sqlfluff",
            "--output",
            output.path().to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(result.success());
}
#[test]
fn cli_generate_check_with_outer_join_hazard() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let temp_dir = tempfile::tempdir().unwrap();
    let query_file = temp_dir.path().join("outer_join_query.sql");
    std::fs::write(
        &query_file,
        "SELECT * FROM users u1 LEFT JOIN users u2 ON u1.id = u2.id WHERE u2.name != 'Alice'",
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
        .args([
            "hazards",
            "--input",
            query_file.to_str().unwrap(),
            "--setup",
            root.join("tests/fixtures/users.sql").to_str().unwrap(),
            "--format",
            "json",
        ])
        .output()
        .unwrap();

    assert!(output.status.success());
    let hazards_str = String::from_utf8(output.stdout).unwrap();
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&hazards_str) {
        if let Some(findings) = val.get("findings").and_then(|f| f.as_array()) {
            // Find a finding with NullableNotEqual or similar that targets u2.name
            let finding_opt = findings.iter().find(|finding| {
                finding
                    .get("evidence")
                    .and_then(|ev| ev.as_array())
                    .map(|ev_arr| {
                        ev_arr.iter().any(|ev_val| {
                            ev_val
                                .as_str()
                                .map(|s| s.contains("outer join can synthesize NULL for"))
                                .unwrap_or(false)
                        })
                    })
                    .unwrap_or(false)
            });

            if let Some(finding) = finding_opt {
                if let Some(id) = finding.get("id").and_then(|i| i.as_str()) {
                    let gen_output = Command::new(env!("CARGO_BIN_EXE_sql-cov"))
                        .args([
                            "generate-check",
                            "--input",
                            query_file.to_str().unwrap(),
                            "--setup",
                            root.join("tests/fixtures/users.sql").to_str().unwrap(),
                            "--id",
                            id,
                        ])
                        .output()
                        .unwrap();
                    assert!(gen_output.status.success());
                    let gen_str = String::from_utf8(gen_output.stdout).unwrap();
                    assert!(gen_str.contains("Checking nullable column"));
                }
            }
        }
    }
}
