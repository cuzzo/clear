use super::super::{named_children, node_text};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct RustAstAdapter;

impl AstNormalizationAdapter for RustAstAdapter {
    fn variable_declarator_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "let_declaration" | "static_item")
    }

    fn variable_declarator_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "let_declaration")
            .then(|| node.child_by_field_name("alternative"))
            .flatten()
    }

    fn class_like_owner_kind(&self, kind: &str) -> bool {
        kind == "impl_item"
    }

    fn case_arm_guard<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "match_arm")
            .then(|| {
                node.child_by_field_name("pattern")
                    .and_then(|pattern| pattern.child_by_field_name("condition"))
            })
            .flatten()
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
        node.child_by_field_name("body").or(Some(node))
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_expression").then_some("FOR")
    }

    fn loop_condition_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        // A Rust `for binding in iterable` stores the binding before `value`.
        // Selecting the generic first named child drops calls and size domains
        // from the iterable expression.
        (node.kind() == "for_expression")
            .then(|| node.child_by_field_name("value"))
            .flatten()
    }

    fn scoped_call_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
        if node.kind() != "scoped_identifier" {
            return None;
        }
        // `Cell::new` -> receiver `Cell` (the `path` field), method `new` (the
        // `name` field). `std::mem::replace` -> receiver `std::mem`, method
        // `replace`. Only the terminal segment becomes the message.
        let path = node.child_by_field_name("path")?;
        let name = node.child_by_field_name("name")?;
        Some((path, node_text(name, source).to_string()))
    }

    /// A Rust closure `|x| ...` is a lambda, so it is normalized (and later
    /// extracted) as a first-class function. Its own Big-O is what a caller
    /// substitutes for the callee's parametric callback cost.
    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "closure_expression").then_some(node)
    }

    fn type_argument_callee<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "generic_function" {
            return None;
        }
        node.child_by_field_name("function")
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
