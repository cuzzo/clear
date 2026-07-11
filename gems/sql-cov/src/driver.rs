use crate::instrument::telemetry_queries;
use crate::model::SourceFileCoverage;
use crate::parser::Analysis;
use anyhow::{Context, Result};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{ConnectOptions, Row, SqlitePool};
use std::str::FromStr;

pub async fn sqlite_pool(database_url: &str) -> Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .disable_statement_logging();
    Ok(SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?)
}

pub async fn execute_sqlite_setup(pool: &SqlitePool, setup_sql: &str) -> Result<()> {
    sqlx::raw_sql(setup_sql)
        .execute(pool)
        .await
        .context("execute SQLite setup")?;
    Ok(())
}

pub async fn cover_sqlite(
    pool: &SqlitePool,
    analysis: &Analysis,
    parameters: &[String],
) -> Result<SourceFileCoverage> {
    let mut coverage = analysis.coverage.clone();
    for telemetry in telemetry_queries(analysis) {
        let mut query = sqlx::query(&telemetry.sql);
        for parameter in parameters {
            query = query.bind(parameter);
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
