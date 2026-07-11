use sql_cov::instrument::telemetry_queries;
use sql_cov::schema::SchemaCatalog;
use sql_cov::{analyze_hazards, analyze_sql, DialectName, HazardKind};

async fn schema() -> SchemaCatalog {
    let pool = sql_cov::driver::sqlite_pool("sqlite::memory:")
        .await
        .unwrap();
    sql_cov::execute_sqlite_setup(
        &pool,
        "CREATE TABLE users(name TEXT NOT NULL, bonus INTEGER, age INTEGER NOT NULL);",
    )
    .await
    .unwrap();
    SchemaCatalog::load_sqlite(&pool).await.unwrap()
}

#[tokio::test]
async fn mysql_and_mariadb_any_all_cover_all_comparison_operators() {
    let schema = schema().await;
    for quantifier in ["ANY", "SOME", "ALL"] {
        for operator in ["=", "<>", "!=", "<", "<=", ">", ">="] {
            let nullable = format!(
                "SELECT name FROM users WHERE age {operator} {quantifier} (SELECT bonus FROM users)"
            );
            let report = analyze_hazards("mysql.sql", &nullable, DialectName::Mysql, &schema)
                .unwrap_or_else(|error| panic!("failed to parse {nullable}: {error}"));
            assert!(report
                .findings
                .iter()
                .any(|finding| finding.kind == HazardKind::NullableAnyAll));

            let required = format!(
                "SELECT name FROM users WHERE age {operator} {quantifier} (SELECT age FROM users)"
            );
            let report = analyze_hazards("mysql.sql", &required, DialectName::Mysql, &schema)
                .unwrap_or_else(|error| panic!("failed to parse {required}: {error}"));
            assert!(!report
                .findings
                .iter()
                .any(|finding| finding.kind == HazardKind::NullableAnyAll));
        }
    }
}

#[test]
fn mysql_anonymous_parameters_are_rebound_for_each_instrumented_expression() {
    let sql = "SELECT name FROM users WHERE bonus <> ? AND age > ?";
    let analysis = analyze_sql("mysql.sql", sql, DialectName::Mysql, None).unwrap();
    let queries = telemetry_queries(&analysis);
    assert_eq!(queries.len(), 1);
    assert_eq!(queries[0].parameter_indices, vec![0, 1, 0, 1]);
    assert_eq!(queries[0].sql.matches('?').count(), 4);
    assert_eq!(queries[0].sql.matches("bonus <> ?").count(), 2);
    assert_eq!(queries[0].sql.matches("age > ?").count(), 2);
}

#[test]
fn dialect_aliases_select_the_expected_frontend() {
    assert_eq!(
        DialectName::parse("postgresql").unwrap(),
        DialectName::Postgres
    );
    assert_eq!(DialectName::parse("mysql").unwrap(), DialectName::Mysql);
    assert_eq!(DialectName::parse("mariadb").unwrap(), DialectName::Mysql);
}
