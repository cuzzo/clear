use super::{SqlDialect, SqlPerformanceFinding};
use anyhow::{Context, Result};
use postgres::{Client, NoTls};

pub struct PostgresDialect;

impl SqlDialect for PostgresDialect {
    fn name(&self) -> &'static str {
        "postgres"
    }

    fn sanitize_query(&self, sql: &str) -> String {
        let re_num = regex::Regex::new(r"\$\d+").unwrap();
        let s = re_num.replace_all(sql, "NULL");
        s.replace("?", "NULL")
    }

    fn explain_query(&self, conn_str: &str, sql: &str) -> Result<String> {
        let mut client = Client::connect(conn_str, NoTls)
            .with_context(|| format!("failed to connect to postgres: {}", conn_str))?;
        let sanitized = self.sanitize_query(sql);
        let query = format!("EXPLAIN {}", sanitized);
        let rows = client.query(&query, &[])
            .with_context(|| format!("failed to explain postgres query: {}", sql))?;
        let mut plan = String::new();
        for row in rows {
            let line: String = row.get(0);
            plan.push_str(&line);
            plan.push('\n');
        }
        Ok(plan)
    }

    fn analyze_plan(&self, plan: &str) -> Vec<SqlPerformanceFinding> {
        let mut findings = Vec::new();
        let re_scan = regex::Regex::new(r"(?i)seq scan on\s+([a-zA-Z0-9_]+)").unwrap();
        for line in plan.lines() {
            let lower = line.to_lowercase();
            let table_name = re_scan.captures(line)
                .and_then(|cap| cap.get(1))
                .map(|m| m.as_str().to_string());

            if lower.contains("seq scan") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_SCAN".to_string(),
                    level: "warning".to_string(),
                    message: format!("Full table scan (Seq Scan): {}", line.trim()),
                    big_o_time: "O(N)".to_string(),
                    big_o_space: "O(1)".to_string(),
                    explain_output: plan.to_string(),
                    table_name: table_name.clone(),
                });
            }
            if lower.contains("sort") && lower.contains("temp") {
                findings.push(SqlPerformanceFinding {
                    rule_id: "SQL_TEMP_B_TREE".to_string(),
                    level: "warning".to_string(),
                    message: format!("Uses temporary disk/memory sort: {}", line.trim()),
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
        let mut client = Client::connect(conn_str, NoTls)
            .with_context(|| format!("failed to connect to postgres: {}", conn_str))?;
        let clean_table = table.chars().filter(|c| c.is_alphanumeric() || *c == '_').collect::<String>();
        let query = format!("SELECT COUNT(*) FROM {}", clean_table);
        let row = client.query_one(&query, &[])?;
        let count: i64 = row.get(0);
        Ok(count)
    }
}
