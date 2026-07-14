use fact_mine_rust::profile::DeclarationTypePressure;
use serde::Serialize;

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
    pub score: usize,
}

pub fn scan(rows: &[DeclarationTypePressure]) -> Vec<DeclaredTypePressureFinding> {
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
            let score = row.union_width
                + row.nested_union_width
                + row.unknown_leaves * 3
                + row.collection_depth
                + usize::from(row.nilable)
                + usize::from(row.nilable_collection) * 2;
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

#[cfg(test)]
mod tests {
    use super::*;
    use fact_mine_rust::type_inference::TypeExpr;

    #[test]
    fn requires_converging_type_shape_signals() {
        let row = |nilable| DeclarationTypePressure {
            id: "id".into(),
            language: "ruby".into(),
            path: "a.rb".into(),
            owner: "A".into(),
            declaration_kind: "type_alias".into(),
            declaration_name: "Value".into(),
            slot: "alias_target".into(),
            line: 1,
            declared_type: TypeExpr::Untyped,
            union_width: 5,
            nested_union_width: 0,
            unknown_leaves: 0,
            collection_depth: 0,
            nilable,
            nilable_collection: false,
        };
        assert!(scan(&[row(false)]).is_empty());
        let findings = scan(&[row(true)]);
        assert_eq!(findings[0].signals, vec!["wide_union", "nilable"]);
    }
}
