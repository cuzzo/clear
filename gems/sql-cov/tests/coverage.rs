use sql_cov::driver::sqlite_pool;
use sql_cov::reporter;
use sql_cov::{analyze_sql, cover_sqlite, execute_sqlite_setup, DialectName};

const QUERY: &str = include_str!("fixtures/users_query.sql");
const SETUP: &str = include_str!("fixtures/users.sql");

#[test]
fn parser_maps_nested_boolean_spans_to_source() {
    let analysis = analyze_sql("users_query.sql", QUERY, DialectName::Sqlite, None).unwrap();
    let expressions = analysis
        .coverage
        .metrics
        .iter()
        .map(|metric| metric.span.raw_expression.trim().to_string())
        .collect::<Vec<_>>();
    assert_eq!(
        expressions,
        vec!["bonus != 0 AND age > 18", "bonus != 0", "age > 18"]
    );
    assert!(analysis
        .coverage
        .metrics
        .iter()
        .all(|metric| metric.span.start_line == 3));
}

#[tokio::test]
async fn sqlite_driver_captures_true_false_and_unknown() {
    let analysis = analyze_sql("users_query.sql", QUERY, DialectName::Sqlite, None).unwrap();
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(&pool, SETUP).await.unwrap();
    let coverage = cover_sqlite(&pool, &analysis, &[]).await.unwrap();

    assert_eq!(coverage.statements.len(), 1);
    assert_eq!(coverage.statements[0].hit_count, 1);
    assert_eq!(
        (
            coverage.statements[0].start_line,
            coverage.statements[0].end_line
        ),
        (1, 3)
    );

    let top = &coverage.metrics[0];
    assert_eq!(
        (
            top.hit_true_count,
            top.hit_false_count,
            top.hit_unknown_count
        ),
        (1, 2, 1)
    );
    let bonus = &coverage.metrics[1];
    assert_eq!(
        (
            bonus.hit_true_count,
            bonus.hit_false_count,
            bonus.hit_unknown_count
        ),
        (2, 1, 1)
    );
    let age = &coverage.metrics[2];
    assert_eq!(
        (
            age.hit_true_count,
            age.hit_false_count,
            age.hit_unknown_count
        ),
        (2, 1, 1)
    );
    assert_eq!(coverage.covered_branches(), coverage.total_branches());

    let lcov = reporter::lcov(&coverage);
    assert!(lcov.contains("BRF:9"));
    assert!(lcov.contains("BRH:9"));
    assert!(lcov.contains("DA:1,1"));
    assert!(lcov.contains("DA:2,1"));
    assert!(lcov.contains("DA:3,1"));
    assert!(lcov.contains("end_of_record"));
    let html = reporter::html(&coverage);
    assert!(html.contains("SQL expression coverage"));
    assert!(html.contains("9/9 branches"));
    assert!(html.contains("<mark class=\"covered\">"));
}

#[tokio::test]
async fn reports_partial_branch_coverage() {
    let analysis = analyze_sql("users_query.sql", QUERY, DialectName::Sqlite, None).unwrap();
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(
        &pool,
        "CREATE TABLE users(name TEXT, bonus INTEGER, age INTEGER); INSERT INTO users VALUES ('Alice', 5, 30);",
    )
    .await
    .unwrap();
    let coverage = cover_sqlite(&pool, &analysis, &[]).await.unwrap();
    assert_eq!(coverage.covered_branches(), 3);
    assert_eq!(coverage.total_branches(), 9);
    assert!(coverage
        .metrics
        .iter()
        .all(|metric| !metric.is_fully_covered()));
    assert!(reporter::html(&coverage).contains("class=\"partial\""));
}
