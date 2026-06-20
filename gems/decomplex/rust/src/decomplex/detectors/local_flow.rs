use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{self, Document, FunctionDef, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct LocalFlowRow {
    pub summaries: Vec<MethodSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MethodSummary {
    pub id: String,
    pub owner: String,
    pub name: String,
    pub file: String,
    pub line: usize,
    pub span: Span,
    #[serde(skip_serializing)]
    pub node: Node,
    pub statements: Vec<Statement>,
    pub boundaries: Vec<Boundary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Statement {
    pub index: usize,
    pub line: usize,
    pub end_line: usize,
    pub span: Span,
    pub source: String,
    pub reads: BTreeSet<String>,
    pub writes: BTreeSet<String>,
    pub dependencies: Vec<(String, String)>,
    pub co_uses: Vec<(String, String)>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Boundary {
    pub before_index: usize,
    pub after_index: usize,
    pub line: usize,
    pub kind: String,
    pub text: String,
}

const OWNER_TYPES: &[&str] = &["CLASS", "MODULE"];
const METHOD_TYPES: &[&str] = &["DEFN", "DEFS"];
const SKIP_NESTED_TYPES: &[&str] = &["CLASS", "MODULE", "DEFN", "DEFS", "LAMBDA"];
const LOCAL_READ_TYPES: &[&str] = &["LVAR", "DVAR"];
const LOCAL_WRITE_TYPES: &[&str] = &["LASGN", "DASGN"];
const STATEMENT_CONTAINER_TYPES: &[&str] = &[
    "BLOCK",
    "COMPOUND_STATEMENT",
    "DECLARATION_LIST",
    "FUNCTION_BODY",
    "HASH",
    "STATEMENTS",
];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<MethodSummary>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<MethodSummary> {
    let mut out = Vec::new();
    for document in documents {
        let mut detector = LocalFlow::new(
            document.file.clone(),
            document.lines.clone(),
            document.language,
            method_metadata(document),
        );
        out.extend(detector.scan(&document.normalized_root));
    }
    out
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MethodMetadata {
    owner: String,
    name: String,
    params: BTreeSet<String>,
}

struct LocalFlow {
    file: String,
    lines: Vec<String>,
    language: Language,
    methods_by_span: BTreeMap<Span, MethodMetadata>,
}

impl LocalFlow {
    fn new(
        file: String,
        lines: Vec<String>,
        language: Language,
        methods_by_span: BTreeMap<Span, MethodMetadata>,
    ) -> Self {
        Self {
            file,
            lines,
            language,
            methods_by_span,
        }
    }

    fn scan(&mut self, root: &Node) -> Vec<MethodSummary> {
        let mut out = Vec::new();
        self.collect_methods(root, &Vec::new(), &mut out);
        out
    }

    fn collect_methods(&self, node: &Node, owners: &[String], out: &mut Vec<MethodSummary>) {
        if OWNER_TYPES.contains(&node.r#type.as_str()) {
            let owner = self.full_owner_name(owners, node);
            for method in self.owner_methods(node) {
                out.push(self.method_summary(method, Some(&owner)));
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            self.collect_nested_owners(node, &next_owners, out);
        } else if METHOD_TYPES.contains(&node.r#type.as_str()) && owners.is_empty() {
            out.push(self.method_summary(node, None));
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.collect_methods(child, owners, out);
            }
        }
    }

    fn collect_nested_owners(&self, node: &Node, owners: &[String], out: &mut Vec<MethodSummary>) {
        if METHOD_TYPES.contains(&node.r#type.as_str()) {
            return;
        }

        for child in node.children.iter().filter_map(ast::node) {
            if OWNER_TYPES.contains(&child.r#type.as_str()) {
                self.collect_methods(child, owners, out);
            } else {
                self.collect_nested_owners(child, owners, out);
            }
        }
    }

    fn method_summary(&self, node: &Node, owner_hint: Option<&str>) -> MethodSummary {
        let node_span = [
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ];
        let metadata = self.methods_by_span.get(&node_span);
        let owner = metadata
            .map(|item| item.owner.as_str())
            .or(owner_hint)
            .unwrap_or("(top-level)");
        let name = metadata
            .map(|item| item.name.clone())
            .unwrap_or_else(|| self.method_name(node));
        let statement_nodes = ast::body_stmts(node)
            .into_iter()
            .filter(|statement| !comment_statement(statement))
            .collect::<Vec<_>>();
        let local_names = self.local_names(&statement_nodes, metadata);
        let statements: Vec<_> = statement_nodes
            .iter()
            .enumerate()
            .map(|(index, stmt)| self.statement_summary(stmt, index, &local_names))
            .collect();
        MethodSummary {
            id: format!("{}#{}", owner, name),
            owner: owner.to_string(),
            name,
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            node: node.clone(),
            boundaries: self.structural_boundaries(&statements),
            statements,
        }
    }

    fn statement_summary(
        &self,
        node: &Node,
        index: usize,
        local_names: &BTreeSet<String>,
    ) -> Statement {
        let source = ast::slice(node, &self.lines);
        let writes = self.local_writes(node);
        let reads = self.local_reads(node, local_names, &writes);
        Statement {
            index,
            line: node.first_lineno,
            end_line: node.last_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            source,
            dependencies: self.assignment_dependencies(node, local_names),
            co_uses: self.co_use_edges(node, local_names),
            reads,
            writes,
        }
    }

    fn local_names(
        &self,
        statements: &[&Node],
        metadata: Option<&MethodMetadata>,
    ) -> BTreeSet<String> {
        let mut names = metadata.map(|item| item.params.clone()).unwrap_or_default();
        for statement in statements {
            names.extend(self.local_writes(statement));
        }
        names
    }

    fn structural_boundaries(&self, statements: &[Statement]) -> Vec<Boundary> {
        let mut out = Vec::new();
        for i in 0..statements.len().saturating_sub(1) {
            let left = &statements[i];
            let right = &statements[i + 1];
            if let Some(boundary) = self.source_boundary(left.end_line + 1, right.line - 1) {
                out.push(Boundary {
                    before_index: left.index,
                    after_index: right.index,
                    line: boundary.line,
                    kind: boundary.kind,
                    text: boundary.text,
                });
            }
        }
        out
    }

    fn source_boundary(&self, first_line: usize, last_line: usize) -> Option<RawBoundary> {
        if first_line > last_line {
            return None;
        }

        let mut blank = None;
        for line_number in first_line..=last_line {
            let text = self
                .lines
                .get(line_number - 1)
                .map(|s| s.as_str())
                .unwrap_or("");
            let stripped = text.trim();
            if stripped.starts_with('#') || stripped.starts_with("//") || stripped.starts_with("--")
            {
                return Some(RawBoundary {
                    line: line_number,
                    kind: "comment".to_string(),
                    text: stripped.to_string(),
                });
            }
            if stripped.is_empty() && blank.is_none() {
                blank = Some(RawBoundary {
                    line: line_number,
                    kind: "blank".to_string(),
                    text: stripped.to_string(),
                });
            }
        }
        blank
    }

    fn owner_methods<'a>(&self, owner_node: &'a Node) -> Vec<&'a Node> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };

        let stmts = if statement_container(body) {
            body.children
                .iter()
                .filter_map(ast::node)
                .collect::<Vec<_>>()
        } else {
            vec![body]
        };

        stmts
            .into_iter()
            .flat_map(|stmt| {
                if METHOD_TYPES.contains(&stmt.r#type.as_str()) {
                    vec![stmt]
                } else if self.visibility_call(stmt) {
                    self.inline_methods(stmt)
                } else {
                    vec![]
                }
            })
            .collect()
    }

    fn inline_methods<'a>(&self, stmt: &'a Node) -> Vec<&'a Node> {
        let Some(args) = stmt.children.get(1).and_then(ast::node) else {
            return Vec::new();
        };
        args.children
            .iter()
            .filter_map(ast::node)
            .filter(|arg| METHOD_TYPES.contains(&arg.r#type.as_str()))
            .collect()
    }

    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
        if scope.r#type != "SCOPE" {
            return None;
        }
        scope.children.get(2).and_then(ast::node)
    }

    fn visibility_call(&self, node: &Node) -> bool {
        if node.r#type == "FCALL" {
            if let Some(Child::Symbol(name)) = node.children.first() {
                return matches!(name.as_str(), "public" | "protected" | "private");
            }
        }
        false
    }

    fn method_name(&self, node: &Node) -> String {
        if node.r#type == "DEFS" {
            let receiver = node.children.get(0).and_then(ast::node);
            let prefix = if let Some(r) = receiver {
                if r.r#type == "SELF" {
                    "self".to_string()
                } else {
                    ast::slice(r, &self.lines)
                }
            } else {
                "?".to_string()
            };
            format!(
                "{}.{}",
                prefix,
                node.children
                    .get(1)
                    .and_then(|c| match c {
                        Child::Symbol(s) => Some(s),
                        _ => None,
                    })
                    .unwrap_or(&"?".to_string())
            )
        } else {
            node.children
                .first()
                .and_then(|c| match c {
                    Child::Symbol(s) => Some(s.clone()),
                    _ => None,
                })
                .unwrap_or_else(|| "?".to_string())
        }
    }

    fn full_owner_name(&self, owners: &[String], node: &Node) -> String {
        let mut next = owners.to_vec();
        next.push(self.owner_segment(node));
        next.join("::")
    }

    fn owner_segment(&self, node: &Node) -> String {
        let text = ast::slice(
            node.children.first().and_then(ast::node).unwrap_or(node),
            &self.lines,
        );
        if text.is_empty() {
            "(anonymous)".to_string()
        } else {
            text
        }
    }

    fn local_reads(
        &self,
        node: &Node,
        local_names: &BTreeSet<String>,
        writes: &BTreeSet<String>,
    ) -> BTreeSet<String> {
        let mut reads = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_READ_TYPES.contains(&child.r#type.as_str()) {
                if let Some(name) = local_read_name(child) {
                    if local_names.contains(&name) {
                        reads.push(name);
                    }
                }
            }
        });
        reads.extend(textual_local_reads(
            &ast::slice(node, &self.lines),
            local_names,
            writes,
        ));
        reads.into_iter().collect()
    }

    fn local_writes(&self, node: &Node) -> BTreeSet<String> {
        let mut writes = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_WRITE_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(name)) = child.children.first() {
                    writes.push(name.clone());
                }
            }
        });
        writes.extend(textual_local_writes(&ast::slice(node, &self.lines)));
        writes.into_iter().collect()
    }

    fn assignment_dependencies(
        &self,
        node: &Node,
        local_names: &BTreeSet<String>,
    ) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_WRITE_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(lhs)) = child.children.first() {
                    if let Some(rhs) = child.children.get(1).and_then(ast::node) {
                        let rhs_writes = BTreeSet::new();
                        for read in self.local_reads(rhs, local_names, &rhs_writes) {
                            if lhs != &read {
                                deps.push((lhs.clone(), read));
                            }
                        }
                    }
                }
            }
        });
        let lhs_names = self.local_writes(node);
        if !lhs_names.is_empty() {
            let reads = self.local_reads(node, local_names, &lhs_names);
            for lhs in lhs_names {
                for read in &reads {
                    if &lhs != read {
                        deps.push((lhs.clone(), read.clone()));
                    }
                }
            }
        }
        deps.sort();
        deps.dedup();
        deps
    }

    fn co_use_edges(&self, node: &Node, local_names: &BTreeSet<String>) -> Vec<(String, String)> {
        let writes = self.local_writes(node);
        let reads: Vec<_> = self
            .local_reads(node, local_names, &writes)
            .into_iter()
            .collect();
        let mut out = Vec::new();
        for i in 0..reads.len() {
            for j in i + 1..reads.len() {
                out.push((reads[i].clone(), reads[j].clone()));
            }
        }
        out
    }

    fn walk_local(&self, node: &Node, blk: &mut dyn FnMut(&Node)) {
        if SKIP_NESTED_TYPES.contains(&node.r#type.as_str()) {
            return;
        }
        blk(node);
        for child in node.children.iter().filter_map(ast::node) {
            self.walk_local(child, blk);
        }
    }
}

fn local_read_name(node: &Node) -> Option<String> {
    match node.children.first() {
        Some(Child::String(name)) | Some(Child::Symbol(name)) => Some(name.clone()),
        Some(Child::Nil) => Some(String::new()),
        _ => None,
    }
}

fn textual_local_writes(source: &str) -> Vec<String> {
    let Some((lhs, operator)) = split_assignment(source) else {
        return Vec::new();
    };
    if lhs.contains('.') || lhs.contains("->") || lhs.contains('[') {
        return Vec::new();
    }

    let identifiers = identifiers_with_positions(lhs)
        .into_iter()
        .map(|identifier| identifier.name)
        .filter(|name| !local_keyword(name))
        .collect::<Vec<_>>();
    if identifiers.is_empty() {
        return Vec::new();
    }

    if operator == ":=" || declaration_like_lhs(lhs) || identifiers.len() == 1 {
        return identifiers
            .into_iter()
            .filter(|name| simple_identifier(name))
            .collect();
    }

    Vec::new()
}

fn textual_local_reads(
    source: &str,
    local_names: &BTreeSet<String>,
    writes: &BTreeSet<String>,
) -> Vec<String> {
    identifiers_with_positions(source)
        .into_iter()
        .filter(|identifier| local_names.contains(&identifier.name))
        .filter(|identifier| !writes.contains(&identifier.name))
        .filter(|identifier| !local_keyword(&identifier.name))
        .filter(|identifier| !member_name(source, identifier.start))
        .filter(|identifier| !call_name(source, identifier.end))
        .map(|identifier| identifier.name)
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct IdentifierSpan {
    name: String,
    start: usize,
    end: usize,
}

fn identifiers_with_positions(source: &str) -> Vec<IdentifierSpan> {
    let bytes = source.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        let start = if bytes[index] == b'$' {
            let next = index + 1;
            if next < bytes.len() && identifier_start(bytes[next]) {
                next
            } else {
                index += 1;
                continue;
            }
        } else if identifier_start(bytes[index]) {
            index
        } else {
            index += 1;
            continue;
        };
        let mut end = start + 1;
        while end < bytes.len() && identifier_part(bytes[end]) {
            end += 1;
        }
        out.push(IdentifierSpan {
            name: source[start..end].to_string(),
            start,
            end,
        });
        index = end;
    }
    out
}

fn identifier_start(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphabetic()
}

fn identifier_part(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphanumeric()
}

fn split_assignment(source: &str) -> Option<(&str, &str)> {
    let bytes = source.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if index + 1 < bytes.len() && &source[index..index + 2] == ":=" {
            return Some((source[..index].trim(), ":="));
        }
        if bytes[index] == b'=' {
            let previous = index.checked_sub(1).and_then(|i| bytes.get(i)).copied();
            let next = bytes.get(index + 1).copied();
            if !matches!(
                previous,
                Some(
                    b'=' | b'!'
                        | b'<'
                        | b'>'
                        | b':'
                        | b'+'
                        | b'-'
                        | b'*'
                        | b'/'
                        | b'%'
                        | b'&'
                        | b'|'
                )
            ) && !matches!(next, Some(b'=' | b'>'))
            {
                return Some((source[..index].trim(), "="));
            }
        }
        index += 1;
    }
    None
}

fn declaration_like_lhs(lhs: &str) -> bool {
    identifiers_with_positions(lhs)
        .first()
        .map(|identifier| {
            matches!(
                identifier.name.as_str(),
                "let"
                    | "const"
                    | "var"
                    | "val"
                    | "auto"
                    | "int"
                    | "long"
                    | "float"
                    | "double"
                    | "bool"
                    | "boolean"
                    | "char"
                    | "String"
                    | "string"
            )
        })
        .unwrap_or(false)
}

fn local_keyword(name: &str) -> bool {
    matches!(
        name,
        "as" | "break"
            | "auto"
            | "boolean"
            | "bool"
            | "case"
            | "char"
            | "class"
            | "const"
            | "continue"
            | "default"
            | "double"
            | "else"
            | "false"
            | "float"
            | "for"
            | "func"
            | "fun"
            | "function"
            | "if"
            | "in"
            | "int"
            | "long"
            | "let"
            | "mut"
            | "nil"
            | "None"
            | "null"
            | "private"
            | "protected"
            | "public"
            | "return"
            | "self"
            | "short"
            | "static"
            | "String"
            | "string"
            | "this"
            | "true"
            | "val"
            | "var"
            | "void"
            | "while"
    )
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn member_name(source: &str, start: usize) -> bool {
    let prefix = source[..start].trim_end();
    prefix.ends_with('.') || prefix.ends_with("->") || prefix.ends_with("::")
}

fn call_name(source: &str, end: usize) -> bool {
    let suffix = source[end..].trim_start();
    suffix.starts_with('(')
}

fn method_metadata(document: &Document) -> BTreeMap<Span, MethodMetadata> {
    document
        .function_defs
        .iter()
        .map(|function| (function.span, metadata_for_function(document, function)))
        .collect()
}

fn metadata_for_function(document: &Document, function: &FunctionDef) -> MethodMetadata {
    let owner = if function.owner == file_owner(&document.file) {
        "(top-level)".to_string()
    } else {
        function.owner.clone()
    };
    MethodMetadata {
        owner,
        name: function.name.clone(),
        params: function.params.iter().cloned().collect(),
    }
}

fn file_owner(file: &str) -> String {
    Path::new(file)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("(file)")
        .to_string()
}

fn statement_container(node: &Node) -> bool {
    STATEMENT_CONTAINER_TYPES.contains(&node.r#type.as_str())
}

fn comment_statement(node: &Node) -> bool {
    node.r#type.to_ascii_lowercase().contains("comment")
        || node.text.trim_start().starts_with("//")
        || node.text.trim_start().starts_with('#')
        || node.text.trim_start().starts_with("--")
}

struct RawBoundary {
    line: usize,
    kind: String,
    text: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn summaries(source: &str, language: Language) -> Vec<MethodSummary> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write");
        scan_files(&[file.path().to_path_buf()], language).expect("scan")
    }

    #[test]
    fn extracts_python_function_local_flow() {
        let summaries = summaries(
            "def mixed(price, tax):\n    subtotal = price + tax\n    total = subtotal\n    return total\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "mixed")
            .expect("mixed summary");

        assert_eq!(summary.owner, "(top-level)");
        assert_eq!(summary.statements.len(), 3);
        assert_eq!(
            summary.statements[0].reads,
            ["price".to_string(), "tax".to_string()]
                .into_iter()
                .collect()
        );
        assert_eq!(
            summary.statements[1].dependencies,
            vec![("total".to_string(), "subtotal".to_string())]
        );
        assert_eq!(
            summary.statements[2].reads,
            ["total".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn extracts_java_kotlin_and_swift_local_flow() {
        let cases = [
            (
                Language::Java,
                "class Billing {\n  int mixed(int price, int tax) {\n    int subtotal = price + tax;\n    int total = subtotal;\n    return total;\n  }\n}\n",
            ),
            (
                Language::Kotlin,
                "class Billing {\n  fun mixed(price: Int, tax: Int): Int {\n    val subtotal = price + tax\n    val total = subtotal\n    return total\n  }\n}\n",
            ),
            (
                Language::Swift,
                "class Billing {\n  func mixed(price: Int, tax: Int) -> Int {\n    let subtotal = price + tax\n    let total = subtotal\n    return total\n  }\n}\n",
            ),
        ];

        for (language, source) in cases {
            let summaries = summaries(source, language);
            let summary = summaries
                .iter()
                .find(|summary| summary.name == "mixed")
                .expect("mixed summary");

            assert_eq!(summary.owner, "Billing");
            assert_eq!(summary.statements.len(), 3);
            assert_eq!(
                summary.statements[0].reads,
                ["price".to_string(), "tax".to_string()]
                    .into_iter()
                    .collect()
            );
            assert_eq!(
                summary.statements[1].dependencies,
                vec![("total".to_string(), "subtotal".to_string())]
            );
            assert_eq!(
                summary.statements[2].reads,
                ["total".to_string()].into_iter().collect()
            );
        }
    }
}
