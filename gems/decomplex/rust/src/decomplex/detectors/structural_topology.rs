use crate::decomplex::ast::{self, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize)]
pub struct StructuralTopologyReport {
    pub methods: Vec<Method>,
    pub edges: Vec<Edge>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Method {
    pub id: String,
    pub owner: String,
    pub name: String,
    pub file: String,
    pub line: usize,
    pub span: Span,
    pub visibility: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Edge {
    pub caller: String,
    pub callee: String,
    pub caller_name: String,
    pub callee_name: String,
    pub file: String,
    pub line: usize,
    pub span: Span,
    pub r#type: String,
    pub kind: String,
    pub confidence: String,
}

const VISIBILITY_MIDS: &[&str] = &["public", "protected", "private"];
const OWNER_TYPES: &[&str] = &["CLASS", "MODULE"];
const METHOD_TYPES: &[&str] = &["DEFN", "DEFS"];
const SKIP_NESTED_TYPES: &[&str] = &["CLASS", "MODULE", "DEFN", "DEFS", "LAMBDA"];
const CONDITIONAL_TYPES: &[&str] = &["IF", "UNLESS", "CASE", "CASE2"];
const ITERATION_TYPES: &[&str] = &["ITER", "FOR", "WHILE", "UNTIL"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<StructuralTopologyReport> {
    let mut methods = Vec::new();
    let mut parsed = Vec::new();

    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut mc = MethodCollector::new(file.to_string_lossy().to_string(), lines.clone());
        methods.extend(mc.scan(&root));
        parsed.push((file.to_string_lossy().to_string(), root, lines));
    }

    let mut edges = Vec::new();
    for (file, root, lines) in &parsed {
        let mut ec = EdgeCollector::new(file.clone(), lines.clone(), &methods);
        edges.extend(ec.scan(root));
    }

    Ok(StructuralTopologyReport { methods, edges })
}

pub struct Graph {
    pub methods: Vec<Method>,
    pub edges: Vec<Edge>,
    method_by_id: BTreeMap<String, Method>,
    edges_by_caller: BTreeMap<String, Vec<Edge>>,
    edges_by_callee: BTreeMap<String, Vec<Edge>>,
}

impl Graph {
    pub fn new(methods: Vec<Method>, edges: Vec<Edge>) -> Self {
        let mut method_by_id = BTreeMap::new();
        for m in &methods {
            method_by_id.insert(m.id.clone(), m.clone());
        }

        let mut edges_by_caller = BTreeMap::new();
        let mut edges_by_callee = BTreeMap::new();
        for e in &edges {
            edges_by_caller
                .entry(e.caller.clone())
                .or_insert_with(Vec::new)
                .push(e.clone());
            edges_by_callee
                .entry(e.callee.clone())
                .or_insert_with(Vec::new)
                .push(e.clone());
        }

        Self {
            methods,
            edges,
            method_by_id,
            edges_by_caller,
            edges_by_callee,
        }
    }

    pub fn method(&self, id: &str) -> Option<&Method> {
        self.method_by_id.get(id)
    }

    pub fn internal_calls(&self, id: &str) -> Vec<Edge> {
        self.edges_by_caller.get(id).cloned().unwrap_or_default()
    }

    pub fn internal_callers(&self, id: &str) -> Vec<Edge> {
        self.edges_by_callee.get(id).cloned().unwrap_or_default()
    }

    pub fn single_internal_caller(&self, id: &str) -> bool {
        let callers = self.internal_callers(id);
        let mut unique = BTreeMap::new();
        for c in callers {
            unique.insert(c.caller, true);
        }
        unique.len() == 1
    }

    pub fn visibility(&self, id: &str) -> Option<&str> {
        self.method(id).map(|m| m.visibility.as_str())
    }
}

struct MethodCollector {
    file: String,
    lines: Vec<String>,
}

impl MethodCollector {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines }
    }

    fn scan(&mut self, root: &Node) -> Vec<Method> {
        let mut out = Vec::new();
        out.extend(
            self.methods_from_statements(&self.top_level_statements(root), &self.top_level_owner()),
        );
        self.walk(root, &Vec::new(), &mut out);
        out
    }

    fn walk(&self, node: &Node, owners: &[String], out: &mut Vec<Method>) {
        if OWNER_TYPES.contains(&node.r#type.as_str()) {
            let owner = self.full_owner_name(owners, node);
            out.extend(self.owner_methods(node, &owner));
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, &next_owners, out);
            }
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, owners, out);
            }
        }
    }

    fn owner_methods(&self, owner_node: &Node, owner: &str) -> Vec<Method> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };
        self.methods_from_statements(&self.owner_statements(body), owner)
    }

    fn methods_from_statements(&self, stmts: &[&Node], owner: &str) -> Vec<Method> {
        let mut methods = Vec::new();
        let mut visibility = "public".to_string();
        for stmt in stmts {
            if self.bare_visibility_marker(stmt) {
                visibility = ast::child_to_string(stmt.children.get(0)).unwrap_or_default();
            } else if self.visibility_call(stmt) {
                visibility = self.handle_visibility_call(stmt, owner, &visibility, &mut methods);
            } else if METHOD_TYPES.contains(&stmt.r#type.as_str()) {
                methods.push(self.method_record(stmt, owner, &visibility));
            }
        }
        methods
    }

    fn handle_visibility_call(
        &self,
        stmt: &Node,
        owner: &str,
        current_visibility: &str,
        methods: &mut Vec<Method>,
    ) -> String {
        let vis = ast::child_to_string(stmt.children.get(0)).unwrap_or_default();
        if let Some(args) = stmt.children.get(1).and_then(ast::node) {
            for arg in args.children.iter().filter_map(ast::node) {
                if METHOD_TYPES.contains(&arg.r#type.as_str()) {
                    methods.push(self.method_record(arg, owner, &vis));
                } else if let Some(name) = self.literal_method_name(arg) {
                    if let Some(m) = methods.iter_mut().rev().find(|m| m.name == name) {
                        m.visibility = vis.clone();
                    }
                }
            }
        }
        current_visibility.to_string()
    }

    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
        if scope.r#type != "SCOPE" {
            return None;
        }
        scope.children.get(2).and_then(ast::node)
    }

    fn owner_statements<'a>(&self, body: &'a Node) -> Vec<&'a Node> {
        if body.r#type == "BLOCK" {
            body.children.iter().filter_map(ast::node).collect()
        } else {
            vec![body]
        }
    }

    fn top_level_statements<'a>(&self, root: &'a Node) -> Vec<&'a Node> {
        root.children
            .iter()
            .filter_map(ast::node)
            .flat_map(|c| {
                if c.r#type == "BLOCK" {
                    c.children.iter().filter_map(ast::node).collect()
                } else {
                    vec![c]
                }
            })
            .collect()
    }

    fn bare_visibility_marker(&self, node: &Node) -> bool {
        node.r#type == "VCALL"
            && VISIBILITY_MIDS.contains(
                &ast::child_to_string(node.children.get(0))
                    .unwrap_or_default()
                    .as_str(),
            )
    }

    fn visibility_call(&self, node: &Node) -> bool {
        node.r#type == "FCALL"
            && VISIBILITY_MIDS.contains(
                &ast::child_to_string(node.children.get(0))
                    .unwrap_or_default()
                    .as_str(),
            )
    }

    fn literal_method_name(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "LIT" | "STR" | "DSTR" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }

    fn method_record(&self, node: &Node, owner: &str, visibility: &str) -> Method {
        let name = self.method_name(node);
        Method {
            id: format!("{}#{}", owner, name),
            owner: owner.to_string(),
            name: name.clone(),
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            visibility: if node.r#type == "DEFS" {
                "public".to_string()
            } else {
                visibility.to_string()
            },
        }
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
                ast::child_to_string(node.children.get(1)).unwrap_or_else(|| "?".to_string())
            )
        } else {
            ast::child_to_string(node.children.get(0)).unwrap_or_else(|| "?".to_string())
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

    fn top_level_owner(&self) -> String {
        format!("(top-level:{})", self.file)
    }
}

struct EdgeCollector {
    file: String,
    lines: Vec<String>,
    method_by_id: BTreeMap<String, Method>,
}

impl EdgeCollector {
    fn new(file: String, lines: Vec<String>, methods: &[Method]) -> Self {
        let mut map = BTreeMap::new();
        for m in methods {
            map.insert(m.id.clone(), m.clone());
        }
        Self {
            file,
            lines,
            method_by_id: map,
        }
    }

    fn scan(&mut self, root: &Node) -> Vec<Edge> {
        let mut out = Vec::new();
        let top_level_methods: Vec<_> = self
            .top_level_statements(root)
            .into_iter()
            .filter(|s| METHOD_TYPES.contains(&s.r#type.as_str()))
            .collect();
        for m_node in top_level_methods {
            let id = format!("(top-level:{})#{}", self.file, self.method_name(m_node));
            if let Some(m) = self.method_by_id.get(&id) {
                self.collect_calls(m_node, m, &Vec::new(), &mut out);
            }
        }
        self.walk(root, &Vec::new(), &mut out);
        out
    }

    fn walk(&self, node: &Node, owners: &[String], out: &mut Vec<Edge>) {
        if OWNER_TYPES.contains(&node.r#type.as_str()) {
            let owner = self.full_owner_name(owners, node);
            for m_node in self.owner_methods(node) {
                let id = format!("{}#{}", owner, self.method_name(m_node));
                if let Some(m) = self.method_by_id.get(&id) {
                    self.collect_calls(m_node, m, &Vec::new(), out);
                }
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, &next_owners, out);
            }
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, owners, out);
            }
        }
    }

    fn collect_calls(
        &self,
        node: &Node,
        caller: &Method,
        context_stack: &[String],
        out: &mut Vec<Edge>,
    ) {
        if SKIP_NESTED_TYPES.contains(&node.r#type.as_str())
            && !METHOD_TYPES.contains(&node.r#type.as_str())
        {
            return;
        }

        let mut next_context = context_stack.to_vec();
        if CONDITIONAL_TYPES.contains(&node.r#type.as_str()) {
            next_context.push("conditional".to_string())
        }
        if ITERATION_TYPES.contains(&node.r#type.as_str()) {
            next_context.push("iterates".to_string())
        }

        if let Some(edge) = self.internal_edge(node, caller, &next_context) {
            if edge.caller != edge.callee {
                out.push(edge)
            }
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.collect_calls(child, caller, &next_context, out);
        }
    }

    fn internal_edge(
        &self,
        node: &Node,
        caller: &Method,
        context_stack: &[String],
    ) -> Option<Edge> {
        let call = self.internal_call_name(node, caller)?;
        let id = format!("{}#{}", caller.owner, call.name);
        let callee = self.method_by_id.get(&id)?;

        Some(Edge {
            caller: caller.id.clone(),
            callee: callee.id.clone(),
            caller_name: caller.name.clone(),
            callee_name: callee.name.clone(),
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            r#type: context_stack
                .last()
                .cloned()
                .unwrap_or_else(|| "always".to_string()),
            kind: call.kind,
            confidence: "high".to_string(),
        })
    }

    fn internal_call_name(&self, node: &Node, caller: &Method) -> Option<InternalCallName> {
        match node.r#type.as_str() {
            "FCALL" | "VCALL" => Some(InternalCallName {
                name: self.scoped_name(
                    caller,
                    &ast::child_to_string(node.children.get(0)).unwrap_or_default(),
                ),
                kind: "bare_internal".to_string(),
            }),
            "CALL" | "OPCALL" => {
                let recv = node.children.get(0).and_then(ast::node)?;
                if recv.r#type != "SELF" {
                    return None;
                }
                let mid = ast::child_to_string(node.children.get(1))?;
                Some(InternalCallName {
                    name: self.scoped_name(caller, &mid),
                    kind: "direct_self".to_string(),
                })
            }
            _ => None,
        }
    }

    fn scoped_name(&self, caller: &Method, mid: &str) -> String {
        if caller.name.starts_with("self.") {
            format!("self.{}", mid)
        } else {
            mid.to_string()
        }
    }

    // Reuse helpers from MethodCollector
    fn top_level_statements<'a>(&self, root: &'a Node) -> Vec<&'a Node> {
        root.children
            .iter()
            .filter_map(ast::node)
            .flat_map(|c| {
                if c.r#type == "BLOCK" {
                    c.children.iter().filter_map(ast::node).collect()
                } else {
                    vec![c]
                }
            })
            .collect()
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
                ast::child_to_string(node.children.get(1)).unwrap_or_else(|| "?".to_string())
            )
        } else {
            ast::child_to_string(node.children.get(0)).unwrap_or_else(|| "?".to_string())
        }
    }
    fn owner_methods<'a>(&self, owner_node: &'a Node) -> Vec<&'a Node> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };
        self.owner_statements(body)
    }
    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
        if scope.r#type != "SCOPE" {
            return None;
        }
        scope.children.get(2).and_then(ast::node)
    }
    fn owner_statements<'a>(&self, body: &'a Node) -> Vec<&'a Node> {
        if body.r#type == "BLOCK" {
            body.children.iter().filter_map(ast::node).collect()
        } else {
            vec![body]
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
}

struct InternalCallName {
    name: String,
    kind: String,
}
