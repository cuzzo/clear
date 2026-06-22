use super::super::{descendant, named_children};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct KotlinAstAdapter;

impl AstNormalizationAdapter for KotlinAstAdapter {
    fn hash_literal_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_statement").then_some("FOR")
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "call_expression")
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
        if node.kind() != "when_entry" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .take_while(|child| child.kind() != "call_expression")
            .filter(|child| child.kind() != "else")
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }
}
