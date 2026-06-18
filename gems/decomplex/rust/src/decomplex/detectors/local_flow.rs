use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeSet};
use std::path::PathBuf;

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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<MethodSummary>> {
    let mut out = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut detector = LocalFlow::new(file.to_string_lossy().to_string(), lines);
        out.extend(detector.scan(&root));
    }
    Ok(out)
}

struct LocalFlow {
    file: String,
    lines: Vec<String>,
}

impl LocalFlow {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines }
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
                out.push(self.method_summary(method, &owner));
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            self.collect_nested_owners(node, &next_owners, out);
        } else if METHOD_TYPES.contains(&node.r#type.as_str()) && owners.is_empty() {
            out.push(self.method_summary(node, "(top-level)"));
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

    fn method_summary(&self, node: &Node, owner: &str) -> MethodSummary {
        let statements: Vec<_> = ast::body_stmts(node)
            .iter()
            .enumerate()
            .map(|(index, stmt)| self.statement_summary(stmt, index))
            .collect();
        MethodSummary {
            id: format!("{}#{}", owner, self.method_name(node)),
            owner: owner.to_string(),
            name: self.method_name(node),
            file: self.file.clone(),
            line: node.first_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
            node: node.clone(),
            boundaries: self.structural_boundaries(&statements),
            statements,
        }
    }

    fn statement_summary(&self, node: &Node, index: usize) -> Statement {
        Statement {
            index,
            line: node.first_lineno,
            end_line: node.last_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
            source: ast::slice(node, &self.lines),
            reads: self.local_reads(node),
            writes: self.local_writes(node),
            dependencies: self.assignment_dependencies(node),
            co_uses: self.co_use_edges(node),
        }
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
            let text = self.lines.get(line_number - 1).map(|s| s.as_str()).unwrap_or("");
            let stripped = text.trim();
            if stripped.starts_with('#') {
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

        let stmts = if body.r#type == "BLOCK" {
            body.children.iter().filter_map(ast::node).collect::<Vec<_>>()
        } else {
            vec![body]
        };

        stmts.into_iter().flat_map(|stmt| {
            if METHOD_TYPES.contains(&stmt.r#type.as_str()) {
                vec![stmt]
            } else if self.visibility_call(stmt) {
                self.inline_methods(stmt)
            } else {
                vec![]
            }
        }).collect()
    }

    fn inline_methods<'a>(&self, stmt: &'a Node) -> Vec<&'a Node> {
        let Some(args) = stmt.children.get(1).and_then(ast::node) else {
            return Vec::new();
        };
        args.children.iter().filter_map(ast::node).filter(|arg| METHOD_TYPES.contains(&arg.r#type.as_str())).collect()
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
                if r.r#type == "SELF" { "self".to_string() } else { ast::slice(r, &self.lines) }
            } else {
                "?".to_string()
            };
            format!("{}.{}", prefix, node.children.get(1).and_then(|c| match c { Child::Symbol(s) => Some(s), _ => None }).unwrap_or(&"?".to_string()))
        } else {
            node.children.first().and_then(|c| match c { Child::Symbol(s) => Some(s.clone()), _ => None }).unwrap_or_else(|| "?".to_string())
        }
    }

    fn full_owner_name(&self, owners: &[String], node: &Node) -> String {
        let mut next = owners.to_vec();
        next.push(self.owner_segment(node));
        next.join("::")
    }

    fn owner_segment(&self, node: &Node) -> String {
        let text = ast::slice(node.children.first().and_then(ast::node).unwrap_or(node), &self.lines);
        if text.is_empty() { "(anonymous)".to_string() } else { text }
    }

    fn local_reads(&self, node: &Node) -> BTreeSet<String> {
        let mut reads = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_READ_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(name)) = child.children.first() {
                    reads.push(name.clone());
                }
            }
        });
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
        writes.into_iter().collect()
    }

    fn assignment_dependencies(&self, node: &Node) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_WRITE_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(lhs)) = child.children.first() {
                    if let Some(rhs) = child.children.get(1).and_then(ast::node) {
                        for read in self.local_reads(rhs) {
                            if lhs != &read {
                                deps.push((lhs.clone(), read));
                            }
                        }
                    }
                }
            }
        });
        deps.sort();
        deps.dedup();
        deps
    }

    fn co_use_edges(&self, node: &Node) -> Vec<(String, String)> {
        let reads: Vec<_> = self.local_reads(node).into_iter().collect();
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

    #[test]
    fn extracts_python_function_local_flow() {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(
            b"def mixed(price, tax):\n    subtotal = price + tax\n    total = subtotal\n    return total\n",
        )
        .expect("write");

        let summaries = scan_files(&[file.path().to_path_buf()], Language::Python).expect("scan");
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "mixed")
            .expect("mixed summary");

        assert_eq!(summary.owner, "(top-level)");
        assert_eq!(summary.statements.len(), 3);
        assert_eq!(
            summary.statements[0].reads,
            ["price".to_string(), "tax".to_string()].into_iter().collect()
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
