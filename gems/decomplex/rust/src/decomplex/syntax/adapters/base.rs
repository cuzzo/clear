use super::super::tree_sitter_adapter::{
    first_named_child, first_named_child_except, first_named_child_with_kind, first_named_text,
    named_children, normalize_type_owner, strip_assignment_suffix, AssignmentTarget, CallTarget,
    Target,
};
use super::super::{
    CallSite, CloneCandidate, Document, FunctionDef, Language, ProtocolCall, ProtocolMethodEffect,
    ProtocolMethodPath, SemanticEffectSite, StateRead, StateWrite,
};
use crate::decomplex::ast::{node_text, normalize_text, span, RawNode};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use tree_sitter::{Language as TreeSitterLanguage, Node};

pub(crate) const EMPTY_NODE_KINDS: &[&str] = &[];
pub(crate) const DEFAULT_COMPARISON_OPERATORS: &[&str] = &["==", "!="];
pub(crate) const DEFAULT_EXPRESSION_BODY_OPERATOR_TOKENS: &[&str] = &["="];
pub(crate) const DEFAULT_IGNORED_STATEMENT_NODE_KINDS: &[&str] = &["comment", "heredoc_body"];
const CLONE_IDENTIFIER_KINDS: &[&str] = &[
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "shorthand_property_identifier_pattern",
    "simple_identifier",
    "variable_name",
];
const CLONE_LITERAL_KINDS: &[&str] = &[
    "string",
    "string_content",
    "string_literal",
    "interpreted_string_literal",
    "raw_string_literal",
    "integer",
    "float",
    "int",
    "number",
    "rational",
    "imaginary",
    "character",
    "char_literal",
    "symbol",
    "simple_symbol",
    "true",
    "false",
    "nil",
    "none",
    "null",
];
const CLONE_SKIP_KINDS: &[&str] = &[
    "comment",
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "parameters",
    "formal_parameters",
    "parameter_list",
    "argument_list",
    "arguments",
    "block_parameters",
    "call_suffix",
    "function_value_parameters",
    "method_parameters",
    "value_argument",
    "scope_resolution",
];
const CLONE_CANDIDATE_KINDS: &[&str] = &[
    "array",
    "assignment",
    "assignment_statement",
    "block",
    "case",
    "case_clause",
    "class",
    "class_definition",
    "class_declaration",
    "compound_statement",
    "conjunction_expression",
    "control_structure_body",
    "do_block",
    "enum_declaration",
    "for",
    "for_statement",
    "function_body",
    "hash",
    "if",
    "if_statement",
    "match_expression",
    "match_statement",
    "method",
    "method_definition",
    "module",
    "operator_assignment",
    "singleton_method",
    "statements",
    "struct_declaration",
    "switch_case",
    "switch_expression",
    "switch_statement",
    "unless",
    "until",
    "while",
    "while_statement",
];
const CLONE_BODY_KINDS: &[&str] = &[
    "body",
    "block",
    "body_statement",
    "declaration_list",
    "statement_block",
    "compound_statement",
    "function_body",
    "statements",
    "suite",
    "do_block",
];
const CLONE_CALL_KINDS: &[&str] = &[
    "call",
    "call_expression",
    "function_call",
    "method_call",
    "method_invocation",
    "invocation_expression",
];
const NOISE_MESSAGES: &[&str] = &[
    "!", "!=", "==", "===", "<", "<=", ">", ">=", "[]", "[]=", "to_s", "inspect", "class",
];

pub(crate) trait LanguageProfile {
    fn language(&self) -> Language;
    fn grammar(&self) -> TreeSitterLanguage;

    fn report_requires_normalized_root(&self) -> bool {
        true
    }

    fn function_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn class_owner_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn module_owner_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn generic_owner_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn impl_owner_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn struct_owner_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn call_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn parameter_list_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn parameter_identifier_node_kinds(&self) -> &[&str] {
        self.identifier_node_kinds()
    }

    fn inline_parameter_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn function_body_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn nested_statement_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn local_flow_statement_expansion_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn identifier_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn normalize_local_identifier_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn field_identifier_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn assignment_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn assignment_operator_tokens(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn local_identifier_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn indexed_lhs_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn indexed_lhs_bracket_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn update_statement_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn local_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn short_variable_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn variable_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn local_variable_declarator_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn multi_name_variable_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn field_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn declaration_site_parent_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn assignment_state_declaration_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn declaration_assignment_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn receiver_type_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn method_receiver_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn receiver_parameter_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn first_argument_receiver_type_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn first_argument_receiver_name_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn comparison_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn comparison_operators(&self) -> &[&str] {
        DEFAULT_COMPARISON_OPERATORS
    }

    fn branch_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn decision_enclosing_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_arm_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_pattern_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_subject_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_container_stop_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn case_subject_skip_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn default_case_patterns(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn boolean_and_operators(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn boolean_container_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn boolean_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn parenthesized_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn accessor_call_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn expression_list_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn argument_list_node_kinds(&self) -> &[&str] {
        &[
            "argument_list",
            "arguments",
            "call_suffix",
            "value_arguments",
        ]
    }

    fn block_argument_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn branch_nested_scope_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn navigation_suffix_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn field_like_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn field_like_dot_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn keyed_element_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn deferred_statement_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn suppress_field_receiver_lhs_reads(&self) -> bool {
        false
    }

    fn suppress_indexed_lhs_reads(&self) -> bool {
        true
    }

    fn indexed_lhs_descendants_are_writes(&self) -> bool {
        true
    }

    fn keyed_element_first_named_child_is_key(&self) -> bool {
        true
    }

    fn nested_assignment_dependencies_only(&self) -> bool {
        false
    }

    fn implicit_state_accesses(&self) -> bool {
        false
    }

    fn path_action_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn simple_action_wrapper_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn path_transparent_branch_body_node_kinds(&self) -> &[&str] {
        EMPTY_NODE_KINDS
    }

    fn expression_body_operator_tokens(&self) -> &[&str] {
        DEFAULT_EXPRESSION_BODY_OPERATOR_TOKENS
    }

    fn ignored_statement_node_kinds(&self) -> &[&str] {
        DEFAULT_IGNORED_STATEMENT_NODE_KINDS
    }

    fn first_argument_receiver(&self) -> bool {
        false
    }

    fn function_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        self.default_function_name(node, source)
    }

    fn function_visibility(&self, _node: Node<'_>, _source: &str) -> Option<String> {
        None
    }

    fn function_params(&self, node: Node<'_>, source: &str) -> Vec<String> {
        let param_nodes = if let Some(params) = self.function_parameter_list(node) {
            named_children(params)
        } else {
            named_children(node)
                .into_iter()
                .filter(|child| self.inline_parameter_node_kinds().contains(&child.kind()))
                .collect()
        };
        let mut out = Vec::new();
        for param in param_nodes {
            if let Some(name) = self.parameter_name(param, source) {
                if !out.contains(&name) {
                    out.push(name);
                }
            }
        }
        out
    }

    fn after_collect_facts(&self, _functions: &mut Vec<FunctionDef>, _calls: &[CallSite]) {}

    fn structural_semantic_effect_sites(
        &self,
        _root: Node<'_>,
        _source: &str,
        _file: &Path,
        _functions: &[FunctionDef],
        _state_reads: &[StateRead],
        _state_writes: &[StateWrite],
    ) -> Vec<SemanticEffectSite> {
        Vec::new()
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

    fn protocol_call_paths(&self, document: &Document) -> Vec<ProtocolMethodPath> {
        document
            .function_defs
            .iter()
            .map(|function_def| {
                let calls = document
                    .call_sites
                    .iter()
                    .filter(|call| {
                        call.owner == function_def.owner
                            && call.function == function_def.name
                            && call.receiver == "self"
                    })
                    .map(|call| ProtocolCall {
                        mid: protocol_method_name(&call.message),
                        file: function_def.file.clone(),
                        owner: function_def.owner.clone(),
                        defn: protocol_method_name(&function_def.name),
                        line: call.line,
                        span: call.span,
                    })
                    .collect();

                ProtocolMethodPath {
                    file: function_def.file.clone(),
                    owner: function_def.owner.clone(),
                    name: protocol_method_name(&function_def.name),
                    line: function_def.line,
                    calls,
                }
            })
            .collect()
    }

    fn default_function_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if !self.function_node_kinds().contains(&node.kind()) {
            return None;
        }

        node.child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| self.declarator_name(node.child_by_field_name("declarator"), source))
            .or_else(|| self.first_identifier_text(node, source))
    }

    fn owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        self.default_owner_name_from_declaration(node, source)
    }

    fn owner_def_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        self.owner_name_from_declaration(node, source)
    }

    fn owner_kind(&self, node: Node<'_>) -> String {
        if self.class_owner_node_kinds().contains(&node.kind()) {
            "class".to_string()
        } else if self.module_owner_node_kinds().contains(&node.kind()) {
            "module".to_string()
        } else if self.impl_owner_node_kinds().contains(&node.kind()) {
            "impl".to_string()
        } else if self.struct_owner_node_kinds().contains(&node.kind()) {
            "struct".to_string()
        } else {
            "owner".to_string()
        }
    }

    fn default_owner_name_from_declaration(&self, node: Node<'_>, source: &str) -> Option<String> {
        if self.class_owner_node_kinds().contains(&node.kind())
            || self.module_owner_node_kinds().contains(&node.kind())
            || self.generic_owner_node_kinds().contains(&node.kind())
            || self.struct_owner_node_kinds().contains(&node.kind())
        {
            return node
                .child_by_field_name("name")
                .map(|name| node_text(name, source).to_string())
                .or_else(|| self.first_identifier_text(node, source));
        }
        if self.impl_owner_node_kinds().contains(&node.kind()) {
            return self.impl_owner_name(node, source);
        }
        None
    }

    fn generated_prelude(&self, _node: Node<'_>, _source: &str) -> bool {
        false
    }

    fn control_context(&self, node: Node<'_>, source: &str) -> Option<String> {
        if generic_loop_context(node, source) {
            Some("iterates".to_string())
        } else if generic_branch_context(node, source) {
            Some("conditional".to_string())
        } else {
            None
        }
    }

    fn normalize_source_text(&self, text: &str) -> String {
        normalize_text(text)
    }

    fn hidden_case(&self, _node: Node<'_>) -> bool {
        false
    }

    fn hidden_case_source_node<'tree>(&self, _node: Node<'tree>) -> Option<Node<'tree>> {
        None
    }

    fn case_source_node<'tree>(&self, node: Node<'tree>) -> Node<'tree> {
        if self.hidden_case(node) {
            self.hidden_case_source_node(node).unwrap_or(node)
        } else {
            node
        }
    }

    fn predicate_less_case(&self, node: Node<'_>) -> bool {
        self.case_node_kinds().contains(&node.kind()) && self.decision_subject(node).is_none()
    }

    fn case_pattern_texts(&self, patterns: &[Node<'_>], source: &str) -> Vec<String> {
        patterns
            .iter()
            .map(|pattern| normalize_text(node_text(*pattern, source)))
            .collect()
    }

    fn receiver_convention_owner_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if !self.first_argument_receiver() || !self.function_node_kinds().contains(&node.kind()) {
            return None;
        }

        let (type_name, _) = self.first_argument_receiver_parameter(node, source)?;
        let type_name = normalize_type_owner(&type_name);
        let name = self.function_name(node, source)?;
        if type_name.is_empty() || name.is_empty() {
            return None;
        }

        let prefix = snake_case_type_name(&type_name);
        if name.starts_with(&format!("{prefix}_")) {
            Some(type_name)
        } else {
            None
        }
    }

    fn function_receiver_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        if self.first_argument_receiver() && self.function_node_kinds().contains(&node.kind()) {
            if let Some((_, name)) = self.first_argument_receiver_parameter(node, source) {
                return Some(name);
            }
        }
        None
    }

    fn single_expression_body<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        let mut cursor = node.walk();
        if node.children(&mut cursor).any(|child| {
            self.expression_body_operator_tokens()
                .contains(&child.kind())
        }) {
            let named = named_children(node);
            return named.last().copied();
        }

        let body = node.child_by_field_name("body").or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| self.function_body_node_kinds().contains(&child.kind()))
        })?;
        let mut statements: Vec<Node<'_>> = named_children(body)
            .into_iter()
            .filter(|child| !self.ignored_statement_node_kinds().contains(&child.kind()))
            .collect();
        if statements.len() == 1
            && self
                .nested_statement_wrapper_node_kinds()
                .contains(&statements[0].kind())
        {
            statements = named_children(statements[0])
                .into_iter()
                .filter(|child| !self.ignored_statement_node_kinds().contains(&child.kind()))
                .collect();
        }
        statements.last().copied()
    }

    fn call_target<'tree>(&self, node: Node<'tree>, source: &str) -> Option<CallTarget<'tree>> {
        if self.call_node_kinds().contains(&node.kind()) {
            self.default_call_target(node, source)
        } else {
            None
        }
    }

    fn default_call_target<'tree>(
        &self,
        node: Node<'tree>,
        source: &str,
    ) -> Option<CallTarget<'tree>> {
        let callee = if self.field_like_node_kinds().contains(&node.kind()) {
            node
        } else {
            node.child_by_field_name("function")
                .or_else(|| node.child_by_field_name("callee"))
                .or_else(|| first_named_child(node))?
        };
        if callee.kind() == "builtin_function" || node_text(callee, source).starts_with('@') {
            return None;
        }

        let (receiver, message) = self.target_from_callee(callee, source)?;
        let mut target = CallTarget::new(receiver, message, self.call_argument_texts(node, source));
        if let Some(receiver) = self.first_argument_receiver_call_receiver(node, source, &target) {
            target.receiver = receiver;
        }
        Some(target)
    }

    fn first_argument_receiver_call_receiver(
        &self,
        node: Node<'_>,
        source: &str,
        target: &CallTarget<'_>,
    ) -> Option<String> {
        if !self.first_argument_receiver() || target.receiver != "self" {
            return None;
        }
        let first_arg = self.call_argument_nodes(node).first().copied()?;
        let arg_target = self.state_read_target(first_arg, source)?;
        Some(format!("{}.{}", arg_target.receiver, arg_target.field))
    }

    fn target_from_callee(&self, callee: Node<'_>, source: &str) -> Option<(String, String)> {
        if self.field_like_node_kinds().contains(&callee.kind()) {
            let object = callee
                .child_by_field_name("object")
                .or_else(|| callee.child_by_field_name("receiver"))
                .or_else(|| callee.child_by_field_name("operand"))
                .or_else(|| callee.child_by_field_name("value"))
                .or_else(|| callee.child_by_field_name("expression"))
                .or_else(|| first_named_child_except(callee, "navigation_suffix"))?;
            let field = callee
                .child_by_field_name("field")
                .or_else(|| callee.child_by_field_name("property"))
                .or_else(|| callee.child_by_field_name("name"))
                .or_else(|| callee.child_by_field_name("suffix"))
                .or_else(|| first_named_child_with_kind(callee, "navigation_suffix"))
                .or_else(|| named_children(callee).into_iter().last())?;
            let field_text = self.member_field_text(field, source)?;
            return Some((
                normalize_text(node_text(object, source))
                    .trim_start_matches('*')
                    .to_string(),
                field_text,
            ));
        }

        if self.identifier_node_kinds().contains(&callee.kind()) {
            return Some(("self".to_string(), node_text(callee, source).to_string()));
        }

        let text = normalize_text(node_text(callee, source));
        if text.is_empty() {
            return None;
        }
        let parts = text.split('.').collect::<Vec<_>>();
        if parts.len() > 1 {
            Some((
                parts[..parts.len() - 1].join("."),
                parts[parts.len() - 1].to_string(),
            ))
        } else {
            Some(("self".to_string(), text))
        }
    }

    fn call_argument_texts(&self, node: Node<'_>, source: &str) -> Vec<String> {
        self.call_argument_nodes(node)
            .into_iter()
            .map(|argument| normalize_text(node_text(argument, source)))
            .collect()
    }

    fn call_argument_nodes<'tree>(&self, node: Node<'tree>) -> Vec<Node<'tree>> {
        if let Some(args) = node.child_by_field_name("arguments").or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| self.argument_list_node_kinds().contains(&child.kind()))
        }) {
            return named_children(args);
        }
        if !self.call_node_kinds().contains(&node.kind()) {
            return Vec::new();
        }

        let callee = node
            .child_by_field_name("function")
            .or_else(|| node.child_by_field_name("callee"))
            .or_else(|| first_named_child(node));
        named_children(node)
            .into_iter()
            .filter(|child| Some(*child) != callee)
            .collect()
    }

    fn call_has_block(&self, node: Node<'_>) -> bool {
        named_children(node)
            .into_iter()
            .any(|child| self.block_argument_node_kinds().contains(&child.kind()))
    }

    fn noise_call(&self, target: &CallTarget<'_>) -> bool {
        let message = target.message.as_str();
        let receiver = target.receiver.as_str();
        message.is_empty()
            || NOISE_MESSAGES.contains(&message)
            || message.starts_with('@')
            || matches!(receiver, "std" | "builtin" | "build_options")
            || receiver.starts_with("std.")
            || receiver.starts_with("builtin.")
            || receiver.starts_with("build_options.")
    }

    fn state_target(&self, lhs: Node<'_>, source: &str) -> Option<Target> {
        self.default_state_target(lhs, source)
    }

    fn state_declaration(&self, node: Node<'_>, source: &str) -> Option<(String, Option<String>)> {
        self.default_state_declaration(node, source)
    }

    fn state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        self.default_state_read_target(node, source)
    }

    fn default_state_read_target(&self, node: Node<'_>, source: &str) -> Option<Target> {
        if self.accessor_call_node_kinds().contains(&node.kind()) {
            let receiver = node.child_by_field_name("receiver")?;
            let method = node.child_by_field_name("method")?;
            let field = node_text(method, source);
            if node.child_by_field_name("arguments").is_some() || NOISE_MESSAGES.contains(&field) {
                return None;
            }
            return Some(Target {
                receiver: normalize_text(node_text(receiver, source)),
                field: field.to_string(),
            });
        }

        let target = self.default_state_target(node, source)?;
        if NOISE_MESSAGES.contains(&target.field.as_str()) {
            None
        } else {
            Some(target)
        }
    }

    fn default_state_target(&self, lhs: Node<'_>, source: &str) -> Option<Target> {
        if self.expression_list_node_kinds().contains(&lhs.kind()) {
            let children = named_children(lhs);
            if children.len() == 1 {
                return self.default_state_target(children[0], source);
            }
            if !self.member_expression_list(lhs, source) {
                return None;
            }
        }

        if self.accessor_call_node_kinds().contains(&lhs.kind()) {
            let receiver = lhs.child_by_field_name("receiver")?;
            let method = lhs.child_by_field_name("method")?;
            return Some(Target {
                receiver: normalize_text(node_text(receiver, source)),
                field: strip_assignment_suffix(node_text(method, source)),
            });
        }

        if self.field_like_node_kinds().contains(&lhs.kind())
            || self.expression_list_node_kinds().contains(&lhs.kind())
        {
            let object = lhs
                .child_by_field_name("object")
                .or_else(|| lhs.child_by_field_name("receiver"))
                .or_else(|| lhs.child_by_field_name("expression"))
                .or_else(|| lhs.child_by_field_name("operand"))
                .or_else(|| lhs.child_by_field_name("value"))
                .or_else(|| lhs.child_by_field_name("argument"))
                .or_else(|| first_named_child_except(lhs, "navigation_suffix"))?;
            let field = lhs
                .child_by_field_name("field")
                .or_else(|| lhs.child_by_field_name("property"))
                .or_else(|| lhs.child_by_field_name("name"))
                .or_else(|| lhs.child_by_field_name("suffix"))
                .or_else(|| first_named_child_with_kind(lhs, "navigation_suffix"))
                .or_else(|| named_children(lhs).into_iter().last())?;
            let field_text = self.member_field_text(field, source)?;
            return Some(Target {
                receiver: normalize_text(node_text(object, source)),
                field: strip_assignment_suffix(&field_text),
            });
        }

        None
    }

    fn member_expression_list(&self, node: Node<'_>, source: &str) -> bool {
        if node.child_by_field_name("operand").is_some()
            && node.child_by_field_name("field").is_some()
        {
            return true;
        }
        if !self
            .field_like_dot_wrapper_node_kinds()
            .contains(&node.kind())
        {
            return false;
        }
        let text = node_text(node, source);
        text.contains('.') || text.contains("->") || text.contains("::") || text.contains("?.")
    }

    fn default_state_declaration(
        &self,
        node: Node<'_>,
        source: &str,
    ) -> Option<(String, Option<String>)> {
        if self
            .assignment_state_declaration_node_kinds()
            .contains(&node.kind())
        {
            if let Some((field, r#type)) = self.assignment_state_declaration(node, source) {
                return Some((field, r#type));
            }
        }
        if !self.field_declaration_node_kinds().contains(&node.kind()) {
            return None;
        }
        let name = self.field_declaration_name_node(node, source)?;
        let field = node_text(name, source).to_string();
        let r#type = declared_type_text(node, name, source);
        Some((field, r#type))
    }

    fn field_declaration_name_node<'tree>(
        &self,
        node: Node<'tree>,
        source: &str,
    ) -> Option<Node<'tree>> {
        node.child_by_field_name("name")
            .or_else(|| self.declarator_name_node(node, source))
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| self.field_identifier_node_kinds().contains(&child.kind()))
            })
            .or_else(|| {
                named_children(node).into_iter().rev().find(|child| {
                    self.identifier_node_kinds().contains(&child.kind())
                        || self.field_identifier_node_kinds().contains(&child.kind())
                })
            })
    }

    fn declarator_name_node<'tree>(&self, node: Node<'tree>, _source: &str) -> Option<Node<'tree>> {
        let mut pending = named_children(node);
        let mut seen = HashSet::new();
        while let Some(current) = pending.pop() {
            let key = format!("{:?}\0{}", span(current), current.kind());
            if !seen.insert(key) {
                continue;
            }
            if self.identifier_node_kinds().contains(&current.kind())
                || self.field_identifier_node_kinds().contains(&current.kind())
            {
                return Some(current);
            }
            pending.extend(named_children(current));
        }
        None
    }

    fn assignment_state_declaration(
        &self,
        node: Node<'_>,
        source: &str,
    ) -> Option<(String, Option<String>)> {
        let assignment = self.assignment_target(node)?;
        let target = self.state_target(assignment.lhs, source)?;
        if !matches!(target.receiver.as_str(), "self" | "this") {
            return None;
        }
        let rhs = node
            .child_by_field_name("right")
            .or_else(|| node.child_by_field_name("value"))
            .or_else(|| named_children(node).get(1).copied());
        let r#type = rhs.and_then(|node| inferred_assignment_type(node, source));
        r#type.map(|type_name| (target.field, Some(type_name)))
    }

    fn assignment_target<'tree>(&self, node: Node<'tree>) -> Option<AssignmentTarget<'tree>> {
        self.default_assignment_target(node)
    }

    fn default_assignment_target<'tree>(
        &self,
        node: Node<'tree>,
    ) -> Option<AssignmentTarget<'tree>> {
        if !self.assignment_node_kinds().contains(&node.kind()) {
            return None;
        }
        let lhs = node
            .child_by_field_name("left")
            .or_else(|| first_named_child(node))?;
        Some(AssignmentTarget { lhs, source: node })
    }

    fn skip_state_write_node(&self, _node: Node<'_>) -> bool {
        false
    }

    fn skip_state_write_target(&self, target: &Target) -> bool {
        target.field == "[]"
    }

    fn state_write_source_node<'tree>(
        &self,
        _node: Node<'tree>,
        assignment: &AssignmentTarget<'tree>,
    ) -> Node<'tree> {
        assignment.source
    }

    fn assignment_lhs_node(&self, node: Node<'_>) -> bool {
        if !super::super::tree_sitter_adapter::next_sibling_raw_text(node)
            .map(|token| self.assignment_operator_tokens().contains(&token.as_str()))
            .unwrap_or(false)
        {
            return false;
        }
        if super::super::tree_sitter_adapter::previous_sibling_raw_text(node).as_deref()
            == Some(":")
        {
            return false;
        }
        true
    }

    fn parenthesized_wrapper(&self, node: Node<'_>) -> bool {
        self.parenthesized_wrapper_node_kinds()
            .contains(&node.kind())
            && named_children(node).len() == 1
    }

    fn boolean_container(&self, node: Node<'_>) -> bool {
        if self.boolean_container_node_kinds().contains(&node.kind()) {
            return true;
        }
        if self.parenthesized_wrapper(node) {
            return first_named_child(node)
                .map(|child| self.boolean_container(child))
                .unwrap_or(false);
        }
        if !self.boolean_wrapper_node_kinds().contains(&node.kind()) {
            return false;
        }
        if !self
            .boolean_and_operators()
            .contains(&super::super::tree_sitter_adapter::direct_operator(node).as_str())
        {
            return false;
        }
        if named_children(node).len() < 2 {
            return false;
        }
        let mut cursor = node.walk();
        let result = node.children(&mut cursor).all(|child| {
            child.is_named()
                || self.boolean_and_operators().contains(&child.kind())
                || matches!(child.kind(), "(" | ")")
        });
        result
    }

    fn decision_subject<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        node.child_by_field_name("value")
            .or_else(|| node.child_by_field_name("subject"))
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| self.case_subject_node_kinds().contains(&child.kind()))
            })
            .or_else(|| node.child_by_field_name("condition"))
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| !self.case_subject_skip_node_kinds().contains(&child.kind()))
            })
    }

    fn first_identifier_text(&self, node: Node<'_>, source: &str) -> Option<String> {
        let mut kinds = Vec::new();
        kinds.extend_from_slice(self.identifier_node_kinds());
        kinds.extend_from_slice(self.field_identifier_node_kinds());
        first_named_text(node, source, &kinds)
    }

    fn declarator_name(&self, node: Option<Node<'_>>, source: &str) -> Option<String> {
        let mut pending = vec![node?];
        let mut seen = HashSet::new();
        while let Some(current) = pending.pop() {
            let key = format!("{:?}\0{}", span(current), current.kind());
            if !seen.insert(key) {
                continue;
            }
            if self.identifier_node_kinds().contains(&current.kind())
                || self.field_identifier_node_kinds().contains(&current.kind())
            {
                return Some(node_text(current, source).to_string());
            }
            let mut children = named_children(current);
            children.reverse();
            pending.extend(children);
        }
        None
    }

    fn function_parameter_list<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        let declarator = node.child_by_field_name("declarator");
        declarator
            .and_then(|declarator| declarator.child_by_field_name("parameters"))
            .or_else(|| node.child_by_field_name("parameters"))
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| self.parameter_list_node_kinds().contains(&child.kind()))
            })
            .or_else(|| {
                declarator.and_then(|declarator| {
                    named_children(declarator)
                        .into_iter()
                        .find(|child| self.parameter_list_node_kinds().contains(&child.kind()))
                })
            })
    }

    fn parameter_name(&self, param: Node<'_>, source: &str) -> Option<String> {
        let name = if self
            .parameter_identifier_node_kinds()
            .contains(&param.kind())
        {
            Some(param)
        } else {
            param
                .child_by_field_name("name")
                .or_else(|| {
                    named_children(param)
                        .into_iter()
                        .filter(|child| {
                            self.parameter_identifier_node_kinds()
                                .contains(&child.kind())
                        })
                        .last()
                })
                .or_else(|| self.descendant_parameter_name(param))
        }?;
        let text = self.normalize_parameter_name(node_text(name, source));
        (!text.is_empty() && text != "_").then_some(text)
    }

    fn descendant_parameter_name<'tree>(&self, node: Node<'tree>) -> Option<Node<'tree>> {
        let mut found = None;
        let mut stack = named_children(node);
        while let Some(current) = stack.pop() {
            if self
                .parameter_identifier_node_kinds()
                .contains(&current.kind())
            {
                found = Some(current);
            }
            stack.extend(named_children(current));
        }
        found
    }

    fn normalize_parameter_name(&self, text: &str) -> String {
        text.to_string()
    }

    fn impl_owner_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        let r#type = node.child_by_field_name("type").or_else(|| {
            named_children(node).into_iter().find(|child| {
                self.receiver_type_node_kinds().contains(&child.kind())
                    || self.identifier_node_kinds().contains(&child.kind())
                    || self.field_identifier_node_kinds().contains(&child.kind())
            })
        })?;
        Some(normalize_type_owner(node_text(r#type, source)))
    }

    fn first_argument_receiver_parameter(
        &self,
        node: Node<'_>,
        source: &str,
    ) -> Option<(String, String)> {
        let declarator = node.child_by_field_name("declarator");
        let params = declarator
            .and_then(|declarator| declarator.child_by_field_name("parameters"))
            .or_else(|| node.child_by_field_name("parameters"))
            .or_else(|| {
                named_children(node)
                    .into_iter()
                    .find(|child| self.parameter_list_node_kinds().contains(&child.kind()))
            })
            .or_else(|| {
                declarator.and_then(|declarator| {
                    named_children(declarator)
                        .into_iter()
                        .find(|child| self.parameter_list_node_kinds().contains(&child.kind()))
                })
            })?;

        let first = named_children(params)
            .into_iter()
            .find(|child| self.receiver_parameter_node_kinds().contains(&child.kind()))?;

        let type_node = named_children(first).into_iter().find(|child| {
            self.first_argument_receiver_type_node_kinds()
                .contains(&child.kind())
        })?;
        let name = named_children(first)
            .into_iter()
            .rev()
            .find(|child| {
                self.first_argument_receiver_name_node_kinds()
                    .contains(&child.kind())
            })
            .map(|child| node_text(child, source).to_string())
            .or_else(|| self.nested_receiver_name(first, source))
            .or_else(|| self.declarator_name(Some(first), source))?;

        Some((node_text(type_node, source).to_string(), name))
    }

    fn nested_receiver_name(&self, node: Node<'_>, source: &str) -> Option<String> {
        for child in named_children(node).into_iter().rev() {
            let direct = named_children(child).into_iter().rev().find(|grandchild| {
                self.first_argument_receiver_name_node_kinds()
                    .contains(&grandchild.kind())
            });
            if let Some(direct) = direct {
                return Some(node_text(direct, source).to_string());
            }
        }
        None
    }

    fn member_field_text(&self, field: Node<'_>, source: &str) -> Option<String> {
        if self.navigation_suffix_node_kinds().contains(&field.kind()) {
            let suffix = field
                .child_by_field_name("suffix")
                .or_else(|| {
                    named_children(field).into_iter().find(|child| {
                        self.identifier_node_kinds().contains(&child.kind())
                            || self.field_identifier_node_kinds().contains(&child.kind())
                    })
                })
                .or_else(|| named_children(field).into_iter().last())?;
            let text = node_text(suffix, source)
                .trim_start_matches(['.', '?'])
                .trim_start_matches("->");
            return (!text.is_empty()).then(|| text.to_string());
        }

        Some(
            node_text(field, source)
                .trim_start_matches(['.', '?'])
                .trim_start_matches("->")
                .to_string(),
        )
    }

    fn clone_candidates(&self, document: &Document) -> Vec<CloneCandidate> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        let mut fingerprint_cache = HashMap::new();

        for function in &document.function_defs {
            let candidate = clone_candidate_for(
                self,
                document,
                &function.body,
                Some("defn"),
                Some(function.name.as_str()),
                &mut fingerprint_cache,
            );
            clone_add_candidate(&mut out, &mut seen, candidate);
        }

        let mut nodes = Vec::new();
        document.root.walk(&mut nodes);
        for node in nodes {
            if self.clone_candidate_node(node) {
                let candidate =
                    clone_candidate_for(self, document, node, None, None, &mut fingerprint_cache);
                clone_add_candidate(&mut out, &mut seen, candidate);
            }
        }

        out
    }

    #[cfg(test)]
    fn clone_fingerprint(&self, node: &RawNode) -> (String, usize) {
        clone_fingerprint_for_profile(self, node, &mut HashSet::new())
    }

    fn clone_candidate_node(&self, node: &RawNode) -> bool {
        default_clone_candidate_node(node)
    }

    fn clone_fingerprint_children<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode> {
        node.children.iter().collect()
    }

    fn clone_child_fingerprint(
        &self,
        _parent: &RawNode,
        _child: &RawNode,
    ) -> Option<(String, usize)> {
        None
    }
}

fn clone_add_candidate(
    out: &mut Vec<CloneCandidate>,
    seen: &mut HashSet<String>,
    candidate: Option<CloneCandidate>,
) {
    let Some(candidate) = candidate else { return };
    if clone_typed_struct_schema_text(&candidate.raw) {
        return;
    }
    let key = format!(
        "{}\0{}\0{:?}\0{}\0{}",
        candidate.file, candidate.line, candidate.span, candidate.node_name, candidate.fingerprint
    );
    if seen.insert(key) {
        out.push(candidate);
    }
}

fn clone_candidate_for<P: LanguageProfile + ?Sized>(
    profile: &P,
    document: &Document,
    node: &RawNode,
    node_name: Option<&str>,
    function_name: Option<&str>,
    fingerprint_cache: &mut HashMap<usize, (String, usize)>,
) -> Option<CloneCandidate> {
    let (fingerprint, mass) =
        clone_fingerprint_for_profile_cached(profile, node, &mut HashSet::new(), fingerprint_cache);
    if fingerprint.is_empty() {
        return None;
    }

    let line = node.line();
    let method = clone_method_span_for(document, line);
    let children = clone_fuzzy_children_for(profile, node);
    let mut child_fingerprints = Vec::new();
    let mut child_masses = Vec::new();
    for child in children {
        let (child_fp, child_mass) = clone_fingerprint_for_profile_cached(
            profile,
            child,
            &mut HashSet::new(),
            fingerprint_cache,
        );
        if !child_fp.is_empty() && child_mass > 0 {
            child_fingerprints.push(child_fp);
            child_masses.push(child_mass);
        }
    }

    Some(CloneCandidate {
        file: document.file.clone(),
        line,
        span: node.span,
        method_name: function_name
            .map(ToString::to_string)
            .or_else(|| method.map(|function| function.name.clone()))
            .unwrap_or_else(|| "(top-level)".to_string()),
        node_name: node_name
            .map(ToString::to_string)
            .unwrap_or_else(|| clone_node_name(node).to_string()),
        mass,
        fingerprint,
        raw: normalize_text(&node.text),
        child_fingerprints,
        child_masses,
    })
}

pub(super) fn default_clone_candidate_node(node: &RawNode) -> bool {
    node.named
        && !CLONE_SKIP_KINDS.contains(&node.kind.as_str())
        && CLONE_CANDIDATE_KINDS.contains(&node.kind.as_str())
        && !clone_typed_struct_schema_text(&node.text)
        && !node.named_children().is_empty()
}

fn clone_fuzzy_children_for<'a, P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &'a RawNode,
) -> Vec<&'a RawNode> {
    let source = clone_body_node_for(profile, node).unwrap_or(node);
    let mut children = profile
        .clone_fingerprint_children(source)
        .into_iter()
        .filter(|child| child.named)
        .collect::<Vec<_>>();
    if children.is_empty() {
        children = profile
            .clone_fingerprint_children(node)
            .into_iter()
            .filter(|child| child.named)
            .collect();
    }
    children
        .into_iter()
        .filter(|child| {
            !CLONE_SKIP_KINDS.contains(&child.kind.as_str())
                && !clone_typed_struct_schema_text(&child.text)
        })
        .collect()
}

fn clone_body_node_for<'a, P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &'a RawNode,
) -> Option<&'a RawNode> {
    clone_body_node(node).or_else(|| {
        profile
            .clone_fingerprint_children(node)
            .into_iter()
            .find(|child| CLONE_BODY_KINDS.contains(&child.kind.as_str()))
    })
}

fn clone_body_node(node: &RawNode) -> Option<&RawNode> {
    node.children
        .iter()
        .find(|child| CLONE_BODY_KINDS.contains(&child.kind.as_str()))
}

fn declared_type_text(node: Node<'_>, name: Node<'_>, source: &str) -> Option<String> {
    if let Some(r#type) = node.child_by_field_name("type") {
        let text = normalize_text(node_text(r#type, source));
        if !text.is_empty() {
            return Some(text);
        }
    }

    let text = node_text(node, source);
    let name_text = node_text(name, source);
    let before_name = text.split(name_text).next().unwrap_or("").trim();
    let candidate = before_name
        .split_whitespace()
        .filter(|token| {
            !matches!(
                *token,
                "public" | "private" | "protected" | "static" | "final" | "const"
            )
        })
        .last()
        .unwrap_or("")
        .trim_matches(['*', '&']);
    (!candidate.is_empty()).then(|| candidate.to_string())
}

fn inferred_assignment_type(node: Node<'_>, source: &str) -> Option<String> {
    let text = normalize_text(node_text(node, source));
    for prefix in ["new ", ""] {
        let value = text.strip_prefix(prefix).unwrap_or(&text);
        let candidate = value
            .split(['(', '{', '<', ' ', ':'])
            .next()
            .unwrap_or("")
            .trim();
        if candidate
            .chars()
            .next()
            .map(|ch| ch.is_ascii_uppercase())
            .unwrap_or(false)
        {
            return Some(candidate.to_string());
        }
    }
    None
}

#[cfg(test)]
fn clone_fingerprint_for_profile<P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &RawNode,
    active: &mut HashSet<String>,
) -> (String, usize) {
    let key = clone_node_key(node);
    if active.contains(&key) || node.kind == "comment" {
        return (String::new(), 0);
    }
    active.insert(key.clone());
    let out =
        if CLONE_CALL_KINDS.contains(&node.kind.as_str()) && clone_call_message(node).is_some() {
            clone_fingerprint_call(profile, node, active)
        } else if node.children.is_empty() {
            let token = clone_terminal_token(node);
            if token.is_empty() {
                (String::new(), 0)
            } else {
                (token, 1)
            }
        } else {
            let mut child_parts = Vec::new();
            let mut mass = 1;
            for child in profile.clone_fingerprint_children(node) {
                let (child_fp, child_mass) = profile
                    .clone_child_fingerprint(node, child)
                    .unwrap_or_else(|| clone_fingerprint_for_profile(profile, child, active));
                if child_fp.is_empty() {
                    continue;
                }
                child_parts.push(child_fp);
                mass += child_mass;
            }
            if child_parts.is_empty() {
                (clone_terminal_token(node), 1)
            } else {
                (format!("{}({})", node.kind, child_parts.join(" ")), mass)
            }
        };
    active.remove(&key);
    out
}

fn clone_fingerprint_for_profile_cached<P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &RawNode,
    active: &mut HashSet<String>,
    cache: &mut HashMap<usize, (String, usize)>,
) -> (String, usize) {
    let cache_key = clone_node_ptr(node);
    if let Some(cached) = cache.get(&cache_key) {
        return cached.clone();
    }

    let active_key = clone_node_key(node);
    if active.contains(&active_key) || node.kind == "comment" {
        return (String::new(), 0);
    }
    active.insert(active_key.clone());
    let out =
        if CLONE_CALL_KINDS.contains(&node.kind.as_str()) && clone_call_message(node).is_some() {
            clone_fingerprint_call_cached(profile, node, active, cache)
        } else if node.children.is_empty() {
            let token = clone_terminal_token(node);
            if token.is_empty() {
                (String::new(), 0)
            } else {
                (token, 1)
            }
        } else {
            let mut child_parts = Vec::new();
            let mut mass = 1;
            for child in profile.clone_fingerprint_children(node) {
                let (child_fp, child_mass) = profile
                    .clone_child_fingerprint(node, child)
                    .unwrap_or_else(|| {
                        clone_fingerprint_for_profile_cached(profile, child, active, cache)
                    });
                if child_fp.is_empty() {
                    continue;
                }
                child_parts.push(child_fp);
                mass += child_mass;
            }
            if child_parts.is_empty() {
                (clone_terminal_token(node), 1)
            } else {
                (format!("{}({})", node.kind, child_parts.join(" ")), mass)
            }
        };
    active.remove(&active_key);
    cache.insert(cache_key, out.clone());
    out
}

#[cfg(test)]
fn clone_fingerprint_call<P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &RawNode,
    active: &mut HashSet<String>,
) -> (String, usize) {
    let message = clone_call_message(node).unwrap_or_default();
    let mut child_parts = Vec::new();
    let mut mass = 1;
    for child in profile.clone_fingerprint_children(node) {
        let (child_fp, child_mass) = profile
            .clone_child_fingerprint(node, child)
            .unwrap_or_else(|| clone_fingerprint_for_profile(profile, child, active));
        if child_fp.is_empty() {
            continue;
        }
        child_parts.push(child_fp);
        mass += child_mass;
    }
    (
        format!("{}<{}>({})", node.kind, message, child_parts.join(" ")),
        mass,
    )
}

fn clone_fingerprint_call_cached<P: LanguageProfile + ?Sized>(
    profile: &P,
    node: &RawNode,
    active: &mut HashSet<String>,
    cache: &mut HashMap<usize, (String, usize)>,
) -> (String, usize) {
    let message = clone_call_message(node).unwrap_or_default();
    let mut child_parts = Vec::new();
    let mut mass = 1;
    for child in profile.clone_fingerprint_children(node) {
        let (child_fp, child_mass) = profile
            .clone_child_fingerprint(node, child)
            .unwrap_or_else(|| clone_fingerprint_for_profile_cached(profile, child, active, cache));
        if child_fp.is_empty() {
            continue;
        }
        child_parts.push(child_fp);
        mass += child_mass;
    }
    (
        format!("{}<{}>({})", node.kind, message, child_parts.join(" ")),
        mass,
    )
}

fn clone_call_message(node: &RawNode) -> Option<String> {
    if !node.children.iter().any(|child| {
        matches!(
            child.kind.as_str(),
            "argument_list" | "arguments" | "call_suffix"
        )
    }) {
        return None;
    }
    let argument_start = node
        .children
        .iter()
        .find(|child| {
            matches!(
                child.kind.as_str(),
                "argument_list" | "arguments" | "call_suffix"
            )
        })
        .map(|child| (child.span[0], child.span[1]));
    let named_before_args = node
        .named_children()
        .into_iter()
        .filter(|child| {
            argument_start
                .map(|start| (child.span[0], child.span[1]) < start)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    named_before_args
        .last()
        .and_then(|callee| clone_callee_message(callee))
}

fn clone_callee_message(node: &RawNode) -> Option<String> {
    if CLONE_IDENTIFIER_KINDS.contains(&node.kind.as_str()) {
        return Some(node.text.clone());
    }
    if matches!(
        node.kind.as_str(),
        "navigation_expression" | "directly_assignable_expression"
    ) {
        return clone_navigation_suffix_message(node);
    }

    node.named_children()
        .into_iter()
        .rev()
        .find(|child| CLONE_IDENTIFIER_KINDS.contains(&child.kind.as_str()))
        .map(|child| child.text.clone())
}

fn clone_navigation_suffix_message(node: &RawNode) -> Option<String> {
    let suffix = node
        .named_children()
        .into_iter()
        .rev()
        .find(|child| child.kind == "navigation_suffix")?;
    suffix
        .named_children()
        .into_iter()
        .rev()
        .find(|child| CLONE_IDENTIFIER_KINDS.contains(&child.kind.as_str()))
        .map(|child| child.text.clone())
}

fn clone_terminal_token(node: &RawNode) -> String {
    let kind = node.kind.as_str();
    if CLONE_IDENTIFIER_KINDS.contains(&kind) {
        return "id".to_string();
    }
    if CLONE_LITERAL_KINDS.contains(&kind) {
        return clone_literal_token(kind).to_string();
    }
    let text = normalize_text(&node.text);
    if text.is_empty() {
        return String::new();
    }
    if clone_identifier_text(&text) {
        return "id".to_string();
    }
    if clone_literal_text(&text) {
        return "lit".to_string();
    }
    format!("{kind}:{text}")
}

fn clone_literal_token(kind: &str) -> &str {
    match kind {
        "true" | "false" => "bool",
        "nil" | "none" | "null" => "nil",
        _ => "lit",
    }
}

fn clone_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| {
            char == '_' || char == '!' || char == '?' || char == '=' || char.is_ascii_alphanumeric()
        })
}

fn clone_literal_text(text: &str) -> bool {
    if clone_symbol_literal_text(text)
        || clone_quoted_literal_text(text, '"')
        || clone_quoted_literal_text(text, '\'')
    {
        return true;
    }
    text.parse::<f64>().is_ok()
}

fn clone_symbol_literal_text(text: &str) -> bool {
    let mut chars = text.chars();
    if chars.next() != Some(':') {
        return false;
    }
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| char == '_' || char.is_ascii_alphanumeric())
}

fn clone_quoted_literal_text(text: &str, quote: char) -> bool {
    text.len() >= 2 && text.starts_with(quote) && text.ends_with(quote)
}

fn clone_node_name(node: &RawNode) -> &str {
    match node.kind.as_str() {
        "method"
        | "function_definition"
        | "function_declaration"
        | "method_definition"
        | "function_item" => "defn",
        "singleton_method" => "defs",
        other => other,
    }
}

fn clone_typed_struct_schema_text(text: &str) -> bool {
    text.contains("< T::Struct")
        || text.contains("<T::Struct")
        || text.lines().all(|line| {
            let stripped = line.trim();
            stripped.is_empty() || stripped.starts_with("const :") || stripped.starts_with("prop :")
        })
}

fn clone_method_span_for<'a>(
    document: &'a Document,
    line_no: usize,
) -> Option<&'a super::super::FunctionDef> {
    document
        .function_defs
        .iter()
        .find(|function| function.span[0] <= line_no && line_no <= function.span[2])
}

fn generic_loop_context(node: Node<'_>, source: &str) -> bool {
    matches!(
        node.kind(),
        "while"
            | "until"
            | "for"
            | "do_block"
            | "while_statement"
            | "until_statement"
            | "for_statement"
            | "for_in_statement"
            | "enhanced_for_statement"
            | "foreach_statement"
            | "for_range_loop"
            | "for_expression"
            | "loop_expression"
    ) || matches!(node.kind(), "expression_statement" | "labeled_statement")
        && normalize_text(node_text(node, source))
            .trim_start()
            .starts_with("for ")
}

fn generic_branch_context(node: Node<'_>, source: &str) -> bool {
    if matches!(
        node.kind(),
        "if" | "unless"
            | "if_modifier"
            | "unless_modifier"
            | "case"
            | "if_statement"
            | "if_expression"
            | "case_statement"
            | "switch_statement"
            | "switch_expression"
            | "match_statement"
            | "match_expression"
            | "when_expression"
            | "expression_switch_statement"
    ) {
        return true;
    }

    let first_token_is_branch = matches!(
        node.kind(),
        "body_statement" | "block" | "statements" | "statement_list"
    ) && {
        let mut cursor = node.walk();
        let result = node
            .children(&mut cursor)
            .next()
            .map(|child| matches!(child.kind(), "if" | "unless" | "case"))
            .unwrap_or(false);
        result
    };
    first_token_is_branch
        || node.kind() == "expression_statement"
            && normalize_text(node_text(node, source))
                .trim_start()
                .starts_with("if ")
}

pub(crate) fn protocol_method_name(name: &str) -> String {
    name.split(['.', ':'])
        .filter(|part| !part.is_empty())
        .last()
        .unwrap_or(name)
        .to_string()
}

pub(crate) fn normalize_protocol_state(name: &str) -> String {
    name.trim_start_matches('@')
        .trim_end_matches('=')
        .to_string()
}

fn clone_node_key(node: &RawNode) -> String {
    format!(
        "{}\0{}\0{}\0{}\0{}\0{}",
        node.kind,
        node.span[0],
        node.span[1],
        node.span[2],
        node.span[3],
        node.text.len()
    )
}

fn clone_node_ptr(node: &RawNode) -> usize {
    node as *const RawNode as usize
}

fn snake_case_type_name(type_str: &str) -> String {
    type_str
        .split("::")
        .last()
        .unwrap_or(type_str)
        .chars()
        .enumerate()
        .fold(String::new(), |mut acc, (index, ch)| {
            if index > 0 && ch.is_ascii_uppercase() {
                acc.push('_');
            }
            acc.push(ch.to_ascii_lowercase());
            acc
        })
}
