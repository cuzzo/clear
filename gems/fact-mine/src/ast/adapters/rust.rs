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
        let target = node.child_by_field_name("type").or_else(|| {
            named_children(node).into_iter().find(|child| {
                matches!(
                    child.kind(),
                    "type_identifier" | "scoped_type_identifier" | "identifier"
                )
            })
        })?;
        // `impl<T> Cell<T>` yields a `generic_type` (`Cell<T>`); unwrap it to the
        // base identifier `Cell` so associated-function calls at the bare type
        // (`Cell::new`) resolve to these methods, and the impl owner unifies with
        // the struct owner instead of splitting into `Cell` and `Cell<T>`.
        if target.kind() == "generic_type" {
            return target.child_by_field_name("type").or_else(|| {
                named_children(target).into_iter().find(|child| {
                    matches!(
                        child.kind(),
                        "type_identifier" | "scoped_type_identifier" | "identifier"
                    )
                })
            });
        }
        Some(target)
    }

    fn class_like_owner_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        node.child_by_field_name("body").or(Some(node))
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

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn test_rust_adapter_fallback_paths() {
        let adapter = RustAstAdapter;
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_rust::LANGUAGE.into())
            .unwrap();

        let tree = parser.parse("struct Widget;", None).unwrap();
        let struct_node = tree.root_node().child(0).unwrap();
        assert_eq!(struct_node.kind(), "struct_item");

        let owner_name_node = adapter
            .class_like_owner_name(struct_node, "struct Widget;")
            .unwrap();
        assert_eq!(owner_name_node.kind(), "type_identifier");

        let tree2 = parser.parse("impl Widget { }", None).unwrap();
        let impl_node = tree2.root_node().child(0).unwrap();
        let body_node = adapter
            .class_like_owner_body(impl_node, "impl Widget { }")
            .unwrap();
        assert_eq!(body_node.kind(), "declaration_list");
    }
}
