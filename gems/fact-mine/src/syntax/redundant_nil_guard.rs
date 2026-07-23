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

/// Guard semantics before they are joined to CFG places. Keeping this small
/// record independent of CFG construction lets redundant-guard detection and
/// nullable flow share one normalized interpretation of a condition.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NullableRefinementSeed {
    pub(crate) function: String,
    pub(crate) subject: String,
    pub(crate) condition_span: Span,
    pub(crate) edge: String,
    pub(crate) state_on_edge: String,
    pub(crate) proof_kind: String,
}

pub(crate) struct NormalizedNilGuardFacts {
    pub(crate) redundant_guards: Vec<RedundantNilGuardRow>,
    pub(crate) refinements: Vec<NullableRefinementSeed>,
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

pub(crate) fn normalized_facts_from_normalized(
    file: &str,
    lines: &[String],
    root: &Node,
    behavior: &dyn NormalizedLanguageBehavior,
) -> NormalizedNilGuardFacts {
    let mut scanner = RedundantNilGuard::new(file.to_string(), lines.to_vec(), behavior);
    scanner.walk(root, &Vec::new());
    let mut out = scanner
        .findings
        .into_iter()
        .map(|finding| finding.to_h())
        .collect::<Vec<_>>();
    sort_rows(&mut out);
    scanner.refinements.sort_by(|left, right| {
        left.function
            .cmp(&right.function)
            .then_with(|| left.condition_span.cmp(&right.condition_span))
            .then_with(|| left.subject.cmp(&right.subject))
            .then_with(|| left.edge.cmp(&right.edge))
    });
    scanner.refinements.dedup();
    NormalizedNilGuardFacts {
        redundant_guards: out,
        refinements: scanner.refinements,
    }
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
    refinements: Vec<NullableRefinementSeed>,
}

impl<'a> RedundantNilGuard<'a> {
    fn new(file: String, lines: Vec<String>, behavior: &'a dyn NormalizedLanguageBehavior) -> Self {
        Self {
            file,
            lines,
            behavior,
            findings: Vec::new(),
            refinements: Vec::new(),
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

        let scoped_bindings = self
            .behavior
            .conditional_local_bindings(node)
            .into_iter()
            .collect::<BTreeSet<_>>();
        let mut scoped_known = known.clone();
        for binding in &scoped_bindings {
            scoped_known.remove(binding);
        }

        if let Some(cond) = cond {
            self.inspect_node(cond, defstack, &scoped_known);
            self.record_refinements(node.r#type.as_str(), cond, defstack);
        }

        let then_known = self.known_for_branch(node.r#type.as_str(), true, cond, &scoped_known);
        let else_known = self.known_for_branch(node.r#type.as_str(), false, cond, &scoped_known);

        let then_flow = self.process_block(&self.stmts_for(then_body), defstack, &then_known);
        let else_flow = self.process_block(&self.stmts_for(else_body), defstack, &else_known);

        let mut flow = if then_flow.terminated && else_flow.terminated {
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
        };

        if !flow.terminated {
            for binding in scoped_bindings {
                flow.known.remove(&binding);
                if known.contains(&binding) {
                    flow.known.insert(binding);
                }
            }
        }
        flow
    }

    fn record_refinements(&mut self, node_type: &str, condition: &Node, defstack: &[String]) {
        let function = defstack
            .last()
            .cloned()
            .unwrap_or_else(|| "(top-level)".to_string());
        let condition_span = self.span(condition);
        let proof_kind = self.refinement_proof_kind(condition);

        if let Some(fact) = self.nil_fact(condition) {
            self.push_refinement(
                &function,
                condition_span,
                node_type,
                true,
                &fact.local,
                fact.non_nil_when_true,
                &proof_kind,
            );
            self.push_refinement(
                &function,
                condition_span,
                node_type,
                false,
                &fact.local,
                !fact.non_nil_when_true,
                &proof_kind,
            );
            return;
        }

        for fact in self.branch_nil_facts(condition, true) {
            self.push_refinement(
                &function,
                condition_span,
                node_type,
                true,
                &fact.local,
                true,
                &proof_kind,
            );
        }
    }

    #[allow(clippy::too_many_arguments)] // Refinement facts retain each proof component explicitly.
    fn push_refinement(
        &mut self,
        function: &str,
        condition_span: Span,
        node_type: &str,
        condition_truth: bool,
        subject: &str,
        non_null: bool,
        proof_kind: &str,
    ) {
        let then_branch = if node_type == "IF" {
            condition_truth
        } else {
            !condition_truth
        };
        self.refinements.push(NullableRefinementSeed {
            function: function.to_string(),
            subject: subject.to_string(),
            condition_span,
            edge: if then_branch { "then" } else { "else" }.to_string(),
            state_on_edge: if non_null {
                "definitely_non_null"
            } else {
                "definitely_null"
            }
            .to_string(),
            proof_kind: proof_kind.to_string(),
        });
    }

    fn refinement_proof_kind(&self, node: &Node) -> String {
        if node.r#type == "QCALL" {
            return "safe_navigation".to_string();
        }
        if node.r#type == "OPCALL" {
            return "nil_comparison".to_string();
        }
        if self.call_parts(node).is_some() {
            return "predicate".to_string();
        }
        "truthy".to_string()
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
            let child = self
                .first_node_child(node)
                .expect("wrapper must have node child");
            return self.branch_nil_facts(child, cond_truth);
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
        // Tree-sitter C/C#/JS-style `else if` uses an ELSE_CLAUSE wrapper.
        // Process its child as a statement so assignments and nested branch
        // facts update flow state, rather than merely recursively inspecting
        // it under the predecessor's proof set.
        if node.r#type == "ELSE_CLAUSE" {
            return node.children.iter().filter_map(ast::node).collect();
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use tree_sitter::Parser;

    struct TestBehavior;
    impl NormalizedLanguageBehavior for TestBehavior {}

    struct ShadowBehavior;
    impl NormalizedLanguageBehavior for ShadowBehavior {
        fn conditional_local_bindings(&self, _conditional: &Node) -> Vec<String> {
            vec!["err".to_string()]
        }
    }

    fn scanner() -> RedundantNilGuard<'static> {
        RedundantNilGuard {
            file: "foo.rb".to_string(),
            lines: Vec::new(),
            behavior: &TestBehavior,
            findings: Vec::new(),
            refinements: Vec::new(),
        }
    }

    #[test]
    fn c_reallocation_kills_a_prior_non_nil_proof() {
        let source = r#"
struct entry { int size; };
int queue(struct entry* previous) {
  struct entry* value = previous;
  if (value == NULL) {
    return 1;
  } else if (value->size == 0) {
    value = realloc(value, 64);
    if (value == NULL)
      return 2;
  }
  return 0;
}
"#;
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_c::LANGUAGE.into())
            .expect("C grammar");
        let tree = parser.parse(source, None).expect("C source parses");
        let root = crate::ast::normalize_tree(tree.root_node(), source, Language::C);
        let lines = source.lines().map(str::to_string).collect::<Vec<_>>();
        let facts = normalized_facts_from_normalized(
            "queue.c",
            &lines,
            &root,
            crate::syntax::c::behavior(),
        );
        assert!(
            facts.redundant_guards.is_empty(),
            "unexpected findings: {:?}",
            facts.redundant_guards
        );
        assert_eq!(facts.refinements.len(), 4);
        assert!(facts
            .refinements
            .iter()
            .all(|row| row.proof_kind == "nil_comparison"));
    }

    #[test]
    fn conditional_shadowing_restores_the_outer_flow_fact_after_the_branch() {
        let mut scanner = RedundantNilGuard {
            file: "shadow.go".to_string(),
            lines: Vec::new(),
            behavior: &ShadowBehavior,
            findings: Vec::new(),
            refinements: Vec::new(),
        };
        let branch = Node {
            r#type: "IF".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 1,
            text: "if err := load(); err != nil {}".to_string(),
        };
        let known = BTreeSet::from(["err".to_string(), "other".to_string()]);

        let flow = scanner.process_branch(&branch, &[], &known);

        assert_eq!(flow.known, known);
        assert!(!flow.terminated);
    }

    #[test]
    fn test_scan_files_and_sort_rows() {
        let prev_jobs = crate::parallel::job_count();
        crate::parallel::set_jobs_for_process(Some(2)).unwrap();

        let mut doc1: Document =
            serde_json::from_str(r#"{"file":"a.rb","language":"ruby"}"#).unwrap();
        doc1.redundant_nil_guards = serde_json::from_str(r#"[{"defn":"foo","line":10,"local":"x","guard":"safe","proof":"proof","file":"a.rb","span":[10,0,10,5],"at":"","spans":{}}]"#).unwrap();

        let mut doc2: Document =
            serde_json::from_str(r#"{"file":"b.rb","language":"ruby"}"#).unwrap();
        doc2.redundant_nil_guards = serde_json::from_str(r#"[{"defn":"bar","line":20,"local":"y","guard":"safe","proof":"proof","file":"b.rb","span":[20,0,20,5],"at":"","spans":{}}]"#).unwrap();

        let results = scan_documents(&[doc2, doc1]); // reverse order to test sort_rows
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].file, "a.rb");
        assert_eq!(results[1].file, "b.rb");

        crate::parallel::set_jobs_for_process(Some(prev_jobs)).ok();
    }

    #[test]
    fn test_scan_files_api() {
        // scan_files wrapper
        let res = scan_files(&[], Language::Ruby).unwrap();
        assert!(res.is_empty());
    }

    #[test]
    fn test_subject_key_fallback() {
        let s = scanner();
        let node = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Nil], // not String or Symbol
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(s.subject_key(&node).is_none());
    }

    #[test]
    fn test_child_name_and_node_name_fallback() {
        let s = scanner();
        // child_name node path
        let node_child = Child::Node(Box::new(Node {
            r#type: "foo".to_string(),
            children: vec![Child::Nil], // falls back to text extraction
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "my_name".to_string(),
        }));
        assert_eq!(s.child_name(&node_child), Some("my_name".to_string()));

        // child_name fallback
        assert_eq!(s.child_name(&Child::Nil), None);

        // node_name with first child as String
        let node_string = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::String("var_str".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(s.node_name(&node_string), Some("var_str".to_string()));

        // node_name with first child as Symbol
        let node_symbol = Node {
            r#type: "LVAR".to_string(),
            children: vec![Child::Symbol("var_sym".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert_eq!(s.node_name(&node_symbol), Some("var_sym".to_string()));
    }

    #[test]
    fn test_no_call_arguments_non_node() {
        let s = scanner();
        assert!(!s.no_call_arguments(Some(&Child::Integer(42))));
    }

    #[test]
    fn test_nil_arg_edge_cases() {
        let s = scanner();
        assert!(!s.nil_arg(Some(&Child::Integer(42)))); // not Node

        let nil_node = Node {
            r#type: "LIST".to_string(),
            children: vec![Child::Nil], // Child::Nil path
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(s.nil_arg(Some(&Child::Node(Box::new(nil_node)))));

        let other_node = Node {
            r#type: "LIST".to_string(),
            children: vec![Child::Integer(42)], // _ fallback path
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(!s.nil_arg(Some(&Child::Node(Box::new(other_node)))));
    }

    #[test]
    fn test_opcall_symbol_fallback() {
        let s = scanner();
        let node = Node {
            r#type: "OPCALL".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "LVAR".to_string(),
                    children: vec![Child::Symbol("x".to_string())],
                    first_lineno: 1,
                    first_column: 0,
                    last_lineno: 1,
                    last_column: 0,
                    text: "x".to_string(),
                })),
                Child::Nil, // not Child::Symbol
            ],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(s.nil_fact(&node).is_none());
    }

    #[test]
    fn test_known_for_branch_none_cond() {
        let mut s = scanner();
        let if_node = Node {
            r#type: "IF".to_string(),
            children: Vec::new(),
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        let flow = s.process_stmt(&if_node, &[], &BTreeSet::new());
        assert!(flow.known.is_empty());
    }

    #[test]
    fn test_opcall_no_child_negated() {
        let s = scanner();
        let opcall_no_child = Node {
            r#type: "OPCALL".to_string(),
            children: vec![Child::Nil, Child::Symbol("!".to_string())],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(s.branch_nil_facts(&opcall_no_child, true).is_empty());
    }

    #[test]
    fn test_opcall_no_symbol() {
        let s = scanner();
        let opcall_no_symbol = Node {
            r#type: "OPCALL".to_string(),
            children: vec![Child::Node(Box::new(Node {
                r#type: "LVAR".to_string(),
                children: vec![Child::Symbol("x".to_string())],
                first_lineno: 1,
                first_column: 0,
                last_lineno: 1,
                last_column: 0,
                text: "x".to_string(),
            }))],
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 0,
            text: "".to_string(),
        };
        assert!(s.branch_nil_facts(&opcall_no_symbol, true).is_empty());
    }
}
