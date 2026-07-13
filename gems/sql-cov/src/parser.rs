use crate::model::{CoverageMetric, ExpressionSpan, SourceFileCoverage, StatementCoverage};
use crate::nullability::{register_factor, Resolver};
use crate::schema::SchemaCatalog;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    BinaryOperator, Expr, JoinConstraint, JoinOperator, SetExpr, Spanned, Statement, Visit, Visitor,
};
use sqlparser::dialect::{Dialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use std::ops::ControlFlow;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DialectName {
    Sqlite,
    Postgres,
    Mysql,
}

impl DialectName {
    pub fn parse(value: &str) -> Result<Self> {
        match value.to_ascii_lowercase().as_str() {
            "sqlite" | "sqlite3" => Ok(Self::Sqlite),
            "postgres" | "postgresql" | "pg" => Ok(Self::Postgres),
            "mysql" | "mariadb" | "maria" => Ok(Self::Mysql),
            other => {
                bail!("unsupported SQL dialect {other:?}; use sqlite, postgres, mysql, or mariadb")
            }
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::Postgres => "postgres",
            Self::Mysql => "mysql",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TelemetryDomain {
    pub with_sql: String,
    pub from_sql: String,
    pub expression_ids: Vec<usize>,
}

#[derive(Debug, Clone)]
pub struct Analysis {
    pub coverage: SourceFileCoverage,
    pub domains: Vec<TelemetryDomain>,
    pub statement_sql: Vec<String>,
}

pub fn analyze_sql(
    file_path: &str,
    source: &str,
    dialect: DialectName,
    schema: Option<&SchemaCatalog>,
) -> Result<Analysis> {
    let dialect_impl: Box<dyn Dialect> = match dialect {
        DialectName::Sqlite => Box::new(SQLiteDialect {}),
        DialectName::Postgres => Box::new(PostgreSqlDialect {}),
        DialectName::Mysql => Box::new(MySqlDialect {}),
    };
    let statements = Parser::parse_sql(dialect_impl.as_ref(), source)
        .with_context(|| format!("parse SQL in {file_path}"))?;
    let mut metrics = Vec::new();
    let mut domains = Vec::new();
    let mut unsupported = Vec::new();
    let mut statement_coverage = Vec::new();
    let mut statement_sql = Vec::new();

    let dummy_schema = SchemaCatalog::default();
    let schema_ref = schema.unwrap_or(&dummy_schema);

    for (statement_id, statement) in statements.iter().enumerate() {
        let span = statement.span();
        statement_coverage.push(StatementCoverage {
            id: statement_id,
            start_line: span.start.line.max(1) as usize,
            end_line: span.end.line.max(span.start.line).max(1) as usize,
            hit_count: 0,
            normalized_sql: statement.to_string(),
        });
        statement_sql.push(statement.to_string());
        let Statement::Query(query) = statement else {
            unsupported.push(format!(
                "statement {} is parsed but not executable coverage input",
                statement
            ));
            continue;
        };

        let resolver = Resolver::new(schema_ref);
        traverse_query(
            query,
            &resolver,
            schema,
            source,
            &mut metrics,
            &mut domains,
            &mut unsupported,
        );
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
            statements: statement_coverage,
            unsupported,
        },
        domains,
        statement_sql,
    })
}

fn traverse_query(
    query: &sqlparser::ast::Query,
    outer_resolver: &Resolver<'_>,
    schema: Option<&SchemaCatalog>,
    source: &str,
    metrics: &mut Vec<CoverageMetric>,
    domains: &mut Vec<TelemetryDomain>,
    unsupported: &mut Vec<String>,
) {
    let mut local_resolver = outer_resolver.clone();
    let with_clause = &query.with;
    if let Some(with) = with_clause {
        for cte in &with.cte_tables {
            let name = crate::schema::normalize_identifier(&cte.alias.name.value);
            local_resolver.aliases.insert(name, None);
            traverse_query(
                &cte.query,
                outer_resolver,
                schema,
                source,
                metrics,
                domains,
                unsupported,
            );
        }
    }
    traverse_set_expr(
        &query.body,
        &local_resolver,
        schema,
        source,
        metrics,
        domains,
        unsupported,
        with_clause,
        outer_resolver,
    );
}

fn traverse_set_expr(
    expr: &SetExpr,
    resolver: &Resolver<'_>,
    schema: Option<&SchemaCatalog>,
    source: &str,
    metrics: &mut Vec<CoverageMetric>,
    domains: &mut Vec<TelemetryDomain>,
    unsupported: &mut Vec<String>,
    with_clause: &Option<sqlparser::ast::With>,
    outer_resolver: &Resolver<'_>,
) {
    match expr {
        SetExpr::Select(select) => {
            traverse_select(
                select,
                resolver,
                schema,
                source,
                metrics,
                domains,
                unsupported,
                with_clause,
                outer_resolver,
            );
        }
        SetExpr::Query(query) => {
            traverse_query(
                query,
                resolver,
                schema,
                source,
                metrics,
                domains,
                unsupported,
            );
        }
        SetExpr::SetOperation { left, right, .. } => {
            traverse_set_expr(
                left,
                resolver,
                schema,
                source,
                metrics,
                domains,
                unsupported,
                &None,
                outer_resolver,
            );
            traverse_set_expr(
                right,
                resolver,
                schema,
                source,
                metrics,
                domains,
                unsupported,
                &None,
                outer_resolver,
            );
        }
        SetExpr::Values(_)
        | SetExpr::Insert(_)
        | SetExpr::Table(_)
        | SetExpr::Update(_)
        | SetExpr::Delete(_)
        | SetExpr::Merge(_) => {}
    }
}

fn traverse_select(
    select: &sqlparser::ast::Select,
    outer_resolver: &Resolver<'_>,
    schema: Option<&SchemaCatalog>,
    source: &str,
    metrics: &mut Vec<CoverageMetric>,
    domains: &mut Vec<TelemetryDomain>,
    unsupported: &mut Vec<String>,
    with_clause: &Option<sqlparser::ast::With>,
    parent_resolver: &Resolver<'_>,
) {
    let mut resolver = outer_resolver.clone();
    for table in &select.from {
        register_factor(&table.relation, false, &mut resolver);
        for join in &table.joins {
            let right_is_optional = matches!(
                join.join_operator,
                JoinOperator::Left(_) | JoinOperator::LeftOuter(_) | JoinOperator::FullOuter(_)
            );
            if matches!(
                join.join_operator,
                JoinOperator::Right(_) | JoinOperator::RightOuter(_) | JoinOperator::FullOuter(_)
            ) {
                resolver
                    .outer_nullable_aliases
                    .extend(resolver.aliases.keys().cloned());
            }
            register_factor(&join.relation, right_is_optional, &mut resolver);
        }
    }

    let with_sql = with_clause
        .as_ref()
        .map(ToString::to_string)
        .unwrap_or_default();
    let from_sql = select
        .from
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ");

    if let Some(selection) = &select.selection {
        let ids = collect_exprs_with_resolver(
            selection,
            "where",
            true,
            source,
            metrics,
            schema,
            &resolver,
            parent_resolver,
        );
        if !ids.is_empty() {
            domains.push(TelemetryDomain {
                with_sql: with_sql.clone(),
                from_sql: from_sql.clone(),
                expression_ids: ids,
            });
        }
    }

    if let Some(having) = &select.having {
        let _ids = collect_exprs_with_resolver(
            having,
            "having",
            false,
            source,
            metrics,
            schema,
            &resolver,
            parent_resolver,
        );
        unsupported.push(
            "HAVING expressions are mapped but not executed in the initial telemetry driver"
                .to_string(),
        );
    }

    for table in &select.from {
        let mut left_side_sql = table.relation.to_string();
        for join in &table.joins {
            let right_side_sql = join.relation.to_string();
            if let Some(join_expr) = join_expression(&join.join_operator) {
                let ids = collect_exprs_with_resolver(
                    join_expr,
                    "join",
                    true,
                    source,
                    metrics,
                    schema,
                    &resolver,
                    parent_resolver,
                );
                if !ids.is_empty() {
                    let cross_join_from = format!("({}) CROSS JOIN {}", left_side_sql, right_side_sql);
                    domains.push(TelemetryDomain {
                        with_sql: with_sql.clone(),
                        from_sql: cross_join_from,
                        expression_ids: ids,
                    });
                }
            }
            left_side_sql = format!("{} {}", left_side_sql, join);
        }
    }

    // Recurse into subqueries inside all clauses of this SELECT query block
    let mut collector = SubqueryCollector::default();
    if let Some(selection) = &select.selection {
        let _ = selection.visit(&mut collector);
    }
    if let Some(having) = &select.having {
        let _ = having.visit(&mut collector);
    }
    for item in &select.projection {
        let _ = item.visit(&mut collector);
    }
    for table in &select.from {
        let _ = table.relation.visit(&mut collector);
        for join in &table.joins {
            let _ = join.relation.visit(&mut collector);
            if let Some(expr) = join_expression(&join.join_operator) {
                let _ = expr.visit(&mut collector);
            }
        }
    }

    for subquery in collector.subqueries {
        traverse_query(
            &subquery,
            &resolver,
            schema,
            source,
            metrics,
            domains,
            unsupported,
        );
    }
}

#[derive(Default)]
struct SubqueryCollector {
    subqueries: Vec<sqlparser::ast::Query>,
}

impl Visitor for SubqueryCollector {
    type Break = ();

    fn pre_visit_query(&mut self, query: &sqlparser::ast::Query) -> ControlFlow<Self::Break> {
        self.subqueries.push(query.clone());
        ControlFlow::Continue(())
    }
}

struct ExpressionRecord {
    span: ExpressionSpan,
    expr: Expr,
}

fn collect_exprs_with_resolver(
    root: &Expr,
    context: &str,
    measurable: bool,
    source: &str,
    metrics: &mut Vec<CoverageMetric>,
    schema: Option<&SchemaCatalog>,
    resolver: &Resolver<'_>,
    outer_resolver: &Resolver<'_>,
) -> Vec<usize> {
    let mut rows = Vec::new();
    find_coverage_expressions(root, context, source, &mut rows);
    let mut ids = Vec::new();
    for mut row in rows {
        let is_correlated = is_correlated_expression(&row.expr, resolver, outer_resolver);

        let row_measurable = measurable && !is_correlated;

        if let Some(_schema) = schema {
            let resolver_ref = resolver;
            let evidence = crate::nullability::nullability(&row.expr, resolver_ref, false);
            row.span.nullable = match evidence.state {
                crate::nullability::Nullability::Never => false,
                _ => true,
            };
        }

        if let Some(existing) = metrics.iter_mut().find(|metric| {
            metric.span.start_offset == row.span.start_offset
                && metric.span.end_offset == row.span.end_offset
                && metric.span.context == row.span.context
        }) {
            if row_measurable {
                existing.measurable = true;
                ids.push(existing.span.id);
            }
            continue;
        }
        row.span.id = metrics.len();
        if row_measurable {
            ids.push(row.span.id);
        }
        metrics.push(CoverageMetric {
            span: row.span,
            measurable: row_measurable,
            hit_true_count: 0,
            hit_false_count: 0,
            hit_unknown_count: 0,
        });
    }
    ids
}

fn find_coverage_expressions(
    expr: &Expr,
    context: &str,
    source: &str,
    rows: &mut Vec<ExpressionRecord>,
) {
    if is_coverage_expression(expr) {
        if let Some(span) = expression_span(expr, context, source) {
            rows.push(ExpressionRecord {
                span,
                expr: expr.clone(),
            });
        }
    }

    match expr {
        Expr::Nested(inner) | Expr::UnaryOp { expr: inner, .. } => {
            find_coverage_expressions(inner, context, source, rows);
        }
        Expr::BinaryOp { left, right, .. } => {
            find_coverage_expressions(left, context, source, rows);
            find_coverage_expressions(right, context, source, rows);
        }
        Expr::Between { expr: val, low, high, .. } => {
            find_coverage_expressions(val, context, source, rows);
            find_coverage_expressions(low, context, source, rows);
            find_coverage_expressions(high, context, source, rows);
        }
        Expr::InList { expr: val, list, .. } => {
            find_coverage_expressions(val, context, source, rows);
            for item in list {
                find_coverage_expressions(item, context, source, rows);
            }
        }
        Expr::InSubquery { expr: val, .. } => {
            find_coverage_expressions(val, context, source, rows);
        }
        Expr::IsNull(inner)
        | Expr::IsNotNull(inner)
        | Expr::IsTrue(inner)
        | Expr::IsNotTrue(inner)
        | Expr::IsFalse(inner)
        | Expr::IsNotFalse(inner)
        | Expr::IsUnknown(inner)
        | Expr::IsNotUnknown(inner) => {
            find_coverage_expressions(inner, context, source, rows);
        }
        Expr::IsDistinctFrom(left, right)
        | Expr::IsNotDistinctFrom(left, right) => {
            find_coverage_expressions(left, context, source, rows);
            find_coverage_expressions(right, context, source, rows);
        }
        Expr::Function(function) => {
            if let sqlparser::ast::FunctionArguments::List(args) = &function.args {
                for arg in &args.args {
                    match arg {
                        sqlparser::ast::FunctionArg::Unnamed(sqlparser::ast::FunctionArgExpr::Expr(e)) => {
                            find_coverage_expressions(e, context, source, rows);
                        }
                        sqlparser::ast::FunctionArg::Named { arg: sqlparser::ast::FunctionArgExpr::Expr(e), .. }
                        | sqlparser::ast::FunctionArg::ExprNamed { arg: sqlparser::ast::FunctionArgExpr::Expr(e), .. } => {
                            find_coverage_expressions(e, context, source, rows);
                        }
                        _ => {}
                    }
                }
            }
        }
        Expr::Case { operand, conditions, else_result, .. } => {
            if let Some(op) = operand {
                find_coverage_expressions(op, context, source, rows);
            }
            for cond in conditions {
                find_coverage_expressions(&cond.condition, context, source, rows);
                find_coverage_expressions(&cond.result, context, source, rows);
            }
            if let Some(el) = else_result {
                find_coverage_expressions(el, context, source, rows);
            }
        }
        _ => {}
    }
}

fn is_correlated_expression(
    expr: &Expr,
    combined_resolver: &Resolver<'_>,
    outer_resolver: &Resolver<'_>,
) -> bool {
    let refs = crate::nullability::referenced_aliases(expr);
    for r in refs {
        if outer_resolver.aliases.contains_key(&r) && !is_local_alias(&r, combined_resolver, outer_resolver) {
            return true;
        }
    }

    struct UnqualifiedVisitor<'a> {
        combined_resolver: &'a Resolver<'a>,
        outer_resolver: &'a Resolver<'a>,
        correlated: bool,
    }
    impl Visitor for UnqualifiedVisitor<'_> {
        type Break = ();
        fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
            if let Expr::Identifier(id) = expr {
                let name = &id.value;
                let in_local = self.combined_resolver.aliases.iter()
                    .filter(|(alias, _)| !self.outer_resolver.aliases.contains_key(*alias))
                    .any(|(_, table)| {
                        table.as_ref().map_or(false, |t| self.combined_resolver.schema.column(t, name).is_some())
                    });
                if !in_local {
                    let in_outer = self.outer_resolver.aliases.iter().any(|(_, table)| {
                        table.as_ref().map_or(false, |t| self.outer_resolver.schema.column(t, name).is_some())
                    });
                    if in_outer {
                        self.correlated = true;
                        return ControlFlow::Break(());
                    }
                }
            }
            ControlFlow::Continue(())
        }
    }
    let mut visitor = UnqualifiedVisitor {
        combined_resolver,
        outer_resolver,
        correlated: false,
    };
    let _ = expr.visit(&mut visitor);
    visitor.correlated
}

fn is_local_alias(alias: &str, combined: &Resolver<'_>, outer: &Resolver<'_>) -> bool {
    combined.aliases.contains_key(alias) && !outer.aliases.contains_key(alias)
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
        parameter_indices: anonymous_parameter_indices(source, start_offset, end_offset),
    })
}

fn anonymous_parameter_indices(source: &str, start: usize, end: usize) -> Vec<usize> {
    let mut indices = Vec::new();
    let mut ordinal = 0;
    let mut quote = None;
    let bytes = source.as_bytes();
    let mut offset = 0;
    while offset < bytes.len() {
        let byte = bytes[offset];
        if let Some(active) = quote {
            if byte == active {
                if bytes.get(offset + 1) == Some(&active) {
                    offset += 2;
                    continue;
                }
                quote = None;
            }
        } else if matches!(byte, b'\'' | b'"' | b'`') {
            quote = Some(byte);
        } else if byte == b'?' {
            if offset >= start && offset < end {
                indices.push(ordinal);
            }
            ordinal += 1;
        }
        offset += 1;
    }
    indices
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parser_edge_cases() {
        let schema = SchemaCatalog::default();

        // 1. CTE traversal
        let sql = "WITH cte AS (SELECT 1) SELECT * FROM cte";
        let analysis = analyze_sql("test.sql", sql, DialectName::Sqlite, Some(&schema)).unwrap();
        assert!(analysis.domains.is_empty());

        // 2. HAVING expression
        let sql = "SELECT age FROM users GROUP BY age HAVING age > 18";
        let analysis = analyze_sql("test.sql", sql, DialectName::Sqlite, Some(&schema)).unwrap();
        assert!(analysis.coverage.unsupported.iter().any(|u| u.contains("HAVING")));

        // 3. Correlated subquery with unqualified outer columns
        let mut schema_with_cols = SchemaCatalog::default();
        schema_with_cols.insert_column("users".to_string(), "age".to_string(), false, false);
        let sql = "SELECT * FROM users WHERE age > (SELECT MIN(age) FROM users WHERE age > 18)";
        let analysis = analyze_sql("test.sql", sql, DialectName::Sqlite, Some(&schema_with_cols)).unwrap();
        assert_eq!(analysis.coverage.metrics.len(), 2);

        // 4. Parenthesized query in set expression & escaped quotes
        let sql_set = "SELECT 1 UNION (SELECT 'hello''world' WHERE age > 20)";
        let analysis_set = analyze_sql("test.sql", sql_set, DialectName::Sqlite, Some(&schema_with_cols)).unwrap();
        println!("SET METRICS: {:#?}", analysis_set.coverage.metrics);
        assert_eq!(analysis_set.coverage.metrics.len(), 1);

        // 5. Named arguments & wildcard function args & JoinOperator coverage
        let sql_func = "SELECT 1 WHERE my_func(x => COUNT(*)) = 1 AND my_func(COUNT(*)) = 1";
        let dialect_pg = sqlparser::dialect::PostgreSqlDialect {};
        let statements_func = sqlparser::parser::Parser::parse_sql(&dialect_pg, sql_func).unwrap();
        let sqlparser::ast::Statement::Query(query_func) = &statements_func[0] else { panic!() };
        let sqlparser::ast::SetExpr::Select(select_func) = &*query_func.body else { panic!() };
        let selection_func = select_func.selection.as_ref().unwrap();
        let mut metrics_func = Vec::new();
        find_coverage_expressions(selection_func, "where", sql_func, &mut metrics_func);
        assert!(!metrics_func.is_empty());

        // 6. Direct collect_exprs_with_resolver calls for deduplication
        let mut metrics = Vec::new();
        let resolver = Resolver::new(&schema);
        let dialect = sqlparser::dialect::GenericDialect;
        let statements = sqlparser::parser::Parser::parse_sql(&dialect, "SELECT 1 IS NULL").unwrap();
        let sqlparser::ast::Statement::Query(query_dedup) = &statements[0] else { panic!() };
        let sqlparser::ast::SetExpr::Select(select_dedup) = &*query_dedup.body else { panic!() };
        let sqlparser::ast::SelectItem::UnnamedExpr(expr) = &select_dedup.projection[0] else { panic!() };
        
        let source_str = "1 IS NULL";
        let ids1 = collect_exprs_with_resolver(
            &expr,
            "where",
            true,
            source_str,
            &mut metrics,
            Some(&schema),
            &resolver,
            &resolver,
        );
        assert_eq!(ids1.len(), 1);
        
        // Call it again to hit deduplication path
        let ids2 = collect_exprs_with_resolver(
            &expr,
            "where",
            true,
            source_str,
            &mut metrics,
            Some(&schema),
            &resolver,
            &resolver,
        );
        assert_eq!(ids2.len(), 1);

        // 7. location_offset and expression_span edge cases
        assert!(location_offset("test", 0, 0).is_none());
        assert!(location_offset("test", 5, 5).is_none());
        assert!(expression_span(&expr, "where", "").is_none());

        // 8. Join operators coverage
        use sqlparser::ast::{JoinConstraint, JoinOperator, ValueWithSpan, Value};
        let op_expr = sqlparser::ast::Expr::Value(ValueWithSpan { value: Value::Null, span: sqlparser::tokenizer::Span::empty() });
        let operators = vec![
            JoinOperator::Join(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Inner(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Left(JoinConstraint::On(op_expr.clone())),
            JoinOperator::LeftOuter(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Right(JoinConstraint::On(op_expr.clone())),
            JoinOperator::RightOuter(JoinConstraint::On(op_expr.clone())),
            JoinOperator::FullOuter(JoinConstraint::On(op_expr.clone())),
            JoinOperator::CrossJoin(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Semi(JoinConstraint::On(op_expr.clone())),
            JoinOperator::LeftSemi(JoinConstraint::On(op_expr.clone())),
            JoinOperator::RightSemi(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Anti(JoinConstraint::On(op_expr.clone())),
            JoinOperator::LeftAnti(JoinConstraint::On(op_expr.clone())),
            JoinOperator::RightAnti(JoinConstraint::On(op_expr.clone())),
            JoinOperator::StraightJoin(JoinConstraint::On(op_expr.clone())),
            JoinOperator::Join(JoinConstraint::None),
        ];
        for op in operators {
            let _ = join_expression(&op);
        }
    }
}
