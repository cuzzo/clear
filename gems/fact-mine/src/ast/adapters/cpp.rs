use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CppAstAdapter;

impl AstNormalizationAdapter for CppAstAdapter {
    fn valid_function_definition(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        if node.kind() != "function_definition" {
            return true;
        }
        let Some(declarator) = node.child_by_field_name("declarator") else {
            return false;
        };
        cpp_function_declarator(declarator)
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(
            kind,
            "for_statement" | "for_range_loop" | "range_based_for_statement"
        )
        .then_some("FOR")
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "case_statement" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "qualified_identifier" | "identifier" | "break_statement"
                )
            })
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "case_statement" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .take_while(|child| !matches!(child.kind(), "expression_statement" | "break_statement"))
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }

    fn custom_function_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() == "function_definition" {
            if let Some(decl) = node.child_by_field_name("declarator") {
                let mut stack = vec![decl];
                while !stack.is_empty() {
                    let child = stack.remove(0);
                    if child.kind() == "identifier"
                        || child.kind() == "field_identifier"
                        || child.kind() == "qualified_identifier"
                        || child.kind() == "destructor_name"
                    {
                        return Some(super::super::node_text(child, source).to_string());
                    }
                    stack.extend(named_children(child));
                }
            }
        }
        None
    }
}

fn cpp_function_declarator(node: TreeSitterNode<'_>) -> bool {
    if matches!(node.kind(), "function_declarator" | "operator_cast") {
        return true;
    }
    named_children(node)
        .into_iter()
        .any(cpp_function_declarator)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn rejects_preprocessor_recovery_that_looks_like_a_function() {
        let source =
            "FMT_BEGIN_NAMESPACE\nnamespace detail {\nint real_function() { return 1; }\n}\n";
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_cpp::LANGUAGE.into())
            .unwrap();
        let tree = parser.parse(source, None).unwrap();
        let mut nodes = vec![tree.root_node()];
        let mut saw_recovery = false;
        while let Some(node) = nodes.pop() {
            if node.kind() == "function_definition" {
                saw_recovery |=
                    !cpp_function_declarator(node.child_by_field_name("declarator").unwrap());
                if !cpp_function_declarator(node.child_by_field_name("declarator").unwrap()) {
                    assert!(!CppAstAdapter.valid_function_definition(node, source));
                }
            }
            nodes.extend(named_children(node));
        }
        assert!(saw_recovery);
    }

    #[test]
    fn normalizes_counted_for_loops_alongside_range_loops() {
        let adapter = CppAstAdapter;
        assert_eq!(adapter.loop_node_type("for_statement"), Some("FOR"));
        assert_eq!(adapter.loop_node_type("for_range_loop"), Some("FOR"));
        assert_eq!(
            adapter.loop_node_type("range_based_for_statement"),
            Some("FOR")
        );
    }
}
