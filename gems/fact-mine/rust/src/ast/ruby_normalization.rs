use super::{exact_bare_identifier_text, function_kind, node_text, TreeSitterNormalizer};
use std::collections::BTreeSet;
use tree_sitter::Node as TreeSitterNode;

pub(crate) fn ruby_exception_constant_text(text: &str) -> bool {
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

pub(crate) fn ruby_constant_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_uppercase() && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

pub(crate) fn ruby_instance_variable_text(text: &str) -> bool {
    text.strip_prefix('@')
        .map(exact_bare_identifier_text)
        .unwrap_or(false)
}

pub(crate) fn ruby_variable_name_text(text: &str) -> bool {
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

pub(crate) fn dynamic_exception_constant_text(text: &str) -> bool {
    ruby_exception_constant_text(text)
}

pub(crate) fn dynamic_constant_pattern_text(text: &str) -> bool {
    ruby_constant_text(text)
}

pub(crate) fn dynamic_instance_variable_text(text: &str) -> bool {
    ruby_instance_variable_text(text)
}

impl<'source> TreeSitterNormalizer<'source> {
    pub(super) fn with_dynamic_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
        self.with_ruby_scope(node, reset, f)
    }

    pub(super) fn dynamic_vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        self.ruby_vcall_identifier(node, name)
    }

    pub(super) fn dynamic_local_name(&self, name: &str) -> bool {
        self.ruby_local_name(name)
    }

    pub(super) fn dynamic_syntax_enabled(&self) -> bool {
        self.ruby()
    }

    pub(super) fn with_ruby_scope<T>(
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

    pub(super) fn ruby_vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        self.ruby()
            && self.identifier_kind(node.kind())
            && !self.assignment_lhs(node)
            && !self.ruby_definition_identifier(node)
            && !self.ruby_local_name(name)
    }

    pub(super) fn ruby_local_name(&self, name: &str) -> bool {
        self.local_stack
            .iter()
            .rev()
            .any(|scope| scope.contains(name))
    }

    pub(super) fn ruby(&self) -> bool {
        self.normalization_adapter.ruby()
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
        ) || function_kind(node.kind())
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
