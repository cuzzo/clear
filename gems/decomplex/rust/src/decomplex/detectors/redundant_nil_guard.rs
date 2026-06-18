use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
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

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<RedundantNilGuardRow>> {
    let mut findings = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut scanner = RedundantNilGuard::new(file.to_string_lossy().to_string(), lines);
        scanner.walk(&root, &Vec::new());
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
    Ok(out)
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
        if recorded && node.r#type == "OPCALL" {
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
        match node.r#type.as_str() {
            "CALL" => {
                let recv = node.children.get(0).and_then(ast::node)?;
                let mid = match node.children.get(1)? {
                    Child::Symbol(s) => s,
                    _ => return None,
                };
                let args = node.children.get(2);
                if mid == "nil?" && (args.is_none() || matches!(args, Some(Child::Nil))) {
                    let subject = self.subject_key(recv)?;
                    return Some(NilFact {
                        local: subject,
                        non_nil_when_true: false,
                    });
                }
                None
            }
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
            "CALL" => {
                let recv = node.children.get(0).and_then(ast::node);
                let mid = match node.children.get(1)? {
                    Child::Symbol(s) => s,
                    _ => return None,
                };
                let args = node.children.get(2);
                if (args.is_none() || matches!(args, Some(Child::Nil)))
                    && self.stable_reader_name(mid)
                {
                    if let Some(recv) = recv {
                        if recv.r#type == "SELF" {
                            return Some(format!("self.{}", mid));
                        }
                        let recv_key = self.subject_key(recv)?;
                        return Some(format!("{}.{}", recv_key, mid));
                    }
                }
                None
            }
            _ => None,
        }
    }

    fn stable_reader_name(&self, mid: &str) -> bool {
        !(mid.ends_with('=') || mid.ends_with('!') || mid == "[]")
    }

    #[allow(dead_code)]
    fn local_name(&self, node: &Node) -> Option<String> {
        if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
            match node.children.first()? {
                Child::String(s) | Child::Symbol(s) => return Some(s.clone()),
                _ => {}
            }
        }
        None
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
        if !matches!(node.r#type.as_str(), "FCALL" | "VCALL" | "CALL") {
            return false;
        }

        let mid = if node.r#type == "CALL" {
            node.children.get(1).and_then(|c| match c {
                Child::Symbol(s) => Some(s.as_str()),
                _ => None,
            })
        } else {
            node.children.get(0).and_then(|c| match c {
                Child::Symbol(s) => Some(s.as_str()),
                _ => None,
            })
        };

        if let Some(mid) = mid {
            return TERMINATING_CALLS.contains(&mid);
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
