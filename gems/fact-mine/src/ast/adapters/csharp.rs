use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CSharpAstAdapter;

impl AstNormalizationAdapter for CSharpAstAdapter {
    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "invocation_expression")
    }


    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "foreach_statement").then_some("FOR")
    }

    fn hash_literal_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if matches!(node.kind(), "block" | "declaration_list") {
            return None;
        }
        None
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_section" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "case_switch_label"
                        | "switch_label"
                        | "case_pattern_switch_label"
                        | "constant_pattern"
                        | "default_switch_label"
                        | "break_statement"
                )
            })
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }
}
