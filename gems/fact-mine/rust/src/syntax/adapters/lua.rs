use super::super::tree_sitter_adapter::{named_children, CallTarget, Target};
use super::super::Language;
use super::base::LanguageProfile;
use crate::ast::{line, node_text};
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct LuaProfile;

impl LanguageProfile for LuaProfile {
    fn language(&self) -> Language {
        Language::Lua
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_lua::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration"]
    }

    fn function_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        lua_method_name(node, source).or_else(|| self.default_function_name(node, source))
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        lua_method_owner_name(node, source)
            .or_else(|| self.default_owner_name_from_declaration(node, source))
    }

    fn owner_def_name_from_declaration(&self, _node: Node<'_>, _source: &str) -> Option<String> {
        None
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["function_call", "method_call"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_statement"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        &["function_call", "expression_list", "return_statement"]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declaration"]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declaration", "variable_list"]
    }

    fn declaration_assignment_node_kinds(&self) -> &[&str] {
        &["assignment_statement"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["and", "&&"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn expression_list_node_kinds(&self) -> &[&str] {
        &["expression_list", "variable_list"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["dot_index_expression"]
    }

    fn generated_prelude(&self, node: Node<'_>, source: &str) -> bool {
        if line(node) != 1 {
            return false;
        }
        let first_line = source.lines().next().unwrap_or("");
        first_line.contains("_tl_compat") && first_line.contains("compat53.module")
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if !self.call_node_kinds().contains(&node.kind()) {
            return None;
        }
        let callee = named_children(node).into_iter().next()?;
        let mut target = if callee.kind() == "method_index_expression" {
            lua_method_call_target(callee, node, self.call_argument_texts(node, source), source)?
        } else {
            self.default_call_target(node, source)?
        };
        if lua_callee_source_span(node) {
            target.source_node = Some(callee);
        }
        Some(target)
    }

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        let target = self.default_state_read_target(node, source)?;
        if target.receiver == "_" && target.field == "_" {
            None
        } else {
            Some(target)
        }
    }

    fn assignment_lhs_node(&self, node: Node<'_>) -> bool {
        let candidate = if node
            .parent()
            .map(|parent| parent.kind() == "variable_list")
            .unwrap_or(false)
        {
            node.parent().unwrap()
        } else {
            node
        };
        let Some(parent) = candidate.parent() else {
            return false;
        };
        if parent.kind() != "assignment_statement" {
            return false;
        }
        named_children(parent)
            .into_iter()
            .next()
            .map(|lhs| same_node(lhs, candidate))
            .unwrap_or(false)
    }
}

fn lua_method_call_target<'tree>(
    callee: Node<'tree>,
    node: Node<'tree>,
    arguments: Vec<String>,
    source: &str,
) -> Option<CallTarget<'tree>> {
    let children = named_children(callee);
    let receiver = children.first().copied()?;
    let message = children.last().copied()?;
    let mut target = CallTarget::new(
        node_text(receiver, source).to_string(),
        node_text(message, source).to_string(),
        arguments,
    );
    target.source_node = Some(node);
    Some(target)
}

fn lua_callee_source_span(node: Node<'_>) -> bool {
    if node
        .parent()
        .map(|parent| parent.kind() == "expression_list")
        .unwrap_or(false)
    {
        return true;
    }
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "block" {
        return false;
    }
    if named_children(parent).len() != 1 {
        return false;
    }
    parent
        .parent()
        .map(|ancestor| {
            matches!(
                ancestor.kind(),
                "if_statement" | "elseif_statement" | "else_statement" | "for_statement"
            )
        })
        .unwrap_or(false)
}

fn same_node(left: Node<'_>, right: Node<'_>) -> bool {
    left.kind() == right.kind()
        && left.start_byte() == right.start_byte()
        && left.end_byte() == right.end_byte()
}

fn lua_method_name(node: Node<'_>, source: &str) -> Option<String> {
    let method = lua_method_index_expression(node)?;
    named_children(method)
        .into_iter()
        .last()
        .map(|child| node_text(child, source).to_string())
}

fn lua_method_owner_name(node: Node<'_>, source: &str) -> Option<String> {
    let method = lua_method_index_expression(node)?;
    named_children(method)
        .into_iter()
        .next()
        .map(|child| node_text(child, source).to_string())
}

fn lua_method_index_expression<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    if node.kind() != "function_declaration" {
        return None;
    }
    named_children(node)
        .into_iter()
        .find(|child| child.kind() == "method_index_expression")
}
