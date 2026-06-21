use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct SwiftAstAdapter;

impl AstNormalizationAdapter for SwiftAstAdapter {
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
}
