use super::{FunctionDef, LocalComplexityScore};
use crate::decomplex::ast::RawNode;
use std::collections::BTreeMap;
use std::path::Path;

pub(crate) fn local_complexity_scores(
    file: &str,
    functions: &[FunctionDef],
) -> BTreeMap<String, LocalComplexityScore> {
    functions
        .iter()
        .map(|function| {
            let owner = local_method_owner(file, &function.owner);
            let id = format!("{}#{}", owner, function.name);
            (id, LocalComplexityScorer::new().score(&function.body))
        })
        .collect()
}

struct LocalComplexityScorer;

impl LocalComplexityScorer {
    fn new() -> Self {
        Self
    }

    fn score(&self, method_node: &RawNode) -> LocalComplexityScore {
        let mut signals = BTreeMap::new();
        LocalComplexityScore {
            score: self.round(self.score_node(method_node, 0, &mut signals)),
            signals,
        }
    }

    fn score_node(
        &self,
        node: &RawNode,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        if skip_nested(node) {
            return 0.0;
        }

        if branch(node) {
            *signals.entry("branches".to_string()).or_insert(0) += 1;
            if nesting > 0 {
                *signals.entry("nested".to_string()).or_insert(0) += 1;
            }
            return self.branch_cost(nesting)
                + self.predicate_cost(condition_node(node), signals)
                + self.score_children(node, nesting + 1, signals);
        }

        if loop_node(node) {
            *signals.entry("loops".to_string()).or_insert(0) += 1;
            if nesting > 0 {
                *signals.entry("nested".to_string()).or_insert(0) += 1;
            }
            return self.branch_cost(nesting) + self.score_children(node, nesting + 1, signals);
        }

        if case_node(node) {
            *signals.entry("cases".to_string()).or_insert(0) += 1;
            return 0.5 + self.score_children(node, nesting + 1, signals);
        }

        if rescue_node(node) {
            *signals.entry("rescues".to_string()).or_insert(0) += 1;
            return self.branch_cost(nesting) + self.score_children(node, nesting + 1, signals);
        }

        if early_exit(node) {
            *signals.entry("early_exits".to_string()).or_insert(0) += 1;
            let exit_cost = if nesting > 0 {
                0.5 + (nesting as f64 * 0.25)
            } else {
                0.0
            };
            let child_cost = if bare_early_exit_wrapper(node) {
                0.0
            } else {
                self.score_children(node, nesting, signals)
            };
            return exit_cost + child_cost;
        }

        if boolean_node(node) {
            *signals.entry("boolean_ops".to_string()).or_insert(0) += 1;
            return 0.25 + self.score_children(node, nesting, signals);
        }

        self.score_children(node, nesting, signals)
    }

    fn score_children(
        &self,
        node: &RawNode,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        compensated_sum(node.children.iter().map(|child| {
            if transparent_single_line_suite_statement(node, child) {
                if bare_early_exit_wrapper(child) {
                    0.0
                } else {
                    self.score_children(child, nesting, signals)
                }
            } else {
                self.score_node(child, nesting, signals)
            }
        }))
    }

    fn predicate_cost(&self, node: Option<&RawNode>, signals: &mut BTreeMap<String, usize>) -> f64 {
        let Some(node) = node else { return 0.0 };
        let bools = boolean_count(node);
        *signals.entry("boolean_ops".to_string()).or_insert(0) += bools;
        (bools as f64) * 0.5
    }

    fn branch_cost(&self, nesting: usize) -> f64 {
        1.1 + (nesting as f64)
    }

    fn round(&self, value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }
}

fn local_method_owner(file: &str, owner: &str) -> String {
    let file_owner = file_owner(file);
    if owner == file_owner {
        return "(top-level)".to_string();
    }
    owner
        .strip_prefix(&format!("{file_owner}::"))
        .unwrap_or(owner)
        .to_string()
}

fn file_owner(file: &str) -> String {
    Path::new(file)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("Object")
        .to_string()
}

fn skip_nested(node: &RawNode) -> bool {
    matches!(node.kind.as_str(), "class" | "module" | "lambda")
}

fn branch(node: &RawNode) -> bool {
    (matches!(
        node.kind.as_str(),
        "if" | "unless" | "if_statement" | "if_expression" | "if_modifier" | "unless_modifier"
    ) && !node.named_children().is_empty())
        || hidden_if(node)
        || modifier_if(node)
}

fn hidden_if(node: &RawNode) -> bool {
    if node.kind == "expression_statement" && node.text.trim_start().starts_with("if ") {
        return true;
    }
    matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list"
    ) && node
        .children
        .first()
        .map(|child| !child.named && matches!(child.kind.as_str(), "if" | "unless"))
        .unwrap_or(false)
}

fn modifier_if(node: &RawNode) -> bool {
    if matches!(node.kind.as_str(), "if_modifier" | "unless_modifier") {
        return true;
    }
    if node.kind != "body_statement" {
        return false;
    }
    let mut seen_named = false;
    node.children.iter().any(|child| {
        seen_named |= child.named;
        seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless")
    })
}

fn loop_node(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "while"
            | "until"
            | "while_statement"
            | "for"
            | "for_statement"
            | "for_in_statement"
            | "do_block"
    ) || hidden_loop(node)
        || (node.kind == "expression_statement"
            && starts_with_any(node.text.trim_start(), &["for", "while", "loop"]))
        || (node.kind == "labeled_statement" && node.text.trim_start().starts_with("for "))
}

fn hidden_loop(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list"
    ) && node
        .children
        .first()
        .map(|child| !child.named && matches!(child.kind.as_str(), "for" | "while" | "loop"))
        .unwrap_or(false)
}

fn starts_with_any(text: &str, words: &[&str]) -> bool {
    words
        .iter()
        .any(|word| text == *word || text.starts_with(&format!("{word} ")))
}

fn case_node(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "case" | "switch_statement" | "switch_expression" | "match_statement" | "match_expression"
    ) || (node.kind == "expression_statement" && node.text.trim_start().starts_with("match "))
}

fn rescue_node(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "rescue" | "rescue_modifier" | "rescue_clause" | "rescue_body"
    )
}

fn early_exit(node: &RawNode) -> bool {
    (node.named || node.kind == "return")
        && matches!(
            node.kind.as_str(),
            "return"
                | "break"
                | "next"
                | "redo"
                | "retry"
                | "return_statement"
                | "break_statement"
                | "continue_statement"
        )
}

fn transparent_single_line_suite_statement(parent: &RawNode, child: &RawNode) -> bool {
    parent.kind == "block"
        && parent.children.len() == 1
        && parent.text == child.text
        && matches!(
            child.kind.as_str(),
            "return_statement" | "break_statement" | "continue_statement"
        )
}

fn bare_early_exit_wrapper(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "return_statement" | "break_statement" | "continue_statement"
    ) && node.children.len() == 1
        && !node.children[0].named
        && node.children[0].text == node.text
}

fn boolean_node(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "binary"
            | "binary_expression"
            | "boolean_operator"
            | "conjunction_expression"
            | "disjunction_expression"
    ) && node
        .children
        .iter()
        .any(|child| !child.named && matches!(child.text.as_str(), "&&" | "||" | "and" | "or"))
}

fn condition_node(node: &RawNode) -> Option<&RawNode> {
    if modifier_if(node) {
        return node.named_children().last().copied();
    }
    if node.kind == "body_statement" {
        return node.named_children().first().copied();
    }
    node.named_children().first().copied()
}

fn boolean_count(node: &RawNode) -> usize {
    let own = usize::from(boolean_node(node));
    own + node.children.iter().map(boolean_count).sum::<usize>()
}

fn compensated_sum(values: impl IntoIterator<Item = f64>) -> f64 {
    let mut sum = 0.0f64;
    let mut compensation = 0.0f64;
    for value in values {
        let next = sum + value;
        if sum.abs() >= value.abs() {
            compensation += (sum - next) + value;
        } else {
            compensation += (value - next) + sum;
        }
        sum = next;
    }
    sum + compensation
}
