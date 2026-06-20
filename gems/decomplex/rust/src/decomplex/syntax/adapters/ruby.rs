use super::super::tree_sitter_adapter::{
    first_child_kind, first_named_text, named_children, next_sibling_raw_text,
    previous_sibling_raw_text, AssignmentTarget, CallTarget, Target,
};
use super::super::{CallSite, FunctionDef, Language};
use super::base::LanguageProfile;
use crate::decomplex::ast::{node_text, normalize_text, span};
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

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        &["identifier"]
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        &["body_statement", "do_block"]
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        &["body_statement"]
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

    fn argument_list_node_kinds(&self) -> &[&str] {
        &["argument_list"]
    }

    fn block_argument_node_kinds(&self) -> &[&str] {
        &["do_block", "block"]
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if ruby_embedded_text_node(node) {
            return None;
        }
        if node.kind() == "call" && ruby_command_argument_call(node, source) {
            return None;
        }
        let mut target = match node.kind() {
            "call" => {
                ruby_proc_call_target(node, source).or_else(|| ruby_call_target(node, source))
            }
            "body_statement" => ruby_bare_body_call_target(node, source),
            "identifier" => ruby_bare_call_target(node, source),
            _ => None,
        }?;
        if ruby_brace_block_parameter_receiver(node, &target.receiver, source) {
            return None;
        }
        if target.arguments.is_empty() {
            if let Some(span) =
                ruby_narrow_no_arg_call_span(node, source, &target.receiver, &target.message)
            {
                target.span = Some(span);
            }
        }
        let effective_span = target
            .span
            .unwrap_or_else(|| target.source_node.map(span).unwrap_or_else(|| span(node)));
        if target.receiver == "self"
            && target.message.ends_with('?')
            && effective_span[0] != effective_span[2]
        {
            return None;
        }
        ruby_valid_call_target(&target).then_some(target)
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

    fn function_visibility(&self, node: Node<'_>, source: &str) -> Option<String> {
        if node.kind() == "singleton_method" {
            return Some("public".to_string());
        }
        if node.kind() == "argument_list" && first_child_kind(node) == Some("def") {
            let target = node
                .parent()
                .and_then(|parent| (parent.kind() == "call").then_some(parent))
                .and_then(|parent| ruby_call_target(parent, source))?;
            if target.receiver == "self"
                && matches!(target.message.as_str(), "private" | "protected" | "public")
            {
                return Some(target.message);
            }
        }
        None
    }

    fn after_collect_facts(&self, functions: &mut Vec<FunctionDef>, calls: &[CallSite]) {
        apply_ruby_visibility(functions, calls);
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

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        if ruby_direct_flat_map_block_statement(node, source) {
            return None;
        }
        ruby_state_variable_target(node, source)
            .or_else(|| ruby_bare_state_reader_target(node, source))
            .or_else(|| self.default_state_read_target(node, source))
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

fn ruby_call_target<'tree>(node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
    let receiver = node.child_by_field_name("receiver");
    let method = node.child_by_field_name("method");
    let arguments = ruby_argument_texts(node, source);
    let message = method
        .map(|method| node_text(method, source).to_string())
        .or_else(|| first_named_text(node, source, &["identifier", "constant"]))
        .or_else(|| {
            let text = normalize_text(node_text(node, source));
            (receiver.is_none() && ruby_simple_call_text(&text)).then_some(text)
        })?;

    let mut target = CallTarget::new(
        receiver
            .map(|receiver| normalize_text(node_text(receiver, source)))
            .unwrap_or_else(|| "self".to_string()),
        message,
        arguments,
    );
    if target.arguments.is_empty() {
        if let (Some(receiver), Some(method)) = (receiver, method) {
            let receiver_span = span(receiver);
            let method_span = span(method);
            target.span = Some([
                receiver_span[0],
                receiver_span[1],
                method_span[2],
                method_span[3],
            ]);
        }
    }
    target.safe_navigation = ruby_safe_navigation_call(node, source);
    Some(target)
}

fn apply_ruby_visibility(functions: &mut [FunctionDef], calls: &[CallSite]) {
    let mut owners = functions
        .iter()
        .map(|function| function.owner.clone())
        .collect::<Vec<_>>();
    owners.sort();
    owners.dedup();

    for owner in owners {
        let function_indices = functions
            .iter()
            .enumerate()
            .filter_map(|(index, function)| (function.owner == owner).then_some(index))
            .collect::<Vec<_>>();
        let call_indices = calls
            .iter()
            .enumerate()
            .filter_map(|(index, call)| {
                (call.owner == owner && ruby_visibility_call(call)).then_some(index)
            })
            .collect::<Vec<_>>();

        let mut visibility = "public".to_string();
        let mut events = Vec::new();
        events.extend(
            function_indices
                .iter()
                .map(|index| (functions[*index].line, 1_u8, *index)),
        );
        events.extend(
            call_indices
                .iter()
                .map(|index| (calls[*index].line, 0_u8, *index)),
        );
        events.sort();

        for (_, kind, index) in events {
            if kind == 1 {
                if functions[index].visibility.is_none() {
                    functions[index].visibility = Some(if functions[index].name.contains('.') {
                        "public".to_string()
                    } else {
                        visibility.clone()
                    });
                }
            } else {
                let call = &calls[index];
                if call.arguments.is_empty() {
                    visibility = call.message.clone();
                } else {
                    for argument in &call.arguments {
                        let name = ruby_visibility_arg_name(argument);
                        for function_index in function_indices.iter().rev() {
                            if functions[*function_index].name == name {
                                functions[*function_index].visibility = Some(call.message.clone());
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

fn ruby_visibility_call(call: &CallSite) -> bool {
    call.function == "(top-level)"
        && call.receiver == "self"
        && matches!(call.message.as_str(), "public" | "protected" | "private")
}

fn ruby_visibility_arg_name(argument: &str) -> String {
    argument
        .trim()
        .trim_start_matches(':')
        .trim_start_matches('"')
        .trim_end_matches('"')
        .trim_start_matches('\'')
        .trim_end_matches('\'')
        .to_string()
}

fn ruby_bare_call_target<'tree>(node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
    if !ruby_bare_call_identifier(node, source) {
        return None;
    }
    let parent = node.parent();
    let source_node = if parent
        .map(|parent| parent.kind() == "call")
        .unwrap_or(false)
        || node
            .next_sibling()
            .map(|sibling| sibling.kind() == "argument_list")
            .unwrap_or(false)
    {
        parent.unwrap_or(node)
    } else {
        node
    };
    let mut target = CallTarget::new(
        "self".to_string(),
        node_text(node, source).to_string(),
        ruby_argument_texts(source_node, source),
    );
    target.source_node = Some(source_node);
    target.safe_navigation = ruby_safe_navigation_call(source_node, source);
    Some(target)
}

fn ruby_bare_body_call_target<'tree>(node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
    let stripped = node_text(node, source).trim_start();
    if matches!(first_child_kind(node), Some("def" | "class" | "module"))
        || stripped.starts_with("def ")
        || stripped.starts_with("class ")
        || stripped.starts_with("module ")
    {
        return None;
    }
    if let Some(explicit) = ruby_explicit_receiver_body_call_target(node, source) {
        return Some(explicit);
    }

    let message = node_text(node, source).trim().to_string();
    if !ruby_simple_call_text(&message)
        || matches!(message.as_str(), "true" | "false" | "nil" | "self")
    {
        return None;
    }
    Some(CallTarget::new("self".to_string(), message, Vec::new()))
}

fn ruby_explicit_receiver_body_call_target<'tree>(
    node: Node<'tree>,
    source: &str,
) -> Option<CallTarget<'tree>> {
    let children = named_children(node);
    let receiver = *children.first()?;
    let message = *children.get(1)?;
    if !matches!(receiver.kind(), "self" | "constant" | "identifier") {
        return None;
    }
    if !matches!(message.kind(), "identifier" | "constant") {
        return None;
    }
    let mut target = CallTarget::new(
        normalize_text(node_text(receiver, source)),
        node_text(message, source).to_string(),
        Vec::new(),
    );
    let receiver_span = span(receiver);
    let message_span = span(message);
    target.span = Some([
        receiver_span[0],
        receiver_span[1],
        message_span[2],
        message_span[3],
    ]);
    Some(target)
}

fn ruby_proc_call_target<'tree>(node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
    if node.kind() != "call" {
        return None;
    }
    let mut cursor = node.walk();
    if !node
        .children(&mut cursor)
        .any(|child| !child.is_named() && node_text(child, source) == ".")
    {
        return None;
    }
    if node.child_by_field_name("method").is_some() {
        return None;
    }

    let receiver = node
        .child_by_field_name("receiver")
        .or_else(|| named_children(node).into_iter().next())?;
    let args = node.child_by_field_name("arguments").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list")
    })?;
    let mut target = CallTarget::new(
        normalize_text(node_text(receiver, source)),
        "call".to_string(),
        ruby_argument_texts(node, source),
    );
    target.source_node = Some(node);
    target.safe_navigation = ruby_safe_navigation_call(node, source);
    target.block = named_children(args)
        .into_iter()
        .any(|child| matches!(child.kind(), "do_block" | "block"));
    Some(target)
}

fn ruby_argument_texts(node: Node<'_>, source: &str) -> Vec<String> {
    let args = node.child_by_field_name("arguments").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "argument_list")
    });
    let Some(args) = args else {
        return Vec::new();
    };
    let values = named_children(args)
        .into_iter()
        .map(|child| normalize_text(node_text(child, source)))
        .collect::<Vec<_>>();
    if !values.is_empty() {
        return values;
    }

    let mut text = node_text(args, source).trim().to_string();
    if text.starts_with('(') && text.ends_with(')') && text.len() >= 2 {
        text = text[1..text.len() - 1].to_string();
    }
    text.split(',')
        .map(normalize_text)
        .filter(|arg| !arg.is_empty())
        .collect()
}

fn ruby_safe_navigation_call(node: Node<'_>, source: &str) -> bool {
    let mut cursor = node.walk();
    let found = node
        .children(&mut cursor)
        .any(|child| !child.is_named() && node_text(child, source) == "&.");
    found
}

fn ruby_simple_call_text(text: &str) -> bool {
    Regex::new(r"^[a-z_]\w*[!?=]?$")
        .unwrap()
        .is_match(text.trim())
}

fn ruby_bare_call_identifier(node: Node<'_>, source: &str) -> bool {
    if ruby_embedded_text_node(node) {
        return false;
    }
    let Some(parent) = node.parent() else {
        return false;
    };
    if ruby_declaration_name(node, parent, source) {
        return false;
    }
    if matches!(
        parent.kind(),
        "method_parameters" | "block_parameters" | "argument_list" | "assignment"
    ) {
        return false;
    }
    if parent.kind() == "call" {
        if ruby_command_argument_call(parent, source) {
            return false;
        }
        if parent.child_by_field_name("receiver").is_some() {
            return false;
        }
        let first = named_children(parent).into_iter().next();
        return first == Some(node)
            && node
                .next_sibling()
                .map(|sibling| sibling.kind() == "argument_list")
                .unwrap_or(false);
    }
    if next_sibling_raw_text(node).as_deref() == Some("=")
        || previous_sibling_raw_text(node).as_deref() == Some("=")
        || next_sibling_raw_text(node).as_deref() == Some(".")
        || previous_sibling_raw_text(node).as_deref() == Some(".")
    {
        return false;
    }

    matches!(
        parent.kind(),
        "body_statement" | "then" | "else" | "elsif" | "ensure" | "rescue"
    ) || node
        .next_sibling()
        .map(|sibling| sibling.kind() == "argument_list")
        .unwrap_or(false)
}

fn ruby_declaration_name(node: Node<'_>, parent: Node<'_>, source: &str) -> bool {
    if matches!(
        parent.kind(),
        "method" | "singleton_method" | "class" | "module"
    ) {
        return true;
    }
    if parent.kind() == "body_statement" {
        let stripped = node_text(parent, source).trim_start();
        if matches!(first_child_kind(parent), Some("def" | "class" | "module"))
            || stripped.starts_with("def ")
            || stripped.starts_with("class ")
            || stripped.starts_with("module ")
        {
            return true;
        }
    }
    matches!(node.kind(), "identifier" | "constant") && parent.kind() == "method_parameters"
}

fn ruby_command_argument_call(node: Node<'_>, source: &str) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "argument_list" {
        return false;
    }
    !node_text(parent, source).trim_start().starts_with('(')
}

fn ruby_embedded_text_node(node: Node<'_>) -> bool {
    let mut current = Some(node);
    while let Some(node) = current {
        if matches!(
            node.kind(),
            "string"
                | "string_content"
                | "heredoc_body"
                | "simple_symbol"
                | "symbol"
                | "delimited_symbol"
        ) {
            return true;
        }
        current = node.parent();
    }
    false
}

fn ruby_brace_block_parameter_receiver(node: Node<'_>, receiver: &str, source: &str) -> bool {
    if receiver.contains('.') || receiver.contains('[') || receiver == "self" {
        return false;
    }
    let mut current = node.parent();
    while let Some(parent) = current {
        if parent.kind() == "block" {
            return ruby_block_parameters(parent, source)
                .into_iter()
                .any(|param| param == receiver);
        }
        if matches!(
            parent.kind(),
            "method" | "singleton_method" | "body_statement"
        ) {
            return false;
        }
        current = parent.parent();
    }
    false
}

fn ruby_block_parameters(block: Node<'_>, source: &str) -> Vec<String> {
    named_children(block)
        .into_iter()
        .find(|child| child.kind() == "block_parameters")
        .map(|params| {
            named_children(params)
                .into_iter()
                .filter(|child| child.kind() == "identifier")
                .map(|child| node_text(child, source).to_string())
                .collect()
        })
        .unwrap_or_default()
}

fn ruby_narrow_no_arg_call_span(
    node: Node<'_>,
    source: &str,
    receiver: &str,
    message: &str,
) -> Option<[usize; 4]> {
    if message.is_empty() || message == "[]" || message == "[]=" {
        return None;
    }
    let needle = if receiver == "self" {
        message.to_string()
    } else {
        format!("{receiver}.{message}")
    };
    let node_span = span(node);
    if let Some(line_text) = source.lines().nth(node_span[0].saturating_sub(1)) {
        if let Some(start) = line_text.find(&needle) {
            let end = start + needle.chars().count();
            return Some([node_span[0], start, node_span[0], end]);
        }
    }
    let text = node_text(node, source);
    let offset = text.find(&needle)?;
    if text[..offset].contains('\n') || needle.contains('\n') {
        return None;
    }
    let mut start = node_span[1] + text[..offset].chars().count();
    let end = start + needle.chars().count();
    if start == node_span[1]
        && (previous_sibling_raw_text(node).as_deref() == Some("!")
            || node
                .start_byte()
                .checked_sub(1)
                .and_then(|index| source.as_bytes().get(index))
                .copied()
                == Some(b'!'))
    {
        start += 1;
    }
    Some([node_span[0], start, node_span[0], end])
}

fn ruby_valid_call_target(target: &CallTarget<'_>) -> bool {
    if invalid_call_text(&target.receiver)
        || invalid_call_text(&target.message)
        || target.receiver.split_whitespace().count() > 1
    {
        return false;
    }
    if matches!(target.message.as_str(), "[]" | "[]=") {
        return true;
    }
    Regex::new(r"^[A-Za-z_]\w*[!?=]?$")
        .unwrap()
        .is_match(target.message.as_str())
}

fn invalid_call_text(text: &str) -> bool {
    text.chars()
        .any(|ch| matches!(ch, '"' | '\'' | '\n' | '\r'))
}

fn ruby_state_variable_target(node: Node<'_>, source: &str) -> Option<Target> {
    matches!(node.kind(), "instance_variable" | "global_variable").then(|| Target {
        receiver: "self".to_string(),
        field: node_text(node, source).to_string(),
    })
}

fn ruby_bare_state_reader_target(node: Node<'_>, source: &str) -> Option<Target> {
    if node.kind() != "identifier" || !ruby_simple_call_text(node_text(node, source)) {
        return None;
    }
    let parent = node.parent()?;
    if ruby_declaration_name(node, parent, source) {
        return None;
    }
    if matches!(
        parent.kind(),
        "call"
            | "method_parameters"
            | "block_parameters"
            | "argument_list"
            | "assignment"
            | "operator_assignment"
            | "pair"
            | "hash_key_symbol"
    ) {
        return None;
    }
    if next_sibling_raw_text(node).as_deref() == Some("=")
        || previous_sibling_raw_text(node).as_deref() == Some("=")
        || next_sibling_raw_text(node).as_deref() == Some(".")
        || previous_sibling_raw_text(node).as_deref() == Some(".")
        || next_sibling_raw_text(node).as_deref() == Some(":")
        || previous_sibling_raw_text(node).as_deref() == Some(":")
    {
        return None;
    }

    Some(Target {
        receiver: "self".to_string(),
        field: node_text(node, source).to_string(),
    })
}

fn ruby_direct_flat_map_block_statement(node: Node<'_>, source: &str) -> bool {
    if node.kind() != "call" {
        return false;
    }
    let Some(method) = node.child_by_field_name("method") else {
        return false;
    };
    if node_text(method, source) != "flat_map" {
        return false;
    }
    let Some(parent) = node.parent() else {
        return false;
    };
    parent.kind() == "body_statement"
        && named_children(parent).first().copied() == Some(node)
        && named_children(node)
            .iter()
            .any(|child| child.kind() == "do_block" || child.kind() == "block")
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
