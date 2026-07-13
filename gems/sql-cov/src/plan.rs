use crate::driver::ParameterValue;
use crate::DialectName;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{MySqlPool, PgPool, Row, SqlitePool};
use std::fs;
use std::path::{Path, PathBuf};

pub const COMPLEXITY_RULE_ID: &str = "complexity.observation";
pub const PLAN_SARIF_FORMAT: &str = "sql-cov.plan.sarif.v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Growth {
    Constant,
    Logarithmic,
    LogarithmicPlusOutput,
    Linear,
    Linearithmic,
    Product,
    Cubic,
    Exponential,
    Factorial,
    Unknown,
}

impl Growth {
    pub fn notation(self) -> &'static str {
        match self {
            Self::Constant => "O(1)",
            Self::Logarithmic => "O(log N)",
            Self::LogarithmicPlusOutput => "O(log N + K)",
            Self::Linear => "O(N)",
            Self::Linearithmic => "O(N log N)",
            Self::Product => "O(N * M)",
            Self::Cubic => "O(N^3)",
            Self::Exponential => "O(2^N)",
            Self::Factorial => "O(N!)",
            Self::Unknown => "unknown",
        }
    }

    pub fn rank(self) -> u32 {
        match self {
            Self::Constant => 1,
            Self::Logarithmic => 2,
            Self::LogarithmicPlusOutput => 3,
            Self::Linear => 10,
            Self::Linearithmic => 11,
            Self::Product => 14,
            Self::Cubic => 16,
            Self::Exponential => 100,
            Self::Factorial => 200,
            Self::Unknown => 0,
        }
    }

    fn max(self, other: Self) -> Self {
        if self == Self::Unknown || other == Self::Unknown {
            Self::Unknown
        } else if self.rank() >= other.rank() {
            self
        } else {
            other
        }
    }

    fn multiply(self, other: Self) -> Self {
        use Growth::*;
        match (self, other) {
            (Unknown, _) | (_, Unknown) => Unknown,
            (Constant, value) | (value, Constant) => value,
            (Factorial, _) | (_, Factorial) => Factorial,
            (Exponential, _) | (_, Exponential) => Exponential,
            (Cubic, _) | (_, Cubic) => Cubic,
            (Product, Linear | LogarithmicPlusOutput)
            | (Linear | LogarithmicPlusOutput, Product)
            | (Linearithmic, Linear | LogarithmicPlusOutput)
            | (Linear | LogarithmicPlusOutput, Linearithmic) => Cubic,
            (Product, _) | (_, Product) => Product,
            (Linear | LogarithmicPlusOutput, Linear | LogarithmicPlusOutput) => Product,
            (Linearithmic, Linearithmic) => Product,
            (Linearithmic, Logarithmic) | (Logarithmic, Linearithmic) => Linearithmic,
            (Linear, Logarithmic) | (Logarithmic, Linear) => Linearithmic,
            (LogarithmicPlusOutput, Logarithmic) | (Logarithmic, LogarithmicPlusOutput) => {
                Linearithmic
            }
            (Logarithmic, Logarithmic) => Logarithmic,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanWarning {
    pub rule_id: String,
    pub message: String,
    pub time: Growth,
    pub auxiliary_space: Growth,
    pub table_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanComplexity {
    pub time: Growth,
    pub auxiliary_space: Growth,
    pub triggers: Vec<String>,
    pub warnings: Vec<PlanWarning>,
}

impl Default for PlanComplexity {
    fn default() -> Self {
        Self {
            time: Growth::Constant,
            auxiliary_space: Growth::Constant,
            triggers: Vec::new(),
            warnings: Vec::new(),
        }
    }
}

impl PlanComplexity {
    fn sequential(mut self, other: Self) -> Self {
        self.time = self.time.max(other.time);
        self.auxiliary_space = self.auxiliary_space.max(other.auxiliary_space);
        self.triggers.extend(other.triggers);
        self.warnings.extend(other.warnings);
        self
    }

    fn nested(mut self, other: Self) -> Self {
        self.time = self.time.multiply(other.time);
        self.auxiliary_space = self.auxiliary_space.max(other.auxiliary_space);
        self.triggers.extend(other.triggers);
        self.warnings.extend(other.warnings);
        self
    }

    fn add_sort(&mut self, trigger: &str) {
        self.time = self.time.max(Growth::Linearithmic);
        self.auxiliary_space = self.auxiliary_space.max(Growth::Linear);
        self.triggers.push(trigger.to_string());
        self.warnings.push(PlanWarning {
            rule_id: "SQL_SORT".to_string(),
            message: "Query plan performs an asymptotically linear-space sort".to_string(),
            time: Growth::Linearithmic,
            auxiliary_space: Growth::Linear,
            table_name: None,
        });
    }

    fn deduplicate(&mut self) {
        self.triggers.sort();
        self.triggers.dedup();
        self.warnings.sort_by(|left, right| {
            (&left.rule_id, &left.table_name, &left.message).cmp(&(
                &right.rule_id,
                &right.table_name,
                &right.message,
            ))
        });
        self.warnings.dedup();
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryPlanObservation {
    pub path: String,
    pub query_id: String,
    pub dialect: DialectName,
    pub complexity: PlanComplexity,
    pub explain: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SqlitePlanRow {
    pub id: i64,
    pub parent: i64,
    pub detail: String,
}

fn scan_warning(table_name: Option<String>, index_only: bool) -> PlanWarning {
    PlanWarning {
        rule_id: if index_only {
            "SQL_INDEX_SCAN"
        } else {
            "SQL_SCAN"
        }
        .to_string(),
        message: if index_only {
            "Full index scan visits O(N) keys".to_string()
        } else {
            "Full table scan visits O(N) rows".to_string()
        },
        time: Growth::Linear,
        auxiliary_space: Growth::Constant,
        table_name,
    }
}

fn lookup_warning(table_name: Option<String>) -> PlanWarning {
    PlanWarning {
        rule_id: "SQL_NON_COVERING_INDEX".to_string(),
        message: "Non-covering index lookup may require random heap/page reads".to_string(),
        time: Growth::LogarithmicPlusOutput,
        auxiliary_space: Growth::Constant,
        table_name,
    }
}

fn identifier_after(detail: &str, marker: &str) -> Option<String> {
    let upper = detail.to_ascii_uppercase();
    let start = upper.find(marker)? + marker.len();
    detail[start..]
        .split_whitespace()
        .next()
        .map(|value| value.trim_matches(|character| character == '`' || character == '"'))
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

pub fn analyze_sqlite_plan(rows: &[SqlitePlanRow]) -> PlanComplexity {
    let mut accesses = Vec::new();
    let mut result = PlanComplexity::default();
    for row in rows {
        let upper = row.detail.to_ascii_uppercase();
        if upper.contains("USE TEMP B-TREE") {
            result.add_sort("sqlite temporary b-tree");
        } else if upper.starts_with("SCAN ") || upper.contains(" SCAN ") {
            let index_only =
                upper.contains("USING COVERING INDEX") || upper.contains("USING INDEX");
            let table = identifier_after(&row.detail, "SCAN ");
            let mut access = PlanComplexity {
                time: Growth::Linear,
                ..PlanComplexity::default()
            };
            access.warnings.push(scan_warning(table, index_only));
            accesses.push(access);
        } else if upper.starts_with("SEARCH ") || upper.contains(" SEARCH ") {
            let table = identifier_after(&row.detail, "SEARCH ");
            let covering = upper.contains("USING COVERING INDEX")
                || upper.contains("USING INTEGER PRIMARY KEY");
            let mut access = PlanComplexity {
                time: Growth::LogarithmicPlusOutput,
                ..PlanComplexity::default()
            };
            if !covering {
                access.warnings.push(lookup_warning(table));
            }
            accesses.push(access);
        }
    }

    if let Some(first) = accesses.first().cloned() {
        let joined = accesses
            .into_iter()
            .skip(1)
            .fold(first, PlanComplexity::nested);
        result = result.sequential(joined);
        if rows
            .iter()
            .filter(|row| {
                let upper = row.detail.to_ascii_uppercase();
                upper.starts_with("SCAN ") || upper.starts_with("SEARCH ")
            })
            .count()
            > 1
        {
            result.triggers.push("sqlite nested-loop join".to_string());
        }
    }
    result.deduplicate();
    result
}

fn postgres_children(node: &Value) -> Vec<&Value> {
    node.get("Plans")
        .and_then(Value::as_array)
        .map(|plans| plans.iter().collect())
        .unwrap_or_default()
}

fn analyze_postgres_node(node: &Value) -> PlanComplexity {
    let children = postgres_children(node);
    let node_type = node.get("Node Type").and_then(Value::as_str).unwrap_or("");
    let relation = node
        .get("Relation Name")
        .and_then(Value::as_str)
        .map(str::to_string);

    let correlated_subplans = children
        .iter()
        .filter(|child| {
            child.get("Parent Relationship").and_then(Value::as_str) == Some("SubPlan")
        })
        .copied()
        .collect::<Vec<_>>();
    let ordinary_children = children
        .iter()
        .filter(|child| {
            child.get("Parent Relationship").and_then(Value::as_str) != Some("SubPlan")
        })
        .copied()
        .collect::<Vec<_>>();

    let mut result = if node_type == "Nested Loop" && !ordinary_children.is_empty() {
        let first = analyze_postgres_node(ordinary_children[0]);
        ordinary_children.iter().skip(1).fold(first, |cost, child| {
            cost.nested(analyze_postgres_node(child))
        })
    } else {
        ordinary_children
            .iter()
            .fold(PlanComplexity::default(), |cost, child| {
                cost.sequential(analyze_postgres_node(child))
            })
    };

    match node_type {
        "Seq Scan" => {
            result.time = result.time.max(Growth::Linear);
            result.warnings.push(scan_warning(relation, false));
            result.triggers.push("postgres sequential scan".to_string());
        }
        "Index Scan" | "Bitmap Heap Scan" => {
            result.time = result.time.max(Growth::LogarithmicPlusOutput);
            result.warnings.push(lookup_warning(relation));
        }
        "Index Only Scan" | "Bitmap Index Scan" => {
            result.time = result.time.max(Growth::LogarithmicPlusOutput);
        }
        "Sort" | "Incremental Sort" => result.add_sort("postgres sort"),
        "Hash" | "Hash Join" | "HashAggregate" => {
            result.time = result.time.max(Growth::Linear);
            result.auxiliary_space = result.auxiliary_space.max(Growth::Linear);
            result
                .triggers
                .push(format!("postgres {}", node_type.to_ascii_lowercase()));
        }
        "Aggregate" | "GroupAggregate" => {
            result.time = result.time.max(Growth::Linear);
        }
        "Materialize" | "Memoize" => {
            result.auxiliary_space = result.auxiliary_space.max(Growth::Linear);
            result
                .triggers
                .push(format!("postgres {}", node_type.to_ascii_lowercase()));
        }
        "Nested Loop" => result
            .triggers
            .push("postgres nested-loop join".to_string()),
        _ => {}
    }
    for subplan in correlated_subplans {
        result = result.nested(analyze_postgres_node(subplan));
        result
            .triggers
            .push("postgres correlated subplan".to_string());
    }
    result
}

pub fn analyze_postgres_plan(value: &Value) -> Result<PlanComplexity> {
    let plan = value
        .as_array()
        .and_then(|items| items.first())
        .and_then(|entry| entry.get("Plan"))
        .or_else(|| value.get("Plan"))
        .context("PostgreSQL EXPLAIN JSON is missing its Plan root")?;
    let mut result = analyze_postgres_node(plan);
    result.deduplicate();
    Ok(result)
}

fn mysql_table(value: &Value) -> Option<PlanComplexity> {
    let table = value.get("table")?;
    let access = table
        .get("access_type")
        .and_then(Value::as_str)
        .unwrap_or("");
    let table_name = table
        .get("table_name")
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut result = PlanComplexity::default();
    match access.to_ascii_uppercase().as_str() {
        "ALL" => {
            result.time = Growth::Linear;
            result.warnings.push(scan_warning(table_name, false));
            result.triggers.push("mysql full table scan".to_string());
        }
        "INDEX" => {
            result.time = Growth::Linear;
            result.warnings.push(scan_warning(table_name, true));
        }
        "RANGE" | "REF" | "EQ_REF" | "REF_OR_NULL" | "INDEX_MERGE" => {
            result.time = Growth::LogarithmicPlusOutput;
            let covering = table
                .get("using_index")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if !covering {
                result.warnings.push(lookup_warning(table_name));
            }
        }
        "CONST" | "SYSTEM" | "UNIQUE_SUBQUERY" => result.time = Growth::Constant,
        _ => result.time = Growth::Unknown,
    }
    Some(result)
}

fn analyze_mysql_node(value: &Value) -> PlanComplexity {
    if let Some(mut table) = mysql_table(value) {
        if value
            .get("using_filesort")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            table.add_sort("mysql filesort");
        }
        if value
            .get("using_temporary_table")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            table.auxiliary_space = table.auxiliary_space.max(Growth::Linear);
            table.triggers.push("mysql temporary table".to_string());
        }
        return table;
    }
    if let Some(loop_nodes) = value.get("nested_loop").and_then(Value::as_array) {
        let mut iterator = loop_nodes.iter();
        let Some(first) = iterator.next() else {
            return PlanComplexity::default();
        };
        let mut result = iterator.fold(analyze_mysql_node(first), |cost, node| {
            cost.nested(analyze_mysql_node(node))
        });
        result.triggers.push("mysql nested-loop join".to_string());
        if value
            .get("using_filesort")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            result.add_sort("mysql filesort");
        }
        if value
            .get("using_temporary_table")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            result.auxiliary_space = result.auxiliary_space.max(Growth::Linear);
            result.triggers.push("mysql temporary table".to_string());
        }
        return result;
    }

    let mut result = PlanComplexity::default();
    if let Some(object) = value.as_object() {
        for (key, child) in object {
            if matches!(key.as_str(), "using_filesort" | "using_temporary_table") {
                continue;
            }
            result = result.sequential(analyze_mysql_node(child));
        }
        if object
            .get("using_filesort")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            result.add_sort("mysql filesort");
        }
        if object
            .get("using_temporary_table")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            result.auxiliary_space = result.auxiliary_space.max(Growth::Linear);
            result.triggers.push("mysql temporary table".to_string());
        }
    } else if let Some(array) = value.as_array() {
        for child in array {
            result = result.sequential(analyze_mysql_node(child));
        }
    }
    result
}

pub fn analyze_mysql_plan(value: &Value) -> Result<PlanComplexity> {
    let root = value.get("query_block").unwrap_or(value);
    let mut result = analyze_mysql_node(root);
    result.deduplicate();
    Ok(result)
}

fn parse_parameters(parameters: &[String]) -> Result<Vec<ParameterValue>> {
    parameters
        .iter()
        .map(|value| ParameterValue::parse(value))
        .collect()
}

pub async fn explain_sqlite(
    pool: &SqlitePool,
    sql: &str,
    parameters: &[String],
) -> Result<(PlanComplexity, String)> {
    let parameters = parse_parameters(parameters)?;
    let explain_sql = format!("EXPLAIN QUERY PLAN {sql}");
    let mut query = sqlx::query(&explain_sql);
    for parameter in &parameters {
        query = crate::driver::bind_sqlite(query, parameter);
    }
    let raw_rows = query
        .fetch_all(pool)
        .await
        .context("execute SQLite EXPLAIN QUERY PLAN")?;
    let rows = raw_rows
        .iter()
        .map(|row| {
            Ok(SqlitePlanRow {
                id: row.try_get(0)?,
                parent: row.try_get(1)?,
                detail: row.try_get(3)?,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let explain = rows
        .iter()
        .map(|row| format!("{}|{}|{}", row.id, row.parent, row.detail))
        .collect::<Vec<_>>()
        .join("\n");
    Ok((analyze_sqlite_plan(&rows), explain))
}

#[cfg(not(coverage))]
pub async fn explain_postgres(
    pool: &PgPool,
    sql: &str,
    parameters: &[String],
) -> Result<(PlanComplexity, String)> {
    let parameters = parse_parameters(parameters)?;
    let explain_sql = format!("EXPLAIN (FORMAT JSON) {sql}");
    let mut query = sqlx::query(&explain_sql);
    for parameter in &parameters {
        query = crate::driver::bind_postgres(query, parameter);
    }
    let row = query
        .fetch_one(pool)
        .await
        .context("execute PostgreSQL EXPLAIN (FORMAT JSON)")?;
    let value: Value = row.try_get(0)?;
    let explain = serde_json::to_string(&value)?;
    Ok((analyze_postgres_plan(&value)?, explain))
}

#[cfg(coverage)]
pub async fn explain_postgres(
    _pool: &PgPool,
    _sql: &str,
    _parameters: &[String],
) -> Result<(PlanComplexity, String)> {
    anyhow::bail!("PostgreSQL plan execution is unavailable in coverage-stub builds")
}

#[cfg(not(coverage))]
pub async fn explain_mysql(
    pool: &MySqlPool,
    sql: &str,
    parameters: &[String],
) -> Result<(PlanComplexity, String)> {
    let parameters = parse_parameters(parameters)?;
    let explain_sql = format!("EXPLAIN FORMAT=JSON {sql}");
    let mut query = sqlx::query(&explain_sql);
    for parameter in &parameters {
        query = crate::driver::bind_mysql(query, parameter);
    }
    let row = query
        .fetch_one(pool)
        .await
        .context("execute MySQL EXPLAIN FORMAT=JSON")?;
    let raw: String = row.try_get(0)?;
    let value: Value = serde_json::from_str(&raw).context("parse MySQL EXPLAIN JSON")?;
    Ok((analyze_mysql_plan(&value)?, raw))
}

#[cfg(coverage)]
pub async fn explain_mysql(
    _pool: &MySqlPool,
    _sql: &str,
    _parameters: &[String],
) -> Result<(PlanComplexity, String)> {
    anyhow::bail!("MySQL plan execution is unavailable in coverage-stub builds")
}

pub fn collect_sql_files(path: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    fn collect(path: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
        if path.is_dir() {
            for entry in fs::read_dir(path)? {
                collect(&entry?.path(), files)?;
            }
        } else if path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extension.eq_ignore_ascii_case("sql"))
        {
            files.push(path.to_path_buf());
        }
        Ok(())
    }
    collect(path, &mut files)?;
    files.sort();
    Ok(files)
}

pub fn query_id(path: &Path, source: &str) -> String {
    source
        .lines()
        .find_map(|line| line.trim().strip_prefix("-- query-id:").map(str::trim))
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| {
            path.file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("sql-query")
                .to_string()
        })
}

pub fn plan_sarif(observations: &[QueryPlanObservation]) -> Result<String> {
    let mut results = Vec::new();
    for observation in observations {
        let complexity = &observation.complexity;
        results.push(json!({
            "ruleId": COMPLEXITY_RULE_ID,
            "level": "note",
            "message": { "text": format!(
                "{} has estimated runtime {} and auxiliary space {}",
                observation.query_id,
                complexity.time.notation(),
                complexity.auxiliary_space.notation()
            ) },
            "locations": [{ "physicalLocation": {
                "artifactLocation": { "uri": observation.path },
                "region": { "startLine": 1, "startColumn": 1 }
            } }],
            "properties": {
                "category": "complexity",
                "complexity": {
                    "subject_kind": "query",
                    "subject_name": observation.query_id,
                    "time": complexity.time.notation(),
                    "auxiliary_space": complexity.auxiliary_space.notation(),
                    "dynamic": true,
                    "basis": format!("{}-explain", observation.dialect.as_str()),
                    "confidence": "plan-derived",
                    "dialect": observation.dialect.as_str(),
                    "triggers": complexity.triggers,
                    "explain": observation.explain
                }
            },
            "partialFingerprints": { "queryId": observation.query_id }
        }));
        for warning in &complexity.warnings {
            results.push(json!({
                "ruleId": warning.rule_id,
                "level": "warning",
                "message": { "text": warning.message },
                "locations": [{ "physicalLocation": {
                    "artifactLocation": { "uri": observation.path },
                    "region": { "startLine": 1, "startColumn": 1 }
                } }],
                "properties": {
                    "category": "performance",
                    "query_id": observation.query_id,
                    "time": warning.time.notation(),
                    "auxiliary_space": warning.auxiliary_space.notation(),
                    "table_name": warning.table_name
                },
                "partialFingerprints": {
                    "queryId": observation.query_id,
                    "operator": format!("{}:{}", warning.rule_id, warning.table_name.as_deref().unwrap_or(""))
                }
            }));
        }
    }
    let document = json!({
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": { "driver": {
                "name": "SQL-COV",
                "semanticVersion": env!("CARGO_PKG_VERSION"),
                "rules": [
                    {
                        "id": COMPLEXITY_RULE_ID,
                        "shortDescription": { "text": "Database query-plan time and auxiliary-space complexity" },
                        "defaultConfiguration": { "level": "note" }
                    },
                    {
                        "id": "SQL_SCAN",
                        "shortDescription": { "text": "Full table scan" },
                        "defaultConfiguration": { "level": "warning" }
                    },
                    {
                        "id": "SQL_INDEX_SCAN",
                        "shortDescription": { "text": "Full index scan" },
                        "defaultConfiguration": { "level": "warning" }
                    },
                    {
                        "id": "SQL_NON_COVERING_INDEX",
                        "shortDescription": { "text": "Non-covering index lookup" },
                        "defaultConfiguration": { "level": "warning" }
                    },
                    {
                        "id": "SQL_SORT",
                        "shortDescription": { "text": "Linear-space query-plan sort" },
                        "defaultConfiguration": { "level": "warning" }
                    }
                ]
            } },
            "results": results,
            "properties": { "format": PLAN_SARIF_FORMAT }
        }]
    });
    Ok(serde_json::to_string_pretty(&document)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn growth_algebra_is_monotonic_and_composes_nested_work() {
        assert_eq!(
            Growth::Linear.max(Growth::Linearithmic),
            Growth::Linearithmic
        );
        assert_eq!(Growth::Linear.multiply(Growth::Linear), Growth::Product);
        assert_eq!(Growth::Product.multiply(Growth::Linear), Growth::Cubic);
        assert_eq!(
            Growth::Constant.multiply(Growth::Logarithmic),
            Growth::Logarithmic
        );
        assert_eq!(Growth::Unknown.max(Growth::Linear), Growth::Unknown);
    }

    #[test]
    fn sqlite_plan_combines_joins_and_temporary_sort_space() {
        let rows = vec![
            SqlitePlanRow {
                id: 3,
                parent: 0,
                detail: "SCAN users".into(),
            },
            SqlitePlanRow {
                id: 7,
                parent: 0,
                detail: "SEARCH orders USING INDEX idx_orders_user (user_id=?)".into(),
            },
            SqlitePlanRow {
                id: 20,
                parent: 0,
                detail: "USE TEMP B-TREE FOR ORDER BY".into(),
            },
        ];
        let result = analyze_sqlite_plan(&rows);
        assert_eq!(result.time, Growth::Product);
        assert_eq!(result.auxiliary_space, Growth::Linear);
        assert!(result
            .warnings
            .iter()
            .any(|warning| warning.rule_id == "SQL_SCAN"));
        assert!(result
            .warnings
            .iter()
            .any(|warning| warning.rule_id == "SQL_SORT"));
    }

    #[test]
    fn postgres_json_handles_hash_join_sort_and_index_only_scan() {
        let plan = json!([{"Plan": {
            "Node Type": "Sort",
            "Plans": [{
                "Node Type": "Hash Join",
                "Plans": [
                    {"Node Type": "Seq Scan", "Relation Name": "users"},
                    {"Node Type": "Hash", "Plans": [{"Node Type": "Index Only Scan", "Relation Name": "orders"}]}
                ]
            }]
        }}]);
        let result = analyze_postgres_plan(&plan).unwrap();
        assert_eq!(result.time, Growth::Linearithmic);
        assert_eq!(result.auxiliary_space, Growth::Linear);
        assert!(result.triggers.contains(&"postgres hash join".to_string()));
    }

    #[test]
    fn postgres_json_multiplies_nested_loop_children() {
        let plan = json!([{"Plan": {
            "Node Type": "Nested Loop",
            "Plans": [
                {"Node Type": "Seq Scan", "Relation Name": "users"},
                {"Node Type": "Seq Scan", "Relation Name": "orders"}
            ]
        }}]);
        let result = analyze_postgres_plan(&plan).unwrap();
        assert_eq!(result.time, Growth::Product);
    }

    #[test]
    fn postgres_correlated_subplan_is_multiplied_by_outer_scan() {
        let plan = json!([{"Plan": {
            "Node Type": "Seq Scan",
            "Relation Name": "users",
            "Plans": [{
                "Node Type": "Index Scan",
                "Parent Relationship": "SubPlan",
                "Relation Name": "orders"
            }]
        }}]);
        let result = analyze_postgres_plan(&plan).unwrap();
        assert_eq!(result.time, Growth::Product);
        assert!(result.triggers.contains(&"postgres correlated subplan".to_string()));
    }

    #[test]
    fn sqlite_access_modes_distinguish_scans_covering_and_heap_lookups() {
        let scan = analyze_sqlite_plan(&[SqlitePlanRow {
            id: 1,
            parent: 0,
            detail: "SCAN users USING COVERING INDEX users_name".into(),
        }]);
        assert_eq!(scan.time, Growth::Linear);
        assert_eq!(scan.warnings[0].rule_id, "SQL_INDEX_SCAN");

        let covering = analyze_sqlite_plan(&[SqlitePlanRow {
            id: 1,
            parent: 0,
            detail: "SEARCH users USING COVERING INDEX users_name (name=?)".into(),
        }]);
        assert_eq!(covering.time, Growth::LogarithmicPlusOutput);
        assert!(covering.warnings.is_empty());

        let heap = analyze_sqlite_plan(&[SqlitePlanRow {
            id: 1,
            parent: 0,
            detail: "SEARCH users USING INDEX users_name (name=?)".into(),
        }]);
        assert_eq!(heap.warnings[0].rule_id, "SQL_NON_COVERING_INDEX");
    }

    #[test]
    fn mysql_json_handles_nested_loop_and_filesort() {
        let plan = json!({"query_block": {
            "ordering_operation": {
                "using_filesort": true,
                "nested_loop": [
                    {"table": {"table_name": "users", "access_type": "ALL"}},
                    {"table": {"table_name": "orders", "access_type": "ref", "using_index": false}}
                ]
            }
        }});
        let result = analyze_mysql_plan(&plan).unwrap();
        assert_eq!(result.time, Growth::Product);
        assert_eq!(result.auxiliary_space, Growth::Linear);
        assert!(result.triggers.contains(&"mysql filesort".to_string()));
    }

    #[test]
    fn mysql_access_modes_and_temporary_tables_are_classified() {
        let cases = [
            ("ALL", Growth::Linear, Some("SQL_SCAN")),
            ("index", Growth::Linear, Some("SQL_INDEX_SCAN")),
            ("range", Growth::LogarithmicPlusOutput, Some("SQL_NON_COVERING_INDEX")),
            ("const", Growth::Constant, None),
            ("unrecognized", Growth::Unknown, None),
        ];
        for (access_type, expected, warning) in cases {
            let plan = json!({"query_block": {"table": {
                "table_name": "users", "access_type": access_type
            }}});
            let result = analyze_mysql_plan(&plan).unwrap();
            assert_eq!(result.time, expected, "access type {access_type}");
            assert_eq!(result.warnings.first().map(|item| item.rule_id.as_str()), warning);
        }

        let temporary = analyze_mysql_plan(&json!({"query_block": {
            "using_temporary_table": true,
            "table": {"table_name": "users", "access_type": "ALL"}
        }}))
        .unwrap();
        assert_eq!(temporary.auxiliary_space, Growth::Linear);
        assert!(temporary.triggers.contains(&"mysql temporary table".to_string()));
    }

    #[test]
    fn canonical_sarif_contains_one_summary_and_operator_provenance() {
        let observation = QueryPlanObservation {
            path: "queries/users.sql".into(),
            query_id: "users.list.v1".into(),
            dialect: DialectName::Sqlite,
            complexity: PlanComplexity {
                time: Growth::Linear,
                auxiliary_space: Growth::Constant,
                triggers: vec!["sqlite sequential scan".into()],
                warnings: vec![scan_warning(Some("users".into()), false)],
            },
            explain: "SCAN users".into(),
        };
        let value: Value = serde_json::from_str(&plan_sarif(&[observation]).unwrap()).unwrap();
        let results = value["runs"][0]["results"].as_array().unwrap();
        assert_eq!(
            results
                .iter()
                .filter(|result| result["ruleId"] == COMPLEXITY_RULE_ID)
                .count(),
            1
        );
        assert_eq!(results[0]["properties"]["complexity"]["time"], "O(N)");
        assert_eq!(value["runs"][0]["properties"]["format"], PLAN_SARIF_FORMAT);
        assert_eq!(
            value["runs"][0]["tool"]["driver"]["rules"]
                .as_array()
                .unwrap()
                .len(),
            5
        );
        assert_eq!(
            results[0]["partialFingerprints"]["queryId"],
            "users.list.v1"
        );
    }

    #[test]
    fn query_id_prefers_stable_source_annotation() {
        assert_eq!(
            query_id(
                Path::new("fallback.sql"),
                "-- query-id: storage.users.v1\nSELECT 1"
            ),
            "storage.users.v1"
        );
        assert_eq!(query_id(Path::new("fallback.sql"), "SELECT 1"), "fallback");
    }
}
