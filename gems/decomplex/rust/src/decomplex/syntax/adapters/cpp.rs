use super::super::Language;
use super::base::LanguageProfile;
use tree_sitter::Language as TreeSitterLanguage;

pub(crate) struct CppProfile;

impl LanguageProfile for CppProfile {
    fn language(&self) -> Language {
        Language::Cpp
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_cpp::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_definition"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_specifier"]
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
        &[
            "identifier",
            "type_identifier",
            "qualified_identifier",
            "namespace_identifier",
        ]
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

    fn receiver_type_node_kinds(&self) -> &[&str] {
        &[
            "type_identifier",
            "qualified_identifier",
            "scoped_type_identifier",
        ]
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
        &["if_statement", "for_range_loop", "switch_statement"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["case_statement"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_definition", "class_specifier", "struct_specifier"]
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
        &["condition_clause", "parenthesized_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["field_expression"]
    }
}
