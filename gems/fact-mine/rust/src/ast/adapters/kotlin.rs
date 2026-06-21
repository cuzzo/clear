use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct KotlinAstAdapter;

impl AstNormalizationAdapter for KotlinAstAdapter {
    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_statement").then_some("FOR")
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "call_expression")
    }
}
