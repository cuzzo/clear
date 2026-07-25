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
        // A single `import "os"` puts `import_spec` directly under
        // `import_declaration`; a grouped `import ( ... )` wraps each spec
        // in an intermediate `import_spec_list` - collect specs at either
        // depth rather than assuming one shape.
        fn collect_import_specs<'tree>(
            node: TreeSitterNode<'tree>,
            out: &mut Vec<TreeSitterNode<'tree>>,
        ) {
            for child in named_children(node) {
                if child.kind() == "import_spec" {
                    out.push(child);
                } else if child.kind() == "import_spec_list" {
                    collect_import_specs(child, out);
                }
            }
        }
        let mut specs = Vec::new();
        for decl in named_children(root)
            .into_iter()
            .filter(|child| child.kind() == "import_declaration")
        {
            collect_import_specs(decl, &mut specs);
        }
        let imports = specs
            .into_iter()
            .filter_map(|spec| go_import_alias_and_target(spec, source))
            .collect();
        (package, imports)
    }

    /// A Go function literal `func(...) ... { ... }` is a lambda, so it is
    /// normalized (and later extracted) as a first-class function whose Big-O is
    /// computed with the same pipeline as a named function.
    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "func_literal").then_some(node)
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        go_statement_without_inner_call(node)
    }

    fn if_initializer<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        (node.kind() == "if_statement")
            .then(|| node.child_by_field_name("initializer"))
            .flatten()
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

/// An `import_spec`'s `path` field carries its quoted string
/// (`"demo/util"`); an explicit `name` field (`util "demo/util"`,
/// including blank `_` and dot `.` imports) names the alias, otherwise the
/// alias importing code uses is the path's own last segment (Go's
/// convention: `import "demo/util"` still binds the identifier `util`,
/// from that package's own package clause, which by convention - and for
/// every case this can statically see - matches the last path segment).
/// Blank/dot imports still create a real dependency edge (a cycle through
/// one is exactly as real as through a named import), so they are kept,
/// not dropped - their alias just never happens to match a qualified call.
fn go_import_alias_and_target(spec: TreeSitterNode<'_>, source: &str) -> Option<(String, String)> {
    let path_node = spec.child_by_field_name("path")?;
    let target = node_text(path_node, source).trim_matches('"').to_string();
    if target.is_empty() {
        return None;
    }
    let alias = spec
        .child_by_field_name("name")
        .map(|name| node_text(name, source).to_string())
        .unwrap_or_else(|| target.rsplit('/').next().unwrap_or(&target).to_string());
    Some((alias, target))
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

    // Real bug: symbol_scope unconditionally returned Vec::new() for
    // imports, so Go emitted zero import facts regardless of what a
    // downstream consumer's resolver could do with them - a cycle or
    // dependency spanning a Go import edge was invisible to any tool
    // relying on fact-mine's imports, not just narrowly unsupported.
    #[test]
    fn symbol_scope_extracts_grouped_and_single_import_declarations() {
        let source = "package main\n\nimport (\n\t\"fmt\"\n\tutil \"demo/util\"\n\t_ \"demo/sideeffect\"\n)\n\nimport \"os\"\n\nfunc main() {}\n";
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_go::LANGUAGE.into())
            .unwrap();
        let tree = parser.parse(source, None).unwrap();

        let (package, imports) = GoAstAdapter.symbol_scope(tree.root_node(), source);
        assert_eq!(package, "main");
        assert_eq!(
            imports,
            vec![
                ("fmt".to_string(), "fmt".to_string()),
                ("util".to_string(), "demo/util".to_string()),
                ("_".to_string(), "demo/sideeffect".to_string()),
                ("os".to_string(), "os".to_string()),
            ]
        );
    }
}
