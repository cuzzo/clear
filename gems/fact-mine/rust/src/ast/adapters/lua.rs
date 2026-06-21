use super::super::{
    bracketed, direct_binary_operator, lua_keyed_table_target, lua_positional_table_target,
    named_children, node_text, raw_named_children, LUA_LEADING_FUNCTION_WRAPPER_KINDS,
    LUA_LEADING_IF_WRAPPER_KINDS,
};
use super::base::{AstNormalizationAdapter, NamedChildrenAction, LUA_ASSIGNMENT_OPERATORS};
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct LuaAstAdapter;

impl AstNormalizationAdapter for LuaAstAdapter {
    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "elseif_statement" | "else" | "else_statement"))
    }

    fn ternary_parts<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<super::super::TernaryParts<'tree>> {
        None
    }

    fn named_children_action<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> NamedChildrenAction<'tree> {
        if node.kind() == "variable_list" && children.len() == 1 {
            if children[0].kind() == "identifier" && lua_single_assignment_block_child(node, source)
            {
                return NamedChildrenAction::Drop;
            }
            if node
                .parent()
                .map(|parent| parent.kind() == "for_generic_clause")
                .unwrap_or(false)
            {
                return NamedChildrenAction::Drop;
            }
            if node
                .parent()
                .map(|parent| {
                    parent.kind() == "variable_declaration" && raw_named_children(parent).len() == 1
                })
                .unwrap_or(false)
            {
                return NamedChildrenAction::Drop;
            }
            if children[0].kind() == "dot_index_expression"
                && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Recurse(children[0]);
            }
        }

        if node.kind() == "expression_list" && children.len() == 1 {
            if children[0].kind() == "identifier"
                && node
                    .parent()
                    .map(|parent| {
                        matches!(parent.kind(), "assignment_statement" | "return_statement")
                    })
                    .unwrap_or(false)
                && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Drop;
            }
            if matches!(
                children[0].kind(),
                "true" | "false" | "nil" | "number" | "integer" | "float"
            ) && node
                .parent()
                .map(|parent| matches!(parent.kind(), "assignment_statement" | "return_statement"))
                .unwrap_or(false)
                && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Drop;
            }
            if matches!(
                children[0].kind(),
                "binary_expression"
                    | "function_call"
                    | "dot_index_expression"
                    | "function_definition"
                    | "string"
                    | "table_constructor"
            ) && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Recurse(children[0]);
            }
        }

        if node.kind() == "field" && children.len() == 1 {
            if children[0].kind() == "identifier"
                && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Drop;
            }
            if matches!(children[0].kind(), "string" | "function_call")
                && node_text(node, source) == node_text(children[0], source)
            {
                return NamedChildrenAction::Recurse(children[0]);
            }
        }

        if node.kind() == "block"
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "function_call" | "return_statement" | "variable_declaration"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            return NamedChildrenAction::Recurse(children[0]);
        }

        NamedChildrenAction::Default
    }

    fn unary_minus_expression(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        (matches!(node.kind(), "unary" | "unary_expression")
            && node_text(node, source).trim_start().starts_with('-'))
            || (node.kind() == "expression_list"
                && node
                    .children(&mut node.walk())
                    .next()
                    .map(|child| node_text(child, source) == "-")
                    .unwrap_or(false)
                && named_children(node).len() == 1)
    }

    fn binary_operator(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if let Some(operator) = direct_binary_operator(node, source) {
            return Some(operator.to_string());
        }

        let child = self.exact_single_named_child(node, self.binary_wrapper_kinds(), source)?;
        self.binary_operator(child, source)
    }

    fn unwrap_node(
        &self,
        node: TreeSitterNode<'_>,
        source: &str,
        named_child_count: usize,
    ) -> bool {
        if matches!(
            node.kind(),
            "parenthesized_expression"
                | "parenthesized_statements"
                | "expression_statement"
                | "statement"
                | "case_pattern"
                | "match_pattern"
                | "pattern"
        ) && named_child_count == 1
        {
            return true;
        }

        if node.kind() != "expression_list" || named_child_count != 1 {
            return false;
        }

        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && raw_named[0].kind() == "parenthesized_expression"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return true;
        }

        let raw_children = node.children(&mut node.walk()).collect::<Vec<_>>();
        raw_children
            .first()
            .map(|child| node_text(*child, source) == "(")
            .unwrap_or(false)
            && raw_children
                .last()
                .map(|child| node_text(*child, source) == ")")
                .unwrap_or(false)
    }

    fn leading_function_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.leading_function_statement_with_keyword(
            node,
            source,
            "function",
            LUA_LEADING_FUNCTION_WRAPPER_KINDS,
        )
    }

    fn leading_function_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LUA_LEADING_FUNCTION_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| child.kind() == "function")
            .unwrap_or(false)
        {
            return Some(node);
        }
        self.exact_single_named_child(node, &["function_declaration"], source)
    }

    fn leading_function_body_kind(&self) -> &'static str {
        "block"
    }

    fn leading_if_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if LUA_LEADING_IF_WRAPPER_KINDS.contains(&node.kind()) {
            if let Some(child) = self.exact_single_named_child(node, &["if_statement"], source) {
                return Some(child);
            }
        }
        if super::super::LEADING_IF_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn array_literal_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(target) = lua_positional_table_target(node, source) {
            return Some(target);
        }

        if super::super::ARRAY_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !super::super::ARRAY_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if bracketed(node, source, "[", "]") {
            return Some(node);
        }
        let named = named_children(node);
        let child = *named.first()?;
        if named.len() == 1 {
            if super::super::ARRAY_LITERAL_NODE_KINDS.contains(&child.kind()) {
                return Some(child);
            }
            if matches!(child.kind(), "expression_statement" | "statement")
                && node_text(child, source).trim() == node_text(node, source).trim()
            {
                return self.array_literal_target(child, source);
            }
        }
        None
    }

    fn array_literal_values<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.array_literal_target(node, source).unwrap_or(node);
        if target.kind() == "arguments" {
            if let Some(table) = named_children(target)
                .into_iter()
                .find(|child| child.kind() == "table_constructor")
            {
                if node_text(target, source).trim() == node_text(table, source).trim() {
                    return named_children(table);
                }
            }
        }
        if target.kind() == "table_constructor" {
            return named_children(target);
        }

        named_children(target)
    }

    fn hash_literal_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(target) = lua_keyed_table_target(node, source) {
            return Some(target);
        }

        if super::super::HASH_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !super::super::HASH_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        None
    }

    fn hash_literal_values<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.hash_literal_target(node, source).unwrap_or(node);
        if target.kind() == "arguments" {
            if let Some(table) = named_children(target)
                .into_iter()
                .find(|child| child.kind() == "table_constructor")
            {
                return named_children(table);
            }
            return named_children(target);
        }
        if target.kind() == "table_constructor" {
            return named_children(target);
        }

        named_children(target)
    }

    fn member_assignment_target(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() != "variable_list" {
            return false;
        }

        let raw_named = raw_named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "dot_index_expression"
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            raw_named[0]
        } else {
            node
        };

        raw_named_children(target).len() == 2
            && target
                .children(&mut target.walk())
                .any(|child| !child.is_named() && node_text(child, source) == ".")
    }

    fn literal_fragment_assignment_context(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(parent) = node.parent() else {
            return false;
        };
        if matches!(
            parent.kind(),
            "string" | "delimited_symbol" | "regex" | "regex_literal"
        ) {
            return true;
        }
        matches!(
            node.kind(),
            "string_content" | "escape_sequence" | "interpolation" | "string_fragment"
        ) && (parent.kind() == "expression_list"
            || parent
                .parent()
                .map(|grandparent| {
                    matches!(
                        grandparent.kind(),
                        "string" | "delimited_symbol" | "regex" | "regex_literal"
                    )
                })
                .unwrap_or(false))
            && !source.is_empty()
    }

    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "function_definition" {
            return Some(node);
        }

        if node.kind() == "expression_list" {
            if node
                .children(&mut node.walk())
                .next()
                .map(|child| child.kind() == "function")
                .unwrap_or(false)
                && named_children(node)
                    .iter()
                    .any(|child| child.kind() == "block")
            {
                return Some(node);
            }

            let named = named_children(node);
            if named.len() == 1
                && named[0].kind() == "function_definition"
                && node_text(named[0], source) == node_text(node, source)
            {
                return Some(named[0]);
            }
        }

        if node.kind() == "lambda" {
            Some(node)
        } else {
            None
        }
    }

    fn operator_call_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "binary" | "binary_expression" | "expression_list"
        )
    }

    fn boolean_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        super::super::BOOLEAN_EXPRESSION_KINDS.contains(&node.kind())
            || node.kind() == "expression_list"
    }

    fn comparison_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        super::super::COMPARISON_EXPRESSION_KINDS.contains(&node.kind())
            || node.kind() == "expression_list"
    }

    fn single_assignment_block_child(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        lua_single_assignment_block_child(node, source)
    }

    fn member_read_excluded(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "field"
    }

    fn no_paren_string_argument_content<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "string" {
            return None;
        }
        let parent = node.parent()?;
        if parent.kind() != "arguments" || node_text(parent, source) != node_text(node, source) {
            return None;
        }
        raw_named_children(node)
            .into_iter()
            .find(|child| child.kind() == "string_content")
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        LUA_ASSIGNMENT_OPERATORS
    }
}

fn lua_single_assignment_block_child(node: TreeSitterNode<'_>, source: &str) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "assignment_statement" {
        return false;
    }
    let Some(grandparent) = parent.parent() else {
        return false;
    };
    grandparent.kind() == "block"
        && node_text(grandparent, source) == node_text(parent, source)
        && raw_named_children(grandparent).len() == 1
}
