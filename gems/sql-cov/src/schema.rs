use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sqlx::{Row, SqlitePool};
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

    pub fn column(&self, table: &str, column: &str) -> Option<&ColumnSchema> {
        self.tables
            .get(&normalize_identifier(table))?
            .columns
            .get(&normalize_identifier(column))
    }
}

pub fn normalize_identifier(value: &str) -> String {
    value
        .trim()
        .trim_matches(|ch| matches!(ch, '`' | '"' | '[' | ']'))
        .to_ascii_lowercase()
}
