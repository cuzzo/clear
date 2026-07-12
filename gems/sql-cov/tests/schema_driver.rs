use sql_cov::driver::{sqlite_pool, execute_sqlite_setup, ParameterValue};
use sql_cov::schema::{normalize_identifier, SchemaCatalog};
use sql_cov::DialectName;

#[test]
fn test_normalize_identifier() {
    assert_eq!(normalize_identifier("  `USER` "), "user");
    assert_eq!(normalize_identifier(" [Age] "), "age");
    assert_eq!(normalize_identifier(" \"Bonus\" "), "bonus");
    assert_eq!(normalize_identifier("Normal"), "normal");
}

#[test]
fn test_dialect_name_parse_and_str() {
    assert_eq!(DialectName::parse("sqlite").unwrap(), DialectName::Sqlite);
    assert_eq!(DialectName::parse("sqlite3").unwrap(), DialectName::Sqlite);
    assert_eq!(DialectName::parse("postgres").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("postgresql").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("pg").unwrap(), DialectName::Postgres);
    assert_eq!(DialectName::parse("mysql").unwrap(), DialectName::Mysql);
    assert_eq!(DialectName::parse("mariadb").unwrap(), DialectName::Mysql);
    assert_eq!(DialectName::parse("maria").unwrap(), DialectName::Mysql);
    assert!(DialectName::parse("invalid").is_err());

    assert_eq!(DialectName::Sqlite.as_str(), "sqlite");
    assert_eq!(DialectName::Postgres.as_str(), "postgres");
    assert_eq!(DialectName::Mysql.as_str(), "mysql");
}

#[test]
fn test_parameter_value_parse() {
    assert_eq!(ParameterValue::parse("null").unwrap(), ParameterValue::NullText);
    assert_eq!(ParameterValue::parse("null:text").unwrap(), ParameterValue::NullText);
    assert_eq!(ParameterValue::parse("null:int").unwrap(), ParameterValue::NullInteger);
    assert_eq!(ParameterValue::parse("null:integer").unwrap(), ParameterValue::NullInteger);
    assert_eq!(ParameterValue::parse("null:float").unwrap(), ParameterValue::NullFloat);
    assert_eq!(ParameterValue::parse("null:bool").unwrap(), ParameterValue::NullBoolean);
    assert_eq!(ParameterValue::parse("null:boolean").unwrap(), ParameterValue::NullBoolean);

    assert_eq!(ParameterValue::parse("int:123").unwrap(), ParameterValue::Integer(123));
    assert!(ParameterValue::parse("int:abc").is_err());

    assert_eq!(ParameterValue::parse("float:12.34").unwrap(), ParameterValue::Float(12.34));
    assert!(ParameterValue::parse("float:abc").is_err());

    assert_eq!(ParameterValue::parse("bool:true").unwrap(), ParameterValue::Boolean(true));
    assert_eq!(ParameterValue::parse("bool:false").unwrap(), ParameterValue::Boolean(false));
    assert!(ParameterValue::parse("bool:abc").is_err());

    assert_eq!(ParameterValue::parse("text:hello").unwrap(), ParameterValue::Text("hello".to_string()));
    assert_eq!(ParameterValue::parse("hello").unwrap(), ParameterValue::Text("hello".to_string()));
}

#[tokio::test]
async fn test_sqlite_schema_catalog_loading() {
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(
        &pool,
        "CREATE TABLE test_table (\
            id INTEGER PRIMARY KEY,\
            name TEXT NOT NULL,\
            age INTEGER,\
            salary REAL NOT NULL\
         );\
         CREATE VIEW test_view AS SELECT id, name FROM test_table;",
    )
    .await
    .unwrap();

    let catalog = SchemaCatalog::load_sqlite(&pool).await.unwrap();

    // Verify table structure
    let table = catalog.tables.get("test_table").unwrap();
    assert_eq!(table.name, "test_table");

    // Verify columns
    let id_col = catalog.column("test_table", "id").unwrap();
    assert_eq!(id_col.name, "id");
    assert!(!id_col.nullable);
    assert!(id_col.primary_key);

    let name_col = catalog.column("test_table", "name").unwrap();
    assert_eq!(name_col.name, "name");
    assert!(!name_col.nullable);
    assert!(!name_col.primary_key);

    let age_col = catalog.column("test_table", "age").unwrap();
    assert_eq!(age_col.name, "age");
    assert!(age_col.nullable);
    assert!(!age_col.primary_key);

    let salary_col = catalog.column("test_table", "salary").unwrap();
    assert_eq!(salary_col.name, "salary");
    assert!(!salary_col.nullable);
    assert!(!salary_col.primary_key);

    // Verify view loading
    let view = catalog.tables.get("test_view").unwrap();
    assert_eq!(view.name, "test_view");
    assert!(catalog.column("test_view", "name").is_some());
}
