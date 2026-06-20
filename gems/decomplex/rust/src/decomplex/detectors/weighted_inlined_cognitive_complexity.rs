use crate::decomplex::ast::{self, Node, RawNode, Span};
use crate::decomplex::detectors::{local_flow, structural_topology};
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct WeightedInlinedCognitiveComplexityRow {
    pub at: String,
    pub owner: String,
    pub method: String,
    pub local: f64,
    pub inlined: f64,
    pub hidden: f64,
    pub depth: usize,
    pub single_caller_callees: Vec<String>,
    pub call_chain: Vec<String>,
    pub reason: String,
    pub signals: BTreeMap<String, usize>,
    pub spans: BTreeMap<String, Span>,
}

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<WeightedInlinedCognitiveComplexityRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<WeightedInlinedCognitiveComplexityRow> {
    let topology_report = structural_topology::scan_documents(documents);
    let topology = structural_topology::Graph::new(topology_report.methods, topology_report.edges);
    let raw_scores = raw_complexity_scores(documents);

    let mut scores = BTreeMap::new();
    for summary in local_flow::scan_documents(documents) {
        let owner = if summary.owner == "(top-level)" {
            format!("(top-level:{})", summary.file)
        } else {
            summary.owner.clone()
        };
        let id = format!("{}#{}", owner, summary.name);
        let score = raw_scores
            .get(&(summary.file.clone(), summary.line, summary.name.clone()))
            .cloned()
            .unwrap_or_else(|| LocalScorer::new().score(&summary.node));
        scores.insert(
            id.clone(),
            LocalScore {
                id,
                owner,
                name: summary.name,
                file: summary.file,
                line: summary.line,
                span: summary.span,
                score: score.score,
                signals: score.signals,
            },
        );
    }

    let analyzer = Analyzer::new(topology, scores, 12.0, 15.0, 2);
    analyzer.findings()
}

fn raw_complexity_scores(documents: &[Document]) -> BTreeMap<(String, usize, String), ScoreResult> {
    let mut out = BTreeMap::new();
    for document in documents {
        for function in &document.function_defs {
            out.insert(
                (function.file.clone(), function.line, function.name.clone()),
                LocalScorer::new().score_raw(&function.body),
            );
        }
    }
    out
}

struct LocalScore {
    id: String,
    owner: String,
    name: String,
    file: String,
    line: usize,
    span: Span,
    score: f64,
    signals: BTreeMap<String, usize>,
}

struct Contribution {
    #[allow(dead_code)]
    callee_id: String,
    callee_name: String,
    score: f64,
    #[allow(dead_code)]
    weight: f64,
    depth: usize,
    chain: Vec<String>,
}

const METHOD_TYPES: &[&str] = &["DEFN", "DEFS"];
const SKIP_NESTED_TYPES: &[&str] = &["CLASS", "MODULE", "DEFN", "DEFS", "LAMBDA"];
const BRANCH_TYPES: &[&str] = &["IF", "UNLESS"];
const LOOP_TYPES: &[&str] = &["WHILE", "UNTIL", "FOR", "ITER"];
const CASE_TYPES: &[&str] = &["CASE", "CASE2"];
const RESCUE_TYPES: &[&str] = &["RESCUE", "RESBODY"];
const EARLY_EXIT_TYPES: &[&str] = &["RETURN", "BREAK", "NEXT", "REDO", "RETRY"];
const BOOLEAN_TYPES: &[&str] = &["AND", "OR"];

pub struct LocalScorer {}

#[derive(Clone)]
pub struct ScoreResult {
    pub score: f64,
    pub signals: BTreeMap<String, usize>,
}

impl LocalScorer {
    pub fn new() -> Self {
        Self {}
    }

    pub fn score(&self, method_node: &Node) -> ScoreResult {
        let mut signals = BTreeMap::new();
        ScoreResult {
            score: self.round(self.score_node(method_node, 0, &mut signals)),
            signals,
        }
    }

    pub fn score_raw(&self, method_node: &RawNode) -> ScoreResult {
        let mut signals = BTreeMap::new();
        ScoreResult {
            score: self.round(self.score_raw_node(method_node, 0, &mut signals)),
            signals,
        }
    }

    fn score_node(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        if self.skip_nested(node) {
            return 0.0;
        }

        match node.r#type.as_str() {
            t if BRANCH_TYPES.contains(&t) => self.score_branch(node, nesting, signals),
            t if LOOP_TYPES.contains(&t) => self.score_loop(node, nesting, signals),
            t if CASE_TYPES.contains(&t) => self.score_case(node, nesting, signals),
            t if RESCUE_TYPES.contains(&t) => self.score_rescue(node, nesting, signals),
            t if EARLY_EXIT_TYPES.contains(&t) => self.score_early_exit(node, nesting, signals),
            t if BOOLEAN_TYPES.contains(&t) => self.score_boolean_node(node, nesting, signals),
            _ => self.score_children(node, nesting, signals),
        }
    }

    fn skip_nested(&self, node: &Node) -> bool {
        SKIP_NESTED_TYPES.contains(&node.r#type.as_str())
            && !METHOD_TYPES.contains(&node.r#type.as_str())
    }

    fn score_branch(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("branches".to_string()).or_insert(0) += 1;
        if nesting > 0 {
            *signals.entry("nested".to_string()).or_insert(0) += 1;
        }
        let condition = node.children.get(0).and_then(ast::node);
        let positive = node.children.get(1).and_then(ast::node);
        let negative = node.children.get(2).and_then(ast::node);

        self.branch_cost(nesting)
            + self.predicate_cost(condition, signals)
            + positive
                .map(|n| self.score_node(n, nesting + 1, signals))
                .unwrap_or(0.0)
            + negative
                .map(|n| self.score_node(n, nesting + 1, signals))
                .unwrap_or(0.0)
    }

    fn score_loop(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("loops".to_string()).or_insert(0) += 1;
        if nesting > 0 {
            *signals.entry("nested".to_string()).or_insert(0) += 1;
        }
        self.branch_cost(nesting) + self.score_children(node, nesting + 1, signals)
    }

    fn score_case(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("cases".to_string()).or_insert(0) += 1;
        0.5 + self.score_case_children(node, nesting, signals)
    }

    fn score_case_children(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        node.children
            .iter()
            .filter_map(ast::node)
            .map(|child| {
                if child.r#type == "WHEN" {
                    self.score_when(child, nesting, signals)
                } else {
                    self.score_node(child, nesting, signals)
                }
            })
            .sum()
    }

    fn score_when(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        let body = node.children.get(1).and_then(ast::node);
        let next_when = node.children.get(2).and_then(ast::node);
        body.map(|n| self.score_node(n, nesting + 1, signals))
            .unwrap_or(0.0)
            + next_when
                .map(|n| self.score_node(n, nesting, signals))
                .unwrap_or(0.0)
    }

    fn score_rescue(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("rescues".to_string()).or_insert(0) += 1;
        self.branch_cost(nesting) + self.score_children(node, nesting + 1, signals)
    }

    fn score_early_exit(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("early_exits".to_string()).or_insert(0) += 1;
        let exit_cost = if nesting > 0 {
            0.5 + (nesting as f64 * 0.25)
        } else {
            0.0
        };
        exit_cost + self.score_children(node, nesting, signals)
    }

    fn score_boolean_node(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        *signals.entry("boolean_ops".to_string()).or_insert(0) += 1;
        0.25 + self.score_children(node, nesting, signals)
    }

    fn score_children(
        &self,
        node: &Node,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        node.children
            .iter()
            .filter_map(ast::node)
            .map(|child| self.score_node(child, nesting, signals))
            .sum()
    }

    fn predicate_cost(&self, node: Option<&Node>, signals: &mut BTreeMap<String, usize>) -> f64 {
        let Some(node) = node else { return 0.0 };
        let bools = self.boolean_count(node);
        *signals.entry("boolean_ops".to_string()).or_insert(0) += bools;
        (bools as f64) * 0.5
    }

    fn boolean_count(&self, node: &Node) -> usize {
        let own = if BOOLEAN_TYPES.contains(&node.r#type.as_str()) {
            1
        } else {
            0
        };
        own + node
            .children
            .iter()
            .filter_map(ast::node)
            .map(|child| self.boolean_count(child))
            .sum::<usize>()
    }

    fn branch_cost(&self, nesting: usize) -> f64 {
        1.1 + (nesting as f64)
    }

    fn round(&self, value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }

    fn score_raw_node(
        &self,
        node: &RawNode,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        if raw_skip_nested(node) {
            return 0.0;
        }

        if raw_branch(node) {
            *signals.entry("branches".to_string()).or_insert(0) += 1;
            if nesting > 0 {
                *signals.entry("nested".to_string()).or_insert(0) += 1;
            }
            return self.branch_cost(nesting)
                + self.raw_predicate_cost(raw_condition_node(node), signals)
                + self.score_raw_children(node, nesting + 1, signals);
        }

        if raw_loop(node) {
            *signals.entry("loops".to_string()).or_insert(0) += 1;
            if nesting > 0 {
                *signals.entry("nested".to_string()).or_insert(0) += 1;
            }
            return self.branch_cost(nesting) + self.score_raw_children(node, nesting + 1, signals);
        }

        if raw_case(node) {
            *signals.entry("cases".to_string()).or_insert(0) += 1;
            return 0.5 + self.score_raw_children(node, nesting + 1, signals);
        }

        if raw_rescue(node) {
            *signals.entry("rescues".to_string()).or_insert(0) += 1;
            return self.branch_cost(nesting) + self.score_raw_children(node, nesting + 1, signals);
        }

        if raw_early_exit(node) {
            *signals.entry("early_exits".to_string()).or_insert(0) += 1;
            let exit_cost = if nesting > 0 {
                0.5 + (nesting as f64 * 0.25)
            } else {
                0.0
            };
            return exit_cost + self.score_raw_children(node, nesting, signals);
        }

        if raw_boolean_node(node) {
            *signals.entry("boolean_ops".to_string()).or_insert(0) += 1;
            return 0.25 + self.score_raw_children(node, nesting, signals);
        }

        self.score_raw_children(node, nesting, signals)
    }

    fn score_raw_children(
        &self,
        node: &RawNode,
        nesting: usize,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        node.children
            .iter()
            .map(|child| self.score_raw_node(child, nesting, signals))
            .sum()
    }

    fn raw_predicate_cost(
        &self,
        node: Option<&RawNode>,
        signals: &mut BTreeMap<String, usize>,
    ) -> f64 {
        let Some(node) = node else { return 0.0 };
        let bools = raw_boolean_count(node);
        *signals.entry("boolean_ops".to_string()).or_insert(0) += bools;
        (bools as f64) * 0.5
    }
}

fn raw_skip_nested(node: &RawNode) -> bool {
    matches!(node.kind.as_str(), "class" | "module" | "lambda")
}

fn raw_branch(node: &RawNode) -> bool {
    (matches!(
        node.kind.as_str(),
        "if" | "unless" | "if_statement" | "if_expression" | "if_modifier" | "unless_modifier"
    ) && !node.named_children().is_empty())
        || raw_hidden_if(node)
        || raw_modifier_if(node)
}

fn raw_hidden_if(node: &RawNode) -> bool {
    if node.kind == "expression_statement" && node.text.trim_start().starts_with("if ") {
        return true;
    }
    matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list"
    ) && node
        .children
        .first()
        .map(|child| !child.named && matches!(child.kind.as_str(), "if" | "unless"))
        .unwrap_or(false)
}

fn raw_modifier_if(node: &RawNode) -> bool {
    if matches!(node.kind.as_str(), "if_modifier" | "unless_modifier") {
        return true;
    }
    if node.kind != "body_statement" {
        return false;
    }
    let mut seen_named = false;
    node.children.iter().any(|child| {
        seen_named |= child.named;
        seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless")
    })
}

fn raw_loop(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "while"
            | "until"
            | "while_statement"
            | "for"
            | "for_statement"
            | "for_in_statement"
            | "do_block"
    ) || raw_hidden_loop(node)
        || (node.kind == "expression_statement"
            && starts_with_any(node.text.trim_start(), &["for", "while", "loop"]))
        || (node.kind == "labeled_statement" && node.text.trim_start().starts_with("for "))
}

fn raw_hidden_loop(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list"
    ) && node
        .children
        .first()
        .map(|child| !child.named && matches!(child.kind.as_str(), "for" | "while" | "loop"))
        .unwrap_or(false)
}

fn starts_with_any(text: &str, words: &[&str]) -> bool {
    words
        .iter()
        .any(|word| text == *word || text.starts_with(&format!("{word} ")))
}

fn raw_case(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "case" | "switch_statement" | "switch_expression" | "match_statement" | "match_expression"
    ) || (node.kind == "expression_statement" && node.text.trim_start().starts_with("match "))
}

fn raw_rescue(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "rescue" | "rescue_modifier" | "rescue_clause" | "rescue_body"
    )
}

fn raw_early_exit(node: &RawNode) -> bool {
    (node.named || node.kind == "return")
        && matches!(
            node.kind.as_str(),
            "return"
                | "break"
                | "next"
                | "redo"
                | "retry"
                | "return_statement"
                | "break_statement"
                | "continue_statement"
        )
}

fn raw_boolean_node(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "binary"
            | "binary_expression"
            | "boolean_operator"
            | "conjunction_expression"
            | "disjunction_expression"
    ) && node
        .children
        .iter()
        .any(|child| !child.named && matches!(child.text.as_str(), "&&" | "||" | "and" | "or"))
}

fn raw_condition_node(node: &RawNode) -> Option<&RawNode> {
    if raw_modifier_if(node) {
        return node.named_children().last().copied();
    }
    if node.kind == "body_statement" {
        return node.named_children().first().copied();
    }
    node.named_children().first().copied()
}

fn raw_boolean_count(node: &RawNode) -> usize {
    let own = usize::from(raw_boolean_node(node));
    own + node.children.iter().map(raw_boolean_count).sum::<usize>()
}

struct Analyzer {
    topology: structural_topology::Graph,
    scores: BTreeMap<String, LocalScore>,
    min_score: f64,
    min_hidden: f64,
    max_depth: usize,
}

impl Analyzer {
    fn new(
        topology: structural_topology::Graph,
        scores: BTreeMap<String, LocalScore>,
        min_score: f64,
        min_hidden: f64,
        max_depth: usize,
    ) -> Self {
        Self {
            topology,
            scores,
            min_score,
            min_hidden,
            max_depth,
        }
    }

    fn findings(&self) -> Vec<WeightedInlinedCognitiveComplexityRow> {
        let mut out: Vec<_> = self
            .scores
            .values()
            .filter_map(|s| self.finding_for(s))
            .collect();
        out.sort_by(|a, b| {
            b.hidden
                .partial_cmp(&a.hidden)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    b.inlined
                        .partial_cmp(&a.inlined)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| a.at.cmp(&b.at))
        });
        out
    }

    fn finding_for(&self, score: &LocalScore) -> Option<WeightedInlinedCognitiveComplexityRow> {
        let mut visited = BTreeSet::new();
        visited.insert(score.id.clone());
        let contributions = self.inlined_contributions(&score.id, 1, &mut visited);

        let hidden = self.round(contributions.iter().map(|c| c.score).sum());
        let total = self.round(score.score + hidden);
        if total < self.min_score || hidden < self.min_hidden {
            return None;
        }

        let direct_single_caller = self.single_caller_callees(&score.id);
        let at = format!("{}:{}:{}", score.file, score.name, score.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), score.span);

        Some(WeightedInlinedCognitiveComplexityRow {
            at,
            owner: score.owner.clone(),
            method: score.name.clone(),
            local: score.score,
            inlined: total,
            hidden,
            depth: contributions.iter().map(|c| c.depth).max().unwrap_or(0),
            single_caller_callees: direct_single_caller.clone(),
            call_chain: self.strongest_chain(score, &contributions),
            reason: self.reason(hidden, &direct_single_caller),
            signals: score.signals.clone(),
            spans,
        })
    }

    fn inlined_contributions(
        &self,
        method_id: &str,
        depth: usize,
        visited: &mut BTreeSet<String>,
    ) -> Vec<Contribution> {
        if depth > self.max_depth {
            return Vec::new();
        }

        let mut out = Vec::new();
        for edge in self.grouped_edges(method_id) {
            if visited.contains(&edge.callee) {
                continue;
            }
            let Some(callee) = self.scores.get(&edge.callee) else {
                continue;
            };

            let weight = self.contribution_weight(&edge, depth);
            let direct = Contribution {
                callee_id: edge.callee.clone(),
                callee_name: edge.callee_name.clone(),
                score: self.round(callee.score * weight),
                weight: self.round(weight),
                depth,
                chain: vec![edge.callee_name.clone()],
            };

            let mut next_visited = visited.clone();
            next_visited.insert(edge.callee.clone());
            let nested = self.inlined_contributions(&edge.callee, depth + 1, &mut next_visited);
            let nested: Vec<_> = nested
                .into_iter()
                .map(|c| Contribution {
                    callee_id: c.callee_id,
                    callee_name: c.callee_name,
                    score: self.round(c.score * weight),
                    weight: self.round(c.weight * weight),
                    depth: c.depth,
                    chain: {
                        let mut chain = vec![edge.callee_name.clone()];
                        chain.extend(c.chain);
                        chain
                    },
                })
                .collect();

            out.push(direct);
            out.extend(nested);
        }
        out
    }

    fn grouped_edges(&self, method_id: &str) -> Vec<structural_topology::Edge> {
        let mut by_callee: BTreeMap<String, Vec<structural_topology::Edge>> = BTreeMap::new();
        for edge in self.topology.internal_calls(method_id) {
            by_callee.entry(edge.callee.clone()).or_default().push(edge);
        }
        by_callee
            .into_iter()
            .map(|(_, edges)| {
                edges
                    .into_iter()
                    .max_by(|a, b| {
                        self.edge_weight(&a.r#type)
                            .partial_cmp(&self.edge_weight(&b.r#type))
                            .unwrap()
                    })
                    .unwrap()
            })
            .collect()
    }

    fn contribution_weight(&self, edge: &structural_topology::Edge, depth: usize) -> f64 {
        let caller_factor = if self.topology.single_internal_caller(&edge.callee) {
            1.0
        } else {
            0.35
        };
        let visibility_factor = if self.shared_public_step(edge) {
            0.6
        } else {
            1.0
        };
        let depth_factor = match depth {
            1 => 1.0,
            2 => 0.6,
            _ => 0.35,
        };
        let edge_factor = self.edge_weight(&edge.r#type);
        caller_factor * visibility_factor * depth_factor * edge_factor
    }

    fn edge_weight(&self, t: &str) -> f64 {
        match t {
            "always" => 1.0,
            "conditional" => 0.75,
            "iterates" => 1.15,
            _ => 1.0,
        }
    }

    fn shared_public_step(&self, edge: &structural_topology::Edge) -> bool {
        self.topology.visibility(&edge.callee) == Some("public")
            && !self.topology.single_internal_caller(&edge.callee)
    }

    fn single_caller_callees(&self, method_id: &str) -> Vec<String> {
        let mut out: Vec<_> = self
            .grouped_edges(method_id)
            .into_iter()
            .filter(|e| self.topology.single_internal_caller(&e.callee))
            .map(|e| e.callee_name)
            .collect();
        out.sort();
        out
    }

    fn strongest_chain(&self, score: &LocalScore, contributions: &[Contribution]) -> Vec<String> {
        let chain = contributions
            .iter()
            .max_by(|a, b| a.score.partial_cmp(&b.score).unwrap())
            .map(|c| c.chain.clone())
            .unwrap_or_default();
        let mut out = vec![score.name.clone()];
        out.extend(chain);
        out
    }

    fn reason(&self, hidden: f64, single_caller_callees: &[String]) -> String {
        if single_caller_callees.is_empty() {
            format!(
                "same-owner call chain adds {} weighted cognitive points",
                hidden
            )
        } else {
            format!(
                "{} single-caller helper(s) add {} weighted cognitive points",
                single_caller_callees.len(),
                hidden
            )
        }
    }

    fn round(&self, value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }
}
