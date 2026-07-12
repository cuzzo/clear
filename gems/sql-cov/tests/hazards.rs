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

#[tokio::test]
async fn test_looker_join_malformed_lookml_and_uncovered_branches() {
    use sql_cov::{analyze_hazards_with_looker, parse_lookml, LookerJoin};
    use sql_cov::schema::SchemaCatalog;

    // 1. parse malformed lookml to hit parsing fallbacks
    let malformed_lookml = r#"
explore: companies {
  join: employees {
    relationship: one_to_many
    sql_on: ${companies.company_id = employees.company_id ;;
  }
}
explore: companies2 {
  join: employees2 {
    relationship: one_to_many
    sql_on: companies.company_id = employees.company_id ;;
  }
}
"#;
    let malformed_joins = parse_lookml(malformed_lookml);
    assert_eq!(malformed_joins.len(), 2);
    assert_eq!(malformed_joins[0].primary_key, ""); // Hits the unclosed ${ branch

    // 2. set up schema with aliases and derived tables to hit resolves_to_table aliases
    let mut mock_schema = SchemaCatalog::default();
    mock_schema.insert_column("companies".to_string(), "company_id".to_string(), false, true);
    mock_schema.insert_column("companies".to_string(), "annual_revenue".to_string(), false, false);
    mock_schema.insert_column("employees".to_string(), "company_id".to_string(), false, false);

    let lookml = r#"
explore: companies {
  join: employees {
    relationship: one_to_many
    sql_on: ${companies.company_id} = ${employees.company_id} ;;
  }
}
"#;
    let joins = parse_lookml(lookml);

    // Test alias table resolving: FROM companies c JOIN employees e ON c.company_id = e.company_id
    // And projection alias: SELECT SUM(c.annual_revenue) AS revenue
    let sql = "SELECT SUM(c.annual_revenue) AS revenue FROM companies c JOIN employees e ON c.company_id = e.company_id";
    let report = analyze_hazards_with_looker("test.sql", sql, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test joining right side PK: FROM employees JOIN companies ON employees.company_id = companies.company_id
    let sql_right_pk = "SELECT SUM(companies.annual_revenue) FROM employees JOIN companies ON employees.company_id = companies.company_id";
    let report_right_pk = analyze_hazards_with_looker("test.sql", sql_right_pk, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_right_pk.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test unqualified identifier in projection: SELECT SUM(annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id
    let sql_unqualified = "SELECT SUM(annual_revenue) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_unqualified = analyze_hazards_with_looker("test.sql", sql_unqualified, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_unqualified.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test duplicate joins for dedup_by
    let duplicate_joins = vec![joins[0].clone(), joins[0].clone()];
    let report_dedup = analyze_hazards_with_looker("test.sql", sql, DialectName::Sqlite, &mock_schema, &duplicate_joins).unwrap();
    assert!(report_dedup.findings.len() > 0);

    // Test aggregate binary expression shallow match: SUM(companies.annual_revenue + 1)
    let sql_agg_bin = "SELECT SUM(companies.annual_revenue + 1) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_agg_bin = analyze_hazards_with_looker("test.sql", sql_agg_bin, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_agg_bin.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test unqualified aggregate binary expression: SUM(annual_revenue + 1)
    let sql_agg_bin_unq = "SELECT SUM(annual_revenue + 1) FROM companies JOIN employees ON companies.company_id = employees.company_id";
    let report_agg_bin_unq = analyze_hazards_with_looker("test.sql", sql_agg_bin_unq, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_agg_bin_unq.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test derived table: FROM (SELECT * FROM companies) AS companies
    let sql_derived = "SELECT SUM(companies.annual_revenue) FROM (SELECT * FROM companies) AS companies JOIN employees ON companies.company_id = employees.company_id";
    let report_derived = analyze_hazards_with_looker("test.sql", sql_derived, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_derived.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Test wildcard projection, COUNT/AVG, compound identifier with alias in binary expression, and EQ visitor right operand is None
    let sql_comprehensive = "SELECT *, COUNT(c.annual_revenue), AVG(c.annual_revenue + 1), SUM(age + 1), SUM(e.company_id + 1) FROM companies c JOIN employees e ON c.company_id = e.company_id AND c.company_id = 5";
    let report_comprehensive = analyze_hazards_with_looker("test.sql", sql_comprehensive, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_comprehensive.findings.iter().any(|f| f.kind == HazardKind::LookerJoinHazard));

    // Insert departments to schema
    mock_schema.insert_column("departments".to_string(), "dept_id".to_string(), false, true);
    mock_schema.insert_column("departments".to_string(), "company_id".to_string(), false, false);

    // Test unqualified columns in JOIN condition: ON company_id = e.company_id
    let sql_unqualified_join = "SELECT *, COUNT(c.annual_revenue) FROM companies c JOIN employees e ON company_id = e.company_id";
    let report_unq_join = analyze_hazards_with_looker("test.sql", sql_unqualified_join, DialectName::Sqlite, &mock_schema, &joins).unwrap();
    assert!(report_unq_join.findings.len() > 0);

    // Test table prefix not in resolver aliases but in schema tables: e.company_id = companies.company_id where companies is not in FROM
    let sql_no_alias_prefix = "SELECT * FROM employees e JOIN departments d ON e.company_id = companies.company_id";
    let _ = analyze_hazards_with_looker("test.sql", sql_no_alias_prefix, DialectName::Sqlite, &mock_schema, &joins).unwrap();

    // Test non-existent unqualified column in JOIN condition (get_table_and_column None for Identifier)
    let sql_non_existent_unqualified = "SELECT * FROM companies c JOIN employees e ON non_existent_column = e.company_id";
    let _ = analyze_hazards_with_looker("test.sql", sql_non_existent_unqualified, DialectName::Sqlite, &mock_schema, &joins).unwrap();

    // Test non-existent compound identifier prefix in JOIN condition (get_table_and_column None for CompoundIdentifier)
    let sql_non_existent_prefix = "SELECT * FROM companies c JOIN employees e ON non_existent_table.some_col = e.company_id";
    let _ = analyze_hazards_with_looker("test.sql", sql_non_existent_prefix, DialectName::Sqlite, &mock_schema, &joins).unwrap();
}

