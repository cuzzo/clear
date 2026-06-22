use super::super::{
    named_children, node_text, question_colon_ternary_parts, raw_named_children, TernaryParts,
    TYPESCRIPT_TERNARY_KINDS,
};
use super::base::{AstNormalizationAdapter, TYPESCRIPT_ASSIGNMENT_OPERATORS};
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct TypeScriptAstAdapter;

impl AstNormalizationAdapter for TypeScriptAstAdapter {
    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "else" | "else_clause"))
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, source) == "&.")
            || node
                .children(&mut node.walk())
                .any(|child| child.kind() == "optional_chain" && node_text(child, source) == "?.")
            || (node.kind() == "call_expression"
                && named_children(node)
                    .into_iter()
                    .any(|child| self.safe_navigation_call(child, source)))
    }

    fn ternary_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TernaryParts<'tree>> {
        question_colon_ternary_parts(node, source, TYPESCRIPT_TERNARY_KINDS)
    }

    fn interpolated_string(
        &self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        (node.kind() == "string" && children.iter().any(|child| child.kind() == "interpolation"))
            || (node.kind() == "template_string"
                && children
                    .iter()
                    .any(|child| child.kind() == "template_substitution"))
    }

    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if matches!(
            node.kind(),
            "arrow_function" | "function_expression" | "lambda"
        ) {
            Some(node)
        } else {
            None
        }
    }

    fn interpolation_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "interpolation" | "template_substitution")
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_case" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .skip(1)
            .filter(|child| child.kind() != "break_statement")
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_case" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .take_while(|child| child.kind() != "expression_statement")
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement" {
            return Some(node);
        }
        if node.kind() == "statement_block" {
            let raw_named = raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "try_statement"
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
        }
        if super::super::RESCUE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn rescue_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.rescue_body_target(node, source).unwrap_or(node);
        if target.kind() == "try_statement" {
            return named_children(target)
                .into_iter()
                .take_while(|child| !matches!(child.kind(), "catch_clause" | "finally_clause"))
                .collect();
        }
        let named = named_children(target);
        let Some(index) = named.iter().position(|child| self.rescue_clause(*child)) else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn rescue_clauses<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.rescue_body_target(node, source) else {
            return Vec::new();
        };
        named_children(target)
            .into_iter()
            .filter(|child| child.kind() == "catch_clause")
            .collect()
    }

    fn rescue_clause_exceptions<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        Vec::new()
    }

    fn rescue_clause_exceptions_source<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn rescue_clause_exception_variable_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| super::super::identifier_kind_name(child.kind()))
    }

    fn rescue_clause_exception_variable_source<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.rescue_clause_exception_variable_name(node)
    }

    fn rescue_clause_handler<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == "statement_block")
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement" {
            return Some(node);
        }
        if node.kind() == "statement_block" {
            let raw_named = raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "try_statement"
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
        }
        if super::super::ENSURE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn ensure_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.ensure_body_target(node, source).unwrap_or(node);
        if target.kind() == "try_statement" {
            return named_children(target)
                .into_iter()
                .take_while(|child| child.kind() != "finally_clause")
                .collect();
        }
        let named = named_children(target);
        let Some(index) = named
            .iter()
            .position(|child| self.ensure_clause_kind(*child))
        else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn ensure_clause<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let target = self.ensure_body_target(node, source)?;
        named_children(target)
            .into_iter()
            .find(|child| child.kind() == "finally_clause")
    }

    fn ensure_clause_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == "statement_block")
    }

    fn empty_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        (super::super::EMPTY_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node).is_empty()
            && node_text(node, source).trim().is_empty())
            || (node.kind() == "statement_block"
                && named_children(node).is_empty()
                && node_text(node, source).trim() == "{}")
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        TYPESCRIPT_ASSIGNMENT_OPERATORS
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        match kind {
            "for_in_statement" | "for_statement" => Some("FOR"),
            "while_statement" => Some("WHILE"),
            _ => None,
        }
    }
}
