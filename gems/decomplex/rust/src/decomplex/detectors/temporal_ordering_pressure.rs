use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TemporalOrderingPressureRow {
    pub at: String,
    pub file: String,
    pub owner: String,
    pub public_methods: usize,
    pub state_methods: usize,
    pub writers: usize,
    pub state_fields: Vec<String>,
    pub shared_fields: Vec<String>,
    pub orderings: String,
    pub state_space: String,
    pub score: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct MethodState {
    name: String,
    line: usize,
    span: Span,
    visibility: String,
    reads: Vec<String>,
    writes: Vec<String>,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<Vec<TemporalOrderingPressureRow>> {
    let mut rows = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut detector = TemporalOrderingPressure::new(file.to_string_lossy().to_string(), lines);
        rows.extend(detector.scan(&root));
    }
    rows.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| b.state_methods.cmp(&a.state_methods))
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.owner.cmp(&b.owner))
    });
    Ok(rows)
}

struct TemporalOrderingPressure {
    file: String,
    lines: Vec<String>,
}

impl TemporalOrderingPressure {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines }
    }

    fn scan(&mut self, root: &Node) -> Vec<TemporalOrderingPressureRow> {
        let mut out = Vec::new();
        self.walk_owners(root, &Vec::new(), &mut out);
        out
    }

    fn walk_owners(&self, node: &Node, owners: &[String], out: &mut Vec<TemporalOrderingPressureRow>) {
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE") {
            let owner = self.owner_name(node);
            let methods = self.owner_methods(node);
            if let Some(row) = self.pressure_row(&owner, &methods) {
                out.push(row);
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(owner);
            for child in node.children.iter().filter_map(ast::node) {
                self.walk_owners(child, &next_owners, out);
            }
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk_owners(child, owners, out);
            }
        }
    }

    fn owner_name(&self, node: &Node) -> String {
        let name = ast::slice(node.children.first().and_then(ast::node).unwrap_or(node), &self.lines);
        if name.is_empty() {
            "(anonymous)".to_string()
        } else {
            name
        }
    }

    fn owner_methods(&self, owner_node: &Node) -> Vec<MethodState> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };

        let stmts = if body.r#type == "BLOCK" {
            body.children.iter().filter_map(ast::node).collect::<Vec<_>>()
        } else {
            vec![body]
        };

        let mut visibility = "public".to_string();
        let mut methods = Vec::new();

        for stmt in stmts {
            if self.visibility_marker(stmt) {
                if let Some(Child::Symbol(name)) = stmt.children.first() {
                    visibility = name.clone();
                }
            } else if matches!(stmt.r#type.as_str(), "DEFN" | "DEFS") {
                methods.push(self.method_state(stmt, &visibility));
            }
        }
        methods
    }

    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope = owner_node.children.get(2).and_then(ast::node)?;
        if scope.r#type != "SCOPE" {
            return None;
        }
        scope.children.get(2).and_then(ast::node)
    }

    fn visibility_marker(&self, node: &Node) -> bool {
        if node.r#type == "VCALL" {
            if let Some(Child::Symbol(name)) = node.children.first() {
                return matches!(name.as_str(), "public" | "protected" | "private");
            }
        }
        false
    }

    fn method_state(&self, defn_node: &Node, visibility: &str) -> MethodState {
        let mut reads = Vec::new();
        let mut writes = Vec::new();
        self.collect_state_access(defn_node, &mut reads, &mut writes);

        let name_index = if defn_node.r#type == "DEFS" { 1 } else { 0 };
        let name = defn_node
            .children
            .get(name_index)
            .and_then(|c| match c {
                Child::Symbol(s) => Some(s.clone()),
                _ => None,
            })
            .unwrap_or_else(|| "(anonymous)".to_string());

        let mut reads: Vec<_> = reads.into_iter().collect::<BTreeSet<_>>().into_iter().collect();
        let mut writes: Vec<_> = writes.into_iter().collect::<BTreeSet<_>>().into_iter().collect();
        reads.sort();
        writes.sort();

        MethodState {
            name,
            line: defn_node.first_lineno,
            span: [
                defn_node.first_lineno,
                defn_node.first_column,
                defn_node.last_lineno,
                defn_node.last_column,
            ],
            visibility: visibility.to_string(),
            reads,
            writes,
        }
    }

    fn collect_state_access(&self, node: &Node, reads: &mut Vec<String>, writes: &mut Vec<String>) {
        match node.r#type.as_str() {
            "IASGN" => {
                if let Some(Child::String(name)) = node.children.first() {
                    writes.push(name.clone());
                }
            }
            "IVAR" => {
                if let Some(Child::String(name)) = node.children.first() {
                    reads.push(name.clone());
                }
            }
            _ => {}
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.collect_state_access(child, reads, writes);
        }
    }

    fn pressure_row(&self, owner: &str, methods: &[MethodState]) -> Option<TemporalOrderingPressureRow> {
        let public_methods: Vec<_> = methods.iter().filter(|m| m.visibility == "public").collect();
        let state_methods: Vec<_> = public_methods
            .iter()
            .filter(|m| !m.reads.is_empty() || !m.writes.is_empty())
            .collect();
        let writers: Vec<_> = public_methods.iter().filter(|m| !m.writes.is_empty()).collect();

        if state_methods.len() < 3 || writers.len() < 2 {
            return None;
        }

        let mut fields_set = BTreeSet::new();
        for m in &state_methods {
            for r in &m.reads {
                fields_set.insert(r.clone());
            }
            for w in &m.writes {
                fields_set.insert(w.clone());
            }
        }
        let fields: Vec<_> = fields_set.into_iter().collect();

        let shared_fields: Vec<_> = fields
            .iter()
            .filter(|field| {
                state_methods
                    .iter()
                    .filter(|m| m.reads.contains(*field) || m.writes.contains(*field))
                    .count()
                    >= 2
            })
            .cloned()
            .collect();

        if shared_fields.is_empty() {
            return None;
        }

        let n = state_methods.len();
        let state_space_exp = fields.len().min(12);
        let state_space = 2usize.pow(state_space_exp as u32);
        let score = (n * writers.len() * shared_fields.len().max(1)) + state_space;

        let first_line = state_methods.first()?.line;
        let at = format!("{}:{}:{}", self.file, owner, first_line);

        let mut sites = Vec::new();
        let mut spans = BTreeMap::new();
        for m in &state_methods {
            let loc = format!("{}:{}:{}", self.file, m.name, m.line);
            sites.push(loc.clone());
            spans.insert(loc, m.span);
        }

        Some(TemporalOrderingPressureRow {
            at,
            file: self.file.clone(),
            owner: owner.to_string(),
            public_methods: public_methods.len(),
            state_methods: n,
            writers: writers.len(),
            state_fields: fields,
            shared_fields,
            orderings: self.factorial_label(n),
            state_space: format!("2^{}", state_space_exp),
            score,
            sites,
            spans,
        })
    }

    fn factorial_label(&self, n: usize) -> String {
        format!("{}!", n)
    }
}
