use sql_cov::driver::sqlite_pool;
use sql_cov::schema::SchemaCatalog;
use sql_cov::{analyze_hazards, execute_sqlite_setup, DialectName, HazardKind};

const SCHEMA: &str = include_str!("fixtures/hazards.sql");
const OPERATORS: [&str; 6] = ["=", "<>", "<", "<=", ">", ">="];
const QUANTIFIERS: [&str; 2] = ["ANY", "ALL"];

async fn schema() -> SchemaCatalog {
    let pool = sqlite_pool("sqlite::memory:").await.unwrap();
    execute_sqlite_setup(&pool, SCHEMA).await.unwrap();
    SchemaCatalog::load_sqlite(&pool).await.unwrap()
}

fn has_quantified_hazard(sql: &str, schema: &SchemaCatalog) -> bool {
    analyze_hazards("quantified.sql", sql, DialectName::Postgres, schema)
        .unwrap()
        .findings
        .iter()
        .any(|finding| finding.kind == HazardKind::NullableAnyAll)
}

#[tokio::test]
async fn postgres_any_all_covers_every_strict_comparison_operator_and_null_source() {
    let schema = schema().await;
    for quantifier in QUANTIFIERS {
        for operator in OPERATORS {
            let nullable_left =
                format!("SELECT name FROM users WHERE bonus {operator} {quantifier} (ARRAY[1, 2])");
            assert!(
                has_quantified_hazard(&nullable_left, &schema),
                "missed nullable left operand: {nullable_left}"
            );

            let nullable_element = format!(
                "SELECT name FROM users WHERE age {operator} {quantifier} (ARRAY[1, NULL])"
            );
            assert!(
                has_quantified_hazard(&nullable_element, &schema),
                "missed nullable array element: {nullable_element}"
            );

            let non_null =
                format!("SELECT name FROM users WHERE age {operator} {quantifier} (ARRAY[1, 2])");
            assert!(
                !has_quantified_hazard(&non_null, &schema),
                "false positive for non-null operands: {non_null}"
            );
        }
    }
}

#[tokio::test]
async fn postgres_any_all_resolves_nullable_and_required_subquery_outputs() {
    let schema = schema().await;
    for quantifier in QUANTIFIERS {
        for operator in OPERATORS {
            let nullable_output = format!(
                "SELECT name FROM users WHERE age {operator} {quantifier} (SELECT bonus FROM users)"
            );
            assert!(
                has_quantified_hazard(&nullable_output, &schema),
                "missed nullable subquery output: {nullable_output}"
            );

            let required_output = format!(
                "SELECT name FROM users WHERE age {operator} {quantifier} (SELECT age FROM users)"
            );
            assert!(
                !has_quantified_hazard(&required_output, &schema),
                "false positive for required subquery output: {required_output}"
            );
        }
    }
}

#[tokio::test]
async fn postgres_some_alias_and_null_array_are_covered() {
    let schema = schema().await;
    assert!(has_quantified_hazard(
        "SELECT name FROM users WHERE age = SOME (ARRAY[1, NULL])",
        &schema
    ));
    assert!(has_quantified_hazard(
        "SELECT name FROM users WHERE age = ANY (NULL)",
        &schema
    ));
    assert!(has_quantified_hazard(
        "SELECT name FROM users WHERE age = ALL (NULL)",
        &schema
    ));
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Truth {
    True,
    False,
    Unknown,
}

fn compare(operator: &str, left: Option<i32>, right: Option<i32>) -> Truth {
    let (Some(left), Some(right)) = (left, right) else {
        return Truth::Unknown;
    };
    let value = match operator {
        "=" => left == right,
        "<>" => left != right,
        "<" => left < right,
        "<=" => left <= right,
        ">" => left > right,
        ">=" => left >= right,
        _ => unreachable!(),
    };
    if value {
        Truth::True
    } else {
        Truth::False
    }
}

fn quantified(quantifier: &str, operator: &str, left: Option<i32>, right: &[Option<i32>]) -> Truth {
    let comparisons = right
        .iter()
        .map(|right| compare(operator, left, *right))
        .collect::<Vec<_>>();
    match quantifier {
        "ANY" if comparisons.contains(&Truth::True) => Truth::True,
        "ANY" if comparisons.contains(&Truth::Unknown) => Truth::Unknown,
        "ANY" => Truth::False,
        "ALL" if comparisons.contains(&Truth::False) => Truth::False,
        "ALL" if comparisons.contains(&Truth::Unknown) => Truth::Unknown,
        "ALL" => Truth::True,
        _ => unreachable!(),
    }
}

#[test]
fn strict_any_all_truth_table_exhausts_empty_null_mixed_and_decisive_sets() {
    let left_values = [None, Some(0), Some(1)];
    let right_sets = [
        vec![],
        vec![None],
        vec![Some(0)],
        vec![Some(1)],
        vec![Some(0), None],
        vec![Some(1), None],
        vec![Some(0), Some(1)],
        vec![Some(0), Some(1), None],
    ];
    let mut cases = 0;
    for quantifier in QUANTIFIERS {
        for operator in OPERATORS {
            for left in left_values {
                for right in &right_sets {
                    let result = quantified(quantifier, operator, left, right);
                    if right.is_empty() {
                        assert_eq!(
                            result,
                            if quantifier == "ANY" {
                                Truth::False
                            } else {
                                Truth::True
                            }
                        );
                    }
                    if right.iter().all(Option::is_none) && !right.is_empty() {
                        assert_eq!(result, Truth::Unknown);
                    }
                    cases += 1;
                }
            }
        }
    }
    assert_eq!(cases, 288);
}
