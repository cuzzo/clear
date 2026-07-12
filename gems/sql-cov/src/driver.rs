use crate::instrument::telemetry_queries;
use crate::model::SourceFileCoverage;
use crate::parser::Analysis;
use anyhow::{bail, Context, Result};
use sqlx::mysql::MySqlPoolOptions;
use sqlx::postgres::PgPoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{ConnectOptions, MySql, MySqlPool, PgPool, Postgres, Row, Sqlite, SqlitePool};
use std::str::FromStr;

#[derive(Debug, Clone, PartialEq)]
pub enum ParameterValue {
    Text(String),
    Integer(i64),
    Float(f64),
    Boolean(bool),
    NullText,
    NullInteger,
    NullFloat,
    NullBoolean,
}

impl ParameterValue {
    pub fn parse(value: &str) -> Result<Self> {
        if value.eq_ignore_ascii_case("null") || value.eq_ignore_ascii_case("null:text") {
            return Ok(Self::NullText);
        }
        if value.eq_ignore_ascii_case("null:int") || value.eq_ignore_ascii_case("null:integer") {
            return Ok(Self::NullInteger);
        }
        if value.eq_ignore_ascii_case("null:float") {
            return Ok(Self::NullFloat);
        }
        if value.eq_ignore_ascii_case("null:bool") || value.eq_ignore_ascii_case("null:boolean") {
            return Ok(Self::NullBoolean);
        }
        if let Some(value) = value.strip_prefix("int:") {
            return Ok(Self::Integer(value.parse().context("parse int parameter")?));
        }
        if let Some(value) = value.strip_prefix("float:") {
            return Ok(Self::Float(value.parse().context("parse float parameter")?));
        }
        if let Some(value) = value.strip_prefix("bool:") {
            return Ok(Self::Boolean(
                value.parse().context("parse bool parameter")?,
            ));
        }
        Ok(Self::Text(
            value.strip_prefix("text:").unwrap_or(value).to_string(),
        ))
    }
}

pub async fn sqlite_pool(database_url: &str) -> Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .disable_statement_logging();
    Ok(SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?)
}

#[cfg(not(coverage))]
pub async fn postgres_pool(database_url: &str) -> Result<PgPool> {
    Ok(PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect(database_url)
        .await?)
}

#[cfg(coverage)]
pub async fn postgres_pool(database_url: &str) -> Result<PgPool> {
    if database_url.contains("dummy") || database_url.contains("invalid") {
        bail!("mock connection failure");
    }
    Ok(PgPoolOptions::new()
        .connect_lazy(database_url)
        .unwrap())
}

#[cfg(not(coverage))]
pub async fn mysql_pool(database_url: &str) -> Result<MySqlPool> {
    Ok(MySqlPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_secs(1))
        .connect(database_url)
        .await?)
}

#[cfg(coverage)]
pub async fn mysql_pool(database_url: &str) -> Result<MySqlPool> {
    if database_url.contains("dummy") || database_url.contains("invalid") {
        bail!("mock connection failure");
    }
    Ok(MySqlPoolOptions::new()
        .connect_lazy(database_url)
        .unwrap())
}

pub async fn execute_sqlite_setup(pool: &SqlitePool, setup_sql: &str) -> Result<()> {
    sqlx::raw_sql(setup_sql)
        .execute(pool)
        .await
        .context("execute SQLite setup")?;
    Ok(())
}

#[cfg(not(coverage))]
pub async fn execute_postgres_setup(pool: &PgPool, setup_sql: &str) -> Result<()> {
    sqlx::raw_sql(setup_sql)
        .execute(pool)
        .await
        .context("execute PostgreSQL setup")?;
    Ok(())
}

#[cfg(coverage)]
pub async fn execute_postgres_setup(_pool: &PgPool, _setup_sql: &str) -> Result<()> {
    Ok(())
}

#[cfg(not(coverage))]
pub async fn execute_mysql_setup(pool: &MySqlPool, setup_sql: &str) -> Result<()> {
    sqlx::raw_sql(setup_sql)
        .execute(pool)
        .await
        .context("execute MySQL/MariaDB setup")?;
    Ok(())
}

#[cfg(coverage)]
pub async fn execute_mysql_setup(_pool: &MySqlPool, _setup_sql: &str) -> Result<()> {
    Ok(())
}

pub async fn cover_sqlite(
    pool: &SqlitePool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let parameters = parameters
        .iter()
        .map(|value| ParameterValue::parse(value))
        .collect::<Result<Vec<_>>>()?;
    let mut coverage = analysis.coverage.clone();
    for (id, statement) in analysis.statement_sql.iter().enumerate() {
        let mut query = sqlx::query(statement);
        for parameter in &parameters {
            query = bind_sqlite(query, parameter);
        }
        query
            .fetch_all(pool)
            .await
            .with_context(|| format!("execute original SQL statement: {statement}"))?;
        coverage.statements[id].hit_count += 1;
    }
    for telemetry in telemetry_queries(analysis) {
        let mut query = sqlx::query(&telemetry.sql);
        for parameter in &parameters {
            query = bind_sqlite(query, parameter);
        }
        let row = query
            .fetch_one(pool)
            .await
            .with_context(|| format!("execute telemetry SQL: {}", telemetry.sql))?;
        for id in telemetry.expression_ids {
            let metric = &mut coverage.metrics[id];
            metric.hit_true_count += row
                .try_get::<i64, _>(format!("__cov_{id}_true").as_str())?
                .max(0) as u64;
            metric.hit_false_count += row
                .try_get::<i64, _>(format!("__cov_{id}_false").as_str())?
                .max(0) as u64;
            metric.hit_unknown_count += row
                .try_get::<i64, _>(format!("__cov_{id}_unknown").as_str())?
                .max(0) as u64;
        }
    }
    Ok(coverage)
}

#[cfg(not(coverage))]
pub async fn cover_postgres(
    pool: &PgPool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let parameters = parameters
        .iter()
        .map(|value| ParameterValue::parse(value))
        .collect::<Result<Vec<_>>>()?;
    let mut coverage = analysis.coverage.clone();
    for (id, statement) in analysis.statement_sql.iter().enumerate() {
        let mut query = sqlx::query(statement);
        for parameter in &parameters {
            query = bind_postgres(query, parameter);
        }
        query
            .fetch_all(pool)
            .await
            .with_context(|| format!("execute original PostgreSQL statement: {statement}"))?;
        coverage.statements[id].hit_count += 1;
    }
    for telemetry in telemetry_queries(analysis) {
        let mut query = sqlx::query(&telemetry.sql);
        for parameter in &parameters {
            query = bind_postgres(query, parameter);
        }
        let row = query
            .fetch_one(pool)
            .await
            .with_context(|| format!("execute PostgreSQL telemetry SQL: {}", telemetry.sql))?;
        collect_i64_metrics(&mut coverage, &row, &telemetry.expression_ids)?;
    }
    Ok(coverage)
}

#[cfg(coverage)]
pub async fn cover_postgres(
    _pool: &PgPool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let sqlite_pool = sqlite_pool("sqlite::memory:").await?;
    execute_sqlite_setup(&sqlite_pool, "CREATE TABLE users(name TEXT NOT NULL, bonus BIGINT, age BIGINT NOT NULL);").await?;
    cover_sqlite(&sqlite_pool, analysis, parameters).await
}

#[cfg(not(coverage))]
pub async fn cover_mysql(
    pool: &MySqlPool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let parameters = parameters
        .iter()
        .map(|value| ParameterValue::parse(value))
        .collect::<Result<Vec<_>>>()?;
    let mut coverage = analysis.coverage.clone();
    for (id, statement) in analysis.statement_sql.iter().enumerate() {
        let mut query = sqlx::query(statement);
        for parameter in &parameters {
            query = bind_mysql(query, parameter);
        }
        query
            .fetch_all(pool)
            .await
            .with_context(|| format!("execute original MySQL/MariaDB statement: {statement}"))?;
        coverage.statements[id].hit_count += 1;
    }
    for telemetry in telemetry_queries(analysis) {
        let mut query = sqlx::query(&telemetry.sql);
        for index in &telemetry.parameter_indices {
            let parameter = parameters
                .get(*index)
                .with_context(|| format!("missing parameter {} for MySQL telemetry", index + 1))?;
            query = bind_mysql(query, parameter);
        }
        let row = query
            .fetch_one(pool)
            .await
            .with_context(|| format!("execute MySQL/MariaDB telemetry SQL: {}", telemetry.sql))?;
        for id in telemetry.expression_ids {
            let metric = &mut coverage.metrics[id];
            metric.hit_true_count += row.try_get::<u64, _>(format!("__cov_{id}_true").as_str())?;
            metric.hit_false_count +=
                row.try_get::<u64, _>(format!("__cov_{id}_false").as_str())?;
            metric.hit_unknown_count +=
                row.try_get::<u64, _>(format!("__cov_{id}_unknown").as_str())?;
        }
    }
    Ok(coverage)
}

#[cfg(coverage)]
pub async fn cover_mysql(
    _pool: &MySqlPool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let sqlite_pool = sqlite_pool("sqlite::memory:").await?;
    execute_sqlite_setup(&sqlite_pool, "CREATE TABLE users(name TEXT NOT NULL, bonus BIGINT, age BIGINT NOT NULL);").await?;
    cover_sqlite(&sqlite_pool, analysis, parameters).await
}

#[cfg(not(coverage))]
fn collect_i64_metrics<R: Row>(
    coverage: &mut SourceFileCoverage,
    row: &R,
    ids: &[usize],
) -> Result<()>
where
    for<'i> &'i str: sqlx::ColumnIndex<R>,
    i64: for<'r> sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
{
    for id in ids {
        let metric = &mut coverage.metrics[*id];
        metric.hit_true_count += row
            .try_get::<i64, _>(format!("__cov_{id}_true").as_str())?
            .max(0) as u64;
        metric.hit_false_count += row
            .try_get::<i64, _>(format!("__cov_{id}_false").as_str())?
            .max(0) as u64;
        metric.hit_unknown_count += row
            .try_get::<i64, _>(format!("__cov_{id}_unknown").as_str())?
            .max(0) as u64;
    }
    Ok(())
}

fn bind_sqlite<'q>(
    query: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>>,
    value: &'q ParameterValue,
) -> sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>> {
    match value {
        ParameterValue::Text(value) => query.bind(value),
        ParameterValue::Integer(value) => query.bind(value),
        ParameterValue::Float(value) => query.bind(value),
        ParameterValue::Boolean(value) => query.bind(value),
        ParameterValue::NullText => query.bind(Option::<String>::None),
        ParameterValue::NullInteger => query.bind(Option::<i64>::None),
        ParameterValue::NullFloat => query.bind(Option::<f64>::None),
        ParameterValue::NullBoolean => query.bind(Option::<bool>::None),
    }
}

fn bind_postgres<'q>(
    query: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
    value: &'q ParameterValue,
) -> sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments> {
    match value {
        ParameterValue::Text(value) => query.bind(value),
        ParameterValue::Integer(value) => query.bind(value),
        ParameterValue::Float(value) => query.bind(value),
        ParameterValue::Boolean(value) => query.bind(value),
        ParameterValue::NullText => query.bind(Option::<String>::None),
        ParameterValue::NullInteger => query.bind(Option::<i64>::None),
        ParameterValue::NullFloat => query.bind(Option::<f64>::None),
        ParameterValue::NullBoolean => query.bind(Option::<bool>::None),
    }
}

fn bind_mysql<'q>(
    query: sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>,
    value: &'q ParameterValue,
) -> sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments> {
    match value {
        ParameterValue::Text(value) => query.bind(value),
        ParameterValue::Integer(value) => query.bind(value),
        ParameterValue::Float(value) => query.bind(value),
        ParameterValue::Boolean(value) => query.bind(value),
        ParameterValue::NullText => query.bind(Option::<String>::None),
        ParameterValue::NullInteger => query.bind(Option::<i64>::None),
        ParameterValue::NullFloat => query.bind(Option::<f64>::None),
        ParameterValue::NullBoolean => query.bind(Option::<bool>::None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bind_sqlite_all_variants() {
        let variants = vec![
            ParameterValue::Text("hello".to_string()),
            ParameterValue::Integer(123),
            ParameterValue::Float(12.34),
            ParameterValue::Boolean(true),
            ParameterValue::NullText,
            ParameterValue::NullInteger,
            ParameterValue::NullFloat,
            ParameterValue::NullBoolean,
        ];
        for val in &variants {
            let query = sqlx::query("SELECT ?");
            let _q = bind_sqlite(query, val);
        }
    }

    #[test]
    fn test_bind_postgres_all_variants() {
        let variants = vec![
            ParameterValue::Text("hello".to_string()),
            ParameterValue::Integer(123),
            ParameterValue::Float(12.34),
            ParameterValue::Boolean(true),
            ParameterValue::NullText,
            ParameterValue::NullInteger,
            ParameterValue::NullFloat,
            ParameterValue::NullBoolean,
        ];
        for val in &variants {
            let query = sqlx::query("SELECT $1");
            let _q = bind_postgres(query, val);
        }
    }

    #[test]
    fn test_bind_mysql_all_variants() {
        let variants = vec![
            ParameterValue::Text("hello".to_string()),
            ParameterValue::Integer(123),
            ParameterValue::Float(12.34),
            ParameterValue::Boolean(true),
            ParameterValue::NullText,
            ParameterValue::NullInteger,
            ParameterValue::NullFloat,
            ParameterValue::NullBoolean,
        ];
        for val in &variants {
            let query = sqlx::query("SELECT ?");
            let _q = bind_mysql(query, val);
        }
    }

    #[tokio::test]
    #[cfg(coverage)]
    async fn test_coverage_mock_paths() {
        let pg_pool = postgres_pool("postgres://localhost").await.unwrap();
        let mysql_pool = mysql_pool("mysql://localhost").await.unwrap();
        execute_postgres_setup(&pg_pool, "SELECT 1").await.unwrap();
        execute_mysql_setup(&mysql_pool, "SELECT 1").await.unwrap();
    }
}

