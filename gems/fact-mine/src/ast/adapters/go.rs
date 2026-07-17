use super::super::{named_children, node_text};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct GoAstAdapter;

impl AstNormalizationAdapter for GoAstAdapter {
    fn symbol_scope(
        &self,
        root: TreeSitterNode<'_>,
        source: &str,
    ) -> (String, Vec<(String, String)>) {
        let package = named_children(root)
            .into_iter()
            .find(|child| child.kind() == "package_clause")
            .map(|child| node_text(child, source))
            .and_then(|text| text.split_whitespace().nth(1).map(str::to_string))
            .unwrap_or_default();
        (package, Vec::new())
    }

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

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn test_go_adapter_fallback_paths() {
        let adapter = GoAstAdapter;
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_go::LANGUAGE.into())
            .unwrap();

        // test case_arm_body_nodes fallback None path (line 51)
        let tree = parser
            .parse("package main\nfunc main() { var x = 5 }", None)
            .unwrap();
        let var_node = tree.root_node().child(1).unwrap();
        assert!(adapter.case_arm_body_nodes(var_node, "").is_none());

        // test call_argument_nodes fallback None path
        assert!(adapter.call_argument_nodes(var_node, None, "").is_none());

        // go statement with parenthesized_expression argument
        let tree_go = parser
            .parse("package main\nfunc main() { go (x) }", None)
            .unwrap();
        let mut go_node = None;
        let mut queue = vec![tree_go.root_node()];
        while let Some(n) = queue.pop() {
            if n.kind() == "go_statement" {
                go_node = Some(n);
                break;
            }
            for i in 0..n.child_count() {
                queue.push(n.child(i).unwrap());
            }
        }
        let n = go_node.unwrap();
        let args = adapter.call_argument_nodes(n, None, "go (x)").unwrap();
        assert_eq!(args.len(), 1);
        assert_eq!(args[0].kind(), "identifier");
    }

}
