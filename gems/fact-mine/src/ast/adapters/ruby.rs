use super::super::{
    exact_bare_identifier_text, identifier_kind_name, named_children, node_text,
    raw_named_children, TreeSitterNormalizer, CASE_ARGUMENT_WHEN_KINDS, ENSURE_BODY_WRAPPER_KINDS,
    HEREDOC_BODY_WRAPPER_KINDS, INTERPOLATED_STATEMENT_WRAPPER_KINDS,
    LEADING_FUNCTION_WRAPPER_KINDS, LEADING_LOOP_WRAPPER_KINDS, RESCUE_BODY_WRAPPER_KINDS,
};
use super::base::{AstNormalizationAdapter, ConditionalBranchParts, NamedChildrenAction};
use std::collections::BTreeSet;
use tree_sitter::Node as TreeSitterNode;

const RUBY_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "**=", "&&=", "||=", "&=", "|=", "^=", "<<=", ">>=",
];

pub(crate) struct RubyAstAdapter;

impl AstNormalizationAdapter for RubyAstAdapter {
    fn tracks_dynamic_local_scope(&self) -> bool {
        true
    }

    fn yield_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "statement"
        ) {
            return false;
        }
        let named = named_children(node);
        named.len() == 1
            && named[0].kind() == "yield"
            && node_text(named[0], source) == node_text(node, source)
    }

    fn super_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "call" | "statement"
        ) {
            return false;
        }
        if node_text(node, source).trim() == "super" {
            return true;
        }
        let raw = raw_named_children(node);
        let named = if raw.len() == 1 && raw[0].kind() == "call" {
            raw_named_children(raw[0])
        } else {
            raw
        };
        named
            .first()
            .map(|child| child.kind() == "super")
            .unwrap_or(false)
            && named
                .iter()
                .skip(1)
                .all(|child| child.kind() == "argument_list")
    }

    fn function_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "method"
                | "function_definition"
                | "function_declaration"
                | "method_definition"
                | "method_declaration"
                | "function_item"
                | "singleton_method"
        )
    }

    fn singleton_function_kind(&self, kind: &str) -> bool {
        kind == "singleton_method"
    }

    fn singleton_class_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "singleton_class"
    }

    fn block_pass_argument(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "block_argument"
    }

    fn leading_function_keyword(&self, kind: &str) -> bool {
        kind == "def"
    }

    fn inline_def_receiver_text(&self, text: &str) -> bool {
        ruby_inline_def_receiver_text(text)
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "elsif" | "else"))
    }

    fn elsif_statement(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "elsif"
    }

    fn elsif_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<ConditionalBranchParts<'tree>> {
        if node.kind() != "elsif" {
            return None;
        }

        let named = named_children(node);
        Some(ConditionalBranchParts {
            condition: named
                .iter()
                .copied()
                .find(|child| !matches!(child.kind(), "comment" | "then" | "elsif" | "else"))?,
            positive: named.iter().copied().find(|child| child.kind() == "then"),
            negative: named
                .iter()
                .copied()
                .find(|child| matches!(child.kind(), "elsif" | "else")),
        })
    }

    fn instance_variable(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "instance_variable"
            || node_text(node, source)
                .strip_prefix('@')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn global_variable(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "global_variable"
            || node_text(node, source)
                .strip_prefix('$')
                .map(ruby_variable_name_text)
                .unwrap_or(false)
    }

    fn dynamic_constant_pattern_text(&self, text: &str) -> bool {
        ruby_constant_text(text)
    }

    fn dynamic_exception_constant_text(&self, text: &str) -> bool {
        ruby_exception_constant_text(text)
    }

    fn dynamic_instance_variable_text(&self, text: &str) -> bool {
        ruby_instance_variable_text(text)
    }

    fn case_argument_list(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() != "argument_list" {
            return false;
        }
        let raw_named = named_children(node);
        let target = if raw_named.len() == 1
            && raw_named[0].kind() == "case"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            raw_named[0]
        } else {
            node
        };
        let has_case_keyword = target
            .children(&mut target.walk())
            .any(|child| !child.is_named() && child.kind() == "case");
        has_case_keyword
            && named_children(target)
                .iter()
                .any(|child| CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()))
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, source) == "&.")
    }

    fn begin_statement(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "begin"
    }

    fn rescue_modifier_statement(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "rescue_modifier"
    }

    fn ensure_clause_statement(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "ensure"
    }

    fn if_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "if" | "if_statement"
                | "if_modifier"
                | "unless"
                | "unless_modifier"
                | "if_expression"
                | "conditional"
        )
    }

    fn conditional_modifier_kind(&self, kind: &str) -> bool {
        matches!(kind, "if_modifier" | "unless_modifier")
    }

    fn conditional_node_type(&self, kind: &str) -> Option<&'static str> {
        if kind.starts_with("unless") {
            Some("UNLESS")
        } else if self.if_node_kind(kind) {
            Some("IF")
        } else {
            None
        }
    }

    fn conditional_keyword_node_type(&self, keyword: &str) -> Option<&'static str> {
        match keyword {
            "if" => Some("IF"),
            "unless" => Some("UNLESS"),
            _ => None,
        }
    }

    fn modifier_node_type(&self, keyword: &str) -> Option<&'static str> {
        match keyword {
            "if" => Some("IF"),
            "unless" => Some("UNLESS"),
            "while" => Some("WHILE"),
            "until" => Some("UNTIL"),
            _ => None,
        }
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        match kind {
            "while" | "while_statement" | "while_modifier" => Some("WHILE"),
            "until" | "until_statement" | "until_modifier" => Some("UNTIL"),
            "for" | "for_statement" | "for_in_clause" => Some("FOR"),
            _ => None,
        }
    }

    fn modifier_loop_kind(&self, kind: &str) -> bool {
        matches!(kind, "while_modifier" | "until_modifier")
    }

    fn conditional_branch_skip_kind(&self, kind: &str) -> bool {
        matches!(kind, "comment" | "then" | "elsif" | "else")
    }

    fn branch_child_skip_kind(&self, kind: &str) -> bool {
        matches!(kind, "comment" | "elsif" | "else")
    }

    fn rescue_clause_exceptions<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(exceptions) = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exceptions")
        else {
            return Vec::new();
        };
        let text = node_text(exceptions, source).trim();
        if ruby_exception_constant_text(text)
            || (named_children(exceptions).is_empty() && !text.is_empty())
        {
            return vec![exceptions];
        }
        named_children(exceptions)
    }

    fn rescue_clause_exceptions_source<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exceptions")
    }

    fn rescue_clause_exception_variable_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exception_variable")
            .and_then(|variable| {
                named_children(variable)
                    .into_iter()
                    .find(|child| identifier_kind_name(child.kind()))
            })
    }

    fn rescue_clause_exception_variable_source<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "exception_variable")
    }

    fn rescue_clause_handler<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node).into_iter().rev().find(|child| {
            !matches!(
                child.kind(),
                "exceptions" | "exception_variable" | "comment"
            )
        })
    }

    fn rescue_clause(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "rescue"
    }

    fn ensure_clause_kind(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "ensure"
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        RESCUE_BODY_WRAPPER_KINDS
            .contains(&node.kind())
            .then_some(node)
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        ENSURE_BODY_WRAPPER_KINDS
            .contains(&node.kind())
            .then_some(node)
    }

    fn leading_function_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.leading_function_statement_with_keyword(
            node,
            source,
            "def",
            LEADING_FUNCTION_WRAPPER_KINDS,
        )
    }

    fn leading_loop_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_LOOP_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && matches!(
                raw_named[0].kind(),
                "while" | "until" | "while_modifier" | "until_modifier"
            )
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn zero_child_identifier_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() != "call" || !ruby_variable_name_text(node_text(node, source)) {
            return false;
        }
        let named = named_children(node);
        named.is_empty()
            || (named.len() == 1
                && super::super::identifier_kind_name(named[0].kind())
                && node_text(named[0], source) == node_text(node, source))
    }

    fn heredoc_call_for_body(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if node.kind() == "heredoc_beginning" {
            return true;
        }
        if matches!(node.kind(), "call" | "argument_list")
            && heredoc_marker_text(node_text(node, source))
        {
            return true;
        }

        named_children(node).into_iter().any(|child| {
            if named_children(child)
                .into_iter()
                .any(|grandchild| grandchild.kind() == "heredoc_body")
            {
                return false;
            }

            self.heredoc_call_for_body(child, source)
        })
    }

    fn heredoc_start_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "heredoc_beginning"
    }

    fn heredoc_body_nodes<'tree>(&self, node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
        if !HEREDOC_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            return Vec::new();
        }
        named_children(node)
            .into_iter()
            .filter(|child| self.heredoc_body_node(*child))
            .collect()
    }

    fn heredoc_body_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "heredoc_body"
    }

    fn heredoc_content_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "heredoc_content"
    }

    fn heredoc_literal_argument(
        &self,
        node: TreeSitterNode<'_>,
        source: &str,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        if children.len() == 1 && self.heredoc_start_node(children[0], source) {
            return heredoc_marker_text(node_text(node, source).trim_start());
        }

        children.is_empty()
            && node_text(node, source).trim_start().starts_with("<<")
            && heredoc_marker_text(node_text(node, source).trim_start())
    }

    fn concatenated_string_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "chained_string" | "concatenated_string")
    }

    fn named_children_action<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> NamedChildrenAction<'tree> {
        if INTERPOLATED_STATEMENT_WRAPPER_KINDS.contains(&node.kind())
            && children.len() == 1
            && children[0].kind() == "string"
            && node_text(node, source) == node_text(children[0], source)
        {
            let string_children = raw_named_children(children[0]);
            if string_children
                .iter()
                .any(|child| child.kind() == "interpolation")
            {
                return NamedChildrenAction::Replace(string_children);
            }
        }

        if matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && children.len() == 1
            && matches!(
                children[0].kind(),
                "if_modifier" | "unless_modifier" | "while_modifier" | "until_modifier" | "yield"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            return NamedChildrenAction::Recurse(children[0]);
        }

        NamedChildrenAction::Default
    }

    fn logical_operator_assignment(&self, operator: &str) -> bool {
        matches!(operator, "||" | "&&")
    }

    fn statement_wrapped_call_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !matches!(
            node.kind(),
            "body_statement" | "block_body" | "statement" | "argument_list"
        ) {
            return None;
        }
        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && raw_named[0].kind() == "call"
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            Some(raw_named[0])
        } else {
            None
        }
    }

    fn inline_def_function_text_source<'tree>(
        &self,
        function: TreeSitterNode<'tree>,
        _source: &str,
    ) -> TreeSitterNode<'tree> {
        if function.kind() == "call" {
            return named_children(function)
                .into_iter()
                .next()
                .unwrap_or(function);
        }
        function
    }

    fn inline_def_wrapper_mid(&self, text: &str) -> bool {
        matches!(
            text,
            "public" | "protected" | "private" | "private_class_method" | "module_function"
        )
    }

    fn bare_const_call_function(&self, function: TreeSitterNode<'_>) -> bool {
        matches!(
            function.kind(),
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
        )
    }

    fn normalize_default_parameters(&self) -> bool {
        true
    }

    fn normalize_block_parameters(&self) -> bool {
        true
    }

    fn boolean_statement_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> TreeSitterNode<'tree> {
        if children.len() == 1
            && matches!(
                children[0].kind(),
                "binary" | "binary_expression" | "binary_operator" | "boolean_operator"
            )
            && node_text(node, source) == node_text(children[0], source)
        {
            children[0]
        } else {
            node
        }
    }

    fn elides_tail_returns(&self) -> bool {
        true
    }

    fn elides_implicit_nil_body(&self) -> bool {
        true
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        RUBY_ASSIGNMENT_OPERATORS
    }
}
pub(super) fn ruby_exception_constant_text(text: &str) -> bool {
    let mut parts = text.split("::");
    let Some(first) = parts.next() else {
        return false;
    };
    let mut first_chars = first.chars();
    if !matches!(first_chars.next(), Some(ch) if ch.is_ascii_uppercase()) {
        return false;
    }
    if !first_chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric()) {
        return false;
    }
    parts.all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}

fn ruby_constant_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_uppercase() && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn ruby_instance_variable_text(text: &str) -> bool {
    text.strip_prefix('@')
        .map(exact_bare_identifier_text)
        .unwrap_or(false)
}

fn ruby_variable_name_text(text: &str) -> bool {
    let mut chars = text.chars().peekable();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    while let Some(ch) = chars.next() {
        if matches!(ch, '!' | '?' | '=') {
            return chars.peek().is_none();
        }
        if !(ch == '_' || ch.is_ascii_alphanumeric()) {
            return false;
        }
    }
    true
}

fn ruby_inline_def_receiver_text(text: &str) -> bool {
    let mut tokens = text.split_whitespace();
    while let Some(token) = tokens.next() {
        if token != "def" {
            continue;
        }
        let Some(name) = tokens.next() else {
            return false;
        };
        let Some((receiver, _method)) = name.split_once('.') else {
            return false;
        };
        return !receiver.is_empty();
    }
    false
}

fn heredoc_marker_text(text: &str) -> bool {
    text.split(|ch: char| ch.is_whitespace() || matches!(ch, '(' | ','))
        .any(|token| {
            let Some(marker) = token.strip_prefix("<<") else {
                return false;
            };
            let marker = marker
                .strip_prefix('-')
                .or_else(|| marker.strip_prefix('~'))
                .unwrap_or(marker);
            let mut chars = marker.chars();
            let Some(first) = chars.next() else {
                return false;
            };
            first == '_' || first.is_ascii_alphabetic()
        })
}

impl<'source> TreeSitterNormalizer<'source> {
    pub(in crate::ast) fn with_dynamic_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
        self.with_ruby_scope(node, reset, f)
    }

    pub(in crate::ast) fn dynamic_vcall_identifier(
        &self,
        node: TreeSitterNode<'_>,
        name: &str,
    ) -> bool {
        self.ruby_vcall_identifier(node, name)
    }

    pub(in crate::ast) fn dynamic_local_name(&self, name: &str) -> bool {
        self.ruby_local_name(name)
    }

    pub(in crate::ast) fn dynamic_syntax_enabled(&self) -> bool {
        self.ruby()
    }

    pub(crate) fn with_ruby_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
        if !self.ruby() {
            return f(self);
        }
        let previous = self.local_stack.clone();
        if reset {
            self.local_stack.clear();
        }
        self.local_stack.push(self.ruby_scope_locals(node));
        let result = f(self);
        self.local_stack = previous;
        result
    }

    pub(crate) fn ruby_vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        self.ruby()
            && self.identifier_kind(node.kind())
            && !self.assignment_lhs(node)
            && !self.ruby_definition_identifier(node)
            && !self.ruby_local_name(name)
    }

    pub(crate) fn ruby_local_name(&self, name: &str) -> bool {
        self.local_stack
            .iter()
            .rev()
            .any(|scope| scope.contains(name))
    }

    pub(crate) fn ruby(&self) -> bool {
        self.normalization_adapter.tracks_dynamic_local_scope()
    }

    pub(crate) fn ruby_scope_locals(&self, node: TreeSitterNode<'_>) -> BTreeSet<String> {
        let mut locals = BTreeSet::new();
        self.collect_ruby_scope_locals(node, &mut locals, true);
        locals
    }

    pub(crate) fn collect_ruby_scope_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
        root: bool,
    ) {
        if !root && self.ruby_scope_boundary(node) {
            return;
        }
        self.collect_ruby_parameter_locals(node, locals);
        self.collect_ruby_assignment_locals(node, locals);
        for child in self.named_children(node) {
            if !self.ruby_scope_child_boundary(child) {
                self.collect_ruby_scope_locals(child, locals, false);
            }
        }
    }

    pub(crate) fn collect_ruby_parameter_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if !matches!(
            node.kind(),
            "method_parameters" | "block_parameters" | "lambda_parameters"
        ) {
            return;
        }

        for child in self.named_children(node) {
            self.collect_identifier_names(child, locals);
        }
    }

    pub(crate) fn collect_ruby_assignment_locals(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if node.kind() == "exception_variable" {
            self.collect_identifier_names(node, locals);
            return;
        }

        if !self.ruby_assignment_node(node) {
            return;
        }

        if let Some(left) = self.assignment_left(node) {
            self.collect_assignment_target_names(left, locals);
        }
    }

    pub(crate) fn collect_assignment_target_names(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if let Some(name) = self.identifier_text(node) {
            locals.insert(name);
            return;
        }
        if matches!(
            node.kind(),
            "left_assignment_list"
                | "expression_list"
                | "splat"
                | "splat_parameter"
                | "rest_assignment"
        ) {
            for child in self.named_children(node) {
                self.collect_assignment_target_names(child, locals);
            }
        }
    }

    pub(crate) fn collect_identifier_names(
        &self,
        node: TreeSitterNode<'_>,
        locals: &mut BTreeSet<String>,
    ) {
        if let Some(name) = self.identifier_text(node) {
            locals.insert(name);
        }
        for child in self.raw_named_children(node) {
            self.collect_identifier_names(child, locals);
        }
    }

    pub(crate) fn ruby_scope_boundary(&self, node: TreeSitterNode<'_>) -> bool {
        if matches!(node.kind(), "block" | "do_block")
            && node
                .parent()
                .map(|parent| parent.kind() == "lambda")
                .unwrap_or(false)
        {
            return false;
        }
        matches!(
            node.kind(),
            "singleton_class" | "lambda" | "block" | "do_block"
        ) || self.function_kind(node.kind())
            || self.class_node(node)
            || self.module_node(node)
    }

    pub(crate) fn ruby_scope_child_boundary(&self, node: TreeSitterNode<'_>) -> bool {
        self.ruby_scope_boundary(node)
    }

    pub(crate) fn ruby_definition_identifier(&self, node: TreeSitterNode<'_>) -> bool {
        let Some(parent) = self.parent_node(node) else {
            return false;
        };
        if matches!(parent.kind(), "method" | "singleton_method") {
            let name = self.named_field(parent, "name").or_else(|| {
                self.named_children(parent)
                    .into_iter()
                    .find(|child| self.identifier_kind(child.kind()))
            });
            return name
                .map(|name| self.same_ts_node(name, node))
                .unwrap_or(false);
        }
        matches!(
            parent.kind(),
            "method_parameters"
                | "block_parameters"
                | "lambda_parameters"
                | "optional_parameter"
                | "keyword_parameter"
                | "block_parameter"
        )
    }

    pub(crate) fn ruby_assignment_node(&self, node: TreeSitterNode<'_>) -> bool {
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            return true;
        }
        if node.kind() == "pattern"
            && node
                .children(&mut node.walk())
                .any(|child| !child.is_named() && node_text(child, self.source) == "=")
        {
            return true;
        }
        let raw_named = self.raw_named_children(node);
        if node.kind() == "block_body"
            && raw_named.len() == 1
            && raw_named[0].kind() == "assignment"
        {
            return true;
        }

        matches!(node.kind(), "body_statement" | "block_body" | "statement")
            && self.has_assignment_operator_child(node)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::parser_grammar::grammar_for_language;
    use crate::syntax::Language;
    use tree_sitter::{Node as TreeSitterNode, Parser as TreeSitterParser};

    fn raw_tree(source: &str) -> tree_sitter::Tree {
        let mut parser = TreeSitterParser::new();
        parser
            .set_language(&grammar_for_language(Language::Ruby))
            .expect("set raw parser language");
        parser.parse(source, None).expect("parse raw source")
    }

    fn collect_all_nodes<'tree>(
        node: TreeSitterNode<'tree>,
        found: &mut Vec<TreeSitterNode<'tree>>,
    ) {
        found.push(node);
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            collect_all_nodes(child, found);
        }
    }

    #[test]
    fn ruby_ast_adapter_edge_cases() {
        let adapter = RubyAstAdapter;
        assert!(adapter.tracks_dynamic_local_scope());

        // yield_statement
        let tree = raw_tree("yield\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(yield_node) = nodes.iter().find(|n| n.kind() == "body_statement") {
            adapter.yield_statement(*yield_node, "yield\n");
        }

        // super_statement
        let tree = raw_tree("super\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(super_node) = nodes.iter().find(|n| n.kind() == "body_statement") {
            assert!(adapter.super_statement(*super_node, "super\n"));
        }

        let tree = raw_tree("super(a)\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(super_node) = nodes.iter().find(|n| n.kind() == "call") {
            adapter.super_statement(*super_node, "super(a)\n");
        }

        // elsif_parts
        let tree = raw_tree("if a; elsif b; end\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(elsif_node) = nodes.iter().find(|n| n.kind() == "elsif") {
            assert!(adapter.elsif_statement(*elsif_node, "if a; elsif b; end\n"));
            assert!(adapter
                .elsif_parts(*elsif_node, "if a; elsif b; end\n")
                .is_some());
        }
        assert!(adapter.elsif_parts(node, "if a; elsif b; end\n").is_none());

        // variables
        let tree = raw_tree("@x = 1\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(ivar_node) = nodes.iter().find(|n| n.kind() == "instance_variable") {
            assert!(adapter.instance_variable(*ivar_node, "@x = 1\n"));
        }

        let tree = raw_tree("$x = 1\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(gvar_node) = nodes.iter().find(|n| n.kind() == "global_variable") {
            assert!(adapter.global_variable(*gvar_node, "$x = 1\n"));
        }

        // dynamic matching
        assert!(adapter.dynamic_constant_pattern_text("Constant"));
        assert!(adapter.dynamic_exception_constant_text("StandardError"));
        assert!(adapter.dynamic_instance_variable_text("@ivar"));

        // case_argument_list
        let tree = raw_tree("case x; when 1; end\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(arg_node) = nodes.iter().find(|n| n.kind() == "argument_list") {
            adapter.case_argument_list(*arg_node, "case x; when 1; end\n");
        }

        // loop / conditional kind overrides
        assert_eq!(adapter.conditional_node_type("if"), Some("IF"));
        assert_eq!(adapter.conditional_node_type("unless"), Some("UNLESS"));
        assert_eq!(adapter.conditional_node_type("other"), None);
        assert_eq!(adapter.conditional_keyword_node_type("if"), Some("IF"));
        assert_eq!(
            adapter.conditional_keyword_node_type("unless"),
            Some("UNLESS")
        );
        assert_eq!(adapter.conditional_keyword_node_type("other"), None);
        assert_eq!(adapter.modifier_node_type("if"), Some("IF"));
        assert_eq!(adapter.modifier_node_type("unless"), Some("UNLESS"));
        assert_eq!(adapter.modifier_node_type("while"), Some("WHILE"));
        assert_eq!(adapter.modifier_node_type("until"), Some("UNTIL"));
        assert_eq!(adapter.modifier_node_type("other"), None);
        assert_eq!(adapter.loop_node_type("while"), Some("WHILE"));
        assert_eq!(adapter.loop_node_type("until_modifier"), Some("UNTIL"));
        assert_eq!(adapter.loop_node_type("for"), Some("FOR"));
        assert_eq!(adapter.loop_node_type("other"), None);
        assert!(adapter.modifier_loop_kind("while_modifier"));
        assert!(adapter.conditional_branch_skip_kind("elsif"));
        assert!(adapter.branch_child_skip_kind("elsif"));

        // rescue
        let tree = raw_tree("begin; a; rescue StandardError, CustomError => e; nil; end\n");
        let node = tree.root_node();
        let mut nodes = Vec::new();
        collect_all_nodes(node, &mut nodes);
        if let Some(rescue_node) = nodes.iter().find(|n| n.kind() == "rescue") {
            assert!(adapter.rescue_clause(*rescue_node));
            assert!(adapter.rescue_clause_handler(*rescue_node).is_some());
            assert!(!adapter
                .rescue_clause_exceptions(
                    *rescue_node,
                    "begin; a; rescue StandardError, CustomError => e; nil; end\n"
                )
                .is_empty());
        }
    }
}
