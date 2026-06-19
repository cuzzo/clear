use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::line;
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

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
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

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
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
        &["expression_list"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["dot_index_expression", "variable_list"]
    }

    fn generated_prelude(&self, node: Node<'_>, source: &str) -> bool {
        if line(node) != 1 {
            return false;
        }
        let first_line = source.lines().next().unwrap_or("");
        first_line.contains("_tl_compat") && first_line.contains("compat53.module")
    }
}
