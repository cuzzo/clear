use crate::ast::{self, Child, Node, Span};
use crate::parallel;
use crate::syntax::normalized_behavior::NormalizedLanguageBehavior;
use crate::syntax::{Document, FunctionDef, Language};
use anyhow::Result;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct LocalFlowRow {
    pub summaries: Vec<MethodSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct MethodSummary {
    pub id: String,
    pub owner: String,
    pub name: String,
    pub file: String,
    pub line: usize,
    pub span: Span,
    #[serde(default = "empty_node", skip_serializing)]
    pub node: Node,
    pub statements: Vec<Statement>,
    pub boundaries: Vec<Boundary>,
    #[serde(default, skip_serializing)]
    pub params: BTreeSet<String>,
    #[serde(default)]
    pub param_types: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
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

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
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
const LOCAL_READ_TYPES: &[&str] = &["LVAR", "DVAR", "IVAR", "CVAR"];
const LOCAL_WRITE_TYPES: &[&str] = &["LASGN", "DASGN", "IASGN", "CVASGN"];
const STATEMENT_CONTAINER_TYPES: &[&str] = &[
    "BLOCK",
    "COMPOUND_STATEMENT",
    "DECLARATION_LIST",
    "FUNCTION_BODY",
    "HASH",
    "STATEMENTS",
];

fn empty_node() -> Node {
    Node {
        r#type: "ROOT".to_string(),
        children: Vec::new(),
        first_lineno: 1,
        first_column: 0,
        last_lineno: 1,
        last_column: 0,
        text: String::new(),
    }
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<MethodSummary>> {
    let documents = super::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<MethodSummary> {
    if documents.len() > 1 && parallel::job_count() > 1 {
        let mut methods: Vec<_> =
            parallel::map_ordered(documents, |document| Ok(document.local_methods.clone()))
                .expect("local-flow worker failed")
                .into_iter()
                .flatten()
                .collect();
        sort_method_summaries(&mut methods);
        return methods;
    }

    let mut methods = documents
        .iter()
        .flat_map(|document| document.local_methods.clone())
        .collect::<Vec<_>>();
    sort_method_summaries(&mut methods);
    methods
}

pub(crate) fn local_methods_from_normalized(
    file: &str,
    lines: &[String],
    root: &Node,
    functions: &[FunctionDef],
    method_param_types: &BTreeMap<String, BTreeMap<String, String>>,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Vec<MethodSummary> {
    let mut detector = LocalFlow::new(
        file.to_string(),
        lines.to_vec(),
        method_metadata(file, functions),
        method_param_types.clone(),
        behavior,
    );
    let mut methods = detector.scan(root);
    sort_method_summaries(&mut methods);
    methods
}

fn sort_method_summaries(methods: &mut [MethodSummary]) {
    methods.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.span.cmp(&b.span))
            .then_with(|| a.owner.cmp(&b.owner))
            .then_with(|| a.name.cmp(&b.name))
    });
}

pub fn local_contract_assignments(method: &MethodSummary) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for statement in &method.statements {
        if statement.writes.len() != 1 {
            continue;
        }
        let name = statement.writes.iter().next().unwrap();
        if map.contains_key(name) {
            continue;
        }
        if local_contract_conditional_statement(&method.node, statement.span) {
            continue;
        }
        if let Some(source) = local_contract_source(name, &statement.source) {
            map.insert(name.clone(), source);
        }
    }
    map
}

fn local_contract_source(name: &str, source: &str) -> Option<String> {
    let pattern = format!(
        r"(?s)\b{}\b\s*(?::=|=)\s*(.+?)\s*;?\s*$",
        regex::escape(name)
    );
    let assignment = Regex::new(&pattern).ok()?;
    let rhs = assignment.captures(source)?.get(1)?.as_str().trim();
    (!rhs.contains('?') && !rhs.contains(':')).then(|| rhs.to_string())
}

fn local_contract_conditional_statement(root: &Node, span: Span) -> bool {
    node_for_span(root, span).is_some_and(contains_contract_condition)
}

fn node_for_span(node: &Node, span: Span) -> Option<&Node> {
    if [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ] == span
    {
        return Some(node);
    }
    node.children
        .iter()
        .filter_map(ast::node)
        .find_map(|child| node_for_span(child, span))
}

fn contains_contract_condition(node: &Node) -> bool {
    matches!(
        node.r#type.as_str(),
        "IF" | "UNLESS" | "CASE" | "CASE2" | "WHEN" | "RESCUE"
    ) || node
        .children
        .iter()
        .filter_map(ast::node)
        .any(contains_contract_condition)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MethodMetadata {
    owner: String,
    name: String,
    params: BTreeSet<String>,
}

struct LocalFlow<'a> {
    file: String,
    lines: Vec<String>,
    methods_by_span: BTreeMap<Span, MethodMetadata>,
    method_param_types: BTreeMap<String, BTreeMap<String, String>>,
    behavior: &'a dyn NormalizedLanguageBehavior,
}

impl<'a> LocalFlow<'a> {
    fn new(
        file: String,
        lines: Vec<String>,
        methods_by_span: BTreeMap<Span, MethodMetadata>,
        method_param_types: BTreeMap<String, BTreeMap<String, String>>,
        behavior: &'a dyn NormalizedLanguageBehavior,
    ) -> Self {
        Self {
            file,
            lines,
            methods_by_span,
            method_param_types,
            behavior,
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
            // A normalized DEFN is already an adapter-validated executable
            // declaration. Continue through its body so named local
            // functions and variable-bound callables receive the same
            // CFG/DFG and complexity facts as top-level declarations.
            if self.behavior.nested_function_is_local_callable(node) {
                for child in node.children.iter().filter_map(ast::node) {
                    self.collect_methods(child, owners, out);
                }
            }
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.collect_methods(child, owners, out);
            }
        }
    }

    fn collect_nested_owners(&self, node: &Node, owners: &[String], out: &mut Vec<MethodSummary>) {
        for child in node.children.iter().filter_map(ast::node) {
            if OWNER_TYPES.contains(&child.r#type.as_str()) {
                self.collect_methods(child, owners, out);
            } else if METHOD_TYPES.contains(&child.r#type.as_str()) {
                let span = [
                    child.first_lineno,
                    child.first_column,
                    child.last_lineno,
                    child.last_column,
                ];
                // Java anonymous classes contain owner methods below a
                // constructor or initializer. Preserve only declarations the
                // language adapter positively identifies as owner methods;
                // ordinary nested/inline declarations stay out of this pass.
                if (self.behavior.nested_function_is_owner_method(child)
                    || (self.behavior.nested_function_is_local_callable(child)
                        && self.methods_by_span.contains_key(&span)))
                    && !out.iter().any(|method| method.span == span)
                {
                    out.push(self.method_summary(child, None));
                }
                self.collect_nested_owners(child, owners, out);
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
        let statements = statement_nodes
            .iter()
            .enumerate()
            .map(|(index, stmt)| self.statement_summary(stmt, index, &local_names))
            .collect::<Vec<_>>();
        let param_types = self.param_types_for(owner, &name, node.first_lineno);
        let params = metadata
            .map(|metadata| metadata.params.clone())
            .unwrap_or_default();
        MethodSummary {
            id: format!("{}#{}", owner, name),
            owner: owner.to_string(),
            name,
            file: self.file.clone(),
            line: node.first_lineno,
            span: node_span,
            node: node.clone(),
            boundaries: self.structural_boundaries(&statements),
            statements,
            params,
            param_types,
        }
    }

    fn param_types_for(&self, owner: &str, name: &str, line: usize) -> BTreeMap<String, String> {
        let line_key = super::normalized_behavior::method_parameter_type_key(owner, name, line);
        let null_key = format!("{owner}\0{name}");
        let colon_key = if owner.is_empty() || owner == "(top-level)" {
            name.to_string()
        } else {
            format!("{owner}::{name}")
        };
        self.method_param_types
            .get(&line_key)
            .or_else(|| self.method_param_types.get(&null_key))
            .or_else(|| self.method_param_types.get(&colon_key))
            .or_else(|| self.method_param_types.get(name))
            .cloned()
            .unwrap_or_default()
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

    fn source_boundary(&self, first_line: usize, last_line: usize) -> Option<BoundaryText> {
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
                return Some(BoundaryText {
                    line: line_number,
                    kind: "comment".to_string(),
                    text: stripped.to_string(),
                });
            }
            if stripped.is_empty() && blank.is_none() {
                blank = Some(BoundaryText {
                    line: line_number,
                    kind: "blank".to_string(),
                    text: stripped.to_string(),
                });
            }
        }
        blank
    }

    fn owner_methods<'node>(&self, owner_node: &'node Node) -> Vec<&'node Node> {
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
                } else {
                    Vec::new()
                }
            })
            .collect()
    }

    fn owner_body<'node>(&self, owner_node: &'node Node) -> Option<&'node Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
        (scope.r#type == "SCOPE")
            .then(|| scope.children.get(2).and_then(ast::node))
            .flatten()
    }

    fn method_name(&self, node: &Node) -> String {
        let name = if node.r#type == "DEFS" {
            let receiver = node.children.get(0).and_then(ast::node);
            let prefix = receiver
                .map(|receiver| {
                    if receiver.r#type == "SELF" {
                        "self".to_string()
                    } else {
                        ast::slice(receiver, &self.lines)
                    }
                })
                .unwrap_or_else(|| "?".to_string());
            let name = node.children.get(1).and_then(symbol_child).unwrap_or("?");
            format!("{prefix}.{name}")
        } else {
            node.children
                .first()
                .and_then(symbol_child)
                .unwrap_or("?")
                .to_string()
        };
        self.behavior.clean_identifier(&name)
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
        // A multi-declarator statement (`int retval, j, numevents = 0;`)
        // only forms an assignment-shaped node for declarators that carry
        // an initializer; bare co-declared names have no dedicated
        // "declaration target" node, so they normalize as plain identifier
        // references and get misread as reads of the whole declaration
        // statement (falsely "deriving" the initialized declarator from
        // them). Declarator names named in a declaration-like LHS are
        // being introduced here, not referenced, regardless of whether
        // they carry their own initializer.
        let source = ast::slice(node, &self.lines);
        let declared_names: BTreeSet<String> = split_assignment(&source)
            .filter(|(lhs, _)| declaration_like_lhs(lhs, self.behavior))
            .map(|(lhs, _)| {
                identifiers_with_positions(lhs)
                    .into_iter()
                    .map(|identifier| identifier.name)
                    .filter(|name| !self.behavior.local_flow_keyword(name))
                    .collect::<BTreeSet<_>>()
            })
            .unwrap_or_default();

        let mut reads = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_READ_TYPES.contains(&child.r#type.as_str()) {
                if let Some(name) = local_read_name(child) {
                    if local_names.contains(&name) && !declared_names.contains(&name) {
                        reads.push(name);
                    }
                }
            }
        });
        // Text scanning is a fallback for adapters whose normalized tree does
        // not expose local reads. Mixing it into structural evidence lets
        // identifiers in comments and string fragments masquerade as data
        // dependencies even when the AST already supplied the real reads.
        if reads.is_empty() {
            reads.extend(
                textual_local_reads(&ast::slice(node, &self.lines), local_names, writes)
                    .into_iter()
                    .filter(|name| !declared_names.contains(name)),
            );
        }
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
            writes.extend(normalized_control_writes(child));
        });
        if writes.is_empty() {
            writes.extend(textual_local_writes(
                &ast::slice(node, &self.lines),
                self.behavior,
            ));
        }
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
                        let rhs_writes = self.local_writes(rhs);
                        for read in self.local_reads(rhs, local_names, &rhs_writes) {
                            if lhs != &read {
                                deps.push((lhs.clone(), read));
                            }
                        }
                    }
                }
            }
        });
        let is_control_flow = matches!(
            node.r#type.as_str(),
            "IF" | "UNLESS"
                | "CASE"
                | "CASE2"
                | "WHEN"
                | "WHILE"
                | "UNTIL"
                | "FOR"
                | "ITER"
                | "BEGIN"
                | "RESCUE"
                | "ENSURE"
                | "COND"
                | "SWITCH"
                | "MATCH"
        );
        if !is_control_flow {
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
        }
        deps.sort();
        deps.dedup();
        deps
    }

    fn co_use_edges(&self, node: &Node, local_names: &BTreeSet<String>) -> Vec<(String, String)> {
        let writes = self.local_writes(node);
        let reads = self
            .local_reads(node, local_names, &writes)
            .into_iter()
            .collect::<Vec<_>>();
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

fn textual_local_writes(source: &str, behavior: &dyn NormalizedLanguageBehavior) -> Vec<String> {
    let Some((lhs, operator)) = split_assignment(source) else {
        return Vec::new();
    };
    let trimmed_lhs = lhs.trim();
    let is_state_write = trimmed_lhs.starts_with("self.")
        || trimmed_lhs.starts_with("this.")
        || trimmed_lhs.starts_with("self->")
        || trimmed_lhs.starts_with("this->")
        || trimmed_lhs.starts_with("$this->")
        || trimmed_lhs.starts_with('@');

    // A call whose receiver happens to start with `self.`/`this.` (e.g.
    // `self.add_headers(request, stream=stream, ...)`) must never be read
    // as a `self.x = value` state write just because its first `=` is a
    // keyword argument's binding, not an assignment. Parens mean this is a
    // call, never a plain assignment target, regardless of the receiver
    // prefix that made it look like one - unlike brackets, which a
    // legitimate indexed state write (`self.cache[index].status = 1`)
    // still needs to keep tolerating for is_state_write.
    if lhs.contains('(') || lhs.contains(')') {
        return Vec::new();
    }
    if !is_state_write && (lhs.contains('.') || lhs.contains("->") || lhs.contains('[')) {
        return Vec::new();
    }

    let clean_lhs = if declaration_like_lhs(lhs, behavior) {
        if let Some((before_colon, _)) = lhs.split_once(':') {
            before_colon
        } else {
            lhs
        }
    } else {
        lhs
    };

    let identifiers = identifiers_with_positions(clean_lhs)
        .into_iter()
        .map(|identifier| identifier.name)
        .filter(|name| !behavior.local_flow_keyword(name))
        .collect::<Vec<_>>();
    if identifiers.is_empty() {
        return Vec::new();
    }

    if behavior.local_flow_assignment_operator(operator)
        || declaration_like_lhs(lhs, behavior)
        || identifiers.len() == 1
    {
        return identifiers;
    }

    Vec::new()
}

fn textual_local_reads(
    source: &str,
    local_names: &BTreeSet<String>,
    writes: &BTreeSet<String>,
) -> Vec<String> {
    if plain_string_literal_source(source) {
        return Vec::new();
    }

    identifiers_with_positions(source)
        .into_iter()
        .filter(|identifier| local_names.contains(&identifier.name))
        .filter(|identifier| !writes.contains(&identifier.name))
        .filter(|identifier| !member_name(source, identifier.start))
        .map(|identifier| identifier.name)
        .collect()
}

fn normalized_control_writes(node: &Node) -> Vec<String> {
    match node.r#type.as_str() {
        "FOR" => node
            .children
            .first()
            .and_then(ast::node)
            .into_iter()
            .flat_map(normalized_target_names)
            .collect(),
        _ => Vec::new(),
    }
}

fn normalized_target_names(node: &Node) -> Vec<String> {
    if matches!(node.r#type.as_str(), "LVAR" | "DVAR" | "LASGN" | "DASGN") {
        return local_read_name(node)
            .filter(|name| simple_identifier(name))
            .into_iter()
            .collect();
    }
    node.children
        .iter()
        .filter_map(ast::node)
        .flat_map(normalized_assignment_target_names)
        .collect()
}

/// Descends looking only for genuine assignment targets (LASGN/DASGN), not
/// bare reads. A bare LVAR/DVAR found directly as a for-loop's own init
/// clause (matched by `normalized_target_names` above, at the top level)
/// is a for-each-style loop variable and a legitimate write; the same node
/// type found while recursing through a *different* expression is just a
/// read. This distinction matters for a C-style `for (; cond; step)` with
/// an empty init clause: the loop's first child is then the *condition*
/// (e.g. `p != data + len`), and blindly harvesting every LVAR/DVAR found
/// while descending into it - as the old single-function recursion did -
/// misclassified every variable the condition merely reads (`data`, `len`)
/// as if the loop reassigned them.
fn normalized_assignment_target_names(node: &Node) -> Vec<String> {
    if matches!(node.r#type.as_str(), "LASGN" | "DASGN") {
        return local_read_name(node)
            .filter(|name| simple_identifier(name))
            .into_iter()
            .collect();
    }
    node.children
        .iter()
        .filter_map(ast::node)
        .flat_map(normalized_assignment_target_names)
        .collect()
}

fn plain_string_literal_source(source: &str) -> bool {
    let source = source.trim();
    if source.starts_with('f') || source.starts_with('F') {
        return false;
    }
    (source.starts_with("\"\"\"") && source.ends_with("\"\"\""))
        || (source.starts_with("'''") && source.ends_with("'''"))
        || (source.starts_with('"') && source.ends_with('"'))
        || (source.starts_with('\'') && source.ends_with('\''))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct IdentifierSpan {
    name: String,
    start: usize,
}

fn identifiers_with_positions(source: &str) -> Vec<IdentifierSpan> {
    let bytes = source.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        let has_prefix = if index + 5 <= bytes.len() && &bytes[index..index + 5] == b"self." {
            Some(5)
        } else if index + 5 <= bytes.len() && &bytes[index..index + 5] == b"this." {
            Some(5)
        } else if index + 6 <= bytes.len() && &bytes[index..index + 6] == b"self->" {
            Some(6)
        } else if index + 6 <= bytes.len() && &bytes[index..index + 6] == b"this->" {
            Some(6)
        } else if index + 7 <= bytes.len() && &bytes[index..index + 7] == b"$this->" {
            Some(7)
        } else {
            None
        };

        if let Some(prefix_len) = has_prefix {
            let start = index;
            let val_start = index + prefix_len;
            if val_start < bytes.len() && identifier_start(bytes[val_start]) {
                let mut end = val_start + 1;
                while end < bytes.len() && identifier_part(bytes[end]) {
                    end += 1;
                }
                out.push(IdentifierSpan {
                    name: source[start..end].to_string(),
                    start,
                });
                index = end;
                continue;
            }
        }

        let start = if bytes[index] == b'$' {
            let next = index + 1;
            if next < bytes.len() && identifier_start(bytes[next]) {
                next
            } else {
                index += 1;
                continue;
            }
        } else if bytes[index] == b'@' {
            let next = index + 1;
            let mut prefix_len = 1;
            if next < bytes.len() && bytes[next] == b'@' {
                prefix_len = 2;
            }
            let val_start = index + prefix_len;
            if val_start < bytes.len() && identifier_start(bytes[val_start]) {
                let mut end = val_start + 1;
                while end < bytes.len() && identifier_part(bytes[end]) {
                    end += 1;
                }
                out.push(IdentifierSpan {
                    name: source[index..end].to_string(),
                    start: index,
                });
                index = end;
                continue;
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
        if index + 1 < bytes.len() && bytes[index] == b':' && bytes[index + 1] == b'=' {
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

fn declaration_like_lhs(lhs: &str, behavior: &dyn NormalizedLanguageBehavior) -> bool {
    identifiers_with_positions(lhs)
        .first()
        .map(|identifier| behavior.local_flow_declaration_keyword(&identifier.name))
        .unwrap_or(false)
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

fn method_metadata(file: &str, functions: &[FunctionDef]) -> BTreeMap<Span, MethodMetadata> {
    functions
        .iter()
        .map(|function| (function.span, metadata_for_function(file, function)))
        .collect()
}

fn metadata_for_function(file: &str, function: &FunctionDef) -> MethodMetadata {
    MethodMetadata {
        owner: local_flow_owner(file, &function.owner),
        name: function.name.clone(),
        params: function.params.iter().cloned().collect(),
    }
}

fn local_flow_owner(file: &str, owner: &str) -> String {
    let file_owner = file_owner(file);
    if owner == file_owner {
        return "(top-level)".to_string();
    }
    owner
        .strip_prefix(&format!("{file_owner}::"))
        .unwrap_or(owner)
        .to_string()
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

fn symbol_child(child: &Child) -> Option<&str> {
    match child {
        Child::Symbol(value) | Child::String(value) => Some(value.as_str()),
        _ => None,
    }
}

struct BoundaryText {
    line: usize,
    kind: String,
    text: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::Language;

    #[test]
    fn test_empty_node() {
        let node = empty_node();
        assert_eq!(node.r#type, "ROOT");
        assert!(node.children.is_empty());
    }

    #[test]
    fn test_scan_documents_parallel() {
        let prev_jobs = parallel::job_count();
        parallel::set_jobs_for_process(Some(2)).unwrap();
        let mut doc1: Document =
            serde_json::from_str(r#"{"file":"a.rb","language":"ruby"}"#).unwrap();
        doc1.local_methods = vec![MethodSummary {
            id: "a".to_string(),
            owner: "A".to_string(),
            name: "foo".to_string(),
            file: "a.rb".to_string(),
            line: 10,
            span: [10, 0, 12, 0],
            node: empty_node(),
            statements: Vec::new(),
            boundaries: Vec::new(),
            params: BTreeSet::new(),
            param_types: BTreeMap::new(),
        }];

        let mut doc2: Document =
            serde_json::from_str(r#"{"file":"b.rb","language":"ruby"}"#).unwrap();
        doc2.local_methods = vec![MethodSummary {
            id: "b".to_string(),
            owner: "B".to_string(),
            name: "bar".to_string(),
            file: "b.rb".to_string(),
            line: 20,
            span: [20, 0, 22, 0],
            node: empty_node(),
            statements: Vec::new(),
            boundaries: Vec::new(),
            params: BTreeSet::new(),
            param_types: BTreeMap::new(),
        }];

        let methods = scan_documents(&[doc1, doc2]);
        assert_eq!(methods.len(), 2);
        parallel::set_jobs_for_process(Some(prev_jobs)).ok();
    }

    #[test]
    fn test_comment_boundaries() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec![
                "def foo".to_string(),
                "  x = 1".to_string(),
                "  # comment line".to_string(),
                "  y = 2".to_string(),
                "end".to_string(),
            ],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let boundary = detector.source_boundary(3, 3).unwrap();
        assert_eq!(boundary.kind, "comment");
        assert_eq!(boundary.text, "# comment line");
    }

    #[test]
    fn test_defs_method_name() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec!["def self.foo".to_string(), "def receiver.bar".to_string()],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let self_node = Node {
            r#type: "SELF".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 4,
            last_lineno: 1,
            last_column: 8,
            text: "self".to_string(),
        };
        let name_node1 = Child::Symbol("foo".to_string());
        let defs_node_self = Node {
            r#type: "DEFS".to_string(),
            children: vec![Child::Node(Box::new(self_node)), name_node1],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 12,
            text: "def self.foo".to_string(),
        };
        assert_eq!(detector.method_name(&defs_node_self), "foo");

        let receiver_node = Node {
            r#type: "IDENTIFIER".to_string(),
            children: Vec::new(),
            first_lineno: 2,
            first_column: 4,
            last_lineno: 2,
            last_column: 12,
            text: "receiver".to_string(),
        };
        let name_node2 = Child::Symbol("bar".to_string());
        let defs_node_rec = Node {
            r#type: "DEFS".to_string(),
            children: vec![Child::Node(Box::new(receiver_node)), name_node2],
            first_lineno: 2,
            first_column: 0,
            last_lineno: 2,
            last_column: 16,
            text: "def receiver.bar".to_string(),
        };
        assert_eq!(detector.method_name(&defs_node_rec), "receiver.bar");

        let normal_node = Node {
            r#type: "DEF".to_string(),
            children: vec![Child::Symbol("normal_method".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 10,
            text: "def normal_method".to_string(),
        };
        assert_eq!(detector.method_name(&normal_node), "normal_method");
    }

    #[test]
    fn test_owner_segment_empty() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec!["".to_string()],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let empty_node = Node {
            r#type: "CLASS".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(detector.owner_segment(&empty_node), "(anonymous)");
    }

    #[test]
    fn test_local_read_name_nil() {
        let node_nil = Node {
            r#type: "NIL_NODE".to_string(),
            children: vec![Child::Nil],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(local_read_name(&node_nil), Some(String::new()));

        let node_other = Node {
            r#type: "INT_NODE".to_string(),
            children: vec![Child::Integer(42)],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(local_read_name(&node_other), None);
    }

    #[test]
    fn test_textual_local_writes_edge_cases() {
        let behavior = crate::syntax::lua::behavior();
        // empty identifiers
        assert!(textual_local_writes("1 + 2", behavior).is_empty());

        // declaration like lhs
        assert!(declaration_like_lhs("local x", behavior));

        // simple_identifier check
        assert!(!simple_identifier("123foo"));

        // dollar sign not followed by start
        assert!(textual_local_writes("$ = 1", behavior).is_empty());

        // fallback path (+= with len > 1 LHS)
        assert!(textual_local_writes("a, b += 1", behavior).is_empty());

        // successful multiple identifier parse path
        assert_eq!(textual_local_writes("a, b = 1", behavior), vec!["a", "b"]);

        // first false, second true
        let lua_behavior = crate::syntax::lua::behavior();
        assert_eq!(
            textual_local_writes("local a, b := 1", lua_behavior),
            vec!["a", "b"]
        );

        // first false, second false, third true
        assert_eq!(textual_local_writes("a := 1", behavior), vec!["a"]);

        // first false, second false, third false
        assert!(textual_local_writes("a, b := 1", behavior).is_empty());
    }

    #[test]
    fn test_local_reads_push() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec!["x = y".to_string()],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let node = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Symbol("y".to_string())],
            first_lineno: 1,
            first_column: 4,
            last_lineno: 1,
            last_column: 5,
            text: "y".to_string(),
        };
        let mut local_names = BTreeSet::new();
        local_names.insert("y".to_string());
        let writes = BTreeSet::new();
        let reads = detector.local_reads(&node, &local_names, &writes);
        assert!(reads.contains("y"));

        let node_nil = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Nil],
            first_lineno: 1,
            first_column: 4,
            last_lineno: 1,
            last_column: 5,
            text: "nil_read".to_string(),
        };
        let reads_nil = detector.local_reads(&node_nil, &local_names, &writes);
        assert!(reads_nil.is_empty());

        let node_empty = Node {
            r#type: "LVAR".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 4,
            last_lineno: 1,
            last_column: 5,
            text: "empty_read".to_string(),
        };
        let reads_empty = detector.local_reads(&node_empty, &local_names, &writes);
        assert!(reads_empty.is_empty());
    }

    #[test]
    fn structural_reads_exclude_comment_only_identifiers() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec!["result = caps # outer_ref is illustrative".to_string()],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let rhs = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Symbol("caps".to_string())],
            first_lineno: 1,
            first_column: 9,
            last_lineno: 1,
            last_column: 13,
            text: "caps".to_string(),
        };
        let node = Node {
            r#type: "LASGN".to_string(),
            children: vec![
                Child::Symbol("result".to_string()),
                Child::Node(Box::new(rhs)),
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 41,
            text: "result = caps # outer_ref is illustrative".to_string(),
        };
        let local_names = BTreeSet::from([
            "caps".to_string(),
            "outer_ref".to_string(),
            "result".to_string(),
        ]);
        let writes = BTreeSet::from(["result".to_string()]);
        let reads = detector.local_reads(&node, &local_names, &writes);

        assert!(reads.contains("caps"));
        assert!(!reads.contains("outer_ref"));
    }

    #[test]
    fn test_assignment_dependencies_same() {
        let behavior = crate::syntax::ruby::behavior();
        let detector = LocalFlow::new(
            "foo.rb".to_string(),
            vec!["x = x".to_string()],
            BTreeMap::new(),
            BTreeMap::new(),
            behavior,
        );
        let rhs = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Symbol("x".to_string())],
            first_lineno: 1,
            first_column: 4,
            last_lineno: 1,
            last_column: 5,
            text: "x".to_string(),
        };
        let node = Node {
            r#type: "LASGN".to_string(),
            children: vec![Child::Symbol("x".to_string()), Child::Node(Box::new(rhs))],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 5,
            text: "x = x".to_string(),
        };
        let mut local_names = BTreeSet::new();
        local_names.insert("x".to_string());
        let deps = detector.assignment_dependencies(&node, &local_names);
        assert!(deps.is_empty());
    }

    #[test]
    fn test_symbol_child() {
        assert_eq!(symbol_child(&Child::Symbol("foo".to_string())), Some("foo"));
        assert_eq!(symbol_child(&Child::String("bar".to_string())), Some("bar"));
        assert_eq!(symbol_child(&Child::Nil), None);
    }

    // Real bug, found auditing wrk/src/ae_select.c's aeApiPoll: a bare
    // co-declared name with no initializer of its own
    // (`int retval, j, numevents = 0;`) has no assignment-shaped node, so
    // it normalizes as a plain identifier reference and got misread as a
    // *read* of the whole declaration statement - producing a false
    // "numevents derived from retval" dependency once retval was later
    // reassigned elsewhere in the function. retval/j must not appear as
    // reads of their own declaration line; numevents (the only declarator
    // with an initializer) is unaffected.
    #[test]
    fn multi_declarator_statement_does_not_read_its_own_bare_declarators() {
        use std::io::Write;
        let mut file = tempfile::Builder::new().suffix(".c").tempfile().unwrap();
        file.write_all(
            b"void run(void) {\n\
              \x20   int retval, j, numevents = 0;\n\
              \x20   retval = select_thing();\n\
              \x20   for (j = 0; j < 3; j++) {\n\
              \x20       numevents++;\n\
              \x20   }\n\
              \x20   return numevents;\n\
              }\n",
        )
        .unwrap();
        let summaries = scan_files(&[file.path().to_path_buf()], crate::syntax::Language::C).unwrap();
        let declaration = summaries[0]
            .statements
            .iter()
            .find(|statement| statement.source.contains("numevents = 0"))
            .expect("declaration statement");
        assert!(declaration.reads.is_empty(), "reads should be empty, got {:?}", declaration.reads);
        assert_eq!(declaration.writes, BTreeSet::from(["numevents".to_string()]));
        assert!(declaration.dependencies.is_empty());
    }

    // Real bug, found auditing requests/src/requests/adapters.py's
    // Session.send: a multi-line call whose receiver happens to start with
    // `self.` (`self.add_headers(request, stream=stream, ...)`) was read
    // as a `self.x = value` state write, because the is_state_write
    // exception (meant only to let a real dotted assignment target
    // through despite containing a `.`) also bypassed the parens/brackets
    // exclusion - so the call's first `=` (a keyword argument binding, not
    // an assignment) got treated as the statement's own reassignment.
    // request/stream must be plain reads of this call, not writes.
    #[test]
    fn call_with_self_prefixed_receiver_is_not_read_as_a_state_write() {
        use std::io::Write;
        let mut file = tempfile::Builder::new().suffix(".py").tempfile().unwrap();
        file.write_all(
            b"class Session:\n\
              \x20   def send(self, request, stream):\n\
              \x20       self.add_headers(\n\
              \x20           request,\n\
              \x20           stream=stream,\n\
              \x20       )\n",
        )
        .unwrap();
        let summaries = scan_files(&[file.path().to_path_buf()], crate::syntax::Language::Python).unwrap();
        let call_statement = summaries[0]
            .statements
            .iter()
            .find(|statement| statement.source.contains("add_headers"))
            .expect("call statement");
        assert!(
            call_statement.writes.is_empty(),
            "a call is not a state write, got {:?}",
            call_statement.writes
        );
        assert!(call_statement.dependencies.is_empty());
        assert!(call_statement.reads.contains("request"));
        assert!(call_statement.reads.contains("stream"));
    }

    // Real bug, found auditing wrk/src/http_parser.c's http_parser_execute:
    // a C-style `for (; cond; step)` with an empty init clause has the
    // *condition* as its first child (there is no init assignment to be
    // first instead), so recursively harvesting every LVAR/DVAR found
    // while descending into it - which normalized_target_names used to do
    // - treated every variable the condition merely reads as if the loop
    // reassigned it. `data`/`len` (read-only for the whole function) must
    // not appear as writes of a loop that only ever assigns its own
    // counter/state locals.
    #[test]
    fn empty_init_for_loop_does_not_write_variables_its_condition_only_reads() {
        use std::io::Write;
        let mut file = tempfile::Builder::new().suffix(".c").tempfile().unwrap();
        file.write_all(
            b"void run(const char *data, size_t len) {\n\
              \x20   const char *p = data;\n\
              \x20   for (; p != data + len; p++) {\n\
              \x20       char ch = *p;\n\
              \x20   }\n\
              }\n",
        )
        .unwrap();
        let summaries = scan_files(&[file.path().to_path_buf()], crate::syntax::Language::C).unwrap();
        let loop_statement = summaries[0]
            .statements
            .iter()
            .find(|statement| statement.source.starts_with("for ("))
            .expect("for-loop statement");
        assert!(
            !loop_statement.writes.contains("data") && !loop_statement.writes.contains("len"),
            "condition-only reads must not appear as writes, got {:?}",
            loop_statement.writes
        );
    }
}
