use super::super::tree_sitter_adapter::{named_children, normalize_type_owner, CallTarget, Target};
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::{node_text, normalize_text};
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct GoProfile;

impl LanguageProfile for GoProfile {
    fn language(&self) -> Language {
        Language::Go
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_go::LANGUAGE.into()
    }

    fn first_argument_receiver(&self) -> bool {
        true
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["function_declaration", "method_declaration"]
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "method_declaration" {
            return go_method_receiver(node, source).map(|(owner, _name)| owner);
        }
        self.default_owner_name_from_declaration(node, source)
    }

    fn function_receiver_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "method_declaration" {
            return go_method_receiver(node, source).map(|(_owner, name)| name);
        }
        None
    }

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        let name = self.function_name(node, source)?;
        if name.chars().next().map(char::is_uppercase).unwrap_or(false) {
            Some("public".to_string())
        } else {
            Some("private".to_string())
        }
    }

    fn generic_owner_node_kinds(&self) -> &[&str] {
        &["type_spec"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameter_list"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "field_identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block", "statement_list"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        &["statement_list"]
    }

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list", "literal_element"]
    }

    fn indexed_lhs_node_kinds(&self) -> &[&str] {
        &["index_expression", "slice_expression"]
    }

    fn indexed_lhs_bracket_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn update_statement_node_kinds(&self) -> &[&str] {
        &["inc_statement", "dec_statement"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call_expression", "go_statement"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn field_identifier_node_kinds(&self) -> &[&str] {
        &["field_identifier"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment_statement", "short_var_declaration"]
    }

    fn expression_list_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", ":=", "+=", "-=", "*=", "/=", "%="]
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        &[
            "call_expression",
            "expression_statement",
            "return_statement",
        ]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["block", "statement_list"]
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        &[
            "short_var_declaration",
            "range_clause",
            "var_declaration",
            "variable_declaration",
        ]
    }

    fn short_variable_declaration_node_kinds(&self) -> &[&str] {
        &["short_var_declaration", "range_clause"]
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        &["expression_list", "var_spec", "variable_declaration"]
    }

    fn multi_name_variable_declaration_node_kinds(&self) -> &[&str] {
        &["var_spec"]
    }

    fn normalize_local_identifier_text(&self, text: &str) -> String {
        if text == "_" {
            String::new()
        } else {
            text.to_string()
        }
    }

    fn receiver_type_node_kinds(&self) -> &[&str] {
        &["pointer_type", "type_identifier"]
    }

    fn method_receiver_node_kinds(&self) -> &[&str] {
        &["method_declaration"]
    }

    fn receiver_parameter_node_kinds(&self) -> &[&str] {
        &["parameter_declaration"]
    }

    fn first_argument_receiver_type_node_kinds(&self) -> &[&str] {
        &["type_identifier", "pointer_type"]
    }

    fn first_argument_receiver_name_node_kinds(&self) -> &[&str] {
        &["identifier", "field_identifier"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary_expression"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &[
            "if_statement",
            "for_statement",
            "expression_switch_statement",
        ]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["expression_switch_statement"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["expression_case"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["function_declaration", "method_declaration", "type_spec"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["expression_case", "else", "comment"]
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

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn parenthesized_wrapper_node_kinds(&self) -> &[&str] {
        &["parenthesized_expression"]
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        &["selector_expression"]
    }

    fn field_like_dot_wrapper_node_kinds(&self) -> &[&str] {
        &["expression_list"]
    }

    fn keyed_element_node_kinds(&self) -> &[&str] {
        &["keyed_element"]
    }

    fn deferred_statement_node_kinds(&self) -> &[&str] {
        &["defer_statement"]
    }

    fn suppress_field_receiver_lhs_reads(&self) -> bool {
        true
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        match node.kind() {
            "call_expression" => self.default_call_target(node, source),
            "go_statement" => go_keyword_call_target(node, source),
            _ => None,
        }
    }

    fn state_target(&self, lhs: Node<'_>, source: &str) -> Option<Target> {
        if self.expression_list_node_kinds().contains(&lhs.kind()) {
            let children = named_children(lhs);
            if children.len() == 1 {
                return self.state_target(children[0], source);
            }
        }
        if self.indexed_lhs_node_kinds().contains(&lhs.kind()) {
            let object = named_children(lhs).into_iter().next()?;
            return self.default_state_target(object, source);
        }
        self.default_state_target(lhs, source)
    }

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        if go_augmented_assignment_lhs(node) {
            return None;
        }
        self.default_state_read_target(node, source)
    }
}

fn go_method_receiver(node: Node<'_>, source: &str) -> Option<(String, String)> {
    let receiver_params = named_children(node)
        .into_iter()
        .find(|child| child.kind() == "parameter_list")?;
    let receiver = named_children(receiver_params)
        .into_iter()
        .find(|child| child.kind() == "parameter_declaration")?;
    let children = named_children(receiver);
    let name = children
        .iter()
        .find(|child| matches!(child.kind(), "identifier" | "field_identifier"))
        .map(|child| node_text(*child, source).to_string())?;
    let type_node = children
        .iter()
        .find(|child| matches!(child.kind(), "pointer_type" | "type_identifier"))?;
    Some((normalize_type_owner(node_text(*type_node, source)), name))
}

fn go_keyword_call_target<'tree>(node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
    if node.kind() != "go_statement" {
        return None;
    }
    let arguments = go_statement_arguments(node, source)?;
    let mut target = CallTarget::new("self".to_string(), "go".to_string(), arguments);
    target.source_node = Some(node);
    Some(target)
}

fn go_statement_arguments(node: Node<'_>, source: &str) -> Option<Vec<String>> {
    let text = node_text(node, source).trim();
    let inner = text.strip_prefix("go(")?.strip_suffix(')')?;
    Some(
        inner
            .split(',')
            .map(normalize_text)
            .filter(|argument| !argument.is_empty())
            .collect(),
    )
}

fn go_augmented_assignment_lhs(node: Node<'_>) -> bool {
    let mut current = node;
    while let Some(parent) = current.parent() {
        if parent.kind() == "assignment_statement" {
            let lhs = named_children(parent).into_iter().next();
            let operator = go_assignment_operator(parent);
            return lhs.map(|lhs| go_contains_node(lhs, node)).unwrap_or(false)
                && !matches!(operator.as_deref(), Some("=" | ":="));
        }
        current = parent;
    }
    false
}

fn go_assignment_operator(node: Node<'_>) -> Option<String> {
    let mut cursor = node.walk();
    let operator = node
        .children(&mut cursor)
        .find(|child| !child.is_named() && child.kind().ends_with('='))
        .map(|child| child.kind().to_string());
    operator
}

fn go_contains_node(root: Node<'_>, target: Node<'_>) -> bool {
    if root.kind() == target.kind()
        && root.start_byte() == target.start_byte()
        && root.end_byte() == target.end_byte()
    {
        return true;
    }
    named_children(root)
        .into_iter()
        .any(|child| go_contains_node(child, target))
}
