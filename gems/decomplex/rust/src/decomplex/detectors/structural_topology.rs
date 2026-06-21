use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, CallSite, Document, FunctionDef, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<StructuralTopologyReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> StructuralTopologyReport {
    let mut methods = Vec::new();
    for document in documents {
        methods.extend(methods_for_document(document));
    }
    methods.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.owner.cmp(&b.owner))
            .then_with(|| a.name.cmp(&b.name))
    });

    let method_by_id = methods
        .iter()
        .map(|method| (method.id.clone(), method.clone()))
        .collect::<BTreeMap<_, _>>();

    let mut edges = Vec::new();
    for document in documents {
        edges.extend(edges_for_document(document, &method_by_id));
    }
    edges.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.span.cmp(&b.span))
            .then_with(|| a.caller.cmp(&b.caller))
            .then_with(|| a.callee.cmp(&b.callee))
    });
    let mut seen = BTreeSet::new();
    edges.retain(|edge| {
        seen.insert((
            edge.caller.clone(),
            edge.callee.clone(),
            edge.r#type.clone(),
        ))
    });

    StructuralTopologyReport { methods, edges }
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

fn methods_for_document(document: &Document) -> Vec<Method> {
    document
        .function_defs
        .iter()
        .map(|function| method_for_function(document, function))
        .collect()
}

fn method_for_function(document: &Document, function: &FunctionDef) -> Method {
    let owner = top_level_owner_for(document, &function.owner, function.span);
    Method {
        id: format!("{}#{}", owner, function.name),
        owner,
        name: function.name.clone(),
        file: function.file.clone(),
        line: function.line,
        span: function.span,
        visibility: function
            .visibility
            .clone()
            .unwrap_or_else(|| "public".to_string()),
    }
}

fn edges_for_document(document: &Document, method_by_id: &BTreeMap<String, Method>) -> Vec<Edge> {
    document
        .call_sites
        .iter()
        .filter_map(|call| edge_for_call(document, method_by_id, call))
        .collect()
}

fn edge_for_call(
    document: &Document,
    method_by_id: &BTreeMap<String, Method>,
    call: &CallSite,
) -> Option<Edge> {
    if call.receiver != "self" {
        return None;
    }

    let owner = top_level_owner_for(document, &call.owner, call.span);
    let caller = method_by_id.get(&format!("{}#{}", owner, call.function))?;
    let callee_name = scoped_name(caller, &call.message);
    let callee = method_by_id.get(&format!("{}#{}", owner, callee_name))?;
    if caller.id == callee.id {
        return None;
    }

    Some(Edge {
        caller: caller.id.clone(),
        callee: callee.id.clone(),
        caller_name: caller.name.clone(),
        callee_name: callee.name.clone(),
        file: call.file.clone(),
        line: call.line,
        span: call.span,
        r#type: edge_type(call.control.as_deref()),
        kind: call_kind(document, call.span),
        confidence: "high".to_string(),
    })
}

fn scoped_name(caller: &Method, message: &str) -> String {
    if caller.name.starts_with("self.") {
        format!("self.{message}")
    } else {
        message.to_string()
    }
}

fn edge_type(control: Option<&str>) -> String {
    match control {
        Some("conditional" | "iterates") => control.unwrap().to_string(),
        _ => "always".to_string(),
    }
}

fn call_kind(document: &Document, span: Span) -> String {
    if source_text(&document.lines, span)
        .trim_start()
        .starts_with("self.")
    {
        "direct_self".to_string()
    } else {
        "bare_internal".to_string()
    }
}

fn source_text(lines: &[String], span: Span) -> String {
    let [first_line, first_column, last_line, last_column] = span;
    if first_line == 0 || last_line == 0 || first_line > lines.len() || last_line > lines.len() {
        return String::new();
    }
    if first_line == last_line {
        return lines[first_line - 1]
            .chars()
            .skip(first_column)
            .take(last_column.saturating_sub(first_column))
            .collect();
    }

    let mut parts = Vec::new();
    parts.push(lines[first_line - 1].chars().skip(first_column).collect());
    for line in lines
        .iter()
        .take(last_line.saturating_sub(1))
        .skip(first_line)
    {
        parts.push(line.clone());
    }
    parts.push(lines[last_line - 1].chars().take(last_column).collect());
    parts.join("")
}

fn top_level_owner_for(document: &Document, owner: &str, span: Span) -> String {
    if owner != file_owner(&document.file) || enclosed_by_matching_owner(document, owner, span) {
        owner.to_string()
    } else {
        format!("(top-level:{})", document.file)
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

fn enclosed_by_matching_owner(document: &Document, owner: &str, span: Span) -> bool {
    document
        .owner_defs
        .iter()
        .any(|owner_def| owner_def.name == owner && span_encloses(owner_def.span, span))
}

fn span_encloses(outer: Span, inner: Span) -> bool {
    let starts_before = outer[0] < inner[0] || (outer[0] == inner[0] && outer[1] <= inner[1]);
    let ends_after = outer[2] > inner[2] || (outer[2] == inner[2] && outer[3] >= inner[3]);
    starts_before && ends_after
}
