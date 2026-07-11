use crate::model::{CoverageMetric, ExpressionSpan, SourceFileCoverage};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    BinaryOperator, Expr, JoinConstraint, JoinOperator, SetExpr, Spanned, Statement, Visit, Visitor,
};
use sqlparser::dialect::{Dialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use std::ops::ControlFlow;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DialectName {
    Sqlite,
    Postgres,
}

impl DialectName {
    pub fn parse(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "sqlite" | "sqlite3" => Ok(Self::Sqlite),
            "postgres" | "postgresql" | "pg" => Ok(Self::Postgres),
            other => bail!("unsupported SQL dialect {other:?}; use sqlite or postgres"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::Postgres => "postgres",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TelemetryDomain {
    pub from_sql: String,
    pub expression_ids: Vec<usize>,
}

#[derive(Debug, Clone)]
pub struct Analysis {
    pub coverage: SourceFileCoverage,
    pub domains: Vec<TelemetryDomain>,
}

pub fn analyze_sql(file_path: &str, source: &str, dialect: DialectName) -> Result<Analysis> {
    let dialect_impl: Box<dyn Dialect> = match dialect {
        DialectName::Sqlite => Box::new(SQLiteDialect {}),
        DialectName::Postgres => Box::new(PostgreSqlDialect {}),
    };
    let statements = Parser::parse_sql(dialect_impl.as_ref(), source)
        .with_context(|| format!("parse SQL in {file_path}"))?;
    let mut metrics = Vec::new();
    let mut domains = Vec::new();
    let mut unsupported = Vec::new();

    for statement in &statements {
        let Statement::Query(query) = statement else {
            unsupported.push(format!(
                "statement {} is parsed but not executable coverage input",
                statement
            ));
            continue;
        };
        let SetExpr::Select(select) = query.body.as_ref() else {
            unsupported.push(
                "set operations and non-SELECT query bodies are not instrumented yet".to_string(),
            );
            continue;
        };
        let from_sql = select
            .from
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ");
        if let Some(selection) = &select.selection {
            let ids = collect_exprs(selection, "where", true, source, &mut metrics)?;
            domains.push(TelemetryDomain {
                from_sql: from_sql.clone(),
                expression_ids: ids,
            });
        }
        if let Some(having) = &select.having {
            collect_exprs(having, "having", false, source, &mut metrics)?;
            unsupported.push(
                "HAVING expressions are mapped but not executed in the initial telemetry driver"
                    .to_string(),
            );
        }
        for table in &select.from {
            for join in &table.joins {
                if let Some(expr) = join_expression(&join.join_operator) {
                    collect_exprs(expr, "join", false, source, &mut metrics)?;
                    unsupported.push("JOIN ON expressions are mapped but false pre-join rows require a dialect-specific telemetry strategy".to_string());
                }
            }
        }
    }

    unsupported.sort();
    unsupported.dedup();
    Ok(Analysis {
        coverage: SourceFileCoverage {
            format: "sql-cov/v1".to_string(),
            file_path: file_path.to_string(),
            dialect: dialect.as_str().to_string(),
            raw_source: source.to_string(),
            metrics,
            unsupported,
        },
        domains,
    })
}

fn collect_exprs(
    root: &Expr,
    context: &str,
    measurable: bool,
    source: &str,
    metrics: &mut Vec<CoverageMetric>,
) -> Result<Vec<usize>> {
    let mut visitor = ExpressionVisitor {
        context,
        source,
        rows: Vec::new(),
    };
    let _ = root.visit(&mut visitor);
    let mut ids = Vec::new();
    for mut span in visitor.rows {
        if let Some(existing) = metrics.iter().find(|metric| {
            metric.span.start_offset == span.start_offset
                && metric.span.end_offset == span.end_offset
                && metric.span.context == span.context
        }) {
            ids.push(existing.span.id);
            continue;
        }
        span.id = metrics.len();
        ids.push(span.id);
        metrics.push(CoverageMetric {
            span,
            measurable,
            hit_true_count: 0,
            hit_false_count: 0,
            hit_unknown_count: 0,
        });
    }
    Ok(ids)
}

struct ExpressionVisitor<'a> {
    context: &'a str,
    source: &'a str,
    rows: Vec<ExpressionSpan>,
}

impl Visitor for ExpressionVisitor<'_> {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        if is_coverage_expression(expr) {
            if let Some(span) = expression_span(expr, self.context, self.source) {
                self.rows.push(span);
            }
        }
        ControlFlow::Continue(())
    }
}

fn is_coverage_expression(expr: &Expr) -> bool {
    match expr {
        Expr::BinaryOp { op, .. } => matches!(
            op,
            BinaryOperator::Gt
                | BinaryOperator::Lt
                | BinaryOperator::GtEq
                | BinaryOperator::LtEq
                | BinaryOperator::Spaceship
                | BinaryOperator::Eq
                | BinaryOperator::NotEq
                | BinaryOperator::And
                | BinaryOperator::Or
                | BinaryOperator::Xor
        ),
        Expr::InList { .. }
        | Expr::InSubquery { .. }
        | Expr::Between { .. }
        | Expr::IsNull(_)
        | Expr::IsNotNull(_)
        | Expr::IsTrue(_)
        | Expr::IsFalse(_)
        | Expr::IsUnknown(_)
        | Expr::IsNotUnknown(_)
        | Expr::IsDistinctFrom(_, _)
        | Expr::IsNotDistinctFrom(_, _)
        | Expr::Like { .. }
        | Expr::ILike { .. }
        | Expr::SimilarTo { .. } => true,
        _ => false,
    }
}

fn expression_span(expr: &Expr, context: &str, source: &str) -> Option<ExpressionSpan> {
    let parser_span = expr.span();
    if parser_span.start.line == 0 || parser_span.end.line == 0 {
        return None;
    }
    let start_offset = location_offset(
        source,
        parser_span.start.line as usize,
        parser_span.start.column as usize,
    )?;
    let end_offset = location_offset(
        source,
        parser_span.end.line as usize,
        parser_span.end.column as usize,
    )?;
    let raw = source.get(start_offset..end_offset)?.to_string();
    Some(ExpressionSpan {
        id: 0,
        start_offset,
        end_offset,
        start_line: parser_span.start.line as usize,
        start_column: parser_span.start.column as usize,
        end_line: parser_span.end.line as usize,
        end_column: parser_span.end.column as usize,
        raw_expression: raw,
        normalized_expression: expr.to_string(),
        context: context.to_string(),
        nullable: !matches!(
            expr,
            Expr::IsNull(_)
                | Expr::IsNotNull(_)
                | Expr::IsTrue(_)
                | Expr::IsFalse(_)
                | Expr::IsUnknown(_)
                | Expr::IsNotUnknown(_)
                | Expr::IsDistinctFrom(_, _)
                | Expr::IsNotDistinctFrom(_, _)
        ),
    })
}

fn location_offset(source: &str, line: usize, column: usize) -> Option<usize> {
    if line == 0 || column == 0 {
        return None;
    }
    let line_start = source
        .split_inclusive('\n')
        .take(line.saturating_sub(1))
        .map(str::len)
        .sum::<usize>();
    let line_text = source.get(line_start..)?.split('\n').next()?;
    let column_offset = line_text
        .char_indices()
        .nth(column.saturating_sub(1))
        .map(|(offset, _)| offset)
        .or_else(|| (column == line_text.chars().count() + 1).then_some(line_text.len()))?;
    Some(line_start + column_offset)
}

fn join_expression(operator: &JoinOperator) -> Option<&Expr> {
    let constraint = match operator {
        JoinOperator::Join(value)
        | JoinOperator::Inner(value)
        | JoinOperator::Left(value)
        | JoinOperator::LeftOuter(value)
        | JoinOperator::Right(value)
        | JoinOperator::RightOuter(value)
        | JoinOperator::FullOuter(value)
        | JoinOperator::CrossJoin(value)
        | JoinOperator::Semi(value)
        | JoinOperator::LeftSemi(value)
        | JoinOperator::RightSemi(value)
        | JoinOperator::Anti(value)
        | JoinOperator::LeftAnti(value)
        | JoinOperator::RightAnti(value)
        | JoinOperator::StraightJoin(value) => value,
        _ => return None,
    };
    match constraint {
        JoinConstraint::On(expr) => Some(expr),
        _ => None,
    }
}
