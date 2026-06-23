use super::super::{
    bare_identifier_text, named_children, node_text, raw_named_children, TernaryParts,
};
use super::base::{AstNormalizationAdapter, NamedChildrenAction};
use tree_sitter::Node as TreeSitterNode;

const PYTHON_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "//=", "**=", "@=", "&=", "|=", "^=", "<<=", ">>=", ":=",
];
const PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "expression_statement",
];
const PYTHON_LEADING_FUNCTION_WRAPPER_KINDS: &[&str] = &["block"];
const PYTHON_LEADING_OWNER_WRAPPER_KINDS: &[&str] = &["block"];
const PYTHON_LEADING_IF_WRAPPER_KINDS: &[&str] = &["block"];
const PYTHON_CONCATENATED_STRING_WRAPPER_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "block",
    "expression_statement",
];
const PYTHON_BODY_FIELD_KINDS: &[&str] = &[
    "elif_clause",
    "else_clause",
    "for_statement",
    "function_definition",
    "if_statement",
    "try_statement",
    "while_statement",
    "with_statement",
];

pub(crate) struct PythonAstAdapter;

impl AstNormalizationAdapter for PythonAstAdapter {
    fn yield_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        if !matches!(
            node.kind(),
            "body_statement" | "block" | "block_body" | "expression_statement" | "statement"
        ) {
            return false;
        }
        let named = named_children(node);
        named.len() == 1
            && named[0].kind() == "yield"
            && node_text(named[0], source) == node_text(node, source)
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "elif_clause" | "else" | "else_clause"))
    }

    fn case_else_arm(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "case_clause" && self.default_case_pattern(node, source)
    }

    fn named_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        node.child_by_field_name(name)
            .or_else(|| self.python_body_field(node, name))
    }

    fn named_children_action<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> NamedChildrenAction<'tree> {
        if node.kind() == "with_clause" && bare_identifier_text(node_text(node, source)) {
            return NamedChildrenAction::Drop;
        }

        if node.kind() == "relative_import"
            && children.len() == 1
            && children[0].kind() == "import_prefix"
        {
            return NamedChildrenAction::Drop;
        }

        if node.kind() == "block" && children.len() == 1 {
            let child = children[0];
            if matches!(child.kind(), "function_definition" | "decorated_definition") {
                return NamedChildrenAction::Recurse(child);
            }
            if child.kind() == "pass_statement" && node_text(node, source).trim() == "pass" {
                return NamedChildrenAction::Drop;
            }
            if matches!(child.kind(), "break_statement" | "continue_statement")
                && bare_identifier_text(node_text(node, source).trim())
            {
                return NamedChildrenAction::Drop;
            }
            if child.kind() == "return_statement"
                && node_text(node, source) == node_text(child, source)
            {
                if raw_named_children(child).is_empty() {
                    return NamedChildrenAction::Drop;
                }
                return NamedChildrenAction::Recurse(child);
            }
            if matches!(child.kind(), "delete_statement" | "if_statement") {
                return NamedChildrenAction::Recurse(child);
            }
            if matches!(
                child.kind(),
                "assert_statement"
                    | "for_statement"
                    | "import_from_statement"
                    | "import_statement"
                    | "raise_statement"
                    | "try_statement"
                    | "while_statement"
                    | "with_statement"
            ) {
                return NamedChildrenAction::Recurse(child);
            }
            if child.kind() == "expression_statement" {
                let statement_children = raw_named_children(child);
                if statement_children.len() == 1
                    && statement_children[0].kind() == "identifier"
                    && node_text(node, source) == node_text(child, source)
                {
                    return NamedChildrenAction::Drop;
                }
                if statement_children.len() == 1 && statement_children[0].kind() == "ellipsis" {
                    return NamedChildrenAction::Drop;
                }
                if statement_children.len() == 1 && statement_children[0].kind() == "call" {
                    let call_children = raw_named_children(statement_children[0]);
                    if call_children
                        .first()
                        .map(|child| child.kind() == "identifier")
                        .unwrap_or(false)
                    {
                        return NamedChildrenAction::Recurse(statement_children[0]);
                    }
                }
                if statement_children.len() == 1
                    && matches!(
                        statement_children[0].kind(),
                        "assignment"
                            | "augmented_assignment"
                            | "binary_operator"
                            | "string"
                            | "subscript"
                    )
                {
                    return NamedChildrenAction::Recurse(statement_children[0]);
                }
            }
        }

        if node.kind() == "expression_statement" && children.len() == 1 {
            let child = children[0];
            if child.kind() == "identifier" {
                return NamedChildrenAction::Drop;
            }
            if matches!(
                child.kind(),
                "yield" | "binary_operator" | "comparison_operator" | "attribute" | "string"
            ) {
                return NamedChildrenAction::Recurse(child);
            }
            if child.kind() == "call" {
                let call_children = raw_named_children(child);
                if call_children
                    .first()
                    .map(|child| child.kind() == "identifier")
                    .unwrap_or(false)
                {
                    return NamedChildrenAction::Recurse(child);
                }
            }
        }

        if node.kind() == "as_pattern_target" {
            return NamedChildrenAction::Drop;
        }

        if matches!(node.kind(), "with_clause" | "with_item")
            && children.len() == 1
            && matches!(children[0].kind(), "with_item" | "as_pattern")
        {
            return NamedChildrenAction::Recurse(children[0]);
        }

        if node.kind() == "with_item"
            && children.len() == 1
            && matches!(children[0].kind(), "call" | "attribute")
            && node_text(node, source) == node_text(children[0], source)
        {
            return NamedChildrenAction::Recurse(children[0]);
        }

        if node.kind() == "type" && children.len() == 1 && children[0].kind() == "binary_operator" {
            return NamedChildrenAction::Recurse(children[0]);
        }

        NamedChildrenAction::Default
    }

    fn non_local_assignment_lhs(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.parent()
            .map(|parent| parent.kind() == "keyword_argument")
            .unwrap_or(false)
    }

    fn local_binding_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        (node.kind() == "as_pattern_target")
            .then(|| node_text(node, source).to_string())
            .filter(|name| bare_identifier_text(name))
    }

    fn nested_class_body_child<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "block" {
            return None;
        }
        let raw_children = raw_named_children(node);
        if raw_children.len() == 1
            && raw_children[0].kind() == "class_definition"
            && node
                .parent()
                .map(|parent| parent.kind() == "class_definition")
                .unwrap_or(false)
        {
            Some(raw_children[0])
        } else {
            None
        }
    }

    fn else_if_block<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "else_clause" {
            return None;
        }
        raw_named_children(node)
            .into_iter()
            .find(|child| child.kind() == "block")
    }

    fn leading_function_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.leading_function_statement_with_keyword(
            node,
            source,
            "def",
            PYTHON_LEADING_FUNCTION_WRAPPER_KINDS,
        )
    }

    fn leading_function_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !PYTHON_LEADING_FUNCTION_WRAPPER_KINDS.contains(&node.kind()) {
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
        self.exact_single_named_child(node, &["function_definition"], source)
    }

    fn leading_function_body_kind(&self) -> &'static str {
        "block"
    }

    fn statement_wrapped_call_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() != "expression_statement" {
            return None;
        }
        let raw_named = raw_named_children(node);
        if raw_named.len() == 1
            && raw_named[0].kind() == "call"
            && node_text(raw_named[0], source) == node_text(node, source)
        {
            Some(raw_named[0])
        } else {
            None
        }
    }

    fn normalized_for_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<(
        TreeSitterNode<'tree>,
        TreeSitterNode<'tree>,
        Option<TreeSitterNode<'tree>>,
    )> {
        let statement = self
            .exact_single_named_child(node, &["for_statement"], source)
            .unwrap_or(node);
        if statement.kind() != "for_statement" {
            return None;
        }

        let named = named_children(statement);
        let body = named
            .iter()
            .rev()
            .copied()
            .find(|child| child.kind() == "block");
        let mut header = named.into_iter().filter(|child| Some(*child) != body);
        let target = header.next()?;
        let iterable = header.next()?;
        Some((target, iterable, body))
    }

    fn normalized_with_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<(Option<TreeSitterNode<'tree>>, Option<TreeSitterNode<'tree>>)> {
        let statement = self
            .exact_single_named_child(node, &["with_statement"], source)
            .unwrap_or(node);
        if statement.kind() != "with_statement" {
            return None;
        }

        let named = named_children(statement);
        let clause = named
            .iter()
            .copied()
            .find(|child| child.kind() == "with_clause");
        let body = named
            .iter()
            .rev()
            .copied()
            .find(|child| child.kind() == "block");
        Some((clause, body))
    }

    fn leading_owner_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if PYTHON_LEADING_OWNER_WRAPPER_KINDS.contains(&node.kind()) {
            let raw_named = named_children(node);
            if raw_named.len() == 1
                && matches!(
                    raw_named[0].kind(),
                    "class" | "class_definition" | "class_declaration" | "module"
                )
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
            }
            return Some(node);
        }
        if super::super::LEADING_OWNER_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn leading_if_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if PYTHON_LEADING_IF_WRAPPER_KINDS.contains(&node.kind()) {
            if let Some(child) = self.exact_single_named_child(node, &["if_statement"], source) {
                return Some(child);
            }
        }
        if super::super::LEADING_IF_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement"
            || self.flattened_try_block(node, &["except_clause"], source)
        {
            return Some(node);
        }
        if node.kind() == "block" {
            if let Some(child) = self.exact_single_named_child(node, &["try_statement"], source) {
                return Some(child);
            }
        }
        if super::super::RESCUE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn rescue_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.rescue_body_target(node, source).unwrap_or(node);
        if target.kind() == "try_statement"
            || self.flattened_try_block(target, &["except_clause"], source)
        {
            return named_children(target)
                .into_iter()
                .take_while(|child| !matches!(child.kind(), "except_clause" | "finally_clause"))
                .collect();
        }
        let Some(index) = named_children(target)
            .iter()
            .position(|child| self.rescue_clause(*child))
        else {
            return Vec::new();
        };
        named_children(target)[..index].to_vec()
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
            .filter(|child| child.kind() == "except_clause")
            .collect()
    }

    fn rescue_clause_exceptions<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(pattern) = named_children(node)
            .into_iter()
            .find(|child| !matches!(child.kind(), "block" | "comment"))
        else {
            return Vec::new();
        };
        if pattern.kind() != "as_pattern" {
            return vec![pattern];
        }
        named_children(pattern)
            .into_iter()
            .find(|child| child.kind() != "as_pattern_target")
            .into_iter()
            .collect()
    }

    fn rescue_clause_exceptions_source<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        self.rescue_clause_exceptions(node, source)
            .into_iter()
            .next()
    }

    fn rescue_clause_exception_variable_name<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "as_pattern")
            .and_then(|pattern| self.descendant(pattern, &["as_pattern_target"]))
    }

    fn rescue_clause_exception_variable_source<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        self.rescue_clause_exception_variable_name(node)
    }

    fn rescue_clause_handler<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == "block")
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement"
            || self.flattened_try_block(node, &["finally_clause"], source)
        {
            return Some(node);
        }
        if node.kind() == "block" {
            if let Some(child) = self.exact_single_named_child(node, &["try_statement"], source) {
                return Some(child);
            }
        }
        if super::super::ENSURE_BODY_WRAPPER_KINDS.contains(&node.kind()) {
            return Some(node);
        }
        None
    }

    fn ensure_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let target = self.ensure_body_target(node, source).unwrap_or(node);
        if target.kind() == "try_statement"
            || self.flattened_try_block(target, &["finally_clause"], source)
        {
            return named_children(target)
                .into_iter()
                .take_while(|child| child.kind() != "finally_clause")
                .collect();
        }
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
            .find(|child| child.kind() == "finally_clause")
    }

    fn ensure_clause_body<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind() == "block")
    }

    fn ternary_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TernaryParts<'tree>> {
        if node.kind() != "conditional_expression" {
            return None;
        }
        let named = named_children(node);
        Some(TernaryParts {
            condition: *named.get(1)?,
            positive: vec![*named.first()?],
            negative: vec![*named.get(2)?],
        })
    }

    fn unary_minus_expression(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        matches!(node.kind(), "unary" | "unary_expression" | "unary_operator")
            && node_text(node, source).trim_start().starts_with('-')
    }

    fn empty_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        (super::super::EMPTY_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node).is_empty()
            && node_text(node, source).trim().is_empty())
            || node.kind() == "pass_statement"
            || (node.kind() == "block" && node_text(node, source).trim() == "pass" && {
                let named = named_children(node);
                named.is_empty() || named.iter().all(|child| child.kind() == "pass_statement")
            })
    }

    fn operator_call_expression_kind(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "binary" | "binary_expression" | "binary_operator"
        )
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        PYTHON_ASSIGNMENT_OPERATORS
    }

    fn concatenated_string_wrapper_kinds(&self) -> &'static [&'static str] {
        PYTHON_CONCATENATED_STRING_WRAPPER_KINDS
    }

    fn concatenated_string_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "concatenated_string"
    }

    fn dotted_expression_wrapper_kinds(&self) -> &'static [&'static str] {
        PYTHON_DOTTED_EXPRESSION_WRAPPER_KINDS
    }
}

impl PythonAstAdapter {
    fn flattened_try_block(
        &self,
        node: TreeSitterNode<'_>,
        clauses: &[&str],
        source: &str,
    ) -> bool {
        node.kind() == "block"
            && node
                .children(&mut node.walk())
                .next()
                .map(|child| node_text(child, source) == "try")
                .unwrap_or(false)
            && named_children(node)
                .iter()
                .any(|child| clauses.contains(&child.kind()))
    }

    fn python_body_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if !matches!(name, "body" | "consequence")
            || !PYTHON_BODY_FIELD_KINDS.contains(&node.kind())
        {
            return None;
        }
        raw_named_children(node)
            .into_iter()
            .find(|child| child.kind() == "block")
    }
}
