use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct JavaProfile;

impl LanguageProfile for JavaProfile {
    fn language(&self) -> Language {
        Language::Java
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_java::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["method_declaration"]
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
        &["block"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["method_invocation"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "type_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_expression"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_expression"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["switch_block_statement_group"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["method_declaration", "class_declaration"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["switch_block_statement_group", "else", "comment"]
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
        &["field_access"]
    }
}
