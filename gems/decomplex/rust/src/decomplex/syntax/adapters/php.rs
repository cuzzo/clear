use super::super::tree_sitter_adapter::{named_children, AssignmentTarget, CallTarget, Target};
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::{node_text, normalize_text};
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct PhpProfile;

impl LanguageProfile for PhpProfile {
    fn language(&self) -> Language {
        Language::Php
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_php::LANGUAGE_PHP.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_definition", "method_declaration"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_declaration"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["formal_parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["name", "variable_name"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["compound_statement", "declaration_list"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &[
            "function_call_expression",
            "member_call_expression",
            "scoped_call_expression",
            "print_intrinsic",
        ]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["name", "variable_name"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_expression", "augmented_assignment_expression"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%="]
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        &[
            "function_call_expression",
            "member_call_expression",
            "scoped_call_expression",
            "expression_statement",
            "return_statement",
            "print_intrinsic",
        ]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["compound_statement", "declaration_list"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn comparison_operators(&self) -> &[&str] {
        &["==", "!=", "===", "!==", "<", "<=", ">", ">="]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["case_statement"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &[
            "function_definition",
            "method_declaration",
            "class_declaration",
        ]
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
        &["parenthesized_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "foreach_statement", "switch_statement"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &[
            "member_access_expression",
            "nullsafe_member_access_expression",
            "member_call_expression",
            "class_constant_access_expression",
        ]
    }

    fn normalize_source_text(&self, text: &str) -> String {
        normalize_text(&php_normalize_source(text))
    }

    fn normalize_parameter_name(&self, text: &str) -> String {
        php_identifier_text_value(text)
    }

    fn normalize_local_identifier_text(&self, text: &str) -> String {
        php_identifier_text_value(text)
    }

    fn function_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if self.function_node_kinds().contains(&node.kind()) {
            return node
                .child_by_field_name("name")
                .or_else(|| php_first_name_node(node))
                .and_then(|name| php_name_text(name, source));
        }
        self.default_function_name(node, source)
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "class_declaration" {
            return node
                .child_by_field_name("name")
                .or_else(|| php_first_name_node(node))
                .and_then(|name| php_name_text(name, source));
        }
        self.default_owner_name_from_declaration(node, source)
    }

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "visibility_modifier")
            .map(|modifier| node_text(modifier, source).to_string())
            .filter(|modifier| matches!(modifier.as_str(), "public" | "private" | "protected"))
            .or_else(|| Some("public".to_string()))
    }

    fn assignment_target<'tree>(&self, node: Node<'tree>) -> Option<AssignmentTarget<'tree>> {
        self.default_assignment_target(node)
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if !self.call_node_kinds().contains(&node.kind()) {
            return None;
        }
        if node.kind() == "print_intrinsic" {
            return Some(CallTarget::new(
                "self".to_string(),
                "print".to_string(),
                php_print_argument_texts(node, source),
            ));
        }
        let mut target = self.default_call_target(node, source)?;
        target.receiver = php_normalize_receiver(&target.receiver);
        target.message = php_identifier_text_value(&target.message);
        Some(target)
    }

    fn call_argument_texts(&self, node: Node<'_>, source: &str) -> Vec<String> {
        self.call_argument_nodes(node)
            .into_iter()
            .map(|argument| normalize_text(&php_normalize_source(node_text(argument, source))))
            .collect()
    }

    fn state_target(&self, lhs: Node<'_>, source: &str) -> Option<Target> {
        let target = self.default_state_target(lhs, source)?;
        Some(Target {
            receiver: php_normalize_receiver(&target.receiver),
            field: php_identifier_text_value(&target.field),
        })
    }

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        let target = self.default_state_read_target(node, source)?;
        Some(Target {
            receiver: php_normalize_receiver(&target.receiver),
            field: php_identifier_text_value(&target.field),
        })
    }

    fn member_field_text(&self, field: Node<'_>, source: &str) -> Option<String> {
        php_name_text(field, source)
    }

    fn case_pattern_texts(&self, patterns: &[Node<'_>], source: &str) -> Vec<String> {
        patterns
            .iter()
            .map(|pattern| normalize_text(&php_normalize_source(node_text(*pattern, source))))
            .collect()
    }
}

fn php_first_name_node<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| php_name_node(*child))
}

fn php_name_node(node: Node<'_>) -> bool {
    matches!(node.kind(), "name" | "qualified_name" | "variable_name")
}

fn php_name_text(node: Node<'_>, source: &str) -> Option<String> {
    let text = php_identifier_text_value(node_text(node, source));
    (!text.is_empty()).then_some(text)
}

fn php_identifier_text_value(text: &str) -> String {
    text.trim().trim_start_matches('$').to_string()
}

fn php_normalize_receiver(receiver: &str) -> String {
    let value = php_normalize_source(&php_identifier_text_value(receiver));
    if value == "this" {
        "self".to_string()
    } else {
        value
    }
}

fn php_print_argument_texts(node: Node<'_>, source: &str) -> Vec<String> {
    named_children(node)
        .into_iter()
        .flat_map(|child| {
            if child.kind() == "parenthesized_expression" {
                let children = named_children(child);
                if children.is_empty() {
                    vec![child]
                } else {
                    children
                }
            } else {
                vec![child]
            }
        })
        .map(|argument| normalize_text(&php_normalize_source(node_text(argument, source))))
        .collect()
}

fn php_normalize_source(source: &str) -> String {
    let mut out = String::new();
    let mut chars = source.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '$' {
            if chars
                .peek()
                .map(|next| *next == '_' || next.is_ascii_alphabetic())
                .unwrap_or(false)
            {
                continue;
            }
        }
        out.push(ch);
    }
    out.replace("->", ".").replace("::", ".")
}
