use super::{SqlDialect, SqlPerformanceFinding};
use anyhow::{Context, Result};
use rusqlite::Connection;

pub struct SqliteDialect;

impl SqlDialect for SqliteDialect {
    fn name(&self) -> &'static str {
        "sqlite"
    }

    fn sanitize_query(&self, sql: &str) -> String {
        let re_num = regex::Regex::new(r"\?\d+").unwrap();
        let s = re_num.replace_all(sql, "NULL");
        let re_named = regex::Regex::new(r":\w+").unwrap();
        let s = re_named.replace_all(&s, "NULL");
        s.replace("?", "NULL")
    }

    fn explain_query(&self, conn_str: &str, sql: &str) -> Result<String> {
        let conn = Connection::open(conn_str)
            .with_context(|| format!("failed to open sqlite database: {}", conn_str))?;
        let sanitized = self.sanitize_query(sql);
        let query = format!("EXPLAIN QUERY PLAN {}", sanitized);
        let mut stmt = conn.prepare(&query)
            .with_context(|| format!("failed to prepare explain for query: {}", sql))?;
        let mut rows = stmt.query([])?;
        let mut plan = String::new();
        while let Some(row) = rows.next()? {
            let detail: String = row.get(3)?;
            plan.push_str(&detail);
            plan.push('\n');
        }
        Ok(plan)
    }

    fn analyze_plan(&self, plan: &str) -> Vec<SqlPerformanceFinding> {
        let mut findings = Vec::new();
        let re_scan = regex::Regex::new(r"(?i)SCAN(?:\s+TABLE)?\s+([a-zA-Z0-9_]+)").unwrap();
        let re_search = regex::Regex::new(r"(?i)SEARCH\s+([a-zA-Z0-9_]+)").unwrap();
        for line in plan.lines() {
            let upper = line.to_uppercase();
            let scan_table = re_scan.captures(line)
                .and_then(|cap| cap.get(1))
                .map(|m| m.as_str().to_string());
            let search_table = re_search.captures(line)
                .and_then(|cap| cap.get(1))
                .map(|m| m.as_str().to_string());

            if upper.contains("SCAN") {
                if upper.contains("USING INDEX") {
                    findings.push(SqlPerformanceFinding {
                        rule_id: "SQL_INDEX_SCAN".to_string(),
                        level: "warning".to_string(),
                        message: format!("Full scan of index leaf nodes. Asymptotically O(N) key visits, but faster than table scan due to smaller key footprint: {}", line),
                        big_o_time: "O(N)".to_string(),
                        big_o_space: "O(1)".to_string(),
                        explain_output: plan.to_string(),
                        table_name: scan_table.clone(),
                    });
                } else {
                    findings.push(SqlPerformanceFinding {
                        rule_id: "SQL_SCAN".to_string(),
                        level: "warning".to_string(),
                        message: format!("Full table scan (sequential reads, cache-friendly): {}", line),
                        big_o_time: "O(N)".to_string(),
                        big_o_space: "O(1)".to_string(),
                        explain_output: plan.to_string(),
                        table_name: scan_table.clone(),
                    });
                }
            } else if upper.contains("SEARCH") && upper.contains("USING INDEX") && !upper.contains("COVERING") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_NON_COVERING_INDEX".to_string(),
                    level: "warning".to_string(),
                    message: format!("Non-covering index search (Cache Miss Hazard: triggers random heap page seeks): {}", line),
                    big_o_time: "O(log N + K)".to_string(),
                    big_o_space: "O(1)".to_string(),
                    explain_output: plan.to_string(),
                    table_name: search_table.clone(),
                });
            }
            if upper.contains("TEMP B-TREE") || upper.contains("USING TEMP B-TREE") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_TEMP_B_TREE".to_string(),
                    level: "warning".to_string(),
                    message: format!("Uses temporary B-Tree for sorting/grouping: {}", line),
                    big_o_time: "O(N log N)".to_string(),
                    big_o_space: "O(N)".to_string(),
                    explain_output: plan.to_string(),
                    table_name: None,
                });
            }
        }
        findings
    }

    fn get_table_size(&self, conn_str: &str, table: &str) -> Result<i64> {
        let conn = Connection::open(conn_str)
            .with_context(|| format!("failed to open sqlite database: {}", conn_str))?;
        let clean_table = table.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect::<String>();
        let query = format!("SELECT COUNT(*) FROM {}", clean_table);
        let count: i64 = conn.query_row(&query, [], |r| r.get(0))?;
        Ok(count)
    }

    fn get_table_size_bytes(&self, conn_str: &str, table: &str) -> Result<i64> {
        let conn = Connection::open(conn_str)
            .with_context(|| format!("failed to open sqlite database: {}", conn_str))?;
        let clean_table = table.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect::<String>();
        let mut stmt = conn.prepare(&format!("PRAGMA table_info({})", clean_table))?;
        let cols: Vec<String> = stmt.query_map([], |r| r.get(1))?
            .collect::<Result<Vec<String>, _>>()?;
        if cols.is_empty() {
            return Ok(0);
        }
        let col_expr = cols.iter()
            .map(|c| format!("coalesce(length(cast([{}] as blob)), 0)", c))
            .collect::<Vec<_>>()
            .join(" + ");
        let query = format!("SELECT avg({}) FROM (SELECT * FROM {} LIMIT 50)", col_expr, clean_table);
        let avg_row_size: f64 = conn.query_row(&query, [], |r| r.get(0)).unwrap_or(0.0);
        let count = self.get_table_size(conn_str, table)?;
        Ok((avg_row_size * count as f64) as i64)
    }
}
