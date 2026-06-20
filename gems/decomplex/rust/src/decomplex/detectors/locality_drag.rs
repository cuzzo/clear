use crate::decomplex::ast::Span;
use crate::decomplex::detectors::{local_flow, weighted_inlined_cognitive_complexity};
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct LocalityDragRow {
    pub at: String,
    pub file: String,
    pub owner: String,
    pub defn: String,
    pub method: String,
    pub line: usize,
    pub variable: String,
    pub defined_at: usize,
    pub used_at: usize,
    pub gap_lines: usize,
    pub gap_statements: usize,
    pub unrelated_statements: usize,
    pub setup_statements: usize,
    pub related_statements: usize,
    pub boundary_crossings: usize,
    pub local_complexity: f64,
    pub score: isize,
    pub definition_deps: Vec<String>,
    pub use_reads: Vec<String>,
    pub examples: Vec<Example>,
    pub boundaries: Vec<BoundaryInfo>,
    pub reason: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Example {
    pub line: usize,
    pub source: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct BoundaryInfo {
    pub line: usize,
    pub marker: String,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<LocalityDragRow>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<LocalityDragRow> {
    let summaries = local_flow::scan_documents(documents);
    let complexity_scores = weighted_inlined_cognitive_complexity::raw_complexity_scores(documents);
    scan_summaries_with_scores(summaries, complexity_scores)
}

pub fn scan_summaries(summaries: Vec<local_flow::MethodSummary>) -> Vec<LocalityDragRow> {
    let mut detector = LocalityDrag::new(summaries, BTreeMap::new());
    detector.findings()
}

fn scan_summaries_with_scores(
    summaries: Vec<local_flow::MethodSummary>,
    complexity_scores: BTreeMap<
        (String, usize, String),
        weighted_inlined_cognitive_complexity::ScoreResult,
    >,
) -> Vec<LocalityDragRow> {
    let mut detector = LocalityDrag::new(summaries, complexity_scores);
    detector.findings()
}

struct LocalityDrag {
    summaries: Vec<local_flow::MethodSummary>,
    min_unrelated_statements: usize,
    min_gap_lines: usize,
    min_local_complexity: f64,
    min_score: isize,
    max_findings_per_method: usize,
    complexity_scores:
        BTreeMap<(String, usize, String), weighted_inlined_cognitive_complexity::ScoreResult>,
}

impl LocalityDrag {
    fn new(
        summaries: Vec<local_flow::MethodSummary>,
        complexity_scores: BTreeMap<
            (String, usize, String),
            weighted_inlined_cognitive_complexity::ScoreResult,
        >,
    ) -> Self {
        Self {
            summaries,
            min_unrelated_statements: 4,
            min_gap_lines: 8,
            min_local_complexity: 12.0,
            min_score: 60,
            max_findings_per_method: 3,
            complexity_scores,
        }
    }

    fn findings(&mut self) -> Vec<LocalityDragRow> {
        let mut out: Vec<_> = self
            .summaries
            .iter()
            .flat_map(|s| self.findings_for(s))
            .collect();
        out.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| b.unrelated_statements.cmp(&a.unrelated_statements))
                .then_with(|| b.gap_lines.cmp(&a.gap_lines))
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.line.cmp(&b.line))
        });
        out
    }

    fn findings_for(&self, summary: &local_flow::MethodSummary) -> Vec<LocalityDragRow> {
        if summary.statements.len() < self.min_unrelated_statements + 2 {
            return Vec::new();
        }

        let local_complexity = self.local_complexity(summary);
        if local_complexity < self.min_local_complexity {
            return Vec::new();
        }

        let mut findings = Vec::new();
        for (index, statement) in summary.statements.iter().enumerate() {
            for name in &statement.writes {
                if let Some(f) =
                    self.finding_for_write(summary, local_complexity, statement, index, name)
                {
                    findings.push(f);
                }
            }
        }

        findings.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.defined_at.cmp(&b.defined_at))
                .then_with(|| a.variable.cmp(&b.variable))
        });
        findings
            .into_iter()
            .take(self.max_findings_per_method)
            .collect()
    }

    fn local_complexity(&self, summary: &local_flow::MethodSummary) -> f64 {
        self.complexity_scores
            .get(&(summary.file.clone(), summary.line, summary.name.clone()))
            .map(|score| score.score)
            .unwrap_or_else(|| {
                let scorer = weighted_inlined_cognitive_complexity::LocalScorer::new();
                summary
                    .raw_node
                    .as_ref()
                    .map(|node| scorer.score_raw(node).score)
                    .unwrap_or_else(|| scorer.score(&summary.node).score)
            })
    }

    fn finding_for_write(
        &self,
        summary: &local_flow::MethodSummary,
        local_complexity: f64,
        statement: &local_flow::Statement,
        index: usize,
        name: &str,
    ) -> Option<LocalityDragRow> {
        if self.ignorable_local(name) {
            return None;
        }

        let use_index = self.first_read_before_rewrite(&summary.statements, index, name)?;
        if self.same_prefix_staging_batch(&summary.statements, use_index, name) {
            return None;
        }

        let gap = &summary.statements[(index + 1)..use_index];
        if gap.is_empty() {
            return None;
        }

        let gap_refs: Vec<_> = gap.iter().collect();
        let (related, unrelated) = self.classify_gap_statements(name, statement, &gap_refs);
        let substantive_unrelated: Vec<_> = unrelated
            .into_iter()
            .filter(|s| !self.trivial_initializer(s))
            .collect();
        if substantive_unrelated.len() < self.min_unrelated_statements {
            return None;
        }

        let use_statement = &summary.statements[use_index];
        let gap_lines = use_statement.line - statement.line;
        let boundaries = self.boundary_crossings(summary, index, use_index);
        if gap_lines < self.min_gap_lines && boundaries.is_empty() {
            return None;
        }

        let score = self.score_for(
            name,
            &substantive_unrelated,
            &related,
            gap_lines,
            &boundaries,
            local_complexity,
            self.read_count_after_write(&summary.statements, index, name),
        );
        if score < self.min_score {
            return None;
        }

        let at = format!("{}:{}:{}", summary.file, summary.name, statement.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), summary.span);

        Some(LocalityDragRow {
            at,
            file: summary.file.clone(),
            owner: summary.owner.clone(),
            defn: summary.name.clone(),
            method: summary.name.clone(),
            line: statement.line,
            variable: name.to_string(),
            defined_at: statement.line,
            used_at: use_statement.line,
            gap_lines,
            gap_statements: gap.len(),
            unrelated_statements: substantive_unrelated.len(),
            setup_statements: (gap.len() - related.len()) - substantive_unrelated.len(),
            related_statements: related.len(),
            boundary_crossings: boundaries.len(),
            local_complexity: self.round(local_complexity),
            score,
            definition_deps: self.definition_deps(statement, name).into_iter().collect(),
            use_reads: use_statement.reads.iter().cloned().collect(),
            examples: substantive_unrelated
                .iter()
                .take(3)
                .map(|s| self.example_for(s))
                .collect(),
            boundaries: boundaries.iter().map(|b| self.boundary_for(b)).collect(),
            reason: self.reason_for(
                name,
                &substantive_unrelated,
                gap_lines,
                &boundaries,
                local_complexity,
            ),
            spans,
        })
    }

    fn first_read_before_rewrite(
        &self,
        statements: &[local_flow::Statement],
        index: usize,
        name: &str,
    ) -> Option<usize> {
        for (offset, statement) in statements.iter().skip(index + 1).enumerate() {
            if statement.writes.contains(name) {
                return None;
            }
            if statement.reads.contains(name) {
                return Some(index + 1 + offset);
            }
        }
        None
    }

    fn read_count_after_write(
        &self,
        statements: &[local_flow::Statement],
        index: usize,
        name: &str,
    ) -> usize {
        statements
            .iter()
            .skip(index + 1)
            .filter(|s| s.reads.contains(name))
            .count()
    }

    fn classify_gap_statements<'a>(
        &self,
        name: &str,
        definition: &local_flow::Statement,
        gap: &'a [&local_flow::Statement],
    ) -> (
        Vec<&'a local_flow::Statement>,
        Vec<&'a local_flow::Statement>,
    ) {
        let mut related_names = BTreeSet::new();
        related_names.insert(name.to_string());
        for d in self.definition_deps(definition, name) {
            related_names.insert(d);
        }

        let mut related = Vec::new();
        let mut unrelated = Vec::new();
        for s in gap {
            let new_related = self.derived_from_related(s, &related_names);
            let touched: BTreeSet<_> = s.reads.union(&s.writes).cloned().collect();
            let touches_related = !touched.is_disjoint(&related_names);
            if touches_related || !new_related.is_empty() {
                related.push(*s);
                for n in new_related {
                    related_names.insert(n);
                }
            } else {
                unrelated.push(*s);
            }
        }
        (related, unrelated)
    }

    fn definition_deps(&self, statement: &local_flow::Statement, name: &str) -> BTreeSet<String> {
        statement
            .dependencies
            .iter()
            .filter(|(lhs, _)| lhs == name)
            .map(|(_, rhs)| rhs.clone())
            .collect()
    }

    fn derived_from_related(
        &self,
        statement: &local_flow::Statement,
        related_names: &BTreeSet<String>,
    ) -> BTreeSet<String> {
        statement
            .dependencies
            .iter()
            .filter(|(_, rhs)| related_names.contains(rhs))
            .map(|(lhs, _)| lhs.clone())
            .collect()
    }

    fn boundary_crossings<'a>(
        &self,
        summary: &'a local_flow::MethodSummary,
        definition_index: usize,
        use_index: usize,
    ) -> Vec<&'a local_flow::Boundary> {
        summary
            .boundaries
            .iter()
            .filter(|b| b.before_index >= definition_index && b.after_index <= use_index)
            .collect()
    }

    fn score_for(
        &self,
        variable: &str,
        unrelated: &[&local_flow::Statement],
        related: &[&local_flow::Statement],
        gap_lines: usize,
        boundaries: &[&local_flow::Boundary],
        local_complexity: f64,
        read_count: usize,
    ) -> isize {
        let mut score = (unrelated.len() as isize * 5)
            + (gap_lines.min(30) as isize)
            + (boundaries.len() as isize * 8)
            + (local_complexity.min(25.0).round() as isize);
        if read_count == 1 {
            score += 5;
        }
        if self.benign_local(variable) {
            score -= 8;
        }
        score -= related.len() as isize * 2;
        score
    }

    fn ignorable_local(&self, name: &str) -> bool {
        name.starts_with('_') || self.source_location_local(name)
    }

    fn same_prefix_staging_batch(
        &self,
        statements: &[local_flow::Statement],
        use_index: usize,
        name: &str,
    ) -> bool {
        let Some(prefix) = self.staging_prefix(name) else {
            return false;
        };
        let staged_names: BTreeSet<_> = statements
            .iter()
            .take(use_index)
            .flat_map(|s| s.writes.iter())
            .filter(|n| n.starts_with(&format!("{}_", prefix)))
            .cloned()
            .collect();
        if staged_names.len() < 4 {
            return false;
        }
        let use_reads = &statements[use_index].reads;
        staged_names.intersection(use_reads).count() >= 4
    }

    fn trivial_initializer(&self, statement: &local_flow::Statement) -> bool {
        if statement.writes.is_empty() || !statement.reads.is_empty() {
            return false;
        }
        let source = statement.source.trim();
        let re = regex::Regex::new(
            r"^\w+\s*=\s*(?:\{\}|\[\]|nil|false|true|0|T\.let\((?:nil|false|true|0)\b)",
        )
        .unwrap();
        re.is_match(source)
    }

    fn staging_prefix(&self, name: &str) -> Option<String> {
        let parts: Vec<_> = name.split('_').collect();
        if parts.len() >= 2 && parts[0].len() >= 3 {
            Some(parts[0].to_string())
        } else {
            None
        }
    }

    fn benign_local(&self, name: &str) -> bool {
        self.source_location_local(name)
    }

    fn source_location_local(&self, name: &str) -> bool {
        let re = regex::Regex::new(r"(?i)(?:\A|_)(?:tok|token|span|source|source_code|line|column|col|pos|idx|index|loc|location)(?:\z|_)").unwrap();
        re.is_match(name)
    }

    fn example_for(&self, statement: &local_flow::Statement) -> Example {
        let source = statement.source.lines().next().unwrap_or("").trim();
        let source = truncate_example_source(source);
        Example {
            line: statement.line,
            source,
        }
    }

    fn boundary_for(&self, boundary: &local_flow::Boundary) -> BoundaryInfo {
        BoundaryInfo {
            line: boundary.line,
            marker: if boundary.text.is_empty() {
                boundary.kind.clone()
            } else {
                boundary.text.clone()
            },
        }
    }

    fn reason_for(
        &self,
        variable: &str,
        unrelated: &[&local_flow::Statement],
        gap_lines: usize,
        boundaries: &[&local_flow::Boundary],
        local_complexity: f64,
    ) -> String {
        let mut parts = vec![
            format!(
                "`{}` is initialized {} line(s) before first use",
                variable, gap_lines
            ),
            format!("{} unrelated intervening statement(s)", unrelated.len()),
        ];
        if !boundaries.is_empty() {
            parts.push(format!(
                "{} structural boundary crossing(s)",
                boundaries.len()
            ));
        }
        parts.push(format!(
            "method local complexity {:.1}",
            self.round(local_complexity)
        ));
        parts.join("; ")
    }

    fn round(&self, value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }
}

fn truncate_example_source(source: &str) -> String {
    if source.chars().count() <= 99 {
        return source.to_string();
    }

    let prefix: String = source.chars().take(96).collect();
    format!("{prefix}...")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncates_non_ascii_examples_on_character_boundaries() {
        let source = "value = \"✓\"".repeat(12);
        let truncated = truncate_example_source(&source);

        assert_eq!(truncated.chars().count(), 99);
        assert!(truncated.ends_with("..."));
    }
}
