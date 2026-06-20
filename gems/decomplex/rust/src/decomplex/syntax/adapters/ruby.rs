use super::super::calls;
use super::super::raw_tree::{
    first_child_kind as raw_first_child_kind, named_children as raw_named_children,
    next_sibling as raw_next_sibling, next_sibling_text as raw_next_sibling_text,
    previous_sibling_text as raw_previous_sibling_text,
};
use super::super::tree_sitter_adapter::{
    direct_operator, first_child_kind, first_named_text, named_children, next_sibling_raw_text,
    previous_sibling_raw_text, AssignmentTarget, CallTarget, Target,
};
use super::super::visibility;
use super::super::{
    protocols, semantic_effects, CallSite, Document, FunctionDef, Language, ProtocolMethodEffect,
    ProtocolMethodPath, SemanticEffectSite, StateRead, StateWrite,
};
use super::base::{default_clone_candidate_node, normalize_protocol_state, LanguageProfile};
use super::ruby_data;
use crate::decomplex::ast::{node_text, normalize_text, span, RawNode};
use std::collections::BTreeSet;
use std::path::Path;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) struct RubyProfile;

impl LanguageProfile for RubyProfile {
    fn language(&self) -> Language {
        Language::Ruby
    }

    fn grammar(&self) -> TreeSitterLanguage {
        tree_sitter_ruby::LANGUAGE.into()
    }

    fn report_requires_normalized_root(&self) -> bool {
        false
    }

    fn function_node_kinds(&self) -> &[&str] {
        ruby_data::FUNCTION_NODE_KINDS
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        ruby_data::CLASS_OWNER_NODE_KINDS
    }

    fn module_owner_node_kinds(&self) -> &[&str] {
        ruby_data::MODULE_OWNER_NODE_KINDS
    }

    fn call_node_kinds(&self) -> &[&str] {
        ruby_data::CALL_NODE_KINDS
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        ruby_data::PARAMETER_LIST_NODE_KINDS
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        ruby_data::PARAMETER_IDENTIFIER_NODE_KINDS
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        ruby_data::FUNCTION_BODY_NODE_KINDS
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        ruby_data::NESTED_STATEMENT_WRAPPER_NODE_KINDS
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        ruby_data::IDENTIFIER_NODE_KINDS
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        ruby_data::ASSIGNMENT_NODE_KINDS
    }

    fn indexed_lhs_node_kinds(&self) -> &[&str] {
        ruby_data::INDEXED_LHS_NODE_KINDS
    }

    fn expression_list_node_kinds(&self) -> &[&str] {
        ruby_data::EXPRESSION_LIST_NODE_KINDS
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        ruby_data::ASSIGNMENT_OPERATOR_TOKENS
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        ruby_data::PATH_ACTION_NODE_KINDS
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        ruby_data::SIMPLE_ACTION_WRAPPER_NODE_KINDS
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        ruby_data::COMPARISON_NODE_KINDS
    }

    fn branch_node_kinds(&self) -> &[&str] {
        ruby_data::BRANCH_NODE_KINDS
    }

    fn case_node_kinds(&self) -> &[&str] {
        ruby_data::CASE_NODE_KINDS
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        ruby_data::CASE_ARM_NODE_KINDS
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        ruby_data::CASE_PATTERN_NODE_KINDS
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        ruby_data::CASE_CONTAINER_STOP_NODE_KINDS
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        ruby_data::CASE_SUBJECT_SKIP_NODE_KINDS
    }

    fn default_case_patterns(&self) -> &[&str] {
        ruby_data::DEFAULT_CASE_PATTERNS
    }

    fn boolean_and_operators(&self) -> &[&str] {
        ruby_data::BOOLEAN_AND_OPERATORS
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        ruby_data::BOOLEAN_CONTAINER_NODE_KINDS
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        ruby_data::BOOLEAN_WRAPPER_NODE_KINDS
    }

    fn accessor_call_node_kinds(&self) -> &[&str] {
        ruby_data::ACCESSOR_CALL_NODE_KINDS
    }

    fn argument_list_node_kinds(&self) -> &[&str] {
        ruby_data::ARGUMENT_LIST_NODE_KINDS
    }

    fn block_argument_node_kinds(&self) -> &[&str] {
        ruby_data::BLOCK_ARGUMENT_NODE_KINDS
    }

    fn branch_nested_scope_node_kinds(&self) -> &[&str] {
        ruby_data::BRANCH_NESTED_SCOPE_NODE_KINDS
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if node.kind() == "call" && ruby_single_command_argument_call(node, source) {
            return None;
        }
        let mut target = match node.kind() {
            "call" => {
                ruby_proc_call_target(node, source).or_else(|| ruby_call_target(node, source))
            }
            "body_statement" | "block_body" => ruby_bare_body_call_target(node, source),
            "identifier" => ruby_visibility_identifier_call_target(node, source)
                .or_else(|| ruby_bare_call_target(node, source)),
            _ => None,
        }?;
        if ruby_whole_body_implicit_self_chain(node, source) {
            return None;
        }
        if target.arguments.is_empty() && !ruby_call_has_block(node) {
            if let Some(span) = calls::narrow_no_arg_call_span(
                node,
                source,
                &target.receiver,
                &target.message,
                true,
            ) {
                target.span = Some(span);
            }
        }
        if ruby_chained_element_predicate_target(&target) {
            return None;
        }
        if ruby_sorbet_signature_chain_target(node, source, &target) {
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

    fn single_expression_body<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        let mut cursor = node.walk();
        if node.children(&mut cursor).any(|child| {
            self.expression_body_operator_tokens()
                .contains(&child.kind())
        }) {
            return named_children(node).last().copied();
        }

        let body = node.child_by_field_name("body").or_else(|| {
            named_children(node)
                .into_iter()
                .rev()
                .find(|child| self.function_body_node_kinds().contains(&child.kind()))
        })?;
        let named = named_children(body)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if named.len() == 1 {
            return named.first().copied();
        }

        let operator = direct_operator(body);
        if body.kind() == "body_statement"
            && self.comparison_operators().contains(&operator.as_str())
        {
            return Some(body);
        }

        None
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
                && ruby_data::VISIBILITY_DIRECTIVES.contains(&target.message.as_str())
            {
                return Some(target.message);
            }
        }
        None
    }

    fn after_collect_facts(&self, functions: &mut Vec<FunctionDef>, calls: &[CallSite]) {
        visibility::apply_visibility(functions, calls, self);
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
        protocols::method_effects(document, self)
    }

    fn protocol_call_paths(&self, document: &Document) -> Vec<ProtocolMethodPath> {
        protocols::call_paths(document, self)
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
        let target = ruby_state_variable_target(node, source)
            .or_else(|| self.default_state_read_target(node, source))?;
        if ruby_whole_body_implicit_self_chain(node, source) {
            return None;
        }
        if ruby_direct_flat_map_block_statement(node, source) {
            return None;
        }
        if ruby_sorbet_signature_payload_node(node, source) {
            return None;
        }
        if ruby_chained_element_predicate_read_target(&target) {
            return None;
        }
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

    fn clone_candidate_node(&self, node: &RawNode) -> bool {
        if ruby_state_assignment_node(node) {
            return false;
        }
        default_clone_candidate_node(node)
    }

    fn clone_fingerprint_children<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode> {
        if node.kind == "body_statement" {
            let named = raw_named_children(node);
            if named.len() == 1 && ruby_state_assignment_node(named[0]) {
                return named[0].children.iter().collect();
            }
        }
        node.children.iter().collect()
    }
}

impl protocols::RawProtocolAdapter for RubyProfile {
    fn method_body_statements<'a>(&self, body: &'a RawNode) -> Vec<&'a RawNode> {
        protocols::function_body_statements(
            body,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_hidden_method_definition,
            ruby_raw_flat_assignment_statement,
            ruby_raw_hidden_modifier_if,
            ruby_raw_heredoc_body,
        )
    }

    fn local_bindings(&self, node: &RawNode) -> Vec<String> {
        protocols::local_bindings(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_simple_call_text,
            ruby_raw_flat_assignment_statement,
        )
    }

    fn nested_boundary(&self, node: &RawNode) -> bool {
        protocols::nested_boundary(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn assignment_parts<'a>(
        &self,
        node: &'a RawNode,
    ) -> Option<(&'a RawNode, Option<&'a RawNode>)> {
        protocols::assignment_parts(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_flat_assignment_statement,
        )
    }

    fn operator_assignment_parts<'a>(
        &self,
        node: &'a RawNode,
    ) -> Option<(&'a RawNode, Option<&'a RawNode>)> {
        protocols::operator_assignment_parts(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn state_target(&self, node: &RawNode, local_names: &BTreeSet<String>) -> Option<String> {
        ruby_protocol_state_target(node, local_names)
    }

    fn direct_state_read(&self, node: &RawNode) -> Option<String> {
        ruby_data::PROTOCOL_SHAPE
            .direct_state_read_kinds
            .contains(&node.kind.as_str())
            .then(|| normalize_protocol_state(&node.text))
    }

    fn collect_call_state(
        &self,
        node: &RawNode,
        local_names: &BTreeSet<String>,
        reads: &mut BTreeSet<String>,
        writes: &mut BTreeSet<String>,
    ) {
        ruby_protocol_collect_call_state(node, local_names, reads, writes);
    }

    fn bare_state_reader(
        &self,
        node: &RawNode,
        parent: Option<&RawNode>,
        local_names: &BTreeSet<String>,
    ) -> Option<String> {
        if node.kind != "identifier" {
            return None;
        }
        ruby_protocol_bare_reader(node, parent, local_names)
            .then(|| normalize_protocol_state(&node.text))
    }

    fn branch_node(&self, node: &RawNode) -> bool {
        protocols::branch_node(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_hidden_modifier_if,
        )
    }

    fn case_node(&self, node: &RawNode) -> bool {
        protocols::case_node(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn path_condition<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode> {
        protocols::path_condition(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_hidden_modifier_if,
        )
    }

    fn then_body<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode> {
        protocols::then_body(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_hidden_modifier_if,
        )
    }

    fn else_body<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode> {
        protocols::else_body(
            node,
            &ruby_data::PROTOCOL_SHAPE,
            ruby_raw_hidden_modifier_if,
        )
    }

    fn case_subject<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode> {
        protocols::case_subject(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn case_branch_bodies<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode> {
        protocols::case_branch_bodies(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn statement_body<'a>(&self, node: &'a RawNode) -> Option<Vec<&'a RawNode>> {
        protocols::statement_body(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn path_child_nodes<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode> {
        protocols::path_child_nodes(node, &ruby_data::PROTOCOL_SHAPE)
    }

    fn internal_call(&self, node: &RawNode, local_names: &BTreeSet<String>) -> Option<String> {
        ruby_protocol_internal_call(node, local_names)
    }

    fn terminal_node(&self, node: &RawNode) -> bool {
        protocols::terminal_node(node, &ruby_data::PROTOCOL_SHAPE)
    }
}

impl visibility::VisibilityAdapter for RubyProfile {
    fn visibility_call(&self, call: &CallSite) -> bool {
        ruby_visibility_call(call)
    }

    fn visibility_arg_name(&self, argument: &str) -> String {
        ruby_visibility_arg_name(argument)
    }
}

fn ruby_state_assignment_node(node: &RawNode) -> bool {
    if !matches!(node.kind.as_str(), "assignment" | "operator_assignment") {
        return false;
    }
    raw_named_children(node)
        .first()
        .map(|lhs| matches!(lhs.kind.as_str(), "instance_variable" | "global_variable"))
        .unwrap_or(false)
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
    calls::receiver_message_call_target(
        node,
        source,
        &ruby_data::CALL_SHAPE,
        |node, source, receiver, _method| {
            let text = normalize_text(node_text(node, source));
            (receiver.is_none() && ruby_simple_call_text(&text)).then_some(text)
        },
        |node, source, message| {
            if ruby_require_message(message) {
                ruby_require_argument_texts(node, source)
            } else {
                ruby_argument_texts(node, source)
            }
        },
        ruby_safe_navigation_call,
        ruby_call_has_block,
    )
}

fn ruby_implicit_self_call_receiver(node: Node<'_>, source: &str) -> bool {
    let Some(receiver) = node.child_by_field_name("receiver") else {
        return false;
    };
    if receiver.kind() != "call" || receiver.child_by_field_name("receiver").is_some() {
        return false;
    }
    let message = receiver
        .child_by_field_name("method")
        .or_else(|| named_children(receiver).into_iter().next())
        .map(|method| node_text(method, source).to_string());
    let Some(message) = message else {
        return false;
    };
    ruby_simple_call_text(&message)
        && message
            .chars()
            .next()
            .map(|ch| ch.is_ascii_lowercase() || ch == '_')
            .unwrap_or(false)
}

fn ruby_whole_body_implicit_self_chain(node: Node<'_>, source: &str) -> bool {
    if !ruby_implicit_self_call_receiver(node, source) {
        return false;
    }
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "body_statement" {
        return false;
    }
    let named = named_children(parent)
        .into_iter()
        .filter(|child| child.kind() != "comment")
        .collect::<Vec<_>>();
    named.len() == 1 && named.first().copied() == Some(node)
}

fn ruby_visibility_call(call: &CallSite) -> bool {
    call.function == "(top-level)"
        && call.receiver == "self"
        && ruby_data::VISIBILITY_DIRECTIVES.contains(&call.message.as_str())
}

fn ruby_visibility_identifier_call_target<'tree>(
    node: Node<'tree>,
    source: &str,
) -> Option<CallTarget<'tree>> {
    let message = node_text(node, source);
    if !ruby_data::VISIBILITY_DIRECTIVES.contains(&message) {
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
        || ruby_data::BARE_BODY_NON_CALL_MESSAGES.contains(&message.as_str())
    {
        return None;
    }
    Some(CallTarget::new("self".to_string(), message, Vec::new()))
}

fn ruby_explicit_receiver_body_call_target<'tree>(
    node: Node<'tree>,
    source: &str,
) -> Option<CallTarget<'tree>> {
    let mut cursor = node.walk();
    if !node
        .children(&mut cursor)
        .any(|child| !child.is_named() && node_text(child, source) == ".")
    {
        return None;
    }
    let children = named_children(node);
    let receiver = *children.first()?;
    let message = *children.get(1)?;
    if !matches!(receiver.kind(), "self" | "constant" | "identifier")
        && !ruby_constant_constructor_call(receiver, source)
    {
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

fn ruby_constant_constructor_call(node: Node<'_>, source: &str) -> bool {
    if node.kind() != "call" {
        return false;
    }
    let receiver = node
        .child_by_field_name("receiver")
        .or_else(|| named_children(node).into_iter().next());
    let method = node
        .child_by_field_name("method")
        .or_else(|| named_children(node).into_iter().nth(1));
    receiver
        .map(|receiver| receiver.kind() == "constant")
        .unwrap_or(false)
        && method
            .map(|method| node_text(method, source) == "new")
            .unwrap_or(false)
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
    let args = calls::argument_list_node(node, "argument_list")?;
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
    calls::argument_texts(node, source, "argument_list", |args, source| {
        ruby_inline_def_argument_texts(args, source)
            .or_else(|| ruby_single_command_call_argument_texts(args, source))
    })
}

fn ruby_single_command_call_argument_texts(args: Node<'_>, source: &str) -> Option<Vec<String>> {
    if node_text(args, source).trim_start().starts_with('(') {
        return None;
    }
    let children = named_children(args);
    if children.len() != 1 || children[0].kind() != "call" {
        return None;
    }
    let values = named_children(children[0])
        .into_iter()
        .map(|part| normalize_text(node_text(part, source)))
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    (!values.is_empty()).then_some(values)
}

fn ruby_require_argument_texts(node: Node<'_>, source: &str) -> Vec<String> {
    let Some(args) = calls::argument_list_node(node, "argument_list") else {
        return Vec::new();
    };
    let children = named_children(args);
    if children.len() == 1 {
        let child = children[0];
        if child.kind() == "string" && !node_text(args, source).trim_start().starts_with('(') {
            return vec![ruby_unquoted_string_text(child, source)];
        }
        if child.kind() == "call" && !node_text(args, source).trim_start().starts_with('(') {
            return named_children(child)
                .into_iter()
                .map(|part| normalize_text(node_text(part, source)))
                .filter(|part| !part.is_empty())
                .collect();
        }
    }
    children
        .into_iter()
        .map(|child| normalize_text(node_text(child, source)))
        .filter(|part| !part.is_empty())
        .collect()
}

fn ruby_unquoted_string_text(node: Node<'_>, source: &str) -> String {
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
    text
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
    out.extend(semantic_effects::external_state_mutation_effects(
        state_writes,
    ));
    out.extend(semantic_effects::method_hook_effects(
        functions,
        ruby_data::METHOD_HOOKS,
    ));
    out.extend(semantic_effects::collect_structural_effect_nodes(
        root,
        source,
        &file_name,
        functions,
        ruby_structural_effect_for_node,
    ));
    out
}

fn ruby_global_context_effects(source: &str, state_reads: &[StateRead]) -> Vec<SemanticEffectSite> {
    semantic_effects::state_read_context_dependencies(state_reads, |read| {
        read.field.starts_with('$') && !ruby_global_assignment_read(source, read)
    })
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

fn ruby_structural_effect_for_node(
    node: Node<'_>,
    source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    if let Some(effect) = semantic_effects::static_node_effect(
        node,
        file,
        functions,
        ruby_data::STATIC_SEMANTIC_EFFECTS,
    ) {
        return vec![effect];
    }
    match node.kind() {
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
    vec![semantic_effects::site(
        node,
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
    vec![semantic_effects::site(
        node,
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
        out.push(semantic_effects::site(
            node,
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
            out.push(semantic_effects::site(
                node,
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
    _source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let lhs = node
        .child_by_field_name("left")
        .or_else(|| named_children(node).into_iter().next());
    if ruby_local_operator_assignment_lhs(lhs) {
        return Vec::new();
    }
    vec![semantic_effects::site(
        node,
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
    _source: &str,
    file: &str,
    functions: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    if direct_operator(node) != "<<" {
        return Vec::new();
    }
    vec![semantic_effects::site(
        node,
        file,
        functions,
        "hidden_mutation",
        "<<",
    )]
}

fn ruby_safe_navigation_call(node: Node<'_>, source: &str) -> bool {
    let mut cursor = node.walk();
    let found = node
        .children(&mut cursor)
        .any(|child| !child.is_named() && node_text(child, source) == "&.");
    found
}

fn ruby_simple_call_text(text: &str) -> bool {
    calls::identifier_like(text.trim(), true)
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
    if parent.kind() == "operator_assignment" {
        return ruby_operator_assignment_rhs_bare_call(node, parent, source);
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
        "body_statement"
            | "then"
            | "else"
            | "elsif"
            | "ensure"
            | "rescue"
            | "if_modifier"
            | "unless_modifier"
    ) || node
        .next_sibling()
        .map(|sibling| sibling.kind() == "argument_list")
        .unwrap_or(false)
}

fn ruby_operator_assignment_rhs_bare_call(node: Node<'_>, parent: Node<'_>, source: &str) -> bool {
    let children = named_children(parent);
    if children.get(1).copied() != Some(node) || !ruby_simple_call_text(node_text(node, source)) {
        return false;
    }
    let Some(grandparent) = parent.parent() else {
        return false;
    };
    if grandparent.kind() != "body_statement" {
        return false;
    }
    let named = named_children(grandparent)
        .into_iter()
        .filter(|child| child.kind() != "comment")
        .collect::<Vec<_>>();
    named.len() == 1 && named.first().copied() == Some(parent)
}

fn ruby_protocol_collect_call_state(
    node: &RawNode,
    local_names: &BTreeSet<String>,
    reads: &mut BTreeSet<String>,
    writes: &mut BTreeSet<String>,
) {
    let Some(target) = ruby_raw_call_target(node) else {
        return;
    };
    if target.receiver == "self"
        && target.arguments.is_empty()
        && !ruby_raw_unparenthesized_call_has_arguments(node)
        && !ruby_protocol_mutating_mid(&target.message)
        && !ruby_data::PROTOCOL_IGNORED_MIDS.contains(&target.message.as_str())
    {
        reads.insert(normalize_protocol_state(&target.message));
    }
    if ruby_protocol_mutating_mid(&target.message) {
        if let Some(token) = ruby_protocol_receiver_state_token(&target.receiver, local_names) {
            writes.insert(token);
        }
    }
}

fn ruby_raw_unparenthesized_call_has_arguments(node: &RawNode) -> bool {
    raw_named_children(node)
        .into_iter()
        .any(|child| child.kind == "argument_list" && !child.text.trim_start().starts_with('('))
}

fn ruby_protocol_state_target(node: &RawNode, local_names: &BTreeSet<String>) -> Option<String> {
    match node.kind.as_str() {
        "instance_variable" => Some(normalize_protocol_state(&node.text)),
        "element_reference" => raw_named_children(node)
            .first()
            .and_then(|receiver| ruby_protocol_receiver_state_token(&receiver.text, local_names)),
        "call" => {
            let target = ruby_raw_call_target(node)?;
            let receiver = ruby_protocol_receiver_state_token(&target.receiver, local_names)?;
            let field = normalize_protocol_state(&target.message);
            if receiver == "self" {
                Some(field)
            } else {
                Some(format!("{receiver}.{field}"))
            }
        }
        _ => None,
    }
}

fn ruby_protocol_receiver_state_token(
    receiver: &str,
    local_names: &BTreeSet<String>,
) -> Option<String> {
    let text = receiver.trim();
    if text.is_empty() {
        return None;
    }
    if text == "self" {
        return Some("self".to_string());
    }
    if text.starts_with('@') {
        return Some(normalize_protocol_state(text));
    }
    if ruby_simple_call_text(text) {
        if local_names.contains(text) {
            None
        } else {
            Some(normalize_protocol_state(text))
        }
    } else {
        None
    }
}

fn ruby_protocol_internal_call(node: &RawNode, local_names: &BTreeSet<String>) -> Option<String> {
    let target = if node.kind == "call" {
        ruby_raw_call_target(node)
    } else if node.kind == "identifier" && ruby_protocol_bare_internal_identifier(node, local_names)
    {
        Some(protocols::RawCallTarget {
            receiver: "self".to_string(),
            message: node.text.clone(),
            arguments: Vec::new(),
        })
    } else {
        None
    }?;
    if target.receiver != "self" {
        return None;
    }
    if local_names.contains(&target.message)
        || ruby_data::PROTOCOL_IGNORED_MIDS.contains(&target.message.as_str())
    {
        return None;
    }
    Some(target.message)
}

fn ruby_protocol_mutating_mid(mid: &str) -> bool {
    !ruby_data::PROTOCOL_NON_MUTATING_OPERATOR_MIDS.contains(&mid)
        && (ruby_data::PROTOCOL_MUTATING_MIDS.contains(&mid) || mid.ends_with('!'))
}

fn ruby_protocol_bare_internal_identifier(node: &RawNode, local_names: &BTreeSet<String>) -> bool {
    ruby_simple_call_text(&node.text)
        && !local_names.contains(&node.text)
        && !ruby_data::PROTOCOL_IGNORED_MIDS.contains(&node.text.as_str())
}

fn ruby_raw_call_target(node: &RawNode) -> Option<protocols::RawCallTarget> {
    let mut target = protocols::raw_call_target(node, &ruby_data::RAW_CALL_SHAPE)?;
    if target.receiver == "self" && target.arguments.is_empty() {
        let named = raw_named_children(node);
        if named.len() > 1
            && named
                .first()
                .map(|child| child.text.as_str() == target.message)
                .unwrap_or(false)
        {
            target.arguments = named
                .into_iter()
                .skip(1)
                .map(|child| normalize_text(&child.text))
                .filter(|argument| !argument.is_empty())
                .collect();
        }
    }
    Some(target)
}

fn ruby_raw_heredoc_body(named: &[&RawNode]) -> bool {
    named.first().map(|child| child.kind.as_str()) == Some("call")
        && named
            .iter()
            .skip(1)
            .all(|child| child.kind == "heredoc_body")
}

fn ruby_raw_flat_assignment_statement(node: &RawNode) -> bool {
    node.kind == "body_statement"
        && node
            .children
            .iter()
            .filter(|child| !child.named && child.text == "=")
            .count()
            == 1
        && raw_named_children(node).len() >= 2
}

fn ruby_raw_hidden_modifier_if(node: &RawNode) -> bool {
    if node.kind != "body_statement" {
        return false;
    }
    let mut seen_named = false;
    node.children.iter().any(|child| {
        seen_named |= child.named;
        seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless")
    })
}

fn ruby_raw_hidden_method_definition(node: &RawNode) -> bool {
    node.kind == "body_statement" && matches!(raw_first_child_kind(node).as_deref(), Some("def"))
}

fn ruby_protocol_bare_reader(
    node: &RawNode,
    parent: Option<&RawNode>,
    local_names: &BTreeSet<String>,
) -> bool {
    let name = node.text.as_str();
    if !ruby_simple_call_text(name)
        || local_names.contains(name)
        || ruby_data::PROTOCOL_IGNORED_MIDS.contains(&name)
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
    if raw_next_sibling(node, parent)
        .map(|sibling| sibling.kind == "argument_list")
        .unwrap_or(false)
    {
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

fn ruby_single_command_argument_call(node: Node<'_>, source: &str) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.kind() != "argument_list" || node_text(parent, source).trim_start().starts_with('(') {
        return false;
    }
    let children = named_children(parent);
    children.len() == 1 && children[0] == node
}

fn ruby_require_message(message: &str) -> bool {
    ruby_data::REQUIRE_MESSAGES.contains(&message)
}

fn ruby_embedded_text_node(node: Node<'_>) -> bool {
    let mut current = Some(node);
    while let Some(node) = current {
        if ruby_data::EMBEDDED_TEXT_NODE_KINDS.contains(&node.kind()) {
            return true;
        }
        current = node.parent();
    }
    false
}

fn ruby_valid_call_target(target: &CallTarget<'_>) -> bool {
    if calls::invalid_message_text(&target.message) {
        return false;
    }
    if matches!(target.message.as_str(), "[]" | "[]=") {
        return true;
    }
    calls::identifier_like(target.message.as_str(), false)
}

fn ruby_state_variable_target(node: Node<'_>, source: &str) -> Option<Target> {
    if !matches!(node.kind(), "instance_variable" | "global_variable") {
        return None;
    }
    if ruby_embedded_text_node(node) {
        return None;
    }
    Some(Target {
        receiver: "self".to_string(),
        field: node_text(node, source).to_string(),
    })
}

fn ruby_chained_element_predicate_target(target: &CallTarget<'_>) -> bool {
    ruby_chained_element_predicate(&target.receiver, &target.message)
}

fn ruby_chained_element_predicate_read_target(target: &Target) -> bool {
    ruby_chained_element_predicate(&target.receiver, &target.field)
}

fn ruby_chained_element_predicate(receiver: &str, message: &str) -> bool {
    message.ends_with('?')
        && receiver.contains('.')
        && (receiver.contains("[:") || receiver.contains("[\"") || receiver.contains("['"))
}

fn ruby_sorbet_signature_chain_target(
    node: Node<'_>,
    source: &str,
    target: &CallTarget<'_>,
) -> bool {
    ruby_sorbet_signature_payload_node(node, source) && target.receiver != "self"
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
