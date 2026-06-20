use super::super::tree_sitter_adapter::named_children;
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::{line, node_text};
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
