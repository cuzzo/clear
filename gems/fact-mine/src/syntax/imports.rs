use crate::syntax::Language;
use tree_sitter::Node;

/// A first-class import/include/require fact.
///
/// `kind` is `symbol` for module-system imports whose targets are symbol
/// namespaces (Python/Java/Go/C# - sourced from the adapter symbol scope),
/// `file` for path-based requires (JS/TS `import`/`require`, Ruby
/// `require_relative`/`require`), and `include` for C/C++ `#include "..."`.
#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ImportFact {
    pub alias: String,
    pub target: String,
    pub kind: String,
    pub line: u32,
}

pub(crate) fn extract_file_imports(root: Node, source: &str, language: Language) -> Vec<ImportFact> {
    let mut imports = Vec::new();
    match language {
        Language::JavaScript | Language::TypeScript => {
            walk(root, &mut |node| match node.kind() {
                "import_statement" | "export_statement" => {
                    // Only the module-source string names an import; other
                    // string literals in export statements are values.
                    if let Some(source_node) = node.child_by_field_name("source") {
                        let target = text(source_node, source);
                        let target = target.trim_matches(|c| c == '"' || c == '\'' || c == '`');
                        push(&mut imports, node, "", target, "file");
                    }
                }
                "call_expression" => {
                    let callee = node
                        .child_by_field_name("function")
                        .map(|f| text(f, source))
                        .unwrap_or_default();
                    if callee == "require" || callee == "import" {
                        if let Some(target) = first_string_literal(node, source) {
                            push(&mut imports, node, "", &target, "file");
                        }
                    }
                }
                _ => {}
            });
        }
        Language::Ruby => {
            walk(root, &mut |node| {
                if node.kind() != "call" {
                    return;
                }
                let method = node
                    .child_by_field_name("method")
                    .map(|m| text(m, source))
                    .unwrap_or_default();
                if method == "require" || method == "require_relative" {
                    if let Some(target) = first_string_literal(node, source) {
                        push(&mut imports, node, &method, &target, "file");
                    }
                }
            });
        }
        Language::Lua => {
            walk(root, &mut |node| {
                if node.kind() != "function_call" {
                    return;
                }
                let callee = node
                    .child_by_field_name("name")
                    .map(|f| text(f, source))
                    .unwrap_or_default();
                if callee == "require" {
                    if let Some(target) = first_string_literal(node, source) {
                        push(&mut imports, node, "", &target, "file");
                    }
                }
            });
        }
        Language::C | Language::Cpp => {
            walk(root, &mut |node| {
                if node.kind() != "preproc_include" {
                    return;
                }
                if let Some(path_node) = node.child_by_field_name("path") {
                    let raw = text(path_node, source);
                    // Only quoted includes name project files; <...> is system.
                    if raw.starts_with('"') {
                        let target = raw.trim_matches('"').to_string();
                        push(&mut imports, node, "", &target, "include");
                    }
                }
            });
        }
        _ => {}
    }
    imports.sort_by(|a, b| (a.line, &a.target).cmp(&(b.line, &b.target)));
    imports.dedup();
    imports
}

pub(crate) fn symbol_imports(explicit_imports: &[(String, String)], _language: Language) -> Vec<ImportFact> {
    explicit_imports
        .iter()
        .map(|(alias, target)| ImportFact {
            alias: alias.clone(),
            target: target.clone(),
            kind: "symbol".to_string(),
            line: 0,
        })
        .collect()
}

fn push(imports: &mut Vec<ImportFact>, node: Node, alias: &str, target: &str, kind: &str) {
    if target.is_empty() {
        return;
    }
    imports.push(ImportFact {
        alias: alias.to_string(),
        target: target.to_string(),
        kind: kind.to_string(),
        line: (node.start_position().row + 1) as u32,
    });
}

fn text(node: Node, source: &str) -> String {
    source
        .get(node.byte_range())
        .unwrap_or_default()
        .to_string()
}

fn first_string_literal(node: Node, source: &str) -> Option<String> {
    let mut found = None;
    walk(node, &mut |candidate| {
        if found.is_some() {
            return;
        }
        if matches!(candidate.kind(), "string" | "string_literal") {
            let raw = text(candidate, source);
            let trimmed = raw.trim_matches(|c| c == '"' || c == '\'' || c == '`');
            if !trimmed.is_empty() {
                found = Some(trimmed.to_string());
            }
        }
    });
    found
}

fn walk<'tree>(node: Node<'tree>, visit: &mut dyn FnMut(Node<'tree>)) {
    visit(node);
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        walk(child, visit);
    }
}
