use sql_cov::driver::sqlite_pool;
use sql_cov::{analyze_sql, cover_sqlite, execute_sqlite_setup, DialectName};

const OWNER_INVENTORY: &str = include_str!("../../lineage/sql/architecture/owner_inventory.sql");
const SETUP: &str = include_str!("fixtures/lineage_architecture.sql");

#[tokio::test]
async fn measures_real_lineage_owner_inventory_where_clause() {
    let analysis = analyze_sql(
        "gems/lineage/sql/architecture/owner_inventory.sql",
        OWNER_INVENTORY,
        DialectName::Sqlite,
    )
    .unwrap();
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(&pool, SETUP).await.unwrap();
    let coverage = cover_sqlite(&pool, &analysis, &["1".into(), "owner:1".into()])
        .await
        .unwrap();

    assert_eq!(coverage.metrics.len(), 7);
    assert_eq!(
        coverage
            .metrics
            .iter()
            .filter(|metric| metric.measurable)
            .count(),
        3
    );
    assert_eq!(
        (
            coverage.metrics[0].hit_true_count,
            coverage.metrics[0].hit_false_count,
            coverage.metrics[0].hit_unknown_count,
        ),
        (1, 2, 2)
    );
    assert_eq!(coverage.covered_branches(), 8);
    assert_eq!(coverage.total_branches(), 9);
    assert!(!coverage.metrics[1].is_fully_covered());
}

#[test]
fn all_migrated_lineage_architecture_queries_parse() {
    let queries = [
        (
            "delete_snapshot",
            include_str!("../../lineage/sql/architecture/delete_snapshot.sql"),
        ),
        (
            "insert_artifact",
            include_str!("../../lineage/sql/architecture/insert_artifact.sql"),
        ),
        (
            "insert_node",
            include_str!("../../lineage/sql/architecture/insert_node.sql"),
        ),
        (
            "insert_edge",
            include_str!("../../lineage/sql/architecture/insert_edge.sql"),
        ),
        (
            "insert_edge_span",
            include_str!("../../lineage/sql/architecture/insert_edge_span.sql"),
        ),
        (
            "insert_pressure",
            include_str!("../../lineage/sql/architecture/insert_pressure.sql"),
        ),
        (
            "reconcile",
            include_str!("../../lineage/sql/architecture/reconcile_logical_unit.sql"),
        ),
        (
            "search",
            include_str!("../../lineage/sql/architecture/search.sql"),
        ),
        (
            "latest",
            include_str!("../../lineage/sql/architecture/latest_artifact.sql"),
        ),
        (
            "health",
            include_str!("../../lineage/sql/architecture/artifact_health.sql"),
        ),
        (
            "load_node",
            include_str!("../../lineage/sql/architecture/load_node.sql"),
        ),
        ("owner_inventory", OWNER_INVENTORY),
        (
            "load_edges",
            include_str!("../../lineage/sql/architecture/load_edges.sql"),
        ),
        (
            "ui_symbols",
            include_str!("../../lineage/sql/ui/architecture_symbols_for_path.sql"),
        ),
        (
            "ui_owner",
            include_str!("../../lineage/sql/ui/architecture_owner_by_name.sql"),
        ),
    ];
    for (name, sql) in queries {
        analyze_sql(name, sql, DialectName::Sqlite)
            .unwrap_or_else(|error| panic!("SQL-COV could not parse {name}: {error}"));
    }
}

#[tokio::test]
async fn every_migrated_lineage_sql_file_executes_as_statement_coverage() {
    let queries: [(&str, &str, &[&str]); 15] = [
        (
            "artifact_health",
            include_str!("../../lineage/sql/architecture/artifact_health.sql"),
            &["int:1"],
        ),
        (
            "delete_snapshot",
            include_str!("../../lineage/sql/architecture/delete_snapshot.sql"),
            &["text:espalier", "text:missing"],
        ),
        (
            "insert_artifact",
            include_str!("../../lineage/sql/architecture/insert_artifact.sql"),
            &[
                "text:new", "text:1", "int:1", "text:new", "text:.", "int:1", "text:now", "text:{}",
            ],
        ),
        (
            "insert_edge",
            include_str!("../../lineage/sql/architecture/insert_edge.sql"),
            &[
                "int:1",
                "text:edge:new",
                "text:fn:match",
                "text:fn:other",
                "text:calls",
                "int:0",
                "int:1",
                "text:high",
                "text:{}",
            ],
        ),
        (
            "insert_edge_span",
            include_str!("../../lineage/sql/architecture/insert_edge_span.sql"),
            &[
                "int:1",
                "text:edge:new",
                "text:demo.rb",
                "int:1",
                "int:0",
                "int:1",
                "int:3",
            ],
        ),
        (
            "insert_node",
            include_str!("../../lineage/sql/architecture/insert_node.sql"),
            &[
                "int:1",
                "text:fn:new",
                "null:text",
                "text:owner:1",
                "text:function",
                "text:new",
                "text:Demo",
                "text:ruby",
                "text:demo.rb",
                "int:3",
                "int:0",
                "int:4",
                "int:3",
                "text:high",
                "text:{}",
            ],
        ),
        (
            "insert_pressure",
            include_str!("../../lineage/sql/architecture/insert_pressure.sql"),
            &[
                "int:1",
                "text:fn:new",
                "float:1.5",
                "text:green",
                "float:0",
                "float:0",
                "float:0",
                "float:0",
                "text:{}",
            ],
        ),
        (
            "latest_artifact",
            include_str!("../../lineage/sql/architecture/latest_artifact.sql"),
            &[],
        ),
        (
            "load_edges",
            include_str!("../../lineage/sql/architecture/load_edges.sql"),
            &["int:1", "text:fn:match"],
        ),
        (
            "load_node",
            include_str!("../../lineage/sql/architecture/load_node.sql"),
            &["int:1", "text:fn:match"],
        ),
        (
            "owner_inventory",
            OWNER_INVENTORY,
            &["int:1", "text:owner:1"],
        ),
        (
            "reconcile",
            include_str!("../../lineage/sql/architecture/reconcile_logical_unit.sql"),
            &[
                "text:demo.rb",
                "text:match",
                "text:%match",
                "text:function",
                "text:method",
                "int:2",
            ],
        ),
        (
            "search",
            include_str!("../../lineage/sql/architecture/search.sql"),
            &["int:1", "text:%match%", "null:text"],
        ),
        (
            "ui_symbols",
            include_str!("../../lineage/sql/ui/architecture_symbols_for_path.sql"),
            &["text:demo.rb"],
        ),
        (
            "ui_owner",
            include_str!("../../lineage/sql/ui/architecture_owner_by_name.sql"),
            &["text:demo.rb", "text:Demo", "text:%Demo"],
        ),
    ];
    for (name, sql, parameters) in queries {
        let analysis = analyze_sql(name, sql, DialectName::Sqlite).unwrap();
        let pool = sqlite_pool("sqlite::memory:").await.unwrap();
        execute_sqlite_setup(&pool, SETUP).await.unwrap();
        let parameters = parameters
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>();
        let coverage = cover_sqlite(&pool, &analysis, &parameters)
            .await
            .unwrap_or_else(|error| panic!("{name} did not execute: {error:#}"));
        assert_eq!(coverage.statements.len(), 1, "{name}");
        assert_eq!(coverage.statements[0].hit_count, 1, "{name}");
    }
}
