use super::{SqlDialect, SqlPerformanceFinding};
use anyhow::{Context, Result};
use mysql::prelude::Queryable;
use mysql::Conn;

pub struct MysqlDialect;

impl SqlDialect for MysqlDialect {
    fn name(&self) -> &'static str {
        "mysql"
    }

    fn sanitize_query(&self, sql: &str) -> String {
        let re_plain = regex::Regex::new(r"\?").unwrap();
        re_plain.replace_all(sql, "NULL").into_owned()
    }

    fn explain_query(&self, conn_str: &str, sql: &str) -> Result<String> {
        let mut conn = Conn::new(conn_str)
            .with_context(|| format!("failed to connect to mysql: {}", conn_str))?;
        let sanitized = self.sanitize_query(sql);
        let query = format!("EXPLAIN {}", sanitized);
        let result: Vec<(Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>)> = conn.query(&query)
            .with_context(|| format!("failed to explain mysql query: {}", sql))?;
        
        let mut plan = String::new();
        for r in result {
            let tbl = r.2.unwrap_or_else(|| "unknown".to_string());
            let join_type = r.4.unwrap_or_else(|| "ALL".to_string());
            let extra = r.11.unwrap_or_default();
            plan.push_str(&format!("table: {}, type: {}, extra: {}\n", tbl, join_type, extra));
        }
        Ok(plan)
    }

    fn analyze_plan(&self, plan: &str) -> Vec<SqlPerformanceFinding> {
        let mut findings = Vec::new();
        let re_scan = regex::Regex::new(r"(?i)table:\s+([a-zA-Z0-9_]+)").unwrap();
        for line in plan.lines() {
            let lower = line.to_lowercase();
            let table_name = re_scan.captures(line)
                .and_then(|cap| cap.get(1))
                .map(|m| m.as_str().to_string());

            if lower.contains("type: all") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_SCAN".to_string(),
                    level: "warning".to_string(),
                    message: format!("Full table scan (sequential reads, cache-friendly): {}", line.trim()),
                    big_o_time: "O(N)".to_string(),
                    big_o_space: "O(1)".to_string(),
                    explain_output: plan.to_string(),
                    table_name: table_name.clone(),
                });
            } else if (lower.contains("type: ref")
                || lower.contains("type: eq_ref")
                || lower.contains("type: range")
                || lower.contains("type: index"))
                && !lower.contains("using index")
            {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_NON_COVERING_INDEX".to_string(),
                    level: "warning".to_string(),
                    message: format!("Non-covering index scan (Cache Miss Hazard: triggers random heap page seeks): {}", line.trim()),
                    big_o_time: "O(log N + K)".to_string(),
                    big_o_space: "O(1)".to_string(),
                    explain_output: plan.to_string(),
                    table_name: table_name.clone(),
                });
            }
            if lower.contains("using filesort") || lower.contains("using temporary") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_TEMP_B_TREE".to_string(),
                    level: "warning".to_string(),
                    message: format!("Uses filesort or temporary table: {}", line.trim()),
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
        let mut conn = Conn::new(conn_str)
            .with_context(|| format!("failed to connect to mysql: {}", conn_str))?;
        let clean_table = table.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect::<String>();
        let query = format!("SELECT COUNT(*) FROM {}", clean_table);
        let count: i64 = conn.query_first(&query)?.unwrap_or(0);
        Ok(count)
    }
}
