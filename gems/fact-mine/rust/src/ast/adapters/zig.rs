use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct ZigAstAdapter;

impl AstNormalizationAdapter for ZigAstAdapter {
    fn hash_literal_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn call_argument_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "call_expression" {
            return None;
        }
        let mut args = named_children(node)
            .into_iter()
            .filter(|child| Some(*child) != function)
            .collect::<Vec<_>>();
        if function.is_none() && !args.is_empty() {
            args.remove(0);
        }
        (!args.is_empty()).then_some(args)
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_case" {
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
