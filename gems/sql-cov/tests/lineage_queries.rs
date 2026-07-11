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
        (1, 2, 1)
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
