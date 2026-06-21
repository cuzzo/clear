use super::super::{
    bracketed, case_arm_descendant, concatenated_string_node, concatenated_string_target,
    descendant, direct_binary_operator, element_reference_shape, function_kind,
    identifier_kind_name, named_children, node_text, question_colon_ternary_parts,
    raw_named_children, ruby_exception_constant_text, statement_block_wrapper, TernaryParts,
    ARRAY_LITERAL_NODE_KINDS, ARRAY_LITERAL_WRAPPER_KINDS, BOOLEAN_EXPRESSION_KINDS,
    CASE_ARGUMENT_WHEN_KINDS, CASE_ELSE_KINDS, CASE_NODE_KINDS, COMPARISON_EXPRESSION_KINDS,
    CONCATENATED_STRING_WRAPPER_KINDS, DOTTED_EXPRESSION_WRAPPER_KINDS,
    ELEMENT_REFERENCE_NODE_KINDS, ELEMENT_REFERENCE_WRAPPER_KINDS, EMPTY_BODY_WRAPPER_KINDS,
    ENSURE_BODY_WRAPPER_KINDS, HASH_LITERAL_NODE_KINDS, HASH_LITERAL_WRAPPER_KINDS,
    HEREDOC_BODY_WRAPPER_KINDS, IF_NODE_KINDS, INTERPOLATED_STATEMENT_WRAPPER_KINDS,
    LEADING_CASE_WRAPPER_KINDS, LEADING_FUNCTION_WRAPPER_KINDS, LEADING_IF_WRAPPER_KINDS,
    LEADING_LOOP_WRAPPER_KINDS, LEADING_OWNER_WRAPPER_KINDS, LOOP_NODE_KINDS, OWNER_NODE_KINDS,
    OWNER_STATEMENT_NESTED_KINDS, QUESTION_COLON_TERNARY_KINDS, RESCUE_BODY_WRAPPER_KINDS,
};
use tree_sitter::Node as TreeSitterNode;

pub(crate) const COMMON_ASSIGNMENT_OPERATORS: &[&str] = &["=", "+=", "-=", "*=", "/=", "%="];
pub(crate) const RUBY_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "**=", "&&=", "||=", "&=", "|=", "^=", "<<=", ">>=",
];
pub(crate) const PYTHON_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "//=", "**=", "@=", "&=", "|=", "^=", "<<=", ">>=", ":=",
];
pub(crate) const LUA_ASSIGNMENT_OPERATORS: &[&str] = &["="];
pub(crate) const TYPESCRIPT_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=",
    "??=",
];

pub(crate) enum NamedChildrenAction<'tree> {
    Default,
    Drop,
    Recurse(TreeSitterNode<'tree>),
    Replace(Vec<TreeSitterNode<'tree>>),
}

pub(crate) struct ConditionalBranchParts<'tree> {
    pub(crate) condition: TreeSitterNode<'tree>,
    pub(crate) positive: Option<TreeSitterNode<'tree>>,
    pub(crate) negative: Option<TreeSitterNode<'tree>>,
}

pub(crate) trait AstNormalizationAdapter: Sync {
    fn ruby(&self) -> bool {
        false
    }

    fn yield_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn super_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn safe_navigation_call(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn ternary_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.ternary_parts(node, source).is_some()
    }

    fn ternary_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TernaryParts<'tree>> {
        question_colon_ternary_parts(node, source, QUESTION_COLON_TERNARY_KINDS)
    }

    fn case_argument_list(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn case_arm(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        CASE_ARGUMENT_WHEN_KINDS.contains(&node.kind()) && !self.case_else_arm(node, source)
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        None
    }

    fn case_else_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let mut stack = named_children(node);
        while !stack.is_empty() {
            let child = stack.remove(0);
            if self.case_else_node_kind(child, source) {
                return Some(child);
            }
            if CASE_ARGUMENT_WHEN_KINDS.contains(&child.kind()) {
                continue;
            }
            if !function_kind(child.kind()) {
                stack.extend(named_children(child));
            }
        }
        None
    }

    fn case_else_node_kind(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        CASE_ELSE_KINDS.contains(&node.kind()) || self.case_else_arm(node, source)
    }

    fn case_else_arm(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn leading_function_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn leading_function_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_FUNCTION_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if node
            .children(&mut node.walk())
            .next()
            .map(|child| child.kind() == "def")
            .unwrap_or(false)
        {
            return Some(node);
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && matches!(raw_named[0].kind(), "method" | "singleton_method")
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        None
    }

    fn leading_function_body_kind(&self) -> &'static str {
        "body_statement"
    }

    fn leading_owner_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_owner_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "class" | "module"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
            && named_children(target)
                .first()
                .map(|child| !OWNER_STATEMENT_NESTED_KINDS.contains(&child.kind()))
                .unwrap_or(false)
    }

    fn leading_owner_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_OWNER_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && OWNER_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_if_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_if_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "if" | "unless"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
            && named_children(target)
                .first()
                .map(|child| !IF_NODE_KINDS.contains(&child.kind()))
                .unwrap_or(false)
    }

    fn leading_if_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_IF_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && IF_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_case_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_case_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| matches!(child.kind(), "case" | "match" | "switch"))
            .unwrap_or(false)
            && case_arm_descendant(target)
    }

    fn leading_case_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !LEADING_CASE_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && CASE_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn leading_loop_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        let Some(target) = self.leading_loop_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| !child.is_named() && matches!(child.kind(), "while" | "until"))
            .unwrap_or(false)
            && named_children(target).len() >= 2
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
            && LOOP_NODE_KINDS.contains(&raw_named[0].kind())
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            return Some(raw_named[0]);
        }
        Some(node)
    }

    fn rescue_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        !self.rescue_clauses(node, source).is_empty()
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if RESCUE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            Some(node)
        } else {
            None
        }
    }

    fn rescue_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.rescue_body_target(node, source) else {
            return Vec::new();
        };
        let named = named_children(target);
        let Some(index) = named.iter().position(|child| self.rescue_clause(*child)) else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn rescue_clauses<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.rescue_body_target(node, source) else {
            return Vec::new();
        };
        named_children(target)
            .into_iter()
            .filter(|child| self.rescue_clause(*child))
            .collect()
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

    fn ensure_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.ensure_clause(node, source).is_some()
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if ENSURE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            Some(node)
        } else {
            None
        }
    }

    fn ensure_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(target) = self.ensure_body_target(node, source) else {
            return Vec::new();
        };
        let named = named_children(target);
        let Some(index) = named
            .iter()
            .position(|child| self.ensure_clause_kind(*child))
        else {
            return Vec::new();
        };
        named[..index].to_vec()
    }

    fn ensure_clause<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let target = self.ensure_body_target(node, source)?;
        named_children(target)
            .into_iter()
            .find(|child| self.ensure_clause_kind(*child))
    }

    fn ensure_clause_body<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn ensure_clause_kind(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "ensure"
    }

    fn array_literal_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.array_literal_target(node, source).is_some()
    }

    fn array_literal_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if ARRAY_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !ARRAY_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if bracketed(node, source, "[", "]") {
            return Some(node);
        }

        let named = named_children(node);
        let child = *named.first()?;
        if named.len() == 1 {
            if ARRAY_LITERAL_NODE_KINDS.contains(&child.kind()) {
                return Some(child);
            }

            if matches!(child.kind(), "expression_statement" | "statement")
                && node_text(child, source).trim() == node_text(node, source).trim()
            {
                return self.array_literal_target(child, source);
            }

            let stripped = node_text(node, source).trim();
            if stripped == node_text(child, source)
                || stripped == format!("{};", node_text(child, source))
            {
                if ARRAY_LITERAL_NODE_KINDS.contains(&child.kind()) {
                    return Some(child);
                }
            }
        }

        None
    }

    fn array_literal_values<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.array_literal_target(node, source).unwrap_or(node);
        named_children(target)
    }

    fn element_reference_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.element_reference_target(node, source).is_some()
    }

    fn element_reference_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if ELEMENT_REFERENCE_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !ELEMENT_REFERENCE_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }

        let named = named_children(node);
        if named.len() == 1
            && ELEMENT_REFERENCE_WRAPPER_KINDS.contains(&named[0].kind())
            && node_text(named[0], source).trim() == node_text(node, source).trim()
        {
            return self.element_reference_target(named[0], source);
        }
        if named.len() == 1 && ELEMENT_REFERENCE_NODE_KINDS.contains(&named[0].kind()) {
            let stripped = node_text(node, source).trim();
            let child_text = node_text(named[0], source);
            if stripped == child_text || stripped == format!("{child_text};") {
                return Some(named[0]);
            }
        }

        if element_reference_shape(node, source) {
            Some(node)
        } else {
            None
        }
    }

    fn element_reference_receiver<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let target = self.element_reference_target(node, source).unwrap_or(node);
        named_children(target).first().copied()
    }

    fn element_reference_arguments<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.element_reference_target(node, source).unwrap_or(node);
        named_children(target).into_iter().skip(1).collect()
    }

    fn hash_literal_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.hash_literal_target(node, source).is_some()
    }

    fn hash_literal_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if HASH_LITERAL_NODE_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        if !HASH_LITERAL_WRAPPER_KINDS.contains(&node.kind()) {
            return None;
        }
        if statement_block_wrapper(node) {
            return None;
        }
        if bracketed(node, source, "{", "}") {
            return Some(node);
        }

        let named = named_children(node);
        if named.len() != 1 {
            return None;
        }

        let child = named[0];
        if node.kind() == "parenthesized_expression" {
            return self.hash_literal_target(child, source);
        }

        let stripped = node_text(node, source).trim();
        let child_text = node_text(child, source);
        if stripped == child_text || stripped == format!("{child_text};") {
            if HASH_LITERAL_NODE_KINDS.contains(&child.kind()) {
                return Some(child);
            }
            if HASH_LITERAL_WRAPPER_KINDS.contains(&child.kind()) {
                return self.hash_literal_target(child, source);
            }
        }

        None
    }

    fn hash_literal_values<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.hash_literal_target(node, source).unwrap_or(node);
        named_children(target)
    }

    fn empty_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        EMPTY_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node).is_empty()
            && node_text(node, source).trim().is_empty()
    }

    fn heredoc_body_statement(&self, node: TreeSitterNode<'_>) -> bool {
        HEREDOC_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node)
                .iter()
                .any(|child| child.kind() == "heredoc_body")
    }

    fn heredoc_call_for_body(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn interpolated_statement(
        &self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        INTERPOLATED_STATEMENT_WRAPPER_KINDS.contains(&node.kind())
            && children.iter().any(|child| child.kind() == "interpolation")
    }

    fn concatenated_string_statement(
        &self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        if concatenated_string_node(node).is_some() {
            return true;
        }
        if !self
            .concatenated_string_wrapper_kinds()
            .contains(&node.kind())
        {
            return false;
        }
        if children.len() > 1 && children.iter().all(|child| child.kind() == "string") {
            return true;
        }
        children.len() == 1 && concatenated_string_target(children[0]).is_some()
    }

    fn concatenated_string_children<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        None
    }

    fn zero_child_identifier_call(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn operator_call_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "binary" | "binary_expression")
    }

    fn boolean_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        BOOLEAN_EXPRESSION_KINDS.contains(&node.kind())
    }

    fn comparison_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        COMPARISON_EXPRESSION_KINDS.contains(&node.kind())
    }

    fn dotted_expression_wrapper(&self, node: TreeSitterNode<'_>) -> bool {
        self.dotted_expression_wrapper_kinds()
            .contains(&node.kind())
    }

    fn unary_not_expression(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        matches!(node.kind(), "unary" | "unary_expression")
            && node_text(node, source).trim_start().starts_with('!')
    }

    fn unary_minus_expression(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        matches!(node.kind(), "unary" | "unary_expression")
            && node_text(node, source).trim_start().starts_with('-')
    }

    fn binary_operator(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if let Some(operator) = direct_binary_operator(node, source) {
            return Some(operator.to_string());
        }

        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && self.binary_wrapper_kinds().contains(&raw_named[0].kind())
            && node_text(node, source) == node_text(raw_named[0], source)
        {
            return self.binary_operator(raw_named[0], source);
        }

        None
    }

    fn class_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "class" | "class_definition" | "class_declaration" | "class_specifier"
        )
    }

    fn local_identifier_text(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
    }

    fn constant_identifier_text(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
    }

    fn self_identifier(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn call_node(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn intrinsic_call_name(
        &self,
        _node: TreeSitterNode<'_>,
        _source: &str,
    ) -> Option<&'static str> {
        None
    }

    fn block_node_kind(&self, _kind: &str) -> bool {
        false
    }

    fn loop_node_type(&self, _kind: &str) -> Option<&'static str> {
        None
    }

    fn member_access_operator(&self, text: &str) -> bool {
        matches!(text, "." | "&.")
    }

    fn source_text(&self, text: &str) -> String {
        text.to_string()
    }

    fn state_field_name(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
    }

    fn member_assignment_target(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn instance_variable(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "instance_variable"
    }

    fn global_variable(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "global_variable"
    }

    fn literal_fragment_assignment_context(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        let Some(parent) = node.parent() else {
            return false;
        };
        if matches!(
            parent.kind(),
            "string" | "delimited_symbol" | "regex" | "regex_literal"
        ) {
            return true;
        }

        matches!(
            node.kind(),
            "string_content" | "escape_sequence" | "interpolation" | "string_fragment"
        ) && parent
            .parent()
            .map(|grandparent| {
                matches!(
                    grandparent.kind(),
                    "string" | "delimited_symbol" | "regex" | "regex_literal"
                )
            })
            .unwrap_or(false)
    }

    fn assignment_operator(&self, text: &str) -> bool {
        self.assignment_operators().contains(&text)
    }

    fn unwrap_node(
        &self,
        node: TreeSitterNode<'_>,
        _source: &str,
        named_child_count: usize,
    ) -> bool {
        matches!(
            node.kind(),
            "parenthesized_expression"
                | "parenthesized_statements"
                | "expression_statement"
                | "statement"
                | "case_pattern"
                | "match_pattern"
                | "pattern"
        ) && named_child_count == 1
    }

    fn interpolated_string(
        &self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        node.kind() == "string" && children.iter().any(|child| child.kind() == "interpolation")
    }

    fn lambda_expression(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.lambda_target(node, source).is_some()
    }

    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "lambda" {
            Some(node)
        } else {
            None
        }
    }

    fn interpolation_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "interpolation"
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "else" | "else_clause" | "else_statement"))
    }

    fn elsif_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn elsif_parts<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<ConditionalBranchParts<'tree>> {
        None
    }

    fn else_body_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        None
    }

    fn named_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        node.child_by_field_name(name)
    }

    fn named_children_action<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
        _children: &[TreeSitterNode<'tree>],
    ) -> NamedChildrenAction<'tree> {
        NamedChildrenAction::Default
    }

    fn nested_class_body_child<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn else_if_block<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn logical_operator_assignment(&self, _operator: &str) -> bool {
        false
    }

    fn statement_wrapped_call_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn inline_def_function_text_source<'tree>(
        &self,
        function: TreeSitterNode<'tree>,
        _source: &str,
    ) -> TreeSitterNode<'tree> {
        function
    }

    fn bare_const_call_function(&self, _function: TreeSitterNode<'_>) -> bool {
        false
    }

    fn normalize_default_parameters(&self) -> bool {
        false
    }

    fn normalize_block_parameters(&self) -> bool {
        false
    }

    fn boolean_statement_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
        _children: &[TreeSitterNode<'tree>],
    ) -> TreeSitterNode<'tree> {
        node
    }

    fn single_assignment_block_child(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn member_read_excluded(&self, _node: TreeSitterNode<'_>) -> bool {
        false
    }

    fn no_paren_string_argument_content<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn elides_tail_returns(&self) -> bool {
        false
    }

    fn elides_implicit_nil_body(&self) -> bool {
        false
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        COMMON_ASSIGNMENT_OPERATORS
    }

    fn binary_wrapper_kinds(&self) -> &'static [&'static str] {
        super::super::BINARY_WRAPPER_KINDS
    }

    fn concatenated_string_wrapper_kinds(&self) -> &'static [&'static str] {
        CONCATENATED_STRING_WRAPPER_KINDS
    }

    fn dotted_expression_wrapper_kinds(&self) -> &'static [&'static str] {
        DOTTED_EXPRESSION_WRAPPER_KINDS
    }

    fn leading_function_statement_with_keyword(
        &self,
        node: TreeSitterNode<'_>,
        source: &str,
        keyword: &str,
        wrapper_kinds: &[&str],
    ) -> bool {
        if !wrapper_kinds.contains(&node.kind()) {
            return false;
        }
        let Some(target) = self.leading_function_target(node, source) else {
            return false;
        };
        target
            .children(&mut target.walk())
            .next()
            .map(|child| child.kind() == keyword)
            .unwrap_or(false)
            && named_children(target)
                .iter()
                .any(|child| identifier_kind_name(child.kind()))
    }

    fn exact_single_named_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        kinds: &[&str],
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let children = named_children(node);
        if children.len() != 1 {
            return None;
        }
        let child = children[0];
        if !kinds.contains(&child.kind()) || node_text(node, source) != node_text(child, source) {
            return None;
        }
        Some(child)
    }

    fn default_case_pattern(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        named_children(node)
            .into_iter()
            .find(|child| super::super::CASE_DEFAULT_PATTERN_KINDS.contains(&child.kind()))
            .map(|pattern| node_text(pattern, source).trim() == "_")
            .unwrap_or(false)
    }

    fn descendant<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        kinds: &[&str],
    ) -> Option<TreeSitterNode<'tree>> {
        descendant(node, kinds)
    }
}
