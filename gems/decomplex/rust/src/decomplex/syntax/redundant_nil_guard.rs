use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
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

const TERMINATING_CALLS: &[&str] = &["raise", "fail", "abort", "exit", "exit!"];
const NIL_PREDICATE_MIDS: &[&str] = &["nil?", "isNull", "is_null", "nil", "is_none"];
const NON_NIL_PREDICATE_MIDS: &[&str] = &["isSome", "is_some", "present", "present?"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<RedundantNilGuardRow>> {
    let documents = super::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<RedundantNilGuardRow> {
    let mut findings = Vec::new();
    for document in documents {
        let mut scanner = RedundantNilGuard::new(document.file.clone(), document.lines.clone());
        scanner.walk(&document.normalized_root, &Vec::new());
        findings.extend(scanner.findings);
    }
    let mut out: Vec<_> = findings.into_iter().map(|f| f.to_h()).collect();
    out.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.local.cmp(&b.local))
            .then_with(|| a.guard.cmp(&b.guard))
    });
    out
}

struct RedundantNilGuard {
    file: String,
    lines: Vec<String>,
    findings: Vec<Finding>,
}

impl RedundantNilGuard {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
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
        let cond = node.children.get(0).and_then(ast::node);
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
            let intersection: BTreeSet<_> = then_flow
                .known
                .intersection(&else_flow.known)
                .cloned()
                .collect();
            Flow {
                known: intersection,
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
        let local = self.redundant_nil_subject(node, known);
        let Some(local) = local else { return false };

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
        if known.contains(&fact.local) {
            return Some(fact.local);
        }
        None
    }

    fn nil_fact(&self, node: &Node) -> Option<NilFact> {
        if self.parenthesized_wrapper(node) {
            return self.nil_fact(self.first_node_child(node)?);
        }

        if let Some(call) = self.call_parts(node) {
            if call.no_args && NIL_PREDICATE_MIDS.contains(&call.message.as_str()) {
                let subject = self.subject_key(call.receiver?)?;
                return Some(NilFact {
                    local: subject,
                    non_nil_when_true: false,
                });
            }
            if call.no_args && NON_NIL_PREDICATE_MIDS.contains(&call.message.as_str()) {
                let subject = self.subject_key(call.receiver?)?;
                return Some(NilFact {
                    local: subject,
                    non_nil_when_true: true,
                });
            }
        }

        match node.r#type.as_str() {
            "OPCALL" => {
                let recv = node.children.get(0).and_then(ast::node)?;
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
                None
            }
            _ => None,
        }
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
            let mut facts = Vec::new();
            for child in ast::flatten_and(node) {
                facts.extend(self.branch_nil_facts(child, true));
            }
            return facts;
        }

        if node.r#type == "OPCALL" {
            if let Some(Child::Symbol(mid)) = node.children.get(1) {
                if mid == "!" {
                    if let Some(child) = node.children.get(0).and_then(ast::node) {
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
            let recv = node.children.get(0).and_then(ast::node)?;
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
        let recv = node.children.get(0).and_then(ast::node)?;
        let subject = self.subject_key(recv)?;
        if known.contains(&subject) {
            return Some(subject);
        }
        None
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

    fn call_parts<'a>(&self, node: &'a Node) -> Option<CallParts<'a>> {
        match node.r#type.as_str() {
            "CALL" => {
                let receiver = node.children.get(0).and_then(ast::node);
                let message = self.child_name(node.children.get(1)?)?;
                Some(CallParts {
                    receiver,
                    message,
                    no_args: self.no_call_arguments(node.children.get(2)),
                })
            }
            "METHOD_INVOCATION" => {
                let nodes = node
                    .children
                    .iter()
                    .filter_map(ast::node)
                    .collect::<Vec<_>>();
                let receiver = nodes.first().copied();
                let message = nodes.get(1).and_then(|child| self.node_name(child))?;
                Some(CallParts {
                    receiver,
                    message,
                    no_args: self.no_call_arguments(node.children.get(2)),
                })
            }
            "FUNCTION_CALL" | "METHOD_CALL" => {
                let callee = node.children.iter().filter_map(ast::node).next()?;
                let args = node
                    .children
                    .iter()
                    .skip(1)
                    .find(|child| matches!(child, Child::Node(n) if matches!(n.r#type.as_str(), "ARGUMENTS" | "ARGUMENT_LIST" | "LIST")));
                self.field_call_parts(callee, args)
            }
            "BLOCK" => {
                let callee = node.children.iter().filter_map(ast::node).next()?;
                let args = node
                    .children
                    .iter()
                    .skip(1)
                    .find(|child| matches!(child, Child::Node(n) if matches!(n.r#type.as_str(), "ARGUMENTS" | "ARGUMENT_LIST" | "LIST")));
                self.field_call_parts(callee, args)
            }
            "INVOCATION_EXPRESSION" => {
                let callee = node.children.iter().filter_map(ast::node).next()?;
                let mut parts = self.call_parts(callee)?;
                let args = node
                    .children
                    .iter()
                    .skip(1)
                    .find(|child| matches!(child, Child::Node(n) if matches!(n.r#type.as_str(), "ARGUMENTS" | "ARGUMENT_LIST" | "LIST")));
                parts.no_args = self.no_call_arguments(args);
                Some(parts)
            }
            _ => None,
        }
    }

    fn field_call_parts<'a>(
        &self,
        node: &'a Node,
        args: Option<&'a Child>,
    ) -> Option<CallParts<'a>> {
        if !matches!(
            node.r#type.as_str(),
            "DOT_INDEX_EXPRESSION"
                | "FIELD_EXPRESSION"
                | "FIELD_ACCESS"
                | "MEMBER_EXPRESSION"
                | "CALL"
        ) {
            return self.call_parts(node);
        }
        let nodes = node
            .children
            .iter()
            .filter_map(ast::node)
            .collect::<Vec<_>>();
        let receiver = nodes.first().copied();
        let message = nodes.last().and_then(|child| self.node_name(child))?;
        Some(CallParts {
            receiver,
            message,
            no_args: self.no_call_arguments(args),
        })
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

    fn first_node_child<'a>(&self, node: &'a Node) -> Option<&'a Node> {
        node.children.iter().find_map(ast::node)
    }

    fn stable_reader_name(&self, mid: &str) -> bool {
        !(mid.ends_with('=') || mid.ends_with('!') || mid == "[]")
    }

    fn nil_arg(&self, args: Option<&Child>) -> bool {
        let Some(Child::Node(node)) = args else {
            return false;
        };
        if node.r#type != "LIST" {
            return false;
        }
        node.children.iter().any(|c| match c {
            Child::Node(n) => n.r#type == "NIL",
            Child::Nil => true,
            _ => false,
        })
    }

    fn stmts_for<'a>(&self, node: Option<&'a Node>) -> Vec<&'a Node> {
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
        if !matches!(node.r#type.as_str(), "FCALL" | "VCALL" | "CALL")
            && self.call_parts(node).is_none()
        {
            return false;
        }

        let mid = if let Some(call) = self.call_parts(node) {
            Some(call.message)
        } else if node.r#type == "CALL" {
            node.children.get(1).and_then(|c| match c {
                Child::String(s) | Child::Symbol(s) => Some(s.clone()),
                _ => None,
            })
        } else {
            node.children.get(0).and_then(|c| match c {
                Child::String(s) | Child::Symbol(s) => Some(s.clone()),
                _ => None,
            })
        };

        if let Some(mid) = mid {
            return TERMINATING_CALLS.contains(&mid.as_str());
        }
        false
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
