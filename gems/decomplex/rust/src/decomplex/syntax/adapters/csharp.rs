use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct CSharpProfile;

impl LanguageProfile for CSharpProfile {
    fn language(&self) -> Language {
        Language::CSharp
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_c_sharp::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["method_declaration"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_declaration"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameter_list"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block", "declaration_list"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["invocation_expression"]
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

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        &["argument"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &[
            "local_declaration_statement",
            "variable_declaration",
            "variable_declarator",
        ]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declaration"]
    }

    fn declarator_node_kinds(&self) -> &[&str] {
        &["variable_declaration", "variable_declarator"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "foreach_statement", "switch_statement"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["switch_section"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["method_declaration", "class_declaration"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["switch_section", "else", "comment"]
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
        &["member_access_expression"]
    }
}
