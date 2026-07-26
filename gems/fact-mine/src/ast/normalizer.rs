use super::adapters::{normalization_adapter, AstNormalizationAdapter, NamedChildrenAction};
use super::{
    bare_identifier_text, child_node, comparison_operator_from_text, dynamic_scope,
    exact_bare_identifier_text, exact_integer_text, identifier_kind_name, integer_text, kind_type,
    list_or_nil, literal_symbol_arguments, node, node_text, operator_assignment_statement_operator,
    optional_node, return_kind, return_statement_kind, span, Child, Node, Span, TernaryParts,
    COMPARISON_OPERATORS, OPERATOR_CALL_OPERATORS,
};
use crate::syntax::Language;
use std::cell::RefCell;
use std::collections::BTreeSet;
use tree_sitter::Node as TreeSitterNode;

fn normalized_call(node: &Node) -> bool {
    matches!(node.r#type.as_str(), "CALL" | "FCALL" | "QCALL" | "VCALL")
}

fn primary_normalized_call_span(node: &Node) -> Option<Span> {
    if normalized_call(node) {
        return Some([
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ]);
    }
    node.children.iter().find_map(|child| match child {
        Child::Node(child) => primary_normalized_call_span(child),
        Child::String(_) | Child::Symbol(_) | Child::Integer(_) | Child::Bool(_) | Child::Nil => {
            None
        }
    })
}

pub(in crate::ast) struct TreeSitterNormalizer<'source> {
    pub(in crate::ast) source: &'source str,
    #[allow(dead_code)]
    pub(in crate::ast) language: Language,
    pub(in crate::ast) normalization_adapter: &'static dyn AstNormalizationAdapter,
    pub(in crate::ast) local_stack: Vec<BTreeSet<String>>,
    pub(in crate::ast) root_span: Option<Span>,
    pub(in crate::ast) current_heredoc_body_span: Option<Span>,
    /// Parser-call identity belongs to this normalization run. Keeping it on
    /// the normalizer makes nested/re-entrant normalization explicit rather
    /// than relying on ambient thread-local state.
    pub(in crate::ast) parser_call_spans: BTreeSet<Span>,
    pub(in crate::ast) call_raw_origins: RefCell<Vec<(Span, Span)>>,
}

impl<'source> TreeSitterNormalizer<'source> {
    pub(in crate::ast) fn new(source: &'source str, language: Language) -> Self {
        Self {
            source,
            language,
            normalization_adapter: normalization_adapter(language),
            local_stack: Vec::new(),
            root_span: None,
            current_heredoc_body_span: None,
            parser_call_spans: BTreeSet::new(),
            call_raw_origins: RefCell::new(Vec::new()),
        }
    }

    pub(in crate::ast) fn normalize(self, root: TreeSitterNode<'_>) -> Node {
        self.normalize_with_call_origins(root).0
    }

    pub(in crate::ast) fn normalize_with_call_origins(
        mut self,
        root: TreeSitterNode<'_>,
    ) -> (Node, Vec<(Span, Span)>) {
        self.call_raw_origins.borrow_mut().clear();
        self.parser_call_spans = crate::ast::raw_call_sites(root, self.source, self.language)
            .into_iter()
            .map(|site| site.span)
            .collect();
        self.root_span = Some(span(root));
        let children = if self.dynamic_syntax_enabled() {
            self.with_dynamic_scope(root, true, |normalizer| normalizer.normalize_children(root))
        } else {
            self.normalize_children(root)
        };
        let root = self.wrap("ROOT", children, root);
        let mut origins = self.call_raw_origins.borrow().clone();
        origins.sort_unstable();
        origins.dedup();
        (root, origins)
    }

    pub(in crate::ast) fn normalize_node(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if node.kind() == "comment" {
            return None;
        }
        if let Some(name) = self
            .normalization_adapter
            .local_binding_name(node, self.source)
        {
            return Some(self.wrap("LASGN", vec![Child::String(name), Child::Nil], node));
        }
        if self.assignment_lhs(node) {
            return self.normalize_assignment_lhs(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.leading_function_statement(node) {
            return self.normalize_leading_function_statement(node);
        }
        if self.leading_owner_statement(node) {
            return self.normalize_leading_owner_statement(node);
        }
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if self.elsif_statement(node) {
            return Some(self.normalize_elsif(node));
        }
        if self.ensure_body_statement(node) {
            return self.normalize_ensure_body_statement(node);
        }
        if self.rescue_body_statement(node) {
            return self.normalize_rescue_body_statement(node);
        }
        if self.if_node_kind(node.kind()) {
            return self.normalize_if(node);
        }
        if self.leading_case_statement(node) {
            return self.normalize_leading_case_statement(node);
        }
        if self.special_statement(node) {
            return self.normalize_special_statement(node);
        }
        if self.leading_loop_statement(node) {
            return self.normalize_leading_loop_statement(node);
        }
        if let Some(loop_type) = self.loop_node_type(node.kind()) {
            return self.normalize_loop(node, loop_type);
        }
        if self.case_kind(node.kind()) || self.hidden_match(node) {
            return self.normalize_case(node);
        }
        if self.hash_literal_statement(node) {
            return self.normalize_hash_literal_statement(node);
        }
        if self.array_literal_statement(node) {
            return self.normalize_array_literal_statement(node);
        }
        if self.element_reference_statement(node) {
            return self.normalize_element_reference_statement(node);
        }
        if self.concatenated_string_statement(node) {
            return Some(self.normalize_concatenated_string_statement(node));
        }
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.wrapped_return_statement(node) {
            return self.normalize_wrapped_return_statement(node);
        }
        if self.heredoc_body_statement(node) {
            return self.normalize_heredoc_body_statement(node);
        }
        if self.empty_body_statement(node) {
            return None;
        }
        if self.terminal_statement(node) {
            return Some(self.normalize_terminal_statement(node));
        }
        if self.modifier_statement(node) {
            return self.normalize_modifier_statement(node);
        }
        if self.statement_call_with_block(node) {
            return self.normalize_statement_call_with_block(node);
        }
        if self.super_statement(node) {
            return Some(self.normalize_super_statement(node));
        }
        if self.command_call_statement(node) {
            return self.normalize_command_call_statement(node);
        }
        if let Some(target) = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
        {
            if !self.same_ts_node(target, node) {
                return self.normalize_call(target);
            }
        }
        if self.yield_statement(node) {
            return Some(self.normalize_yield_statement(node));
        }
        if self.yield_argument_list(node) {
            return Some(self.normalize_yield_argument_list(node));
        }
        if self.unary_not_statement(node) {
            return self.normalize_unary_not_statement(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.unary_minus_expression(node) {
            return self.normalize_unary_minus(node);
        }
        if self.unary_not_expression(node) {
            return self.normalize_unary_not(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.operator_call_expression(node) {
            return self.normalize_operator_call(node);
        }
        if self.comparison_expression(node) {
            return self.normalize_comparison(node);
        }
        if self.self_node(node) {
            return Some(self.wrap("SELF", Vec::new(), node));
        }
        if self.instance_variable(node) {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(node, self.source).to_string())],
                node,
            ));
        }
        if self.global_variable(node) {
            return Some(self.normalize_global_variable(node));
        }
        if self.self_identifier(node) {
            return Some(self.wrap("SELF", Vec::new(), node));
        }
        if let Some(name) = self
            .normalization_adapter
            .direct_state_identifier(node, self.source)
        {
            if !self.dynamic_local_name(&name) {
                return Some(self.wrap("IVAR", vec![Child::String(name)], node));
            }
        }
        if let Some(name) = self
            .normalization_adapter
            .local_identifier_text(node, self.source)
        {
            return Some(self.normalize_identifier_with_name(node, name));
        }
        if let Some(name) = self
            .normalization_adapter
            .constant_identifier_text(node, self.source)
        {
            return Some(self.wrap("CONST", vec![Child::Symbol(name)], node));
        }
        if self.class_node(node) {
            return self.normalize_class(node);
        }
        if self.module_node(node) {
            return self.normalize_module(node);
        }
        if self.class_like_owner_kind(node.kind()) {
            return self.normalize_class_like_owner(node);
        }
        if self.lambda_expression(node) {
            return self.normalize_lambda(node);
        }
        if self.singleton_function_kind(node.kind()) {
            return self.normalize_singleton_function(node);
        }
        if self
            .normalization_adapter
            .ensure_clause_statement(node, self.source)
        {
            return self.normalize_ensure_clause(node);
        }
        if self
            .normalization_adapter
            .begin_statement(node, self.source)
        {
            return self.normalize_begin(node);
        }
        if self
            .normalization_adapter
            .rescue_modifier_statement(node, self.source)
        {
            return self.normalize_rescue_modifier(node);
        }

        if self.normalization_adapter.check_node_role(node, "root") {
            let children = self.normalize_children(node);
            return Some(self.wrap("ROOT", children, node));
        }
        if self.normalization_adapter.check_node_role(node, "function") {
            // A language adapter can reject a tree-sitter error-recovery
            // node that only resembles a function definition. Do not drop
            // its descendants: a malformed outer region can still contain
            // valid declarations which remain useful to every consumer.
            if !self
                .normalization_adapter
                .valid_function_definition(node, self.source)
            {
                let children = self.normalize_children(node);
                return Some(self.wrap(&kind_type(node.kind()), children, node));
            }
            return self.normalize_function(node);
        }
        if self.block_kind(node.kind()) {
            let children = self.normalize_children(node);
            return Some(self.wrap("BLOCK", children, node));
        }
        if self.normalization_adapter.check_node_role(node, "subshell") {
            return Some(self.normalize_subshell(node));
        }
        if self.block_pass_argument(node) {
            return self.normalize_block_argument(node);
        }
        if self.singleton_class_node(node) {
            return self.normalize_singleton_class(node);
        }
        if self.normalization_adapter.check_node_role(node, "yield") {
            return Some(self.normalize_yield(node));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "operator_assignment")
        {
            return self.normalize_operator_assignment(node);
        }
        if self
            .normalization_adapter
            .check_node_role(node, "assignment")
        {
            return self.normalize_assignment(node);
        }
        if self
            .normalization_adapter
            .check_node_role(node, "variable_declarator")
        {
            if self.assignment_right(node).is_none() {
                return Some(self.wrap(&kind_type(node.kind()), Vec::new(), node));
            }
            let assignment = self.normalize_assignment(node)?;
            return Some(self.wrap(
                &kind_type(node.kind()),
                vec![Child::Node(Box::new(assignment))],
                node,
            ));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "expression_list")
            && self.single_short_var_lhs(node)
        {
            // `x := expr` declares a local: expose the write and its value
            // source so dataflow facts see the binding.
            let target = self.named_children(node).into_iter().next()?;
            let right = node
                .next_named_sibling()
                .map(|rhs| {
                    let named = self.named_children(rhs);
                    if named.len() == 1 {
                        named[0]
                    } else {
                        rhs
                    }
                })
                .and_then(|child| self.normalize_node(child));
            let source = node.parent().unwrap_or(node);
            return Some(self.wrap(
                "LASGN",
                vec![
                    Child::String(self.target_name(target)),
                    optional_node(right),
                ],
                source,
            ));
        }
        if self.call_node(node) {
            return self.normalize_call(node);
        }
        if self.member_read_node(node) {
            return self.normalize_member_read(node);
        }
        if self.unwrap_node(node) {
            return self
                .named_children(node)
                .into_iter()
                .next()
                .and_then(|child| self.normalize_node(child));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "element_reference")
        {
            return self.normalize_element_reference(node);
        }
        if self.normalization_adapter.check_node_role(node, "super") {
            return Some(self.normalize_super(node));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "return_or_break")
        {
            return self.normalize_return(node);
        }
        if self
            .normalization_adapter
            .absence_literal(node, self.source)
        {
            return Some(self.wrap("NIL", Vec::new(), node));
        }
        if self.normalization_adapter.check_node_role(node, "true") {
            return Some(self.wrap("TRUE", Vec::new(), node));
        }
        if self.normalization_adapter.check_node_role(node, "false") {
            return Some(self.wrap("FALSE", Vec::new(), node));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "identifier")
        {
            return Some(self.normalize_identifier(node));
        }
        if self.normalization_adapter.check_node_role(node, "constant") {
            return Some(self.normalize_const(node));
        }
        if self
            .normalization_adapter
            .check_node_role(node, "self_or_this")
        {
            return Some(self.wrap("SELF", Vec::new(), node));
        }
        if self.normalization_adapter.check_node_role(node, "array") {
            return Some(self.normalize_array_literal(node));
        }
        if self.interpolation_node(node) {
            return self.normalize_interpolation(node);
        }
        if self.heredoc_start_node(node) {
            return Some(self.normalize_heredoc_beginning(node));
        }
        if self.concatenated_string_node(node) {
            return Some(self.normalize_chained_string(node));
        }
        if self.normalization_adapter.check_node_role(node, "string") {
            if self.interpolated_string(node) {
                return Some(self.normalize_interpolated_string(node));
            } else if let Some(content) = self.no_paren_string_argument_content(node) {
                return Some(self.wrap(
                    "STR",
                    vec![Child::String(node_text(content, self.source).to_string())],
                    content,
                ));
            } else {
                return Some(self.wrap(
                    "STR",
                    vec![Child::String(node_text(node, self.source).to_string())],
                    node,
                ));
            }
        }
        if self.normalization_adapter.check_node_role(node, "integer") {
            return Some(self.wrap("INTEGER", Vec::new(), node));
        }
        if self.normalization_adapter.check_node_role(node, "float") {
            return Some(self.wrap("FLOAT", Vec::new(), node));
        }
        if self.normalization_adapter.check_node_role(node, "pair") {
            return self.normalize_pair(node);
        }
        if self.normalization_adapter.check_node_role(node, "symbol") {
            return Some(self.wrap(
                "LIT",
                vec![Child::Symbol(
                    node_text(node, self.source).trim_start_matches(':').to_string(),
                )],
                node,
            ));
        }

        let children = self.normalize_children(node);
        Some(self.wrap(&kind_type(node.kind()), children, node))
    }

    pub(in crate::ast) fn normalize_function(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self.singleton_function_kind(node.kind()) {
            return self.normalize_singleton_function(node);
        }

        if !self
            .normalization_adapter
            .valid_function_definition(node, self.source)
        {
            return None;
        }

        let name = self.function_name(node)?;
        let args = self.normalize_function_parameters(node);
        let body = self.with_dynamic_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))
                .or_else(|| {
                    normalizer
                        .normalization_adapter
                        .function_body(node, normalizer.source)
                })?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
            let body = normalizer.prepend_inline_parameter_begin(node, body);
            normalizer.elide_implicit_nil_body(body)
        });
        let scope = self.scope(body, args, node);
        let declaration_node = self
            .normalization_adapter
            .function_declaration_node(node, self.source);
        Some(self.wrap(
            "DEFN",
            vec![Child::Symbol(name), Child::Node(Box::new(scope))],
            declaration_node,
        ))
    }

    pub(in crate::ast) fn normalize_leading_function_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.leading_function_target(node)?;
        if self.function_kind(target.kind()) {
            return self.normalize_function(target);
        }
        let name = self
            .leading_function_name(target)
            .map(|name| node_text(name, self.source).to_string())?;
        let body_node = self.leading_function_body(target);
        let body = self.with_dynamic_scope(target, true, |normalizer| {
            let body = body_node.and_then(|body| normalizer.normalize_body(body));
            normalizer.elide_tail_returns(body)
        });
        Some(self.wrap(
            "DEFN",
            vec![
                Child::Symbol(name),
                Child::Node(Box::new(self.scope(body, None, target))),
            ],
            target,
        ))
    }

    pub(in crate::ast) fn normalize_singleton_function(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let name = self.function_name(node)?;
        let receiver = self
            .singleton_receiver(node)
            .and_then(|child| self.normalize_node(child))
            .unwrap_or_else(|| self.wrap("SELF", Vec::new(), node));
        let args = self.normalize_function_parameters(node);
        let body = self.with_dynamic_scope(node, true, |normalizer| {
            let body_node = normalizer
                .named_field(node, "body")
                .or_else(|| normalizer.block_child(node))?;
            let body = normalizer.normalize_body(body_node);
            let body = normalizer.elide_tail_returns(body);
            let body = normalizer.prepend_inline_parameter_begin(node, body);
            normalizer.elide_implicit_nil_body(body)
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "DEFS",
            vec![
                Child::Node(Box::new(receiver)),
                Child::Symbol(name),
                Child::Node(Box::new(scope)),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_class(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.const_for(
            self.named_field(node, "name")
                .or_else(|| self.first_named(node)),
            node,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        let body = self.with_supplementary_class_body(node, body);
        Some(self.wrap(
            "CLASS",
            vec![
                Child::Node(Box::new(name)),
                Child::Nil,
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    /// Splices `supplementary_class_body_nodes` (normalized individually)
    /// into `body`'s children, or creates a body from just those nodes if
    /// there was none. A no-op whenever the hook returns nothing, which is
    /// every language except the ones that override it.
    fn with_supplementary_class_body(
        &mut self,
        node: TreeSitterNode<'_>,
        body: Option<Node>,
    ) -> Option<Node> {
        let extra = self
            .normalization_adapter
            .supplementary_class_body_nodes(node, self.source);
        if extra.is_empty() {
            return body;
        }
        let mut children: Vec<Child> = extra
            .into_iter()
            .filter_map(|extra_node| self.normalize_node(extra_node))
            .map(|extra_node| Child::Node(Box::new(extra_node)))
            .collect();
        // `body` may come back as a bare single-statement node rather than
        // a container (normalize_body elides the wrapper when the body has
        // exactly one statement) - always build a fresh BLOCK around it
        // rather than mutating its children directly, or the extra nodes
        // end up nested *inside* that one statement (e.g. as if they were
        // part of a function's own body) instead of alongside it.
        if let Some(existing) = body {
            children.insert(0, Child::Node(Box::new(existing)));
        }
        Some(self.wrap("BLOCK", children, node))
    }

    pub(in crate::ast) fn normalize_class_like_owner(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let type_node = self
            .normalization_adapter
            .class_like_owner_name(node, self.source);
        let name = self.const_for(type_node, node);
        let body = self
            .normalization_adapter
            .class_like_owner_body(node, self.source)
            .and_then(|body| self.normalize_body(body));
        Some(self.wrap(
            "CLASS",
            vec![
                Child::Node(Box::new(name)),
                Child::Nil,
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_nested_class_as_iter(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let name_node = self
            .named_field(node, "name")
            .or_else(|| self.first_named(node))?;
        let name = node_text(name_node, self.source).to_string();
        let header_end = node
            .children(&mut node.walk())
            .find(|child| !child.is_named() && node_text(*child, self.source) == ":")
            .unwrap_or(name_node);
        let call = self.wrap_from_nodes(
            "VCALL",
            vec![Child::Symbol(name), Child::Nil],
            node,
            header_end,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        let scope = self.scope(body, None, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_module(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let name = self.const_for(
            self.named_field(node, "name")
                .or_else(|| self.first_named(node)),
            node,
        );
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node))
            .and_then(|body| self.normalize_body(body));
        Some(self.wrap(
            "MODULE",
            vec![
                Child::Node(Box::new(name)),
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_singleton_class(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let named = self.named_children(node);
        let receiver = named
            .first()
            .and_then(|receiver| self.normalize_node(*receiver));
        let body = named.get(1).and_then(|body| self.normalize_body(*body));
        Some(self.wrap(
            "SCLASS",
            vec![
                optional_node(receiver),
                Child::Node(Box::new(self.scope(body, None, node))),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_lambda(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let target = self.lambda_target(node).unwrap_or(node);
        let args = self.normalize_block_parameters(Some(target));
        let body_node = self
            .named_field(target, "body")
            .or_else(|| self.block_child(target))
            .or_else(|| self.named_children(target).into_iter().last())?;
        let body = self.with_dynamic_scope(target, false, |normalizer| {
            normalizer
                .normalize_body(body_node)
                .map(|node| normalizer.normalize_dynamic_scope(node))
        });
        let scope = self.scope(body, args, target);
        Some(self.wrap("LAMBDA", vec![Child::Node(Box::new(scope))], target))
    }

    pub(in crate::ast) fn normalize_yield(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_else(|| self.yield_inline_arguments(node));
        self.wrap(
            "YIELD",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    pub(in crate::ast) fn normalize_yield_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_else(|| self.yield_inline_arguments(node));
        self.wrap(
            "YIELD",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    pub(in crate::ast) fn normalize_yield_argument_list(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Node {
        let args = self.yield_argument_nodes(node);
        let source = self.parent_node(node).unwrap_or(node);
        self.wrap("YIELD", vec![list_or_nil(args, node, self)], source)
    }

    pub(in crate::ast) fn normalize_super_statement(&mut self, node: TreeSitterNode<'_>) -> Node {
        let raw = self.raw_named_children(node);
        let children =
            if raw.len() == 1 && self.normalization_adapter.check_node_role(raw[0], "call") {
                self.raw_named_children(raw[0])
            } else {
                raw
            };
        let args_node = children.into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| self.yield_argument_nodes(args))
            .unwrap_or_default();
        self.wrap(
            "SUPER",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    pub(in crate::ast) fn normalize_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(child) = self
            .normalization_adapter
            .nested_class_body_child(node, self.source)
        {
            return self.normalize_nested_class_as_iter(child);
        }
        if self.leading_function_statement(node) {
            return self.normalize_leading_function_statement(node);
        }
        if self.leading_owner_statement(node) {
            return self.normalize_leading_owner_statement(node);
        }
        if self.leading_if_statement(node) {
            return self.normalize_leading_if_statement(node);
        }
        if self.elsif_statement(node) {
            return Some(self.normalize_elsif(node));
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.if_node_kind(node.kind()) {
            return self.normalize_if(node);
        }
        if self.leading_case_statement(node) {
            return self.normalize_leading_case_statement(node);
        }
        if self.special_statement(node) {
            return self.normalize_special_statement(node);
        }
        if self.leading_loop_statement(node) {
            return self.normalize_leading_loop_statement(node);
        }
        if self.ensure_body_statement(node) {
            return self.normalize_ensure_body_statement(node);
        }
        if self.rescue_body_statement(node) {
            return self.normalize_rescue_body_statement(node);
        }
        if self.hash_literal_statement(node) {
            return self.normalize_hash_literal_statement(node);
        }
        if self.array_literal_statement(node) {
            return self.normalize_array_literal_statement(node);
        }
        if self.element_reference_statement(node) {
            return self.normalize_element_reference_statement(node);
        }
        if self.interpolated_statement(node) {
            return Some(self.normalize_interpolated_statement(node));
        }
        if self.wrapped_return_statement(node) {
            return self.normalize_wrapped_return_statement(node);
        }
        if self.heredoc_body_statement(node) {
            return self.normalize_heredoc_body_statement(node);
        }
        if self.empty_body_statement(node) {
            return None;
        }
        if self.modifier_statement(node) {
            return self.normalize_modifier_statement(node);
        }
        if self.statement_call_with_block(node) {
            return self.normalize_statement_call_with_block(node);
        }
        if self.command_call_statement(node) {
            return self.normalize_command_call_statement(node);
        }
        if self.yield_statement(node) {
            return Some(self.normalize_yield_statement(node));
        }
        if self.unary_not_statement(node) {
            return self.normalize_unary_not_statement(node);
        }
        if self.operator_assignment_statement(node) {
            return self.normalize_operator_assignment_statement(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.unary_minus_expression(node) {
            return self.normalize_unary_minus(node);
        }
        if self.argument_list_unary_not(node) {
            return self.normalize_argument_list_unary_not(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.block_kind(node.kind()) {
            let children = self.normalize_children(node);
            if children.is_empty() {
                let text = node_text(node, self.source).trim();
                if bare_identifier_text(text) {
                    return Some(self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node));
                }
                return None;
            }
            if children.len() == 1 {
                return child_node(children.into_iter().next().unwrap());
            }

            return Some(self.wrap("BLOCK", children, node));
        }

        self.normalize_node(node)
    }

    fn normalize_control_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self.normalization_adapter.cfg_control_body_wrapper(node) {
            let nodes = self.named_children(node);
            let source = nodes.first().copied().unwrap_or(node);
            self.normalize_body_nodes(nodes, source)
        } else {
            self.normalize_body(node)
        }
    }

    pub(in crate::ast) fn normalize_if(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        if self
            .normalization_adapter
            .conditional_modifier_kind(node.kind())
        {
            let named = self.named_children(node);
            let action = *named.first()?;
            let condition = *named.get(1)?;
            let node_type = self
                .normalization_adapter
                .conditional_node_type(node.kind())
                .unwrap_or("IF");
            let condition = optional_node(self.normalize_node(condition));
            let action = optional_node(self.normalize_modifier_action(action));
            return Some(self.wrap(node_type, vec![condition, action, Child::Nil], node));
        }

        let condition_raw = self
            .named_field(node, "condition")
            .or_else(|| self.named_field(node, "predicate"))
            .or_else(|| self.first_named(node))?;
        let condition = self.normalize_node(condition_raw);
        let condition = if let Some(initializer) = self
            .normalization_adapter
            .if_initializer(node, self.source)
            .and_then(|initializer| self.normalize_node(initializer))
        {
            Some(self.wrap(
                "BEGIN",
                vec![Child::Node(Box::new(initializer)), optional_node(condition)],
                node,
            ))
        } else {
            condition
        };
        let condition = optional_node(condition);
        let positive_raw = self
            .named_field(node, "consequence")
            .or_else(|| self.named_field(node, "body"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| self.normalization_adapter.check_node_role(*child, "then"))
            })
            .or_else(|| self.branch_child(node, condition_raw, 0));
        let negative_raw = self
            .named_field(node, "alternative")
            .or_else(|| self.explicit_alternative(node))
            .or_else(|| {
                if self.dynamic_syntax_enabled() {
                    None
                } else {
                    self.branch_child(node, condition_raw, 1)
                }
            });
        let positive = optional_node(positive_raw.and_then(|child| self.normalize_body(child)));
        let negative =
            optional_node(negative_raw.and_then(|child| self.normalize_else_or_branch(child)));
        let node_type = self
            .normalization_adapter
            .conditional_node_type(node.kind())
            .unwrap_or("IF");
        Some(self.wrap(node_type, vec![condition, positive, negative], node))
    }

    pub(in crate::ast) fn normalize_elsif(&mut self, node: TreeSitterNode<'_>) -> Node {
        let Some(parts) = self.normalization_adapter.elsif_parts(node, self.source) else {
            return self.wrap("IF", Vec::new(), node);
        };
        let condition = optional_node(self.normalize_node(parts.condition));
        let positive = optional_node(parts.positive.and_then(|child| self.normalize_body(child)));
        let negative = optional_node(
            parts
                .negative
                .and_then(|child| self.normalize_else_or_branch(child)),
        );

        self.wrap("IF", vec![condition, positive, negative], node)
    }

    pub(in crate::ast) fn normalize_loop(
        &mut self,
        node: TreeSitterNode<'_>,
        node_type: &str,
    ) -> Option<Node> {
        if self.modifier_loop_kind(node.kind()) {
            let named = self.named_children(node);
            let action = *named.first()?;
            let condition = *named.get(1)?;
            let condition = optional_node(self.normalize_node(condition));
            let action = optional_node(self.normalize_modifier_action(action));
            return Some(self.wrap(node_type, vec![condition, action, Child::Bool(true)], node));
        }

        let condition = self
            .normalization_adapter
            .loop_condition_node(node, self.source)
            .or_else(|| self.named_field(node, "condition"))
            .or_else(|| self.first_named(node));
        let body = self
            .named_field(node, "body")
            .or_else(|| self.named_field(node, "consequence"))
            .or_else(|| self.block_child(node));
        let condition =
            optional_node(condition.and_then(|condition| self.normalize_node(condition)));
        let body = optional_node(body.and_then(|body| self.normalize_control_body(body)));
        Some(self.wrap(node_type, vec![condition, body], node))
    }

    pub(in crate::ast) fn normalize_else_or_branch(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if let Some(block) = self.normalization_adapter.else_if_block(node, self.source) {
            if let Some(normalized) = self.normalize_else_if_block_child(block) {
                return Some(self.wrap(
                    "ELSE_CLAUSE",
                    vec![Child::Node(Box::new(normalized))],
                    node,
                ));
            }
        }
        if let Some(nodes) = self
            .normalization_adapter
            .else_body_nodes(node, self.source)
        {
            let body = self.normalize_body_nodes(nodes, node);
            let children = body
                .map(|node| vec![Child::Node(Box::new(node))])
                .unwrap_or_default();
            return Some(self.wrap(&kind_type(node.kind()), children, node));
        }
        if !self.normalization_adapter.check_node_role(node, "else") {
            return self.normalize_body(node);
        }
        if let Some(call) = self.single_dotted_else_body(node) {
            let trailing = self
                .source
                .get(call.end_byte()..node.end_byte())
                .unwrap_or("")
                .trim();
            if trailing.is_empty() {
                return self.normalize_node(call);
            }
        }
        self.normalize_body_nodes(self.named_children(node), node)
    }

    pub(in crate::ast) fn normalize_else_if_block_child(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let statements = self
            .raw_named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if statements.len() != 1
            || !self
                .normalization_adapter
                .check_node_role(statements[0], "if_statement")
        {
            return None;
        }
        let if_node = statements[0];
        self.normalize_if(if_node)
    }

    pub(in crate::ast) fn normalize_case(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let value_raw = self.case_value(node);
        let value = value_raw.and_then(|value| self.normalize_node(value));
        let whens = self
            .case_arms(node)
            .into_iter()
            .filter_map(|arm| self.normalize_when(arm))
            .collect::<Vec<_>>();
        let fallback = self.case_else_body(node);
        let chain = self.link_when_chain(whens, fallback);
        if value_raw.is_none() {
            Some(self.wrap("CASE2", vec![optional_node(chain)], node))
        } else {
            Some(self.wrap(
                "CASE",
                vec![optional_node(value), optional_node(chain)],
                node,
            ))
        }
    }

    pub(in crate::ast) fn normalize_when(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let patterns = self.normalize_patterns(node);
        let body = if let Some(body_nodes) = self
            .normalization_adapter
            .case_arm_body_nodes(node, self.source)
        {
            body_nodes
                .first()
                .copied()
                .and_then(|source| self.normalize_body_nodes(body_nodes, source))
        } else {
            self.when_body(node)
                .and_then(|body| self.normalize_body(body))
        };
        Some(self.wrap(
            "WHEN",
            vec![
                list_or_nil(patterns, node, self),
                optional_node(body),
                Child::Nil,
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_patterns(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        let mut patterns = self
            .normalization_adapter
            .case_arm_pattern_nodes(node, self.source)
            .unwrap_or_else(|| {
                self.raw_named_children(node)
                    .into_iter()
                    .filter(|child| {
                        self.normalization_adapter
                            .is_pattern_node_kind(child.kind())
                    })
                    .collect::<Vec<_>>()
            });
        if patterns.is_empty() {
            if let Some(value) = self.named_field(node, "value") {
                patterns.push(value);
            }
        }
        if patterns.is_empty() {
            if let Some(pattern) = self
                .named_children(node)
                .into_iter()
                .find(|child| !self.block_kind(child.kind()) && !self.statement_node(child.kind()))
            {
                patterns.push(pattern);
            }
        }

        let mut normalized = Vec::new();
        for pattern in patterns {
            let pattern_text = node_text(pattern, self.source).to_string();
            let pattern_wrapper = self
                .normalization_adapter
                .is_pattern_wrapper_kind(pattern.kind());
            let pattern_children = self.named_children(pattern);
            if pattern_text.contains("::") {
                normalized.push(self.wrap("CONST", vec![Child::Symbol(pattern_text)], pattern));
            } else if pattern_wrapper && pattern_children.is_empty() && integer_text(&pattern_text)
            {
                normalized.push(self.wrap("INTEGER", Vec::new(), pattern));
            } else if self.dynamic_syntax_enabled()
                && pattern_wrapper
                && pattern_children.is_empty()
                && self
                    .normalization_adapter
                    .dynamic_constant_pattern_text(&pattern_text)
            {
                normalized.push(self.wrap("CONST", vec![Child::Symbol(pattern_text)], pattern));
            } else if self.dynamic_syntax_enabled()
                && pattern_wrapper
                && pattern_children.is_empty()
                && bare_identifier_text(&pattern_text)
            {
                normalized.push(self.local_or_call_for_name(&pattern_text, pattern));
            } else if pattern_wrapper {
                normalized.extend(
                    pattern_children
                        .into_iter()
                        .filter_map(|child| self.normalize_node(child)),
                );
            } else if let Some(pattern) = self.normalize_node(pattern) {
                normalized.push(pattern);
            }
        }
        normalized
    }

    pub(in crate::ast) fn link_when_chain(
        &self,
        whens: Vec<Node>,
        fallback: Option<Node>,
    ) -> Option<Node> {
        whens
            .into_iter()
            .rev()
            .fold(fallback, |next_when, mut current| {
                while current.children.len() <= 2 {
                    current.children.push(Child::Nil);
                }
                current.children[2] = optional_node(next_when);
                Some(current)
            })
    }

    pub(in crate::ast) fn case_else_body(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let else_node = self
            .normalization_adapter
            .case_else_node(node, self.source)?;
        if self
            .normalization_adapter
            .case_else_arm(else_node, self.source)
            || self
                .normalization_adapter
                .check_node_role(else_node, "switch_default")
        {
            if let Some(body_nodes) = self
                .normalization_adapter
                .case_arm_body_nodes(else_node, self.source)
            {
                return body_nodes
                    .first()
                    .copied()
                    .and_then(|source| self.normalize_body_nodes(body_nodes, source));
            }
            if let Some(body) = self.when_body(else_node) {
                return self.normalize_body(body);
            }
        }
        self.normalize_else_or_branch(else_node)
    }

    pub(in crate::ast) fn normalize_body_nodes(
        &mut self,
        nodes: Vec<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let mut children = Vec::new();
        let mut index = 0;
        while index < nodes.len() {
            if index + 1 < nodes.len() {
                if let Some(call) = self.normalize_flat_dotted_nodes(&nodes[index..=index + 1]) {
                    children.push(Child::Node(Box::new(call)));
                    index += 2;
                    continue;
                }
            }
            if let Some(child) = self.normalize_body(nodes[index]) {
                children.push(Child::Node(Box::new(child)));
            }
            index += 1;
        }
        if children.is_empty() {
            None
        } else if children.len() == 1 {
            child_node(children.into_iter().next().unwrap())
        } else {
            Some(self.wrap("BLOCK", children, source))
        }
    }

    pub(in crate::ast) fn normalize_return(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        self.normalize_return_node(node)
    }

    pub(in crate::ast) fn normalize_super(&mut self, node: TreeSitterNode<'_>) -> Node {
        let args_node = self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| {
                self.named_children(args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.wrap(
            "SUPER",
            vec![list_or_nil(args, args_node.unwrap_or(node), self)],
            node,
        )
    }

    pub(in crate::ast) fn normalize_return_node(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        self.normalize_return_node_with_elide_symbol(node, false)
    }

    pub(in crate::ast) fn normalize_return_node_with_elide_symbol(
        &mut self,
        node: TreeSitterNode<'_>,
        elide_symbol: bool,
    ) -> Option<Node> {
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_return_value(child))
            .collect::<Vec<_>>();
        if elide_symbol
            && self.dynamic_syntax_enabled()
            && children.len() == 1
            && self.symbol_literal_node(children.first())
        {
            return children.into_iter().next();
        }
        let children = children
            .into_iter()
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap(return_kind(node.kind()), children, node))
    }

    pub(in crate::ast) fn wrapped_return_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .wrapped_return_block_kind(node.kind())
            && !node_text(node, self.source).contains('\n')
            && node
                .children(&mut node.walk())
                .next()
                .map(|child| {
                    return_statement_kind(child.kind())
                        && (!child.is_named()
                            || node_text(node, self.source) == node_text(child, self.source))
                })
                .unwrap_or(false)
    }

    pub(in crate::ast) fn normalize_wrapped_return_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let keyword = node.children(&mut node.walk()).next()?;
        if keyword.is_named()
            && return_statement_kind(keyword.kind())
            && node_text(node, self.source) == node_text(keyword, self.source)
        {
            return self.normalize_return_node(keyword);
        }
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_return_value(child))
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap(return_kind(keyword.kind()), children, node))
    }

    pub(in crate::ast) fn normalize_return_value(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self
            .normalization_adapter
            .check_node_role(node, "argument_list")
        {
            return self.normalize_node(node);
        }
        if self.named_children(node).is_empty() {
            return self.scalar_argument_list_value(node);
        }
        if self.argument_list_element_reference(node) {
            return self.normalize_argument_list_element_reference(node);
        }
        if self.boolean_expression(node) {
            return self.normalize_boolean(node);
        }
        if self.ternary_statement(node) {
            return self.normalize_ternary_statement(node);
        }
        if self.case_argument_list(node) {
            return self.normalize_case(node);
        }
        if self.argument_list_call_with_block(node) {
            return self.normalize_argument_list_call_with_block(node);
        }
        if self.dotted_expression(node) {
            return self.normalize_dotted_expression(node);
        }
        if self.argument_list_unary_not(node) {
            return self.normalize_argument_list_unary_not(node);
        }
        if self.infix_statement(node) {
            return self.normalize_infix_statement(node);
        }
        let children = self.named_children(node);
        if children.len() == 1
            && self.call_node(children[0])
            && node_text(children[0], self.source) == node_text(node, self.source)
        {
            if let Some(call) = self.normalize_return_value_call(children[0]) {
                return Some(call);
            }
        }
        if let (Some(function), Some(nested_args)) = (children.first(), children.get(1)) {
            if let Some(function_name) = self.identifier_text(*function).filter(|_| {
                self.normalization_adapter
                    .check_node_role(*nested_args, "argument_list")
            }) {
                let args = self
                    .named_children(*nested_args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>();
                let args_source = self
                    .parenthesized_source(*nested_args)
                    .or_else(|| self.parenthesized_source(node));
                let args_child = if let Some(source) = args_source {
                    self.list_or_nil_from_source_node(args, &source)
                } else {
                    list_or_nil(args, *nested_args, self)
                };
                return Some(self.wrap(
                    "FCALL",
                    vec![Child::Symbol(function_name), args_child],
                    node,
                ));
            }
        }
        let values = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect::<Vec<_>>();
        if values.len() == 1 {
            values.into_iter().next()
        } else if values.is_empty() {
            None
        } else {
            Some(self.list_node(values, node))
        }
    }

    pub(in crate::ast) fn normalize_return_value_call(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let function = self
            .named_field(node, "function")
            .or_else(|| self.named_field(node, "call"))
            .or_else(|| self.named_children(node).into_iter().next())?;
        let function_name = self.identifier_text(function)?;

        let args_node = self
            .named_field(node, "arguments")
            .or_else(|| self.named_field(node, "argument"))
            .or_else(|| {
                self.named_children(node).into_iter().find(|child| {
                    self.normalization_adapter
                        .check_node_role(*child, "argument_list")
                })
            });
        let args = args_node
            .map(|args_node| {
                self.named_children(args_node)
                    .into_iter()
                    .filter(|child| *child != function)
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let args_child = if let Some(args_node) = args_node {
            if let Some(source) = self
                .parenthesized_source(args_node)
                .or_else(|| self.parenthesized_source(node))
            {
                self.list_or_nil_from_source_node(args, &source)
            } else {
                list_or_nil(args, args_node, self)
            }
        } else {
            Child::Nil
        };

        Some(self.wrap(
            "FCALL",
            vec![Child::Symbol(function_name), args_child],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_ternary_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let parts = self.ternary_parts(node)?;
        let condition = optional_node(self.normalize_node(parts.condition));
        let positive = optional_node(self.normalize_ternary_branch(&parts.positive));
        let negative = optional_node(self.normalize_ternary_branch(&parts.negative));
        Some(self.wrap("IF", vec![condition, positive, negative], node))
    }

    pub(in crate::ast) fn normalize_boolean(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let operator = self.boolean_operator(node)?;
        let node_type = if operator == "or" { "OR" } else { "AND" };
        let mut operands = Vec::new();
        for child in self.named_children(node) {
            if let Some(normalized) = self.normalize_node(child) {
                if normalized.r#type == node_type {
                    operands.extend(normalized.children);
                } else {
                    operands.push(Child::Node(Box::new(normalized)));
                }
            }
        }
        Some(self.wrap(node_type, operands, node))
    }

    pub(in crate::ast) fn normalize_comparison(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && self
                .normalization_adapter
                .binary_wrapper_kinds()
                .contains(&raw_named[0].kind())
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let operands = self.named_children(target);
        let left = operands.first().and_then(|left| self.normalize_node(*left));
        let right_raw = operands.get(1).copied()?;
        let right = self.normalize_node(right_raw);
        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(self.comparison_operator(node)?),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_operator_call(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let operands = self.named_children(node);
        let direct_parts = match (
            operands.first().copied(),
            self.binary_operator(node),
            operands.get(1).copied(),
        ) {
            (Some(left), Some(operator), Some(right)) => Some((left, operator, right)),
            _ => None,
        };
        let (left_raw, operator, right_raw) =
            direct_parts.or_else(|| self.infix_statement_parts(node))?;
        let left = self.normalize_node(left_raw);
        let right = self.normalize_node(right_raw);
        if self.dynamic_syntax_enabled() && operator == "=~" && self.regex_literal(Some(right_raw))
        {
            return Some(self.wrap(
                "MATCH3",
                vec![optional_node(right), optional_node(left)],
                node,
            ));
        } else if self.dynamic_syntax_enabled() && operator == "=~" {
            return Some(self.wrap(
                "CALL",
                vec![
                    optional_node(left),
                    Child::Symbol("=~".to_string()),
                    list_or_nil(right.into_iter().collect(), right_raw, self),
                ],
                node,
            ));
        }

        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(operator),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_infix_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let (left_raw, operator, right_raw) = self.infix_statement_parts(node)?;
        let left = self.normalize_node(left_raw);
        let right = self.normalize_node(right_raw);
        if self.dynamic_syntax_enabled() && operator == "=~" && self.regex_literal(Some(right_raw))
        {
            return Some(self.wrap(
                "MATCH3",
                vec![optional_node(right), optional_node(left)],
                node,
            ));
        } else if self.dynamic_syntax_enabled() && operator == "=~" {
            return Some(self.wrap(
                "CALL",
                vec![
                    optional_node(left),
                    Child::Symbol("=~".to_string()),
                    list_or_nil(right.into_iter().collect(), right_raw, self),
                ],
                node,
            ));
        }
        Some(self.wrap(
            "OPCALL",
            vec![
                optional_node(left),
                Child::Symbol(operator),
                list_or_nil(right.into_iter().collect(), right_raw, self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_unary_not(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let operand = self.named_children(node).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_unary_not_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self.unary_not_expression(raw_named[0])
        {
            raw_named[0]
        } else {
            node
        };
        let operand = self.named_children(target).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_unary_minus(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self.unary_minus_expression(raw_named[0])
        {
            raw_named[0]
        } else {
            node
        };
        let operand = self.named_children(target).into_iter().next()?;
        if self
            .normalization_adapter
            .check_node_role(operand, "integer")
        {
            if let Ok(value) = node_text(operand, self.source).parse::<i64>() {
                return Some(self.wrap("INTEGER", vec![Child::Integer(-value)], operand));
            }
        }
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("-@".to_string()), Child::Nil],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_ternary_branch(
        &mut self,
        nodes: &[TreeSitterNode<'_>],
    ) -> Option<Node> {
        if nodes.is_empty() {
            return None;
        }
        if nodes.len() == 1 {
            return self.normalize_node(nodes[0]);
        }
        if let Some(call) = self.normalize_flat_dotted_nodes(nodes) {
            return Some(call);
        }
        self.normalize_body_nodes(nodes.to_vec(), nodes[0])
    }

    pub(in crate::ast) fn normalize_flat_dotted_nodes(
        &mut self,
        nodes: &[TreeSitterNode<'_>],
    ) -> Option<Node> {
        let receiver = *nodes.first()?;
        let method = *nodes.get(1)?;
        let connector = self
            .source
            .get(receiver.end_byte()..method.start_byte())
            .unwrap_or("")
            .trim();
        if !matches!(connector, "." | "&.") {
            return None;
        }
        let node_type = if connector == "&." { "QCALL" } else { "CALL" };
        let receiver_node = optional_node(self.normalize_node(receiver));
        Some(self.wrap_from_nodes(
            node_type,
            vec![
                receiver_node,
                Child::Symbol(node_text(method, self.source).trim_end_matches('=').to_string()),
                Child::Nil,
            ],
            receiver,
            method,
        ))
    }

    pub(in crate::ast) fn normalize_assignment(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let left = self.assignment_left(node)?;
        let right = self
            .assignment_right(node)
            .and_then(|right| self.normalize_node(right));
        if self
            .normalization_adapter
            .check_node_role(left, "multiple_assignment_left")
        {
            return Some(self.normalize_multiple_assignment(left, right, node));
        }
        if let Some(target) = self.assignment_target(left, right.clone(), node) {
            return Some(target);
        }
        Some(self.wrap(
            "LASGN",
            vec![Child::String(self.target_name(left)), optional_node(right)],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_operator_assignment(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let left = self.assignment_left(node)?;
        let right_raw = self.assignment_right(node);
        let right = right_raw.and_then(|right| self.normalize_node(right));
        let operator = self.operator_assignment_operator(node);

        if self
            .normalization_adapter
            .check_node_role(left, "element_reference")
        {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN1",
                vec![
                    receiver,
                    Child::Symbol(operator),
                    list_or_nil(args, left, self),
                    optional_node(right),
                ],
                node,
            ));
        }

        if self.member_read_node(left) {
            let (receiver, method) = self.member_parts(left)?;
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN2",
                vec![
                    receiver,
                    Child::Bool(false),
                    Child::Symbol(method),
                    Child::Symbol(operator),
                    optional_node(right),
                ],
                node,
            ));
        }

        if let Some(logical) =
            self.normalize_logical_operator_assignment(left, &operator, right.clone(), node)
        {
            return Some(logical);
        }

        if self.instance_variable(left) || self.global_variable(left) {
            let value = self.augmented_assignment_value(left, &operator, right_raw, node);
            return self.assignment_target(left, Some(value), node);
        }

        let value = self.augmented_assignment_value(left, &operator, right_raw, node);
        self.assignment_target(left, Some(value.clone()), node)
            .or_else(|| {
                Some(self.wrap(
                    "LASGN",
                    vec![
                        Child::String(self.target_name(left)),
                        Child::Node(Box::new(value)),
                    ],
                    node,
                ))
            })
    }

    pub(in crate::ast) fn normalize_operator_assignment_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let (left, operator, right_raw) = self.operator_assignment_statement_parts(node)?;
        let right = self.normalize_node(right_raw);

        if self
            .normalization_adapter
            .check_node_role(left, "element_reference")
        {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN1",
                vec![
                    receiver,
                    Child::Symbol(operator),
                    list_or_nil(args, left, self),
                    optional_node(right),
                ],
                node,
            ));
        }

        if self.member_read_node(left) {
            let (receiver, method) = self.member_parts(left)?;
            let receiver = optional_node(self.normalize_node(receiver));
            return Some(self.wrap(
                "OP_ASGN2",
                vec![
                    receiver,
                    Child::Bool(false),
                    Child::Symbol(method),
                    Child::Symbol(operator),
                    optional_node(right),
                ],
                node,
            ));
        }

        if let Some(logical) =
            self.normalize_logical_operator_assignment(left, &operator, right.clone(), node)
        {
            return Some(logical);
        }

        if self.instance_variable(left) || self.global_variable(left) {
            let value = self.augmented_assignment_value(left, &operator, Some(right_raw), node);
            return self.assignment_target(left, Some(value), node);
        }

        if let Some(target) = self.assignment_target(left, right, node) {
            return Some(target);
        }

        let value = self.augmented_assignment_value(left, &operator, Some(right_raw), node);
        Some(self.wrap(
            "LASGN",
            vec![
                Child::String(self.target_name(left)),
                Child::Node(Box::new(value)),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn operator_assignment_statement_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String, TreeSitterNode<'tree>)> {
        let mut left = None;
        let mut operator = None;
        let mut right = None;
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if child.is_named() {
                if left.is_none() {
                    left = Some(child);
                }
                if operator.is_some() {
                    right = Some(child);
                }
            } else if let Some(found_operator) =
                operator_assignment_statement_operator(node_text(child, self.source))
            {
                operator = Some(found_operator);
            }
        }

        if let (Some(left), Some(operator), Some(right)) = (left, operator, right) {
            return Some((left, operator, right));
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            return self.operator_assignment_statement_parts(raw_named[0]);
        }

        None
    }

    pub(in crate::ast) fn operator_assignment_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "block_wrapper")
        {
            return false;
        }
        if self.operator_assignment_statement_parts(node).is_some() {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
            && self
                .operator_assignment_statement_parts(raw_named[0])
                .is_some()
    }

    pub(in crate::ast) fn normalize_logical_operator_assignment(
        &mut self,
        left: TreeSitterNode<'_>,
        operator: &str,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self
            .normalization_adapter
            .logical_operator_assignment(operator)
        {
            return None;
        }
        self.identifier_text(left)?;
        let name = self.target_name(left);
        let node_type = if operator == "||" {
            "OP_ASGN_OR"
        } else {
            "OP_ASGN_AND"
        };
        let receiver = self.wrap("LVAR", vec![Child::String(name.clone())], left);
        let assignment = self.wrap(
            "LASGN",
            vec![Child::String(name), optional_node(right)],
            source,
        );
        Some(self.wrap(
            node_type,
            vec![
                Child::Node(Box::new(receiver)),
                Child::Symbol(operator.to_string()),
                Child::Node(Box::new(assignment)),
            ],
            source,
        ))
    }

    pub(in crate::ast) fn augmented_assignment_value(
        &mut self,
        left: TreeSitterNode<'_>,
        operator: &str,
        right_raw: Option<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let receiver = optional_node(self.assignment_receiver(left));
        let right = right_raw.and_then(|right| self.normalize_node(right));
        self.wrap(
            "CALL",
            vec![
                receiver,
                Child::Symbol(operator.to_string()),
                list_or_nil(right.into_iter().collect(), right_raw.unwrap_or(left), self),
            ],
            source,
        )
    }

    pub(in crate::ast) fn assignment_receiver(&mut self, left: TreeSitterNode<'_>) -> Option<Node> {
        if let Some(name) = self.identifier_text(left) {
            return Some(self.wrap("LVAR", vec![Child::String(name)], left));
        }
        if self.instance_variable(left) {
            return Some(self.wrap(
                "IVAR",
                vec![Child::String(node_text(left, self.source).to_string())],
                left,
            ));
        }
        if self.global_variable(left) {
            return Some(self.normalize_global_variable(left));
        }
        if self.const_kind(left.kind()) {
            return Some(self.normalize_const(left));
        }
        self.normalize_node(left)
    }

    pub(in crate::ast) fn normalize_multiple_assignment(
        &self,
        left: TreeSitterNode<'_>,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let targets = self
            .named_children(left)
            .into_iter()
            .map(|child| {
                let node_type = if self.global_variable(child) {
                    "GASGN"
                } else {
                    "LASGN"
                };
                self.wrap(
                    node_type,
                    vec![Child::String(self.target_name(child)), Child::Nil],
                    child,
                )
            })
            .collect::<Vec<_>>();
        self.wrap(
            "MASGN",
            vec![optional_node(right), list_or_nil(targets, left, self)],
            source,
        )
    }

    pub(in crate::ast) fn normalize_call(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let normalized = if self.zero_child_identifier_call(node) {
            Some(self.normalize_zero_child_call(node))
        } else if self.visibility_inline_def_call(node) {
            self.normalize_visibility_inline_def(node)
        } else if self.call_block(node).is_some() {
            self.normalize_call_with_block(node)
        } else {
            self.normalize_call_without_block(node, None)
        };
        if let Some(normalized) = normalized.as_ref() {
            self.record_call_origin(span(node), normalized);
        }
        normalized
    }

    pub(in crate::ast) fn normalize_zero_child_call(&self, node: TreeSitterNode<'_>) -> Node {
        self.wrap(
            "VCALL",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    pub(in crate::ast) fn normalize_member_read(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if let Some(field) = self
            .normalization_adapter
            .state_field_name(node, self.source)
        {
            return Some(self.wrap("IVAR", vec![Child::String(field)], node));
        }
        let Some((receiver, method)) = self.member_parts(node) else {
            let children = self.normalize_children(node);
            return Some(self.wrap(&kind_type(node.kind()), children, node));
        };
        let receiver = optional_node(self.normalize_node(receiver));
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol(method), Child::Nil],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_call_with_block(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let call = self.normalize_call_without_block(call_source, block)?;
        let args = self.normalize_block_parameters(block);
        let body = block.and_then(|block| {
            self.with_dynamic_scope(block, false, |normalizer| {
                let body_node = normalizer
                    .named_field(block, "body")
                    .or_else(|| normalizer.block_child(block))
                    .unwrap_or(block);
                normalizer
                    .normalize_body(body_node)
                    .map(|node| normalizer.normalize_dynamic_scope(node))
            })
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_argument_list_call(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled()
            || !self
                .normalization_adapter
                .check_node_role(node, "argument_list")
        {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && self
                    .normalization_adapter
                    .check_node_role(raw_named[0], "call")
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let function = self.named_children(target).into_iter().next()?;
        let args_node = self.named_children(target).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| {
                self.named_children(args)
                    .into_iter()
                    .filter_map(|child| self.normalize_node(child))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Some(self.wrap(
            "FCALL",
            vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                list_or_nil(args, args_node.unwrap_or(node), self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_argument_list_element_reference(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled() || !self.argument_list_element_reference(node) {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && self
                    .normalization_adapter
                    .check_node_role(raw_named[0], "element_reference")
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let named = self.named_children(target);
        let recv = *named.first()?;
        let args = named
            .iter()
            .skip(1)
            .filter_map(|child| self.normalize_node(*child))
            .collect::<Vec<_>>();
        let recv = self.normalize_node(recv)?;
        Some(self.wrap(
            "CALL",
            vec![
                Child::Node(Box::new(recv)),
                Child::Symbol("[]".to_string()),
                list_or_nil(args, node, self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_argument_list_unary_not(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled() || !self.argument_list_unary_not(node) {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && self
                    .normalization_adapter
                    .check_node_role(raw_named[0], "unary")
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let operand = self.named_children(target).into_iter().next()?;
        let operand = optional_node(self.normalize_node(operand));
        Some(self.wrap(
            "OPCALL",
            vec![operand, Child::Symbol("!".to_string()), Child::Nil],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_argument_list_call_with_block(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled()
            || !self
                .normalization_adapter
                .check_node_role(node, "argument_list")
        {
            return None;
        }
        let target = {
            let raw_named = self.raw_named_children(node);
            if raw_named.len() == 1
                && self
                    .normalization_adapter
                    .check_node_role(raw_named[0], "call")
                && node_text(raw_named[0], self.source) == node_text(node, self.source)
            {
                raw_named[0]
            } else {
                node
            }
        };
        let block = self.call_block(target)?;
        let call = self.normalize_argument_list_call(node)?;
        let args = self.normalize_block_parameters(Some(block));
        let body = self.with_dynamic_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer
                .normalize_body(body_node)
                .map(|node| normalizer.normalize_dynamic_scope(node))
        });
        Some(self.wrap(
            "ITER",
            vec![
                Child::Node(Box::new(call)),
                Child::Node(Box::new(self.scope(body, args, node))),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_statement_call_with_block(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = self.statement_block_call(node)?;
        let call = self.normalize_call_without_block(call_source, block)?;
        let args = self.normalize_block_parameters(block);
        let body = block.and_then(|block| {
            self.with_dynamic_scope(block, false, |normalizer| {
                let body_node = normalizer
                    .named_field(block, "body")
                    .or_else(|| normalizer.block_child(block))
                    .unwrap_or(block);
                normalizer
                    .normalize_body(body_node)
                    .map(|node| normalizer.normalize_dynamic_scope(node))
            })
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_dotted_expression(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let block = self.call_block(node);
        let call_source = block.map(|block| self.source_before_child(node, block));
        let call = self.normalize_dotted_call_expression_with_source(node, call_source.as_ref())?;
        let Some(block) = block else {
            return Some(call);
        };
        let args = self.normalize_block_parameters(Some(block));
        let body = self.with_dynamic_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer
                .normalize_body(body_node)
                .map(|node| normalizer.normalize_dynamic_scope(node))
        });
        let scope = self.scope(body, args, node);
        Some(self.wrap(
            "ITER",
            vec![Child::Node(Box::new(call)), Child::Node(Box::new(scope))],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_call_without_block(
        &mut self,
        node: TreeSitterNode<'_>,
        block: Option<TreeSitterNode<'_>>,
    ) -> Option<Node> {
        let call_source = block.map(|block| self.source_before_child(node, block));
        if let Some(name) = self
            .normalization_adapter
            .intrinsic_call_name(node, self.source)
        {
            let args = self.call_arguments(node, None);
            let node_type = if block.is_some() || !args.is_empty() {
                "FCALL"
            } else {
                "VCALL"
            };
            let children = vec![
                Child::Symbol(name.to_string()),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(node_type, children, source));
            }
            return Some(self.wrap(node_type, children, node));
        }
        if self.dotted_call(node) {
            let (receiver, method) = self.dotted_call_parts(node, block)?;
            let args = self.call_arguments(node, None);
            let node_type = if self.safe_navigation_call(node) {
                "QCALL"
            } else {
                "CALL"
            };
            let receiver = optional_node(self.normalize_node(receiver));
            let args = if let Some(source) = call_source.as_ref() {
                self.list_or_nil_from_source_node(args, source)
            } else {
                list_or_nil(args, node, self)
            };
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(
                    node_type,
                    vec![receiver, Child::Symbol(method), args],
                    source,
                ));
            }
            return Some(self.wrap(node_type, vec![receiver, Child::Symbol(method), args], node));
        }

        let function = self
            .named_field(node, "function")
            .or_else(|| self.named_field(node, "call"))
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .find(|child| Some(*child) != block)
            })?;
        let args = self.call_arguments(node, Some(function));
        if let Some(function_name) = self.identifier_text(function) {
            let node_type = if block.is_some() || !args.is_empty() {
                "FCALL"
            } else {
                "VCALL"
            };
            let children = vec![
                Child::Symbol(function_name),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node(node_type, children, source));
            }
            return Some(self.wrap(node_type, children, node));
        }
        if self
            .normalization_adapter
            .bare_const_call_function(function)
        {
            let children = vec![
                Child::Symbol(node_text(function, self.source).to_string()),
                if let Some(source) = call_source.as_ref() {
                    self.list_or_nil_from_source_node(args, source)
                } else {
                    list_or_nil(args, node, self)
                },
            ];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("FCALL", children, source));
            }
            return Some(self.wrap("FCALL", children, node));
        }
        if self.member_read_node(function) {
            let (receiver, method) = self.member_parts(function)?;
            let receiver = optional_node(self.normalize_node(receiver));
            let args = if let Some(source) = call_source.as_ref() {
                self.list_or_nil_from_source_node(args, source)
            } else {
                list_or_nil(args, node, self)
            };
            let children = vec![receiver, Child::Symbol(method), args];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("CALL", children, source));
            }
            return Some(self.wrap("CALL", children, node));
        }
        if let Some((receiver, method)) = self
            .normalization_adapter
            .scoped_call_parts(function, self.source)
        {
            let receiver = optional_node(self.normalize_node(receiver));
            let args = if let Some(source) = call_source.as_ref() {
                self.list_or_nil_from_source_node(args, source)
            } else {
                list_or_nil(args, node, self)
            };
            let children = vec![receiver, Child::Symbol(method), args];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("CALL", children, source));
            }
            return Some(self.wrap("CALL", children, node));
        }
        let function = optional_node(self.normalize_node(function));
        let args = if let Some(source) = call_source.as_ref() {
            self.list_or_nil_from_source_node(args, source)
        } else {
            list_or_nil(args, node, self)
        };
        let children = vec![function, Child::Symbol("call".to_string()), args];
        if let Some(source) = call_source.as_ref() {
            return Some(self.wrap_from_source_node("CALL", children, source));
        }
        Some(self.wrap("CALL", children, node))
    }

    pub(in crate::ast) fn normalize_element_reference(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self
            .normalization_adapter
            .element_reference_target(node, self.source)
            .unwrap_or(node);
        let named = self.named_children(target);
        let receiver = *named.first()?;
        let args = named
            .iter()
            .skip(1)
            .filter_map(|arg| self.normalize_node(*arg))
            .collect::<Vec<_>>();
        if self.self_node(receiver) {
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol("[]".to_string()),
                    list_or_nil(args, node, self),
                ],
                node,
            ));
        }
        let receiver = optional_node(self.normalize_node(receiver));
        let args = list_or_nil(args, node, self);
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol("[]".to_string()), args],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_rescue_modifier(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let named = self.named_children(node);
        let body = named.first().and_then(|body| self.normalize_node(*body));
        let handler = named
            .get(1)
            .and_then(|handler| self.normalize_node(*handler));
        let resbody = self.wrap(
            "RESBODY",
            vec![Child::Nil, optional_node(handler), Child::Nil],
            node,
        );
        Some(self.wrap(
            "RESCUE",
            vec![
                optional_node(body),
                Child::Node(Box::new(resbody)),
                Child::Nil,
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_ensure_clause(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        self.normalize_body_nodes(self.named_children(node), node)
    }

    pub(in crate::ast) fn normalize_dotted_call_expression(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        self.normalize_dotted_call_expression_with_source(node, None)
    }

    pub(in crate::ast) fn normalize_dotted_call_expression_with_source(
        &mut self,
        node: TreeSitterNode<'_>,
        source: Option<&Node>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1 && self.dotted_call(raw_named[0]) {
            raw_named[0]
        } else {
            node
        };
        let (receiver_raw, method) = self.dotted_call_parts(target, None)?;
        let args = self.call_arguments(target, None);
        let args = if let Some(source) = source {
            self.list_or_nil_from_source_node(args, source)
        } else {
            list_or_nil(args, node, self)
        };
        let receiver = optional_node(self.normalize_node(receiver_raw));
        let node_type = if self.safe_navigation_call(target) {
            "QCALL"
        } else {
            "CALL"
        };
        let children = vec![receiver, Child::Symbol(method), args];
        if let Some(source) = source {
            return Some(self.wrap_from_source_node(node_type, children, source));
        }
        Some(self.wrap(node_type, children, node))
    }

    pub(in crate::ast) fn normalize_begin(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let rescue_nodes = named
            .iter()
            .copied()
            .filter(|child| self.normalization_adapter.rescue_clause(*child))
            .collect::<Vec<_>>();
        let ensure_node = named
            .iter()
            .copied()
            .find(|child| self.normalization_adapter.ensure_clause_kind(*child));
        if rescue_nodes.is_empty() {
            let Some(ensure_node) = ensure_node else {
                let children = self.normalize_children(node);
                return Some(self.wrap("BEGIN", children, node));
            };
            let body_nodes = named
                .iter()
                .copied()
                .take_while(|child| !self.normalization_adapter.ensure_clause_kind(*child))
                .collect::<Vec<_>>();
            let body =
                self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
            let ensure_body_node = self
                .normalization_adapter
                .ensure_clause_body(ensure_node)
                .unwrap_or(ensure_node);
            let ensure_body = self.normalize_control_body(ensure_body_node);
            let source_start = body_nodes.first().copied().unwrap_or(node);
            let ensure_named = self.named_children(ensure_node);
            let source_end = ensure_named.last().copied().unwrap_or(ensure_node);
            let source = self.source_from_nodes(source_start, source_end);
            return Some(self.wrap_from_source_node(
                "ENSURE",
                vec![optional_node(body), optional_node(ensure_body)],
                &source,
            ));
        }

        let body_nodes = named
            .iter()
            .copied()
            .take_while(|child| !self.normalization_adapter.rescue_clause(*child))
            .collect::<Vec<_>>();
        let body =
            self.normalize_body_nodes(body_nodes.clone(), *body_nodes.first().unwrap_or(&node));
        let resbodies = rescue_nodes
            .iter()
            .filter_map(|child| self.normalize_rescue_clause(*child))
            .collect::<Vec<_>>();
        let source_start = body_nodes.first().copied().unwrap_or(node);
        let source_end = rescue_nodes
            .last()
            .and_then(|last| self.rescue_source_end(*last))
            .or_else(|| rescue_nodes.last().copied())
            .unwrap_or(node);
        let source = self.source_from_nodes(source_start, source_end);
        let rescued = self.wrap_from_source_node(
            "RESCUE",
            vec![
                optional_node(body),
                optional_node(self.link_rescue_chain(resbodies)),
                Child::Nil,
            ],
            &source,
        );
        let Some(ensure_node) = ensure_node else {
            return Some(rescued);
        };
        let ensure_body_node = self
            .normalization_adapter
            .ensure_clause_body(ensure_node)
            .unwrap_or(ensure_node);
        let ensure_body = self.normalize_control_body(ensure_body_node);
        let ensure_named = self.named_children(ensure_node);
        let source_end = ensure_named.last().copied().unwrap_or(ensure_node);
        let source = self.source_from_nodes(source_start, source_end);
        Some(self.wrap_from_source_node(
            "ENSURE",
            vec![Child::Node(Box::new(rescued)), optional_node(ensure_body)],
            &source,
        ))
    }

    pub(in crate::ast) fn normalize_rescue_clause(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let exceptions = self
            .normalization_adapter
            .rescue_clause_exceptions(node, self.source);
        let exception_nodes = exceptions
            .iter()
            .filter_map(|child| {
                if self
                    .normalization_adapter
                    .check_node_role(*child, "exceptions")
                    && self
                        .normalization_adapter
                        .dynamic_exception_constant_text(node_text(*child, self.source))
                {
                    Some(self.normalize_const(*child))
                } else {
                    self.normalize_node(*child)
                }
            })
            .collect::<Vec<_>>();
        let exception_source = self
            .normalization_adapter
            .rescue_clause_exceptions_source(node, self.source);
        let exception_variable = self.rescue_exception_variable(node);
        let handler = self.normalization_adapter.rescue_clause_handler(node);
        let normalized_handler = handler.and_then(|handler| self.normalize_body(handler));
        let body = self.prepend_rescue_exception_assignment(normalized_handler, exception_variable);
        Some(self.wrap(
            "RESBODY",
            vec![
                list_or_nil(exception_nodes, exception_source.unwrap_or(node), self),
                optional_node(body),
                Child::Nil,
            ],
            node,
        ))
    }

    pub(in crate::ast) fn rescue_source_end<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(handler) = self.normalization_adapter.rescue_clause_handler(node) {
            return self
                .named_children(handler)
                .last()
                .copied()
                .or(Some(handler));
        }

        self.named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() != "comment")
            .or(Some(node))
    }

    pub(in crate::ast) fn link_rescue_chain(&self, mut resbodies: Vec<Node>) -> Option<Node> {
        let mut next = None;
        while let Some(mut current) = resbodies.pop() {
            while current.children.len() <= 2 {
                current.children.push(Child::Nil);
            }
            current.children[2] = optional_node(next);
            next = Some(current);
        }
        next
    }

    pub(in crate::ast) fn rescue_exception_variable(
        &self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let name = self
            .normalization_adapter
            .rescue_clause_exception_variable_name(node)?;
        let source = self
            .normalization_adapter
            .rescue_clause_exception_variable_source(node)
            .unwrap_or(name);
        let errinfo = self.wrap("ERRINFO", Vec::new(), source);
        Some(self.wrap(
            "LASGN",
            vec![
                Child::String(node_text(name, self.source).to_string()),
                Child::Node(Box::new(errinfo)),
            ],
            source,
        ))
    }

    pub(in crate::ast) fn prepend_rescue_exception_assignment(
        &self,
        body: Option<Node>,
        assignment: Option<Node>,
    ) -> Option<Node> {
        let Some(assignment) = assignment else {
            return body;
        };
        let Some(mut body) = body else {
            return Some(assignment);
        };
        if body.r#type == "BLOCK" {
            let mut children = vec![Child::Node(Box::new(assignment))];
            children.extend(
                body.children
                    .into_iter()
                    .filter(|child| !matches!(child, Child::Nil)),
            );
            body.children = children;
            Some(body)
        } else {
            let source = self.source_from_normalized_nodes(&assignment, &body);
            Some(self.wrap_from_source_node(
                "BLOCK",
                vec![
                    Child::Node(Box::new(assignment)),
                    Child::Node(Box::new(body)),
                ],
                &source,
            ))
        }
    }

    pub(in crate::ast) fn normalize_modifier_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let keyword = self.modifier_keyword(node);
        let (action, condition) = self.modifier_parts(node)?;
        let node_type = keyword
            .as_deref()
            .and_then(|keyword| self.normalization_adapter.modifier_node_type(keyword))
            .unwrap_or("IF");
        let condition = optional_node(self.normalize_node(condition));
        let action = optional_node(self.normalize_modifier_action(action));
        let trailing = if matches!(node_type, "WHILE" | "UNTIL") {
            Child::Bool(true)
        } else {
            Child::Nil
        };
        Some(self.wrap(node_type, vec![condition, action, trailing], node))
    }

    pub(in crate::ast) fn normalize_modifier_action(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if self.modifier_return_action(node) {
            self.normalize_return_node(node)
        } else {
            self.normalize_node(node)
        }
    }

    pub(in crate::ast) fn normalize_command_call_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let raw_named = self.raw_named_children(node);
        let target = if self
            .normalization_adapter
            .is_command_call_wrapper_kind(node.kind())
            && raw_named.len() == 1
            && self
                .normalization_adapter
                .check_node_role(raw_named[0], "call")
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let function = self.named_children(target).into_iter().next()?;
        if self.visibility_inline_def_statement(node, function) {
            let method = self.inline_def_from_statement(node);
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol(node_text(function, self.source).to_string()),
                    list_or_nil(method.into_iter().collect(), node, self),
                ],
                node,
            ));
        }
        let args_node = self.named_children(target).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let args = args_node
            .map(|args| self.command_arguments(args))
            .unwrap_or_default();
        let block = self.call_block(target);
        let call_source = block.map(|block| self.source_before_child(node, block));
        if self.dynamic_syntax_enabled() && node_text(function, self.source) == "yield" {
            let children = vec![list_or_nil(args, args_node.unwrap_or(node), self)];
            if let Some(source) = call_source.as_ref() {
                return Some(self.wrap_from_source_node("YIELD", children, source));
            }
            return Some(self.wrap("YIELD", children, node));
        }
        let call_type = if args.is_empty() { "VCALL" } else { "FCALL" };
        let list_source = args_node.unwrap_or(node);
        let call_children = vec![
            Child::Symbol(node_text(function, self.source).to_string()),
            list_or_nil(args, list_source, self),
        ];
        let call = if let Some(source) = call_source.as_ref() {
            self.wrap_from_source_node(call_type, call_children, source)
        } else {
            self.wrap(call_type, call_children, node)
        };
        let Some(block) = block else {
            return Some(call);
        };
        let block_args = self.normalize_block_parameters(Some(block));
        let body = self.with_dynamic_scope(block, false, |normalizer| {
            let body_node = normalizer
                .named_field(block, "body")
                .or_else(|| normalizer.block_child(block))
                .unwrap_or(block);
            normalizer
                .normalize_body(body_node)
                .map(|node| normalizer.normalize_dynamic_scope(node))
        });
        Some(self.wrap(
            "ITER",
            vec![
                Child::Node(Box::new(call)),
                Child::Node(Box::new(self.scope(body, block_args, node))),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_visibility_inline_def(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let message =
            node_text(self.named_children(node).into_iter().next()?, self.source).to_string();
        let args = self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "argument_list")
        });
        let method = self.inline_def_from_argument_list(args);
        Some(self.wrap(
            "FCALL",
            vec![
                Child::Symbol(message),
                list_or_nil(method.into_iter().collect(), args.unwrap_or(node), self),
            ],
            node,
        ))
    }

    pub(in crate::ast) fn normalize_const(&mut self, node: TreeSitterNode<'_>) -> Node {
        if self
            .normalization_adapter
            .check_node_role(node, "scope_resolution_or_scoped_type")
        {
            let parts = self.named_children(node);
            let base = parts
                .first()
                .map(|part| self.normalize_const(*part))
                .map(|part| Child::Node(Box::new(part)))
                .unwrap_or(Child::Nil);
            let name = self
                .named_field(node, "name")
                .or_else(|| parts.last().copied())
                .map(|name| node_text(name, self.source).to_string())
                .unwrap_or_default();
            return self.wrap("COLON2", vec![base, Child::Symbol(name)], node);
        }

        self.wrap(
            "CONST",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    pub(in crate::ast) fn const_for(
        &mut self,
        node: Option<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let Some(node) = node else {
            return self.wrap(
                "CONST",
                vec![Child::Symbol("(anonymous)".to_string())],
                source,
            );
        };
        if self.const_kind(node.kind()) {
            return self.normalize_const(node);
        }
        self.wrap(
            "CONST",
            vec![Child::Symbol(node_text(node, self.source).to_string())],
            node,
        )
    }

    pub(in crate::ast) fn normalize_global_variable(&self, node: TreeSitterNode<'_>) -> Node {
        let text = node_text(node, self.source).to_string();
        if let Some(value) = text.strip_prefix('$') {
            if value
                .chars()
                .next()
                .map(|first| matches!(first, '1'..='9'))
                .unwrap_or(false)
                && value.chars().all(|ch| ch.is_ascii_digit())
            {
                let number = value
                    .parse::<i64>()
                    .expect("validated global nth reference should parse");
                return self.wrap("NTH_REF", vec![Child::Integer(number)], node);
            }
        }
        self.wrap("GVAR", vec![Child::String(text)], node)
    }

    pub(in crate::ast) fn array_literal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .array_literal_statement(node, self.source)
    }

    pub(in crate::ast) fn normalize_array_literal_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self
            .normalization_adapter
            .array_literal_target(node, self.source)
            .unwrap_or(node);
        let values = self
            .normalization_adapter
            .array_literal_values(target, self.source)
            .into_iter()
            .filter_map(|child| self.normalize_array_literal_value(child))
            .collect::<Vec<_>>();
        if values.is_empty() {
            Some(self.wrap("ZLIST", Vec::new(), target))
        } else {
            Some(self.list_node(values, target))
        }
    }

    pub(in crate::ast) fn normalize_array_literal_value(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if self.normalization_adapter.check_node_role(node, "field") {
            let named = self.named_children(node);
            if named.len() == 1 {
                return self.normalize_node(named[0]);
            }
            if named.is_empty() {
                return Some(self.normalize_terminal_statement(node));
            }
        }

        self.normalize_node(node)
    }

    pub(in crate::ast) fn element_reference_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .element_reference_statement(node, self.source)
    }

    pub(in crate::ast) fn normalize_element_reference_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self
            .normalization_adapter
            .element_reference_target(node, self.source)
            .unwrap_or(node);
        let receiver = self
            .normalization_adapter
            .element_reference_receiver(target, self.source)?;
        let args = self
            .normalization_adapter
            .element_reference_arguments(target, self.source)
            .into_iter()
            .filter_map(|arg| self.normalize_node(arg))
            .collect::<Vec<_>>();
        if self.dynamic_syntax_enabled() && self.self_node(receiver) {
            return Some(self.wrap(
                "FCALL",
                vec![
                    Child::Symbol("[]".to_string()),
                    list_or_nil(args, target, self),
                ],
                target,
            ));
        }

        let receiver = optional_node(self.normalize_node(receiver));
        let args = list_or_nil(args, target, self);
        Some(self.wrap(
            "CALL",
            vec![receiver, Child::Symbol("[]".to_string()), args],
            target,
        ))
    }

    pub(in crate::ast) fn hash_literal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .hash_literal_statement(node, self.source)
    }

    pub(in crate::ast) fn normalize_hash_literal_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self
            .normalization_adapter
            .hash_literal_target(node, self.source)
            .unwrap_or(node);
        let children = self
            .normalization_adapter
            .hash_literal_values(target, self.source)
            .into_iter()
            .filter_map(|child| self.normalize_hash_literal_value(child))
            .map(|child| Child::Node(Box::new(child)))
            .collect::<Vec<_>>();
        Some(self.wrap("HASH", children, target))
    }

    pub(in crate::ast) fn normalize_hash_literal_value(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if self.normalization_adapter.check_node_role(node, "field")
            || self.normalization_adapter.check_node_role(node, "pair")
        {
            let named = self.named_children(node);
            if named.len() >= 2 {
                let key = named[0];
                let value = named[1];
                let key_lit = self.wrap(
                    "LIT",
                    vec![Child::Symbol(node_text(key, self.source).to_string())],
                    key,
                );
                let value = self.normalize_node(value);
                return Some(self.wrap(
                    "HASH",
                    vec![Child::Node(Box::new(key_lit)), optional_node(value)],
                    node,
                ));
            }
        }

        self.normalize_node(node)
    }

    pub(in crate::ast) fn empty_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .empty_body_statement(node, self.source)
    }

    pub(in crate::ast) fn heredoc_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.heredoc_body_statement(node)
    }

    pub(in crate::ast) fn heredoc_call_for_body(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .heredoc_call_for_body(node, self.source)
    }

    pub(in crate::ast) fn heredoc_start_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .heredoc_start_node(node, self.source)
    }

    pub(in crate::ast) fn terminal_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .is_terminal_statement_kind(node.kind())
            && self.named_children(node).is_empty()
            && !node_text(node, self.source).trim().is_empty()
    }

    pub(in crate::ast) fn normalize_terminal_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Node {
        let text = node_text(node, self.source).trim();
        if self
            .normalization_adapter
            .dynamic_instance_variable_text(text)
        {
            return self.wrap("IVAR", vec![Child::String(text.to_string())], node);
        }
        if let Some(name) = self.normalization_adapter.dollar_prefixed_local_name(text) {
            return self.normalize_identifier_with_name(node, name);
        }
        if text.starts_with('$') && self.global_variable(node) {
            return self.normalize_global_variable(node);
        }
        if text == "nil" {
            return self.wrap("NIL", Vec::new(), node);
        }
        if text == "true" {
            return self.wrap("TRUE", Vec::new(), node);
        }
        if text == "false" {
            return self.wrap("FALSE", Vec::new(), node);
        }
        if let Some(symbol) = text.strip_prefix(':') {
            if exact_bare_identifier_text(symbol) {
                return self.wrap("LIT", vec![Child::Symbol(symbol.to_string())], node);
            }
        }
        if exact_integer_text(text) {
            if let Ok(value) = text.parse::<i64>() {
                return self.wrap("INTEGER", vec![Child::Integer(value)], node);
            }
        }
        if text == "[]" {
            return self.wrap("ZLIST", Vec::new(), node);
        }
        if bare_identifier_text(text) {
            if self.dynamic_syntax_enabled() && !self.dynamic_local_name(text) {
                return self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node);
            }
            return self.wrap("LVAR", vec![Child::String(text.to_string())], node);
        }

        self.wrap(&kind_type(node.kind()), Vec::new(), node)
    }

    pub(in crate::ast) fn normalize_array_literal(&mut self, node: TreeSitterNode<'_>) -> Node {
        let values = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_array_literal_value(child))
            .collect::<Vec<_>>();
        if values.is_empty() {
            self.wrap("ZLIST", Vec::new(), node)
        } else {
            self.list_node(values, node)
        }
    }

    pub(in crate::ast) fn normalize_pair(&mut self, node: TreeSitterNode<'_>) -> Option<Node> {
        let named = self.named_children(node);
        let key = *named.first()?;
        let value_raw = named.get(1).copied();

        let has_hash_rocket = node
            .children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, self.source) == "=>");
        if has_hash_rocket {
            let children = [
                self.normalize_node(key),
                value_raw.and_then(|value| self.normalize_node(value)),
            ]
            .into_iter()
            .flatten()
            .map(|child| Child::Node(Box::new(child)))
            .collect();
            return Some(self.wrap("HASH", children, node));
        }

        let key_text = node_text(key, self.source);
        let key_lit = self.wrap("LIT", vec![Child::Symbol(key_text.to_string())], key);
        if self.dynamic_syntax_enabled()
            && self
                .normalization_adapter
                .check_node_role(key, "hash_key_symbol")
            && value_raw.is_none()
        {
            let value = self.local_or_call_for_name(key_text, key);
            return Some(self.wrap(
                "HASH",
                vec![Child::Node(Box::new(key_lit)), Child::Node(Box::new(value))],
                node,
            ));
        }

        let mut children = vec![Child::Node(Box::new(key_lit))];
        if let Some(value) = value_raw.and_then(|value| self.normalize_node(value)) {
            children.push(Child::Node(Box::new(value)));
        }
        Some(self.wrap("HASH", children, node))
    }

    pub(in crate::ast) fn normalize_block_argument(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let value = self
            .named_children(node)
            .into_iter()
            .next()
            .and_then(|child| self.normalize_node(child));
        Some(self.wrap("BLOCK_PASS", vec![Child::Nil, optional_node(value)], node))
    }

    pub(in crate::ast) fn normalize_interpolated_string(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Node {
        let children = self.normalize_children(node);
        self.wrap("DSTR", children, node)
    }

    pub(in crate::ast) fn normalize_subshell(&mut self, node: TreeSitterNode<'_>) -> Node {
        let children = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| {
                if self.normalization_adapter.interpolation_node(child) {
                    self.normalize_interpolation(child)
                        .map(|node| Child::Node(Box::new(node)))
                } else if self
                    .normalization_adapter
                    .check_node_role(child, "string_content")
                {
                    Some(Child::Node(Box::new(self.wrap(
                        "STR",
                        vec![Child::String(node_text(child, self.source).to_string())],
                        child,
                    ))))
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        let node_type = if children
            .iter()
            .any(|child| matches!(child, Child::Node(node) if node.r#type == "EVSTR"))
        {
            "DXSTR"
        } else {
            "XSTR"
        };
        self.wrap(node_type, children, node)
    }

    pub(in crate::ast) fn normalize_chained_string(&mut self, node: TreeSitterNode<'_>) -> Node {
        let mut normalized_children = Vec::new();
        for child in self.named_children(node) {
            let normalized = self.normalize_node(child);
            normalized_children.push((child, normalized));
        }

        let mut parts = Vec::new();
        for (_, normalized) in &normalized_children {
            match normalized {
                Some(normalized) if normalized.r#type == "DSTR" => {
                    parts.extend(normalized.children.clone());
                }
                Some(normalized) => {
                    parts.push(Child::Node(Box::new(normalized.clone())));
                }
                None => {}
            }
        }

        let source = self
            .dynamic_string_source(&normalized_children)
            .or_else(|| normalized_children.first().map(|(child, _)| *child))
            .unwrap_or(node);
        self.wrap("DSTR", parts, source)
    }

    pub(in crate::ast) fn normalize_concatenated_string_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Node {
        let target = self
            .normalization_adapter
            .concatenated_string_target(node, self.source)
            .unwrap_or(node);
        let mut normalized_children = Vec::new();
        let children = self
            .normalization_adapter
            .concatenated_string_children(target, self.source)
            .unwrap_or_else(|| self.named_children(target));
        for child in children {
            let normalized = self.normalize_node(child);
            normalized_children.push((child, normalized));
        }

        let mut parts = Vec::new();
        for (_, normalized) in &normalized_children {
            match normalized {
                Some(normalized) if normalized.r#type == "DSTR" => {
                    parts.extend(normalized.children.clone());
                }
                Some(normalized) => {
                    parts.push(Child::Node(Box::new(normalized.clone())));
                }
                None => {}
            }
        }

        let source = self
            .dynamic_string_source(&normalized_children)
            .or_else(|| normalized_children.first().map(|(child, _)| *child))
            .unwrap_or(node);
        self.wrap("DSTR", parts, source)
    }

    pub(in crate::ast) fn dynamic_string_source<'tree>(
        &self,
        normalized_children: &[(TreeSitterNode<'tree>, Option<Node>)],
    ) -> Option<TreeSitterNode<'tree>> {
        normalized_children
            .iter()
            .find(|(_, child_node)| {
                let Some(child_node) = child_node else {
                    return false;
                };
                child_node.r#type == "DSTR"
                    && child_node
                        .children
                        .iter()
                        .filter_map(self::node)
                        .any(|part| part.r#type == "EVSTR")
            })
            .map(|(child, _)| *child)
    }

    pub(in crate::ast) fn normalize_interpolated_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Node {
        let children = self.normalize_children(node);
        self.wrap("DSTR", children, node)
    }

    pub(in crate::ast) fn normalize_interpolation(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let exprs = self
            .named_children(node)
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect::<Vec<_>>();
        let body = if exprs.len() == 1 {
            exprs.into_iter().next()
        } else if exprs.is_empty() {
            None
        } else {
            Some(self.list_node(exprs, node))
        };
        Some(
            self.wrap(
                "EVSTR",
                body.into_iter()
                    .map(|node| Child::Node(Box::new(node)))
                    .collect(),
                node,
            ),
        )
    }

    pub(in crate::ast) fn normalize_heredoc_body_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let heredoc_bodies = self.normalization_adapter.heredoc_body_nodes(node);
        let mut heredoc_bodies = heredoc_bodies.into_iter();
        let mut children = Vec::new();

        for child in self.named_children(node) {
            if self.normalization_adapter.heredoc_body_node(child) {
                continue;
            }

            let normalized = if self.heredoc_call_for_body(child) {
                let body = heredoc_bodies.next();
                self.with_current_heredoc_body(body, |normalizer| normalizer.normalize_node(child))
            } else {
                self.normalize_body(child)
            };

            if let Some(normalized) = normalized {
                children.push(normalized);
            }
        }

        if children.is_empty() {
            None
        } else if children.len() == 1 {
            children.into_iter().next()
        } else {
            Some(
                self.wrap(
                    "BLOCK",
                    children
                        .into_iter()
                        .map(|child| Child::Node(Box::new(child)))
                        .collect(),
                    node,
                ),
            )
        }
    }

    pub(in crate::ast) fn normalize_heredoc_beginning(&mut self, node: TreeSitterNode<'_>) -> Node {
        let mut heredoc_body = None;
        let mut ancestor = node.parent();
        while let Some(candidate) = ancestor {
            let bodies = self.normalization_adapter.heredoc_body_nodes(candidate);
            if !bodies.is_empty() {
                heredoc_body = if let Some(current) = self.current_heredoc_body_span {
                    bodies
                        .iter()
                        .copied()
                        .find(|body| span(*body) == current)
                        .or_else(|| bodies.first().copied())
                } else {
                    bodies.first().copied()
                };
                break;
            }
            ancestor = candidate.parent();
        }
        let children = heredoc_body
            .map(|body| self.normalize_heredoc_children(body))
            .unwrap_or_default();
        self.wrap("DSTR", children, node)
    }

    pub(in crate::ast) fn with_current_heredoc_body<T>(
        &mut self,
        body: Option<TreeSitterNode<'_>>,
        block: impl FnOnce(&mut Self) -> T,
    ) -> T {
        let previous = self.current_heredoc_body_span;
        self.current_heredoc_body_span = body.map(span);
        let result = block(self);
        self.current_heredoc_body_span = previous;
        result
    }

    pub(in crate::ast) fn normalize_heredoc_children(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Vec<Child> {
        self.named_children(node)
            .into_iter()
            .filter_map(|child| {
                if self.interpolation_node(child) {
                    self.normalize_interpolation(child)
                } else if self.normalization_adapter.heredoc_content_node(child) {
                    let text = node_text(child, self.source).to_string();
                    if text.is_empty() {
                        None
                    } else {
                        Some(self.wrap("STR", vec![Child::String(text)], child))
                    }
                } else {
                    None
                }
            })
            .map(|child| Child::Node(Box::new(child)))
            .collect()
    }

    pub(in crate::ast) fn normalize_identifier(&mut self, node: TreeSitterNode<'_>) -> Node {
        let name = self
            .identifier_text(node)
            .unwrap_or_else(|| node_text(node, self.source).to_string());
        self.normalize_identifier_with_name(node, name)
    }

    pub(in crate::ast) fn normalize_identifier_with_name(
        &mut self,
        node: TreeSitterNode<'_>,
        name: String,
    ) -> Node {
        if self.dynamic_vcall_identifier(node, &name) || self.vcall_identifier(node, &name) {
            self.wrap("VCALL", vec![Child::Symbol(name)], node)
        } else {
            self.wrap("LVAR", vec![Child::String(name)], node)
        }
    }

    pub(in crate::ast) fn normalize_function_parameters(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.normalization_adapter.normalize_default_parameters() {
            return None;
        }
        if let Some(params) = self
            .normalization_adapter
            .function_parameter_nodes(node, self.source)
        {
            return self.normalize_parameter_nodes(params, node);
        }
        self.normalize_parameters(self.parameters_child(node))
    }

    pub(in crate::ast) fn normalize_parameters(
        &mut self,
        node: Option<TreeSitterNode<'_>>,
    ) -> Option<Node> {
        if !self.normalization_adapter.normalize_default_parameters() {
            return None;
        }
        let node = node?;
        self.normalize_parameter_nodes(self.named_children(node), node)
    }

    pub(in crate::ast) fn normalize_parameter_nodes(
        &mut self,
        nodes: Vec<TreeSitterNode<'_>>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let pre_init = nodes
            .into_iter()
            .filter_map(|param| self.normalize_parameter_init(param))
            .map(|node| Child::Node(Box::new(node)))
            .collect::<Vec<_>>();
        if pre_init.is_empty() {
            None
        } else {
            Some(self.wrap("ARGS", pre_init, source))
        }
    }

    pub(in crate::ast) fn normalize_parameter_init(
        &mut self,
        param: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let name = self.parameter_name(param)?;
        let value = self
            .named_field(param, "value")
            .or_else(|| self.parameter_default_value(param))
            .and_then(|value| self.normalize_node(value));
        Some(self.wrap(
            "LASGN",
            vec![Child::Symbol(name), optional_node(value)],
            param,
        ))
    }

    pub(in crate::ast) fn parameter_name(&self, param: TreeSitterNode<'_>) -> Option<String> {
        if self
            .normalization_adapter
            .is_parameter_name_kind(param.kind())
        {
            if let Some(name) = self.identifier_text(param) {
                return Some(name);
            }
        }
        self.named_field(param, "name")
            .and_then(|name| self.identifier_text(name))
            .or_else(|| {
                self.named_children(param)
                    .into_iter()
                    .find_map(|child| self.identifier_text(child))
            })
    }

    pub(in crate::ast) fn parameter_default_value<'tree>(
        &self,
        param: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if !self
            .normalization_adapter
            .check_node_role(param, "optional_or_keyword_parameter")
        {
            return None;
        }
        let name = self.parameter_name(param)?;
        self.named_children(param).into_iter().rev().find(|child| {
            self.identifier_text(*child).as_deref() != Some(name.as_str())
                && !matches!(child.kind(), "comment")
        })
    }

    pub(in crate::ast) fn normalize_block_parameters(
        &mut self,
        block: Option<TreeSitterNode<'_>>,
    ) -> Option<Node> {
        if !self.normalization_adapter.normalize_block_parameters() {
            return None;
        }
        let block = block?;
        let params = self.named_children(block).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "block_parameters")
        })?;
        let mut pre_init = Vec::new();
        for param in self.named_children(params) {
            if self
                .normalization_adapter
                .check_node_role(param, "destructured_parameter")
            {
                if let Some(node) = self.normalize_destructured_block_parameter(param) {
                    pre_init.push(Child::Node(Box::new(node)));
                }
            } else if let Some(name) = self.parameter_name(param) {
                let lasgn = self.wrap("LASGN", vec![Child::Symbol(name), Child::Nil], param);
                pre_init.push(Child::Node(Box::new(lasgn)));
            }
        }
        if pre_init.is_empty() {
            None
        } else {
            Some(self.wrap("ARGS", pre_init, params))
        }
    }

    pub(in crate::ast) fn normalize_destructured_block_parameter(
        &mut self,
        param: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let mut targets = Vec::new();
        for child in self.named_children(param) {
            self.collect_destructured_parameter_targets(child, &mut targets);
        }
        if targets.is_empty() {
            return None;
        }
        let dvar = self.wrap("DVAR", vec![Child::Nil], param);
        Some(self.wrap(
            "MASGN",
            vec![
                Child::Node(Box::new(dvar)),
                list_or_nil(targets, param, self),
                Child::Nil,
            ],
            param,
        ))
    }

    pub(in crate::ast) fn collect_destructured_parameter_targets(
        &mut self,
        node: TreeSitterNode<'_>,
        targets: &mut Vec<Node>,
    ) {
        if self.identifier_kind(node.kind()) {
            targets.push(self.wrap(
                "DASGN",
                vec![
                    Child::String(node_text(node, self.source).to_string()),
                    Child::Nil,
                ],
                node,
            ));
            return;
        }

        for child in self.named_children(node) {
            self.collect_destructured_parameter_targets(child, targets);
        }
    }

    pub(in crate::ast) fn normalize_children(&mut self, node: TreeSitterNode<'_>) -> Vec<Child> {
        let mut children = Vec::new();
        for child in self.named_children(node) {
            if self.normalization_adapter.heredoc_body_node(child) {
                continue;
            }
            if self.assignment_rhs(child) {
                continue;
            }
            if let Some(normalized) = self.normalize_node(child) {
                children.push(Child::Node(Box::new(normalized)));
            }
        }
        children
    }

    pub(in crate::ast) fn scope(
        &self,
        body: Option<Node>,
        args: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let source_node = body.as_ref().or(args.as_ref()).cloned();
        let children = vec![Child::Nil, optional_node(args), optional_node(body)];
        if let Some(source_node) = source_node {
            self.wrap_from_source_node("SCOPE", children, &source_node)
        } else {
            self.wrap("SCOPE", children, source)
        }
    }

    pub(in crate::ast) fn list(
        &self,
        children: Option<Vec<Node>>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let children = children?;
        if children.is_empty() {
            return None;
        }

        Some(self.list_node(children, source))
    }

    pub(in crate::ast) fn list_node(
        &self,
        children: Vec<Node>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        self.wrap(
            "LIST",
            children
                .into_iter()
                .map(|child| Child::Node(Box::new(child)))
                .collect(),
            source,
        )
    }

    pub(in crate::ast) fn list_or_nil_from_source_node(
        &self,
        children: Vec<Node>,
        source: &Node,
    ) -> Child {
        if children.is_empty() {
            Child::Nil
        } else {
            Child::Node(Box::new(
                self.wrap_from_source_node(
                    "LIST",
                    children
                        .into_iter()
                        .map(|child| Child::Node(Box::new(child)))
                        .collect(),
                    source,
                ),
            ))
        }
    }

    pub(in crate::ast) fn wrap(
        &self,
        node_type: &str,
        children: Vec<Child>,
        source: TreeSitterNode<'_>,
    ) -> Node {
        let node_span = span(source);
        let normalized = Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: node_span[0],
            first_column: node_span[1],
            last_lineno: node_span[2],
            last_column: node_span[3],
            text: self.source_text(node_text(source, self.source)),
        };
        if self.parser_call_spans.contains(&node_span) && normalized_call(&normalized) {
            self.record_call_origin(node_span, &normalized);
        }
        normalized
    }

    fn record_call_origin(&self, raw_call_span: Span, normalized: &Node) {
        let normalized_call_span = primary_normalized_call_span(normalized).unwrap_or({
            [
                normalized.first_lineno,
                normalized.first_column,
                normalized.last_lineno,
                normalized.last_column,
            ]
        });
        self.call_raw_origins
            .borrow_mut()
            .push((raw_call_span, normalized_call_span));
    }

    pub(in crate::ast) fn wrap_from_nodes(
        &self,
        node_type: &str,
        children: Vec<Child>,
        first: TreeSitterNode<'_>,
        last: TreeSitterNode<'_>,
    ) -> Node {
        let first_span = span(first);
        let last_span = span(last);
        let text = self
            .source
            .get(first.start_byte()..last.end_byte())
            .unwrap_or("")
            .to_string();
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: first_span[0],
            first_column: first_span[1],
            last_lineno: last_span[2],
            last_column: last_span[3],
            text: self.source_text(&text),
        }
    }

    pub(in crate::ast) fn wrap_from_source_node(
        &self,
        node_type: &str,
        children: Vec<Child>,
        source: &Node,
    ) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: source.first_lineno,
            first_column: source.first_column,
            last_lineno: source.last_lineno,
            last_column: source.last_column,
            text: self.source_text(&source.text),
        }
    }

    pub(in crate::ast) fn instance_variable(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .instance_variable(node, self.source)
    }

    pub(in crate::ast) fn global_variable(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .global_variable(node, self.source)
    }

    pub(in crate::ast) fn assignment_operator(&self, text: &str) -> bool {
        self.normalization_adapter.assignment_operator(text)
    }

    pub(in crate::ast) fn vcall_identifier(&self, node: TreeSitterNode<'_>, name: &str) -> bool {
        if !self.identifier_kind(node.kind()) {
            return false;
        }
        if self.dynamic_syntax_enabled() && self.dynamic_local_name(name) {
            return false;
        }
        let Some(parent) = node.parent() else {
            return false;
        };
        if self
            .normalization_adapter
            .is_vcall_excluded_parent_kind(parent.kind())
        {
            return false;
        }
        if self.member_read_node(parent) {
            return false;
        }
        if self.dotted_expression(parent) {
            return false;
        }
        if self.assignment_lhs(node) || self.assignment_rhs(node) {
            return false;
        }

        if self
            .normalization_adapter
            .check_node_role(parent, "block_wrapper")
            || self.normalization_adapter.check_node_role(parent, "then")
                && self.parent_named_child(parent, node)
        {
            return true;
        }
        if self
            .normalization_adapter
            .conditional_modifier_kind(parent.kind())
            && self
                .named_children(parent)
                .into_iter()
                .next()
                .map(|child| child == node)
                .unwrap_or(false)
        {
            return true;
        }

        false
    }

    pub(in crate::ast) fn self_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.check_node_role(node, "self")
            || self.normalization_adapter.check_node_role(node, "this")
            || matches!(node_text(node, self.source), "self" | "this")
    }

    pub(in crate::ast) fn assignment_lhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.single_assignment_block_child(node) {
            return false;
        }
        if node
            .prev_sibling()
            .map(|sibling| node_text(sibling, self.source) == ":")
            .unwrap_or(false)
        {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        if self
            .normalization_adapter
            .non_local_assignment_lhs(node, self.source)
        {
            return false;
        }
        if let Some(parent) = node.parent() {
            if self
                .normalization_adapter
                .check_node_role(parent, "assignment")
            {
                if let Some(left) = self.assignment_left(parent) {
                    if self.same_ts_node(left, node) {
                        return true;
                    }
                }
            }
        }
        node.next_sibling()
            .map(|sibling| self.assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    pub(in crate::ast) fn literal_fragment_assignment_context(
        &self,
        node: TreeSitterNode<'_>,
    ) -> bool {
        self.normalization_adapter
            .literal_fragment_assignment_context(node, self.source)
    }

    pub(in crate::ast) fn literal_fragment_expression_list(
        &self,
        node: TreeSitterNode<'_>,
    ) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "expression_list")
        {
            return false;
        }

        let named = self.named_children(node);
        named.len() == 1 && self.literal_fragment_assignment_context(named[0])
    }

    pub(in crate::ast) fn assignment_rhs(&self, node: TreeSitterNode<'_>) -> bool {
        if self.single_assignment_block_child(node) {
            return false;
        }
        if self.literal_fragment_assignment_context(node) {
            return false;
        }
        node.prev_sibling()
            .map(|sibling| self.assignment_operator(node_text(sibling, self.source)))
            .unwrap_or(false)
    }

    pub(in crate::ast) fn single_assignment_block_child(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .single_assignment_block_child(node, self.source)
    }

    pub(in crate::ast) fn has_assignment_operator_child(&self, node: TreeSitterNode<'_>) -> bool {
        node.children(&mut node.walk()).any(|child| {
            !child.is_named() && self.assignment_operator(node_text(child, self.source))
        })
    }

    pub(in crate::ast) fn single_short_var_lhs(&self, node: TreeSitterNode<'_>) -> bool {
        let Some(parent) = node.parent() else {
            return false;
        };
        if !self
            .normalization_adapter
            .check_node_role(parent, "short_var_declaration")
        {
            return false;
        }
        if self.named_children(node).len() != 1 {
            return false;
        }
        self.named_children(parent)
            .into_iter()
            .next()
            .map(|child| child == node)
            .unwrap_or(false)
    }

    pub(in crate::ast) fn modifier_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let named = self.named_children(node);
        self.normalization_adapter
            .check_node_role(node, "block_wrapper")
            && self.modifier_keyword(node).is_some()
            && named.len() >= 2
    }

    pub(in crate::ast) fn modifier_return_action(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .check_node_role(node, "return_or_break")
    }

    pub(in crate::ast) fn leading_if_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_if_statement(node, self.source)
    }

    pub(in crate::ast) fn leading_if_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_if_target(node, self.source)
    }

    pub(in crate::ast) fn normalize_leading_if_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.leading_if_target(node).unwrap_or(node);
        if target != node {
            return self.normalize_if(target);
        }
        let keyword = target
            .children(&mut target.walk())
            .next()
            .map(|child| child.kind().to_string())?;
        let condition = self.named_children(target).into_iter().find(|child| {
            !self
                .normalization_adapter
                .conditional_branch_skip_kind(child.kind())
        })?;
        let consequence = self
            .named_children(target)
            .into_iter()
            .find(|child| {
                self.normalization_adapter
                    .conditional_consequence_kind(child.kind())
            })
            .or_else(|| self.branch_child(target, condition, 0));
        let alternative = self.explicit_alternative(target);
        let node_type = self
            .normalization_adapter
            .conditional_keyword_node_type(&keyword)
            .unwrap_or("IF");
        let condition = optional_node(self.normalize_node(condition));
        let consequence = optional_node(consequence.and_then(|child| self.normalize_body(child)));
        let alternative =
            optional_node(alternative.and_then(|child| self.normalize_else_or_branch(child)));
        Some(self.wrap(node_type, vec![condition, consequence, alternative], target))
    }

    pub(in crate::ast) fn leading_case_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_case_statement(node, self.source)
    }

    pub(in crate::ast) fn leading_case_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_case_target(node, self.source)
    }

    pub(in crate::ast) fn normalize_leading_case_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.leading_case_target(node).unwrap_or(node);
        self.normalize_case(target)
    }

    pub(in crate::ast) fn special_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .normalized_for_parts(node, self.source)
            .is_some()
            || self
                .normalization_adapter
                .normalized_with_parts(node, self.source)
                .is_some()
    }

    pub(in crate::ast) fn normalize_special_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if let Some((target, iterable, body)) = self
            .normalization_adapter
            .normalized_for_parts(node, self.source)
        {
            let target = self.normalize_node(target);
            let iterable = self.normalize_node(iterable);
            let body = body.and_then(|body| self.normalize_body(body));
            return Some(self.wrap(
                "FOR",
                vec![
                    optional_node(target),
                    optional_node(iterable),
                    optional_node(body),
                ],
                node,
            ));
        }

        if let Some((contexts, body)) = self
            .normalization_adapter
            .normalized_with_parts(node, self.source)
        {
            let mut contexts = contexts
                .into_iter()
                .filter_map(|context| self.normalize_node(context))
                .collect::<Vec<_>>();
            let context = match contexts.len() {
                0 => None,
                1 => contexts.pop(),
                _ => Some(
                    self.wrap(
                        "LIST",
                        contexts
                            .into_iter()
                            .map(|context| Child::Node(Box::new(context)))
                            .collect(),
                        node,
                    ),
                ),
            };
            let body = body.and_then(|body| self.normalize_body(body));
            return Some(self.wrap(
                "WITH",
                vec![optional_node(context), optional_node(body)],
                node,
            ));
        }

        None
    }

    pub(in crate::ast) fn leading_loop_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_loop_statement(node, self.source)
    }

    pub(in crate::ast) fn leading_loop_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_loop_target(node, self.source)
    }

    pub(in crate::ast) fn normalize_leading_loop_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.leading_loop_target(node).unwrap_or(node);
        if target != node {
            let keyword = target.children(&mut target.walk()).next()?.kind();
            let node_type = self.loop_node_type(keyword).unwrap_or("WHILE");
            return self.normalize_loop(target, node_type);
        }
        let keyword = target.children(&mut target.walk()).next()?.kind();
        let node_type = self.loop_node_type(keyword).unwrap_or("WHILE");
        let named = self.named_children(target);
        let condition = optional_node(
            named
                .first()
                .and_then(|condition| self.normalize_node(*condition)),
        );
        let body = optional_node(
            named
                .get(1)
                .and_then(|body| self.normalize_control_body(*body)),
        );
        Some(self.wrap(node_type, vec![condition, body], target))
    }

    pub(in crate::ast) fn normalize_leading_owner_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.leading_owner_target(node).unwrap_or(node);
        let _keyword = target.children(&mut target.walk()).next()?.kind();
        let name = self.const_for(self.named_children(target).first().copied(), target);
        let body_node = self.named_field(target, "body").or_else(|| {
            self.named_children(target)
                .into_iter()
                .rev()
                .find(|child| self.block_kind(child.kind()))
        });
        let body = body_node.and_then(|body| self.normalize_body(body));
        if self.module_node(target) {
            Some(self.wrap(
                "MODULE",
                vec![
                    Child::Node(Box::new(name)),
                    Child::Node(Box::new(self.scope(body, None, target))),
                ],
                target,
            ))
        } else {
            Some(self.wrap(
                "CLASS",
                vec![
                    Child::Node(Box::new(name)),
                    Child::Nil,
                    Child::Node(Box::new(self.scope(body, None, target))),
                ],
                target,
            ))
        }
    }

    pub(in crate::ast) fn rescue_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .rescue_body_statement(node, self.source)
    }

    pub(in crate::ast) fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .rescue_body_target(node, self.source)
    }

    pub(in crate::ast) fn normalize_rescue_body_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.rescue_body_target(node)?;
        let body_nodes = self
            .normalization_adapter
            .rescue_body_nodes(target, self.source);
        let body = self.normalize_body_nodes(body_nodes.clone(), target);
        let rescue_nodes = self
            .normalization_adapter
            .rescue_clauses(target, self.source);
        let resbodies = rescue_nodes
            .iter()
            .filter_map(|child| self.normalize_rescue_clause(*child))
            .collect::<Vec<_>>();
        let source_start = body_nodes.first().copied().unwrap_or(target);
        let source_end = rescue_nodes
            .last()
            .and_then(|last| self.rescue_source_end(*last))
            .or_else(|| rescue_nodes.last().copied())
            .unwrap_or(target);
        let source = self.source_from_nodes(source_start, source_end);
        Some(self.wrap_from_source_node(
            "RESCUE",
            vec![
                optional_node(body),
                optional_node(self.link_rescue_chain(resbodies)),
                Child::Nil,
            ],
            &source,
        ))
    }

    pub(in crate::ast) fn ensure_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .ensure_body_statement(node, self.source)
    }

    pub(in crate::ast) fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .ensure_body_target(node, self.source)
    }

    pub(in crate::ast) fn normalize_ensure_body_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self.ensure_body_target(node)?;
        let body = if self.rescue_body_statement(target) {
            self.normalize_rescue_body_statement(target)
        } else {
            let body_nodes = self
                .normalization_adapter
                .ensure_body_nodes(target, self.source);
            self.normalize_body_nodes(body_nodes, target)
        };
        let ensure_node = self
            .normalization_adapter
            .ensure_clause(target, self.source)?;
        let ensure_body_node = self
            .normalization_adapter
            .ensure_clause_body(ensure_node)
            .unwrap_or(ensure_node);
        let ensure_body = self.normalize_control_body(ensure_body_node);
        let source = body.clone();
        let children = vec![optional_node(body), optional_node(ensure_body)];
        if let Some(source) = source.as_ref() {
            Some(self.wrap_from_source_node("ENSURE", children, source))
        } else {
            Some(self.wrap("ENSURE", children, target))
        }
    }

    pub(in crate::ast) fn command_call_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .is_command_call_wrapper_kind(node.kind())
            || self.dotted_call(node)
        {
            return false;
        }

        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && self
                .normalization_adapter
                .check_node_role(raw_named[0], "call")
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let children = self.named_children(target);
        children
            .first()
            .map(|child| self.identifier_kind(child.kind()))
            .unwrap_or(false)
            && (children.iter().any(|child| {
                self.normalization_adapter
                    .check_node_role(*child, "argument_list")
            }) || self.call_block(target).is_some())
    }

    pub(in crate::ast) fn visibility_inline_def_call(&self, node: TreeSitterNode<'_>) -> bool {
        if !self.normalization_adapter.check_node_role(node, "call") {
            return false;
        }
        let Some(message) = self.named_children(node).into_iter().next() else {
            return false;
        };
        if !self
            .normalization_adapter
            .inline_def_wrapper_mid(node_text(message, self.source))
        {
            return false;
        }
        self.named_children(node)
            .into_iter()
            .find(|child| {
                self.normalization_adapter
                    .check_node_role(*child, "argument_list")
            })
            .map(|args| {
                node_text(args, self.source)
                    .trim_start()
                    .starts_with("def ")
            })
            .unwrap_or(false)
    }

    pub(in crate::ast) fn visibility_inline_def_statement(
        &self,
        node: TreeSitterNode<'_>,
        function: TreeSitterNode<'_>,
    ) -> bool {
        let function_text_source = self
            .normalization_adapter
            .inline_def_function_text_source(function, self.source);
        let function_text = node_text(function_text_source, self.source);
        self.normalization_adapter
            .inline_def_wrapper_mid(function_text)
            && node_text(node, self.source).contains("def ")
    }

    pub(in crate::ast) fn inline_def_from_argument_list(
        &mut self,
        args: Option<TreeSitterNode<'_>>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled() {
            return None;
        }
        self.inline_def_from_source(args?)
    }

    pub(in crate::ast) fn inline_def_from_statement(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let target = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let source = self
            .named_children(target)
            .into_iter()
            .find(|child| {
                self.normalization_adapter
                    .check_node_role(*child, "argument_list")
            })
            .unwrap_or(target);
        self.inline_def_from_source(source)
    }

    pub(in crate::ast) fn inline_def_from_source(
        &mut self,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled() {
            return None;
        }
        if let Some(method) = self.named_children(source).into_iter().find(|child| {
            self.normalization_adapter
                .inline_def_function_kind(child.kind())
        }) {
            return if self.singleton_function_kind(method.kind()) {
                self.normalize_singleton_function(method)
            } else {
                self.normalize_function(method)
            };
        }
        let body = self.inline_def_body(source);
        let receiver = self.inline_def_receiver(source);
        let normalized_body = self.with_dynamic_scope(source, true, |normalizer| {
            let body = body.and_then(|body| normalizer.normalize_body(body));
            normalizer.elide_tail_returns(body)
        });
        if let Some(receiver) = receiver {
            let name = self.inline_def_name_after_receiver(source, receiver)?;
            if name.is_empty() {
                return None;
            }
            let receiver = self.normalize_node(receiver)?;
            return Some(self.wrap(
                "DEFS",
                vec![
                    Child::Node(Box::new(receiver)),
                    Child::Symbol(name),
                    Child::Node(Box::new(self.scope(normalized_body, None, source))),
                ],
                source,
            ));
        }

        let name = self
            .named_children(source)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))
            .map(|child| node_text(child, self.source).to_string())?;
        if name.is_empty() {
            return None;
        }
        Some(self.wrap(
            "DEFN",
            vec![
                Child::Symbol(name),
                Child::Node(Box::new(self.scope(normalized_body, None, source))),
            ],
            source,
        ))
    }

    pub(in crate::ast) fn inline_def_receiver<'tree>(
        &self,
        source: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let text = node_text(source, self.source);
        if !self.normalization_adapter.inline_def_receiver_text(text) {
            return None;
        }
        let children = self.named_children(source);
        if children.len() == 1
            && self
                .normalization_adapter
                .inline_def_function_kind(children[0].kind())
            && node_text(children[0], self.source) == text
        {
            return self.inline_def_receiver(children[0]);
        }

        children.into_iter().find(|child| {
            self.normalization_adapter
                .is_inline_def_receiver_kind(child.kind())
        })
    }

    pub(in crate::ast) fn inline_def_name_after_receiver(
        &self,
        source: TreeSitterNode<'_>,
        receiver: TreeSitterNode<'_>,
    ) -> Option<String> {
        let children = self.named_children(source);
        if let Some(index) = children
            .iter()
            .position(|child| self.same_ts_node(*child, receiver))
        {
            return children
                .into_iter()
                .skip(index + 1)
                .find(|child| self.identifier_kind(child.kind()))
                .map(|child| node_text(child, self.source).to_string());
        }

        if children.len() == 1
            && self
                .normalization_adapter
                .inline_def_function_kind(children[0].kind())
            && node_text(children[0], self.source) == node_text(source, self.source)
        {
            return self.inline_def_name_after_receiver(children[0], receiver);
        }

        None
    }

    pub(in crate::ast) fn inline_def_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let mut stack = self
            .named_children(node)
            .into_iter()
            .rev()
            .collect::<Vec<_>>();
        while let Some(child) = stack.pop() {
            if self
                .normalization_adapter
                .check_node_role(child, "body_statement")
            {
                return Some(child);
            }
            stack.extend(self.named_children(child).into_iter().rev());
        }
        None
    }

    pub(in crate::ast) fn modifier_keyword(&self, node: TreeSitterNode<'_>) -> Option<String> {
        let mut seen_named = false;
        for child in node.children(&mut node.walk()) {
            seen_named = seen_named || child.is_named();
            if seen_named
                && !child.is_named()
                && self
                    .normalization_adapter
                    .modifier_node_type(child.kind())
                    .is_some()
            {
                return Some(child.kind().to_string());
            }
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            return self.modifier_keyword(raw_named[0]);
        }

        None
    }

    pub(in crate::ast) fn modifier_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, TreeSitterNode<'tree>)> {
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(raw_named[0], self.source) == node_text(node, self.source)
        {
            if let Some(parts) = self.modifier_parts(raw_named[0]) {
                return Some(parts);
            }
        }

        let named = self.named_children(node);
        Some((*named.first()?, *named.last()?))
    }

    pub(in crate::ast) fn ternary_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .ternary_statement(node, self.source)
    }

    pub(in crate::ast) fn ternary_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TernaryParts<'tree>> {
        self.normalization_adapter.ternary_parts(node, self.source)
    }

    pub(in crate::ast) fn case_argument_list(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .case_argument_list(node, self.source)
    }

    pub(in crate::ast) fn leading_function_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_function_statement(node, self.source)
    }

    pub(in crate::ast) fn leading_owner_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .leading_owner_statement(node, self.source)
    }

    pub(in crate::ast) fn leading_owner_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_owner_target(node, self.source)
    }

    pub(in crate::ast) fn leading_function_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .leading_function_target(node, self.source)
    }

    pub(in crate::ast) fn leading_function_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node)
            .into_iter()
            .find(|child| self.identifier_kind(child.kind()))
    }

    pub(in crate::ast) fn leading_function_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let body_kind = self.normalization_adapter.leading_function_body_kind();
        self.named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == body_kind)
    }

    pub(in crate::ast) fn zero_child_identifier_call(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .zero_child_identifier_call(node, self.source)
    }

    pub(in crate::ast) fn boolean_expression(&self, node: TreeSitterNode<'_>) -> bool {
        (self.normalization_adapter.boolean_expression_kind(node) || self.boolean_statement(node))
            && matches!(self.boolean_operator(node).as_deref(), Some("and" | "or"))
    }

    pub(in crate::ast) fn boolean_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .is_boolean_statement_wrapper_kind(node.kind())
        {
            return false;
        }
        let named = self.named_children(node);
        let target = self
            .normalization_adapter
            .boolean_statement_target(node, self.source, &named);
        if !matches!(
            self.binary_operator(target).as_deref(),
            Some("&&" | "||" | "and" | "or")
        ) {
            return false;
        }
        if self.named_children(target).len() < 2 {
            return false;
        }
        target.children(&mut target.walk()).all(|child| {
            child.is_named()
                || matches!(
                    node_text(child, self.source),
                    "&&" | "||" | "and" | "or" | "(" | ")"
                )
        })
    }

    pub(in crate::ast) fn operator_call_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .operator_call_expression_kind(node)
            && self.named_children(node).len() >= 2
            && self
                .binary_operator(node)
                .map(|operator| OPERATOR_CALL_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    pub(in crate::ast) fn comparison_expression(&self, node: TreeSitterNode<'_>) -> bool {
        if self.literal_fragment_expression_list(node) {
            return false;
        }

        self.normalization_adapter.comparison_expression_kind(node)
            && self
                .comparison_operator(node)
                .map(|operator| COMPARISON_OPERATORS.contains(&operator.as_str()))
                .unwrap_or(false)
    }

    pub(in crate::ast) fn infix_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.infix_statement_parts(node).is_some()
    }

    pub(in crate::ast) fn regex_literal(&self, node: Option<TreeSitterNode<'_>>) -> bool {
        node.map(|node| {
            self.normalization_adapter
                .check_node_role(node, "regex_or_literal")
        })
        .unwrap_or(false)
    }

    pub(in crate::ast) fn argument_list_unary_not(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "argument_list")
        {
            return false;
        }
        let named = self.named_children(node);
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| node_text(child, self.source) == "!")
            .unwrap_or(false)
            && named.len() == 1
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() != 1
            || !self
                .normalization_adapter
                .check_node_role(raw_named[0], "unary")
        {
            return false;
        }
        node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_not_expression(raw_named[0])
            && self.raw_named_children(raw_named[0]).len() == 1
    }

    pub(in crate::ast) fn unary_not_statement(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .is_statement_wrapper_kind(node.kind())
        {
            return false;
        }
        let named = self.named_children(node);
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| node_text(child, self.source) == "!")
            .unwrap_or(false)
            && named.len() == 1
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && self
                .normalization_adapter
                .check_node_role(raw_named[0], "unary")
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_not_expression(raw_named[0])
            && self.raw_named_children(raw_named[0]).len() == 1
    }

    pub(in crate::ast) fn unary_not_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .unary_not_expression(node, self.source)
    }

    pub(in crate::ast) fn unary_minus_expression(&self, node: TreeSitterNode<'_>) -> bool {
        if self
            .normalization_adapter
            .unary_minus_expression(node, self.source)
        {
            return true;
        }

        let raw_named = self.raw_named_children(node);
        raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.unary_minus_expression(raw_named[0])
    }

    pub(in crate::ast) fn infix_statement_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String, TreeSitterNode<'tree>)> {
        if !self
            .normalization_adapter
            .is_statement_wrapper_kind(node.kind())
        {
            return None;
        }
        let raw_named = self.raw_named_children(node);
        let target = if raw_named.len() == 1
            && self
                .normalization_adapter
                .is_infix_target_kind(raw_named[0].kind())
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
        {
            raw_named[0]
        } else {
            node
        };
        let mut named_index = 0usize;
        let mut left = None;
        let mut right = None;
        let mut operator = None;
        for child in target.children(&mut target.walk()) {
            if child.is_named() {
                left.get_or_insert(child);
                if operator.is_some() {
                    right = Some(child);
                }
                named_index += 1;
            } else {
                let text = node_text(child, self.source);
                if COMPARISON_OPERATORS.contains(&text) || OPERATOR_CALL_OPERATORS.contains(&text) {
                    operator = Some(text.to_string());
                }
            }
        }
        if named_index == 2 {
            Some((left?, operator?, right?))
        } else {
            None
        }
    }

    pub(in crate::ast) fn boolean_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        let direct = self.binary_operator(node)?;
        if matches!(direct.as_str(), "&&" | "and") {
            Some("and".to_string())
        } else if matches!(direct.as_str(), "||" | "or") {
            Some("or".to_string())
        } else {
            None
        }
    }

    pub(in crate::ast) fn comparison_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if let Some(operator) = self.binary_operator(node) {
            if COMPARISON_OPERATORS.contains(&operator.as_str()) {
                return Some(operator);
            }
        }

        comparison_operator_from_text(&self.spaced_text(node))
    }

    pub(in crate::ast) fn binary_operator(&self, node: TreeSitterNode<'_>) -> Option<String> {
        self.normalization_adapter
            .binary_operator(node, self.source)
    }

    pub(in crate::ast) fn spaced_text(&self, node: TreeSitterNode<'_>) -> String {
        format!(" {} ", node_text(node, self.source))
    }

    pub(in crate::ast) fn class_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.class_node(node)
    }

    pub(in crate::ast) fn module_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.check_node_role(node, "module")
            && self.named_field(node, "name").is_some()
    }

    pub(in crate::ast) fn interpolated_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let children = self.named_children(node);
        self.normalization_adapter
            .interpolated_statement(node, &children)
    }

    pub(in crate::ast) fn concatenated_string_statement(&self, node: TreeSitterNode<'_>) -> bool {
        let children = self.named_children(node);
        self.normalization_adapter
            .concatenated_string_statement(node, self.source, &children)
    }

    pub(in crate::ast) fn concatenated_string_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.concatenated_string_node(node)
    }

    pub(in crate::ast) fn interpolated_string(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .interpolated_string(node, &self.named_children(node))
    }

    pub(in crate::ast) fn lambda_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .lambda_expression(node, self.source)
    }

    pub(in crate::ast) fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.lambda_target(node, self.source)
    }

    pub(in crate::ast) fn interpolation_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.interpolation_node(node)
    }

    pub(in crate::ast) fn statement_call_with_block(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .check_node_role(node, "block_wrapper")
            && self.call_block(node).is_some()
            && self.statement_block_call(node).is_some()
    }

    pub(in crate::ast) fn statement_block_call<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if self.dotted_call(node) {
            return Some(node);
        }

        let block = self.call_block(node);
        let child_source = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);
        let children = self.named_children(child_source);

        children.into_iter().find(|child| {
            Some(*child) != block && (self.call_node(*child) || self.member_read_node(*child))
        })
    }

    pub(in crate::ast) fn yield_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .yield_statement(node, self.source)
    }

    pub(in crate::ast) fn yield_argument_list(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "argument_list")
        {
            return false;
        }
        let Some(parent) = self.parent_node(node) else {
            return false;
        };
        let mut cursor = parent.walk();
        let first_child_is_yield = parent
            .children(&mut cursor)
            .next()
            .map(|child| node_text(child, self.source) == "yield")
            .unwrap_or(false);
        first_child_is_yield
    }

    pub(in crate::ast) fn super_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .super_statement(node, self.source)
    }

    pub(in crate::ast) fn argument_list_element_reference(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "argument_list")
        {
            return false;
        }
        let named = self.named_children(node);
        if named.iter().any(|child| {
            self.normalization_adapter
                .check_node_role(*child, "block_or_do_block")
        }) {
            return false;
        }

        let children = node.children(&mut node.walk()).collect::<Vec<_>>();
        let direct_bracket_shape = children
            .first()
            .map(|child| node_text(*child, self.source) != "[")
            .unwrap_or(false)
            && children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "[")
            && children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "]")
            && named.len() >= 2;
        if direct_bracket_shape {
            return true;
        }

        if named.len() != 1
            || !self
                .normalization_adapter
                .check_node_role(named[0], "element_reference")
        {
            return false;
        }
        let reference = named[0];
        let reference_named = self.raw_named_children(reference);
        if reference_named.len() < 2
            || reference_named.iter().any(|child| {
                self.normalization_adapter
                    .check_node_role(*child, "block_or_do_block")
            })
        {
            return false;
        }
        let reference_children = reference
            .children(&mut reference.walk())
            .collect::<Vec<_>>();
        reference_children
            .first()
            .map(|child| node_text(*child, self.source) != "[")
            .unwrap_or(false)
            && reference_children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "[")
            && reference_children
                .iter()
                .any(|child| !child.is_named() && node_text(*child, self.source) == "]")
    }

    pub(in crate::ast) fn dotted_expression(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter.dotted_expression_wrapper(node) && self.dotted_call(node)
    }

    pub(in crate::ast) fn argument_list_call_with_block(&self, node: TreeSitterNode<'_>) -> bool {
        if !self
            .normalization_adapter
            .check_node_role(node, "argument_list")
            || self.dotted_call(node)
        {
            return false;
        }

        let target = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
            .unwrap_or(node);

        self.call_block(target).is_some()
            && self
                .named_children(target)
                .into_iter()
                .next()
                .map(|child| self.identifier_text(child).is_some())
                .unwrap_or(false)
    }

    pub(in crate::ast) fn dotted_call(&self, node: TreeSitterNode<'_>) -> bool {
        if node.kind() == "generic_function" {
            return false;
        }
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.dotted_call(raw_named[0])
        {
            return true;
        }

        // Some grammars (notably Go) wrap `receiver.member()` in a call node
        // whose first named child is the member selector and whose second
        // child is the argument list. The outer call node has no `.` token of
        // its own, so checking only its direct children silently degrades a
        // zero-argument method invocation into a property read.
        if raw_named.len() >= 2
            && self.dotted_call(raw_named[0])
            && raw_named[1..].iter().all(|child| {
                self.normalization_adapter
                    .is_call_block_or_arg_kind(child.kind())
            })
        {
            return true;
        }

        if !node
            .children(&mut node.walk())
            .any(|child| self.member_access_operator(node_text(child, self.source)))
        {
            return false;
        }
        let callable = self
            .named_children(node)
            .into_iter()
            .filter(|child| {
                !self
                    .normalization_adapter
                    .is_call_block_or_arg_kind(child.kind())
            })
            .collect::<Vec<_>>();
        if callable.iter().any(|child| {
            self.normalization_adapter
                .check_node_role(*child, "string_content_or_interpolation")
        }) {
            return false;
        }
        callable.len() >= 2
    }

    pub(in crate::ast) fn safe_navigation_call(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .safe_navigation_call(node, self.source)
    }

    pub(in crate::ast) fn dotted_call_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        block: Option<TreeSitterNode<'tree>>,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source) == node_text(raw_named[0], self.source)
            && self.dotted_call(raw_named[0])
        {
            return self.dotted_call_parts(raw_named[0], block);
        }

        if raw_named.len() >= 2
            && self.dotted_call(raw_named[0])
            && raw_named[1..].iter().all(|child| {
                self.normalization_adapter
                    .is_call_block_or_arg_kind(child.kind())
            })
        {
            return self.dotted_call_parts(raw_named[0], block);
        }

        let callable = self
            .named_children(node)
            .into_iter()
            .filter(|child| Some(*child) != block)
            .filter(|child| {
                !self
                    .normalization_adapter
                    .is_call_block_or_arg_kind(child.kind())
            })
            .collect::<Vec<_>>();
        let receiver = *callable.first()?;
        let method = node_text(*callable.get(1)?, self.source)
            .trim_start_matches("::")
            .trim_start_matches("->")
            .trim_start_matches(['.', '?'])
            .trim_end_matches('=')
            .to_string();
        Some((receiver, method))
    }

    pub(in crate::ast) fn member_read_node(&self, node: TreeSitterNode<'_>) -> bool {
        if self.normalization_adapter.member_read_excluded(node) {
            return false;
        }
        self.normalization_adapter.is_member_read_kind(node.kind())
            && self.member_parts(node).is_some()
    }

    pub(in crate::ast) fn member_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<(TreeSitterNode<'tree>, String)> {
        if self
            .normalization_adapter
            .check_node_role(node, "expression_list")
            && !(self.named_field(node, "operand").is_some()
                && self.named_field(node, "field").is_some())
        {
            return None;
        }
        if self.dotted_call(node) {
            return self.dotted_call_parts(node, None);
        }
        let named_children = self.named_children(node);
        let receiver = self
            .named_field(node, "receiver")
            .or_else(|| self.named_field(node, "object"))
            .or_else(|| self.named_field(node, "operand"))
            .or_else(|| self.named_field(node, "value"))
            .or_else(|| self.named_field(node, "expression"))
            .or_else(|| {
                named_children.iter().copied().find(|child| {
                    !self
                        .normalization_adapter
                        .check_node_role(*child, "navigation_suffix")
                })
            })?;
        let method = self
            .named_field(node, "method")
            .or_else(|| self.named_field(node, "field"))
            .or_else(|| self.named_field(node, "property"))
            .or_else(|| self.named_field(node, "suffix"))
            .or_else(|| {
                named_children.iter().copied().find(|child| {
                    self.normalization_adapter
                        .check_node_role(*child, "navigation_suffix")
                })
            })
            .or_else(|| {
                named_children.iter().copied().rev().find(|child| {
                    !self
                        .normalization_adapter
                        .is_call_block_or_arg_kind(child.kind())
                })
            })?;
        (receiver != method).then(|| {
            (
                receiver,
                self.member_name(method).trim_end_matches('=').to_string(),
            )
        })
    }

    pub(in crate::ast) fn member_name(&self, node: TreeSitterNode<'_>) -> String {
        if self
            .normalization_adapter
            .check_node_role(node, "navigation_suffix")
        {
            let named_children = self.named_children(node);
            let suffix = self
                .named_field(node, "suffix")
                .or_else(|| {
                    named_children
                        .iter()
                        .copied()
                        .find(|child| self.identifier_kind(child.kind()))
                })
                .or_else(|| named_children.last().copied());
            return suffix
                .map(|suffix| {
                    node_text(suffix, self.source)
                        .trim_start_matches("::")
                        .trim_start_matches("->")
                        .trim_start_matches(['.', '?'])
                        .to_string()
                })
                .unwrap_or_default();
        }

        node_text(node, self.source)
            .trim_start_matches("::")
            .trim_start_matches("->")
            .trim_start_matches(['.', '?'])
            .to_string()
    }

    pub(in crate::ast) fn call_arguments(
        &mut self,
        node: TreeSitterNode<'_>,
        function: Option<TreeSitterNode<'_>>,
    ) -> Vec<Node> {
        if let Some(children) =
            self.normalization_adapter
                .call_argument_nodes(node, function, self.source)
        {
            return children
                .into_iter()
                .filter_map(|child| self.normalize_node(child))
                .collect();
        }
        let Some(args) = self
            .named_field(node, "arguments")
            .or_else(|| self.named_field(node, "argument"))
            .or_else(|| {
                self.named_children(node).into_iter().find(|child| {
                    self.normalization_adapter
                        .check_node_role(*child, "argument_list")
                })
            })
        else {
            return Vec::new();
        };
        let children = self
            .named_children(args)
            .into_iter()
            .filter(|child| Some(*child) != function)
            .collect::<Vec<_>>();
        if self.dotted_expression(args) {
            return self.normalize_dotted_expression(args).into_iter().collect();
        }
        let raw_args = self.raw_named_children(args);
        if raw_args.len() == 1 && self.dotted_call(raw_args[0]) && self.call_node(raw_args[0]) {
            let source = self.wrap("SOURCE", Vec::new(), args);
            self.record_call_origin(span(raw_args[0]), &source);
            return self
                .normalize_dotted_call_expression_with_source(raw_args[0], Some(&source))
                .into_iter()
                .collect();
        }
        if self
            .normalization_adapter
            .heredoc_literal_argument(args, self.source, &children)
            && !children.is_empty()
        {
            return self.literal_arguments_from_text(args);
        }
        if children.is_empty() {
            return self
                .scalar_argument_list_value(args)
                .into_iter()
                .chain(self.literal_arguments_from_text(args))
                .collect();
        }
        if self.infix_statement(args) {
            return self.normalize_infix_statement(args).into_iter().collect();
        }

        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    pub(in crate::ast) fn literal_arguments_from_text(
        &mut self,
        args: TreeSitterNode<'_>,
    ) -> Vec<Node> {
        let text = node_text(args, self.source);
        if self
            .normalization_adapter
            .heredoc_literal_argument(args, self.source, &[])
        {
            return vec![self.normalize_heredoc_beginning(args)];
        }

        literal_symbol_arguments(text)
            .into_iter()
            .map(|name| self.wrap("LIT", vec![Child::Symbol(name)], args))
            .collect()
    }

    pub(in crate::ast) fn command_arguments(&mut self, args: TreeSitterNode<'_>) -> Vec<Node> {
        let children = self.named_children(args);
        if children.is_empty() {
            return self.scalar_argument_list_value(args).into_iter().collect();
        }
        if self.infix_statement(args) {
            return self.normalize_infix_statement(args).into_iter().collect();
        }
        if self.dotted_expression(args) {
            return self.normalize_dotted_expression(args).into_iter().collect();
        }
        if children.len() == 1
            && self.call_node(children[0])
            && self.call_block(children[0]).is_some()
        {
            return self
                .normalize_call_with_block(children[0])
                .into_iter()
                .collect();
        }
        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    pub(in crate::ast) fn yield_argument_nodes(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        let children = self.named_children(node);
        if children.is_empty() {
            return self.scalar_argument_list_value(node).into_iter().collect();
        }
        children
            .into_iter()
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    pub(in crate::ast) fn yield_inline_arguments(&mut self, node: TreeSitterNode<'_>) -> Vec<Node> {
        self.named_children(node)
            .into_iter()
            .filter(|child| !self.normalization_adapter.check_node_role(*child, "yield"))
            .filter_map(|child| self.normalize_node(child))
            .collect()
    }

    pub(in crate::ast) fn scalar_argument_list_value(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let text = node_text(node, self.source).trim();
        if self.dynamic_syntax_enabled() && self.identifier_kind(node.kind()) && text == "yield" {
            return Some(self.wrap("YIELD", vec![Child::Nil], node));
        }
        if text == "nil" {
            return Some(self.wrap("NIL", Vec::new(), node));
        }
        if text == "true" {
            return Some(self.wrap("TRUE", Vec::new(), node));
        }
        if text == "false" {
            return Some(self.wrap("FALSE", Vec::new(), node));
        }
        if let Some(symbol) = text.strip_prefix(':') {
            if bare_identifier_text(symbol) {
                return Some(self.wrap("LIT", vec![Child::Symbol(symbol.to_string())], node));
            }
        }
        if let Ok(value) = text.parse::<i64>() {
            return Some(self.wrap("INTEGER", vec![Child::Integer(value)], node));
        }
        if bare_identifier_text(text) {
            if self.dynamic_syntax_enabled() && !self.dynamic_local_name(text) {
                Some(self.wrap("VCALL", vec![Child::Symbol(text.to_string())], node))
            } else {
                Some(self.wrap("LVAR", vec![Child::String(text.to_string())], node))
            }
        } else {
            None
        }
    }

    pub(in crate::ast) fn local_or_call_for_name(
        &self,
        name: &str,
        source: TreeSitterNode<'_>,
    ) -> Node {
        if self.dynamic_syntax_enabled() && !self.dynamic_local_name(name) {
            self.wrap("VCALL", vec![Child::Symbol(name.to_string())], source)
        } else {
            self.wrap("LVAR", vec![Child::String(name.to_string())], source)
        }
    }

    pub(in crate::ast) fn normalize_dynamic_scope(&self, node: Node) -> Node {
        if self.dynamic_syntax_enabled() {
            dynamic_scope(node)
        } else {
            node
        }
    }

    pub(in crate::ast) fn symbol_literal_node(&self, node: Option<&Node>) -> bool {
        matches!(
            node,
            Some(node)
                if node.r#type == "LIT" && matches!(node.children.first(), Some(Child::Symbol(_)))
        )
    }

    pub(in crate::ast) fn same_ts_node(
        &self,
        left: TreeSitterNode<'_>,
        right: TreeSitterNode<'_>,
    ) -> bool {
        left.kind() == right.kind()
            && left.start_byte() == right.start_byte()
            && left.end_byte() == right.end_byte()
    }

    pub(in crate::ast) fn parent_named_child(
        &self,
        parent: TreeSitterNode<'_>,
        node: TreeSitterNode<'_>,
    ) -> bool {
        self.named_children(parent)
            .into_iter()
            .any(|child| self.same_ts_node(child, node))
    }

    pub(in crate::ast) fn node_key(&self, node: TreeSitterNode<'_>) -> (String, usize, usize) {
        (node.kind().to_string(), node.start_byte(), node.end_byte())
    }

    pub(in crate::ast) fn hidden_match(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .check_node_role(node, "expression_statement")
            && node_text(node, self.source)
                .trim_start()
                .starts_with("match ")
            && self.named_children(node).into_iter().any(|child| {
                self.normalization_adapter
                    .check_node_role(child, "match_block")
            })
    }

    pub(in crate::ast) fn assignment_left<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "annotated_assignment" {
            return self.named_field(node, "name");
        }
        self.named_field(node, "left")
            .or_else(|| self.named_children(node).into_iter().next())
    }

    pub(in crate::ast) fn assignment_right<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "annotated_assignment" {
            return self.named_field(node, "value");
        }
        self.named_field(node, "right")
            .or_else(|| self.named_children(node).into_iter().nth(1))
    }

    pub(in crate::ast) fn operator_assignment_operator(&self, node: TreeSitterNode<'_>) -> String {
        let mut cursor = node.walk();
        let raw = node.children(&mut cursor).find_map(|child| {
            let text = node_text(child, self.source);
            (!child.is_named() && self.assignment_operator(text)).then_some(text)
        });
        if let Some(raw) = raw {
            return match raw {
                "||=" => "||".to_string(),
                "&&=" => "&&".to_string(),
                _ => raw.trim_end_matches('=').to_string(),
            };
        }

        let raw_named = self.raw_named_children(node);
        if raw_named.len() == 1
            && node_text(node, self.source)
                .trim_end_matches(';')
                .trim_end()
                == node_text(raw_named[0], self.source)
        {
            return self.operator_assignment_operator(raw_named[0]);
        }

        String::new()
    }

    pub(in crate::ast) fn parameters_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "parameters").or_else(|| {
            self.named_children(node).into_iter().find(|child| {
                self.normalization_adapter
                    .check_node_role(*child, "parameter_child")
            })
        })
    }

    pub(in crate::ast) fn inline_parameter_begin_marker(
        &self,
        function_node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if !self.dynamic_syntax_enabled() {
            return None;
        }

        let params = self.named_field(function_node, "parameters").or_else(|| {
            self.named_children(function_node)
                .into_iter()
                .find(|child| {
                    self.normalization_adapter
                        .check_node_role(*child, "method_parameters")
                })
        })?;
        let semicolon = params.next_sibling()?;
        if semicolon.is_named() || node_text(semicolon, self.source) != ";" {
            return None;
        }

        let point = semicolon.start_position();
        Some(Node {
            r#type: "BEGIN".to_string(),
            children: vec![Child::Nil],
            first_lineno: point.row + 1,
            first_column: point.column,
            last_lineno: point.row + 1,
            last_column: point.column,
            text: String::new(),
        })
    }

    pub(in crate::ast) fn prepend_inline_parameter_begin(
        &self,
        function_node: TreeSitterNode<'_>,
        body: Option<Node>,
    ) -> Option<Node> {
        let Some(marker) = self.inline_parameter_begin_marker(function_node) else {
            return body;
        };

        let mut body = body?;
        if body.r#type == "BLOCK" {
            let mut children = body
                .children
                .into_iter()
                .filter(|child| !matches!(child, Child::Nil))
                .collect::<Vec<_>>();
            if children.is_empty() {
                return None;
            }

            body.children = vec![Child::Node(Box::new(marker))];
            body.children.append(&mut children);
            return Some(body);
        }

        Some(self.wrap(
            "BLOCK",
            vec![Child::Node(Box::new(marker)), Child::Node(Box::new(body))],
            function_node,
        ))
    }

    pub(in crate::ast) fn assignment_target(
        &mut self,
        left: TreeSitterNode<'_>,
        right: Option<Node>,
        source: TreeSitterNode<'_>,
    ) -> Option<Node> {
        if let Some(field) = self
            .normalization_adapter
            .state_field_name(left, self.source)
        {
            return Some(self.wrap(
                "IASGN",
                vec![Child::String(field), optional_node(right)],
                source,
            ));
        }
        if self.instance_variable(left) {
            return Some(self.wrap(
                "IASGN",
                vec![
                    Child::String(node_text(left, self.source).to_string()),
                    optional_node(right),
                ],
                source,
            ));
        }
        if self.global_variable(left) {
            return Some(self.wrap(
                "GASGN",
                vec![
                    Child::String(node_text(left, self.source).to_string()),
                    optional_node(right),
                ],
                source,
            ));
        }
        if self
            .normalization_adapter
            .check_node_role(left, "element_reference")
        {
            let named = self.named_children(left);
            let receiver = *named.first()?;
            let mut args = named
                .iter()
                .skip(1)
                .filter_map(|arg| self.normalize_node(*arg))
                .collect::<Vec<_>>();
            if let Some(right) = right {
                args.push(right);
            }
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(args, left, self);
            return Some(self.wrap(
                "ATTRASGN",
                vec![receiver, Child::Symbol("[]=".to_string()), args],
                source,
            ));
        }
        if self.member_read_node(left)
            || self
                .normalization_adapter
                .member_assignment_target(left, self.source)
        {
            let (receiver, method) = self.member_parts(left)?;
            let writer = if node_text(left, self.source).contains("&.") {
                method
            } else {
                format!("{method}=")
            };
            let receiver = optional_node(self.normalize_node(receiver));
            let args = list_or_nil(right.into_iter().collect(), left, self);
            return Some(self.wrap(
                "ATTRASGN",
                vec![receiver, Child::Symbol(writer), args],
                source,
            ));
        }
        if self
            .normalization_adapter
            .check_node_role(left, "expression_list")
        {
            return self
                .named_children(left)
                .into_iter()
                .next()
                .and_then(|child| self.assignment_target(child, right, source));
        }
        None
    }

    pub(in crate::ast) fn normalize_assignment_lhs(
        &mut self,
        node: TreeSitterNode<'_>,
    ) -> Option<Node> {
        let right_node = if let Some(parent) = node
            .parent()
            .filter(|p| self.normalization_adapter.check_node_role(*p, "assignment"))
        {
            self.assignment_right(parent)
        } else {
            node.next_named_sibling()
        };
        let right_node = right_node.filter(|r| !self.same_ts_node(*r, node));
        let right = right_node.and_then(|sibling| self.normalize_node(sibling));
        let source = node.parent().unwrap_or(node);
        self.assignment_target(node, right.clone(), source)
            .or_else(|| {
                Some(self.wrap(
                    "LASGN",
                    vec![Child::String(self.target_name(node)), optional_node(right)],
                    source,
                ))
            })
    }

    pub(in crate::ast) fn target_name(&self, node: TreeSitterNode<'_>) -> String {
        let text = node_text(node, self.source);
        if let Some(name) = self
            .normalization_adapter
            .assignment_target_name(node, self.source)
        {
            name
        } else if let Some(name) = self.identifier_text(node) {
            name
        } else if self
            .normalization_adapter
            .check_node_role(node, "splat_or_rest")
        {
            text.trim_start_matches('*').to_string()
        } else {
            text.to_string()
        }
    }

    pub(in crate::ast) fn function_name(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if let Some(name) = self
            .normalization_adapter
            .custom_function_name(node, self.source)
        {
            return Some(name);
        }

        if self.singleton_function_kind(node.kind()) {
            return Some(self.singleton_name(node));
        }

        Some(
            self.named_field(node, "name")
                .or_else(|| {
                    self.named_children(node).into_iter().find(|child| {
                        self.identifier_text(*child).is_some()
                            || self
                                .normalization_adapter
                                .check_node_role(*child, "constant")
                    })
                })
                .map(|name| {
                    self.identifier_text(name)
                        .unwrap_or_else(|| node_text(name, self.source).to_string())
                })
                .unwrap_or_default(),
        )
    }

    pub(in crate::ast) fn singleton_receiver<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(receiver) = self.named_field(node, "receiver") {
            return Some(receiver);
        }

        let children = self.named_children(node);
        let name = self.named_field(node, "name").or_else(|| {
            children
                .iter()
                .rev()
                .copied()
                .find(|child| self.identifier_text(*child).is_some())
        });
        let parameters = self.named_field(node, "parameters");
        let body = self
            .named_field(node, "body")
            .or_else(|| self.block_child(node));

        children.into_iter().find(|child| {
            !name
                .map(|name| self.same_ts_node(*child, name))
                .unwrap_or(false)
                && !parameters
                    .map(|parameters| self.same_ts_node(*child, parameters))
                    .unwrap_or(false)
                && !body
                    .map(|body| self.same_ts_node(*child, body))
                    .unwrap_or(false)
        })
    }

    pub(in crate::ast) fn singleton_name(&self, node: TreeSitterNode<'_>) -> String {
        self.named_field(node, "name")
            .or_else(|| {
                self.named_children(node)
                    .into_iter()
                    .rev()
                    .find(|child| self.identifier_text(*child).is_some())
            })
            .map(|name| node_text(name, self.source).to_string())
            .unwrap_or_default()
    }

    pub(in crate::ast) fn block_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "block_child")
        })
    }

    pub(in crate::ast) fn call_block<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if let Some(target) = self
            .normalization_adapter
            .statement_wrapped_call_target(node, self.source)
        {
            return self.call_block(target);
        }

        if let Some(block) = self
            .normalization_adapter
            .call_block_argument(node, self.source)
        {
            return Some(block);
        }

        self.named_children(node).into_iter().find(|child| {
            self.normalization_adapter
                .check_node_role(*child, "block_or_do_block")
        })
    }

    pub(in crate::ast) fn named_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.named_field(node, name)
    }

    pub(in crate::ast) fn parent_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        node.parent()
    }

    pub(in crate::ast) fn next_sibling<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        node.next_sibling()
    }

    pub(in crate::ast) fn prev_sibling<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        node.prev_sibling()
    }

    pub(in crate::ast) fn next_named_sibling<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        node.next_named_sibling()
    }

    pub(in crate::ast) fn named_children<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Vec<TreeSitterNode<'tree>> {
        if self
            .normalization_adapter
            .check_node_role(node, "dotted_name")
            && !node_text(node, self.source).contains('.')
        {
            return Vec::new();
        }

        let children = self.raw_named_children(node);
        match self
            .normalization_adapter
            .named_children_action(node, self.source, &children)
        {
            NamedChildrenAction::Default => {}
            NamedChildrenAction::Drop => return Vec::new(),
            NamedChildrenAction::Recurse(child) => return self.named_children(child),
            NamedChildrenAction::Replace(children) => return children,
        }

        if self.normalization_adapter.check_node_role(node, "type") && children.len() == 1 {
            if self
                .normalization_adapter
                .check_node_role(children[0], "union_type")
            {
                return self.named_children(children[0]);
            }
            if self
                .normalization_adapter
                .check_node_role(children[0], "generic_type")
            {
                return self.named_children(children[0]);
            }
            if self
                .normalization_adapter
                .check_node_role(children[0], "attribute")
            {
                return self.named_children(children[0]);
            }
            if self
                .normalization_adapter
                .check_node_role(children[0], "string")
            {
                return self.named_children(children[0]);
            }
            if self
                .normalization_adapter
                .check_node_role(children[0], "list")
            {
                if self.raw_named_children(children[0]).is_empty() {
                    return Vec::new();
                }
                return self.named_children(children[0]);
            }
            if self
                .normalization_adapter
                .check_node_role(children[0], "type_leaf")
            {
                return Vec::new();
            }
        }
        if self
            .normalization_adapter
            .check_node_role(node, "expression_statement")
            && children.len() == 1
            && self
                .normalization_adapter
                .check_node_role(children[0], "assignment_or_augmented")
        {
            return self.named_children(children[0]);
        }

        children
    }

    pub(in crate::ast) fn raw_named_children<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Vec<TreeSitterNode<'tree>> {
        node.children(&mut node.walk())
            .filter(|child| child.is_named())
            .collect()
    }

    pub(in crate::ast) fn no_paren_string_argument_content<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter
            .no_paren_string_argument_content(node, self.source)
    }

    pub(in crate::ast) fn source_before_child(
        &self,
        node: TreeSitterNode<'_>,
        child: TreeSitterNode<'_>,
    ) -> Node {
        let text = self
            .source
            .get(node.start_byte()..child.start_byte())
            .unwrap_or("")
            .trim_end()
            .to_string();
        if text.is_empty() {
            return self.wrap("SOURCE", Vec::new(), node);
        }

        let lines = text.lines().collect::<Vec<_>>();
        let first_span = span(node);
        let last_lineno = first_span[0] + lines.len() - 1;
        let last_column = if lines.len() <= 1 {
            first_span[1] + text.len()
        } else {
            lines.last().map(|line| line.len()).unwrap_or(0)
        };
        Node {
            r#type: "SOURCE".to_string(),
            children: Vec::new(),
            first_lineno: first_span[0],
            first_column: first_span[1],
            last_lineno,
            last_column,
            text: self.source_text(&text),
        }
    }

    pub(in crate::ast) fn source_from_nodes(
        &self,
        first_node: TreeSitterNode<'_>,
        last_node: TreeSitterNode<'_>,
    ) -> Node {
        self.wrap_from_nodes("SOURCE", Vec::new(), first_node, last_node)
    }

    pub(in crate::ast) fn parenthesized_source(&self, node: TreeSitterNode<'_>) -> Option<Node> {
        let mut open = None;
        let mut close = None;
        for child in node.children(&mut node.walk()) {
            if child.is_named() {
                continue;
            }
            match node_text(child, self.source) {
                "(" if open.is_none() => open = Some(child),
                ")" => close = Some(child),
                _ => {}
            }
        }
        let source = self.source_from_nodes(open?, close?);
        Some(source)
    }

    pub(in crate::ast) fn source_from_normalized_nodes(
        &self,
        first_node: &Node,
        last_node: &Node,
    ) -> Node {
        let lines = self.source.split_inclusive('\n').collect::<Vec<_>>();
        let text = if first_node.first_lineno == last_node.last_lineno {
            lines
                .get(first_node.first_lineno.saturating_sub(1))
                .and_then(|line| line.get(first_node.first_column..last_node.last_column))
                .unwrap_or("")
                .to_string()
        } else {
            let mut text = String::new();
            if let Some(line) = lines.get(first_node.first_lineno.saturating_sub(1)) {
                text.push_str(line.get(first_node.first_column..).unwrap_or(""));
            }
            for index in first_node.first_lineno..last_node.last_lineno.saturating_sub(1) {
                if let Some(line) = lines.get(index) {
                    text.push_str(line);
                }
            }
            if let Some(line) = lines.get(last_node.last_lineno.saturating_sub(1)) {
                text.push_str(line.get(..last_node.last_column).unwrap_or(""));
            }
            text
        };

        Node {
            r#type: "SOURCE".to_string(),
            children: Vec::new(),
            first_lineno: first_node.first_lineno,
            first_column: first_node.first_column,
            last_lineno: last_node.last_lineno,
            last_column: last_node.last_column,
            text: self.source_text(&text),
        }
    }

    pub(in crate::ast) fn first_named<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node).into_iter().next()
    }

    pub(in crate::ast) fn branch_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        condition: TreeSitterNode<'tree>,
        offset: usize,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_children(node)
            .into_iter()
            .filter(|child| {
                *child != condition
                    && !self
                        .normalization_adapter
                        .branch_child_skip_kind(child.kind())
            })
            .nth(offset)
    }

    pub(in crate::ast) fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.normalization_adapter.explicit_alternative(node)
    }

    pub(in crate::ast) fn elsif_statement(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .elsif_statement(node, self.source)
    }

    pub(in crate::ast) fn case_value<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "value")
            .or_else(|| self.named_field(node, "subject"))
            .or_else(|| self.named_field(node, "condition"))
            .or_else(|| {
                self.named_children(node).into_iter().find(|child| {
                    !self.when_kind(child.kind())
                        && !self.block_kind(child.kind())
                        && !self.normalization_adapter.check_node_role(*child, "else")
                })
            })
    }

    pub(in crate::ast) fn case_arms<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Vec<TreeSitterNode<'tree>> {
        let mut arms = Vec::new();
        let mut stack = self.named_children(node);
        while !stack.is_empty() {
            let child = stack.remove(0);
            if self.normalization_adapter.case_arm(child, self.source) {
                arms.push(child);
            } else if self
                .normalization_adapter
                .case_else_node_kind(child, self.source)
            {
                continue;
            } else if !self.function_kind(child.kind()) {
                stack.extend(self.named_children(child));
            }
        }
        arms
    }

    pub(in crate::ast) fn when_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.named_field(node, "body")
            .or_else(|| self.named_field(node, "consequence"))
            .or_else(|| self.named_field(node, "value"))
            .or_else(|| {
                self.named_children(node).into_iter().rev().find(|child| {
                    self.block_kind(child.kind()) || self.statement_node(child.kind())
                })
            })
    }

    pub(in crate::ast) fn identifier_kind(&self, kind: &str) -> bool {
        identifier_kind_name(kind)
    }

    pub(in crate::ast) fn identifier_text(&self, node: TreeSitterNode<'_>) -> Option<String> {
        if self.identifier_kind(node.kind()) {
            return Some(
                node_text(node, self.source)
                    .trim_start_matches('*')
                    .to_string(),
            );
        }
        self.normalization_adapter
            .local_identifier_text(node, self.source)
    }

    pub(in crate::ast) fn self_identifier(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .self_identifier(node, self.source)
    }

    pub(in crate::ast) fn call_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.call_kind(node.kind()) || self.normalization_adapter.call_node(node, self.source)
    }

    pub(in crate::ast) fn function_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.function_kind(kind)
    }

    pub(in crate::ast) fn singleton_function_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.singleton_function_kind(kind)
    }

    pub(in crate::ast) fn singleton_class_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .singleton_class_node(node, self.source)
    }

    pub(in crate::ast) fn block_pass_argument(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .block_pass_argument(node, self.source)
    }

    pub(in crate::ast) fn class_like_owner_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.class_like_owner_kind(kind)
    }

    pub(in crate::ast) fn if_node_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.if_node_kind(kind)
    }

    pub(in crate::ast) fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        self.normalization_adapter.loop_node_type(kind)
    }

    pub(in crate::ast) fn modifier_loop_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.modifier_loop_kind(kind)
    }

    pub(in crate::ast) fn member_access_operator(&self, text: &str) -> bool {
        self.normalization_adapter.member_access_operator(text)
    }

    pub(in crate::ast) fn source_text(&self, text: &str) -> String {
        self.normalization_adapter.source_text(text)
    }

    pub(in crate::ast) fn const_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.const_node_kind(kind)
    }

    pub(in crate::ast) fn call_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.call_node_kind(kind)
    }

    pub(in crate::ast) fn block_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.block_node_kind(kind)
    }

    pub(in crate::ast) fn case_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.case_node_kind(kind)
    }

    pub(in crate::ast) fn when_kind(&self, kind: &str) -> bool {
        self.normalization_adapter.when_node_kind(kind)
    }

    pub(in crate::ast) fn statement_node(&self, kind: &str) -> bool {
        self.normalization_adapter.statement_node_kind(kind)
    }

    pub(in crate::ast) fn unwrap_node(&self, node: TreeSitterNode<'_>) -> bool {
        self.normalization_adapter
            .unwrap_node(node, self.source, self.named_children(node).len())
    }

    pub(in crate::ast) fn single_dotted_else_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        let children = self
            .named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if children.len() != 1 {
            return None;
        }
        self.single_dotted_body_node(children[0])
    }

    pub(in crate::ast) fn single_dotted_body_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        if self.if_node_kind(node.kind())
            || self.loop_node_type(node.kind()).is_some()
            || self
                .normalization_adapter
                .conditional_modifier_kind(node.kind())
        {
            return None;
        }
        if self.call_node(node) && self.dotted_call(node) {
            return Some(node);
        }

        let children = self
            .named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "comment")
            .collect::<Vec<_>>();
        if children.len() == 1
            && node_text(node, self.source) == node_text(children[0], self.source)
        {
            return self.single_dotted_body_node(children[0]);
        }
        None
    }

    pub(in crate::ast) fn elide_tail_returns(&self, node: Option<Node>) -> Option<Node> {
        if !self.normalization_adapter.elides_tail_returns() {
            return node;
        }
        let mut node = node?;
        if matches!(
            node.r#type.as_str(),
            "DEFN" | "DEFS" | "CLASS" | "MODULE" | "SCLASS" | "LAMBDA" | "ITER"
        ) {
            return Some(node);
        }
        if node.r#type == "RETURN" {
            return node.children.into_iter().next().and_then(child_node);
        }

        match node.r#type.as_str() {
            "BLOCK" => {
                if let Some(last) = node.children.pop() {
                    match child_node(last) {
                        Some(last_node) => {
                            if let Some(elided) = self.elide_tail_returns(Some(last_node)) {
                                node.children.push(Child::Node(Box::new(elided)));
                            } else {
                                node.children.push(Child::Nil);
                            }
                        }
                        None => node.children.push(Child::Nil),
                    }
                }
            }
            "SCOPE" => {
                if node.children.len() > 2 {
                    let child = std::mem::replace(&mut node.children[2], Child::Nil);
                    if let Some(elided) =
                        child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                    {
                        node.children[2] = Child::Node(Box::new(elided));
                    }
                }
            }
            "IF" | "UNLESS" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "CASE" | "CASE2" => {
                let index = if node.r#type == "CASE" { 1 } else { 0 };
                if node.children.len() > index {
                    let child = std::mem::replace(&mut node.children[index], Child::Nil);
                    if let Some(elided) =
                        child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                    {
                        node.children[index] = Child::Node(Box::new(elided));
                    }
                }
            }
            "WHEN" | "RESBODY" => {
                for index in [1usize, 2usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            "RESCUE" => {
                for index in [0usize, 1usize] {
                    if node.children.len() > index {
                        let child = std::mem::replace(&mut node.children[index], Child::Nil);
                        if let Some(elided) =
                            child_node(child).and_then(|body| self.elide_tail_returns(Some(body)))
                        {
                            node.children[index] = Child::Node(Box::new(elided));
                        }
                    }
                }
            }
            _ => {}
        }

        Some(node)
    }

    pub(in crate::ast) fn elide_implicit_nil_body(&self, node: Option<Node>) -> Option<Node> {
        if !self.normalization_adapter.elides_implicit_nil_body() {
            return node;
        }
        let node = self.drop_trailing_nil_statement(node);
        match node {
            Some(node) if node.r#type == "NIL" => None,
            other => other,
        }
    }

    pub(in crate::ast) fn drop_trailing_nil_statement(&self, node: Option<Node>) -> Option<Node> {
        let mut node = node?;
        if node.r#type != "BLOCK" {
            return Some(node);
        }
        node.children.retain(|child| !matches!(child, Child::Nil));
        while node
            .children
            .last()
            .and_then(self::node)
            .map(|child| child.r#type == "NIL")
            .unwrap_or(false)
        {
            node.children.pop();
        }
        if node.children.is_empty() {
            None
        } else if node.children.len() == 1 {
            child_node(node.children.into_iter().next().unwrap())
        } else {
            Some(node)
        }
    }
}

impl<'source> TreeSitterNormalizer<'source> {
    pub(in crate::ast) fn with_dynamic_scope<T>(
        &mut self,
        node: TreeSitterNode<'_>,
        reset: bool,
        f: impl FnOnce(&mut Self) -> T,
    ) -> T {
        if !self.normalization_adapter.tracks_dynamic_local_scope() {
            return f(self);
        }
        let previous = self.local_stack.clone();
        if reset {
            self.local_stack.clear();
        }
        let locals = self.normalization_adapter.scope_locals(node, self);
        self.local_stack.push(locals);
        let result = f(self);
        self.local_stack = previous;
        result
    }

    pub(in crate::ast) fn dynamic_vcall_identifier(
        &self,
        node: TreeSitterNode<'_>,
        name: &str,
    ) -> bool {
        self.normalization_adapter
            .vcall_identifier(node, name, self)
    }

    pub(in crate::ast) fn dynamic_local_name(&self, name: &str) -> bool {
        self.local_stack
            .iter()
            .rev()
            .any(|scope| scope.contains(name))
    }

    pub(in crate::ast) fn dynamic_syntax_enabled(&self) -> bool {
        self.normalization_adapter.tracks_dynamic_local_scope()
    }
}

include!("normalizer-test.rs");
