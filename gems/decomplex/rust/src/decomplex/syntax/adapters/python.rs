use super::super::tree_sitter_adapter::Target;
use super::super::Language;
use super::base::{default_clone_candidate_node, LanguageProfile};
use crate::decomplex::ast::RawNode;
use tree_sitter::{Language as TreeSitterLanguage, Node};

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

    fn function_visibility(&self, node: tree_sitter::Node<'_>, source: &str) -> Option<String> {
        let name = self.function_name(node, source)?;
        if name.starts_with('_') && !name.starts_with("__") {
            Some("private".to_string())
        } else {
            Some("public".to_string())
        }
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class_definition"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["parameters"]
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
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

    fn branch_node_kinds(&self) -> &[&str] {
        &["if_statement", "for_statement", "match_statement"]
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

    fn path_action_node_kinds(&self) -> &[&str] {
        &["call", "expression_statement", "return_statement"]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["block"]
    }

    fn path_transparent_branch_body_node_kinds(&self) -> &[&str] {
        &["if_statement"]
    }

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        if python_type_annotation_expression(node) {
            return None;
        }
        let target = self.default_state_read_target(node, source)?;
        if python_with_context_expression(node) && python_lock_context_field(&target.field) {
            return None;
        }
        Some(target)
    }

    fn clone_candidate_node(&self, node: &RawNode) -> bool {
        if python_assignment_wrapper_node(node) {
            return false;
        }
        default_clone_candidate_node(node)
    }

    fn clone_fingerprint_children<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode> {
        if node.kind == "type"
            && node.children.len() == 1
            && matches!(node.children[0].kind.as_str(), "generic_type" | "string")
        {
            return node.children[0].children.iter().collect();
        }
        if python_terminal_wrapper_node(node) {
            return Vec::new();
        }
        if node.kind == "expression_statement" && node.children.len() == 1 {
            let child = &node.children[0];
            if python_expression_wrapper_child(child) {
                return child.children.iter().collect();
            }
        }
        if python_call_expression_statement(node) {
            return node.children.iter().collect();
        }
        if node.kind == "block" && node.children.len() == 1 {
            let child = &node.children[0];
            if python_single_statement_block_child(child) {
                return child.children.iter().collect();
            }
            if child.kind == "expression_statement" {
                return python_expression_statement_clone_children(child);
            }
        }
        if node.kind == "if_statement" {
            return node
                .children
                .iter()
                .flat_map(python_if_statement_clone_children)
                .collect();
        }
        if matches!(node.kind.as_str(), "else_clause" | "except_clause") {
            return node
                .children
                .iter()
                .flat_map(python_clause_clone_children)
                .collect();
        }
        if node.kind == "with_clause" {
            if python_simple_with_clause(node) {
                return Vec::new();
            }
            return node
                .children
                .iter()
                .flat_map(python_with_clause_clone_children)
                .collect();
        }
        node.children.iter().collect()
    }

    fn clone_child_fingerprint(
        &self,
        _parent: &RawNode,
        child: &RawNode,
    ) -> Option<(String, usize)> {
        if python_escape_only_string_content(child) {
            return Some(("lit".to_string(), 1));
        }
        None
    }
}

fn python_with_context_expression(node: Node<'_>) -> bool {
    let mut current = node.parent();
    while let Some(parent) = current {
        match parent.kind() {
            "with_clause" | "with_item" => return true,
            "block" | "function_definition" | "class_definition" | "module" => return false,
            _ => current = parent.parent(),
        }
    }
    false
}

fn python_type_annotation_expression(node: Node<'_>) -> bool {
    let mut current = Some(node);
    while let Some(item) = current {
        match item.kind() {
            "type" | "type_parameter" => return true,
            "block" | "function_definition" | "class_definition" | "module" => return false,
            _ => current = item.parent(),
        }
    }
    false
}

fn python_lock_context_field(field: &str) -> bool {
    field == "_lock" || field.ends_with("_lock")
}

fn python_assignment_wrapper_node(node: &RawNode) -> bool {
    matches!(node.kind.as_str(), "assignment" | "augmented_assignment")
}

fn python_expression_wrapper_child(node: &RawNode) -> bool {
    python_assignment_wrapper_node(node)
        || matches!(node.kind.as_str(), "call" | "string" | "yield")
}

fn python_expression_statement_clone_children(node: &RawNode) -> Vec<&RawNode> {
    if node.kind == "expression_statement" && node.children.len() == 1 {
        let child = &node.children[0];
        if python_expression_wrapper_child(child) {
            return child.children.iter().collect();
        }
    }
    node.children.iter().collect()
}

fn python_call_expression_statement(node: &RawNode) -> bool {
    if node.kind != "expression_statement" {
        return false;
    }
    if node.children.len() == 1 && node.children[0].kind == "call" {
        return true;
    }
    node.children
        .iter()
        .any(|child| matches!(child.kind.as_str(), "argument_list" | "arguments"))
        && node
            .children
            .iter()
            .all(|child| !python_assignment_wrapper_node(child) && !python_assignment_token(child))
}

fn python_assignment_token(node: &RawNode) -> bool {
    matches!(node.text.as_str(), "=" | "+=" | "-=" | "*=" | "/=" | "%=")
}

fn python_terminal_wrapper_node(node: &RawNode) -> bool {
    if matches!(node.kind.as_str(), "break_statement" | "continue_statement") {
        return node.children.len() == 1 && node.children[0].text == node.text;
    }
    if node.kind == "as_pattern_target" {
        return node.children.len() == 1 && node.children[0].kind == "identifier";
    }
    if node.kind == "dotted_name" {
        return node.children.len() == 1 && node.children[0].kind == "identifier";
    }
    if node.kind == "keyword_separator" {
        return node.children.len() == 1 && node.children[0].text == node.text;
    }
    python_simple_type_wrapper_node(node)
}

fn python_simple_type_wrapper_node(node: &RawNode) -> bool {
    if node.kind != "type" || node.children.len() != 1 {
        return false;
    }
    let child = &node.children[0];
    child.children.is_empty()
        && matches!(
            child.kind.as_str(),
            "identifier" | "none" | "true" | "false" | "integer" | "float" | "string"
        )
        && child.text == node.text
}

fn python_escape_only_string_content(node: &RawNode) -> bool {
    node.kind == "string_content"
        && node.children.len() == 1
        && node.children[0].kind == "escape_sequence"
        && node.children[0].text == node.text
}

fn python_single_statement_block_child(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "assert_statement"
            | "break_statement"
            | "continue_statement"
            | "for_statement"
            | "function_definition"
            | "if_statement"
            | "raise_statement"
            | "try_statement"
            | "with_statement"
            | "while_statement"
    )
}

fn python_if_statement_clone_children(node: &RawNode) -> Vec<&RawNode> {
    if node.kind == "block"
        && node.children.len() == 1
        && matches!(
            node.children[0].kind.as_str(),
            "break_statement" | "continue_statement"
        )
    {
        return node.children[0].children.iter().collect();
    }
    vec![node]
}

fn python_clause_clone_children(node: &RawNode) -> Vec<&RawNode> {
    if node.kind == "block"
        && node.children.len() == 1
        && matches!(
            node.children[0].kind.as_str(),
            "break_statement" | "continue_statement"
        )
    {
        return node.children[0].children.iter().collect();
    }
    vec![node]
}

fn python_simple_with_clause(node: &RawNode) -> bool {
    if node.children.len() != 1 || node.children[0].kind != "with_item" {
        return false;
    }
    let with_item = &node.children[0];
    with_item.text == node.text
        && with_item.children.len() == 1
        && with_item.children[0].kind == "identifier"
}

fn python_with_clause_clone_children(node: &RawNode) -> Vec<&RawNode> {
    if node.kind == "with_item" {
        if node.children.len() == 1 && node.children[0].kind == "as_pattern" {
            return node.children[0].children.iter().collect();
        }
        return node.children.iter().collect();
    }
    vec![node]
}
