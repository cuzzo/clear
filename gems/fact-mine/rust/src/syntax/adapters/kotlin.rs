use super::super::tree_sitter_adapter::{named_children, CallTarget};
use super::super::Language;
use super::base::LanguageProfile;
use crate::ast::node_text;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct KotlinProfile;

impl LanguageProfile for KotlinProfile {
    fn language(&self) -> Language {
        Language::Kotlin
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_kotlin_ng::LANGUAGE.into()
    }

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        for child in named_children(node) {
            if child.kind() != "modifiers" {
                continue;
            }
            if node_text(child, source)
                .split_whitespace()
                .any(|token| token == "private")
            {
                return Some("private".to_string());
            }
        }
        None
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
        &["identifier", "simple_identifier"]
    }

    fn function_params(&self, node: Node<'_>, source: &str) -> Vec<String> {
        let Some(params) = named_children(node)
            .into_iter()
            .find(|child| self.parameter_list_node_kinds().contains(&child.kind()))
        else {
            return Vec::new();
        };

        let mut out = Vec::new();
        for param in named_children(params) {
            if let Some(name) = self.parameter_name(param, source) {
                if !out.contains(&name) {
                    out.push(name);
                }
            }
        }
        out
    }

    fn parameter_name(&self, param: Node<'_>, source: &str) -> Option<String> {
        let name = if self
            .parameter_identifier_node_kinds()
            .contains(&param.kind())
        {
            Some(param)
        } else {
            named_children(param).into_iter().find(|child| {
                self.parameter_identifier_node_kinds()
                    .contains(&child.kind())
            })
        }?;
        let text = node_text(name, source).to_string();
        (!text.is_empty() && text != "_").then_some(text)
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["function_body", "statements"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        &["block", "statements"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "simple_identifier", "type_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        &["call_expression", "jump_expression"]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["statements", "control_structure_body", "function_body"]
    }

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        &["directly_assignable_expression", "value_argument"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &["property_declaration", "variable_declaration"]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["variable_declaration", "directly_assignable_expression"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &[
            "equality_expression",
            "comparison_expression",
            "conjunction_expression",
            "additive_expression",
            "multiplicative_expression",
            "binary_expression",
        ]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_expression", "for_statement", "when_expression"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["when_expression"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["when_entry"]
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        &["when_condition", "pattern", "string_literal"]
    }

    fn case_subject_node_kinds(&self) -> &[&str] {
        &["when_subject"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_declaration", "class_declaration"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["when_entry", "else", "line_comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default", "else"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["&&", "and"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &[
            "conjunction_expression",
            "equality_expression",
            "comparison_expression",
            "binary_expression",
        ]
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["statements", "pattern"]
    }

    fn navigation_suffix_node_kinds(&self) -> &[&str] {
        &["navigation_suffix"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["navigation_expression", "directly_assignable_expression"]
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if node.kind() != "call_expression" {
            return None;
        }
        let mut target = self.default_call_target(node, source)?;
        if kotlin_single_call_control_body(node) {
            target.source_node = named_children(node).into_iter().next();
        }
        Some(target)
    }
}

fn kotlin_single_call_control_body(node: Node<'_>) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() == "when_entry" {
        return true;
    }
    if parent.kind() != "block" {
        return false;
    }
    if named_children(parent)
        .into_iter()
        .filter(|child| child.is_named())
        .count()
        != 1
    {
        return false;
    }
    parent
        .parent()
        .map(|ancestor| {
            matches!(
                ancestor.kind(),
                "if_expression" | "for_statement" | "control_structure_body"
            )
        })
        .unwrap_or(false)
}
