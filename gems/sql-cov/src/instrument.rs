use crate::parser::{Analysis, TelemetryDomain};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelemetryQuery {
    pub sql: String,
    pub expression_ids: Vec<usize>,
    pub parameter_indices: Vec<usize>,
}

pub fn telemetry_queries(analysis: &Analysis) -> Vec<TelemetryQuery> {
    analysis
        .domains
        .iter()
        .filter_map(|domain| telemetry_query(analysis, domain))
        .collect()
}

fn telemetry_query(analysis: &Analysis, domain: &TelemetryDomain) -> Option<TelemetryQuery> {
    if domain.expression_ids.is_empty() {
        return None;
    }
    let metrics = domain
        .expression_ids
        .iter()
        .filter_map(|id| {
            analysis
                .coverage
                .metrics
                .get(*id)
                .map(|metric| (*id, metric))
        })
        .collect::<Vec<_>>();
    let inner = metrics
        .iter()
        .map(|(id, metric)| format!("({}) AS __cov_{id}", metric.span.normalized_expression))
        .collect::<Vec<_>>();
    let projections = metrics
        .iter()
        .flat_map(|(id, _)| {
            [
                format!("COUNT(CASE WHEN __cov_{id} IS TRUE THEN 1 END) AS __cov_{id}_true"),
                format!("COUNT(CASE WHEN __cov_{id} IS FALSE THEN 1 END) AS __cov_{id}_false"),
                format!("COUNT(CASE WHEN __cov_{id} IS NULL THEN 1 END) AS __cov_{id}_unknown"),
            ]
        })
        .collect::<Vec<_>>();
    let parameter_indices = metrics
        .iter()
        .flat_map(|(_, metric)| metric.span.parameter_indices.iter().copied())
        .collect();
    let from = if domain.from_sql.trim().is_empty() {
        String::new()
    } else {
        format!(" FROM {}", domain.from_sql)
    };
    let with = if domain.with_sql.is_empty() {
        String::new()
    } else {
        format!("{} ", domain.with_sql)
    };
    Some(TelemetryQuery {
        sql: format!(
            "{with}SELECT {} FROM (SELECT {}{}) AS __cov_raw",
            projections.join(", "),
            inner.join(", "),
            from
        ),
        expression_ids: domain.expression_ids.clone(),
        parameter_indices,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::SourceFileCoverage;
    use crate::parser::{Analysis, TelemetryDomain};

    #[test]
    fn test_telemetry_query_empty_expression_ids() {
        let analysis = Analysis {
            domains: vec![TelemetryDomain {
                expression_ids: vec![],
                from_sql: "users".to_string(),
                with_sql: "".to_string(),
            }],
            coverage: SourceFileCoverage {
                format: "sql-cov/v1".to_string(),
                file_path: "test.sql".to_string(),
                dialect: "sqlite".to_string(),
                raw_source: "".to_string(),
                statements: vec![],
                metrics: vec![],
                unsupported: vec![],
            },
            statement_sql: vec![],
        };
        let queries = telemetry_queries(&analysis);
        assert!(queries.is_empty());
    }

    #[test]
    fn test_telemetry_query_empty_from_sql() {
        let mut metrics = vec![];
        metrics.push(crate::model::CoverageMetric {
            span: crate::model::ExpressionSpan {
                id: 0,
                start_offset: 0,
                end_offset: 1,
                start_line: 1,
                start_column: 1,
                end_line: 1,
                end_column: 2,
                raw_expression: "1".to_string(),
                normalized_expression: "1".to_string(),
                context: "".to_string(),
                nullable: false,
                parameter_indices: vec![],
            },
            measurable: true,
            hit_true_count: 0,
            hit_false_count: 0,
            hit_unknown_count: 0,
        });

        let analysis = Analysis {
            domains: vec![TelemetryDomain {
                expression_ids: vec![0],
                from_sql: "".to_string(),
                with_sql: "".to_string(),
            }],
            coverage: SourceFileCoverage {
                format: "sql-cov/v1".to_string(),
                file_path: "test.sql".to_string(),
                dialect: "sqlite".to_string(),
                raw_source: "".to_string(),
                statements: vec![],
                metrics,
                unsupported: vec![],
            },
            statement_sql: vec![],
        };
        let queries = telemetry_queries(&analysis);
        assert_eq!(queries.len(), 1);
        assert_eq!(queries[0].sql, "SELECT COUNT(CASE WHEN __cov_0 IS TRUE THEN 1 END) AS __cov_0_true, COUNT(CASE WHEN __cov_0 IS FALSE THEN 1 END) AS __cov_0_false, COUNT(CASE WHEN __cov_0 IS NULL THEN 1 END) AS __cov_0_unknown FROM (SELECT (1) AS __cov_0) AS __cov_raw");
    }
}
