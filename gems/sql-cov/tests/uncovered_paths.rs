use sql_cov::driver::{postgres_pool, mysql_pool, sqlite_pool, ParameterValue};
use sql_cov::schema::{normalize_identifier, SchemaCatalog};
use sql_cov::{
    cover_postgres, cover_mysql, DialectName, analyze_sql,
};
use sql_cov::model::SourceFileCoverage;
use sql_cov::reporter;

#[test]
fn test_parameter_value_parsing() {
    assert_eq!(ParameterValue::parse("null").unwrap(), ParameterValue::NullText);
    assert_eq!(ParameterValue::parse("null:text").unwrap(), ParameterValue::NullText);
    assert_eq!(ParameterValue::parse("null:int").unwrap(), ParameterValue::NullInteger);
    assert_eq!(ParameterValue::parse("null:integer").unwrap(), ParameterValue::NullInteger);
    assert_eq!(ParameterValue::parse("null:float").unwrap(), ParameterValue::NullFloat);
    assert_eq!(ParameterValue::parse("null:bool").unwrap(), ParameterValue::NullBoolean);
    assert_eq!(ParameterValue::parse("null:boolean").unwrap(), ParameterValue::NullBoolean);

    assert_eq!(ParameterValue::parse("int:42").unwrap(), ParameterValue::Integer(42));
    assert_eq!(ParameterValue::parse("float:1.5").unwrap(), ParameterValue::Float(1.5));
    assert_eq!(ParameterValue::parse("bool:true").unwrap(), ParameterValue::Boolean(true));
    assert_eq!(ParameterValue::parse("bool:false").unwrap(), ParameterValue::Boolean(false));

    assert_eq!(ParameterValue::parse("text:foo").unwrap(), ParameterValue::Text("foo".to_string()));
    assert_eq!(ParameterValue::parse("foo").unwrap(), ParameterValue::Text("foo".to_string()));

    // Invalid parameters
    assert!(ParameterValue::parse("int:invalid").is_err());
    assert!(ParameterValue::parse("float:invalid").is_err());
    assert!(ParameterValue::parse("bool:invalid").is_err());
}

#[tokio::test]
async fn test_pool_connection_failures() {
    // Passing invalid URLs to verify connection error handling
    assert!(postgres_pool("postgres://invalid-host-name-12345.com").await.is_err());
    assert!(mysql_pool("mysql://invalid-host-name-12345.com").await.is_err());
    assert!(sqlite_pool("sqlite://invalid-sqlite-path/non-existent-dir/db.sqlite").await.is_err());
}

#[tokio::test]
async fn test_postgres_mysql_coverage_errors() {
    let pg_query = "SELECT name FROM users WHERE id = $1 AND name = $2";
    let pg_analysis = analyze_sql("test.sql", pg_query, DialectName::Postgres, None).unwrap();
    let mysql_query = "SELECT name FROM users WHERE id = ? AND name = ?";
    let mysql_analysis = analyze_sql("test.sql", mysql_query, DialectName::Mysql, None).unwrap();
    let params = vec![
        "int:1".to_string(),
        "text:foo".to_string(),
        "float:1.5".to_string(),
        "bool:true".to_string(),
        "null:text".to_string(),
        "null:int".to_string(),
        "null:float".to_string(),
        "null:bool".to_string(),
    ];

    let pg_pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect_lazy("postgres://127.0.0.1:9999/dummy")
        .unwrap();
    assert!(cover_postgres(&pg_pool, &pg_analysis, &params).await.is_err());

    let mysql_pool = sqlx::mysql::MySqlPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect_lazy("mysql://127.0.0.1:9999/dummy")
        .unwrap();
    assert!(cover_mysql(&mysql_pool, &mysql_analysis, &params).await.is_err());
}

#[tokio::test]
async fn test_schema_catalog_failures() {
    let pg_pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect_lazy("postgres://127.0.0.1:9999/dummy")
        .unwrap();
    assert!(SchemaCatalog::load_postgres(&pg_pool).await.is_err());

    let mysql_pool = sqlx::mysql::MySqlPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect_lazy("mysql://127.0.0.1:9999/dummy")
        .unwrap();
    assert!(SchemaCatalog::load_mysql(&mysql_pool).await.is_err());
}

#[test]
fn test_schema_catalog_helpers() {
    let catalog = SchemaCatalog::default();
    assert!(catalog.column("users", "name").is_none());

    assert_eq!(normalize_identifier("\"users\""), "users");
    assert_eq!(normalize_identifier("`users`"), "users");
    assert_eq!(normalize_identifier("[users]"), "users");
    assert_eq!(normalize_identifier("  Users  "), "users");
}

#[test]
fn test_dialect_name_parse() {
    assert_eq!(DialectName::parse("sqlite").unwrap(), DialectName::Sqlite);
    assert_eq!(DialectName::parse("sqlite3").unwrap(), DialectName::Sqlite);
    assert_eq!(DialectName::parse("postgres").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("postgresql").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("pg").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("mysql").unwrap(), DialectName::Mysql);
    assert_eq!(DialectName::parse("mariadb").unwrap(), DialectName::Mysql);
    assert_eq!(DialectName::parse("maria").unwrap(), DialectName::Mysql);

    assert!(DialectName::parse("invalid-dialect").is_err());
    assert_eq!(DialectName::Sqlite.as_str(), "sqlite");
    assert_eq!(DialectName::Postgres.as_str(), "postgres");
    assert_eq!(DialectName::Mysql.as_str(), "mysql");
}

#[test]
fn test_reporter_invalid_formats() {
    use sql_cov::model::{ExpressionSpan, CoverageMetric};
    use sql_cov::hazard::{HazardReport, HazardFinding};

    let dummy_span = ExpressionSpan {
        id: 1,
        start_offset: 0,
        end_offset: 8,
        start_line: 1,
        start_column: 1,
        end_line: 1,
        end_column: 9,
        raw_expression: "SELECT 1".to_string(),
        normalized_expression: "SELECT 1".to_string(),
        context: "SELECT".to_string(),
        nullable: true,
        parameter_indices: vec![],
    };

    let coverage = SourceFileCoverage {
        format: "sql-cov/json".to_string(),
        file_path: "test.sql".to_string(),
        dialect: "sqlite".to_string(),
        raw_source: "SELECT 1".to_string(),
        metrics: vec![
            CoverageMetric {
                span: dummy_span.clone(),
                measurable: false,
                hit_true_count: 0,
                hit_false_count: 0,
                hit_unknown_count: 0,
            },
            CoverageMetric {
                span: dummy_span.clone(),
                measurable: true,
                hit_true_count: 0,
                hit_false_count: 0,
                hit_unknown_count: 0,
            },
            CoverageMetric {
                span: dummy_span.clone(),
                measurable: true,
                hit_true_count: 1,
                hit_false_count: 1,
                hit_unknown_count: 1,
            },
            CoverageMetric {
                span: dummy_span.clone(),
                measurable: true,
                hit_true_count: 1,
                hit_false_count: 0,
                hit_unknown_count: 0,
            },
        ],
        statements: vec![],
        unsupported: vec!["Some unsupported feature".to_string()],
    };
    assert!(reporter::json(&coverage).is_ok());
    assert!(!reporter::lcov(&coverage).is_empty());
    assert!(!reporter::html(&coverage).is_empty());

    // Hazard reports and SARIF
    let dummy_hazard_span = sql_cov::hazard::HazardSpan {
        start_offset: 0,
        end_offset: 8,
        start_line: 1,
        start_column: 1,
        end_line: 1,
        end_column: 9,
        raw_expression: "SELECT 1".to_string(),
    };

    let hazard_report = HazardReport {
        format: "sql-cov/hazard/json".to_string(),
        file_path: "test.sql".to_string(),
        dialect: "sqlite".to_string(),
        findings: vec![
            HazardFinding {
                id: "test-id".to_string(),
                rule_id: "SQL001".to_string(),
                kind: sql_cov::HazardKind::NullableAnyAll,
                message: "Test finding".to_string(),
                evidence: vec!["test evidence".to_string()],
                recommendation: "Test recommendation".to_string(),
                span: dummy_hazard_span,
            }
        ],
        unresolved_schema_facts: vec!["unresolved fact".to_string()],
    };
    assert!(sql_cov::sarif::hazard_json(&hazard_report).is_ok());
    assert!(sql_cov::sarif::hazard_sarif(&hazard_report, None).is_ok());
}

#[test]
fn test_more_hazards_and_nullability() {
    use sql_cov::hazard::analyze_hazards;
    use sql_cov::schema::SchemaCatalog;

    let schema = SchemaCatalog::default();

    // 1. HAVING clause
    let query_having = "SELECT name FROM users GROUP BY name HAVING bonus <> 0";
    analyze_hazards("test.sql", query_having, DialectName::Sqlite, &schema).unwrap();

    // 2. Unresolved column
    let query_unresolved = "SELECT name FROM users WHERE non_existent_column <> 0";
    analyze_hazards("test.sql", query_unresolved, DialectName::Sqlite, &schema).unwrap();

    // 3. NOT IN UNNEST
    let query_unnest = "SELECT name FROM users WHERE age NOT IN (UNNEST(non_existent_column))";
    analyze_hazards("test.sql", query_unnest, DialectName::Sqlite, &schema).unwrap();

    // 4. Different Join variants
    let join_queries = vec![
        ("SELECT * FROM a LEFT JOIN b USING (id)", DialectName::Sqlite),
        ("SELECT * FROM a FULL OUTER JOIN b ON a.id = b.id", DialectName::Postgres),
        ("SELECT * FROM a CROSS JOIN b", DialectName::Sqlite),
        ("SELECT * FROM a INNER JOIN b ON a.id = b.id", DialectName::Sqlite),
        ("SELECT * FROM a STRAIGHT_JOIN b ON a.id = b.id", DialectName::Mysql),
    ];
    for (q, dialect) in join_queries {
        analyze_sql("test.sql", q, dialect, Some(&schema)).unwrap();
    }

    // Semi and Anti joins (try to parse, but don't panic if sqlparser dialect doesn't support them)
    let _ = analyze_sql("test.sql", "SELECT * FROM a LEFT SEMI JOIN b ON a.id = b.id", DialectName::Mysql, Some(&schema));
    let _ = analyze_sql("test.sql", "SELECT * FROM a ANTI JOIN b ON a.id = b.id", DialectName::Mysql, Some(&schema));

    // 5. COALESCE logic and advanced expressions
    let coalesce_queries = vec![
        "SELECT COALESCE(bonus)",
        "SELECT COALESCE(bonus, 0)",
        "SELECT COALESCE(non_existent_column, 0)",
        "SELECT name FROM users WHERE age IS TRUE AND age IS NOT TRUE AND age IS FALSE AND age IS NOT FALSE AND age IS UNKNOWN AND age IS NOT UNKNOWN",
        "SELECT name FROM users WHERE age IS DISTINCT FROM bonus AND age IS NOT DISTINCT FROM bonus",
        "SELECT name FROM users WHERE (CASE WHEN age > 18 THEN 1 ELSE 0 END) = 1",
        "SELECT name FROM users WHERE (CASE age WHEN 18 THEN 1 ELSE 0 END) = 1",
    ];
    for q in coalesce_queries {
        analyze_sql("test.sql", q, DialectName::Sqlite, Some(&schema)).unwrap();
    }
}

#[test]
fn test_sqlfluff_sarif_merging_and_tiering() {
    use sql_cov::sarif;

    use sql_cov::hazard::analyze_hazards;
    use sql_cov::schema::SchemaCatalog;

    let schema = SchemaCatalog {
        tables: std::collections::HashMap::new(),
    };
    let report = analyze_hazards(
        "test.sql",
        "SELECT * FROM users WHERE age IS NULL",
        DialectName::Sqlite,
        &schema,
    )
    .unwrap();

    // Mock a SQLFluff SARIF report
    let mock_sqlfluff_sarif = r#"{
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "SQLFluff",
              "rules": [
                {
                  "id": "AM05",
                  "name": "ambiguous.join",
                  "properties": {}
                },
                {
                  "id": "AM09",
                  "name": "ambiguous.order_by_limit",
                  "properties": {}
                },
                {
                  "id": "LT01",
                  "name": "layout.spacing",
                  "properties": {}
                }
              ]
            }
          },
          "results": [
            {
              "ruleId": "AM05",
              "message": { "text": "Implicit join used." },
              "properties": {}
            },
            {
              "ruleId": "AM09",
              "message": { "text": "LIMIT has no ORDER BY." },
              "properties": {}
            },
            {
              "ruleId": "LT01",
              "message": { "text": "Incorrect spacing." },
              "properties": {}
            }
          ]
        }
      ]
    }"#;

    let sarif_output = sarif::hazard_sarif(&report, Some(mock_sqlfluff_sarif)).unwrap();
    
    // Verify that the rules and results are successfully merged
    assert!(sarif_output.contains("AM05"));
    assert!(sarif_output.contains("AM09"));
    assert!(sarif_output.contains("LT01"));
    
    // Verify that the correct tiers are assigned
    assert!(sarif_output.contains(r#""tier": "T2""#)); // AM09 is an advisory ambiguity
    assert!(sarif_output.contains(r#""tier": "T3""#)); // AM05 and LT01 are style notes
    assert!(sarif_output.contains(r#""level": "warning""#));
    assert!(sarif_output.contains(r#""level": "note""#));
}

#[test]
fn test_generate_check_logic() {
    use sql_cov::hazard::analyze_hazards;
    use sql_cov::schema::SchemaCatalog;

    let mut schema = SchemaCatalog {
        tables: std::collections::HashMap::new(),
    };
    schema.insert_column("users".to_string(), "age".to_string(), true, false);

    let report = analyze_hazards(
        "test.sql",
        "SELECT * FROM users WHERE age != 18",
        DialectName::Sqlite,
        &schema,
    )
    .unwrap();

    assert_eq!(report.findings.len(), 1);
    let finding = &report.findings[0];
    
    // Check that we can extract the column from the evidence
    let mut matched_targets = Vec::new();
    for ev in &finding.evidence {
        if ev.starts_with("schema declares ") && ev.ends_with(" nullable") {
            let inner = &ev["schema declares ".len()..(ev.len() - " nullable".len())];
            if let Some(dot_idx) = inner.find('.') {
                let table = &inner[..dot_idx];
                let col = &inner[dot_idx + 1..];
                matched_targets.push((table.to_string(), col.to_string()));
            }
        }
    }
    
    assert_eq!(matched_targets.len(), 1);
    assert_eq!(matched_targets[0].0, "users");
    assert_eq!(matched_targets[0].1, "age");
}
