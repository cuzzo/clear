use super::super::tree_sitter_adapter::{named_children, CallTarget};
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::node_text;
use tree_sitter::Language as TreeSitterLanguage;
use tree_sitter::Node;

pub(crate) struct JavaProfile;

impl LanguageProfile for JavaProfile {
    fn language(&self) -> Language {
        Language::Java
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_java::LANGUAGE.into()
    }

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        for child in named_children(node) {
            if child.kind() != "modifiers" {
                continue;
            }
            let text = node_text(child, source);
            if text.split_whitespace().any(|token| token == "public") {
                return Some("public".to_string());
            }
            if text.split_whitespace().any(|token| token == "private") {
                return Some("private".to_string());
            }
            if text.split_whitespace().any(|token| token == "protected") {
                return Some("protected".to_string());
            }
        }
        None
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

    fn path_action_node_kinds(&self) -> &[&str] {
        &[
            "method_invocation",
            "expression_statement",
            "return_statement",
        ]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["local_variable_declaration", "variable_declarator"]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declarator"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &[
            "if_statement",
            "enhanced_for_statement",
            "switch_expression",
        ]
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

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if node.kind() != "method_invocation" {
            return None;
        }
        let children = named_children(node);
        let identifiers = children
            .iter()
            .copied()
            .filter(|child| child.kind() == "identifier")
            .collect::<Vec<_>>();
        if identifiers.len() >= 2 {
            return Some(CallTarget::new(
                node_text(identifiers[0], source).to_string(),
                node_text(identifiers[1], source).to_string(),
                self.call_argument_texts(node, source),
            ));
        }
        self.default_call_target(node, source)
    }
}
