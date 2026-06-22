use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct RustAstAdapter;

impl AstNormalizationAdapter for RustAstAdapter {
    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_expression").then_some("FOR")
    }

    fn hash_literal_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }
}
