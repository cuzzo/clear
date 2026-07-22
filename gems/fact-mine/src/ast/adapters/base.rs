use super::super::{
    bracketed, case_arm_descendant, descendant, direct_binary_operator, element_reference_shape,
    identifier_kind_name, named_children, node_text, question_colon_ternary_parts,
    raw_named_children, statement_block_wrapper, TernaryParts, ARRAY_LITERAL_NODE_KINDS,
    ARRAY_LITERAL_WRAPPER_KINDS, BOOLEAN_EXPRESSION_KINDS, CASE_ARGUMENT_WHEN_KINDS,
    CASE_ELSE_KINDS, CASE_NODE_KINDS, COMPARISON_EXPRESSION_KINDS,
    CONCATENATED_STRING_WRAPPER_KINDS, DOTTED_EXPRESSION_WRAPPER_KINDS,
    ELEMENT_REFERENCE_NODE_KINDS, ELEMENT_REFERENCE_WRAPPER_KINDS, EMPTY_BODY_WRAPPER_KINDS,
    HASH_LITERAL_NODE_KINDS, HASH_LITERAL_WRAPPER_KINDS, INTERPOLATED_STATEMENT_WRAPPER_KINDS,
    LEADING_CASE_WRAPPER_KINDS, LEADING_FUNCTION_WRAPPER_KINDS, LEADING_IF_WRAPPER_KINDS,
    LEADING_LOOP_WRAPPER_KINDS, LEADING_OWNER_WRAPPER_KINDS, LOOP_NODE_KINDS, OWNER_NODE_KINDS,
    OWNER_STATEMENT_NESTED_KINDS, QUESTION_COLON_TERNARY_KINDS,
};
use tree_sitter::Node as TreeSitterNode;

pub(crate) const COMMON_ASSIGNMENT_OPERATORS: &[&str] = &["=", "+=", "-=", "*=", "/=", "%="];

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

use super::super::TreeSitterNormalizer;
pub(crate) trait AstNormalizationAdapter: Sync {
    /// Language-native namespace and explicit-import facts used to form
    /// canonical symbol identities. The empty default deliberately means
    /// "not proven", rather than treating a filename or short owner as a
    /// namespace.
    fn symbol_scope(
        &self,
        _root: TreeSitterNode<'_>,
        _source: &str,
    ) -> (String, Vec<(String, String)>) {
        (String::new(), Vec::new())
    }

    /// Canonical namespace identities keyed by native declaration span.
    /// This remains empty unless the language grammar proves the scope.
    fn declaration_namespaces(
        &self,
        _root: TreeSitterNode<'_>,
        _source: &str,
    ) -> Vec<([usize; 4], String)> {
        Vec::new()
    }

    /// Whether an unqualified declared type with no explicit import is owned
    /// by the current namespace according to native language rules.
    fn unqualified_types_use_current_namespace(&self) -> bool {
        false
    }

    fn preprocessor_callable_names(&self, _root: TreeSitterNode<'_>, _source: &str) -> Vec<String> {
        Vec::new()
    }

    /// Pre-parse source transformation, fed to tree-sitter's `parse()` call
    /// only - never used for digests, snippets, or spans, which always read
    /// the untouched original source. Defaults to a no-op; override only
    /// where a reproduced grammar-corruption gap requires rewriting what the
    /// parser sees. MUST be byte-length preserving (same total length, same
    /// line/column layout everywhere) - callers rely on original-source spans
    /// staying valid against whatever tree-sitter produces from this buffer.
    fn source_preprocessing(&self, _source: &str) -> Option<String> {
        None
    }

    fn scope_locals(
        &self,
        _node: TreeSitterNode<'_>,
        _normalizer: &TreeSitterNormalizer<'_>,
    ) -> std::collections::BTreeSet<String> {
        std::collections::BTreeSet::new()
    }

    fn vcall_identifier(
        &self,
        _node: TreeSitterNode<'_>,
        _name: &str,
        _normalizer: &TreeSitterNormalizer<'_>,
    ) -> bool {
        false
    }

    fn check_node_role(&self, node: TreeSitterNode<'_>, role: &str) -> bool {
        let kind = node.kind();
        match role {
            "root" => kind == "program",
            "function" => self.function_kind(kind),
            "subshell" => kind == "subshell",
            "operator_assignment" => kind == "operator_assignment",
            "assignment" => matches!(
                kind,
                "assignment"
                    | "assignment_expression"
                    | "assignment_statement"
                    | "annotated_assignment"
            ),
            "variable_declarator" => kind == "variable_declarator",
            "super" => kind == "super",
            "return_or_break" => matches!(
                kind,
                "return"
                    | "return_statement"
                    | "return_expression"
                    | "break"
                    | "break_statement"
                    | "break_expression"
                    | "next"
                    | "continue_statement"
            ),
            "nil" => matches!(kind, "nil" | "none" | "null" | "null_literal"),
            "true" => kind == "true",
            "false" => kind == "false",
            "identifier" => matches!(
                kind,
                "identifier"
                    | "simple_identifier"
                    | "property_identifier"
                    | "field_identifier"
                    | "shorthand_property_identifier"
            ),
            "self_or_this" => matches!(kind, "self" | "this"),
            "array" => kind == "array",
            "float" => matches!(kind, "float" | "float_literal"),
            "pair" => kind == "pair",
            "symbol" => matches!(kind, "simple_symbol" | "symbol"),
            "argument_list" => kind == "argument_list" || kind == "arguments",
            "call" => kind == "call",
            "element_reference" => matches!(
                kind,
                "element_reference"
                    | "subscript"
                    | "subscript_expression"
                    | "bracket_index_expression"
                    | "table_index_expression"
            ),
            "multiple_assignment_left" => {
                kind == "left_assignment_list"
                    || (kind == "variable_list" && raw_named_children(node).len() > 1)
            }
            "exceptions" => kind == "exceptions",
            "hash_key_symbol" => kind == "hash_key_symbol",
            "body_statement" => kind == "body_statement",
            "block_parameters" => matches!(kind, "block_parameters" | "lambda_parameters"),
            "destructured_parameter" => kind == "destructured_parameter",
            "optional_or_keyword_parameter" => {
                matches!(kind, "optional_parameter" | "keyword_parameter")
            }
            "expression_list" => kind == "expression_list" || kind == "variable_list",
            "short_var_declaration" => kind == "short_var_declaration",
            "navigation_suffix" => kind == "navigation_suffix",
            "match_block" => kind == "match_block",
            "method_parameters" => kind == "method_parameters",
            "parameter_child" => matches!(
                kind,
                "parameters"
                    | "parameter_list"
                    | "formal_parameters"
                    | "function_value_parameters"
                    | "method_parameters"
            ),
            "splat_or_rest" => matches!(kind, "splat" | "splat_parameter" | "rest_assignment"),
            "constant" => matches!(
                kind,
                "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
            ),
            "block_or_do_block" => matches!(kind, "block" | "do_block"),
            "string_content_or_interpolation" => matches!(kind, "string_content" | "interpolation"),
            "string_content" => matches!(kind, "string_content" | "string_fragment"),
            "regex_or_literal" => matches!(kind, "regex" | "regex_literal"),
            "assignment_or_augmented" => matches!(
                kind,
                "assignment" | "augmented_assignment" | "annotated_assignment"
            ),
            "unary" => kind == "unary",
            "block_wrapper" => matches!(
                kind,
                "body_statement" | "block_body" | "statement" | "statement_block" | "block"
            ),
            "dotted_name" => kind == "dotted_name",
            "type" => kind == "type",
            "union_type" => kind == "union_type",
            "generic_type" => kind == "generic_type",
            "attribute" => kind == "attribute",
            "string" => matches!(
                kind,
                "string"
                    | "string_content"
                    | "string_literal"
                    | "interpreted_string_literal"
                    | "raw_string_literal"
            ),
            "list" => kind == "list",
            "expression_statement" => kind == "expression_statement",
            "else" => kind == "else",
            "then" => kind == "then",
            "if_statement" => kind == "if_statement",
            "switch_default" => kind == "switch_default",
            "scope_resolution_or_scoped_type" => {
                matches!(kind, "scope_resolution" | "scoped_type_identifier")
            }
            "field" => kind == "field",
            "module" => kind == "module",
            "yield" => kind == "yield",
            "integer" => kind == "integer",
            "block_child" => matches!(
                kind,
                "body_statement"
                    | "block_body"
                    | "block"
                    | "do_block"
                    | "class_body"
                    | "compound_statement"
                    | "declaration_list"
                    | "function_body"
                    | "match_block"
                    | "statement_block"
                    | "statement_list"
                    | "statements"
                    | "switch_body"
                    | "then"
                    | "control_structure_body"
            ),
            "type_leaf" => matches!(kind, "ellipsis" | "identifier" | "nil" | "none" | "null"),
            _ => false,
        }
    }

    /// Whether this node is a language-level absence literal. Most languages
    /// express absence with a dedicated grammar node, while TypeScript's
    /// `undefined` is an identifier that needs language-owned resolution.
    fn absence_literal(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        self.check_node_role(node, "nil")
    }

    fn tracks_dynamic_local_scope(&self) -> bool {
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

    fn custom_function_name(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
    }

    /// Source declaration whose span owns the callable's compiler symbol.
    /// Most languages define the symbol on the function node itself. Some
    /// grammars represent a named callable as an anonymous expression bound
    /// by its parent declaration.
    fn function_declaration_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> TreeSitterNode<'tree> {
        node
    }

    /// Tree-sitter error recovery can occasionally label a malformed region
    /// as a function definition. Adapters with syntax that makes a reliable
    /// declaration check possible may reject that recovery node here.
    fn valid_function_definition(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        true
    }

    fn begin_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn rescue_modifier_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn ensure_clause_statement(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn if_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "if" | "if_statement" | "if_modifier" | "if_expression" | "conditional"
        )
    }

    fn conditional_modifier_kind(&self, kind: &str) -> bool {
        kind == "if_modifier"
    }

    fn conditional_node_type(&self, kind: &str) -> Option<&'static str> {
        self.if_node_kind(kind).then_some("IF")
    }

    fn conditional_keyword_node_type(&self, keyword: &str) -> Option<&'static str> {
        match keyword {
            "if" => Some("IF"),
            _ => None,
        }
    }

    fn modifier_node_type(&self, keyword: &str) -> Option<&'static str> {
        match keyword {
            "if" => Some("IF"),
            "while" => Some("WHILE"),
            _ => None,
        }
    }

    fn conditional_branch_skip_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "comment" | "then" | "else" | "else_clause" | "else_statement"
        )
    }

    fn branch_child_skip_kind(&self, kind: &str) -> bool {
        matches!(kind, "comment" | "else")
    }

    fn conditional_consequence_kind(&self, kind: &str) -> bool {
        kind == "then"
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

    fn case_arm_pattern_nodes<'tree>(
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
            if !self.function_kind(child.kind()) {
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

    fn function_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "method"
                | "function_definition"
                | "function_declaration"
                | "method_definition"
                | "method_declaration"
                | "function_item"
        )
    }

    /// Supplies an expression-bodied function body for grammars whose
    /// declarations do not use the common `body` field (for example C#
    /// expression-bodied properties). Keeping this in the grammar adapter
    /// prevents consumers from having to special-case language node names.
    fn function_body<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn singleton_function_kind(&self, _kind: &str) -> bool {
        false
    }

    fn leading_function_keyword(&self, _kind: &str) -> bool {
        false
    }

    fn leading_function_target_kind(&self, kind: &str) -> bool {
        self.function_kind(kind) || self.singleton_function_kind(kind)
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
            .map(|child| self.leading_function_keyword(child.kind()))
            .unwrap_or(false)
        {
            return Some(node);
        }
        let raw_named = named_children(node);
        if raw_named.len() == 1
            && self.leading_function_target_kind(raw_named[0].kind())
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
            .map(|child| self.conditional_keyword_node_type(child.kind()).is_some())
            .unwrap_or(false)
            && named_children(target).len() >= 2
            && named_children(target)
                .first()
                .map(|child| !self.if_node_kind(child.kind()))
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
        if raw_named.len() == 1 {
            if self.if_node_kind(raw_named[0].kind())
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
            return Some(node);
        }
        None
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
        if raw_named.len() == 1 {
            if CASE_NODE_KINDS.contains(&raw_named[0].kind())
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
            return Some(node);
        }
        None
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
        if raw_named.len() == 1 {
            if LOOP_NODE_KINDS.contains(&raw_named[0].kind())
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
            return Some(node);
        }
        None
    }

    fn rescue_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        !self.rescue_clauses(node, source).is_empty()
    }

    fn rescue_body_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
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
        _node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let _ = source;
        Vec::new()
    }

    fn rescue_clause_exceptions_source<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn rescue_clause_exception_variable_name<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn rescue_clause_exception_variable_source<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn rescue_clause_handler<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn rescue_clause(&self, _node: TreeSitterNode<'_>) -> bool {
        false
    }

    fn ensure_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.ensure_clause(node, source).is_some()
    }

    fn ensure_body_target<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
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

    fn ensure_clause_kind(&self, _node: TreeSitterNode<'_>) -> bool {
        false
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
        self.heredoc_body_nodes(node).first().is_some()
    }

    fn heredoc_start_node(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn heredoc_body_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
    ) -> Vec<TreeSitterNode<'tree>> {
        Vec::new()
    }

    fn heredoc_body_node(&self, _node: TreeSitterNode<'_>) -> bool {
        false
    }

    fn heredoc_content_node(&self, _node: TreeSitterNode<'_>) -> bool {
        false
    }

    fn heredoc_literal_argument(
        &self,
        _node: TreeSitterNode<'_>,
        _source: &str,
        _children: &[TreeSitterNode<'_>],
    ) -> bool {
        false
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
        source: &str,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        if self.concatenated_string_target(node, source).is_some() {
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
        children.len() == 1
            && self
                .concatenated_string_target(children[0], source)
                .is_some()
    }

    fn concatenated_string_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if self.concatenated_string_node(node) {
            return Some(node);
        }
        let children = named_children(node);
        if children.len() == 1 {
            return self.concatenated_string_target(children[0], source);
        }
        None
    }

    fn concatenated_string_node(&self, _node: TreeSitterNode<'_>) -> bool {
        false
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

    // Some languages permit direct instance-field reads without an explicit
    // receiver. Adapters may identify those before the generic local-variable
    // normalization runs.
    fn direct_state_identifier(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
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

    fn call_argument_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        None
    }

    /// Return a callback expression that is syntactically carried as a call
    /// argument. Languages with trailing-block syntax use `call_block`
    /// directly; adapters only override this for native lambda-argument
    /// forms whose body is available in the source AST.
    fn call_block_argument<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn intrinsic_call_name(
        &self,
        _node: TreeSitterNode<'_>,
        _source: &str,
    ) -> Option<&'static str> {
        None
    }

    fn block_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "block"
                | "body_statement"
                | "statement_block"
                | "statement_list"
                | "class_body"
                | "switch_body"
                | "match_block"
                | "then"
                | "block_body"
                | "control_structure_body"
                | "compound_statement"
                | "declaration_list"
                | "function_body"
                | "statements"
        )
    }

    // CFG-SPECIFIC: identifies a grammar wrapper around executable control
    // body statements. The shared normalizer unwraps it before CFG lowering.
    fn cfg_control_body_wrapper(&self, _node: TreeSitterNode<'_>) -> bool {
        false
    }

    fn const_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "constant" | "scope_resolution" | "type_identifier" | "scoped_type_identifier"
        )
    }

    fn call_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "call"
                | "call_expression"
                | "function_call_expression"
                | "method_call"
                | "method_call_expression"
        )
    }

    fn case_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "case"
                | "switch_statement"
                | "expression_switch_statement"
                | "switch_expression"
                | "match_statement"
                | "match_expression"
                | "when_expression"
        )
    }

    fn when_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "when"
                | "switch_case"
                | "case_clause"
                | "expression_case"
                | "case_statement"
                | "switch_section"
                | "switch_block_statement_group"
                | "switch_entry"
                | "when_entry"
                | "match_arm"
        )
    }

    fn statement_node_kind(&self, kind: &str) -> bool {
        kind.ends_with("_statement")
            || kind.ends_with("_expression")
            || matches!(kind, "return" | "break" | "next")
    }

    fn is_pattern_node_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "pattern" | "case_pattern" | "match_pattern" | "switch_pattern" | "when_condition"
        )
    }

    fn is_pattern_wrapper_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "pattern"
                | "case_pattern"
                | "match_pattern"
                | "switch_pattern"
                | "when_condition"
                | "expression_list"
        )
    }

    fn wrapped_return_block_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "body_statement" | "block_body" | "statement" | "block" | "statement_list"
        )
    }

    fn is_command_call_wrapper_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "body_statement" | "block" | "block_body" | "statement"
        )
    }

    fn is_terminal_statement_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "body_statement" | "block_body" | "statement" | "argument_list"
        )
    }

    fn is_parameter_name_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "identifier"
                | "hash_splat_parameter"
                | "splat_parameter"
                | "block_parameter"
                | "keyword_parameter"
                | "optional_parameter"
        )
    }

    fn is_vcall_excluded_parent_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "method" | "method_parameters" | "parameter_list" | "argument_list" | "arguments"
        )
    }

    fn is_inline_def_receiver_kind(&self, kind: &str) -> bool {
        matches!(kind, "self" | "this" | "constant" | "scope_resolution")
    }

    fn is_boolean_statement_wrapper_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "body_statement" | "block_body" | "statement" | "argument_list" | "expression_list"
        )
    }

    fn is_statement_wrapper_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "body_statement" | "block_body" | "statement" | "argument_list"
        )
    }

    fn is_infix_target_kind(&self, kind: &str) -> bool {
        matches!(kind, "binary" | "binary_expression" | "comparison_operator")
    }

    fn is_call_block_or_arg_kind(&self, kind: &str) -> bool {
        matches!(kind, "block" | "do_block" | "argument_list" | "arguments")
    }

    fn is_member_read_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "call"
                | "attribute"
                | "member_expression"
                | "member_access_expression"
                | "dot_index_expression"
                | "field"
                | "field_access"
                | "selector_expression"
                | "field_expression"
                | "navigation_expression"
                | "directly_assignable_expression"
                | "expression_list"
        )
    }

    fn block_pass_argument(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn singleton_class_node(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn class_like_owner_kind(&self, _kind: &str) -> bool {
        false
    }

    fn class_like_owner_name<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn class_like_owner_body<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    /// Extra raw nodes to fold into a class's scanned body, for grammars
    /// where the class declaration's members live outside its body block
    /// (for example Kotlin's `class Widget(private var count: Int) { .. }`:
    /// `count` is a `class_parameter` of a sibling `primary_constructor`
    /// node, not a child of `class_body`, so it is invisible to
    /// `collect_owner_fields_from_children` unless surfaced here).
    /// Defaults to none for every language; only overridden where a real
    /// gap was found and reproduced with a fixture, not speculatively.
    fn supplementary_class_body_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        Vec::new()
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        match kind {
            "while" | "while_statement" | "while_modifier" => Some("WHILE"),
            "for" | "for_statement" | "for_in_clause" => Some("FOR"),
            _ => None,
        }
    }

    /// Supplies the iterable/range expression for `FOR` syntaxes whose
    /// binding is the first named child. Returning the binding as the loop
    /// condition loses the cardinality domain and collapses nested products.
    fn loop_condition_node<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        None
    }

    fn modifier_loop_kind(&self, _kind: &str) -> bool {
        false
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

    /// Returns a language-owned canonical assignment target when concrete
    /// declaration syntax adds punctuation that is not part of the binding.
    fn assignment_target_name(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
    }

    fn instance_variable(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn global_variable(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn dynamic_constant_pattern_text(&self, _text: &str) -> bool {
        false
    }

    fn dynamic_exception_constant_text(&self, _text: &str) -> bool {
        false
    }

    fn dynamic_instance_variable_text(&self, _text: &str) -> bool {
        false
    }

    /// Some grammars spell compiler-provided closure parameters with a dollar
    /// prefix. They are lexical locals, not process-global variables.
    fn dollar_prefixed_local_name(&self, _text: &str) -> Option<String> {
        None
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

    fn non_local_assignment_lhs(&self, _node: TreeSitterNode<'_>, _source: &str) -> bool {
        false
    }

    fn local_binding_name(&self, _node: TreeSitterNode<'_>, _source: &str) -> Option<String> {
        None
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

    fn inline_def_wrapper_mid(&self, _text: &str) -> bool {
        false
    }

    fn inline_def_receiver_text(&self, _text: &str) -> bool {
        false
    }

    fn inline_def_function_kind(&self, kind: &str) -> bool {
        self.function_kind(kind) || self.singleton_function_kind(kind)
    }

    fn inline_def_function_text_source<'tree>(
        &self,
        function: TreeSitterNode<'tree>,
        _source: &str,
    ) -> TreeSitterNode<'tree> {
        function
    }

    fn normalized_for_parts<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<(
        TreeSitterNode<'tree>,
        TreeSitterNode<'tree>,
        Option<TreeSitterNode<'tree>>,
    )> {
        None
    }

    fn normalized_with_parts<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<(Vec<TreeSitterNode<'tree>>, Option<TreeSitterNode<'tree>>)> {
        None
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

    fn function_parameter_nodes<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        None
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

#[cfg(test)]
mod dummy_arch_test {}

pub(crate) mod tests {
    use super::*;
    use tree_sitter::Parser;

    struct DummyAdapter;
    impl AstNormalizationAdapter for DummyAdapter {}

    struct MockAdapterForRescue;
    impl AstNormalizationAdapter for MockAdapterForRescue {
        fn rescue_body_target<'tree>(
            &self,
            node: TreeSitterNode<'tree>,
            _source: &str,
        ) -> Option<TreeSitterNode<'tree>> {
            Some(node)
        }
    }

    struct MockAdapterForEnsure;
    impl AstNormalizationAdapter for MockAdapterForEnsure {
        fn ensure_body_target<'tree>(
            &self,
            node: TreeSitterNode<'tree>,
            _source: &str,
        ) -> Option<TreeSitterNode<'tree>> {
            Some(node)
        }
        fn ensure_clause_kind(&self, node: TreeSitterNode<'_>) -> bool {
            node.kind() == "block"
        }
    }

    struct MockAdapterWithKeyword;
    impl AstNormalizationAdapter for MockAdapterWithKeyword {
        fn leading_function_keyword(&self, _kind: &str) -> bool {
            true
        }
    }

    pub(crate) fn test_base_adapter_defaults_impl() {
        let adapter = DummyAdapter;
        // Test non-node methods
        assert!(!adapter.tracks_dynamic_local_scope());
        assert!(adapter.if_node_kind("if"));
        assert!(adapter.if_node_kind("if_statement"));
        assert!(!adapter.if_node_kind("unless"));
        assert!(adapter.conditional_modifier_kind("if_modifier"));
        assert!(!adapter.conditional_modifier_kind("if"));
        assert_eq!(adapter.conditional_node_type("if"), Some("IF"));
        assert_eq!(adapter.conditional_node_type("unless"), None);
        assert_eq!(adapter.conditional_keyword_node_type("if"), Some("IF"));
        assert_eq!(adapter.conditional_keyword_node_type("unless"), None);
        assert_eq!(adapter.modifier_node_type("if"), Some("IF"));
        assert_eq!(adapter.modifier_node_type("while"), Some("WHILE"));
        assert_eq!(adapter.modifier_node_type("unless"), None);
        assert!(adapter.conditional_branch_skip_kind("comment"));
        assert!(!adapter.conditional_branch_skip_kind("if"));
        assert!(adapter.branch_child_skip_kind("comment"));
        assert!(!adapter.branch_child_skip_kind("if"));
        assert!(adapter.conditional_consequence_kind("then"));
        assert!(!adapter.conditional_consequence_kind("else"));
        assert!(adapter.function_kind("method"));
        assert!(!adapter.function_kind("not_func"));
        assert!(!adapter.singleton_function_kind("not_func"));
        assert!(!adapter.leading_function_keyword("def"));
        assert!(!adapter.leading_function_target_kind("def"));
        assert_eq!(adapter.leading_function_body_kind(), "body_statement");
        assert!(!adapter.dynamic_constant_pattern_text(""));
        assert!(!adapter.dynamic_exception_constant_text(""));
        assert!(!adapter.dynamic_instance_variable_text(""));
        assert!(!adapter.logical_operator_assignment("&&="));
        assert!(!adapter.inline_def_receiver_text(""));
        assert!(!adapter.inline_def_function_kind("def"));
        assert!(!adapter.normalize_default_parameters());
        assert!(!adapter.normalize_block_parameters());

        // Parse a dummy node to test node-accepting methods
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_rust::LANGUAGE.into())
            .unwrap();
        let tree = parser.parse("fn foo() { yield 1; }", None).unwrap();
        let root = tree.root_node();
        let fn_node = root.child(0).unwrap();

        assert!(!adapter.rescue_clause(fn_node));
        assert!(!adapter.yield_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.super_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.safe_navigation_call(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.begin_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.rescue_modifier_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.ensure_clause_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.ternary_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .ternary_parts(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.case_argument_list(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.case_arm(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .case_arm_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .case_arm_pattern_nodes(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .case_else_node(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.case_else_node_kind(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.case_else_arm(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.leading_function_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .leading_function_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.leading_owner_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .leading_owner_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.leading_if_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .leading_if_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.leading_case_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .leading_case_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.leading_loop_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .leading_loop_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.rescue_body_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .rescue_body_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .rescue_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(adapter
            .rescue_clauses(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(adapter
            .rescue_clause_exceptions(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(adapter
            .rescue_clause_exceptions_source(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .rescue_clause_exception_variable_name(fn_node)
            .is_none());
        assert!(adapter
            .rescue_clause_exception_variable_source(fn_node)
            .is_none());
        assert!(adapter.rescue_clause_handler(fn_node).is_none());
        assert!(!adapter.ensure_body_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .ensure_body_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .ensure_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(!adapter.ensure_clause_kind(fn_node));
        assert!(adapter
            .ensure_clause(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter.ensure_clause_body(fn_node).is_none());
        assert!(!adapter.instance_variable(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.global_variable(fn_node, "fn foo() { yield 1; }"));
        assert!(!adapter.literal_fragment_assignment_context(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .array_literal_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter
            .array_literal_values(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(!adapter.element_reference_statement(fn_node, "fn foo() { yield 1; }"));
        assert!(adapter
            .element_reference_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .element_reference_receiver(fn_node, "fn foo() { yield 1; }")
            .is_some());
        assert!(!adapter
            .element_reference_arguments(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(adapter
            .statement_wrapped_call_target(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.inline_def_wrapper_mid(""));
        assert_eq!(
            adapter.inline_def_function_text_source(fn_node, "fn foo() { yield 1; }"),
            fn_node
        );
        assert!(adapter
            .normalized_for_parts(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .normalized_with_parts(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.bare_const_call_function(fn_node));
        assert!(adapter
            .function_parameter_nodes(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(!adapter.heredoc_content_node(fn_node));
        assert!(!adapter.heredoc_call_for_body(fn_node, ""));
        assert!(adapter.descendant(fn_node, &["nonexistent"]).is_none());

        // Test MockAdapterForRescue / MockAdapterForEnsure / MockAdapterWithKeyword
        let rescue_adapter = MockAdapterForRescue;
        assert!(rescue_adapter
            .rescue_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_empty());

        let ensure_adapter = MockAdapterForEnsure;
        assert!(!ensure_adapter
            .ensure_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_empty());
        assert!(ensure_adapter
            .ensure_clause(fn_node, "fn foo() { yield 1; }")
            .is_some());

        // JS loop tests
        let mut js_parser = Parser::new();
        js_parser
            .set_language(&tree_sitter_javascript::LANGUAGE.into())
            .unwrap();
        let js_loop_tree = js_parser.parse("while(true){}", None).unwrap();
        let js_loop_stmt = js_loop_tree.root_node().child(0).unwrap(); // while_statement
        let _js_body_stmt = js_loop_stmt.child(2).unwrap(); // statement

        let mut ruby_parser = Parser::new();
        ruby_parser
            .set_language(&tree_sitter_ruby::LANGUAGE.into())
            .unwrap();
        let ruby_tree_fn = ruby_parser.parse("def foo; x = 1; end", None).unwrap();
        let ruby_method = ruby_tree_fn.root_node().child(0).unwrap(); // method
        let ruby_body = (0..ruby_method.child_count())
            .map(|i| ruby_method.child(i).unwrap())
            .find(|c| c.kind() == "body_statement")
            .unwrap_or(ruby_method);

        let kw_adapter = MockAdapterWithKeyword;
        assert!(kw_adapter
            .leading_function_target(ruby_body, "def foo; x = 1; end")
            .is_some());

        let ruby_loop_tree = ruby_parser
            .parse("def bar; while true; end; end", None)
            .unwrap();
        let ruby_loop_method = ruby_loop_tree.root_node().child(0).unwrap();
        let ruby_loop_body = (0..ruby_loop_method.child_count())
            .map(|i| ruby_loop_method.child(i).unwrap())
            .find(|c| c.kind() == "body_statement")
            .unwrap_or(ruby_loop_method);
        assert!(adapter
            .leading_loop_target(ruby_loop_body, "def bar; while true; end; end")
            .is_some());

        // concatenated_string
        let js_str_tree = js_parser.parse("\"foo\"", None).unwrap();
        let js_str_node = js_str_tree.root_node().child(0).unwrap().child(0).unwrap();
        assert!(adapter.concatenated_string_statement(
            ruby_body,
            "def foo; x = 1; end",
            &[js_str_node, js_str_node]
        ));

        // literal_fragment_assignment_context root (no parent) and Ruby grandparent interpolation
        assert!(!adapter.literal_fragment_assignment_context(root, "fn foo() { yield 1; }"));

        let mut ruby_parser = Parser::new();
        ruby_parser
            .set_language(&tree_sitter_ruby::LANGUAGE.into())
            .unwrap();
        let ruby_tree = ruby_parser.parse("\"hello #{name}\"", None).unwrap();
        let string_node = (0..ruby_tree.root_node().child_count())
            .map(|i| ruby_tree.root_node().child(i).unwrap())
            .find(|c| c.kind() == "string")
            .unwrap();
        let interpolation = (0..string_node.child_count())
            .map(|i| string_node.child(i).unwrap())
            .find(|c| c.kind() == "interpolation")
            .unwrap();
        assert!(adapter.literal_fragment_assignment_context(interpolation, "\"hello #{name}\""));

        // Extra coverage cases for remaining missed lines in base.rs
        // class_like_owner_name and class_like_owner_body (lines 867-873, 875-881)
        assert!(adapter
            .class_like_owner_name(fn_node, "fn foo() { yield 1; }")
            .is_none());
        assert!(adapter
            .class_like_owner_body(fn_node, "fn foo() { yield 1; }")
            .is_none());

        // template string grandparent checks (line 948)
        let js_tpl_tree = js_parser.parse("`hello ${x}`", None).unwrap();
        let js_tpl_node = js_tpl_tree.root_node().child(0).unwrap().child(0).unwrap(); // template_string
        let js_frag_node = js_tpl_node.child(1).unwrap(); // string_fragment
        assert!(!adapter.literal_fragment_assignment_context(js_frag_node, "`hello ${x}`"));

        // leading_loop_statement named children count (line 339) and leading_loop_target matching text (line 355)
        let ruby_loop_tree2 = ruby_parser
            .parse("def bar;while true;x = 1;end end", None)
            .unwrap();
        let ruby_loop_method2 = ruby_loop_tree2.root_node().child(0).unwrap();
        let ruby_loop_body2 = (0..ruby_loop_method2.child_count())
            .map(|i| ruby_loop_method2.child(i).unwrap())
            .find(|c| c.kind() == "body_statement")
            .unwrap();
        let loop_target = adapter
            .leading_loop_target(ruby_loop_body2, "def bar;while true;x = 1;end end")
            .unwrap();
        eprintln!("LOOP TARGET KIND: {}", loop_target.kind());
        eprintln!(
            "LOOP TARGET TEXT: {}",
            node_text(loop_target, "def bar;while true;x = 1;end end")
        );
        for child in loop_target.children(&mut loop_target.walk()) {
            eprintln!("  CHILD: {}, named: {}", child.kind(), child.is_named());
        }
        eprintln!("NAMED CHILDREN LEN: {}", named_children(loop_target).len());
        assert!(adapter.leading_loop_statement(ruby_loop_body2, "def bar;while true;x = 1;end end"));

        // ensure_body_nodes empty path when no clause is found (line 470)
        struct MockEnsureMissingClause;
        impl AstNormalizationAdapter for MockEnsureMissingClause {
            fn ensure_body_target<'tree>(
                &self,
                node: TreeSitterNode<'tree>,
                _source: &str,
            ) -> Option<TreeSitterNode<'tree>> {
                Some(node)
            }
        }
        assert!(MockEnsureMissingClause
            .ensure_body_nodes(fn_node, "fn foo() { yield 1; }")
            .is_empty());

        // array_literal_target bracketed case (line 513)
        let js_bracket_tree = js_parser.parse("[1, 2]", None).unwrap();
        let js_bracket_node = js_bracket_tree.root_node().child(0).unwrap(); // expression_statement
        assert!(adapter
            .array_literal_target(js_bracket_node, "[1, 2]")
            .is_some());

        // array_literal_target semicolon stripped child case (line 534)
        let js_semi_tree = js_parser.parse("[1, 2];", None).unwrap();
        let js_semi_node = js_semi_tree.root_node().child(0).unwrap(); // expression_statement
        assert!(adapter
            .array_literal_target(js_semi_node, "[1, 2];")
            .is_some());

        // element_reference_target semicolon stripped child case (line 579)
        let js_ref_semi_tree = js_parser.parse("a[i];", None).unwrap();
        let js_ref_semi_node = js_ref_semi_tree.root_node().child(0).unwrap(); // expression_statement
        assert!(adapter
            .element_reference_target(js_ref_semi_node, "a[i];")
            .is_some());

        // element_reference_target element_reference_shape fallback case (line 583)
        let js_ref_shape_tree = js_parser.parse("a[i]", None).unwrap();
        let js_ref_shape_node = js_ref_shape_tree.root_node().child(0).unwrap(); // expression_statement
        assert!(adapter
            .element_reference_target(js_ref_shape_node, "a[i]")
            .is_some());
    }

    #[test]
    fn test_base_adapter_defaults() {
        test_base_adapter_defaults_impl();
    }
}

pub fn run_base_adapter_defaults_tests() {
    tests::test_base_adapter_defaults_impl();
}
