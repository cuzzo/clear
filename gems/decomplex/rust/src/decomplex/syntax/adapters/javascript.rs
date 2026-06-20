use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::node_text;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct JavaScriptProfile;

impl LanguageProfile for JavaScriptProfile {
    fn language(&self) -> Language {
        Language::JavaScript
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_javascript::LANGUAGE.into()
    }

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        let name = self.function_name(node, source).unwrap_or_default();
        if name.starts_with('#') {
            return Some("private".to_string());
        }
        for child in super::super::tree_sitter_adapter::named_children(node) {
            if !matches!(child.kind(), "accessibility_modifier" | "modifier") {
                continue;
            }
            let text = node_text(child, source);
            if text.split_whitespace().any(|token| token == "private") {
                return Some("private".to_string());
            }
            if text.split_whitespace().any(|token| token == "protected") {
                return Some("protected".to_string());
            }
            if text.split_whitespace().any(|token| token == "public") {
                return Some("public".to_string());
            }
        }
        Some("public".to_string())
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

    fn path_action_node_kinds(&self) -> &[&str] {
        &[
            "call_expression",
            "expression_statement",
            "return_statement",
        ]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["statement_block"]
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

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "for_in_statement", "switch_statement"]
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
