use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ImplicitControlFlowReport {
    pub ordered_protocols: Vec<ProtocolFinding>,
    pub order_drift: Vec<ProtocolFinding>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ProtocolFinding {
    pub kind: String,
    pub protocol: Vec<String>,
    pub dependency: Vec<String>,
    pub states: Vec<String>,
    pub support: usize,
    pub confidence: f64,
    pub at: String,
    pub observed: Vec<String>,
    pub missing: Vec<String>,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct MethodEffect {
    owner: String,
    name: String,
    reads: Vec<String>,
    writes: Vec<String>,
}

#[derive(Clone, Debug)]
struct Call {
    mid: String,
    file: String,
    line: usize,
    span: Span,
    reads: Vec<String>,
    writes: Vec<String>,
}

#[derive(Clone, Debug)]
struct MethodSequence {
    file: String,
    owner: String,
    defn: String,
    line: usize,
    calls: Vec<Call>,
}

#[derive(Clone, Debug)]
struct Path {
    calls: Vec<Call>,
    terminal: bool,
}

const PATH_LIMIT: usize = 64;

const IGNORED_MIDS: &[&str] = &[
    "abstract!",
    "alias_method",
    "any",
    "attr_accessor",
    "attr_reader",
    "attr_writer",
    "bind",
    "cast",
    "checked",
    "enum",
    "extend",
    "final",
    "include",
    "interface!",
    "let",
    "must",
    "must_because",
    "nilable",
    "override",
    "overridable",
    "params",
    "prepend",
    "private",
    "private_class_method",
    "protected",
    "public",
    "require",
    "require_relative",
    "requires_ancestor",
    "sealed!",
    "sig",
    "type_member",
    "type_template",
    "untyped",
    "unsafe",
    "void",
    "a_kind_of",
    "after",
    "around",
    "before",
    "be",
    "be_a",
    "be_an",
    "be_empty",
    "be_falsey",
    "be_nil",
    "be_truthy",
    "change",
    "contain_exactly",
    "context",
    "describe",
    "eq",
    "eql",
    "equal",
    "expect",
    "have_attributes",
    "have_key",
    "have_received",
    "it",
    "match",
    "not_to",
    "raise_error",
    "receive",
    "subject",
    "to",
];

const OPTIONAL_DIAGNOSTIC_MIDS: &[&str] =
    &["error!", "fixable!", "read_interpolated_string", "warn!"];

const MUTATING_MIDS: &[&str] = &[
    "<<",
    "[]=",
    "add",
    "append",
    "clear",
    "collect!",
    "compact!",
    "concat",
    "declare",
    "delete",
    "delete_if",
    "each_key=",
    "fill",
    "filter!",
    "keep_if",
    "mark",
    "merge!",
    "move",
    "push",
    "reject!",
    "replace",
    "resolve",
    "shift",
    "stamp",
    "store",
    "unshift",
    "update",
    "write",
];

const NON_MUTATING_OPERATOR_MIDS: &[&str] = &["!", "!=", "!~"];
const MUTATING_SUFFIXES: &[&str] = &["!"];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<ImplicitControlFlowReport> {
    let mut parsed = BTreeMap::new();
    for file in files {
        parsed.insert(
            file.to_string_lossy().to_string(),
            ast::parse_with_language(file, language)?,
        );
    }

    let effect_index = EffectIndex::build(&parsed);
    let mut sequences = Vec::new();
    for (file, (root, lines)) in &parsed {
        let mut miner = ImplicitControlFlow::new(file.clone(), lines.clone(), &effect_index);
        miner.walk(root, &Vec::new());
        sequences.extend(miner.sequences);
    }

    let report = Report::new(sequences);
    Ok(ImplicitControlFlowReport {
        ordered_protocols: report.ordered_protocols(1),
        order_drift: report.drift(4, 0.75),
    })
}

struct ImplicitControlFlow<'a> {
    file: String,
    lines: Vec<String>,
    effect_index: &'a EffectIndex,
    sequences: Vec<MethodSequence>,
}

impl<'a> ImplicitControlFlow<'a> {
    fn new(file: String, lines: Vec<String>, effect_index: &'a EffectIndex) -> Self {
        Self {
            file,
            lines,
            effect_index,
            sequences: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, owners: &[String]) {
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE") {
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_name(node));
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, &next_owners);
            }
        } else if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            self.record_method_paths(node, &owners.join("::"));
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, owners);
            }
        }
    }

    fn record_method_paths(&mut self, node: &Node, owner: &str) {
        let defn = self.method_name(node);
        for path in self.method_paths(node) {
            let calls: Vec<_> = path
                .calls
                .iter()
                .map(|c| self.call_for(c, owner, &defn))
                .collect();
            if calls.iter().filter(|c| self.stateful_call(c)).count() < 2 {
                continue;
            }

            self.sequences.push(MethodSequence {
                file: self.file.clone(),
                owner: owner.to_string(),
                defn: defn.clone(),
                line: node.first_lineno,
                calls,
            });
        }
    }

    fn method_paths(&self, node: &Node) -> Vec<Path> {
        self.paths_for_statements(&ast::body_stmts(node), 0)
    }

    fn paths_for_statements(&self, statements: &[&Node], depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        let mut paths = vec![self.empty_path()];
        for stmt in statements {
            if stmt.r#type == "BEGIN" {
                continue;
            }
            let stmt_paths = self.paths_for(stmt, depth + 1);
            paths = self.append_statement_paths(paths, stmt_paths);
        }
        paths
    }

    fn append_statement_paths(&self, paths: Vec<Path>, stmt_paths: Vec<Path>) -> Vec<Path> {
        self.combine_path_lists(paths, stmt_paths)
    }

    fn combine_path_lists(&self, left_paths: Vec<Path>, right_paths: Vec<Path>) -> Vec<Path> {
        let mut combined = Vec::new();
        for left in left_paths {
            if left.terminal {
                combined.push(left);
            } else {
                for right in &right_paths {
                    let mut calls = left.calls.clone();
                    calls.extend(right.calls.clone());
                    combined.push(Path {
                        calls,
                        terminal: right.terminal,
                    });
                }
            }
        }
        combined.into_iter().take(PATH_LIMIT).collect()
    }

    fn paths_for(&self, node: &Node, depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        match node.r#type.as_str() {
            "BLOCK" => self.paths_for_statements(
                &node
                    .children
                    .iter()
                    .filter_map(ast::node)
                    .collect::<Vec<_>>(),
                depth,
            ),
            "SCOPE" => self.paths_for(
                node.children.get(2).and_then(ast::node).unwrap_or(node),
                depth,
            ),
            "IF" | "UNLESS" => self.branch_paths(node, depth),
            "CASE" | "CASE2" => self.case_paths(node, depth),
            "RETURN" | "BREAK" | "NEXT" | "REDO" | "RETRY" => self
                .generic_paths(node, depth)
                .into_iter()
                .map(|mut p| {
                    p.terminal = true;
                    p
                })
                .collect(),
            _ => self.generic_paths(node, depth),
        }
    }

    fn branch_paths(&self, node: &Node, depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        let cond = node.children.get(0).and_then(ast::node);
        let pos = node.children.get(1).and_then(ast::node);
        let neg = node.children.get(2).and_then(ast::node);

        let mut alts = self.paths_for(pos.unwrap_or(node), depth + 1);
        if let Some(n) = neg {
            alts.extend(self.paths_for(n, depth + 1));
        } else {
            alts.push(self.empty_path());
        }

        self.combine_path_lists(self.paths_for(cond.unwrap_or(node), depth + 1), alts)
    }

    fn case_paths(&self, node: &Node, depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        let (cond, first_when) = if node.r#type == "CASE2" {
            (None, node.children.get(0).and_then(ast::node))
        } else {
            (
                node.children.get(0).and_then(ast::node),
                node.children.get(1).and_then(ast::node),
            )
        };
        self.combine_path_lists(
            cond.map(|c| self.paths_for(c, depth + 1))
                .unwrap_or(vec![self.empty_path()]),
            self.when_paths(first_when, depth + 1),
        )
    }

    fn when_paths(&self, node: Option<&Node>, depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        let Some(n) = node else {
            return vec![self.empty_path()];
        };
        if n.r#type != "WHEN" {
            return self.paths_for(n, depth + 1);
        }

        let pat = n.children.get(0).and_then(ast::node);
        let body = n.children.get(1).and_then(ast::node);
        let next = n.children.get(2).and_then(ast::node);

        let current = self.combine_path_lists(
            self.paths_for(pat.unwrap_or(n), depth + 1),
            self.paths_for(body.unwrap_or(n), depth + 1),
        );
        let mut out = current;
        out.extend(self.when_paths(next, depth + 1));
        out.into_iter().take(PATH_LIMIT).collect()
    }

    fn generic_paths(&self, node: &Node, depth: usize) -> Vec<Path> {
        if depth > 10 {
            return vec![self.empty_path()];
        }
        if matches!(
            node.r#type.as_str(),
            "CLASS" | "MODULE" | "DEFN" | "DEFS" | "LAMBDA"
        ) {
            return vec![self.empty_path()];
        }

        let mut child_paths = vec![self.empty_path()];
        for child in node.children.iter().filter_map(ast::node) {
            child_paths = self.combine_path_lists(child_paths, self.paths_for(child, depth + 1));
        }

        if let Some(mid) = self.internal_protocol_call(node) {
            self.combine_path_lists(
                vec![Path {
                    calls: vec![self.raw_call(&mid, node)],
                    terminal: false,
                }],
                child_paths,
            )
        } else {
            child_paths
        }
    }

    fn raw_call(&self, mid: &str, node: &Node) -> Call {
        Call {
            mid: mid.to_string(),
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            reads: Vec::new(),
            writes: Vec::new(),
        }
    }

    fn call_for(&self, call: &Call, owner: &str, _defn: &str) -> Call {
        let effect = self.effect_index.effect_for(owner, &call.mid);
        Call {
            mid: call.mid.clone(),
            file: call.file.clone(),
            line: call.line,
            span: call.span,
            reads: effect.map(|e| e.reads.clone()).unwrap_or_default(),
            writes: effect.map(|e| e.writes.clone()).unwrap_or_default(),
        }
    }

    fn stateful_call(&self, call: &Call) -> bool {
        !call.reads.is_empty() || !call.writes.is_empty()
    }

    fn empty_path(&self) -> Path {
        Path {
            calls: Vec::new(),
            terminal: false,
        }
    }

    fn owner_name(&self, node: &Node) -> String {
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

    fn method_name(&self, node: &Node) -> String {
        if node.r#type == "DEFS" {
            ast::child_to_string(node.children.get(1)).unwrap_or_else(|| "?".to_string())
        } else {
            ast::child_to_string(node.children.get(0)).unwrap_or_else(|| "?".to_string())
        }
    }

    fn internal_protocol_call(&self, node: &Node) -> Option<String> {
        let mid = self.call_mid(node)?;
        if IGNORED_MIDS.contains(&mid.as_str()) {
            return None;
        }
        if !self.internal_receiver(node) {
            return None;
        }
        Some(mid)
    }

    fn call_mid(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" | "ATTRASGN" => ast::child_to_string(node.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }

    fn internal_receiver(&self, node: &Node) -> bool {
        if matches!(node.r#type.as_str(), "FCALL" | "VCALL") {
            return true;
        }
        let receiver = node.children.get(0).and_then(ast::node);
        receiver.map(|r| r.r#type == "SELF").unwrap_or(false)
    }
}

struct EffectIndex {
    by_owner_name: BTreeMap<(String, String), MethodEffect>,
    by_name: BTreeMap<String, Vec<MethodEffect>>,
}

impl EffectIndex {
    fn build(parsed: &BTreeMap<String, (Node, Vec<String>)>) -> Self {
        let mut effects = Vec::new();
        for (file, (root, lines)) in parsed {
            effects.extend(EffectCollector::new(file.clone(), lines.clone()).scan(root));
        }
        let mut by_owner_name = BTreeMap::new();
        let mut by_name = BTreeMap::new();
        for e in effects {
            by_owner_name.insert((e.owner.clone(), e.name.clone()), e.clone());
            by_name
                .entry(e.name.clone())
                .or_insert_with(Vec::new)
                .push(e);
        }
        Self {
            by_owner_name,
            by_name,
        }
    }

    fn effect_for(&self, owner: &str, name: &str) -> Option<&MethodEffect> {
        if let Some(e) = self
            .by_owner_name
            .get(&(owner.to_string(), name.to_string()))
        {
            return Some(e);
        }
        let candidates = self.by_name.get(name)?;
        let stateful: Vec<_> = candidates
            .iter()
            .filter(|e| !e.reads.is_empty() || !e.writes.is_empty())
            .collect();
        if stateful.len() == 1 {
            Some(stateful[0])
        } else {
            None
        }
    }
}

struct EffectCollector {
    lines: Vec<String>,
}

impl EffectCollector {
    fn new(_file: String, lines: Vec<String>) -> Self {
        Self { lines }
    }

    fn scan(&self, root: &Node) -> Vec<MethodEffect> {
        let mut out = Vec::new();
        self.walk(root, &Vec::new(), &mut out);
        out
    }

    fn walk(&self, node: &Node, owners: &[String], out: &mut Vec<MethodEffect>) {
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE") {
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_name(node));
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, &next_owners, out);
            }
        } else if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            out.push(self.method_effect(node, &owners.join("::")));
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.walk(child, owners, out);
            }
        }
    }

    fn method_effect(&self, node: &Node, owner: &str) -> MethodEffect {
        let mut reads = BTreeSet::new();
        let mut writes = BTreeSet::new();
        self.collect_state_access(node, &mut reads, &mut writes);
        MethodEffect {
            owner: owner.to_string(),
            name: self.method_name(node),
            reads: {
                let mut v: Vec<_> = reads.into_iter().collect();
                v.sort();
                v
            },
            writes: {
                let mut v: Vec<_> = writes.into_iter().collect();
                v.sort();
                v
            },
        }
    }

    fn collect_state_access(
        &self,
        node: &Node,
        reads: &mut BTreeSet<String>,
        writes: &mut BTreeSet<String>,
    ) {
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE" | "LAMBDA") {
            return;
        }

        match node.r#type.as_str() {
            "IASGN" => {
                if let Some(s) = ast::child_to_string(node.children.get(0)) {
                    writes.insert(self.normalize_state(&s));
                }
            }
            "LASGN" => self.collect_index_write(node, writes),
            "IVAR" => {
                if let Some(s) = ast::child_to_string(node.children.get(0)) {
                    reads.insert(self.normalize_state(&s));
                }
            }
            "ATTRASGN" => self.collect_attr_write(node, writes),
            "CALL" | "OPCALL" => {
                self.collect_bare_reader_comparison(node, reads);
                self.collect_receiver_mutation(node, writes);
                self.collect_self_reader(node, reads);
            }
            "VCALL" | "FCALL" => self.collect_self_reader(node, reads),
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.collect_state_access(child, reads, writes);
        }
    }

    fn collect_attr_write(&self, node: &Node, writes: &mut BTreeSet<String>) {
        let receiver = node.children.get(0).and_then(ast::node);
        let mid = ast::child_to_string(node.children.get(1));
        let Some(mid) = mid else { return };
        let attr = mid.trim_end_matches('=').to_string();

        if mid == "[]=" {
            if let Some(t) = receiver.and_then(|r| self.state_receiver_token(r)) {
                writes.insert(t);
            }
        } else if receiver.map(|r| self.self_receiver(r)).unwrap_or(false) {
            writes.insert(self.normalize_state(&attr));
        } else if let Some(t) = receiver.and_then(|r| self.state_receiver_token(r)) {
            writes.insert(format!("{}.{}", t, attr));
        }
    }

    fn collect_index_write(&self, node: &Node, writes: &mut BTreeSet<String>) {
        let name = ast::child_to_string(node.children.get(0)).unwrap_or_default();
        if name.contains('[') {
            writes.insert(self.normalize_state(name.split('[').next().unwrap()));
        }
    }

    fn collect_bare_reader_comparison(&self, node: &Node, reads: &mut BTreeSet<String>) {
        let receiver = node.children.get(0).and_then(ast::node);
        let mid = ast::child_to_string(node.children.get(1)).unwrap_or_default();
        if matches!(mid.as_str(), "==" | "!=" | "===" | "<" | "<=" | ">" | ">=") {
            if let Some(r) = receiver {
                if r.r#type == "LVAR" {
                    if let Some(name) = ast::child_to_string(r.children.get(0)) {
                        reads.insert(self.normalize_state(&name));
                    }
                }
            }
        }
    }

    fn collect_receiver_mutation(&self, node: &Node, writes: &mut BTreeSet<String>) {
        let receiver = node.children.get(0).and_then(ast::node);
        let mid = ast::child_to_string(node.children.get(1)).unwrap_or_default();
        if self.mutating_mid(&mid) {
            if let Some(r) = receiver {
                if let Some(t) = self.state_receiver_token(r) {
                    writes.insert(t);
                }
            }
        }
    }

    fn collect_self_reader(&self, node: &Node, reads: &mut BTreeSet<String>) {
        let mid = self.call_mid(node);
        let Some(mid) = mid else { return };
        if self.mutating_mid(&mid) {
            return;
        }
        if IGNORED_MIDS.contains(&mid.as_str()) {
            return;
        }
        if !self.no_args(node) {
            return;
        }
        if node.r#type == "CALL"
            && !self.self_receiver(node.children.get(0).and_then(ast::node).unwrap())
        {
            return;
        }
        reads.insert(self.normalize_state(&mid));
    }

    fn mutating_mid(&self, mid: &str) -> bool {
        if NON_MUTATING_OPERATOR_MIDS.contains(&mid) {
            return false;
        }
        MUTATING_MIDS.contains(&mid) || MUTATING_SUFFIXES.iter().any(|s| mid.ends_with(s))
    }

    fn no_args(&self, node: &Node) -> bool {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" => node
                .children
                .get(2)
                .map(|c| matches!(c, Child::Nil))
                .unwrap_or(true),
            "VCALL" => true,
            "FCALL" => node
                .children
                .get(1)
                .map(|c| matches!(c, Child::Nil))
                .unwrap_or(true),
            _ => false,
        }
    }

    fn state_receiver_token(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "IVAR" => ast::child_to_string(node.children.get(0)).map(|s| self.normalize_state(&s)),
            "SELF" => Some("self".to_string()),
            "VCALL" | "FCALL" | "LVAR" => {
                ast::child_to_string(node.children.get(0)).map(|s| self.normalize_state(&s))
            }
            "CALL" => {
                if self.no_args(node) {
                    ast::child_to_string(node.children.get(1)).map(|s| self.normalize_state(&s))
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn self_receiver(&self, node: &Node) -> bool {
        node.r#type == "SELF"
    }

    fn call_mid(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" | "ATTRASGN" => ast::child_to_string(node.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }

    fn owner_name(&self, node: &Node) -> String {
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

    fn method_name(&self, node: &Node) -> String {
        if node.r#type == "DEFS" {
            ast::child_to_string(node.children.get(1)).unwrap_or_else(|| "?".to_string())
        } else {
            ast::child_to_string(node.children.get(0)).unwrap_or_else(|| "?".to_string())
        }
    }

    fn normalize_state(&self, name: &str) -> String {
        name.trim_start_matches('@')
            .trim_end_matches('=')
            .to_string()
    }
}

struct Report {
    sequences: Vec<MethodSequence>,
    site_call_sets: BTreeMap<(String, String, String, usize), BTreeMap<String, bool>>,
}

impl Report {
    fn new(sequences: Vec<MethodSequence>) -> Self {
        let mut site_call_sets = BTreeMap::new();
        for seq in &sequences {
            let mut calls = BTreeMap::new();
            for c in seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
            {
                calls.insert(c.mid.clone(), true);
            }
            site_call_sets.insert(
                (
                    seq.file.clone(),
                    seq.owner.clone(),
                    seq.defn.clone(),
                    seq.line,
                ),
                calls,
            );
        }
        Self {
            sequences,
            site_call_sets,
        }
    }

    fn ordered_protocols(&self, min_support: usize) -> Vec<ProtocolFinding> {
        let mut counts: BTreeMap<
            (String, String, String, String),
            BTreeMap<(String, String, String, usize), ProtocolFinding>,
        > = BTreeMap::new();
        for seq in &self.sequences {
            let state_calls: Vec<_> = seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
                .collect();
            let collapsed = self.collapse_consecutive(&state_calls);
            for i in 0..collapsed.len().saturating_sub(1) {
                let left = collapsed[i];
                let right = collapsed[i + 1];
                let edge = self.dependency_edge(left, right);
                let Some(edge) = edge else { continue };
                if self.diagnostic_protocol(&[left.mid.clone(), right.mid.clone()]) {
                    continue;
                };

                let key = (
                    left.mid.clone(),
                    right.mid.clone(),
                    edge.0.join("|"),
                    edge.1.join("|"),
                );
                let site_key = (
                    seq.file.clone(),
                    seq.owner.clone(),
                    seq.defn.clone(),
                    seq.line,
                );
                counts.entry(key).or_default().insert(
                    site_key,
                    ProtocolFinding {
                        kind: "protocol_pressure".to_string(),
                        protocol: vec![left.mid.clone(), right.mid.clone()],
                        dependency: edge.0,
                        states: edge.1,
                        support: 0,
                        confidence: 1.0,
                        at: format!("{}:{}:{}", seq.file, seq.defn, seq.line),
                        observed: vec![left.mid.clone(), right.mid.clone()],
                        missing: Vec::new(),
                        sites: Vec::new(),
                        spans: {
                            let mut s = BTreeMap::new();
                            s.insert(format!("{}:{}:{}", seq.file, seq.defn, seq.line), left.span);
                            s
                        },
                    },
                );
            }
        }

        let mut out = Vec::new();
        for (_, sites) in counts {
            if sites.len() < min_support {
                continue;
            }
            let mut first = sites.values().next().unwrap().clone();
            first.support = sites.len();
            first.sites = sites
                .keys()
                .map(|k| format!("{}:{}:{}", k.0, k.2, k.3))
                .collect();
            out.push(first);
        }
        out.sort_by(|a, b| {
            b.support
                .cmp(&a.support)
                .then_with(|| self.dependency_rank(a).cmp(&self.dependency_rank(b)))
                .then_with(|| a.protocol.join("\0").cmp(&b.protocol.join("\0")))
        });
        out
    }

    fn drift(&self, min_support: usize, min_confidence: f64) -> Vec<ProtocolFinding> {
        let protocols = self.ordered_protocols(min_support);
        let mut protocol_index: BTreeMap<String, Vec<ProtocolFinding>> = BTreeMap::new();
        for p in protocols {
            let mut pair = p.protocol.clone();
            pair.sort();
            protocol_index.entry(pair.join("\0")).or_default().push(p);
        }

        let mut out = Vec::new();
        for seq in &self.sequences {
            let state_calls: Vec<_> = seq
                .calls
                .iter()
                .filter(|c| !c.reads.is_empty() || !c.writes.is_empty())
                .collect();
            let collapsed = self.collapse_consecutive(&state_calls);
            let mids: Vec<_> = collapsed.iter().map(|c| c.mid.clone()).collect();
            let positions = self.first_positions(&mids);

            for protocol_row in self.candidate_protocols(
                &positions.keys().cloned().collect::<Vec<_>>(),
                &protocol_index,
            ) {
                let present: Vec<_> = protocol_row
                    .protocol
                    .iter()
                    .filter(|m| positions.contains_key(*m))
                    .cloned()
                    .collect();
                if present.len() < 2 {
                    continue;
                }
                if self.ordered_subsequence(&mids, &protocol_row.protocol) {
                    continue;
                }

                let confidence =
                    (protocol_row.support as f64) / (self.denominator_for(&present) as f64);
                if confidence < min_confidence {
                    continue;
                }

                out.push(self.finding(seq, &protocol_row, &present, &positions, confidence));
            }
        }

        let mut deduped = Vec::new();
        let mut seen = BTreeSet::new();
        for row in out {
            let key = (
                row.kind.clone(),
                row.at.clone(),
                row.protocol.clone(),
                row.observed.clone(),
                row.states.clone(),
            );
            if seen.insert(key) {
                deduped.push(row);
            }
        }
        deduped.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap()
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.at.cmp(&b.at))
        });
        deduped
    }

    fn dependency_rank(&self, row: &ProtocolFinding) -> usize {
        if row.dependency.iter().any(|d| d == "write_read") {
            0
        } else if row.dependency.iter().any(|d| d == "write_write") {
            1
        } else {
            2
        }
    }

    fn collapse_consecutive<'a>(&self, calls: &'a [&'a Call]) -> Vec<&'a Call> {
        let mut out = Vec::new();
        let mut last = None;
        for c in calls {
            if last.map(|l| l == &c.mid).unwrap_or(false) {
                continue;
            }
            last = Some(&c.mid);
            out.push(*c);
        }
        out
    }

    fn dependency_edge(&self, left: &Call, right: &Call) -> Option<(Vec<String>, Vec<String>)> {
        let lw: BTreeSet<_> = left.writes.iter().collect();
        let lr: BTreeSet<_> = left.reads.iter().collect();
        let rw: BTreeSet<_> = right.writes.iter().collect();
        let rr: BTreeSet<_> = right.reads.iter().collect();

        let mut kinds = Vec::new();
        let mut states = BTreeSet::new();

        let wr: Vec<_> = lw.intersection(&rr).collect();
        if !wr.is_empty() {
            kinds.push("write_read".to_string());
            for s in wr {
                states.insert((*s).clone());
            }
        }
        let ww: Vec<_> = lw.intersection(&rw).collect();
        if !ww.is_empty() {
            kinds.push("write_write".to_string());
            for s in ww {
                states.insert((*s).clone());
            }
        }
        let rw_int: Vec<_> = lr.intersection(&rw).collect();
        if !rw_int.is_empty() {
            kinds.push("read_write".to_string());
            for s in rw_int {
                states.insert((*s).clone());
            }
        }

        if kinds.is_empty() {
            return None;
        }
        kinds.sort();
        let mut states_v: Vec<_> = states.into_iter().collect();
        states_v.sort();
        Some((kinds, states_v))
    }

    fn diagnostic_protocol(&self, protocol: &[String]) -> bool {
        protocol
            .iter()
            .any(|m| OPTIONAL_DIAGNOSTIC_MIDS.contains(&m.as_str()))
    }

    fn candidate_protocols(
        &self,
        mids: &[String],
        protocol_index: &BTreeMap<String, Vec<ProtocolFinding>>,
    ) -> Vec<ProtocolFinding> {
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        for i in 0..mids.len() {
            for j in i + 1..mids.len() {
                let mut pair = vec![mids[i].clone(), mids[j].clone()];
                pair.sort();
                if let Some(ps) = protocol_index.get(&pair.join("\0")) {
                    for p in ps {
                        let key = (p.protocol.clone(), p.dependency.clone(), p.states.clone());
                        if seen.insert(key) {
                            out.push(p.clone());
                        }
                    }
                }
            }
        }
        out
    }

    fn first_positions(&self, mids: &[String]) -> BTreeMap<String, usize> {
        let mut out = BTreeMap::new();
        for (i, m) in mids.iter().enumerate() {
            out.entry(m.clone()).or_insert(i);
        }
        out
    }

    fn ordered_subsequence(&self, mids: &[String], protocol: &[String]) -> bool {
        let mut idx = 0;
        for m in mids {
            if m == &protocol[idx] {
                idx += 1;
            }
            if idx == protocol.len() {
                return true;
            }
        }
        false
    }

    fn denominator_for(&self, present: &[String]) -> usize {
        self.site_call_sets
            .values()
            .filter(|mids| present.iter().all(|m| mids.contains_key(m)))
            .count()
            .max(1)
    }

    fn finding(
        &self,
        seq: &MethodSequence,
        protocol_row: &ProtocolFinding,
        present: &[String],
        positions: &BTreeMap<String, usize>,
        confidence: f64,
    ) -> ProtocolFinding {
        let anchor_mid = present
            .iter()
            .min_by_key(|m| positions.get(*m).unwrap())
            .unwrap();
        let anchor = seq.calls.iter().find(|c| &c.mid == anchor_mid).unwrap();
        let loc = format!("{}:{}:{}", seq.file, seq.defn, anchor.line);
        let mut observed = present.to_vec();
        observed.sort_by_key(|m| positions.get(m).unwrap());

        let mut spans = BTreeMap::new();
        spans.insert(loc.clone(), anchor.span);

        ProtocolFinding {
            kind: "order_drift".to_string(),
            protocol: protocol_row.protocol.clone(),
            observed,
            missing: Vec::new(),
            dependency: protocol_row.dependency.clone(),
            states: protocol_row.states.clone(),
            support: protocol_row.support,
            confidence: (confidence * 100.0).round() / 100.0,
            at: loc,
            sites: protocol_row.sites.clone(),
            spans,
        }
    }
}
