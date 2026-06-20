use super::super::tree_sitter_adapter::{
    direct_operator, first_child_kind, first_named_text, named_children, next_sibling_raw_text,
    previous_sibling_raw_text, AssignmentTarget, CallTarget, Target,
};
use super::super::{
    CallSite, Document, FunctionDef, Language, ProtocolMethodEffect, SemanticEffectSite, StateRead,
    StateWrite,
};
use super::base::{normalize_protocol_state, protocol_method_name, LanguageProfile};
use crate::decomplex::ast::{node_text, normalize_text, span, RawNode};
use regex::Regex;
use std::collections::BTreeSet;
use std::path::Path;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct RubyProfile;

const RUBY_PROTOCOL_IGNORED_MIDS: &[&str] = &[
    "abstract!",
    "alias_method",
    "any",
    "attr_accessor",
    "attr_reader",
    "attr_writer",
    "bind",
    "cast",
    "checked",
    "enum",
    "extend",
    "final",
    "include",
    "interface!",
    "let",
    "must",
    "must_because",
    "nilable",
    "override",
    "overridable",
    "params",
    "prepend",
    "private",
    "private_class_method",
    "protected",
    "public",
    "require",
    "require_relative",
    "requires_ancestor",
    "sealed!",
    "sig",
    "type_member",
    "type_template",
    "untyped",
    "unsafe",
    "void",
    "a_kind_of",
    "after",
    "around",
    "before",
    "be",
    "be_a",
    "be_an",
    "be_empty",
    "be_falsey",
    "be_nil",
    "be_truthy",
    "change",
    "contain_exactly",
    "context",
    "describe",
    "eq",
    "eql",
    "equal",
    "expect",
    "have_attributes",
    "have_key",
    "have_received",
    "it",
    "match",
    "not_to",
    "raise_error",
    "receive",
    "subject",
    "to",
];

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

    fn path_action_node_kinds(&self) -> &[&str] {
        &["call", "return"]
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        &["body_statement"]
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        &["binary"]
    }

    fn branch_node_kinds(&self) -> &[&str] {
        &[
            "if",
            "unless",
            "if_modifier",
            "unless_modifier",
            "case",
            "while",
            "until",
            "for",
        ]
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
            "identifier" => ruby_visibility_identifier_call_target(node, source)
                .or_else(|| ruby_bare_call_target(node, source)),
            _ => None,
        }?;
        if target.arguments.is_empty() && !ruby_call_has_block(node) {
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

    fn structural_semantic_effect_sites(
        &self,
        root: Node<'_>,
        source: &str,
        file: &Path,
        functions: &[FunctionDef],
        state_reads: &[StateRead],
        state_writes: &[StateWrite],
    ) -> Vec<SemanticEffectSite> {
        ruby_structural_semantic_effect_sites(
            root,
            source,
            file,
            functions,
            state_reads,
            state_writes,
        )
    }

    fn protocol_method_effects(&self, document: &Document) -> Vec<ProtocolMethodEffect> {
        document
            .function_defs
            .iter()
            .map(|function_def| {
                let mut reads = document
                    .state_reads
                    .iter()
                    .filter(|read| {
                        read.owner == function_def.owner && read.function == function_def.name
                    })
                    .map(|read| normalize_protocol_state(&read.field))
                    .collect::<Vec<_>>();
                reads.extend(ruby_protocol_bare_reads(function_def));
                reads.sort();
                reads.dedup();

                let mut writes = document
                    .state_writes
                    .iter()
                    .filter(|write| {
                        write.owner == function_def.owner && write.function == function_def.name
                    })
                    .map(|write| normalize_protocol_state(&write.field))
                    .collect::<Vec<_>>();
                writes.sort();
                writes.dedup();

                ProtocolMethodEffect {
                    file: function_def.file.clone(),
                    owner: function_def.owner.clone(),
                    name: protocol_method_name(&function_def.name),
                    line: function_def.line,
                    reads,
                    writes,
                }
            })
            .collect()
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
        if ruby_sorbet_signature_payload_node(node, source) {
            return None;
        }
        let target = ruby_state_variable_target(node, source)
            .or_else(|| self.default_state_read_target(node, source))?;
        Some(target)
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

    fn suppress_indexed_lhs_reads(&self) -> bool {
        false
    }

    fn indexed_lhs_descendants_are_writes(&self) -> bool {
        false
    }

    fn keyed_element_first_named_child_is_key(&self) -> bool {
        false
    }

    fn nested_assignment_dependencies_only(&self) -> bool {
        true
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
    if target.arguments.is_empty() && !ruby_call_has_block(node) {
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

fn ruby_visibility_identifier_call_target<'tree>(
    node: Node<'tree>,
    source: &str,
) -> Option<CallTarget<'tree>> {
    let message = node_text(node, source);
    if !matches!(message, "private" | "protected" | "public") {
        return None;
    }
    let parent = node.parent()?;
    if matches!(
        parent.kind(),
        "call" | "argument_list" | "method_parameters" | "block_parameters" | "assignment"
    ) {
        return None;
    }
    let mut target = CallTarget::new("self".to_string(), message.to_string(), Vec::new());
    target.source_node = Some(node);
    Some(target)
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
    if let Some(arguments) = ruby_inline_def_argument_texts(args, source) {
        return arguments;
    }
    let values = named_children(args)
        .into_iter()
        .map(|child| ruby_argument_text(child, args, source))
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

fn ruby_argument_text(node: Node<'_>, args: Node<'_>, source: &str) -> String {
    if node.kind() == "string" && !node_text(args, source).trim_start().starts_with('(') {
        if let Some(content) = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "string_content")
        {
            return normalize_text(node_text(content, source));
        }
        let text = normalize_text(node_text(node, source));
        if text.len() >= 2
            && ((text.starts_with('"') && text.ends_with('"'))
                || (text.starts_with('\'') && text.ends_with('\'')))
        {
            return text[1..text.len() - 1].to_string();
        }
        return text;
    }
    normalize_text(node_text(node, source))
}

fn ruby_inline_def_argument_texts(args: Node<'_>, source: &str) -> Option<Vec<String>> {
    let children = named_children(args);
    if children.len() != 1 || first_child_kind(children[0]) != Some("def") {
        return None;
    }
    let method = children[0];
    let name = method
        .child_by_field_name("name")
        .or_else(|| {
            named_children(method)
                .into_iter()
                .find(|child| matches!(child.kind(), "identifier" | "field_identifier"))
        })
        .map(|node| normalize_text(node_text(node, source)))?;
    let params = named_children(method)
        .into_iter()
        .find(|child| child.kind() == "method_parameters")
        .map(|node| normalize_text(node_text(node, source)));
    let body = named_children(method)
        .into_iter()
        .find(|child| child.kind() == "body_statement")
        .map(|node| normalize_text(node_text(node, source)));
    let mut out = vec![name];
    if let Some(params) = params.filter(|value| !value.is_empty()) {
        out.push(params);
    }
    if let Some(body) = body.filter(|value| !value.is_empty()) {
        out.push(body);
    }
    Some(out)
}

fn ruby_structural_semantic_effect_sites(
    root: Node<'_>,
    source: &str,
    file: &Path,
    functions: &[FunctionDef],
    state_reads: &[StateRead],
    state_writes: &[StateWrite],
) -> Vec<SemanticEffectSite> {
    let file_name = file.to_string_lossy().to_string();
    let mut out = Vec::new();
    out.extend(ruby_global_context_effects(source, state_reads));
    out.extend(ruby_state_mutation_effects(state_writes));
    out.extend(ruby_method_hook_effects(functions));
    ruby_collect_structural_effect_nodes(root, source, &file_name, functions, &mut out);
    out
}

fn ruby_global_context_effects(source: &str, state_reads: &[StateRead]) -> Vec<SemanticEffectSite> {
    state_reads
        .iter()
        .filter(|read| read.field.starts_with('$'))
        .filter(|read| !ruby_global_assignment_read(source, read))
        .map(|read| SemanticEffectSite {
            kind: "context_dependency".to_string(),
            detail: read.field.clone(),
            file: read.file.clone(),
            function: read.function.clone(),
            line: read.line,
            span: read.span,
        })
        .collect()
}

fn ruby_global_assignment_read(source: &str, read: &StateRead) -> bool {
    let line_text = source
        .lines()
        .nth(read.line.saturating_sub(1))
        .unwrap_or("");
    line_text
        .chars()
        .skip(read.span[3])
        .collect::<String>()
        .trim_start()
        .starts_with('=')
}

fn ruby_state_mutation_effects(state_writes: &[StateWrite]) -> Vec<SemanticEffectSite> {
    state_writes
        .iter()
        .filter(|write| write.receiver != "self")
        .filter(|write| !write.field.starts_with('@') && !write.field.starts_with('$'))
        .map(|write| SemanticEffectSite {
            kind: "hidden_mutation".to_string(),
            detail: format!("{}=", write.field),
            file: write.file.clone(),
            function: write.function.clone(),
            line: write.line,
            span: write.span,
        })
        .collect()
}

fn ruby_method_hook_effects(functions: &[FunctionDef]) -> Vec<SemanticEffectSite> {
    functions
        .iter()
        .filter_map(|function| {
            let name = function
                .name
                .split('.')
                .last()
                .unwrap_or(function.name.as_str());
            matches!(name, "method_missing" | "respond_to_missing?").then(|| SemanticEffectSite {
                kind: "metaprogramming".to_string(),
                detail: format!("def {name}"),
                file: function.file.clone(),
                function: function.name.clone(),
                line: function.line,
                span: function.span,
            })
        })
        .collect()
}

fn ruby_collect_structural_effect_nodes(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
    out: &mut Vec<SemanticEffectSite>,
) {
    out.extend(ruby_structural_effect_for_node(
        node, source, file, functions,
    ));
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        ruby_collect_structural_effect_nodes(child, source, file, functions, out);
    }
}

fn ruby_structural_effect_for_node(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    match node.kind() {
        "yield" => vec![ruby_semantic_effect_site(
            node,
            source,
            file,
            functions,
            "dynamic_dispatch",
            "yield",
        )],
        "subshell" => vec![ruby_semantic_effect_site(
            node,
            source,
            file,
            functions,
            "hidden_io",
            "backtick",
        )],
        "singleton_class" => ruby_singleton_class_effect(node, source, file, functions),
        "element_reference" => ruby_element_reference_effect(node, source, file, functions),
        "assignment" => ruby_assignment_effects(node, source, file, functions),
        "operator_assignment" => ruby_operator_assignment_effect(node, source, file, functions),
        "binary" => ruby_binary_effect(node, source, file, functions),
        _ => Vec::new(),
    }
}

fn ruby_singleton_class_effect(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let Some(receiver) = named_children(node).into_iter().next() else {
        return Vec::new();
    };
    if node_text(receiver, source) == "self" {
        return Vec::new();
    }
    vec![ruby_semantic_effect_site(
        node,
        source,
        file,
        functions,
        "metaprogramming",
        &format!("class << {}", normalize_text(node_text(receiver, source))),
    )]
}

fn ruby_element_reference_effect(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let Some(receiver) = named_children(node).into_iter().next() else {
        return Vec::new();
    };
    if node_text(receiver, source) != "ENV" {
        return Vec::new();
    }
    vec![ruby_semantic_effect_site(
        node,
        source,
        file,
        functions,
        "context_dependency",
        "ENV",
    )]
}

fn ruby_assignment_effects(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let lhs = node
        .child_by_field_name("left")
        .or_else(|| named_children(node).into_iter().next());
    let Some(lhs) = lhs else {
        return Vec::new();
    };
    let mut out = Vec::new();
    if lhs.kind() == "global_variable" {
        out.push(ruby_semantic_effect_site(
            node,
            source,
            file,
            functions,
            "context_dependency",
            node_text(lhs, source),
        ));
    }
    if lhs.kind() == "element_reference" {
        let receiver = named_children(lhs).into_iter().next();
        if receiver
            .map(|receiver| node_text(receiver, source) != "ENV")
            .unwrap_or(true)
        {
            out.push(ruby_semantic_effect_site(
                node,
                source,
                file,
                functions,
                "hidden_mutation",
                "[]=",
            ));
        }
    }
    out
}

fn ruby_operator_assignment_effect(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let lhs = node
        .child_by_field_name("left")
        .or_else(|| named_children(node).into_iter().next());
    if ruby_local_operator_assignment_lhs(lhs) {
        return Vec::new();
    }
    vec![ruby_semantic_effect_site(
        node,
        source,
        file,
        functions,
        "hidden_mutation",
        "op-assign",
    )]
}

fn ruby_local_operator_assignment_lhs(lhs: Option<Node<'_>>) -> bool {
    let Some(lhs) = lhs else {
        return true;
    };
    matches!(
        lhs.kind(),
        "identifier" | "instance_variable" | "global_variable"
    )
}

fn ruby_binary_effect(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    if direct_operator(node) != "<<" {
        return Vec::new();
    }
    vec![ruby_semantic_effect_site(
        node,
        source,
        file,
        functions,
        "hidden_mutation",
        "<<",
    )]
}

fn ruby_semantic_effect_site(
    node: Node<'_>,
    _source: &str,
    file: &str,
    functions: &[FunctionDef],
    kind: &str,
    detail: &str,
) -> SemanticEffectSite {
    let site_span = span(node);
    SemanticEffectSite {
        kind: kind.to_string(),
        detail: detail.to_string(),
        file: file.to_string(),
        function: ruby_effect_function(functions, site_span),
        line: site_span[0],
        span: site_span,
    }
}

fn ruby_effect_function(functions: &[FunctionDef], site_span: [usize; 4]) -> String {
    functions
        .iter()
        .filter(|function| span_contains(function.span, site_span))
        .min_by_key(|function| span_width(function.span))
        .map(|function| function.name.clone())
        .unwrap_or_else(|| "(top-level)".to_string())
}

fn span_contains(outer: [usize; 4], inner: [usize; 4]) -> bool {
    (outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]))
        && (outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]))
}

fn span_width(span: [usize; 4]) -> usize {
    span[2].saturating_sub(span[0]) * 10_000 + span[3].saturating_sub(span[1])
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

fn ruby_protocol_bare_reads(function_def: &FunctionDef) -> Vec<String> {
    let mut local_names = BTreeSet::new();
    local_names.extend(function_def.params.iter().cloned());
    ruby_protocol_collect_local_names(&function_def.body, &mut local_names, true);

    let mut reads = BTreeSet::new();
    ruby_protocol_collect_bare_reads(&function_def.body, None, &local_names, &mut reads, true);
    reads.into_iter().collect()
}

fn ruby_protocol_collect_local_names(
    node: &RawNode,
    local_names: &mut BTreeSet<String>,
    root: bool,
) {
    if !root && ruby_protocol_nested_boundary(node) {
        return;
    }
    if matches!(node.kind.as_str(), "assignment" | "operator_assignment") {
        if let Some(lhs) = raw_named_children(node).first() {
            if lhs.kind == "identifier" && ruby_simple_call_text(&lhs.text) {
                local_names.insert(lhs.text.clone());
            }
        }
    }
    if matches!(node.kind.as_str(), "block_parameters" | "method_parameters") {
        for child in raw_named_children(node) {
            if child.kind == "identifier" && ruby_simple_call_text(&child.text) {
                local_names.insert(child.text.clone());
            }
        }
    }
    for child in &node.children {
        ruby_protocol_collect_local_names(child, local_names, false);
    }
}

fn ruby_protocol_collect_bare_reads(
    node: &RawNode,
    parent: Option<&RawNode>,
    local_names: &BTreeSet<String>,
    reads: &mut BTreeSet<String>,
    root: bool,
) {
    if !root && ruby_protocol_nested_boundary(node) {
        return;
    }
    if node.kind == "identifier" && ruby_protocol_bare_reader(node, parent, local_names) {
        reads.insert(normalize_protocol_state(&node.text));
    }
    for child in &node.children {
        ruby_protocol_collect_bare_reads(child, Some(node), local_names, reads, false);
    }
}

fn ruby_protocol_bare_reader(
    node: &RawNode,
    parent: Option<&RawNode>,
    local_names: &BTreeSet<String>,
) -> bool {
    let name = node.text.as_str();
    if !ruby_simple_call_text(name)
        || local_names.contains(name)
        || RUBY_PROTOCOL_IGNORED_MIDS.contains(&name)
    {
        return false;
    }
    let Some(parent) = parent else {
        return false;
    };
    if ruby_protocol_declaration_name(node, parent) {
        return false;
    }
    if matches!(
        parent.kind.as_str(),
        "call"
            | "method_parameters"
            | "block_parameters"
            | "argument_list"
            | "assignment"
            | "operator_assignment"
            | "pair"
            | "hash_key_symbol"
    ) {
        return false;
    }
    if matches!(
        raw_next_sibling_text(node, parent).as_deref(),
        Some("=" | "." | ":")
    ) || matches!(
        raw_previous_sibling_text(node, parent).as_deref(),
        Some("=" | "." | ":")
    ) {
        return false;
    }
    true
}

fn ruby_protocol_declaration_name(node: &RawNode, parent: &RawNode) -> bool {
    if matches!(
        parent.kind.as_str(),
        "method" | "singleton_method" | "class" | "module"
    ) {
        return true;
    }
    if parent.kind == "body_statement" {
        let stripped = parent.text.trim_start();
        if stripped.starts_with("def ")
            || stripped.starts_with("class ")
            || stripped.starts_with("module ")
        {
            return true;
        }
    }
    node.kind == "identifier" && parent.kind == "method_parameters"
}

fn ruby_protocol_nested_boundary(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "class" | "module" | "method" | "singleton_method" | "lambda"
    ) || (node.kind == "body_statement"
        && matches!(
            raw_first_child_kind(node).as_deref(),
            Some("def" | "class" | "module")
        ))
}

fn raw_named_children(node: &RawNode) -> Vec<&RawNode> {
    node.children.iter().filter(|child| child.named).collect()
}

fn raw_first_child_kind(node: &RawNode) -> Option<String> {
    node.children.first().map(|child| child.kind.clone())
}

fn raw_next_sibling_text(node: &RawNode, parent: &RawNode) -> Option<String> {
    let index = raw_child_index(node, parent)?;
    parent
        .children
        .get(index + 1)
        .map(|sibling| sibling.text.clone())
}

fn raw_previous_sibling_text(node: &RawNode, parent: &RawNode) -> Option<String> {
    let index = raw_child_index(node, parent)?;
    index
        .checked_sub(1)
        .and_then(|previous| parent.children.get(previous))
        .map(|sibling| sibling.text.clone())
}

fn raw_child_index(node: &RawNode, parent: &RawNode) -> Option<usize> {
    parent.children.iter().position(|child| {
        child.kind == node.kind
            && child.text == node.text
            && child.span == node.span
            && child.named == node.named
    })
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
        || (target.receiver.split_whitespace().count() > 1
            && !ruby_literal_receiver_text(&target.receiver))
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

fn ruby_literal_receiver_text(text: &str) -> bool {
    let value = text.trim();
    (value.starts_with("%w[") || value.starts_with("%i["))
        && value.ends_with(']')
        && !value.contains('\n')
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

fn ruby_sorbet_signature_payload_node(node: Node<'_>, source: &str) -> bool {
    let mut current = Some(node);
    while let Some(candidate) = current {
        if candidate.kind() == "block" {
            let Some(parent) = candidate.parent() else {
                return false;
            };
            if parent.kind() == "call" {
                let message = parent
                    .child_by_field_name("method")
                    .or_else(|| named_children(parent).into_iter().next())
                    .map(|method| node_text(method, source).to_string());
                return message.as_deref() == Some("sig");
            }
            return false;
        }
        if matches!(
            candidate.kind(),
            "method" | "singleton_method" | "class" | "module"
        ) {
            return false;
        }
        current = candidate.parent();
    }
    false
}

fn ruby_call_has_block(node: Node<'_>) -> bool {
    named_children(node)
        .into_iter()
        .any(|child| matches!(child.kind(), "do_block" | "block"))
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
