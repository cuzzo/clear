use super::super::{named_children, node_text, TreeSitterNormalizer};
use super::base::AstNormalizationAdapter;
use std::collections::BTreeSet;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct CSharpAstAdapter;

impl AstNormalizationAdapter for CSharpAstAdapter {
    fn symbol_scope(
        &self,
        root: TreeSitterNode<'_>,
        source: &str,
    ) -> (String, Vec<(String, String)>) {
        let namespace = named_children(root)
            .into_iter()
            .find(|child| {
                matches!(
                    child.kind(),
                    "namespace_declaration" | "file_scoped_namespace_declaration"
                )
            })
            .and_then(|declaration| {
                declaration
                    .child_by_field_name("name")
                    .map(|name| node_text(name, source).trim().to_string())
                    .or_else(|| {
                        let text = node_text(declaration, source).trim();
                        text.strip_prefix("namespace ")
                            .and_then(|tail| tail.split(['{', ';']).next())
                            .map(str::trim)
                            .filter(|name| !name.is_empty())
                            .map(str::to_string)
                    })
            })
            .unwrap_or_default();
        (namespace, Vec::new())
    }

    fn tracks_dynamic_local_scope(&self) -> bool {
        true
    }

    fn scope_locals(
        &self,
        node: TreeSitterNode<'_>,
        normalizer: &TreeSitterNormalizer<'_>,
    ) -> BTreeSet<String> {
        csharp_scope_locals(normalizer, node)
    }

    fn direct_state_identifier(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() != "identifier" || csharp_local_declaration(node) {
            return None;
        }
        let name = node_text(node, source);
        (name.starts_with('_') && name.len() > 1).then_some(name.to_string())
    }

    fn state_field_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        // Private C# fields conventionally use a leading underscore and are
        // referenced directly inside instance methods. Preserve that receiver
        // identity in the normalized AST so downstream analyses do not mistake
        // a queue-drain loop for one bounded by an unrelated boolean flag.
        if node.kind() != "member_access_expression" {
            return None;
        }
        let children = named_children(node);
        let field = match children.as_slice() {
            [receiver, field, ..]
                if node_text(*receiver, source) == "this" && field.kind() == "identifier" =>
            {
                node_text(*field, source)
            }
            [field, ..] if field.kind() == "identifier" => node_text(*field, source),
            _ => return None,
        };
        field
            .starts_with('_')
            .then_some(field)
            .filter(|field| field.len() > 1)
            .map(|field| format!("@{field}"))
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "invocation_expression")
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        match kind {
            "for_statement" | "foreach_statement" => Some("FOR"),
            "while_statement" | "do_statement" => Some("WHILE"),
            _ => None,
        }
    }

    fn function_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "method_declaration" | "constructor_declaration" | "property_declaration"
        )
    }

    fn function_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "property_declaration" {
            return None;
        }
        // Block-bodied properties (get/set) have no `value` field - only
        // expression-bodied ones do. accessor_list's own blocks (empty for
        // an auto-property's `get;`/`set;`) normalize through the ordinary
        // statement path once reached.
        node.child_by_field_name("value").or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| child.kind() == "accessor_list")
        })
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

fn csharp_local_declaration(node: TreeSitterNode<'_>) -> bool {
    node.parent().is_some_and(|parent| {
        matches!(
            parent.kind(),
            "variable_declarator"
                | "parameter"
                | "catch_declaration"
                | "for_each_statement"
                | "declaration_expression"
        )
    })
}

fn csharp_scope_locals(
    normalizer: &TreeSitterNormalizer<'_>,
    node: TreeSitterNode<'_>,
) -> BTreeSet<String> {
    let mut locals = BTreeSet::new();
    collect_csharp_scope_locals(normalizer, node, &mut locals, true);
    locals
}

fn collect_csharp_scope_locals(
    normalizer: &TreeSitterNormalizer<'_>,
    node: TreeSitterNode<'_>,
    locals: &mut BTreeSet<String>,
    root: bool,
) {
    if !root
        && matches!(
            node.kind(),
            "method_declaration"
                | "constructor_declaration"
                | "property_declaration"
                | "lambda_expression"
                | "anonymous_method_expression"
        )
    {
        return;
    }
    if matches!(node.kind(), "parameter" | "variable_declarator") {
        if let Some(name) = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "identifier")
            .map(|child| node_text(child, normalizer.source).to_string())
        {
            locals.insert(name);
        }
    }
    for child in normalizer.named_children(node) {
        collect_csharp_scope_locals(normalizer, child, locals, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn extracts_block_and_file_scoped_namespaces() {
        let adapter = CSharpAstAdapter;
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_c_sharp::LANGUAGE.into())
            .unwrap();
        for source in [
            "namespace Demo.Core { class Item {} }",
            "namespace Demo.Core; class Item {}",
        ] {
            let tree = parser.parse(source, None).unwrap();
            let (namespace, imports) = adapter.symbol_scope(tree.root_node(), source);
            assert_eq!(namespace, "Demo.Core");
            assert!(imports.is_empty());
        }
    }
}
