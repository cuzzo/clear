use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct SwiftProfile;

impl LanguageProfile for SwiftProfile {
    fn language(&self) -> Language {
        Language::Swift
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_swift::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_declaration"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["function_value_parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["simple_identifier"]
    }

    fn inline_parameter_node_kinds(&self) -> &[&str] {
        &["parameter"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["function_body", "statements"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["simple_identifier", "type_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment"]
    }

    fn expression_list_node_kinds(&self) -> &[&str] {
        &["directly_assignable_expression"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &[
            "equality_expression",
            "comparison_expression",
            "conjunction_expression",
            "additive_expression",
            "multiplicative_expression",
        ]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["switch_entry"]
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        &["switch_pattern", "pattern"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_declaration", "class_declaration"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["switch_entry", "else", "comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["&&", "and"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &[
            "conjunction_expression",
            "equality_expression",
            "comparison_expression",
        ]
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["statements", "pattern"]
    }

    fn navigation_suffix_node_kinds(&self) -> &[&str] {
        &["navigation_suffix"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["navigation_expression"]
    }
}
