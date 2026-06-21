use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct JavaAstAdapter;

impl AstNormalizationAdapter for JavaAstAdapter {
    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "method_invocation")
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "enhanced_for_statement").then_some("FOR")
    }
}
