use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{self, Document, Language, StateRead, StateWrite};
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

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<TemporalOrderingPressureRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<TemporalOrderingPressureRow> {
    let mut rows = Vec::new();
    for document in documents {
        rows.extend(scan_document_facts(document));
    }
    rows.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| b.state_methods.cmp(&a.state_methods))
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.owner.cmp(&b.owner))
    });
    rows
}

fn scan_document_facts(document: &Document) -> Vec<TemporalOrderingPressureRow> {
    let owners = document
        .function_defs
        .iter()
        .map(|function| function.owner.clone())
        .collect::<BTreeSet<_>>();
    owners
        .into_iter()
        .filter_map(|owner| pressure_row_for_owner(document, &owner))
        .collect()
}

fn pressure_row_for_owner(document: &Document, owner: &str) -> Option<TemporalOrderingPressureRow> {
    let methods = document
        .function_defs
        .iter()
        .filter(|function| function.owner == owner)
        .map(|function| MethodState {
            name: function.name.clone(),
            line: function.line,
            span: function.span,
            visibility: function
                .visibility
                .clone()
                .unwrap_or_else(|| "public".to_string()),
            reads: sorted_unique(
                document
                    .state_reads
                    .iter()
                    .filter(|read| read.owner == function.owner && read.function == function.name)
                    .map(|read| read.field.clone()),
            ),
            writes: sorted_unique(
                document
                    .state_writes
                    .iter()
                    .filter(|write| {
                        write.owner == function.owner && write.function == function.name
                    })
                    .map(|write| write.field.clone()),
            ),
        })
        .collect::<Vec<_>>();
    pressure_row(document.file.as_str(), owner, &methods)
}

fn pressure_row(
    file: &str,
    owner: &str,
    methods: &[MethodState],
) -> Option<TemporalOrderingPressureRow> {
    let public_methods: Vec<_> = methods
        .iter()
        .filter(|m| m.visibility == "public")
        .collect();
    let state_methods: Vec<_> = public_methods
        .iter()
        .filter(|m| !m.reads.is_empty() || !m.writes.is_empty())
        .collect();
    let writers: Vec<_> = public_methods
        .iter()
        .filter(|m| !m.writes.is_empty())
        .collect();

    if state_methods.len() < 3 || writers.len() < 2 {
        return None;
    }

    let mut fields_set = BTreeSet::new();
    for m in &state_methods {
        fields_set.extend(m.reads.iter().cloned());
        fields_set.extend(m.writes.iter().cloned());
    }
    let fields = fields_set.into_iter().collect::<Vec<_>>();
    let shared_fields = fields
        .iter()
        .filter(|field| {
            state_methods
                .iter()
                .filter(|m| m.reads.contains(*field) || m.writes.contains(*field))
                .count()
                >= 2
        })
        .cloned()
        .collect::<Vec<_>>();
    if shared_fields.is_empty() {
        return None;
    }

    let n = state_methods.len();
    let state_space = 2usize.pow(fields.len().min(12) as u32);
    let score = (n * writers.len() * shared_fields.len().max(1)) + state_space;
    Some(TemporalOrderingPressureRow {
        at: format!("{}:{}:{}", file, owner, state_methods[0].line),
        file: file.to_string(),
        owner: owner.to_string(),
        public_methods: public_methods.len(),
        state_methods: n,
        writers: writers.len(),
        state_fields: fields,
        shared_fields,
        orderings: format!("{n}!"),
        state_space: format!(
            "2^{}",
            state_methods
                .iter()
                .flat_map(|m| m.reads.iter().chain(m.writes.iter()))
                .collect::<BTreeSet<_>>()
                .len()
        ),
        score,
        sites: state_methods
            .iter()
            .map(|m| format!("{}:{}:{}", file, m.name, m.line))
            .collect(),
        spans: state_methods
            .iter()
            .map(|m| (format!("{}:{}:{}", file, m.name, m.line), m.span))
            .collect(),
    })
}

struct TemporalOrderingPressure {
    file: String,
    lines: Vec<String>,
    state_reads: Vec<StateRead>,
    state_writes: Vec<StateWrite>,
}

impl TemporalOrderingPressure {
    fn new(
        file: String,
        lines: Vec<String>,
        state_reads: Vec<StateRead>,
        state_writes: Vec<StateWrite>,
    ) -> Self {
        Self {
            file,
            lines,
            state_reads,
            state_writes,
        }
    }

    fn scan(&mut self, root: &Node) -> Vec<TemporalOrderingPressureRow> {
        let mut out = Vec::new();
        self.walk_owners(root, &Vec::new(), &mut out);
        out
    }

    fn walk_owners(
        &self,
        node: &Node,
        owners: &[String],
        out: &mut Vec<TemporalOrderingPressureRow>,
    ) {
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE") {
            let owner = self.full_owner_name(owners, node);
            let methods = self.owner_methods(node, &owner);
            if let Some(row) = self.pressure_row(&owner, &methods) {
                out.push(row);
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            for child in node.children.iter().filter_map(ast::node) {
                self.walk_owners(child, &next_owners, out);
            }
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk_owners(child, owners, out);
            }
        }
    }

    fn full_owner_name(&self, owners: &[String], node: &Node) -> String {
        let mut next = owners.to_vec();
        next.push(self.owner_segment(node));
        next.join("::")
    }

    fn owner_segment(&self, node: &Node) -> String {
        let name = ast::slice(
            node.children.first().and_then(ast::node).unwrap_or(node),
            &self.lines,
        );
        if name.is_empty() {
            "(anonymous)".to_string()
        } else {
            name
        }
    }

    fn owner_methods(&self, owner_node: &Node, owner: &str) -> Vec<MethodState> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };

        let stmts = if body.r#type == "BLOCK" {
            body.children
                .iter()
                .filter_map(ast::node)
                .collect::<Vec<_>>()
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
                methods.push(self.method_state(stmt, &visibility, owner));
            }
        }
        methods
    }

    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
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

    fn method_state(&self, defn_node: &Node, visibility: &str, owner: &str) -> MethodState {
        let name_index = if defn_node.r#type == "DEFS" { 1 } else { 0 };
        let name = defn_node
            .children
            .get(name_index)
            .and_then(|c| match c {
                Child::Symbol(s) => Some(s.clone()),
                _ => None,
            })
            .unwrap_or_else(|| "(anonymous)".to_string());

        let reads = self.state_reads_for(owner, &name);
        let writes = self.state_writes_for(owner, &name);

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

    fn state_reads_for(&self, owner: &str, function: &str) -> Vec<String> {
        sorted_unique(
            self.state_reads
                .iter()
                .filter(|read| read.owner == owner && read.function == function)
                .map(|read| read.field.clone()),
        )
    }

    fn state_writes_for(&self, owner: &str, function: &str) -> Vec<String> {
        sorted_unique(
            self.state_writes
                .iter()
                .filter(|write| write.owner == owner && write.function == function)
                .map(|write| write.field.clone()),
        )
    }

    fn pressure_row(
        &self,
        owner: &str,
        methods: &[MethodState],
    ) -> Option<TemporalOrderingPressureRow> {
        let public_methods: Vec<_> = methods
            .iter()
            .filter(|m| m.visibility == "public")
            .collect();
        let state_methods: Vec<_> = public_methods
            .iter()
            .filter(|m| !m.reads.is_empty() || !m.writes.is_empty())
            .collect();
        let writers: Vec<_> = public_methods
            .iter()
            .filter(|m| !m.writes.is_empty())
            .collect();

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
        let state_space_exp = fields.len();
        let state_space = 2usize.pow(state_space_exp.min(12) as u32);
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

fn sorted_unique(values: impl Iterator<Item = String>) -> Vec<String> {
    let mut out: Vec<_> = values.collect::<BTreeSet<_>>().into_iter().collect();
    out.sort();
    out
}
