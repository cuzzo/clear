use sql_cov::driver::{mysql_pool, postgres_pool};
use sql_cov::schema::SchemaCatalog;
use sql_cov::{
    analyze_hazards, analyze_sql, cover_mysql, cover_postgres, execute_mysql_setup,
    execute_postgres_setup, DialectName, HazardKind,
};

#[tokio::test]
async fn postgres_live_schema_coverage_and_any_all_hazard() {
    let Ok(url) = std::env::var("SQL_COV_POSTGRES_URL") else {
        return;
    };
    let pool = postgres_pool(&url).await.unwrap();
    execute_postgres_setup(
        &pool,
        "DROP TABLE IF EXISTS sql_cov_rhs; DROP TABLE IF EXISTS sql_cov_users;\
         CREATE TABLE sql_cov_users(name TEXT NOT NULL, bonus BIGINT, age BIGINT NOT NULL);\
         CREATE TABLE sql_cov_rhs(value BIGINT);\
         INSERT INTO sql_cov_users VALUES ('a', 5, 30), ('b', 0, 10), ('c', NULL, 20);\
         INSERT INTO sql_cov_rhs VALUES (30), (NULL);",
    )
    .await
    .unwrap();
    let schema = SchemaCatalog::load_postgres(&pool).await.unwrap();
    assert!(schema.column("sql_cov_users", "bonus").unwrap().nullable);
    assert!(!schema.column("sql_cov_users", "age").unwrap().nullable);

    let query = "SELECT name FROM sql_cov_users WHERE bonus <> 0 AND age > 18";
    let analysis = analyze_sql("postgres.sql", query, DialectName::Postgres, Some(&schema)).unwrap();
    let coverage = cover_postgres(&pool, &analysis, &[]).await.unwrap();
    assert_eq!(coverage.statements[0].hit_count, 1);
    assert!(coverage
        .metrics
        .iter()
        .all(
            |metric| metric.hit_true_count + metric.hit_false_count + metric.hit_unknown_count == 3
        ));

    let quantified =
        "SELECT name FROM sql_cov_users WHERE age = ALL (SELECT value FROM sql_cov_rhs)";
    let report =
        analyze_hazards("postgres.sql", quantified, DialectName::Postgres, &schema).unwrap();
    assert!(report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableAnyAll));
}

#[tokio::test]
async fn mysql_or_mariadb_live_schema_coverage_and_any_all_hazard() {
    let url = std::env::var("SQL_COV_MYSQL_URL").or_else(|_| std::env::var("SQL_COV_MARIADB_URL"));
    let Ok(url) = url else { return };
    let pool = mysql_pool(&url).await.unwrap();
    execute_mysql_setup(
        &pool,
        "DROP TABLE IF EXISTS sql_cov_rhs; DROP TABLE IF EXISTS sql_cov_users;\
         CREATE TABLE sql_cov_users(name TEXT NOT NULL, bonus BIGINT NULL, age BIGINT NOT NULL);\
         CREATE TABLE sql_cov_rhs(value BIGINT NULL);\
         INSERT INTO sql_cov_users VALUES ('a', 5, 30), ('b', 0, 10), ('c', NULL, 20);\
         INSERT INTO sql_cov_rhs VALUES (30), (NULL);",
    )
    .await
    .unwrap();
    let schema = SchemaCatalog::load_mysql(&pool).await.unwrap();
    assert!(schema.column("sql_cov_users", "bonus").unwrap().nullable);
    assert!(!schema.column("sql_cov_users", "age").unwrap().nullable);

    let query = "SELECT name FROM sql_cov_users WHERE bonus <> 0 AND age > ?";
    let analysis = analyze_sql("mysql.sql", query, DialectName::Mysql, Some(&schema)).unwrap();
    let coverage = cover_mysql(&pool, &analysis, &["int:18".to_string()])
        .await
        .unwrap();
    assert_eq!(coverage.statements[0].hit_count, 1);
    assert!(coverage
        .metrics
        .iter()
        .all(
            |metric| metric.hit_true_count + metric.hit_false_count + metric.hit_unknown_count == 3
        ));

    let quantified =
        "SELECT name FROM sql_cov_users WHERE age = ALL (SELECT value FROM sql_cov_rhs)";
    let report = analyze_hazards("mysql.sql", quantified, DialectName::Mysql, &schema).unwrap();
    assert!(report
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableAnyAll));
}
