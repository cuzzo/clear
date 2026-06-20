use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct JavaScriptProfile;

impl LanguageProfile for JavaScriptProfile {
    fn language(&self) -> Language {
        Language::JavaScript
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_javascript::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration", "method_definition"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_declaration"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["formal_parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["statement_block"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn field_identifier_node_kinds(&self) -> &[&str] {
        &["property_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_expression", "augmented_assignment_expression"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%=", "&&=", "||="]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["lexical_declaration", "variable_declarator"]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declarator"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["switch_case"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &[
            "function_declaration",
            "method_definition",
            "class_declaration",
        ]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["switch_case", "else", "comment"]
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
        &["member_expression"]
    }
}
