use super::StateWrite;
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use tree_sitter::{Language, Node, Parser};

pub fn state_writes_for_file(file: &Path) -> Result<Vec<StateWrite>> {
    let source = fs::read_to_string(file)
        .with_context(|| format!("failed to read {}", file.display()))?;
    let mut parser = Parser::new();
    parser
        .set_language(&ruby_language())
        .with_context(|| "failed to initialize tree-sitter ruby parser")?;
    let tree = parser
        .parse(&source, None)
        .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;

    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let context = ContextState::new(file_owner(file));
    walk(tree.root_node(), &source, file, &context, &mut out, &mut seen);
    Ok(out)
}

fn ruby_language() -> Language {
    tree_sitter_ruby::LANGUAGE.into()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ContextState {
    file_owner: String,
    owner: Option<String>,
    function: Option<String>,
}

impl ContextState {
    fn new(file_owner: String) -> Self {
        Self {
            file_owner,
            owner: None,
            function: None,
        }
    }

    fn current_owner(&self) -> String {
        self.owner
            .clone()
            .unwrap_or_else(|| self.file_owner.clone())
    }

    fn current_function(&self) -> String {
        self.function
            .clone()
            .unwrap_or_else(|| "(top-level)".to_string())
    }
}

fn walk(
    node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<StateWrite>,
    seen: &mut HashSet<String>,
) {
    let next_context = push_function_context(node, push_owner_context(node, source, context), source);
    record_state_write(node, source, file, &next_context, out, seen);

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk(child, source, file, &next_context, out, seen);
    }
}

fn push_owner_context(node: Node<'_>, source: &str, context: &ContextState) -> ContextState {
    let Some(owner) = owner_name_from_declaration(node, source) else {
        return context.clone();
    };
    let parent_owner = context.owner.clone();
    let full_owner = if let Some(parent) = parent_owner {
        if parent != owner && !owner.contains("::") {
            format!("{parent}::{owner}")
        } else {
            owner
        }
    } else {
        owner
    };
    let mut next = context.clone();
    next.owner = Some(full_owner);
    next
}

fn push_function_context(node: Node<'_>, mut context: ContextState, source: &str) -> ContextState {
    let Some(function) = function_name(node, source) else {
        return context;
    };
    let owner = context.current_owner();
    context.function = Some(function);
    context.owner = Some(owner);
    context
}

fn record_state_write(
    node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<StateWrite>,
    seen: &mut HashSet<String>,
) {
    if node.kind() == "operator_assignment" {
        return;
    }

    let Some(assignment) = assignment_target(node) else {
        return;
    };
    let Some(target) = state_target(assignment.lhs, source) else {
        return;
    };
    if target.field == "[]" || target.field.starts_with('$') {
        return;
    }

    let file_name = file.to_string_lossy().to_string();
    let owner = context.current_owner();
    let function = context.current_function();
    let line = line(assignment.source);
    let key = format!(
        "{}\0{}\0{}\0{}\0{}\0{}",
        file_name, owner, function, line, target.receiver, target.field
    );
    if !seen.insert(key) {
        return;
    }

    out.push(StateWrite {
        field: target.field,
        receiver: target.receiver,
        file: file_name,
        function,
        line,
        span: span(assignment.source),
        owner,
    });
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AssignmentTarget<'tree> {
    lhs: Node<'tree>,
    source: Node<'tree>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Target {
    receiver: String,
    field: String,
}

fn assignment_target(node: Node<'_>) -> Option<AssignmentTarget<'_>> {
    match node.kind() {
        "assignment" | "assignment_expression" | "assignment_statement" => {
            let lhs = node
                .child_by_field_name("left")
                .or_else(|| first_named_child(node))?;
            Some(AssignmentTarget { lhs, source: node })
        }
        "instance_variable" | "global_variable" if assignment_lhs_node(node) => {
            Some(AssignmentTarget {
                lhs: node,
                source: node.parent().unwrap_or(node),
            })
        }
        _ => None,
    }
}

fn assignment_lhs_node(node: Node<'_>) -> bool {
    if previous_sibling_raw_text(node).as_deref() == Some(":") {
        return false;
    }
    matches!(
        next_sibling_raw_text(node).as_deref(),
        Some("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=")
    )
}

fn state_target(lhs: Node<'_>, source: &str) -> Option<Target> {
    if previous_sibling_text(lhs, source).as_deref() == Some(":") {
        return None;
    }

    match lhs.kind() {
        "call" => {
            let receiver = lhs.child_by_field_name("receiver")?;
            let method = lhs.child_by_field_name("method")?;
            Some(Target {
                receiver: normalize_text(node_text(receiver, source)),
                field: strip_assignment_suffix(node_text(method, source)),
            })
        }
        "field"
        | "field_access"
        | "selector_expression"
        | "member_expression"
        | "member_access_expression"
        | "attribute"
        | "field_expression"
        | "navigation_expression"
        | "directly_assignable_expression"
        | "expression_list" => {
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
                .or_else(|| last_named_child(lhs))?;
            let field_text = member_field_text(field, source)?;
            Some(Target {
                receiver: normalize_text(node_text(object, source)),
                field: strip_assignment_suffix(&field_text),
            })
        }
        "instance_variable" | "global_variable" => Some(Target {
            receiver: "self".to_string(),
            field: node_text(lhs, source).to_string(),
        }),
        _ => None,
    }
}

fn function_name(node: Node<'_>, source: &str) -> Option<String> {
    match node.kind() {
        "method" => node
            .child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| first_named_text(node, source, &["identifier", "constant", "property_identifier"])),
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
        "body_statement" if first_child_kind(node) == Some("def") => hidden_ruby_method_name(node, source),
        "argument_list" if first_child_kind(node) == Some("def") => inline_def_name(node, source),
        _ => None,
    }
}

fn owner_name_from_declaration(node: Node<'_>, source: &str) -> Option<String> {
    if node.kind() == "body_statement" && matches!(first_child_kind(node), Some("class" | "module")) {
        return first_named_text(node, source, &["constant", "identifier", "type_identifier"]);
    }

    match node.kind() {
        "class" | "module" => node
            .child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| first_named_text(node, source, &["constant", "identifier", "type_identifier"])),
        _ => None,
    }
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
        .find(|child| matches!(child.kind(), "identifier" | "field_identifier" | "property_identifier"))
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

fn file_owner(file: &Path) -> String {
    file.file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("(file)")
        .to_string()
}

fn first_named_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    named_children(node)
        .into_iter()
        .find(|child| kinds.iter().any(|kind| *kind == child.kind()))
        .map(|child| node_text(child, source).to_string())
}

fn first_named_child(node: Node<'_>) -> Option<Node<'_>> {
    let mut cursor = node.walk();
    let child = node.named_children(&mut cursor).next();
    child
}

fn last_named_child(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node).into_iter().last()
}

fn first_named_child_except<'tree>(node: Node<'tree>, excluded_kind: &str) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() != excluded_kind)
}

fn first_named_child_with_kind<'tree>(node: Node<'tree>, kind: &str) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() == kind)
}

fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

fn first_child_kind(node: Node<'_>) -> Option<&str> {
    let mut cursor = node.walk();
    let kind = node.children(&mut cursor).next().map(|child| child.kind());
    kind
}

fn previous_sibling_text(node: Node<'_>, source: &str) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| node_text(sibling, source).to_string())
}

fn previous_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| sibling.kind().to_string())
}

fn next_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.next_sibling().map(|sibling| sibling.kind().to_string())
}

fn member_field_text(field: Node<'_>, source: &str) -> Option<String> {
    if field.kind() == "navigation_suffix" {
        let suffix = field
            .child_by_field_name("suffix")
            .or_else(|| {
                named_children(field)
                    .into_iter()
                    .find(|child| matches!(child.kind(), "identifier" | "simple_identifier" | "field_identifier" | "property_identifier"))
            })
            .or_else(|| last_named_child(field))?;
        let text = node_text(suffix, source).trim_start_matches(['.', '?']);
        return (!text.is_empty()).then(|| text.to_string());
    }

    Some(node_text(field, source).trim_start_matches(['.', '?']).to_string())
}

fn strip_assignment_suffix(text: &str) -> String {
    text.strip_suffix('=').unwrap_or(text).to_string()
}

fn node_text<'a>(node: Node<'_>, source: &'a str) -> &'a str {
    node.utf8_text(source.as_bytes()).unwrap_or("")
}

fn normalize_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn span(node: Node<'_>) -> [usize; 4] {
    let start = node.start_position();
    let end = node.end_position();
    [start.row + 1, start.column, end.row + 1, end.column]
}

fn line(node: Node<'_>) -> usize {
    node.start_position().row + 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn extract(source: &str) -> Vec<StateWrite> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        state_writes_for_file(file.path()).expect("state writes")
    }

    #[test]
    fn extracts_ruby_attribute_and_instance_writes() {
        let writes = extract(
            r#"
class Box
  def a(n)
    n.storage = :heap
    n.provenance = :heap
    @field = 1
    @counter += 1
    n.count += 1
    e[:kind] = 1
  end
  def self.b(x); x.value = 1; end
end
"#,
        );

        let summary: Vec<(&str, &str, &str, &str)> = writes
            .iter()
            .map(|write| {
                (
                    write.owner.as_str(),
                    write.function.as_str(),
                    write.receiver.as_str(),
                    write.field.as_str(),
                )
            })
            .collect();

        assert_eq!(
            summary,
            vec![
                ("Box", "a", "n", "storage"),
                ("Box", "a", "n", "provenance"),
                ("Box", "a", "self", "@field"),
                ("Box", "a", "self", "@counter"),
                ("Box", "self.b", "x", "value"),
            ]
        );
    }

    #[test]
    fn extracts_nested_owner_names() {
        let writes = extract(
            r#"
module Outer
  class Inner
    def set(node)
      node.state = :ready
    end
  end
end
"#,
        );

        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].owner, "Outer::Inner");
        assert_eq!(writes[0].function, "set");
        assert_eq!(writes[0].field, "state");
    }
}
