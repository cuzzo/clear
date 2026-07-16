use crate::ast::{self, Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ShortCircuitOutcome {
    ConditionTrue,
    ConditionFalse,
}

pub(crate) fn outcomes(condition: Option<&Node>) -> Vec<ShortCircuitOutcome> {
    let mut out = Vec::new();
    if let Some(condition) = condition {
        collect(condition, &mut out);
    }
    out.sort_by_key(|outcome| match outcome {
        ShortCircuitOutcome::ConditionTrue => 0,
        ShortCircuitOutcome::ConditionFalse => 1,
    });
    out.dedup();
    out
}

fn collect(node: &Node, out: &mut Vec<ShortCircuitOutcome>) {
    match node.r#type.as_str() {
        "AND" => out.push(ShortCircuitOutcome::ConditionFalse),
        "OR" => out.push(ShortCircuitOutcome::ConditionTrue),
        _ => {}
    }

    for child in node.children.iter().filter_map(ast::node) {
        collect(child, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::Child;

    #[test]
    fn and_can_short_circuit_false() {
        assert_eq!(
            outcomes(Some(&node("AND", vec![node("VCALL", Vec::new())]))),
            vec![ShortCircuitOutcome::ConditionFalse]
        );
    }

    #[test]
    fn or_can_short_circuit_true() {
        assert_eq!(
            outcomes(Some(&node("OR", vec![node("VCALL", Vec::new())]))),
            vec![ShortCircuitOutcome::ConditionTrue]
        );
    }

    #[test]
    fn nested_boolean_outcomes_are_deduped() {
        assert_eq!(
            outcomes(Some(&node(
                "AND",
                vec![
                    node("OR", vec![node("VCALL", Vec::new())]),
                    node("AND", vec![node("VCALL", Vec::new())]),
                ],
            ))),
            vec![
                ShortCircuitOutcome::ConditionTrue,
                ShortCircuitOutcome::ConditionFalse,
            ]
        );
    }

    fn node(kind: &str, children: Vec<Node>) -> Node {
        Node {
            r#type: kind.to_string(),
            children: children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 1,
            text: kind.to_string(),
        }
    }
}
