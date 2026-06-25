use super::super::{named_children, node_text};
use super::base::{AstNormalizationAdapter, COMMON_ASSIGNMENT_OPERATORS};
use tree_sitter::Node as TreeSitterNode;

pub(crate) struct PhpAstAdapter;

impl AstNormalizationAdapter for PhpAstAdapter {
    fn local_identifier_text(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if !matches!(node.kind(), "name" | "qualified_name" | "variable_name") {
            return None;
        }
        let text = php_identifier_text(node_text(node, source));
        if matches!(node.kind(), "name" | "qualified_name") && php_constant_identifier(&text) {
            return None;
        }
        (!text.is_empty()).then_some(text)
    }

    fn constant_identifier_text(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if !matches!(node.kind(), "name" | "qualified_name") {
            return None;
        }
        let text = php_identifier_text(node_text(node, source));
        php_constant_identifier(&text).then_some(text)
    }

    fn self_identifier(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "variable_name" && php_identifier_text(node_text(node, source)) == "this"
    }

    fn call_node(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        matches!(
            node.kind(),
            "function_call_expression"
                | "member_call_expression"
                | "scoped_call_expression"
                | "print_intrinsic"
        )
    }

    fn intrinsic_call_name(&self, node: TreeSitterNode<'_>, _source: &str) -> Option<&'static str> {
        (node.kind() == "print_intrinsic").then_some("print")
    }

    fn call_argument_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _function: Option<TreeSitterNode<'tree>>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() != "print_intrinsic" {
            return None;
        }
        let args = named_children(node)
            .into_iter()
            .filter(|child| child.kind() != "print")
            .collect::<Vec<_>>();
        (!args.is_empty()).then_some(args)
    }

    fn loop_node_type(&self, kind: &str) -> Option<&'static str> {
        (kind == "foreach_statement").then_some("FOR")
    }

    fn member_access_operator(&self, text: &str) -> bool {
        matches!(text, "." | "&." | "->" | "::")
    }

    fn source_text(&self, text: &str) -> String {
        php_normalize_source(text)
    }

    fn state_field_name(&self, node: TreeSitterNode<'_>, source: &str) -> Option<String> {
        if node.kind() != "member_access_expression" {
            return None;
        }
        let receiver = php_member_receiver(node)?;
        if !matches!(
            php_identifier_text(node_text(receiver, source)).as_str(),
            "this" | "self"
        ) {
            return None;
        }
        let field = php_member_name(node)?;
        let field = php_identifier_text(node_text(field, source));
        (!field.is_empty()).then_some(field)
    }

    fn class_node(&self, node: TreeSitterNode<'_>) -> bool {
        node.kind() == "class_declaration"
    }

    fn member_assignment_target(&self, node: TreeSitterNode<'_>, _source: &str) -> bool {
        node.kind() == "member_access_expression"
    }

    fn member_read_excluded(&self, node: TreeSitterNode<'_>) -> bool {
        node.parent()
            .map(|parent| {
                matches!(
                    parent.kind(),
                    "member_call_expression" | "scoped_call_expression"
                )
            })
            .unwrap_or(false)
    }

    fn named_children_action<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
        children: &[TreeSitterNode<'tree>],
    ) -> super::base::NamedChildrenAction<'tree> {
        if matches!(node.kind(), "compound_statement" | "declaration_list")
            && children.len() == 1
            && node_text(node, source) == node_text(children[0], source)
        {
            return super::base::NamedChildrenAction::Recurse(children[0]);
        }

        super::base::NamedChildrenAction::Default
    }

    fn case_arm_body_nodes<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        _source: &str,
    ) -> Option<Vec<TreeSitterNode<'tree>>> {
        if node.kind() == "default_statement" {
            let body = php_named_children(node)
                .into_iter()
                .filter(|child| child.kind() != "break_statement")
                .collect::<Vec<_>>();
            return (!body.is_empty()).then_some(body);
        }
        if node.kind() != "case_statement" {
            return None;
        }
        let mut children = php_named_children(node).into_iter();
        children.next()?;
        let mut body = Vec::new();
        for child in children {
            if child.kind() == "case_statement" {
                break;
            }
            body.push(child);
        }
        Some(body)
    }

    fn case_else_node<'tree>(
        &self,
        node: TreeSitterNode<'tree>,
        source: &str,
    ) -> Option<TreeSitterNode<'tree>> {
        let mut stack = php_named_children(node);
        while let Some(child) = stack.pop() {
            if self.case_else_arm(child, source) {
                return Some(child);
            }
            stack.extend(php_named_children(child));
        }
        None
    }

    fn case_else_arm(&self, node: TreeSitterNode<'_>, source: &str) -> bool {
        node.kind() == "default_statement"
            || (node.kind() == "case_statement"
                && node_text(node, source).trim_start().starts_with("default"))
    }

    fn assignment_operators(&self) -> &'static [&'static str] {
        COMMON_ASSIGNMENT_OPERATORS
    }
}

fn php_named_children<'tree>(node: TreeSitterNode<'tree>) -> Vec<TreeSitterNode<'tree>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

fn php_member_receiver<'tree>(node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
    node.child_by_field_name("object")
        .or_else(|| node.child_by_field_name("receiver"))
        .or_else(|| node.child_by_field_name("expression"))
        .or_else(|| php_named_children(node).into_iter().next())
}

fn php_member_name<'tree>(node: TreeSitterNode<'tree>) -> Option<TreeSitterNode<'tree>> {
    node.child_by_field_name("name")
        .or_else(|| node.child_by_field_name("field"))
        .or_else(|| php_named_children(node).into_iter().rev().next())
}

fn php_identifier_text(text: &str) -> String {
    text.trim().trim_start_matches('$').to_string()
}

fn php_constant_identifier(text: &str) -> bool {
    text.chars()
        .next()
        .map(|ch| ch == '_' || ch.is_ascii_uppercase())
        .unwrap_or(false)
}

fn php_normalize_source(source: &str) -> String {
    let mut out = String::new();
    let mut chars = source.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '$'
            && chars
                .peek()
                .map(|next| *next == '_' || next.is_ascii_alphabetic())
                .unwrap_or(false)
        {
            continue;
        }
        out.push(ch);
    }
    out.replace("->", ".").replace("::", ".")
}
