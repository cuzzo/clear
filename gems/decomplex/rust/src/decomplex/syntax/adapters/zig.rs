use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

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

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
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
