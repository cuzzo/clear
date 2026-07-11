use crate::parser::{Analysis, TelemetryDomain};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelemetryQuery {
    pub sql: String,
    pub expression_ids: Vec<usize>,
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
    let projections = domain
        .expression_ids
        .iter()
        .filter_map(|id| {
            analysis
                .coverage
                .metrics
                .get(*id)
                .map(|metric| (*id, metric))
        })
        .flat_map(|(id, metric)| {
            let expression = &metric.span.normalized_expression;
            [
                format!(
                    "SUM(CASE WHEN ({expression}) IS TRUE THEN 1 ELSE 0 END) AS __cov_{id}_true"
                ),
                format!(
                    "SUM(CASE WHEN ({expression}) IS FALSE THEN 1 ELSE 0 END) AS __cov_{id}_false"
                ),
                format!(
                    "SUM(CASE WHEN ({expression}) IS NULL THEN 1 ELSE 0 END) AS __cov_{id}_unknown"
                ),
            ]
        })
        .collect::<Vec<_>>();
    let from = if domain.from_sql.trim().is_empty() {
        String::new()
    } else {
        format!(" FROM {}", domain.from_sql)
    };
    Some(TelemetryQuery {
        sql: format!("SELECT {}{}", projections.join(", "), from),
        expression_ids: domain.expression_ids.clone(),
    })
}
