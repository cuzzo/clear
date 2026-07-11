use crate::schema::{normalize_identifier, SchemaCatalog};
use sqlparser::ast::{
    BinaryOperator, Expr, FunctionArg, FunctionArgExpr, FunctionArguments, JoinOperator,
    Select, TableFactor, Value, Visit, Visitor,
};
use std::collections::{HashMap, HashSet};
use std::ops::ControlFlow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Nullability {
    Never,
    Nullable,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct NullabilityEvidence {
    pub state: Nullability,
    pub reasons: Vec<String>,
}

impl NullabilityEvidence {
    pub fn never() -> Self {
        Self {
            state: Nullability::Never,
            reasons: Vec::new(),
        }
    }

    pub fn unknown(reason: impl Into<String>) -> Self {
        Self {
            state: Nullability::Unknown,
            reasons: vec![reason.into()],
        }
    }

    pub fn nullable(reason: impl Into<String>) -> Self {
        Self {
            state: Nullability::Nullable,
            reasons: vec![reason.into()],
        }
    }

    pub fn merge(mut self, other: Self) -> Self {
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

#[derive(Debug, Clone)]
pub struct Resolver<'a> {
    pub schema: &'a SchemaCatalog,
    pub aliases: HashMap<String, Option<String>>,
    pub outer_nullable_aliases: HashSet<String>,
}

impl<'a> Resolver<'a> {
    pub fn new(schema: &'a SchemaCatalog) -> Self {
        Self {
            schema,
            aliases: HashMap::new(),
            outer_nullable_aliases: HashSet::new(),
        }
    }
}

pub fn resolver_for_select<'a>(select: &Select, schema: &'a SchemaCatalog) -> Resolver<'a> {
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

pub fn register_factor(factor: &TableFactor, outer_nullable: bool, resolver: &mut Resolver<'_>) {
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

pub fn nullability(
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
        Expr::Function(function) if function.name.to_string().eq_ignore_ascii_case("coalesce") => {
            coalesce_nullability(&function.args, resolver, outer_join_context)
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

fn coalesce_nullability(
    arguments: &FunctionArguments,
    resolver: &Resolver<'_>,
    outer_join_context: bool,
) -> NullabilityEvidence {
    let FunctionArguments::List(arguments) = arguments else {
        return NullabilityEvidence::unknown("COALESCE arguments are unresolved");
    };
    let states = arguments
        .args
        .iter()
        .filter_map(|argument| {
            let argument = match argument {
                FunctionArg::Named { arg, .. }
                | FunctionArg::ExprNamed { arg, .. }
                | FunctionArg::Unnamed(arg) => arg,
            };
            match argument {
                FunctionArgExpr::Expr(expr) => {
                    Some(nullability(expr, resolver, outer_join_context))
                }
                _ => None,
            }
        })
        .collect::<Vec<_>>();
    if states.iter().any(|state| state.state == Nullability::Never) {
        return NullabilityEvidence::never();
    }
    if states.is_empty()
        || states
            .iter()
            .any(|state| state.state == Nullability::Unknown)
    {
        return NullabilityEvidence::unknown(
            "COALESCE has an argument with unresolved nullability",
        );
    }
    states
        .into_iter()
        .fold(NullabilityEvidence::never(), NullabilityEvidence::merge)
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

pub fn resolve_qualified(
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

pub fn resolve_unqualified(column: &str, resolver: &Resolver<'_>) -> NullabilityEvidence {
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

pub fn explicitly_null_accepted_aliases(expr: &Expr) -> HashSet<String> {
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

pub fn referenced_aliases(expr: &Expr) -> HashSet<String> {
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

pub fn is_null_rejecting_predicate(expr: &Expr) -> bool {
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

pub fn join_expr(operator: &JoinOperator) -> Option<&Expr> {
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
