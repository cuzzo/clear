use super::super::named_children;
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

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_block_statement_group" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .filter(|child| {
                !matches!(
                    child.kind(),
                    "switch_label"
                        | "switch_rule"
                        | "case_label"
                        | "default_label"
                        | "break_statement"
                )
            })
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }
}
