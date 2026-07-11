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
LEFT JOIN subscriptions s ON u.id = s.user_id
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

    let sarif = sarif::hazard_sarif(&report).unwrap();
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
