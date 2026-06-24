use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CppAstAdapter;

impl AstNormalizationAdapter for CppAstAdapter {
    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_range_loop" | "range_based_for_statement").then_some("FOR")
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
            let mut stack = named_children(node);
            while !stack.is_empty() {
                let child = stack.remove(0);
                if child.kind() == "identifier" || child.kind() == "field_identifier" || child.kind() == "qualified_identifier" || child.kind() == "destructor_name" {
                    return Some(super::super::node_text(child, source).to_string());
                }
                stack.extend(named_children(child));
            }
        }
        None
    }
}
