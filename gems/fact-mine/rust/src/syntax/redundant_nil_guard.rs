use crate::ast::{self, Child, Node, RawNode, Span};
use crate::syntax::adapters::{language_profile, LanguageProfile};
use crate::syntax::raw_tree::{
    child_by_field as raw_child_by_field, named_children as raw_named_children,
};
use crate::syntax::{Document, Language};
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

struct RawCallParts<'a> {
    receiver: Option<&'a RawNode>,
    message: String,
    no_args: bool,
    safe_navigation: bool,
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
        if !document.function_defs.is_empty() && document.normalized_root.children.is_empty() {
            let mut scanner = RawRedundantNilGuard::new(document);
            scanner.scan();
            findings.extend(scanner.findings);
        } else {
            let mut scanner = RedundantNilGuard::new(document.file.clone(), document.lines.clone());
            scanner.walk(&document.normalized_root, &Vec::new());
            findings.extend(scanner.findings);
        }
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

struct RawRedundantNilGuard<'a> {
    document: &'a Document,
    profile: &'static dyn LanguageProfile,
    findings: Vec<Finding>,
}

impl<'a> RawRedundantNilGuard<'a> {
    fn new(document: &'a Document) -> Self {
        Self {
            document,
            profile: language_profile(document.language),
            findings: Vec::new(),
        }
    }

    fn scan(&mut self) {
        for function in &self.document.function_defs {
            let statements = self.method_statements(&function.body);
            self.process_block(&statements, &function.name, &BTreeSet::new());
        }
    }

    fn process_block(
        &mut self,
        stmts: &[&RawNode],
        function: &str,
        known: &BTreeSet<String>,
    ) -> Flow {
        let mut current = known.clone();
        for stmt in stmts {
            let flow = self.process_stmt(stmt, function, &current);
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

    fn process_stmt(&mut self, node: &RawNode, function: &str, known: &BTreeSet<String>) -> Flow {
        if self.if_node(node) {
            return self.process_branch(node, function, known);
        }

        if self.assignment_node(node) {
            if let Some(rhs) = self.assignment_rhs(node) {
                self.inspect_node(rhs, function, known);
            }
            let mut next_known = known.clone();
            if let Some(name) = self.assignment_lhs_name(node) {
                next_known.remove(&name);
            }
            return Flow {
                known: next_known,
                terminated: false,
            };
        }

        self.inspect_node(node, function, known);
        Flow {
            known: known.clone(),
            terminated: self.terminating(node),
        }
    }

    fn process_branch(&mut self, node: &RawNode, function: &str, known: &BTreeSet<String>) -> Flow {
        let cond = self.branch_condition(node);
        if let Some(cond) = cond {
            self.inspect_node(cond, function, known);
        }

        let then_known = self.known_for_branch(node, true, cond, known);
        let else_known = self.known_for_branch(node, false, cond, known);
        let then_body = self.branch_then_body(node);
        let else_body = self.branch_else_body(node);
        let then_stmts = self.stmts_for(then_body);
        let else_stmts = self.stmts_for(else_body);
        let then_flow = self.process_block(&then_stmts, function, &then_known);
        let else_flow = self.process_block(&else_stmts, function, &else_known);

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
            let intersection = then_flow
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
        node: &RawNode,
        body_branch: bool,
        cond: Option<&RawNode>,
        known: &BTreeSet<String>,
    ) -> BTreeSet<String> {
        let mut next_known = known.clone();
        let cond_true_branch = if self.unless_node(node) {
            !body_branch
        } else {
            body_branch
        };
        if let Some(cond) = cond {
            for fact in self.branch_nil_facts(cond, cond_true_branch) {
                next_known.insert(fact.local);
            }
        }
        next_known
    }

    fn inspect_node(&mut self, node: &RawNode, function: &str, known: &BTreeSet<String>) {
        let recorded = self.record_redundant(node, function, known);
        if self.nested_local_scope(node) {
            return;
        }
        if recorded && (self.call_parts(node).is_some() || self.safe_navigation_call(node)) {
            return;
        }
        for child in raw_named_children(node) {
            self.inspect_node(child, function, known);
        }
    }

    fn record_redundant(
        &mut self,
        node: &RawNode,
        function: &str,
        known: &BTreeSet<String>,
    ) -> bool {
        let Some(local) = self.redundant_nil_subject(node, known) else {
            return false;
        };
        self.findings.push(Finding {
            file: self.document.file.clone(),
            defn: function.to_string(),
            line: node.span[0],
            span: node.span,
            local: local.clone(),
            guard: self.profile.normalize_source_text(&node.text),
            proof: format!("{local} is already proven non-nil on this path"),
        });
        true
    }

    fn redundant_nil_subject(&self, node: &RawNode, known: &BTreeSet<String>) -> Option<String> {
        let subject = self.safe_navigation_subject(node);
        if subject
            .as_ref()
            .map(|local| known.contains(local))
            .unwrap_or(false)
        {
            return subject;
        }
        let fact = self.nil_fact(node)?;
        known.contains(&fact.local).then_some(fact.local)
    }

    fn nil_fact(&self, node: &RawNode) -> Option<NilFact> {
        let node = self.unwrap_parenthesized(node);
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
            if NIL_PREDICATE_MIDS.contains(&call.message.as_str()) {
                if let Some(subject) = self.first_argument_subject(node) {
                    return Some(NilFact {
                        local: subject,
                        non_nil_when_true: false,
                    });
                }
            }
        }
        if self.unary_not(node) {
            let child = raw_named_children(node).into_iter().next()?;
            return self.negated_nil_fact(child);
        }
        self.comparison_nil_fact(node)
    }

    fn branch_nil_facts(&self, node: &RawNode, cond_truth: bool) -> Vec<NilFact> {
        let node = self.unwrap_parenthesized(node);
        if self.boolean_and(node) {
            if !cond_truth {
                return Vec::new();
            }
            return self
                .flatten_boolean_and(node)
                .into_iter()
                .flat_map(|child| self.branch_nil_facts(child, true))
                .collect();
        }
        if self.unary_not(node) {
            if let Some(child) = raw_named_children(node).into_iter().next() {
                return self.branch_nil_facts(child, !cond_truth);
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
            return Vec::new();
        }
        if let Some(truthy) = self.truthy_subject_fact(node) {
            if cond_truth {
                return vec![truthy];
            }
        }
        Vec::new()
    }

    fn safe_nav_receiver_fact(&self, node: &RawNode) -> Option<NilFact> {
        let subject = self.safe_navigation_subject(node)?;
        Some(NilFact {
            local: subject,
            non_nil_when_true: true,
        })
    }

    fn truthy_subject_fact(&self, node: &RawNode) -> Option<NilFact> {
        let subject = self.subject_key(node)?;
        Some(NilFact {
            local: subject,
            non_nil_when_true: true,
        })
    }

    fn negated_nil_fact(&self, node: &RawNode) -> Option<NilFact> {
        let mut fact = self.nil_fact(node)?;
        fact.non_nil_when_true = !fact.non_nil_when_true;
        Some(fact)
    }

    fn comparison_nil_fact(&self, node: &RawNode) -> Option<NilFact> {
        let node = self.unwrap_parenthesized(node);
        if !self
            .profile
            .comparison_node_kinds()
            .contains(&node.kind.as_str())
        {
            return None;
        }
        let operator = self.direct_operator(node);
        if !matches!(operator.as_deref(), Some("==" | "!=" | "===" | "!==")) {
            return None;
        }
        let named = raw_named_children(node);
        let left = named.first().copied()?;
        let right = named.get(1).copied()?;
        let subject = if self.nil_literal(right) {
            self.subject_key(left)
        } else if self.nil_literal(left) {
            self.subject_key(right)
        } else {
            None
        }?;
        Some(NilFact {
            local: subject,
            non_nil_when_true: matches!(operator.as_deref(), Some("!=" | "!==")),
        })
    }

    fn safe_navigation_subject(&self, node: &RawNode) -> Option<String> {
        if !self.safe_navigation_call(node) {
            return None;
        }
        self.call_parts(node)
            .and_then(|call| call.receiver)
            .and_then(|receiver| self.subject_key(receiver))
    }

    fn subject_key(&self, node: &RawNode) -> Option<String> {
        let node = self.unwrap_parenthesized(node);
        let text = node.text.trim();
        if matches!(node.kind.as_str(), "self" | "this") || text == "self" || text == "this" {
            return Some("self".to_string());
        }
        if self.simple_subject_identifier(node) {
            let name = self.profile.normalize_local_identifier_text(text);
            if self.nil_literal_text(&name) || name.is_empty() {
                return None;
            }
            return Some(name);
        }
        if let Some(call) = self.call_parts(node) {
            if !call.no_args || !self.stable_reader_name(&call.message) {
                return None;
            }
            let receiver = call.receiver?;
            if self.self_node(receiver) {
                return Some(format!("self.{}", call.message));
            }
            let recv_key = self.subject_key(receiver)?;
            return Some(format!("{}.{}", recv_key, call.message));
        }
        if self
            .profile
            .field_like_node_kinds()
            .contains(&node.kind.as_str())
        {
            let receiver = self.raw_receiver_node(node)?;
            let message = self.raw_member_node(node)?;
            let message = self.profile.normalize_local_identifier_text(&message.text);
            if !self.stable_reader_name(&message) {
                return None;
            }
            let recv_key = self.subject_key(receiver)?;
            return Some(format!("{}.{}", recv_key, message));
        }
        None
    }

    fn call_parts<'n>(&self, node: &'n RawNode) -> Option<RawCallParts<'n>> {
        if !self.profile.call_node_kinds().contains(&node.kind.as_str())
            && !self
                .profile
                .field_like_node_kinds()
                .contains(&node.kind.as_str())
        {
            return None;
        }

        let args = self.raw_arguments_node(node);
        let receiver = self.raw_receiver_node(node);
        let message_node = self
            .raw_member_node(node)
            .or_else(|| self.raw_callee_node(node))
            .or_else(|| raw_named_children(node).into_iter().last())?;
        let message = self
            .profile
            .normalize_local_identifier_text(message_node.text.trim());
        if message.is_empty() {
            return None;
        }
        Some(RawCallParts {
            receiver,
            message,
            no_args: self.no_call_arguments(args),
            safe_navigation: self.safe_navigation_text(&node.text),
        })
    }

    fn first_argument_subject(&self, node: &RawNode) -> Option<String> {
        let args = self.raw_arguments_node(node)?;
        raw_named_children(args)
            .into_iter()
            .find_map(|arg| self.subject_key(arg))
    }

    fn method_statements<'n>(&self, node: &'n RawNode) -> Vec<&'n RawNode> {
        let Some(body) = self.method_body_node(node) else {
            return Vec::new();
        };
        self.stmts_for(Some(body))
    }

    fn method_body_node<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        if let Some(body) = raw_child_by_field(node, "body") {
            return Some(body);
        }
        raw_named_children(node).into_iter().rev().find(|child| {
            self.profile
                .function_body_node_kinds()
                .contains(&child.kind.as_str())
        })
    }

    fn stmts_for<'n>(&self, node: Option<&'n RawNode>) -> Vec<&'n RawNode> {
        let Some(node) = node else { return Vec::new() };
        if self.if_node(node) || self.assignment_node(node) || self.call_parts(node).is_some() {
            return vec![node];
        }

        let mut named = raw_named_children(node)
            .into_iter()
            .filter(|child| !self.ignored_child(child))
            .collect::<Vec<_>>();
        if named.len() == 1
            && self
                .profile
                .nested_statement_wrapper_node_kinds()
                .contains(&named[0].kind.as_str())
        {
            if self.if_node(named[0]) {
                return vec![named[0]];
            }
            named = raw_named_children(named[0])
                .into_iter()
                .filter(|child| !self.ignored_child(child))
                .collect();
        }
        if named.is_empty() && !node.text.trim().is_empty() {
            return vec![node];
        }
        named
    }

    fn if_node(&self, node: &RawNode) -> bool {
        if matches!(
            node.kind.as_str(),
            "if" | "unless" | "if_statement" | "if_expression" | "if_modifier" | "unless_modifier"
        ) && !raw_named_children(node).is_empty()
        {
            return true;
        }
        if matches!(
            node.kind.as_str(),
            "body_statement" | "block" | "statements" | "statement_list" | "expression_statement"
        ) {
            let first = node.children.first();
            if first
                .map(|child| !child.named && matches!(child.kind.as_str(), "if" | "unless"))
                .unwrap_or(false)
            {
                return true;
            }
            return self.hidden_modifier_if(node);
        }
        false
    }

    fn unless_node(&self, node: &RawNode) -> bool {
        node.kind.contains("unless")
            || node
                .children
                .first()
                .map(|child| child.kind == "unless" || child.text == "unless")
                .unwrap_or(false)
            || self
                .modifier_keyword(node)
                .map(|keyword| keyword == "unless")
                .unwrap_or(false)
    }

    fn modifier_if_node(&self, node: &RawNode) -> bool {
        matches!(node.kind.as_str(), "if_modifier" | "unless_modifier")
            || self.hidden_modifier_if(node)
    }

    fn hidden_modifier_if(&self, node: &RawNode) -> bool {
        let mut seen_named = false;
        node.children.iter().any(|child| {
            seen_named |= child.named;
            seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless")
        })
    }

    fn modifier_keyword<'n>(&self, node: &'n RawNode) -> Option<&'n str> {
        let mut seen_named = false;
        for child in &node.children {
            seen_named |= child.named;
            if seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless") {
                return Some(child.kind.as_str());
            }
        }
        None
    }

    fn branch_condition<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        if self.modifier_if_node(node) {
            return raw_named_children(node).into_iter().last();
        }
        raw_child_by_field(node, "condition")
            .or_else(|| raw_child_by_field(node, "value"))
            .or_else(|| raw_child_by_field(node, "subject"))
            .or_else(|| raw_named_children(node).into_iter().next())
    }

    fn branch_then_body<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        if self.modifier_if_node(node) {
            return raw_named_children(node).into_iter().next();
        }
        raw_child_by_field(node, "consequence")
            .or_else(|| raw_child_by_field(node, "body"))
            .or_else(|| {
                raw_named_children(node)
                    .into_iter()
                    .find(|child| child.kind == "then")
            })
            .or_else(|| raw_named_children(node).into_iter().nth(1))
    }

    fn branch_else_body<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        if self.modifier_if_node(node) {
            return None;
        }
        raw_child_by_field(node, "alternative")
            .or_else(|| {
                raw_named_children(node)
                    .into_iter()
                    .find(|child| matches!(child.kind.as_str(), "else" | "elsif"))
            })
            .or_else(|| raw_named_children(node).into_iter().nth(2))
    }

    fn assignment_node(&self, node: &RawNode) -> bool {
        self.profile
            .assignment_node_kinds()
            .contains(&node.kind.as_str())
            || node.children.iter().any(|child| {
                !child.named
                    && self
                        .profile
                        .assignment_operator_tokens()
                        .contains(&child.text.as_str())
            })
    }

    fn assignment_lhs_name(&self, node: &RawNode) -> Option<String> {
        let lhs = self.assignment_lhs(node)?;
        self.simple_subject_identifier(lhs).then(|| {
            self.profile
                .normalize_local_identifier_text(lhs.text.trim())
        })
    }

    fn assignment_lhs<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        self.assignment_node(node)
            .then(|| raw_named_children(node).into_iter().next())
            .flatten()
    }

    fn assignment_rhs<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        self.assignment_node(node)
            .then(|| raw_named_children(node).into_iter().nth(1))
            .flatten()
    }

    fn boolean_and(&self, node: &RawNode) -> bool {
        let node = self.unwrap_parenthesized(node);
        (self
            .profile
            .boolean_container_node_kinds()
            .contains(&node.kind.as_str())
            || self
                .profile
                .boolean_wrapper_node_kinds()
                .contains(&node.kind.as_str()))
            && self
                .direct_operator(node)
                .map(|operator| {
                    self.profile
                        .boolean_and_operators()
                        .contains(&operator.as_str())
                })
                .unwrap_or(false)
            && raw_named_children(node).len() >= 2
    }

    fn flatten_boolean_and<'n>(&self, node: &'n RawNode) -> Vec<&'n RawNode> {
        if !self.boolean_and(node) {
            return vec![node];
        }
        raw_named_children(node)
            .into_iter()
            .flat_map(|child| self.flatten_boolean_and(child))
            .collect()
    }

    fn unary_not(&self, node: &RawNode) -> bool {
        matches!(node.kind.as_str(), "unary" | "unary_expression")
            && self.direct_operator(node).as_deref() == Some("!")
    }

    fn parenthesized_wrapper(&self, node: &RawNode) -> bool {
        self.profile
            .parenthesized_wrapper_node_kinds()
            .contains(&node.kind.as_str())
            && raw_named_children(node).len() == 1
    }

    fn unwrap_parenthesized<'n>(&self, mut node: &'n RawNode) -> &'n RawNode {
        while self.parenthesized_wrapper(node) {
            let Some(child) = raw_named_children(node).into_iter().next() else {
                break;
            };
            node = child;
        }
        node
    }

    fn raw_receiver_node<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        raw_child_by_field(node, "receiver")
            .or_else(|| raw_child_by_field(node, "object"))
            .or_else(|| raw_child_by_field(node, "expression"))
            .or_else(|| raw_child_by_field(node, "operand"))
            .or_else(|| raw_child_by_field(node, "value"))
            .or_else(|| {
                let named = raw_named_children(node);
                (named.len() >= 2).then_some(named[0])
            })
    }

    fn raw_member_node<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        raw_child_by_field(node, "method")
            .or_else(|| raw_child_by_field(node, "field"))
            .or_else(|| raw_child_by_field(node, "property"))
            .or_else(|| raw_child_by_field(node, "name"))
            .or_else(|| raw_child_by_field(node, "suffix"))
            .or_else(|| {
                raw_named_children(node).into_iter().rev().find(|child| {
                    self.profile
                        .identifier_node_kinds()
                        .contains(&child.kind.as_str())
                        || self
                            .profile
                            .field_identifier_node_kinds()
                            .contains(&child.kind.as_str())
                })
            })
    }

    fn raw_callee_node<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        raw_child_by_field(node, "function")
            .or_else(|| raw_child_by_field(node, "callee"))
            .or_else(|| raw_named_children(node).into_iter().next())
    }

    fn raw_arguments_node<'n>(&self, node: &'n RawNode) -> Option<&'n RawNode> {
        raw_child_by_field(node, "arguments")
            .or_else(|| raw_child_by_field(node, "argument"))
            .or_else(|| {
                raw_named_children(node).into_iter().find(|child| {
                    self.profile
                        .argument_list_node_kinds()
                        .contains(&child.kind.as_str())
                })
            })
    }

    fn no_call_arguments(&self, args: Option<&RawNode>) -> bool {
        args.map(|node| raw_named_children(node).is_empty())
            .unwrap_or(true)
    }

    fn safe_navigation_call(&self, node: &RawNode) -> bool {
        self.call_parts(node)
            .map(|call| call.safe_navigation)
            .unwrap_or(false)
            || self.safe_navigation_text(&node.text)
    }

    fn safe_navigation_text(&self, text: &str) -> bool {
        text.contains("&.") || text.contains("?.")
    }

    fn stable_reader_name(&self, mid: &str) -> bool {
        !(mid.ends_with('=') || mid.ends_with('!') || mid == "[]")
    }

    fn nil_literal(&self, node: &RawNode) -> bool {
        self.nil_literal_text(&node.kind) || self.nil_literal_text(node.text.trim())
    }

    fn nil_literal_text(&self, text: &str) -> bool {
        matches!(text, "nil" | "none" | "None" | "null" | "NULL")
    }

    fn simple_subject_identifier(&self, node: &RawNode) -> bool {
        if !node.children.is_empty() {
            return false;
        }
        self.profile
            .identifier_node_kinds()
            .contains(&node.kind.as_str())
            || matches!(node.kind.as_str(), "variable_name" | "simple_identifier")
    }

    fn self_node(&self, node: &RawNode) -> bool {
        matches!(node.kind.as_str(), "self" | "this") || matches!(node.text.trim(), "self" | "this")
    }

    fn terminating(&self, node: &RawNode) -> bool {
        if matches!(
            node.kind.as_str(),
            "return" | "return_statement" | "break" | "break_statement" | "next"
        ) {
            return true;
        }
        let text = node.text.trim();
        if text.starts_with("return ") || text == "return" || text == "break" || text == "next" {
            return true;
        }
        if node.children.is_empty() && TERMINATING_CALLS.contains(&text) {
            return true;
        }
        self.call_parts(node)
            .map(|call| TERMINATING_CALLS.contains(&call.message.as_str()))
            .unwrap_or(false)
    }

    fn nested_local_scope(&self, node: &RawNode) -> bool {
        self.profile
            .function_node_kinds()
            .contains(&node.kind.as_str())
            || self
                .profile
                .class_owner_node_kinds()
                .contains(&node.kind.as_str())
            || self
                .profile
                .module_owner_node_kinds()
                .contains(&node.kind.as_str())
            || self
                .profile
                .generic_owner_node_kinds()
                .contains(&node.kind.as_str())
            || self
                .profile
                .struct_owner_node_kinds()
                .contains(&node.kind.as_str())
    }

    fn ignored_child(&self, node: &RawNode) -> bool {
        node.kind.to_ascii_lowercase().contains("comment")
    }

    fn direct_operator(&self, node: &RawNode) -> Option<String> {
        node.children
            .iter()
            .find(|child| !child.named && !matches!(child.text.as_str(), "(" | ")"))
            .map(|child| {
                if child.text.is_empty() {
                    child.kind.clone()
                } else {
                    child.text.clone()
                }
            })
    }
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
