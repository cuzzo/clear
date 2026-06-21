use super::super::tree_sitter_adapter::Target;
use super::super::Language;
use super::base::LanguageProfile;
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
