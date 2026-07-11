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
