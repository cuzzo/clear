use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct GoAstAdapter;

impl AstNormalizationAdapter for GoAstAdapter {
    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        go_statement_without_inner_call(node)
    }

    fn intrinsic_call_name(&self, node: TreeSitterNode<'_>, _source: &str) -> Option<&'static str> {
        go_statement_without_inner_call(node).then_some("go")
    }

    fn call_argument_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if !go_statement_without_inner_call(node) {
            return None;
        }
        let arguments = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "parenthesized_expression")?;
        Some(named_children(arguments))
    }

    fn case_else_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "default_case")
    }

    fn case_else_arm(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "default_case"
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if !matches!(node.kind(), "expression_case" | "default_case") {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .filter(|child| !matches!(child.kind(), "expression_list"))
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }
}

fn go_statement_without_inner_call(node: TreeSitterNode<'_>) -> bool {
    node.kind() == "go_statement"
        && !named_children(node)
            .into_iter()
            .any(|child| child.kind() == "call_expression")
}
