use super::super::{descendant, named_children};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct SwiftAstAdapter;

impl AstNormalizationAdapter for SwiftAstAdapter {
    fn dollar_prefixed_local_name(&self, text: &str) -> Option<String> {
        let text = text.trim();
        (text.starts_with('$')
            && text.len() > 1
            && text[1..]
                .chars()
                .all(|character| character.is_ascii_digit()))
        .then(|| text.to_string())
    }

    fn loop_condition_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "for_statement")
            .then(|| node.child_by_field_name("collection"))
            .flatten()
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "if_statement" {
            return None;
        }
        let mut saw_else = false;
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if child.kind() == "else" {
                saw_else = true;
                continue;
            }
            if saw_else && child.is_named() {
                return Some(child);
            }
        }
        None
    }

    fn function_parameter_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "function_declaration" {
            return None;
        }
        let params = named_children(node)
            .into_iter()
            .filter(|child| child.kind() == "parameter")
            .collect::<Vec<_>>();
        (!params.is_empty()).then_some(params)
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "call_expression")
    }

    fn boolean_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "conjunction_expression" | "disjunction_expression"
        )
    }

    fn comparison_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "equality_expression" | "comparison_expression")
    }

    fn call_argument_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        let args = descendant(node, &["value_arguments"])?;
        Some(named_children(args))
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_entry" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .filter(|child| child.kind() == "switch_pattern")
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }
}
