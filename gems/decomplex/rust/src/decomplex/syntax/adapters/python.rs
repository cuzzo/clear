use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct PythonProfile;

impl LanguageProfile for PythonProfile {
    fn language(&self) -> Language {
        Language::Python
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_python::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_definition"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_definition"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment", "augmented_assignment"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["comparison_operator", "binary_operator", "boolean_operator"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["match_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["case_clause"]
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        &["case_pattern", "pattern"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_definition", "class_definition"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["case_clause", "else", "comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["and", "&&"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &["binary_operator", "boolean_operator", "comparison_operator"]
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn parenthesized_wrapper_node_kinds(&self) -> &[&str] {
        &["parenthesized_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["attribute"]
    }
}
