use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct RustAstAdapter;

impl AstNormalizationAdapter for RustAstAdapter {
    fn class_like_owner_kind(&self, kind: &str) -> bool {
        kind == "impl_item"
    }

    fn class_like_owner_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        node.child_by_field_name("type").or_else(|| {
            named_children(node).into_iter().find(|child| {
                matches!(
                    child.kind(),
                    "type_identifier" | "scoped_type_identifier" | "identifier"
                )
            })
        })
    }

    fn class_like_owner_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        node.child_by_field_name("body")
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| child.kind() == "declaration_list")
            })
            .or(Some(node))
    }

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
