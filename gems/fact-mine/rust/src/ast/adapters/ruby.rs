use super::super::{
    heredoc_marker_text, named_children, node_text, raw_named_children, ruby_variable_name_text,
    CASE_ARGUMENT_WHEN_KINDS, INTERPOLATED_STATEMENT_WRAPPER_KINDS, LEADING_FUNCTION_WRAPPER_KINDS,
};
use super::base::{AstNormalizationAdapter, NamedChildrenAction, RUBY_ASSIGNMENT_OPERATORS};
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct RubyAstAdapter;

impl AstNormalizationAdapter for RubyAstAdapter {
    fn ruby(&self) -> bool {
        true
    }

    fn yield_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) {
            return false;
        }
        let named = named_children(node);
        named.len() == 1
            && named[0].kind() == "yield"
            && node_text(named[0], source) == node_text(node, source)
    }

    fn super_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "call" | "statement"
        ) {
            return false;
        }
        if node_text(node, source).trim() == "super" {
            return true;
        }
        let raw = raw_named_children(node);
        let named = if raw.len() == 1 && raw[0].kind() == "call" {
            raw_named_children(raw[0])
        } else {
            raw
        };
        named
            .first()
            .map(|child| child.kind() == "super")
            .unwrap_or(false)
            && named
                .iter()
                .skip(1)
                .all(|child| child.kind() == "argument_list")
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "elsif" | "else"))
    }

    fn instance_variable(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "instance_variable"
            || node_text(node, source)
                .strip_prefix('@')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn global_variable(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "global_variable"
            || node_text(node, source)
                .strip_prefix('$')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn case_argument_list(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() != "argument_list" {
            return false;
        }
        let raw_named = named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "case"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            raw_named[0]
        } else {
            node
        };
        let has_case_keyword = target
            .children(&mut target.walk())
            .any(|child| !child.is_named() && child.kind() == "case");
        has_case_keyword
            && named_children(target)
                .iter()
                .any(|child| CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()))
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, source) == "&.")
    }

    fn leading_function_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.leading_function_statement_with_keyword(
            node,
            source,
            "def",
            LEADING_FUNCTION_WRAPPER_KINDS,
        )
    }

    fn zero_child_identifier_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() != "call" || !ruby_variable_name_text(node_text(node, source)) {
            return false;
        }
        let named = named_children(node);
        named.is_empty()
            || (named.len() == 1
                && super::super::identifier_kind_name(named[0].kind())
                && node_text(named[0], source) == node_text(node, source))
    }

    fn heredoc_call_for_body(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() == "heredoc_beginning" {
            return true;
        }
        if matches!(node.kind(), "call" | "argument_list")
            && heredoc_marker_text(node_text(node, source))
        {
            return true;
        }

        named_children(node).into_iter().any(|child| {
            if named_children(child)
                .into_iter()
                .any(|grandchild| grandchild.kind() == "heredoc_body")
            {
                return false;
            }

            self.heredoc_call_for_body(child, source)
        })
    }

    fn named_children_action<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> NamedChildrenAction<'tree> {
        if INTERPOLATED_STATEMENT_WRAPPER_KINDS.contains(&node.kind())
            && children.len() == 1
            && children[0].kind() == "string"
            && node_text(node, source) == node_text(children[0], source)
        {
            let string_children = raw_named_children(children[0]);
            if string_children
                .iter()
                .any(|child| child.kind() == "interpolation")
            {
                return NamedChildrenAction::Replace(string_children);
            }
        }

        if matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "if_modifier" | "unless_modifier" | "while_modifier" | "until_modifier" | "yield"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            return NamedChildrenAction::Recurse(children[0]);
        }

        NamedChildrenAction::Default
    }

    fn logical_operator_assignment(&self, operator: &str) -> bool {
        matches!(operator, "||" | "&&")
    }

    fn statement_wrapped_call_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return None;
        }
        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && raw_named[0].kind() == "call"
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            Some(raw_named[0])
        } else {
            None
        }
    }

    fn inline_def_function_text_source<'tree>(
        &self,
        function: TreeSitterNode<'tree>,
        _source: &str,
    ) -> TreeSitterNode<'tree> {
        if function.kind() == "call" {
            return named_children(function)
                .into_iter()
                .next()
                .unwrap_or(function);
        }
        function
    }

    fn bare_const_call_function(&self, function: TreeSitterNode<'_>) -> bool {
        matches!(
            function.kind(),
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
        )
    }

    fn normalize_default_parameters(&self) -> bool {
        true
    }

    fn normalize_block_parameters(&self) -> bool {
        true
    }

    fn boolean_statement_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> TreeSitterNode<'tree> {
        if children.len() == 1
            && matches!(
                children[0].kind(),
                "binary" | "binary_expression" | "binary_operator" | "boolean_operator"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            children[0]
        } else {
            node
        }
    }

    fn elides_tail_returns(&self) -> bool {
        true
    }

    fn elides_implicit_nil_body(&self) -> bool {
        true
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        RUBY_ASSIGNMENT_OPERATORS
    }
}
