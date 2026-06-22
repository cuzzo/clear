use crate::ast::{self, Child, Node, Span};
use crate::syntax::normalized_behavior::NormalizedLanguageBehavior;
use crate::syntax::{Document, Language};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct RedundantNilGuardRow {
    pub at: String,
    pub file: String,
    pub defn: String,
    pub line: usize,
    pub span: Span,
    pub local: String,
    pub guard: String,
    pub proof: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Flow {
    known: BTreeSet<String>,
    terminated: bool,
}

#[derive(Clone, Debug)]
struct NilFact {
    local: String,
    non_nil_when_true: bool,
}

struct CallParts<'a> {
    receiver: Option<&'a Node>,
    message: String,
    no_args: bool,
}

struct Finding {
    file: String,
    defn: String,
    line: usize,
    span: Span,
    local: String,
    guard: String,
    proof: String,
}

impl Finding {
    fn to_h(&self) -> RedundantNilGuardRow {
        let loc = format!("{}:{}:{}", self.file, self.defn, self.line);
        let mut spans = BTreeMap::new();
        spans.insert(loc.clone(), self.span);
        RedundantNilGuardRow {
            at: loc,
            file: self.file.clone(),
            defn: self.defn.clone(),
            line: self.line,
            span: self.span,
            local: self.local.clone(),
            guard: self.guard.clone(),
            proof: self.proof.clone(),
            spans,
        }
    }
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<RedundantNilGuardRow>> {
    let documents = super::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<RedundantNilGuardRow> {
    let mut out = documents
        .iter()
        .flat_map(|document| document.redundant_nil_guards.clone())
        .collect::<Vec<_>>();
    sort_rows(&mut out);
    out
}

pub(crate) fn scan_normalized(
    file: &str,
    lines: &[String],
    root: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Vec<RedundantNilGuardRow> {
    let mut scanner = RedundantNilGuard::new(file.to_string(), lines.to_vec(), behavior);
    scanner.walk(root, &Vec::new());
    let mut out = scanner
        .findings
        .into_iter()
        .map(|finding| finding.to_h())
        .collect::<Vec<_>>();
    sort_rows(&mut out);
    out
}

fn sort_rows(rows: &mut [RedundantNilGuardRow]) {
    rows.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.local.cmp(&b.local))
            .then_with(|| a.guard.cmp(&b.guard))
    });
}

struct RedundantNilGuard<'a> {
    file: String,
    lines: Vec<String>,
    behavior: &'a dyn NormalizedLanguageBehavior,
    findings: Vec<Finding>,
}

impl<'a> RedundantNilGuard<'a> {
    fn new(file: String, lines: Vec<String>, behavior: &'a dyn NormalizedLanguageBehavior) -> Self {
        Self {
            file,
            lines,
            behavior,
            findings: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                let mut next_defstack = defstack.to_vec();
                next_defstack.push(name.clone());
                self.process_block(&ast::body_stmts(node), &next_defstack, &BTreeSet::new());
            }
            return;
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, defstack);
        }
    }

    fn process_block(
        &mut self,
        stmts: &[&Node],
        defstack: &[String],
        known: &BTreeSet<String>,
    ) -> Flow {
        let mut current = known.clone();
        for stmt in stmts {
            let flow = self.process_stmt(stmt, defstack, &current);
            current = flow.known;
            if flow.terminated {
                return Flow {
                    known: current,
                    terminated: true,
                };
            }
        }
        Flow {
            known: current,
            terminated: false,
        }
    }

    fn process_stmt(&mut self, node: &Node, defstack: &[String], known: &BTreeSet<String>) -> Flow {
        match node.r#type.as_str() {
            "IF" | "UNLESS" => self.process_branch(node, defstack, known),
            "LASGN" => {
                if let Some(rhs) = node.children.get(1).and_then(ast::node) {
                    self.inspect_node(rhs, defstack, known);
                }
                let mut next_known = known.clone();
                if let Some(Child::String(name)) = node.children.first() {
                    next_known.remove(name);
                }
                Flow {
                    known: next_known,
                    terminated: false,
                }
            }
            _ => {
                self.inspect_node(node, defstack, known);
                Flow {
                    known: known.clone(),
                    terminated: self.terminating(node),
                }
            }
        }
    }

    fn process_branch(
        &mut self,
        node: &Node,
        defstack: &[String],
        known: &BTreeSet<String>,
    ) -> Flow {
        let cond = node.children.first().and_then(ast::node);
        let then_body = node.children.get(1).and_then(ast::node);
        let else_body = node.children.get(2).and_then(ast::node);

        if let Some(cond) = cond {
            self.inspect_node(cond, defstack, known);
        }

        let then_known = self.known_for_branch(node.r#type.as_str(), true, cond, known);
        let else_known = self.known_for_branch(node.r#type.as_str(), false, cond, known);

        let then_flow = self.process_block(&self.stmts_for(then_body), defstack, &then_known);
        let else_flow = self.process_block(&self.stmts_for(else_body), defstack, &else_known);

        if then_flow.terminated && else_flow.terminated {
            Flow {
                known: BTreeSet::new(),
                terminated: true,
            }
        } else if then_flow.terminated {
            Flow {
                known: else_flow.known,
                terminated: false,
            }
        } else if else_flow.terminated {
            Flow {
                known: then_flow.known,
                terminated: false,
            }
        } else {
            Flow {
                known: then_flow
                    .known
                    .intersection(&else_flow.known)
                    .cloned()
                    .collect(),
                terminated: false,
            }
        }
    }

    fn known_for_branch(
        &self,
        node_type: &str,
        body_branch: bool,
        cond: Option<&Node>,
        known: &BTreeSet<String>,
    ) -> BTreeSet<String> {
        let mut next_known = known.clone();
        let cond_true_branch = if node_type == "IF" {
            body_branch
        } else {
            !body_branch
        };
        if let Some(cond) = cond {
            for fact in self.branch_nil_facts(cond, cond_true_branch) {
                next_known.insert(fact.local);
            }
        }
        next_known
    }

    fn inspect_node(&mut self, node: &Node, defstack: &[String], known: &BTreeSet<String>) {
        let recorded = self.record_redundant(node, defstack, known);
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            return;
        }
        if recorded && (node.r#type == "OPCALL" || self.call_parts(node).is_some()) {
            return;
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.inspect_node(child, defstack, known);
        }
    }

    fn record_redundant(
        &mut self,
        node: &Node,
        defstack: &[String],
        known: &BTreeSet<String>,
    ) -> bool {
        let Some(local) = self.redundant_nil_subject(node, known) else {
            return false;
        };

        let defn = defstack.last().map(|s| s.as_str()).unwrap_or("(top-level)");
        self.findings.push(Finding {
            file: self.file.clone(),
            defn: defn.to_string(),
            line: node.first_lineno,
            span: self.span(node),
            local: local.clone(),
            guard: ast::slice(node, &self.lines),
            proof: format!("{} is already proven non-nil on this path", local),
        });
        true
    }

    fn redundant_nil_subject(&self, node: &Node, known: &BTreeSet<String>) -> Option<String> {
        if node.r#type == "QCALL" {
            return self.qcall_subject(node, known);
        }

        let fact = self.nil_fact(node)?;
        known.contains(&fact.local).then_some(fact.local)
    }

    fn nil_fact(&self, node: &Node) -> Option<NilFact> {
        if self.parenthesized_wrapper(node) {
            return self.nil_fact(self.first_node_child(node)?);
        }

        if let Some(call) = self.call_parts(node) {
            if call.no_args {
                let subject = self.subject_key(call.receiver?)?;
                return self
                    .behavior
                    .nil_guard_fact(&call.message, &subject)
                    .map(|fact| NilFact {
                        local: fact.local,
                        non_nil_when_true: fact.non_nil_when_true,
                    });
            }
        }

        if node.r#type == "OPCALL" {
            let recv = node.children.first().and_then(ast::node)?;
            let mid = match node.children.get(1)? {
                Child::Symbol(s) => s,
                _ => return None,
            };
            let args = node.children.get(2);
            if mid == "!" {
                return self.negated_nil_fact(recv);
            }
            if mid == "==" || mid == "!=" {
                return self.comparison_nil_fact(recv, mid, args);
            }
        }
        None
    }

    fn branch_nil_facts(&self, node: &Node, cond_truth: bool) -> Vec<NilFact> {
        if self.parenthesized_wrapper(node) {
            if let Some(child) = self.first_node_child(node) {
                return self.branch_nil_facts(child, cond_truth);
            }
        }

        if node.r#type == "AND" {
            if !cond_truth {
                return Vec::new();
            }
            return ast::flatten_and(node)
                .into_iter()
                .flat_map(|child| self.branch_nil_facts(child, true))
                .collect();
        }

        if node.r#type == "OPCALL" {
            if let Some(Child::Symbol(mid)) = node.children.get(1) {
                if mid == "!" {
                    if let Some(child) = node.children.first().and_then(ast::node) {
                        return self.branch_nil_facts(child, !cond_truth);
                    }
                }
            }
        }

        if let Some(safe_receiver) = self.safe_nav_receiver_fact(node) {
            if cond_truth {
                return vec![safe_receiver];
            }
        }

        if let Some(fact) = self.nil_fact(node) {
            if cond_truth == fact.non_nil_when_true {
                return vec![fact];
            }
        }

        if let Some(truthy) = self.truthy_subject_fact(node) {
            if cond_truth {
                return vec![truthy];
            }
        }

        Vec::new()
    }

    fn safe_nav_receiver_fact(&self, node: &Node) -> Option<NilFact> {
        if node.r#type == "QCALL" {
            let recv = node.children.first().and_then(ast::node)?;
            let subject = self.subject_key(recv)?;
            return Some(NilFact {
                local: subject,
                non_nil_when_true: true,
            });
        }
        None
    }

    fn truthy_subject_fact(&self, node: &Node) -> Option<NilFact> {
        let subject = self.subject_key(node)?;
        Some(NilFact {
            local: subject,
            non_nil_when_true: true,
        })
    }

    fn negated_nil_fact(&self, node: &Node) -> Option<NilFact> {
        let mut fact = self.nil_fact(node)?;
        fact.non_nil_when_true = !fact.non_nil_when_true;
        Some(fact)
    }

    fn comparison_nil_fact(&self, recv: &Node, mid: &str, args: Option<&Child>) -> Option<NilFact> {
        let subject = self.subject_key(recv)?;
        if !self.nil_arg(args) {
            return None;
        }
        Some(NilFact {
            local: subject,
            non_nil_when_true: mid == "!=",
        })
    }

    fn qcall_subject(&self, node: &Node, known: &BTreeSet<String>) -> Option<String> {
        let recv = node.children.first().and_then(ast::node)?;
        let subject = self.subject_key(recv)?;
        known.contains(&subject).then_some(subject)
    }

    fn subject_key(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" | "VCALL" => match node.children.first()? {
                Child::String(s) | Child::Symbol(s) => Some(s.clone()),
                _ => None,
            },
            _ if self.call_parts(node).is_some() => {
                let call = self.call_parts(node)?;
                if !call.no_args || !self.stable_reader_name(&call.message) {
                    return None;
                }
                let recv = call.receiver?;
                if recv.r#type == "SELF" {
                    return Some(format!("self.{}", call.message));
                }
                let recv_key = self.subject_key(recv)?;
                Some(format!("{}.{}", recv_key, call.message))
            }
            _ => None,
        }
    }

    fn call_parts<'node>(&self, node: &'node Node) -> Option<CallParts<'node>> {
        match node.r#type.as_str() {
            "CALL" | "QCALL" => {
                let receiver = node.children.first().and_then(ast::node);
                let message = self.child_name(node.children.get(1)?)?;
                Some(CallParts {
                    receiver,
                    message,
                    no_args: self.no_call_arguments(node.children.get(2)),
                })
            }
            "FCALL" | "VCALL" => {
                let message = self.child_name(node.children.first()?)?;
                Some(CallParts {
                    receiver: None,
                    message,
                    no_args: self.no_call_arguments(node.children.get(1)),
                })
            }
            _ => None,
        }
    }

    fn child_name(&self, child: &Child) -> Option<String> {
        match child {
            Child::String(s) | Child::Symbol(s) => Some(s.clone()),
            Child::Node(node) => self.node_name(node),
            _ => None,
        }
    }

    fn node_name(&self, node: &Node) -> Option<String> {
        match node.children.first() {
            Some(Child::String(s)) | Some(Child::Symbol(s)) => Some(s.clone()),
            _ => {
                let text = ast::slice(node, &self.lines).trim().to_string();
                (!text.is_empty()).then_some(text)
            }
        }
    }

    fn no_call_arguments(&self, args: Option<&Child>) -> bool {
        match args {
            None | Some(Child::Nil) => true,
            Some(Child::Node(node)) => {
                !node.children.iter().any(|child| ast::node(child).is_some())
            }
            Some(_) => false,
        }
    }

    fn parenthesized_wrapper(&self, node: &Node) -> bool {
        matches!(
            node.r#type.as_str(),
            "CONDITION_CLAUSE" | "PARENTHESIZED_EXPRESSION" | "PARENTHESIZED_STATEMENTS"
        ) && self.first_node_child(node).is_some()
    }

    fn first_node_child<'node>(&self, node: &'node Node) -> Option<&'node Node> {
        node.children.iter().find_map(ast::node)
    }

    fn stable_reader_name(&self, mid: &str) -> bool {
        !(mid.ends_with('=') || mid.ends_with('!') || mid == "[]")
    }

    fn nil_arg(&self, args: Option<&Child>) -> bool {
        let Some(Child::Node(node)) = args else {
            return false;
        };
        node.r#type == "LIST"
            && node.children.iter().any(|child| match child {
                Child::Node(node) => node.r#type == "NIL",
                Child::Nil => true,
                _ => false,
            })
    }

    fn stmts_for<'node>(&self, node: Option<&'node Node>) -> Vec<&'node Node> {
        let Some(node) = node else { return Vec::new() };
        if self.call_parts(node).is_some() {
            return vec![node];
        }
        if node.r#type == "BLOCK" {
            node.children.iter().filter_map(ast::node).collect()
        } else {
            vec![node]
        }
    }

    fn terminating(&self, node: &Node) -> bool {
        if matches!(node.r#type.as_str(), "RETURN" | "NEXT" | "BREAK") {
            return true;
        }
        let message = self.call_parts(node).map(|call| call.message);
        message
            .as_deref()
            .is_some_and(|message| self.behavior.terminating_call_message(message))
    }

    fn span(&self, node: &Node) -> Span {
        [
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ]
    }
}
