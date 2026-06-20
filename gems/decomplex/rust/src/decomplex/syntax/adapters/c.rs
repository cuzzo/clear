use super::super::tree_sitter_adapter::normalize_type_owner;
use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct CProfile;

impl LanguageProfile for CProfile {
    fn language(&self) -> Language {
        Language::C
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_c::LANGUAGE.into()
    }

    fn first_argument_receiver(&self) -> bool {
        true
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_definition"]
    }

    fn struct_owner_node_kinds(&self) -> &[&str] {
        &["struct_specifier"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameter_list"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "field_identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["compound_statement"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn field_identifier_node_kinds(&self) -> &[&str] {
        &["field_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_expression"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["declaration", "init_declarator"]
    }

    fn receiver_parameter_node_kinds(&self) -> &[&str] {
        &["parameter_declaration"]
    }

    fn first_argument_receiver_type_node_kinds(&self) -> &[&str] {
        &[
            "type_identifier",
            "primitive_type",
            "qualified_identifier",
            "scoped_type_identifier",
        ]
    }

    fn first_argument_receiver_name_node_kinds(&self) -> &[&str] {
        &["identifier", "field_identifier"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "for_statement", "switch_statement"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["case_statement"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_definition", "struct_specifier"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["case_statement", "else", "comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["&&", "and"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn parenthesized_wrapper_node_kinds(&self) -> &[&str] {
        &["parenthesized_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["field_expression"]
    }

    fn receiver_convention_owner_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if !self.first_argument_receiver() || node.kind() != "function_definition" {
            return None;
        }

        let (type_name, name) = self.first_argument_receiver_parameter(node, source)?;
        (name == "self").then(|| normalize_type_owner(&type_name))
    }
}
