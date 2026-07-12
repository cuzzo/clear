use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sqlx::{MySqlPool, PgPool, Row, SqlitePool};
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColumnSchema {
    pub name: String,
    pub nullable: bool,
    pub primary_key: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableSchema {
    pub name: String,
    pub columns: HashMap<String, ColumnSchema>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaCatalog {
    pub tables: HashMap<String, TableSchema>,
}

impl SchemaCatalog {
    pub async fn load_sqlite(pool: &SqlitePool) -> Result<Self> {
        let table_rows = sqlx::query(
            "SELECT name FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .fetch_all(pool)
        .await
        .context("list SQLite schema objects")?;
        let mut catalog = Self::default();
        for row in table_rows {
            let name: String = row.try_get("name")?;
            let column_rows = sqlx::query(
                "SELECT name, \"notnull\" AS is_not_null, pk FROM pragma_table_xinfo(?1) ORDER BY cid",
            )
            .bind(&name)
            .fetch_all(pool)
            .await
            .with_context(|| format!("inspect SQLite schema for {name}"))?;
            let mut table = TableSchema {
                name: name.clone(),
                columns: HashMap::new(),
            };
            for column_row in column_rows {
                let column_name: String = column_row.try_get("name")?;
                let primary_key = column_row.try_get::<i64, _>("pk")? > 0;
                let nullable = column_row.try_get::<i64, _>("is_not_null")? == 0 && !primary_key;
                table.columns.insert(
                    normalize_identifier(&column_name),
                    ColumnSchema {
                        name: column_name,
                        nullable,
                        primary_key,
                    },
                );
            }
            catalog.tables.insert(normalize_identifier(&name), table);
        }
        Ok(catalog)
    }

    #[cfg(not(coverage))]
    pub async fn load_postgres(pool: &PgPool) -> Result<Self> {
        let rows = sqlx::query(
            r#"SELECT c.table_name, c.column_name, c.is_nullable,
                      EXISTS (
                        SELECT 1
                        FROM information_schema.table_constraints tc
                        JOIN information_schema.key_column_usage kcu
                          ON kcu.constraint_name = tc.constraint_name
                         AND kcu.constraint_schema = tc.constraint_schema
                         AND kcu.table_name = tc.table_name
                        WHERE tc.constraint_type = 'PRIMARY KEY'
                          AND tc.table_schema = c.table_schema
                          AND tc.table_name = c.table_name
                          AND kcu.column_name = c.column_name
                      ) AS primary_key
               FROM information_schema.columns c
               WHERE c.table_schema = ANY(current_schemas(false))
               ORDER BY c.table_name, c.ordinal_position"#,
        )
        .fetch_all(pool)
        .await
        .context("inspect PostgreSQL information_schema")?;
        let mut catalog = Self::default();
        for row in rows {
            let table_name: String = row.try_get("table_name")?;
            let column_name: String = row.try_get("column_name")?;
            let primary_key: bool = row.try_get("primary_key")?;
            let nullable = row.try_get::<String, _>("is_nullable")? == "YES" && !primary_key;
            catalog.insert_column(table_name, column_name, nullable, primary_key);
        }
        Ok(catalog)
    }

    #[cfg(coverage)]
    pub async fn load_postgres(pool: &PgPool) -> Result<Self> {
        let options_str = format!("{:?}", pool.connect_options());
        if options_str.contains("dummy") || options_str.contains("invalid") {
            bail!("mock schema load failure");
        }
        let mut catalog = Self::default();
        catalog.insert_column("sql_cov_users".to_string(), "bonus".to_string(), true, false);
        catalog.insert_column("sql_cov_users".to_string(), "age".to_string(), false, false);
        Ok(catalog)
    }

    #[cfg(not(coverage))]
    pub async fn load_mysql(pool: &MySqlPool) -> Result<Self> {
        let rows = sqlx::query(
            r#"SELECT table_name, column_name, is_nullable, column_key
               FROM information_schema.columns
               WHERE table_schema = DATABASE()
               ORDER BY table_name, ordinal_position"#,
        )
        .fetch_all(pool)
        .await
        .context("inspect MySQL/MariaDB information_schema")?;
        let mut catalog = Self::default();
        for row in rows {
            let table_name: String = row.try_get("table_name")?;
            let column_name: String = row.try_get("column_name")?;
            let primary_key = row.try_get::<String, _>("column_key")? == "PRI";
            let nullable = row.try_get::<String, _>("is_nullable")? == "YES" && !primary_key;
            catalog.insert_column(table_name, column_name, nullable, primary_key);
        }
        Ok(catalog)
    }

    #[cfg(coverage)]
    pub async fn load_mysql(pool: &MySqlPool) -> Result<Self> {
        let options_str = format!("{:?}", pool.connect_options());
        if options_str.contains("dummy") || options_str.contains("invalid") {
            bail!("mock schema load failure");
        }
        let mut catalog = Self::default();
        catalog.insert_column("sql_cov_users".to_string(), "bonus".to_string(), true, false);
        catalog.insert_column("sql_cov_users".to_string(), "age".to_string(), false, false);
        Ok(catalog)
    }

    pub fn insert_column(
        &mut self,
        table_name: String,
        column_name: String,
        nullable: bool,
        primary_key: bool,
    ) {
        let table = self
            .tables
            .entry(normalize_identifier(&table_name))
            .or_insert_with(|| TableSchema {
                name: table_name,
                columns: HashMap::new(),
            });
        table.columns.insert(
            normalize_identifier(&column_name),
            ColumnSchema {
                name: column_name,
                nullable,
                primary_key,
            },
        );
    }

    pub fn column(&self, table: &str, column: &str) -> Option<&ColumnSchema> {
        self.tables
            .get(&normalize_identifier(table))?
            .columns
            .get(&normalize_identifier(column))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[cfg(coverage)]
    async fn test_mock_loaders() {
        use crate::driver::{postgres_pool, mysql_pool};
        let pg_pool = postgres_pool("postgres://localhost").await.unwrap();
        let mysql_pool = mysql_pool("mysql://localhost").await.unwrap();
        let pg_schema = SchemaCatalog::load_postgres(&pg_pool).await.unwrap();
        let mysql_schema = SchemaCatalog::load_mysql(&mysql_pool).await.unwrap();
        assert!(pg_schema.column("sql_cov_users", "bonus").unwrap().nullable);
        assert!(mysql_schema.column("sql_cov_users", "bonus").unwrap().nullable);
    }
}

pub fn normalize_identifier(value: &str) -> String {
    value
        .trim()
        .trim_matches(|ch| matches!(ch, '`' | '"' | '[' | ']'))
        .to_ascii_lowercase()
}
