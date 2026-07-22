use super::super::{
    named_children, node_text, question_colon_ternary_parts, raw_named_children, TernaryParts,
};
use super::base::AstNormalizationAdapter;
use tree_sitter::Node as TreeSitterNode;

const TYPESCRIPT_ASSIGNMENT_OPERATORS: &[&str] = &[
    "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=",
    "??=",
];
const TYPESCRIPT_TERNARY_KINDS: &[&str] = &[
    "body_statement",
    "block_body",
    "statement",
    "argument_list",
    "conditional",
    "ternary_expression",
];

pub(crate) struct TypeScriptAstAdapter;

impl AstNormalizationAdapter for TypeScriptAstAdapter {
    fn named_field<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        name: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "variable_declarator" {
            match name {
                "left" => return node.child_by_field_name("name"),
                "right" => return node.child_by_field_name("value"),
                _ => {}
            }
        }
        node.child_by_field_name(name)
    }

    fn absence_literal(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        self.check_node_role(node, "nil")
            || (node_text(node, source).trim() == "undefined"
                && !typescript_undefined_is_shadowed(node, source))
    }

    // `abstract class Foo { ... }` is a distinct grammar node
    // (abstract_class_declaration), not `class_declaration` - the default
    // class_node matcher never recognized it, so an abstract base class
    // (arguably the single most architecturally important class in a
    // typical OO codebase - every concrete subclass extends it) was
    // dropped as an owner entirely, and its own methods/state fell back to
    // whatever unrelated owner the extractor happened to be tracking.
    fn class_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(
            node.kind(),
            "class"
                | "class_definition"
                | "class_declaration"
                | "class_specifier"
                | "abstract_class_declaration"
        )
    }

    fn function_kind(&self, kind: &str) -> bool {
        matches!(
            kind,
            "method"
                | "function_definition"
                | "function_declaration"
                | "method_definition"
                | "method_declaration"
                | "method_signature"
                | "arrow_function"
                | "function_expression"
        )
    }

    fn custom_function_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        typescript_bound_callable_name(node, source)
    }

    fn valid_function_definition(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        !matches!(node.kind(), "arrow_function" | "function_expression")
            || typescript_bound_callable_name(node, source).is_some()
    }

    fn function_declaration_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> TreeSitterNode<'tree> {
        if typescript_bound_callable_name(node, source).is_some() {
            node.parent().unwrap_or(node)
        } else {
            node
        }
    }

    fn explicit_alternative<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "else" | "else_clause"))
    }

    fn safe_navigation_call(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.children(&mut node.walk())
            .any(|child| !child.is_named() && node_text(child, source) == "&.")
            || node
                .children(&mut node.walk())
                .any(|child| child.kind() == "optional_chain" && node_text(child, source) == "?.")
            || (node.kind() == "call_expression"
                && named_children(node)
                    .into_iter()
                    .any(|child| self.safe_navigation_call(child, source)))
    }

    fn ternary_parts<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TernaryParts<'tree>> {
        question_colon_ternary_parts(node, source, TYPESCRIPT_TERNARY_KINDS)
    }

    fn interpolated_string(
        &self,
        node: TreeSitterNode<'_>,
        children: &[TreeSitterNode<'_>],
    ) -> bool {
        (node.kind() == "string" && children.iter().any(|child| child.kind() == "interpolation"))
            || (node.kind() == "template_string"
                && children
                    .iter()
                    .any(|child| child.kind() == "template_substitution"))
    }

    fn lambda_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if matches!(
            node.kind(),
            "arrow_function" | "function_expression" | "lambda"
        ) && typescript_bound_callable_name(node, source).is_none()
        {
            Some(node)
        } else {
            None
        }
    }

    fn interpolation_node(&self, node: TreeSitterNode<'_>) -> bool {
        matches!(node.kind(), "interpolation" | "template_substitution")
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_case" {
            return None;
        }
        let body = named_children(node)
            .into_iter()
            .skip(1)
            .filter(|child| child.kind() != "break_statement")
            .collect::<Vec<_>>();
        (!body.is_empty()).then_some(body)
    }

    fn case_arm_pattern_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "switch_case" {
            return None;
        }
        let patterns = named_children(node)
            .into_iter()
            .take_while(|child| child.kind() != "expression_statement")
            .collect::<Vec<_>>();
        (!patterns.is_empty()).then_some(patterns)
    }

    fn rescue_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement" {
            return Some(node);
        }
        if node.kind() == "statement_block" {
            let raw_named = raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "try_statement"
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
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
        if target.kind() == "try_statement" {
            return named_children(target)
                .into_iter()
                .take_while(|child| !matches!(child.kind(), "catch_clause" | "finally_clause"))
                .collect();
        }
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
            .filter(|child| child.kind() == "catch_clause")
            .collect()
    }

    fn rescue_clause_exceptions<'tree>(
        &self,
        _node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
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
        node: TreeSitterNode<'tree>,
    ) -> Option<TreeSitterNode<'tree>> {
        named_children(node)
            .into_iter()
            .find(|child| super::super::identifier_kind_name(child.kind()))
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
            .find(|child| child.kind() == "statement_block")
    }

    fn ensure_body_target<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        if node.kind() == "try_statement" {
            return Some(node);
        }
        if node.kind() == "statement_block" {
            let raw_named = raw_named_children(node);
            if raw_named.len() == 1
                && raw_named[0].kind() == "try_statement"
                && node_text(raw_named[0], source) == node_text(node, source)
            {
                return Some(raw_named[0]);
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
        if target.kind() == "try_statement" {
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
            .find(|child| child.kind() == "statement_block")
    }

    fn empty_body_statement(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        (super::super::EMPTY_BODY_WRAPPER_KINDS.contains(&node.kind())
            && named_children(node).is_empty()
            && node_text(node, source).trim().is_empty())
            || (node.kind() == "statement_block"
                && named_children(node).is_empty()
                && node_text(node, source).trim() == "{}")
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        TYPESCRIPT_ASSIGNMENT_OPERATORS
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        match kind {
            "for_in_statement" | "for_statement" => Some("FOR"),
            "while_statement" => Some("WHILE"),
            _ => None,
        }
    }

    fn loop_condition_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        // In tree-sitter TypeScript, a `for (const item of items)` header has
        // both a binding (`left`) and the cardinality-bearing iterable
        // (`right`). The generic first-named-child fallback selected the
        // binding, which made every `for..of` loop look like an unbounded
        // local domain. Preserve the iterable in the normalized `FOR`
        // condition so all downstream CFG/DFG and complexity consumers see
        // the same source of cardinality.
        (node.kind() == "for_in_statement")
            .then(|| node.child_by_field_name("right"))
            .flatten()
    }

    // `constructor(private count: number) { ... }`: parameter normalization
    // (normalize_parameter_init, shared/generic) wraps every parameter as a
    // bare `LASGN(Symbol(name), default?)`, discarding the accessibility
    // modifier and type annotation before the syntax layer ever runs - so
    // there is nothing left by then to recognize as a property, regardless
    // of any field-declaration matching added there. Re-supply the raw
    // constructor parameter nodes here instead, so they get normalized
    // through the ordinary (structure-preserving) generic path - ast/
    // normalizer.rs's ast::normalize_class already folds this into the
    // class's scanned body - and property-shaped parameters (those with an
    // accessibility_modifier child) are then recognized by
    // syntax/typescript.rs's state_declaration_from_node.
    fn supplementary_class_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Vec<TreeSitterNode<'tree>> {
        let Some(body) = named_children(node)
            .into_iter()
            .find(|child| child.kind() == "class_body")
        else {
            return Vec::new();
        };
        let Some(constructor) = named_children(body).into_iter().find(|member| {
            member.kind() == "method_definition"
                && member.child_by_field_name("name").is_some_and(|name| {
                    name.kind() == "property_identifier"
                        && node_text(name, _source) == "constructor"
                })
        }) else {
            return Vec::new();
        };
        let Some(parameters) = constructor.child_by_field_name("parameters") else {
            return Vec::new();
        };
        named_children(parameters)
            .into_iter()
            .filter(|param| matches!(param.kind(), "required_parameter" | "optional_parameter"))
            .filter(|param| {
                named_children(*param).iter().any(|child| {
                    child.kind() == "accessibility_modifier"
                        || node_text(*child, _source) == "readonly"
                })
            })
            .collect()
    }
}

fn typescript_undefined_is_shadowed(node: TreeSitterNode<'_>, source: &str) -> bool {
    let mut ancestor = node.parent();
    while let Some(scope) = ancestor {
        if matches!(scope.kind(), "statement_block" | "program")
            && typescript_scope_declares_undefined(scope, source, true)
        {
            return true;
        }
        if matches!(
            scope.kind(),
            "function_declaration" | "method_definition" | "arrow_function" | "function_expression"
        ) && typescript_scope_declares_undefined(scope, source, false)
        {
            return true;
        }
        ancestor = scope.parent();
    }
    false
}

fn typescript_scope_declares_undefined(
    node: TreeSitterNode<'_>,
    source: &str,
    include_local_declarations: bool,
) -> bool {
    if matches!(node.kind(), "required_parameter" | "optional_parameter")
        && typescript_declares_undefined(node, source)
    {
        return true;
    }
    if include_local_declarations
        && node.kind() == "variable_declarator"
        && typescript_declares_undefined(node, source)
    {
        return true;
    }
    named_children(node).into_iter().any(|child| {
        !matches!(
            child.kind(),
            "statement_block"
                | "function_declaration"
                | "method_definition"
                | "arrow_function"
                | "function_expression"
        ) && typescript_scope_declares_undefined(child, source, include_local_declarations)
    })
}

fn typescript_declares_undefined(node: TreeSitterNode<'_>, source: &str) -> bool {
    node.child_by_field_name("name")
        .or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| child.kind() == "identifier")
        })
        .is_some_and(|name| node_text(name, source).trim() == "undefined")
}

/// TypeScript represents `const f = (...) => ...` and
/// `const f = function (...) { ... }` as anonymous callable expressions. The
/// binding identifier is nevertheless a compiler-owned project declaration,
/// so expose only that thin grammar fact and let the shared method/profile
/// pipeline analyze its body normally.
fn typescript_bound_callable_name(node: TreeSitterNode<'_>, source: &str) -> Option<String> {
    if !matches!(node.kind(), "arrow_function" | "function_expression") {
        return None;
    }
    if let Some(name) = node.child_by_field_name("name") {
        let text = node_text(name, source).trim();
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    let parent = node.parent()?;
    if parent.kind() != "variable_declarator" || parent.child_by_field_name("value") != Some(node) {
        return None;
    }
    let name = parent.child_by_field_name("name")?;
    let text = node_text(name, source).trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    #[test]
    fn variable_declarators_map_assignment_fields_without_hiding_other_fields() {
        let source = "const value: string | null = null;";
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into())
            .unwrap();
        let tree = parser.parse(source, None).unwrap();
        let mut nodes = vec![tree.root_node()];
        let declarator = loop {
            let node = nodes.pop().unwrap();
            if node.kind() == "variable_declarator" {
                break node;
            }
            nodes.extend((0..node.child_count()).filter_map(|index| node.child(index)));
        };

        let adapter = TypeScriptAstAdapter;
        assert_eq!(
            node_text(adapter.named_field(declarator, "left").unwrap(), source),
            "value"
        );
        assert_eq!(
            node_text(adapter.named_field(declarator, "right").unwrap(), source),
            "null"
        );
        assert!(adapter.named_field(declarator, "missing").is_none());
    }
}
