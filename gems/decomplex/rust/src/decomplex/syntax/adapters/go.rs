use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct GoProfile;

impl LanguageProfile for GoProfile {
    fn language(&self) -> Language {
        Language::Go
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_go::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration", "method_declaration"]
    }

    fn generic_owner_node_kinds(&self) -> &[&str] {
        &["type_spec"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameter_list"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block", "statement_list"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "type_identifier"]
    }

    fn field_identifier_node_kinds(&self) -> &[&str] {
        &["field_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_statement", "short_var_declaration"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", ":=", "+=", "-=", "*=", "/=", "%="]
    }

    fn receiver_type_node_kinds(&self) -> &[&str] {
        &["pointer_type", "type_identifier"]
    }

    fn receiver_parameter_node_kinds(&self) -> &[&str] {
        &["parameter_declaration"]
    }

    fn first_argument_receiver_type_node_kinds(&self) -> &[&str] {
        &["type_identifier", "pointer_type"]
    }

    fn first_argument_receiver_name_node_kinds(&self) -> &[&str] {
        &["identifier", "field_identifier"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["expression_switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["expression_case"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_declaration", "method_declaration", "type_spec"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["expression_case", "else", "comment"]
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

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn parenthesized_wrapper_node_kinds(&self) -> &[&str] {
        &["parenthesized_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["selector_expression"]
    }
}
