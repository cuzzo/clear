use super::super::named_children;
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CAstAdapter;

impl AstNormalizationAdapter for CAstAdapter {
    fn preprocessor_callable_names(&self, root: TreeSitterNode<'_>, source: &str) -> Vec<String> {
        preprocessor_callable_names(root, source)
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
                    "identifier" | "number_literal" | "char_literal" | "break_statement"
                )
            })
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }

    fn custom_function_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() == "function_definition" {
            if let Some(decl) = node.child_by_field_name("declarator") {
                let mut stack = vec![decl];
                while !stack.is_empty() {
                    let child = stack.remove(0);
                    if child.kind() == "identifier" || child.kind() == "field_identifier" {
                        return Some(super::super::node_text(child, source).to_string());
                    }
                    stack.extend(named_children(child));
                }
            }
        }
        None
    }
}

pub(super) fn preprocessor_callable_names(root: TreeSitterNode<'_>, source: &str) -> Vec<String> {
    fn visit(node: TreeSitterNode<'_>, source: &str, names: &mut Vec<String>) {
        if node.kind() == "preproc_function_def" {
            if let Some(name) = node.child_by_field_name("name") {
                let name = super::super::node_text(name, source).trim();
                if !name.is_empty() {
                    names.push(name.to_string());
                }
            }
        }
        for child in named_children(node) {
            visit(child, source, names);
        }
    }
    let mut names = Vec::new();
    visit(root, source, &mut names);
    names.sort();
    names.dedup();
    names
}
