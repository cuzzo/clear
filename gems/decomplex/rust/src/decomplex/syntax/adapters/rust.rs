use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct RustProfile;

impl LanguageProfile for RustProfile {
    fn language(&self) -> Language {
        Language::Rust
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_rust::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_item"]
    }

    fn impl_owner_node_kinds(&self) -> &[&str] {
        &["impl_item"]
    }

    fn struct_owner_node_kinds(&self) -> &[&str] {
        &["struct_item"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "self_parameter"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block", "declaration_list"]
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
        &["assignment_expression", "compound_assignment_expr"]
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

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        &["pattern"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["let_declaration"]
    }

    fn receiver_type_node_kinds(&self) -> &[&str] {
        &["type_identifier", "generic_type", "scoped_type_identifier"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_expression", "match_expression", "for_expression"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["match_expression"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["match_arm"]
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        &["match_pattern", "pattern"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_item", "impl_item", "struct_item"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["match_arm", "else", "comment"]
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
        &["parenthesized_expression", "tuple_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["field_expression", "scoped_identifier"]
    }
}
