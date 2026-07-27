use super::super::{named_children, node_text};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct JavaAstAdapter;

impl AstNormalizationAdapter for JavaAstAdapter {
    fn unqualified_types_use_current_namespace(&self) -> bool {
        true
    }

    // constructor_declaration has no return type or repeated method name, so
    // it needs its own arm alongside method_declaration; its body is still
    // reachable as constructor_body via the ordinary "body" field.
    fn function_kind(&self, kind: &str) -> bool {
        matches!(kind, "method_declaration" | "constructor_declaration")
    }

    fn symbol_scope(
        &self,
        root: TreeSitterNode<'_>,
        source: &str,
    ) -> (String, Vec<(String, String)>) {
        let mut namespace = String::new();
        let mut imports = Vec::new();
        for child in named_children(root) {
            let text = node_text(child, source).trim();
            match child.kind() {
                "package_declaration" => {
                    namespace = text
                        .strip_prefix("package")
                        .unwrap_or(text)
                        .trim()
                        .trim_end_matches(';')
                        .trim()
                        .to_string();
                }
                "import_declaration" if !text.starts_with("import static ") => {
                    let qualified = text
                        .strip_prefix("import")
                        .unwrap_or(text)
                        .trim()
                        .trim_end_matches(';')
                        .trim();
                    if !qualified.ends_with(".*") {
                        if let Some(short) = qualified.rsplit('.').next() {
                            imports.push((short.to_string(), qualified.to_string()));
                        }
                    }
                }
                _ => {}
            }
        }
        (namespace, imports)
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "method_invocation")
    }

    fn call_block_argument<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "method_invocation" {
            return None;
        }
        let name = node.child_by_field_name("name")?;
        if !matches!(node_text(name, source), "forEach" | "forEachRemaining") {
            return None;
        }
        let arguments = node.child_by_field_name("arguments").or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| child.kind() == "argument_list")
        })?;
        named_children(arguments)
            .into_iter()
            .find(|argument| argument.kind() == "lambda_expression")
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "enhanced_for_statement").then_some("FOR")
    }

    fn loop_condition_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        // In `for (T item : source.items())`, tree-sitter puts the binding
        // before the iterable. The generic first-child fallback therefore
        // discarded every call in the iterable expression. Preserve `value`
        // as the normalized loop condition so its calls and cardinality enter
        // the CFG/DFG.
        (node.kind() == "enhanced_for_statement")
            .then(|| node.child_by_field_name("value"))
            .flatten()
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
