use super::super::{descendant, named_children, node_text};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct KotlinAstAdapter;

impl AstNormalizationAdapter for KotlinAstAdapter {
    fn hash_literal_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        matches!(kind, "for_statement").then_some("FOR")
    }

    // `fun f() = expr`: the expression is the function body, wrapped in a
    // `function_body` node whose leading `=` is expression-body syntax, not an
    // assignment. Without this the generic `assignment_rhs` check (prev sibling
    // is `=`) skips the expression, dropping the whole body - so expression-body
    // functions produced no calls, loops, or complexity facts at all.
    fn single_assignment_block_child(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.parent()
            .map(|parent| parent.kind() == "function_body")
            .unwrap_or(false)
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(node.kind(), "call_expression")
    }

    fn call_argument_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        let mut args = Vec::new();
        for child in named_children(node).into_iter().skip(1) {
            match child.kind() {
                "value_arguments" => args.extend(named_children(child)),
                "annotated_lambda" | "lambda_literal" => args.push(child),
                _ => {}
            }
        }
        Some(args)
    }

    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        match node.kind() {
            "lambda_literal" => Some(node),
            "annotated_lambda" => named_children(node)
                .into_iter()
                .find(|child| child.kind() == "lambda_literal"),
            _ => None,
        }
    }

    fn lambda_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        (node.kind() == "lambda_literal").then(|| {
            named_children(node)
                .into_iter()
                .filter(|child| child.kind() != "lambda_parameters")
                .collect()
        })
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "when_entry" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .take_while(|child| child.kind() != "call_expression")
            .filter(|child| child.kind() != "else")
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }

    // `class Widget(private var count: Int)`: `count` is a `class_parameter`
    // of a `primary_constructor` sibling of `class_body`, not a child of
    // `class_body` itself, so the default class-body scan never sees it.
    // Only `var`/`val` parameters declare a property (a plain constructor
    // parameter with neither is just a parameter, not state) - checked as a
    // whole whitespace-separated token, not a substring match, so a type or
    // parameter named e.g. `Variable` can't false-positive.
    fn supplementary_class_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(primary_constructor) = descendant(node, &["primary_constructor"]) else {
            return Vec::new();
        };
        // The actual parse tree wraps parameters in an intermediate
        // `class_parameters` node (a comma-separated list container) even
        // though tree-sitter-kotlin's node-types.json lists `class_parameter`
        // as a direct child of `primary_constructor` - handle both shapes
        // rather than assuming one.
        named_children(primary_constructor)
            .into_iter()
            .flat_map(|child| {
                if child.kind() == "class_parameter" {
                    vec![child]
                } else {
                    named_children(child)
                }
            })
            .filter(|param| param.kind() == "class_parameter")
            .filter(|param| {
                let text = node_text(*param, source);
                let before_colon = text.split(':').next().unwrap_or(text);
                before_colon
                    .split_whitespace()
                    .any(|token| token == "var" || token == "val")
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use crate::profile::{self, Profile};
    use crate::syntax::{self, Language};
    use anyhow::{Context, Result};
    use std::collections::BTreeSet;
    use std::fs;

    #[test]
    fn trailing_lambdas_preserve_all_nested_calls() -> Result<()> {
        let tmp = tempfile::Builder::new().suffix(".kt").tempfile()?;
        fs::write(
            tmp.path(),
            r#"fun render(values: List<String>) = buildString {
  append("[")
  values.forEach { value ->
    append(value.trim())
  }
  append("]")
}
"#,
        )?;
        let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Kotlin)?;
        let output = profile::extract(&document, Profile::Espalier);
        output
            .methods
            .iter()
            .find(|method| method.name == "render")
            .context("render method")?;
        let messages = output
            .calls
            .iter()
            .map(|call| call.message.as_str())
            .collect::<BTreeSet<_>>();
        for expected in ["buildString", "append", "forEach", "trim"] {
            assert!(messages.contains(expected), "calls={messages:?}");
        }
        assert_eq!(
            output
                .call_resolution_coverage
                .raw_calls_not_normalized_inside_function,
            0
        );
        Ok(())
    }
}
