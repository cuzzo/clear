use super::super::tree_sitter_adapter::named_children;
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::node_text;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct ZigProfile;

impl LanguageProfile for ZigProfile {
    fn language(&self) -> Language {
        Language::Zig
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_zig::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration"]
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "struct_declaration" {
            return node
                .parent()
                .filter(|parent| parent.kind() == "variable_declaration")
                .and_then(|parent| {
                    named_children(parent)
                        .into_iter()
                        .find(|child| child.kind() == "identifier")
                })
                .map(|name| node_text(name, source).to_string());
        }
        self.default_owner_name_from_declaration(node, source)
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block", "block_expression"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_expression", "variable_declaration"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        &[
            "call_expression",
            "expression_statement",
            "return_expression",
        ]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declaration"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &[
            "if_statement",
            "switch_expression",
            "for_statement",
            "labeled_statement",
        ]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_expression"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["switch_case"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_declaration", "struct_declaration"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["switch_case", "else", "comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default", "else"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["and", "&&"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["field_expression"]
    }
}
