use crate::nullability::{
    explicitly_null_accepted_aliases, is_null_rejecting_predicate, join_expr, nullability,
    referenced_aliases, resolver_for_select, Nullability, NullabilityEvidence, Resolver,
};
use crate::parser::DialectName;
use crate::schema::SchemaCatalog;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    BinaryOperator, Expr, Query, SelectItem, SetExpr, Spanned, Statement,
    UnaryOperator, Visit, Visitor,
};
use sqlparser::dialect::{Dialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use std::collections::HashSet;
use std::ops::ControlFlow;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HazardKind {
    NullableNotEqual,
    NullableNotIn,
    NullableNotBetween,
    NullableNot,
    NullableAnyAll,
    OuterJoinNullRejection,
    NullableJoinKey,
    #[serde(rename = "looker_join_hazard")]
    LookerJoinHazard,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HazardSpan {
    pub start_offset: usize,
    pub end_offset: usize,
    pub start_line: usize,
    pub start_column: usize,
    pub end_line: usize,
    pub end_column: usize,
    pub raw_expression: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HazardFinding {
    pub id: String,
    pub rule_id: String,
    pub kind: HazardKind,
    pub message: String,
    pub evidence: Vec<String>,
    pub recommendation: String,
    pub span: HazardSpan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HazardReport {
    pub format: String,
    pub file_path: String,
    pub dialect: String,
    pub findings: Vec<HazardFinding>,
    pub unresolved_schema_facts: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LookerJoin {
    pub explore: String,
    pub join_table: String,
    pub relationship: String,
    pub primary_key: String,
    pub foreign_key: String,
}

pub fn parse_lookml(content: &str) -> Vec<LookerJoin> {
    let mut joins = Vec::new();
    let mut current_explore = None;
    let mut current_join = None;
    let mut current_rel = None;
    let mut current_sql_on = None;

    for line in content.lines() {
        let line_trimmed = line.trim();
        if line_trimmed.starts_with("explore:") {
            if let Some(explore) = line_trimmed.strip_prefix("explore:").map(|s| s.trim().trim_end_matches('{').trim()) {
                current_explore = Some(explore.to_string());
            }
        } else if line_trimmed.starts_with("join:") {
            if let Some(join) = line_trimmed.strip_prefix("join:").map(|s| s.trim().trim_end_matches('{').trim()) {
                current_join = Some(join.to_string());
                current_rel = None;
                current_sql_on = None;
            }
        } else if line_trimmed.starts_with("relationship:") {
            if let Some(rel) = line_trimmed.strip_prefix("relationship:").map(|s| s.trim()) {
                current_rel = Some(rel.to_string());
            }
        } else if line_trimmed.starts_with("sql_on:") {
            if let Some(sql_on) = line_trimmed.strip_prefix("sql_on:").map(|s| s.trim().trim_end_matches(';').trim()) {
                current_sql_on = Some(sql_on.to_string());
            }
        }

        if line_trimmed == "}" || line_trimmed.ends_with('}') {
            if let (Some(explore), Some(join), Some(rel)) = (&current_explore, &current_join, &current_rel) {
                let mut primary_key = String::new();
                let mut foreign_key = String::new();
                if let Some(sql_on_str) = &current_sql_on {
                    let keys: Vec<String> = sql_on_str
                        .split('=')
                        .map(|part| {
                            let part = part.trim();
                            if let Some(start) = part.find("${") {
                                if let Some(end) = part[start..].find('}') {
                                    part[start + 2..start + end].to_string()
                                } else {
                                    String::new()
                                }
                            } else {
                                String::new()
                            }
                        })
                        .filter(|s| !s.is_empty())
                        .collect();
                    if keys.len() == 2 {
                        primary_key = keys[0].clone();
                        foreign_key = keys[1].clone();
                    }
                }
                joins.push(LookerJoin {
                    explore: explore.clone(),
                    join_table: join.clone(),
                    relationship: rel.clone(),
                    primary_key,
                    foreign_key,
                });
                current_join = None;
                current_rel = None;
                current_sql_on = None;
            }
        }
    }
    joins
}

pub fn analyze_hazards(
    file_path: &str,
    source: &str,
    dialect: DialectName,
    schema: &SchemaCatalog,
) -> Result<HazardReport> {
    analyze_hazards_with_looker(file_path, source, dialect, schema, &[])
}

pub fn analyze_hazards_with_looker(
    file_path: &str,
    source: &str,
    dialect: DialectName,
    schema: &SchemaCatalog,
    looker_joins: &[LookerJoin],
) -> Result<HazardReport> {
    let dialect_impl: Box<dyn Dialect> = match dialect {
        DialectName::Sqlite => Box::new(SQLiteDialect {}),
        DialectName::Postgres => Box::new(PostgreSqlDialect {}),
        DialectName::Mysql => Box::new(MySqlDialect {}),
    };
    let statements = Parser::parse_sql(dialect_impl.as_ref(), source)
        .with_context(|| format!("parse SQL hazards in {file_path}"))?;
    let mut findings = Vec::new();
    let mut unresolved = Vec::new();

    for statement in &statements {
        let Statement::Query(query) = statement else {
            continue;
        };
        let mut collector = QueryCollector::default();
        let _ = query.visit(&mut collector);
        for query in &collector.queries {
            scan_query(query, source, schema, &mut findings, &mut unresolved);

            // Looker JOIN hazard checks
            if let SetExpr::Select(select) = query.body.as_ref() {
                let resolver = resolver_for_select(select, schema);
                for looker_join in looker_joins {
                    let mut has_explore = false;
                    let mut has_join_table = false;
                    for table in &select.from {
                        if resolves_to_table(&table.relation, &resolver, &looker_join.explore) {
                            has_explore = true;
                        }
                        if resolves_to_table(&table.relation, &resolver, &looker_join.join_table) {
                            has_join_table = true;
                        }
                        for join in &table.joins {
                            if resolves_to_table(&join.relation, &resolver, &looker_join.explore) {
                                has_explore = true;
                            }
                            if resolves_to_table(&join.relation, &resolver, &looker_join.join_table) {
                                has_join_table = true;
                            }
                        }
                    }

                    if has_explore && has_join_table && looker_join.relationship == "one_to_many" {
                        for item in &select.projection {
                            let expr = match item {
                                SelectItem::UnnamedExpr(e) => Some(e),
                                SelectItem::ExprWithAlias { expr: e, .. } => Some(e),
                                _ => None,
                            };
                            if let Some(e) = expr {
                                let aggs = find_one_side_aggregations(e, &resolver, &looker_join.explore);
                                for (func_name, distinct, span) in aggs {
                                    if !distinct {
                                        if let Some(h_span) = hazard_span_from_parser_span(span, source) {
                                            findings.push(HazardFinding {
                                                id: String::new(),
                                                rule_id: "LOOKER_JOIN_HAZARD".to_string(),
                                                kind: HazardKind::LookerJoinHazard,
                                                message: format!(
                                                    "Looker join between base table '{}' and target table '{}' has a one_to_many relationship, but the query aggregates a one-side column '{}' using {} without a DISTINCT modifier.",
                                                    looker_join.explore,
                                                    looker_join.join_table,
                                                    h_span.raw_expression,
                                                    func_name
                                                ),
                                                evidence: vec![format!("explore: {}", looker_join.explore), format!("join: {}", looker_join.join_table)],
                                                recommendation: "Wrap the aggregate expression with DISTINCT (e.g. SUM(DISTINCT ...)) or pre-aggregate in an inline subquery.".to_string(),
                                                span: h_span,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    findings.sort_by_key(|finding| (finding.span.start_offset, finding.rule_id.clone()));
    findings.dedup_by(|left, right| {
        left.rule_id == right.rule_id
            && left.span.start_offset == right.span.start_offset
            && left.span.end_offset == right.span.end_offset
    });

    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    for finding in &mut findings {
        let mut hasher = DefaultHasher::new();
        file_path.hash(&mut hasher);
        finding.rule_id.hash(&mut hasher);
        finding.span.start_offset.hash(&mut hasher);
        finding.span.raw_expression.hash(&mut hasher);
        finding.id = format!("{:016x}", hasher.finish());
    }

    unresolved.sort();
    unresolved.dedup();
    Ok(HazardReport {
        format: "sql-cov-hazards/v1".to_string(),
        file_path: file_path.to_string(),
        dialect: dialect.as_str().to_string(),
        findings,
        unresolved_schema_facts: unresolved,
    })
}

fn resolves_to_table(relation: &sqlparser::ast::TableFactor, resolver: &Resolver, target_table: &str) -> bool {
    match relation {
        sqlparser::ast::TableFactor::Table { name, alias, .. } => {
            let table_name = name.to_string();
            if table_name == target_table {
                return true;
            }
            if let Some(alias) = alias {
                if let Some(Some(real_table)) = resolver.aliases.get(&alias.name.to_string()) {
                    if real_table == target_table {
                        return true;
                    }
                }
            }
            false
        }
        sqlparser::ast::TableFactor::Derived { alias, .. } => {
            if let Some(alias) = alias {
                if alias.name.to_string() == target_table {
                    return true;
                }
            }
            false
        }
        _ => false,
    }
}

fn find_one_side_aggregations(
    expr: &Expr,
    resolver: &Resolver,
    one_side_table: &str,
) -> Vec<(String, bool, sqlparser::tokenizer::Span)> {
    let mut results = Vec::new();
    struct AggregationVisitor<'a> {
        resolver: &'a Resolver<'a>,
        one_side_table: &'a str,
        results: &'a mut Vec<(String, bool, sqlparser::tokenizer::Span)>,
    }
    impl Visitor for AggregationVisitor<'_> {
        type Break = ();
        fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
            if let Expr::Function(func) = expr {
                let name = func.name.to_string().to_uppercase();
                if name == "SUM" || name == "COUNT" || name == "AVG" || name == "MIN" || name == "MAX" {
                    let mut targets_one_side = false;
                    if let sqlparser::ast::FunctionArguments::List(args) = &func.args {
                        let distinct = matches!(args.duplicate_treatment, Some(sqlparser::ast::DuplicateTreatment::Distinct));
                        for arg in &args.args {
                            if let sqlparser::ast::FunctionArg::Unnamed(sqlparser::ast::FunctionArgExpr::Expr(e)) = arg {
                                if expr_targets_table(e, self.resolver, self.one_side_table) {
                                    targets_one_side = true;
                                }
                            }
                        }
                        if targets_one_side {
                            self.results.push((name, distinct, expr.span()));
                        }
                    }
                }
            }
            ControlFlow::Continue(())
        }
    }
    let mut visitor = AggregationVisitor {
        resolver,
        one_side_table,
        results: &mut results,
    };
    let _ = expr.visit(&mut visitor);
    results
}

fn expr_targets_table(expr: &Expr, resolver: &Resolver, target_table: &str) -> bool {
    match expr {
        Expr::Identifier(ident) => {
            let col_name = ident.value.to_string();
            if let Some(table) = resolver.schema.tables.get(target_table) {
                if table.columns.contains_key(&col_name) {
                    return true;
                }
            }
            false
        }
        Expr::CompoundIdentifier(idents) => {
            if idents.len() >= 2 {
                let prefix = idents[0].value.to_string();
                if prefix == target_table {
                    return true;
                }
                if let Some(Some(real_table)) = resolver.aliases.get(&prefix) {
                    if real_table == target_table {
                        return true;
                    }
                }
            }
            false
        }
        _ => {
            let mut found = false;
            struct TargetVisitor<'a> {
                resolver: &'a Resolver<'a>,
                target_table: &'a str,
                found: &'a mut bool,
            }
            impl Visitor for TargetVisitor<'_> {
                type Break = ();
                fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
                    if expr_targets_table_shallow(expr, self.resolver, self.target_table) {
                        *self.found = true;
                        return ControlFlow::Break(());
                    }
                    ControlFlow::Continue(())
                }
            }
            let mut visitor = TargetVisitor {
                resolver,
                target_table,
                found: &mut found,
            };
            let _ = expr.visit(&mut visitor);
            found
        }
    }
}

fn expr_targets_table_shallow(expr: &Expr, resolver: &Resolver, target_table: &str) -> bool {
    match expr {
        Expr::Identifier(ident) => {
            let col_name = ident.value.to_string();
            if let Some(table) = resolver.schema.tables.get(target_table) {
                if table.columns.contains_key(&col_name) {
                    return true;
                }
            }
            false
        }
        Expr::CompoundIdentifier(idents) => {
            if idents.len() >= 2 {
                let prefix = idents[0].value.to_string();
                if prefix == target_table {
                    return true;
                }
                if let Some(Some(real_table)) = resolver.aliases.get(&prefix) {
                    if real_table == target_table {
                        return true;
                    }
                }
            }
            false
        }
        _ => false,
    }
}

fn hazard_span_from_parser_span(parser_span: sqlparser::tokenizer::Span, source: &str) -> Option<HazardSpan> {
    let start_line = parser_span.start.line as usize;
    let start_column = parser_span.start.column as usize;
    let end_line = parser_span.end.line as usize;
    let end_column = parser_span.end.column as usize;
    let start_offset = location_offset(source, start_line, start_column)?;
    let end_offset = location_offset(source, end_line, end_column)?;
    Some(HazardSpan {
        start_offset,
        end_offset,
        start_line,
        start_column,
        end_line,
        end_column,
        raw_expression: source.get(start_offset..end_offset)?.to_string(),
    })
}

#[derive(Default)]
struct QueryCollector {
    queries: Vec<Query>,
}

impl Visitor for QueryCollector {
    type Break = ();

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<Self::Break> {
        self.queries.push(query.clone());
        ControlFlow::Continue(())
    }
}

fn scan_query(
    query: &Query,
    source: &str,
    schema: &SchemaCatalog,
    findings: &mut Vec<HazardFinding>,
    unresolved: &mut Vec<String>,
) {
    let SetExpr::Select(select) = query.body.as_ref() else {
        return;
    };
    let resolver = resolver_for_select(select, schema);
    if let Some(selection) = &select.selection {
        let protected_aliases = explicitly_null_accepted_aliases(selection);
        let mut visitor = HazardVisitor {
            context: "WHERE",
            source,
            resolver: &resolver,
            protected_aliases: &protected_aliases,
            findings,
            unresolved,
        };
        let _ = selection.visit(&mut visitor);
    }
    if let Some(having) = &select.having {
        let protected_aliases = HashSet::new();
        let mut visitor = HazardVisitor {
            context: "HAVING",
            source,
            resolver: &resolver,
            protected_aliases: &protected_aliases,
            findings,
            unresolved,
        };
        let _ = having.visit(&mut visitor);
    }
    for table in &select.from {
        for join in &table.joins {
            if let Some(expr) = join_expr(&join.join_operator) {
                scan_join_keys(expr, source, &resolver, findings, unresolved);
            }
        }
    }
}

struct HazardVisitor<'a, 'b> {
    context: &'static str,
    source: &'a str,
    resolver: &'a Resolver<'a>,
    protected_aliases: &'a HashSet<String>,
    findings: &'b mut Vec<HazardFinding>,
    unresolved: &'b mut Vec<String>,
}

impl Visitor for HazardVisitor<'_, '_> {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        self.detect_unknown_trap(expr);
        self.detect_outer_join_rejection(expr);
        ControlFlow::Continue(())
    }
}

impl HazardVisitor<'_, '_> {
    fn detect_unknown_trap(&mut self, expr: &Expr) {
        let candidate = match expr {
            Expr::BinaryOp {
                left,
                op: BinaryOperator::NotEq,
                right,
            } => Some((
                "SQL001",
                HazardKind::NullableNotEqual,
                nullability(left, self.resolver, false)
                    .merge(nullability(right, self.resolver, false)),
                "nullable inequality can evaluate to UNKNOWN and silently reject a row",
                "Make the NULL policy explicit with IS NULL/IS NOT NULL, IS DISTINCT FROM where supported, or a deliberate COALESCE.",
            )),
            Expr::InList {
                expr: value,
                list,
                negated: true,
            } => {
                let state = list.iter().fold(
                    nullability(value, self.resolver, false),
                    |state, item| state.merge(nullability(item, self.resolver, false)),
                );
                Some((
                    "SQL002",
                    HazardKind::NullableNotIn,
                    state,
                    "NOT IN can evaluate to UNKNOWN when either side contains NULL",
                    "Prefer NOT EXISTS or explicitly exclude/handle NULL on both sides.",
                ))
            }
            Expr::InSubquery {
                expr: value,
                negated: true,
                subquery,
            } => Some((
                "SQL002",
                HazardKind::NullableNotIn,
                nullability(value, self.resolver, false)
                    .merge(subquery_output_nullability(subquery, self.resolver.schema)),
                "NOT IN can evaluate to UNKNOWN when either side contains NULL",
                "Prefer NOT EXISTS or explicitly exclude/handle NULL on both sides.",
            )),
            Expr::InUnnest {
                expr: value,
                negated: true,
                ..
            } => Some((
                "SQL002",
                HazardKind::NullableNotIn,
                nullability(value, self.resolver, false).merge(NullabilityEvidence::unknown(
                    "the NOT IN result set nullability is not proven by the current schema resolver",
                )),
                "NOT IN can evaluate to UNKNOWN when either side contains NULL",
                "Prefer NOT EXISTS or explicitly exclude/handle NULL on both sides.",
            )),
            Expr::Between {
                expr: value,
                negated: true,
                low,
                high,
            } => Some((
                "SQL003",
                HazardKind::NullableNotBetween,
                nullability(value, self.resolver, false)
                    .merge(nullability(low, self.resolver, false))
                    .merge(nullability(high, self.resolver, false)),
                "NOT BETWEEN over a nullable operand can evaluate to UNKNOWN",
                "Handle NULL explicitly before applying NOT BETWEEN.",
            )),
            Expr::UnaryOp {
                op: UnaryOperator::Not | UnaryOperator::BangNot,
                expr: value,
            } => Some((
                "SQL004",
                HazardKind::NullableNot,
                nullability(value, self.resolver, false),
                "NOT preserves UNKNOWN rather than converting it to TRUE",
                "Make the operand's NULL behavior explicit before negation.",
            )),
            Expr::AnyOp { left, right, .. } | Expr::AllOp { left, right, .. } => Some((
                "SQL005",
                HazardKind::NullableAnyAll,
                nullability(left, self.resolver, false)
                    .merge(quantified_rhs_nullability(right, self.resolver)),
                "ANY/ALL can evaluate to UNKNOWN when a compared value is NULL",
                "Filter NULL from the compared set or encode the intended NULL policy explicitly.",
            )),
            _ => None,
        };
        if let Some((rule, kind, evidence, message, recommendation)) = candidate {
            self.push_if_proven(rule, kind, expr, evidence, message, recommendation);
        }
    }

    fn detect_outer_join_rejection(&mut self, expr: &Expr) {
        if !is_null_rejecting_predicate(expr) {
            return;
        }
        let aliases = referenced_aliases(expr);
        let affected = aliases
            .intersection(&self.resolver.outer_nullable_aliases)
            .filter(|alias| !self.protected_aliases.contains(*alias))
            .cloned()
            .collect::<Vec<_>>();
        if affected.is_empty() {
            return;
        }
        let evidence = nullability(expr, self.resolver, true);
        self.push_if_proven(
            "SQL006",
            HazardKind::OuterJoinNullRejection,
            expr,
            evidence,
            "a filter on the optional side of an outer join rejects unmatched rows",
            "Move the predicate into JOIN ... ON, accept the unmatched row with IS NULL, or use INNER JOIN if rejection is intentional.",
        );
    }

    fn push_if_proven(
        &mut self,
        rule: &str,
        kind: HazardKind,
        expr: &Expr,
        evidence: NullabilityEvidence,
        message: &str,
        recommendation: &str,
    ) {
        match evidence.state {
            Nullability::Never => return,
            Nullability::Unknown => {
                self.unresolved.extend(evidence.reasons);
                return;
            }
            Nullability::Nullable => {}
        }
        let Some(span) = hazard_span(expr, self.source) else {
            return;
        };
        self.findings.push(HazardFinding {
            id: String::new(),
            rule_id: rule.to_string(),
            kind,
            message: format!("{} in {}", message, self.context),
            evidence: evidence.reasons,
            recommendation: recommendation.to_string(),
            span,
        });
    }
}

fn quantified_rhs_nullability(expr: &Expr, resolver: &Resolver<'_>) -> NullabilityEvidence {
    match expr {
        Expr::Subquery(query) => subquery_output_nullability(query, resolver.schema),
        Expr::Array(array) => array
            .elem
            .iter()
            .fold(NullabilityEvidence::never(), |state, item| {
                state.merge(nullability(item, resolver, false))
            }),
        _ => nullability(expr, resolver, false),
    }
}

fn subquery_output_nullability(query: &Query, schema: &SchemaCatalog) -> NullabilityEvidence {
    let SetExpr::Select(select) = query.body.as_ref() else {
        return NullabilityEvidence::unknown("NOT IN subquery output nullability is unresolved");
    };
    let resolver = resolver_for_select(select, schema);
    match select.projection.first() {
        Some(SelectItem::UnnamedExpr(expr)) => nullability(expr, &resolver, false),
        Some(SelectItem::ExprWithAlias { expr, .. }) => nullability(expr, &resolver, false),
        _ => NullabilityEvidence::unknown("NOT IN subquery output column is unresolved"),
    }
}

fn scan_join_keys(
    root: &Expr,
    source: &str,
    resolver: &Resolver<'_>,
    findings: &mut Vec<HazardFinding>,
    unresolved: &mut Vec<String>,
) {
    struct JoinVisitor<'a, 'b> {
        source: &'a str,
        resolver: &'a Resolver<'a>,
        findings: &'b mut Vec<HazardFinding>,
        unresolved: &'b mut Vec<String>,
    }
    impl Visitor for JoinVisitor<'_, '_> {
        type Break = ();

        fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
            let Expr::BinaryOp { left, op, right } = expr else {
                return ControlFlow::Continue(());
            };
            if !matches!(op, BinaryOperator::Eq | BinaryOperator::NotEq) {
                return ControlFlow::Continue(());
            }
            let evidence = nullability(left, self.resolver, false).merge(nullability(
                right,
                self.resolver,
                false,
            ));
            match evidence.state {
                Nullability::Unknown => self.unresolved.extend(evidence.reasons),
                Nullability::Nullable => {
                    if let Some(span) = hazard_span(expr, self.source) {
                        self.findings.push(HazardFinding {
                            id: String::new(),
                            rule_id: "SQL007".to_string(),
                            kind: HazardKind::NullableJoinKey,
                            message: "nullable join equality has an implicit UNKNOWN/non-match policy in JOIN ON".to_string(),
                            evidence: evidence.reasons,
                            recommendation: "Use explicit NULL-safe equality when NULLs should match, or document/test that NULL keys must not match.".to_string(),
                            span,
                        });
                    }
                }
                Nullability::Never => {}
            }
            ControlFlow::Continue(())
        }
    }
    let mut visitor = JoinVisitor {
        source,
        resolver,
        findings,
        unresolved,
    };
    let _ = root.visit(&mut visitor);
}

fn hazard_span(expr: &Expr, source: &str) -> Option<HazardSpan> {
    let parser_span = expr.span();
    let start_line = parser_span.start.line as usize;
    let start_column = parser_span.start.column as usize;
    let end_line = parser_span.end.line as usize;
    let end_column = parser_span.end.column as usize;
    let start_offset = location_offset(source, start_line, start_column)?;
    let end_offset = location_offset(source, end_line, end_column)?;
    Some(HazardSpan {
        start_offset,
        end_offset,
        start_line,
        start_column,
        end_line,
        end_column,
        raw_expression: source.get(start_offset..end_offset)?.to_string(),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_location_offset_bounds() {
        assert_eq!(location_offset("", 0, 0), None);
        assert_eq!(location_offset("abc", 1, 0), None);
        assert_eq!(location_offset("abc", 0, 1), None);
        assert_eq!(location_offset("abc", 3, 2), None); // out of bounds

        let dialect = sqlparser::dialect::GenericDialect;
        let statements = sqlparser::parser::Parser::parse_sql(&dialect, "SELECT age").unwrap();
        if let sqlparser::ast::Statement::Query(query) = &statements[0] {
            if let sqlparser::ast::SetExpr::Select(select) = &*query.body {
                let expr = &select.projection[0];
                if let sqlparser::ast::SelectItem::UnnamedExpr(expr) = expr {
                    assert_eq!(hazard_span(expr, ""), None);
                }
            }
        }
    }

    #[test]
    fn test_finding_deduplication() {
        let mut findings = vec![
            HazardFinding {
                id: String::new(),
                rule_id: "rule_1".to_string(),
                kind: HazardKind::NullableAnyAll,
                message: "msg".to_string(),
                evidence: vec![],
                recommendation: "rec".to_string(),
                span: HazardSpan {
                    start_offset: 10,
                    end_offset: 20,
                    start_line: 1,
                    start_column: 10,
                    end_line: 1,
                    end_column: 20,
                    raw_expression: "expr".to_string(),
                },
            },
            HazardFinding {
                id: String::new(),
                rule_id: "rule_1".to_string(),
                kind: HazardKind::NullableAnyAll,
                message: "msg".to_string(),
                evidence: vec![],
                recommendation: "rec".to_string(),
                span: HazardSpan {
                    start_offset: 10,
                    end_offset: 20,
                    start_line: 1,
                    start_column: 10,
                    end_line: 1,
                    end_column: 20,
                    raw_expression: "expr".to_string(),
                },
            },
        ];
        findings.sort_by_key(|finding| (finding.span.start_offset, finding.rule_id.clone()));
        findings.dedup_by(|left, right| {
            left.rule_id == right.rule_id
                && left.span.start_offset == right.span.start_offset
                && left.span.end_offset == right.span.end_offset
        });
        assert_eq!(findings.len(), 1);
    }

    #[test]
    fn test_quantified_rhs_and_unresolved_joins() {
        let schema = SchemaCatalog::default();
        
        // Non-query statement
        let report = analyze_hazards("test.sql", "CREATE TABLE dummy (id INT)", DialectName::Sqlite, &schema).unwrap();
        assert!(report.findings.is_empty());

        // UNION instead of Select
        let report = analyze_hazards(
            "test.sql",
            "SELECT name FROM users UNION SELECT name FROM users",
            DialectName::Sqlite,
            &schema,
        ).unwrap();
        assert!(report.findings.is_empty());

        // Join ON with non-equality operator
        let report = analyze_hazards(
            "test.sql",
            "SELECT * FROM a JOIN b ON a.id < b.id",
            DialectName::Sqlite,
            &schema,
        ).unwrap();
        assert!(report.findings.is_empty());

        // Join ON with unresolved/unknown nullability keys
        let report = analyze_hazards(
            "test.sql",
            "SELECT * FROM a JOIN b ON a.non_existent = b.non_existent",
            DialectName::Sqlite,
            &schema,
        ).unwrap();
        assert!(report.unresolved_schema_facts.len() > 0);

        // Join ON with never-null keys
        let mut schema_with_pks = SchemaCatalog::default();
        schema_with_pks.insert_column("a".to_string(), "id".to_string(), false, true);
        schema_with_pks.insert_column("b".to_string(), "id".to_string(), false, true);
        let report = analyze_hazards(
            "test.sql",
            "SELECT * FROM a JOIN b ON a.id = b.id",
            DialectName::Sqlite,
            &schema_with_pks,
        ).unwrap();
        assert!(report.findings.is_empty());

        let mut schema_projection = SchemaCatalog::default();
        schema_projection.insert_column("users".to_string(), "bonus".to_string(), true, false);
        schema_projection.insert_column("users".to_string(), "age".to_string(), false, false);

        // NOT IN subquery with UNION / non-Select body
        let report = analyze_hazards(
            "test.sql",
            "SELECT name FROM users WHERE age NOT IN (SELECT bonus FROM users UNION SELECT age FROM users)",
            DialectName::Sqlite,
            &schema_projection,
        ).unwrap();
        assert_eq!(report.unresolved_schema_facts.len(), 1);

        // NOT IN subquery projecting alias
        let report = analyze_hazards(
            "test.sql",
            "SELECT name FROM users WHERE age NOT IN (SELECT bonus AS b FROM users)",
            DialectName::Sqlite,
            &schema_projection,
        ).unwrap();
        assert_eq!(report.findings.len(), 1);

        // NOT IN subquery projecting * (unresolved column)
        let report = analyze_hazards(
            "test.sql",
            "SELECT name FROM users WHERE age NOT IN (SELECT * FROM users)",
            DialectName::Sqlite,
            &schema_projection,
        ).unwrap();
        assert_eq!(report.unresolved_schema_facts.len(), 1);

        // NOT IN UNNEST
        let report = analyze_hazards(
            "test.sql",
            "SELECT name FROM users WHERE age NOT IN UNNEST(some_array)",
            DialectName::Postgres,
            &schema_projection,
        ).unwrap();
        assert_eq!(report.unresolved_schema_facts.len(), 1);
        assert!(report.unresolved_schema_facts[0].contains("not proven"));
    }
}
