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
        let args = descendant(node, &["value_arguments"])?;
        Some(named_children(args))
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
