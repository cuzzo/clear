use anyhow::{Context, Result};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

pub mod mysql;
pub mod postgres;
pub mod sqlite;

pub struct SqlPerformanceFinding {
    pub rule_id: String,
    pub level: String,
    pub message: String,
    pub big_o_time: String,
    pub big_o_space: String,
    pub explain_output: String,
    pub table_name: Option<String>,
}

pub trait SqlDialect {
    fn name(&self) -> &'static str;
    fn sanitize_query(&self, sql: &str) -> String;
    fn explain_query(&self, conn_str: &str, sql: &str) -> Result<String>;
    fn analyze_plan(&self, plan: &str) -> Vec<SqlPerformanceFinding>;
    fn get_table_size(&self, conn_str: &str, table: &str) -> Result<i64>;
    fn get_table_size_bytes(&self, conn_str: &str, table: &str) -> Result<i64>;
}

pub fn analyze_sql_files(
    dialect_name: &str,
    conn_str: &str,
    queries_path: &Path,
    output_sarif: &Path,
) -> Result<()> {
    let dialect: Box<dyn SqlDialect> = match dialect_name.to_lowercase().as_str() {
        "sqlite" => Box::new(sqlite::SqliteDialect),
        "postgres" | "postgresql" => Box::new(postgres::PostgresDialect),
        "mysql" | "mariadb" => Box::new(mysql::MysqlDialect),
        _ => anyhow::bail!("Unsupported SQL dialect: {}", dialect_name),
    };

    let mut sql_files = Vec::new();
    collect_sql_files(queries_path, &mut sql_files)?;

    let mut results = Vec::new();

    for file_path in sql_files {
        let sql = fs::read_to_string(&file_path)
            .with_context(|| format!("failed to read SQL file: {}", file_path.display()))?;

        // Extract query-id or rule-id if present in comments, or default to file name
        let rule_id_fallback = file_path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("sql-query")
            .to_string();

        let plan = match dialect.explain_query(conn_str, &sql) {
            Ok(p) => p,
            Err(e) => {
                results.push(json!({
                    "ruleId": "SQL_EXPLAIN_ERROR",
                    "level": "error",
                    "message": {
                        "text": format!("Explain failed: {}", e)
                    },
                    "locations": [
                        {
                            "physicalLocation": {
                                "artifactLocation": {
                                    "uri": file_path.to_string_lossy().to_string()
                                },
                                "region": {
                                    "startLine": 1,
                                    "startColumn": 1
                                }
                            }
                        }
                    ]
                }));
                continue;
            }
        };

        let findings = dialect.analyze_plan(&plan);
        for finding in findings {
            let mut table_size = None;
            let mut table_size_bytes = None;
            let mut cache_warning = None;

            if let Some(ref tbl) = finding.table_name {
                if let Ok(size) = dialect.get_table_size(conn_str, tbl) {
                    table_size = Some(size);
                }
                if let Ok(bytes) = dialect.get_table_size_bytes(conn_str, tbl) {
                    table_size_bytes = Some(bytes);
                    let limit_bytes = match dialect.name() {
                        "sqlite" => 64 * 1024 * 1024,
                        _ => 128 * 1024 * 1024,
                    };
                    if bytes > limit_bytes {
                        cache_warning = Some(format!(
                            "Estimated size of table '{}' ({:.1} MB) exceeds default buffer pool capacity ({:.1} MB). Prone to memory eviction and disk thrashing.",
                            tbl,
                            bytes as f64 / 1_048_576.0,
                            limit_bytes as f64 / 1_048_576.0
                        ));
                    }
                }
            }

            let message_text = if let Some(ref warn) = cache_warning {
                format!("{} - {}", finding.message, warn)
            } else {
                finding.message.clone()
            };

            results.push(json!({
                "ruleId": finding.rule_id,
                "level": finding.level,
                "message": {
                    "text": message_text
                },
                "locations": [
                    {
                        "physicalLocation": {
                            "artifactLocation": {
                                "uri": file_path.to_string_lossy().to_string()
                            },
                            "region": {
                                "startLine": 1,
                                "startColumn": 1
                            }
                        }
                    }
                ],
                "properties": {
                    "category": "performance",
                    "explain_output": finding.explain_output,
                    "big_o_time": finding.big_o_time,
                    "big_o_space": finding.big_o_space,
                    "table_name": finding.table_name,
                    "table_size_n": table_size,
                    "table_size_bytes": table_size_bytes,
                    "cache_warning": cache_warning,
                    "query_id": rule_id_fallback
                }
            }));
        }
    }

    let sarif = json!({
        "version": "2.1.0",
        "$schema": "https://schemastore.azurewebsites.net/schema/sarif-2.1.0-rtm.5.json",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "sql-explain",
                        "version": "0.1.0"
                    }
                },
                "results": results
            }
        ]
    });

    let json_str = serde_json::to_string_pretty(&sarif)?;
    fs::write(output_sarif, json_str)
        .with_context(|| format!("failed to write SARIF output: {}", output_sarif.display()))?;

    Ok(())
}

fn collect_sql_files(path: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    if path.is_dir() {
        for entry in fs::read_dir(path)? {
            collect_sql_files(&entry?.path(), files)?;
        }
    } else if path.is_file() {
        if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
            if ext.to_lowercase() == "sql" {
                files.push(path.to_path_buf());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_sqlite_analyzer() -> Result<()> {
        let dir = tempdir()?;
        let db_path = dir.path().join("test.db");
        
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", [])?;
        conn.execute("INSERT INTO users (name) VALUES ('Alice')", [])?;
        drop(conn);

        let queries_dir = dir.path().join("queries");
        fs::create_dir(&queries_dir)?;
        let query_file = queries_dir.join("find_users.sql");
        fs::write(&query_file, "SELECT * FROM users WHERE name = ?1")?;

        let sarif_output = dir.path().join("output.sarif");
        
        analyze_sql_files("sqlite", &db_path.to_string_lossy(), &queries_dir, &sarif_output)?;

        let content = fs::read_to_string(&sarif_output)?;
        let sarif_val: serde_json::Value = serde_json::from_str(&content)?;
        
        let results = sarif_val["runs"][0]["results"].as_array().unwrap();
        assert!(!results.is_empty(), "expected at least one finding");
        
        let scan_finding = results.iter().find(|r| r["ruleId"] == "SQL_SCAN").unwrap();
        assert!(scan_finding["message"]["text"].as_str().unwrap().contains("Full table scan"));
        assert_eq!(scan_finding["properties"]["table_name"].as_str(), Some("users"));
        assert_eq!(scan_finding["properties"]["table_size_n"].as_i64(), Some(1));
        assert!(scan_finding["properties"]["table_size_bytes"].as_i64().is_some());
        
        Ok(())
    }
}
