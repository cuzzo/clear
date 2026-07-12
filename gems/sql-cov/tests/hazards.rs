use sql_cov::driver::sqlite_pool;
use sql_cov::sarif;
use sql_cov::schema::SchemaCatalog;
use sql_cov::{analyze_hazards, execute_sqlite_setup, DialectName, HazardKind};

const SCHEMA: &str = include_str!("fixtures/hazards.sql");

async fn schema() -> SchemaCatalog {
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(&pool, SCHEMA).await.unwrap();
    SchemaCatalog::load_sqlite(&pool).await.unwrap()
}

#[tokio::test]
async fn sqlite_schema_distinguishes_nullable_and_required_columns() {
    let schema = schema().await;
    assert!(schema.column("users", "bonus").unwrap().nullable);
    assert!(!schema.column("users", "age").unwrap().nullable);
    assert!(!schema.column("users", "id").unwrap().nullable);
}

#[tokio::test]
async fn only_schema_proven_unknown_traps_become_findings() {
    let schema = schema().await;
    let sql = r#"
SELECT name FROM users WHERE bonus != 0;
SELECT name FROM users WHERE age != 0;
SELECT name FROM users WHERE bonus NOT IN (0, 1);
SELECT name FROM users WHERE age NOT IN (0, 1, NULL);
SELECT name FROM users WHERE bonus NOT BETWEEN 1 AND 5;
SELECT name FROM users WHERE NOT (bonus = 0);
"#;
    let report = analyze_hazards("hazards.sql", sql, DialectName::Sqlite, &schema).unwrap();
    let kinds = report
        .findings
        .iter()
        .map(|finding| finding.kind)
        .collect::<Vec<_>>();
    assert_eq!(
        kinds,
        vec![
            HazardKind::NullableNotEqual,
            HazardKind::NullableNotIn,
            HazardKind::NullableNotIn,
            HazardKind::NullableNotBetween,
            HazardKind::NullableNot,
        ]
    );
    assert!(!report
        .findings
        .iter()
        .any(|finding| finding.span.raw_expression.contains("age != 0")));
}

#[tokio::test]
async fn outer_join_filter_and_nullable_join_key_are_distinct_hazards() {
    let schema = schema().await;
    let sql = r#"SELECT u.name
FROM users u
LEFT JOIN subscriptions s ON u.bonus = s.user_id
WHERE s.status = 'active';"#;
    let report = analyze_hazards("outer_join.sql", sql, DialectName::Sqlite, &schema).unwrap();
    assert!(report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableJoinKey));
    assert!(report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::OuterJoinNullRejection));

    let sarif = sarif::hazard_sarif(&report, None).unwrap();
    assert!(sarif.contains("\"version\": \"2.1.0\""));
    assert!(sarif.contains("\"schemaValidated\": true"));
    assert!(sarif.contains("SQL006"));
    assert!(sarif.contains("SQL007"));
}

#[tokio::test]
async fn explicit_outer_join_null_policy_suppresses_rejection_warning() {
    let schema = schema().await;
    let sql = r#"SELECT u.name
FROM users u
LEFT JOIN subscriptions s ON u.id = s.user_id
WHERE s.status = 'active' OR s.status IS NULL;"#;
    let report = analyze_hazards("outer_join.sql", sql, DialectName::Sqlite, &schema).unwrap();
    assert!(!report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::OuterJoinNullRejection));
}

#[tokio::test]
async fn coalesce_with_non_null_fallback_suppresses_outer_join_rejection() {
    let schema = schema().await;
    let sql = r#"SELECT u.name
FROM users u
LEFT JOIN subscriptions s ON u.id = s.user_id
WHERE COALESCE(s.status, 'missing') = 'active';"#;
    let report = analyze_hazards("outer_join.sql", sql, DialectName::Sqlite, &schema).unwrap();
    assert!(!report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::OuterJoinNullRejection));
}

#[tokio::test]
async fn nullable_subquery_output_and_postgres_all_are_detected() {
    let schema = schema().await;
    let not_in = analyze_hazards(
        "not_in.sql",
        "SELECT name FROM users WHERE age NOT IN (SELECT bonus FROM users);",
        DialectName::Sqlite,
        &schema,
    )
    .unwrap();
    assert!(not_in
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableNotIn));

    let all = analyze_hazards(
        "all.sql",
        "SELECT name FROM users WHERE bonus = ALL (ARRAY[1, 2, NULL]);",
        DialectName::Postgres,
        &schema,
    )
    .unwrap();
    assert!(all
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableAnyAll));
}

#[tokio::test]
async fn test_looker_join_hazard_detection() {
    use sql_cov::{analyze_hazards_with_looker, parse_lookml, LookerJoin};
    let schema = schema().await;
    
    let lookml = r#"
explore: companies {
  join: employees {
    relationship: one_to_many
    sql_on: ${companies.company_id} = ${employees.company_id} ;;
  }
}
"#;
    let joins = parse_lookml(lookml);
    assert_eq!(joins.len(), 1);
    assert_eq!(joins[0].explore, "companies");
    assert_eq!(joins[0].join_table, "employees");
    assert_eq!(joins[0].relationship, "one_to_many");

    // Let's mock companies and employees in SchemaCatalog
    let mut mock_schema = SchemaCatalog::default();
    mock_schema.insert_column("companies".to_string(), "company_id".to_string(), false, true);
    mock_schema.insert_column("companies".to_string(), "annual_revenue".to_string(), false, false);
    mock_schema.insert_column("employees".to_string(), "company_id".to_string(), false, true);

    // Hazard query: joining companies and employees, aggregating annual_revenue (from one-side) without DISTINCT
    let sql_hazard = "SELECT SUM(companies.annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_hazard = analyze_hazards_with_looker("test.sql", sql_hazard, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_hazard.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Safe query: uses DISTINCT modifier on the aggregation
    let sql_safe = "SELECT SUM(DISTINCT companies.annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_safe = analyze_hazards_with_looker("test.sql", sql_safe, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(!report_safe.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));
}

#[tokio::test]
async fn test_schema_inferred_join_hazard_detection() {
    use sql_cov::analyze_hazards_with_looker;
    
    // Set up schema: companies (company_id is primary key), employees (company_id is NOT primary key)
    let mut mock_schema = SchemaCatalog::default();
    mock_schema.insert_column("companies".to_string(), "company_id".to_string(), false, true); // true = primary key
    mock_schema.insert_column("companies".to_string(), "annual_revenue".to_string(), false, false);
    mock_schema.insert_column("employees".to_string(), "company_id".to_string(), false, false); // false = not primary key

    // Run hazard check with empty LookML rules
    let sql_hazard = "SELECT SUM(companies.annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report = analyze_hazards_with_looker("test.sql", sql_hazard, DialectName::Sqlite, &mock_schema, &[]).unwrap();
    
    let finding = report.findings.iter().find(|f| f.rule_id == "SCHEMA_JOIN_HAZARD");
    assert!(finding.is_some());
    assert_eq!(finding.unwrap().kind, HazardKind::LookerJoinHazard);

    // Verify DISTINCT modifier prevents the schema-inferred hazard
    let sql_safe = "SELECT SUM(DISTINCT companies.annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_safe = analyze_hazards_with_looker("test.sql", sql_safe, DialectName::Sqlite, &mock_schema, &[]).unwrap();
    assert!(!report_safe.findings.iter().any(|f| f.rule_id == "SCHEMA_JOIN_HAZARD"));
}

#[tokio::test]
async fn test_cte_is_not_null_propagation() {
    use sql_cov::analyze_hazards;
    let mut schema = SchemaCatalog::default();
    schema.insert_column("test_exposure_events".to_string(), "line".to_string(), true, false);
    schema.insert_column("active_hazards".to_string(), "line".to_string(), true, false);
    schema.insert_column("active_hazards".to_string(), "unit_id".to_string(), true, false);
    schema.insert_column("test_exposure_events".to_string(), "unit_id".to_string(), true, false);
    schema.insert_column("active_hazards".to_string(), "path".to_string(), true, false);
    schema.insert_column("test_exposure_events".to_string(), "path".to_string(), true, false);

    let sql = r#"
        WITH active_hazards AS (
            SELECT * FROM unit_hazards
        ),
        ranked_exposure AS (
            SELECT t.line
            FROM test_exposure_events t
            JOIN active_hazards h
              ON h.unit_id = t.unit_id
             AND h.path = t.path
             AND h.line = t.line
            WHERE t.line IS NOT NULL
        )
        SELECT * FROM ranked_exposure;
    "#;
    let report = analyze_hazards("test.sql", sql, DialectName::Sqlite, &schema).unwrap();
    // Check if there are any NullableJoinKey findings for t.line
    let has_finding_for_t_line = report.findings.iter().any(|f| {
        f.kind == sql_cov::HazardKind::NullableJoinKey && f.span.raw_expression.contains("h.line = t.line")
    });
    assert!(!has_finding_for_t_line);
}
