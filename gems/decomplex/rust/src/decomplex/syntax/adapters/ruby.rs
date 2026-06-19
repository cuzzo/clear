use super::super::tree_sitter_adapter::{
    first_child_kind, first_named_text, named_children, next_sibling_raw_text, AssignmentTarget,
    Target,
};
use super::super::Language;
use super::base::LanguageProfile;
use crate::decomplex::ast::{node_text, normalize_text};
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct RubyProfile;

impl LanguageProfile for RubyProfile {
    fn language(&self) -> Language {
        Language::Ruby
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_ruby::LANGUAGE.into()
    }

    fn function_node_kinds(&self) -> &[&str] {
        &["method"]
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        &["class"]
    }

    fn module_owner_node_kinds(&self) -> &[&str] {
        &["module"]
    }

    fn call_node_kinds(&self) -> &[&str] {
        &["call"]
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        &["method_parameters"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["body_statement", "do_block"]
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        &["identifier", "constant"]
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        &["assignment", "operator_assignment"]
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        &["=", "+=", "-=", "*=", "/=", "%=", "&&=", "||="]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary"]
    }

    fn case_node_kinds(&self) -> &[&str] {
        &["case"]
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        &["when"]
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        &["pattern"]
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        &["method", "class", "module"]
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        &["when", "else", "then", "comment"]
    }

    fn default_case_patterns(&self) -> &[&str] {
        &["_", "default", "else"]
    }

    fn boolean_and_operators(&self) -> &[&str] {
        &["&&", "and"]
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        &["binary"]
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        &["body_statement", "pattern", "argument_list"]
    }

    fn accessor_call_node_kinds(&self) -> &[&str] {
        &["call"]
    }

    fn function_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        match node.kind() {
            "singleton_method" => {
                let name = node
                    .child_by_field_name("name")
                    .map(|name| node_text(name, source).to_string())
                    .or_else(|| {
                        named_children(node)
                            .into_iter()
                            .rev()
                            .find(|child| {
                                matches!(
                                    child.kind(),
                                    "identifier" | "field_identifier" | "property_identifier"
                                )
                            })
                            .map(|child| node_text(child, source).to_string())
                    })?;
                Some(format!("self.{name}"))
            }
            "body_statement" if first_child_kind(node) == Some("def") => {
                hidden_ruby_method_name(node, source)
            }
            "argument_list" if first_child_kind(node) == Some("def") => {
                inline_def_name(node, source)
            }
            _ => self.default_function_name(node, source),
        }
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "body_statement"
            && matches!(first_child_kind(node), Some("class" | "module"))
        {
            return first_named_text(node, source, &["constant", "identifier", "type_identifier"]);
        }
        self.default_owner_name_from_declaration(node, source)
    }

    fn hidden_case(&self, node: Node<'_>) -> bool {
        matches!(
            node.kind(),
            "body_statement" | "block_body" | "argument_list"
        ) && first_child_kind(node) == Some("case")
    }

    fn hidden_case_source_node<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        let mut cursor = node.walk();
        let result = node
            .children(&mut cursor)
            .find(|child| child.kind() == "case");
        result
    }

    fn predicate_less_case(&self, node: Node<'_>) -> bool {
        (node.kind() == "case" || self.hidden_case(node)) && self.decision_subject(node).is_none()
    }

    fn case_pattern_texts(&self, patterns: &[Node<'_>], source: &str) -> Vec<String> {
        ruby_case_pattern_texts(patterns, source)
    }

    fn state_target(&self, lhs: Node<'_>, source: &str) -> Option<Target> {
        ruby_state_variable_target(lhs, source).or_else(|| self.default_state_target(lhs, source))
    }

    fn assignment_target<'tree>(&self, node: Node<'tree>) -> Option<AssignmentTarget<'tree>> {
        self.default_assignment_target(node)
            .or_else(|| match node.kind() {
                "instance_variable" | "global_variable" if self.assignment_lhs_node(node) => {
                    Some(AssignmentTarget {
                        lhs: node,
                        source: node.parent().unwrap_or(node),
                    })
                }
                _ => None,
            })
    }

    fn skip_state_write_node(&self, node: Node<'_>) -> bool {
        node.kind() == "operator_assignment"
            || (self.assignment_lhs_node(node)
                && next_sibling_raw_text(node).as_deref() != Some("=")
                && node.kind() != "instance_variable")
    }

    fn skip_state_write_target(&self, target: &Target) -> bool {
        target.field == "[]" || target.field.starts_with('$')
    }

    fn method_param_types(&self, lines: &[String]) -> BTreeMap<String, BTreeMap<String, String>> {
        ruby_method_param_types(lines)
    }

    fn immutable_struct_readers(&self, lines: &[String]) -> BTreeMap<String, BTreeSet<String>> {
        ruby_immutable_struct_readers(lines)
    }

    fn immutable_struct_reader_types(
        &self,
        lines: &[String],
    ) -> BTreeMap<String, BTreeMap<String, String>> {
        ruby_immutable_struct_reader_types(lines)
    }

    fn type_aliases(&self, lines: &[String]) -> BTreeMap<String, String> {
        ruby_type_aliases(lines)
    }
}

fn hidden_ruby_method_name(node: Node<'_>, source: &str) -> Option<String> {
    let children = named_children(node);
    let receiver_index = children
        .iter()
        .position(|child| matches!(child.kind(), "self" | "constant"));
    let search: Vec<Node<'_>> = if let Some(index) = receiver_index {
        children.into_iter().skip(index + 1).collect()
    } else {
        children
    };
    let name = search
        .into_iter()
        .find(|child| {
            matches!(
                child.kind(),
                "identifier" | "field_identifier" | "property_identifier"
            )
        })
        .map(|child| node_text(child, source).to_string())?;
    if receiver_index.is_some() {
        Some(format!("self.{name}"))
    } else {
        Some(name)
    }
}

fn inline_def_name(node: Node<'_>, source: &str) -> Option<String> {
    hidden_ruby_method_name(node, source)
}

fn ruby_state_variable_target(node: Node<'_>, source: &str) -> Option<Target> {
    matches!(node.kind(), "instance_variable" | "global_variable").then(|| Target {
        receiver: "self".to_string(),
        field: node_text(node, source).to_string(),
    })
}

fn ruby_case_pattern_texts(patterns: &[Node<'_>], source: &str) -> Vec<String> {
    if patterns.is_empty() {
        return Vec::new();
    }
    let texts = patterns
        .iter()
        .map(|pattern| normalize_text(node_text(*pattern, source)))
        .collect::<Vec<_>>();
    if !texts.iter().any(|text| text.starts_with('*')) {
        return texts;
    }

    let mut out = Vec::new();
    let mut pending_plain = Vec::new();
    for (index, text) in texts.iter().enumerate() {
        if text.starts_with('*') {
            if !pending_plain.is_empty() {
                out.push(pending_plain.join(", "));
                pending_plain.clear();
            }
            if texts.len() == 1 || index > 0 {
                out.push(text.trim_start_matches('*').to_string());
            } else {
                out.push(text.clone());
            }
        } else {
            pending_plain.push(text.clone());
        }
    }
    if !pending_plain.is_empty() {
        out.push(pending_plain.join(", "));
    }
    out
}

fn ruby_immutable_struct_readers(lines: &[String]) -> BTreeMap<String, BTreeSet<String>> {
    let mut readers = BTreeMap::new();
    let mut class_stack = Vec::new();
    let class_struct_re =
        Regex::new(r"^\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b").unwrap();
    let const_re = Regex::new(r"^\s*const\s+:([A-Za-z_]\w*)\b").unwrap();
    let end_re = Regex::new(r"^\s*end\s*(?:#.*)?$").unwrap();

    for line in lines {
        if let Some(caps) = class_struct_re.captures(line) {
            class_stack.push(caps[1].to_string());
            continue;
        }
        if !class_stack.is_empty() {
            if let Some(caps) = const_re.captures(line) {
                readers
                    .entry(class_stack.last().unwrap().clone())
                    .or_insert_with(BTreeSet::new)
                    .insert(caps[1].to_string());
                continue;
            }
        }
        if end_re.is_match(line) {
            class_stack.pop();
        }
    }
    readers
}

fn ruby_immutable_struct_reader_types(
    lines: &[String],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut reader_types = BTreeMap::new();
    let mut class_stack = Vec::new();
    let class_struct_re =
        Regex::new(r"^\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b").unwrap();
    let const_type_re =
        Regex::new(r"^\s*const\s+:([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\b")
            .unwrap();
    let end_re = Regex::new(r"^\s*end\s*(?:#.*)?$").unwrap();

    for line in lines {
        if let Some(caps) = class_struct_re.captures(line) {
            class_stack.push(caps[1].to_string());
            continue;
        }
        if !class_stack.is_empty() {
            if let Some(caps) = const_type_re.captures(line) {
                reader_types
                    .entry(class_stack.last().unwrap().clone())
                    .or_insert_with(BTreeMap::new)
                    .insert(caps[1].to_string(), caps[2].to_string());
                continue;
            }
        }
        if end_re.is_match(line) {
            class_stack.pop();
        }
    }
    reader_types
}

fn ruby_type_aliases(lines: &[String]) -> BTreeMap<String, String> {
    let mut aliases = BTreeMap::new();
    let type_alias_re =
        Regex::new(r"^\s*([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*([A-Z]\w*(?:::[A-Z]\w*)*)\s*\}")
            .unwrap();
    let const_alias_re = Regex::new(r"^\s*([A-Z]\w*)\s*=\s*([A-Z]\w*(?:::[A-Z]\w*)*)\b").unwrap();

    for line in lines {
        if let Some(caps) = type_alias_re.captures(line) {
            aliases.insert(caps[1].to_string(), caps[2].to_string());
        } else if let Some(caps) = const_alias_re.captures(line) {
            aliases.insert(caps[1].to_string(), caps[2].to_string());
        }
    }
    aliases
}

fn ruby_method_param_types(lines: &[String]) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut types_by_method = BTreeMap::new();
    let mut pending_sig = String::new();
    let def_re = Regex::new(r"^\s*def\s+([A-Za-z_]\w*[!?=]?)(?:\s|\(|$)").unwrap();

    for line in lines {
        if ruby_pending_sig_active(line, &pending_sig) {
            pending_sig.push_str(line);
        }
        if let Some(caps) = def_re.captures(line) {
            types_by_method.insert(caps[1].to_string(), ruby_sig_param_types(&pending_sig));
            pending_sig.clear();
        }
    }
    types_by_method
}

fn ruby_pending_sig_active(line: &str, pending_sig: &str) -> bool {
    !pending_sig.is_empty() || line.trim().starts_with("sig")
}

fn ruby_sig_param_types(sig_source: &str) -> BTreeMap<String, String> {
    let params_re = Regex::new(r"params\s*\((.*?)\)").unwrap();
    let param_pair_re =
        Regex::new(r"([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)").unwrap();
    let mut params = BTreeMap::new();
    if let Some(p_caps) = params_re.captures(sig_source) {
        for pair in param_pair_re.captures_iter(&p_caps[1]) {
            params.insert(pair[1].to_string(), pair[2].to_string());
        }
    }
    params
}
