use fact_mine_rust::profile::DeclarationTypePressure;
use fact_mine_rust::type_inference::TypeExpr;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DeclaredTypePressureFinding {
    pub at: String,
    pub file: String,
    pub method: String,
    pub owner: String,
    pub declaration_kind: String,
    pub slot: String,
    pub line: usize,
    pub union_width: usize,
    pub nested_union_width: usize,
    pub unknown_leaves: usize,
    pub collection_depth: usize,
    pub nilable: bool,
    pub nilable_collection: bool,
    pub signals: Vec<String>,
    pub cast_assertions: usize,
    pub positional_accesses: usize,
    pub decisions: usize,
    pub state_accesses: usize,
    pub related_functions: Vec<String>,
    pub score: usize,
}

#[derive(Default)]
struct FunctionEvidence {
    cast_assertions: usize,
    positional_accesses: usize,
    decisions: usize,
    state_accesses: usize,
}

type FunctionKey = (String, String, String);

pub fn scan(
    rows: &[DeclarationTypePressure],
    documents: &[&crate::decomplex::syntax::Document],
) -> Vec<DeclaredTypePressureFinding> {
    let evidence = function_evidence(documents);
    let mut findings = rows
        .iter()
        .filter_map(|row| {
            let mut signals = Vec::new();
            if row.union_width >= 4 {
                signals.push("wide_union".to_string());
            }
            if row.nested_union_width >= 2 {
                signals.push("nested_union".to_string());
            }
            if row.unknown_leaves > 0 {
                signals.push("unknown_leaf".to_string());
            }
            if row.collection_depth >= 2 {
                signals.push("nested_collection".to_string());
            }
            if row.nilable {
                signals.push("nilable".to_string());
            }
            if row.nilable_collection {
                signals.push("nilable_collection".to_string());
            }
            // A broad legal type is not independently a smell.
            if signals.len() < 2 {
                return None;
            }
            let related = related_function_keys(row, rows, documents);
            let cast_assertions = related
                .iter()
                .filter_map(|key| evidence.get(key))
                .map(|item| item.cast_assertions)
                .sum::<usize>();
            let positional_accesses = related
                .iter()
                .filter_map(|key| evidence.get(key))
                .map(|item| item.positional_accesses)
                .sum::<usize>();
            let decisions = related
                .iter()
                .filter_map(|key| evidence.get(key))
                .map(|item| item.decisions)
                .sum::<usize>();
            let state_accesses = related
                .iter()
                .filter_map(|key| evidence.get(key))
                .map(|item| item.state_accesses)
                .sum::<usize>();
            // Type shape alone is pressure, not convergence. Require both a
            // recovery/positional assumption and behavioral complexity in a
            // declaration consumer (or a direct caller of a pressured return).
            if cast_assertions + positional_accesses == 0 || decisions + state_accesses == 0 {
                return None;
            }
            let score = row.union_width
                + row.nested_union_width
                + row.unknown_leaves * 3
                + row.collection_depth
                + usize::from(row.nilable)
                + usize::from(row.nilable_collection) * 2
                + cast_assertions * 2
                + positional_accesses * 2
                + decisions
                + state_accesses;
            Some(DeclaredTypePressureFinding {
                at: format!("{}:{}:{}", row.path, row.declaration_name, row.line),
                file: row.path.clone(),
                method: row.declaration_name.clone(),
                owner: row.owner.clone(),
                declaration_kind: row.declaration_kind.clone(),
                slot: row.slot.clone(),
                line: row.line,
                union_width: row.union_width,
                nested_union_width: row.nested_union_width,
                unknown_leaves: row.unknown_leaves,
                collection_depth: row.collection_depth,
                nilable: row.nilable,
                nilable_collection: row.nilable_collection,
                signals,
                cast_assertions,
                positional_accesses,
                decisions,
                state_accesses,
                related_functions: related
                    .into_iter()
                    .map(|(_, owner, function)| format!("{owner}#{function}"))
                    .collect(),
                score,
            })
        })
        .collect::<Vec<_>>();
    findings.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.file.cmp(&right.file))
            .then_with(|| left.method.cmp(&right.method))
            .then_with(|| left.slot.cmp(&right.slot))
    });
    findings
}

fn function_evidence(
    documents: &[&crate::decomplex::syntax::Document],
) -> BTreeMap<FunctionKey, FunctionEvidence> {
    let mut out = BTreeMap::<FunctionKey, FunctionEvidence>::new();
    for document in documents {
        for call in &document.call_sites {
            let item = out
                .entry((document.file.clone(), call.owner.clone(), call.function.clone()))
                .or_default();
            if call.receiver == "T"
                && matches!(call.message.as_str(), "cast" | "must" | "assert_type!" | "unsafe")
            {
                item.cast_assertions += 1;
            }
            if call.message == "[]"
                && call.arguments.first().is_some_and(|argument| {
                    let argument = argument.trim();
                    argument.parse::<isize>().is_ok()
                        || argument
                            .split_once(',')
                            .is_some_and(|(first, _)| first.trim().parse::<isize>().is_ok())
                })
            {
                item.positional_accesses += 1;
            }
        }
        for decision in &document.branch_decisions {
            out.entry((
                document.file.clone(),
                owner_for_function(document, &decision.function, decision.line),
                decision.function.clone(),
            ))
            .or_default()
            .decisions += 1;
        }
        for read in &document.state_reads {
            if read.receiver == "self" {
                out.entry((document.file.clone(), read.owner.clone(), read.function.clone()))
                    .or_default()
                    .state_accesses += 1;
            }
        }
        for write in &document.state_writes {
            if write.receiver == "self" {
                out.entry((document.file.clone(), write.owner.clone(), write.function.clone()))
                    .or_default()
                    .state_accesses += 1;
            }
        }
    }
    out
}

fn owner_for_function(
    document: &crate::decomplex::syntax::Document,
    function: &str,
    line: usize,
) -> String {
    document
        .function_defs
        .iter()
        .find(|definition| {
            definition.name == function
                && definition.span[0] <= line
                && line <= definition.span[2]
        })
        .map(|definition| definition.owner.clone())
        .unwrap_or_default()
}

fn related_function_keys(
    row: &DeclarationTypePressure,
    rows: &[DeclarationTypePressure],
    documents: &[&crate::decomplex::syntax::Document],
) -> BTreeSet<FunctionKey> {
    let mut out = BTreeSet::new();
    if row.declaration_kind == "method_signature" {
        add_method_and_return_callers(row, documents, &mut out);
    } else if row.declaration_kind == "type_alias" {
        for consumer in rows.iter().filter(|candidate| {
            candidate.path == row.path
                && candidate.declaration_kind == "method_signature"
                && type_references(&candidate.declared_type, &row.declaration_name)
        }) {
            add_method_and_return_callers(consumer, documents, &mut out);
        }
    } else if row.declaration_kind == "state_field" {
        for document in documents.iter().filter(|document| document.file == row.path) {
            for access in document
                .state_reads
                .iter()
                .map(|read| (&read.owner, &read.function, &read.field))
                .chain(
                    document
                        .state_writes
                        .iter()
                        .map(|write| (&write.owner, &write.function, &write.field)),
                )
            {
                if access.0 == &row.owner && access.2 == &row.declaration_name {
                    out.insert((row.path.clone(), access.0.clone(), access.1.clone()));
                }
            }
        }
    }
    out
}

fn add_method_and_return_callers(
    row: &DeclarationTypePressure,
    documents: &[&crate::decomplex::syntax::Document],
    out: &mut BTreeSet<FunctionKey>,
) {
    out.insert((
        row.path.clone(),
        row.owner.clone(),
        row.declaration_name.clone(),
    ));
    if row.slot != "return" {
        return;
    }
    for document in documents.iter().filter(|document| document.file == row.path) {
        for call in document
            .call_sites
            .iter()
            .filter(|call| call.owner == row.owner && call.message == row.declaration_name)
        {
            out.insert((row.path.clone(), call.owner.clone(), call.function.clone()));
        }
    }
}

fn type_references(value: &TypeExpr, name: &str) -> bool {
    match value {
        TypeExpr::Primitive(value) => value == name || value.rsplit("::").next() == Some(name),
        TypeExpr::Nilable(inner) | TypeExpr::Array(inner) | TypeExpr::Set(inner) => {
            type_references(inner, name)
        }
        TypeExpr::Hash { key, value } => type_references(key, name) || type_references(value, name),
        TypeExpr::Union(parts) => parts.iter().any(|part| type_references(part, name)),
        TypeExpr::Untyped | TypeExpr::NilClass => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decomplex::syntax::Document;
    use fact_mine_rust::type_inference::TypeExpr;
    use serde_json::json;

    #[test]
    fn requires_converging_type_shape_signals() {
        let row = |nilable| DeclarationTypePressure {
            id: "id".into(),
            language: "ruby".into(),
            path: "a.rb".into(),
            owner: "A".into(),
            declaration_kind: "method_signature".into(),
            declaration_name: "Value".into(),
            slot: "return".into(),
            line: 1,
            declared_type: TypeExpr::Untyped,
            union_width: 5,
            nested_union_width: 0,
            unknown_leaves: 0,
            collection_depth: 0,
            nilable,
            nilable_collection: false,
        };
        assert!(scan(&[row(false)], &[]).is_empty());
        assert!(scan(&[row(true)], &[]).is_empty());

        let document: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "call_sites": [{
                "receiver": "T", "message": "cast", "file": "a.rb",
                "function": "consume_value", "owner": "A", "line": 3,
                "span": [3, 2, 3, 18], "conditional": false,
                "arguments": ["value", "String"], "safe_navigation": false,
                "block": false, "control": "always"
            }],
            "state_reads": [{
                "field": "mode", "receiver": "self", "file": "a.rb",
                "function": "consume_value", "owner": "A", "line": 4,
                "span": [4, 2, 4, 7]
            }]
        }))
        .unwrap();
        let mut method = row(true);
        method.declaration_name = "consume_value".into();
        let finding = scan(&[method], &[&document]).pop().unwrap();
        assert_eq!(finding.signals, vec!["wide_union", "nilable"]);
        assert_eq!(finding.cast_assertions, 1);
        assert_eq!(finding.state_accesses, 1);

        let mut alias = row(true);
        alias.declaration_kind = "type_alias".into();
        alias.slot = "alias_target".into();
        let mut consumer = row(false);
        consumer.declaration_name = "consume_value".into();
        consumer.declared_type = TypeExpr::Array(Box::new(TypeExpr::Primitive("Value".into())));
        consumer.union_width = 0;
        let alias_finding = scan(&[alias, consumer], &[&document]).remove(0);
        assert_eq!(alias_finding.method, "Value");
        assert_eq!(alias_finding.related_functions, vec!["A#consume_value"]);
    }
}
