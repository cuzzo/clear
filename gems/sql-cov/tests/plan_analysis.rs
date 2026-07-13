use serde_json::json;
use sql_cov::driver::sqlite_pool;
use sql_cov::plan::{
    analyze_mysql_plan, analyze_postgres_plan, collect_sql_files, explain_sqlite, plan_sarif,
    query_id, Growth, QueryPlanObservation,
};
use sql_cov::{execute_sqlite_setup, DialectName};
use std::fs;

#[tokio::test]
async fn sqlite_explain_uses_real_parameters_and_reports_index_and_sort_costs() {
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(
        &pool,
        "CREATE TABLE users(id INTEGER PRIMARY KEY, team_id INTEGER, name TEXT);\
         CREATE INDEX users_team ON users(team_id);\
         INSERT INTO users(team_id, name) VALUES (1, 'b'), (1, 'a'), (2, 'c');",
    )
    .await
    .unwrap();

    let (complexity, explain) = explain_sqlite(
        &pool,
        "SELECT name FROM users WHERE team_id = ? ORDER BY name",
        &["int:1".to_string()],
    )
    .await
    .unwrap();

    assert!(explain.contains("SEARCH users USING INDEX users_team"));
    assert!(explain.contains("USE TEMP B-TREE FOR ORDER BY"));
    assert_eq!(complexity.time, Growth::Linearithmic);
    assert_eq!(complexity.auxiliary_space, Growth::Linear);
    assert!(complexity
        .warnings
        .iter()
        .any(|warning| warning.rule_id == "SQL_NON_COVERING_INDEX"));
    assert!(complexity
        .warnings
        .iter()
        .any(|warning| warning.rule_id == "SQL_SORT"));
}

#[test]
fn recursive_collection_and_query_ids_are_deterministic() {
    let directory = tempfile::tempdir().unwrap();
    fs::create_dir(directory.path().join("nested")).unwrap();
    fs::write(directory.path().join("z.sql"), "SELECT 1").unwrap();
    fs::write(
        directory.path().join("nested/a.SQL"),
        "-- query-id: users.by_id.v1\nSELECT 1",
    )
    .unwrap();
    fs::write(directory.path().join("ignored.txt"), "SELECT 1").unwrap();

    let files = collect_sql_files(directory.path()).unwrap();
    assert_eq!(files.len(), 2);
    let source = fs::read_to_string(&files[0]).unwrap();
    assert_eq!(query_id(&files[0], &source), "users.by_id.v1");
}

#[test]
fn malformed_postgres_plan_is_rejected_and_unknown_mysql_access_is_preserved() {
    assert!(analyze_postgres_plan(&json!({"not_a_plan": {}})).is_err());
    let mysql = analyze_mysql_plan(&json!({
        "query_block": {"table": {"table_name": "derived", "access_type": "mystery"}}
    }))
    .unwrap();
    assert_eq!(mysql.time, Growth::Unknown);
}

#[test]
fn canonical_sarif_serializes_multiple_dialects_without_provider_specific_shape() {
    let observations = [
        DialectName::Sqlite,
        DialectName::Postgres,
        DialectName::Mysql,
    ]
    .into_iter()
    .map(|dialect| QueryPlanObservation {
        path: format!("queries/{}.sql", dialect.as_str()),
        query_id: format!("{}.query", dialect.as_str()),
        dialect,
        complexity: Default::default(),
        explain: "{}".to_string(),
    })
    .collect::<Vec<_>>();
    let document: serde_json::Value =
        serde_json::from_str(&plan_sarif(&observations).unwrap()).unwrap();
    let summaries = document["runs"][0]["results"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|result| result["ruleId"] == "complexity.observation")
        .collect::<Vec<_>>();
    assert_eq!(summaries.len(), 3);
    assert_eq!(
        summaries[1]["properties"]["complexity"]["dialect"],
        "postgres"
    );
}
