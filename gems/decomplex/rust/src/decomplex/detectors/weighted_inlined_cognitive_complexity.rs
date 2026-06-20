use crate::decomplex::ast::Span;
use crate::decomplex::detectors::{local_flow, structural_topology};
use crate::decomplex::syntax::{self, Document, Language, LocalComplexityScore};
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
    let summaries = local_flow::scan_documents(documents);
    scan_documents_with_summaries(documents, &summaries)
}

pub fn scan_documents_with_summaries(
    documents: &[Document],
    summaries: &[local_flow::MethodSummary],
) -> Vec<WeightedInlinedCognitiveComplexityRow> {
    let topology_report = structural_topology::scan_documents(documents);
    let topology = structural_topology::Graph::new(topology_report.methods, topology_report.edges);
    let complexity_scores = documents
        .iter()
        .flat_map(|document| {
            document
                .local_complexity_scores
                .iter()
                .map(|(id, score)| ((document.file.clone(), id.clone()), score.clone()))
        })
        .collect::<BTreeMap<_, _>>();

    let mut scores = BTreeMap::new();
    for summary in summaries {
        let owner = if summary.owner == "(top-level)" {
            format!("(top-level:{})", summary.file)
        } else {
            summary.owner.clone()
        };
        let id = format!("{}#{}", owner, summary.name);
        let score = complexity_scores
            .get(&(summary.file.clone(), summary.id.clone()))
            .cloned()
            .unwrap_or_else(|| LocalComplexityScore {
                score: 0.0,
                signals: BTreeMap::new(),
            });
        scores.insert(
            id.clone(),
            LocalScore {
                id,
                owner,
                name: summary.name.clone(),
                file: summary.file.clone(),
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

fn format_one_decimal(value: f64) -> String {
    format!("{value:.1}")
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
                    .fold(None, |best: Option<structural_topology::Edge>, edge| {
                        let Some(current) = best else {
                            return Some(edge);
                        };
                        if self.edge_weight(&edge.r#type) > self.edge_weight(&current.r#type) {
                            Some(edge)
                        } else {
                            Some(current)
                        }
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
            .fold(None, |best: Option<&Contribution>, contribution| {
                let Some(current) = best else {
                    return Some(contribution);
                };
                if contribution.score > current.score {
                    Some(contribution)
                } else {
                    Some(current)
                }
            })
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
                format_one_decimal(hidden)
            )
        } else {
            format!(
                "{} single-caller helper(s) add {} weighted cognitive points",
                single_caller_callees.len(),
                format_one_decimal(hidden)
            )
        }
    }

    fn round(&self, value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }
}
