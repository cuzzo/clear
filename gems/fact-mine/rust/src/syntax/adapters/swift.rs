use super::super::tree_sitter_adapter::{named_children, CallTarget};
use super::super::Language;
use super::base::LanguageProfile;
use crate::ast::{node_text, normalize_text};
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct SwiftProfile;

impl LanguageProfile for SwiftProfile {
    fn language(&self) -> Language {
        Language::Swift
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_swift::LANGUAGE.into()
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
        &["simple_identifier"]
    }

    fn inline_parameter_node_kinds(&self) -> &[&str] {
        &["parameter"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["function_body", "statements"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        &["statements"]
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

    fn path_action_node_kinds(&self) -> &[&str] {
        &["call_expression", "control_transfer_statement"]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["statements", "control_structure_body", "function_body"]
    }

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        &[
            "directly_assignable_expression",
            "value_argument",
            "pattern",
        ]
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
        ]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "for_statement", "switch_statement"]
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

    fn assignment_lhs_node(&self, node: Node<'_>) -> bool {
        let candidate = if node
            .parent()
            .map(|parent| parent.kind() == "directly_assignable_expression")
            .unwrap_or(false)
        {
            node.parent().unwrap()
        } else {
            node
        };
        let Some(parent) = candidate.parent() else {
            return false;
        };
        if parent.kind() != "assignment" {
            return false;
        }
        named_children(parent)
            .into_iter()
            .next()
            .map(|lhs| same_node(lhs, candidate))
            .unwrap_or(false)
    }

    fn state_read_target(
        &self,
        node: Node<'_>,
        source: &str,
    ) -> Option<super::super::tree_sitter_adapter::Target> {
        if self.assignment_lhs_node(node) {
            return None;
        }
        self.default_state_read_target(node, source)
    }

    fn call_argument_nodes<'tree>(&self, node: Node<'tree>) -> Vec<Node<'tree>> {
        let Some(args) = named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "call_suffix" | "value_arguments"))
        else {
            return Vec::new();
        };
        let value_arguments = if args.kind() == "call_suffix" {
            named_children(args)
                .into_iter()
                .find(|child| child.kind() == "value_arguments")
        } else {
            Some(args)
        };
        value_arguments
            .map(|arguments| {
                named_children(arguments)
                    .into_iter()
                    .filter(|child| child.kind() == "value_argument")
                    .collect()
            })
            .unwrap_or_default()
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if node.kind() != "call_expression" {
            return None;
        }
        let mut target = self.default_call_target(node, source)?;
        if swift_single_line_switch_call(node) {
            target.source_node = named_children(node).into_iter().next();
        }
        Some(target)
    }

    fn call_argument_texts(&self, node: Node<'_>, source: &str) -> Vec<String> {
        self.call_argument_nodes(node)
            .into_iter()
            .filter_map(|argument| {
                let text = normalize_text(node_text(argument, source));
                let value = text
                    .strip_prefix('(')
                    .and_then(|inner| inner.strip_suffix(')'))
                    .unwrap_or(&text)
                    .trim()
                    .to_string();
                (!value.is_empty()).then_some(value)
            })
            .collect()
    }
}

fn same_node(left: Node<'_>, right: Node<'_>) -> bool {
    left.kind() == right.kind()
        && left.start_byte() == right.start_byte()
        && left.end_byte() == right.end_byte()
}

fn swift_single_line_switch_call(node: Node<'_>) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "statements" || parent.start_position().row != parent.end_position().row {
        return false;
    }
    parent
        .parent()
        .map(|ancestor| ancestor.kind() == "switch_entry")
        .unwrap_or(false)
}
