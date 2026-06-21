use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CSharpAstAdapter;

impl AstNormalizationAdapter for CSharpAstAdapter {
    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "invocation_expression")
    }

    fn block_node_kind(&self, kind: &str) -> bool {
        matches!(kind, "declaration_list")
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "foreach_statement").then_some("FOR")
    }
}
