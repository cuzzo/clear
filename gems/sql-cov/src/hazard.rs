use crate::parser::DialectName;
use crate::schema::{normalize_identifier, SchemaCatalog};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sqlparser::ast::{
    BinaryOperator, Expr, JoinOperator, Query, Select, SelectItem, SetExpr, Spanned, Statement,
    TableFactor, UnaryOperator, Value, Visit, Visitor,
};
use sqlparser::dialect::{Dialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use std::collections::{HashMap, HashSet};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Nullability {
    Never,
    Nullable,
    Unknown,
}

#[derive(Debug, Clone)]
struct NullabilityEvidence {
    state: Nullability,
    reasons: Vec<String>,
}

impl NullabilityEvidence {
    fn never() -> Self {
        Self {
            state: Nullability::Never,
            reasons: Vec::new(),
        }
    }

    fn unknown(reason: impl Into<String>) -> Self {
        Self {
            state: Nullability::Unknown,
            reasons: vec![reason.into()],
        }
    }

    fn nullable(reason: impl Into<String>) -> Self {
        Self {
            state: Nullability::Nullable,
            reasons: vec![reason.into()],
        }
    }

    fn merge(mut self, other: Self) -> Self {
        self.state = match (self.state, other.state) {
            (Nullability::Nullable, _) | (_, Nullability::Nullable) => Nullability::Nullable,
            (Nullability::Unknown, _) | (_, Nullability::Unknown) => Nullability::Unknown,
            _ => Nullability::Never,
        };
        self.reasons.extend(other.reasons);
        self.reasons.sort();
        self.reasons.dedup();
        self
    }
}

#[derive(Debug)]
struct Resolver<'a> {
    schema: &'a SchemaCatalog,
    aliases: HashMap<String, Option<String>>,
    outer_nullable_aliases: HashSet<String>,
}

impl<'a> Resolver<'a> {
    fn new(schema: &'a SchemaCatalog) -> Self {
        Self {
            schema,
            aliases: HashMap::new(),
            outer_nullable_aliases: HashSet::new(),
        }
    }
}

pub fn analyze_hazards(
    file_path: &str,
    source: &str,
    dialect: DialectName,
    schema: &SchemaCatalog,
) -> Result<HazardReport> {
    let dialect_impl: Box<dyn Dialect> = match dialect {
        DialectName::Sqlite => Box::new(SQLiteDialect {}),
        DialectName::Postgres => Box::new(PostgreSqlDialect {}),
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
        }
    }

    findings.sort_by_key(|finding| (finding.span.start_offset, finding.rule_id.clone()));
    findings.dedup_by(|left, right| {
        left.rule_id == right.rule_id
            && left.span.start_offset == right.span.start_offset
            && left.span.end_offset == right.span.end_offset
    });
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

fn resolver_for_select<'a>(select: &Select, schema: &'a SchemaCatalog) -> Resolver<'a> {
    let mut resolver = Resolver::new(schema);
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
    resolver
}

fn register_factor(factor: &TableFactor, outer_nullable: bool, resolver: &mut Resolver<'_>) {
    match factor {
        TableFactor::Table { name, alias, .. } => {
            let table = name.to_string();
            let table = table.rsplit('.').next().unwrap_or(&table);
            let key = alias
                .as_ref()
                .map(|alias| alias.name.value.as_str())
                .unwrap_or(table);
            let key = normalize_identifier(key);
            resolver
                .aliases
                .insert(key.clone(), Some(normalize_identifier(table)));
            if outer_nullable {
                resolver.outer_nullable_aliases.insert(key);
            }
        }
        TableFactor::Derived { alias, .. } => {
            if let Some(alias) = alias {
                let key = normalize_identifier(&alias.name.value);
                resolver.aliases.insert(key.clone(), None);
                if outer_nullable {
                    resolver.outer_nullable_aliases.insert(key);
                }
            }
        }
        _ => {}
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
                    .merge(nullability(right, self.resolver, false)),
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
        self.push_if_proven(
            "SQL006",
            HazardKind::OuterJoinNullRejection,
            expr,
            NullabilityEvidence::nullable(format!(
                "outer join introduces NULL for alias(es): {}",
                affected.join(", ")
            )),
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
            rule_id: rule.to_string(),
            kind,
            message: format!("{} in {}", message, self.context),
            evidence: evidence.reasons,
            recommendation: recommendation.to_string(),
            span,
        });
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

fn nullability(
    expr: &Expr,
    resolver: &Resolver<'_>,
    outer_join_context: bool,
) -> NullabilityEvidence {
    match expr {
        Expr::Identifier(identifier) => resolve_unqualified(&identifier.value, resolver),
        Expr::CompoundIdentifier(parts) if parts.len() >= 2 => resolve_qualified(
            &parts[parts.len() - 2].value,
            &parts[parts.len() - 1].value,
            resolver,
            outer_join_context,
        ),
        Expr::Value(value) => match value.value {
            Value::Null => NullabilityEvidence::nullable("the expression contains a NULL literal"),
            Value::Placeholder(_) => NullabilityEvidence::unknown("a bound parameter may be NULL"),
            _ => NullabilityEvidence::never(),
        },
        Expr::Nested(value) | Expr::UnaryOp { expr: value, .. } => {
            nullability(value, resolver, outer_join_context)
        }
        Expr::BinaryOp { left, right, .. } => nullability(left, resolver, outer_join_context)
            .merge(nullability(right, resolver, outer_join_context)),
        Expr::Between {
            expr: value,
            low,
            high,
            ..
        } => nullability(value, resolver, outer_join_context)
            .merge(nullability(low, resolver, outer_join_context))
            .merge(nullability(high, resolver, outer_join_context)),
        Expr::InList {
            expr: value, list, ..
        } => list.iter().fold(
            nullability(value, resolver, outer_join_context),
            |state, item| state.merge(nullability(item, resolver, outer_join_context)),
        ),
        Expr::IsNull(_)
        | Expr::IsNotNull(_)
        | Expr::IsTrue(_)
        | Expr::IsNotTrue(_)
        | Expr::IsFalse(_)
        | Expr::IsNotFalse(_)
        | Expr::IsUnknown(_)
        | Expr::IsNotUnknown(_)
        | Expr::IsDistinctFrom(_, _)
        | Expr::IsNotDistinctFrom(_, _) => NullabilityEvidence::never(),
        _ => {
            let mut visitor = NullableColumnVisitor {
                resolver,
                outer_join_context,
                result: NullabilityEvidence::never(),
            };
            let _ = expr.visit(&mut visitor);
            if visitor.result.state == Nullability::Never {
                NullabilityEvidence::unknown(format!(
                    "nullability of expression `{expr}` is not modeled"
                ))
            } else {
                visitor.result
            }
        }
    }
}

struct NullableColumnVisitor<'a> {
    resolver: &'a Resolver<'a>,
    outer_join_context: bool,
    result: NullabilityEvidence,
}

impl Visitor for NullableColumnVisitor<'_> {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        let evidence = match expr {
            Expr::Identifier(identifier) => {
                Some(resolve_unqualified(&identifier.value, self.resolver))
            }
            Expr::CompoundIdentifier(parts) if parts.len() >= 2 => Some(resolve_qualified(
                &parts[parts.len() - 2].value,
                &parts[parts.len() - 1].value,
                self.resolver,
                self.outer_join_context,
            )),
            Expr::Value(value) if matches!(value.value, Value::Null) => Some(
                NullabilityEvidence::nullable("the expression contains a NULL literal"),
            ),
            _ => None,
        };
        if let Some(evidence) = evidence {
            self.result = self.result.clone().merge(evidence);
        }
        ControlFlow::Continue(())
    }
}

fn resolve_qualified(
    alias: &str,
    column: &str,
    resolver: &Resolver<'_>,
    outer_join_context: bool,
) -> NullabilityEvidence {
    let alias = normalize_identifier(alias);
    if outer_join_context && resolver.outer_nullable_aliases.contains(&alias) {
        return NullabilityEvidence::nullable(format!(
            "outer join can synthesize NULL for {alias}.{column}"
        ));
    }
    let Some(table) = resolver.aliases.get(&alias) else {
        return NullabilityEvidence::unknown(format!("schema alias `{alias}` is unresolved"));
    };
    let Some(table) = table else {
        return NullabilityEvidence::unknown(format!(
            "derived-table column {alias}.{column} has unresolved nullability"
        ));
    };
    let Some(schema) = resolver.schema.column(table, column) else {
        return NullabilityEvidence::unknown(format!(
            "column {table}.{column} is absent from the loaded schema"
        ));
    };
    if schema.nullable {
        NullabilityEvidence::nullable(format!("schema declares {table}.{} nullable", schema.name))
    } else {
        NullabilityEvidence::never()
    }
}

fn resolve_unqualified(column: &str, resolver: &Resolver<'_>) -> NullabilityEvidence {
    let matches = resolver
        .aliases
        .iter()
        .filter_map(|(alias, table)| {
            let table = table.as_ref()?;
            resolver
                .schema
                .column(table, column)
                .map(|schema| (alias, table, schema))
        })
        .collect::<Vec<_>>();
    if matches.is_empty() {
        return NullabilityEvidence::unknown(format!(
            "unqualified column `{column}` is absent from the loaded schema"
        ));
    }
    if matches
        .iter()
        .any(|(alias, _, _)| resolver.outer_nullable_aliases.contains(*alias))
    {
        return NullabilityEvidence::nullable(format!(
            "outer join can synthesize NULL for unqualified column {column}"
        ));
    }
    if let Some((_, table, schema)) = matches.iter().find(|(_, _, schema)| schema.nullable) {
        return NullabilityEvidence::nullable(format!(
            "schema declares {table}.{} nullable",
            schema.name
        ));
    }
    NullabilityEvidence::never()
}

fn explicitly_null_accepted_aliases(expr: &Expr) -> HashSet<String> {
    struct NullPolicyVisitor {
        aliases: HashSet<String>,
    }
    impl Visitor for NullPolicyVisitor {
        type Break = ();

        fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
            if let Expr::IsNull(value) = expr {
                self.aliases.extend(referenced_aliases(value));
            }
            ControlFlow::Continue(())
        }
    }
    let mut visitor = NullPolicyVisitor {
        aliases: HashSet::new(),
    };
    let _ = expr.visit(&mut visitor);
    visitor.aliases
}

fn referenced_aliases(expr: &Expr) -> HashSet<String> {
    struct AliasVisitor {
        aliases: HashSet<String>,
    }
    impl Visitor for AliasVisitor {
        type Break = ();

        fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
            if let Expr::CompoundIdentifier(parts) = expr {
                if parts.len() >= 2 {
                    self.aliases
                        .insert(normalize_identifier(&parts[parts.len() - 2].value));
                }
            }
            ControlFlow::Continue(())
        }
    }
    let mut visitor = AliasVisitor {
        aliases: HashSet::new(),
    };
    let _ = expr.visit(&mut visitor);
    visitor.aliases
}

fn is_null_rejecting_predicate(expr: &Expr) -> bool {
    matches!(
        expr,
        Expr::BinaryOp {
            op: BinaryOperator::Eq
                | BinaryOperator::NotEq
                | BinaryOperator::Gt
                | BinaryOperator::GtEq
                | BinaryOperator::Lt
                | BinaryOperator::LtEq,
            ..
        } | Expr::InList { .. }
            | Expr::InSubquery { .. }
            | Expr::InUnnest { .. }
            | Expr::Between { .. }
            | Expr::Like { .. }
            | Expr::ILike { .. }
            | Expr::SimilarTo { .. }
    )
}

fn join_expr(operator: &JoinOperator) -> Option<&Expr> {
    use sqlparser::ast::JoinConstraint;
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
