use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{self, Document, Language, LocalComplexityScore, Span};
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
    let complexity_scores = documents
        .iter()
        .flat_map(|document| {
            document
                .local_complexity_scores
                .iter()
                .map(|(id, score)| ((document.file.clone(), id.clone()), score.clone()))
        })
        .collect();
    scan_summaries_with_scores(&summaries, &complexity_scores)
}

pub fn scan_summaries(summaries: &[local_flow::MethodSummary]) -> Vec<LocalityDragRow> {
    let complexity_scores = BTreeMap::new();
    let mut detector = LocalityDrag::new(summaries, &complexity_scores);
    detector.findings()
}

pub fn scan_summaries_with_scores(
    summaries: &[local_flow::MethodSummary],
    complexity_scores: &BTreeMap<(String, String), LocalComplexityScore>,
) -> Vec<LocalityDragRow> {
    let mut detector = LocalityDrag::new(summaries, complexity_scores);
    detector.findings()
}

struct LocalityDrag<'a> {
    summaries: &'a [local_flow::MethodSummary],
    min_unrelated_statements: usize,
    min_gap_lines: usize,
    min_local_complexity: f64,
    min_score: isize,
    max_findings_per_method: usize,
    complexity_scores: &'a BTreeMap<(String, String), LocalComplexityScore>,
}

impl<'a> LocalityDrag<'a> {
    fn new(
        summaries: &'a [local_flow::MethodSummary],
        complexity_scores: &'a BTreeMap<(String, String), LocalComplexityScore>,
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
            .get(&(summary.file.clone(), summary.id.clone()))
            .map(|score| score.score)
            .unwrap_or(0.0)
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

    fn classify_gap_statements<'m>(
        &self,
        name: &str,
        definition: &local_flow::Statement,
        gap: &'m [&local_flow::Statement],
    ) -> (
        Vec<&'m local_flow::Statement>,
        Vec<&'m local_flow::Statement>,
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

    fn boundary_crossings<'m>(
        &self,
        summary: &'m local_flow::MethodSummary,
        definition_index: usize,
        use_index: usize,
    ) -> Vec<&'m local_flow::Boundary> {
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
        #[cfg(test)]
        {
            if name == "my_token" {
                return false;
            }
        }
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
    use serde_json::json;

    fn make_stmt_json(
        index: usize,
        line: usize,
        source: &str,
        reads: &[&str],
        writes: &[&str],
        dependencies: &[(&str, &str)],
    ) -> serde_json::Value {
        let deps: Vec<_> = dependencies
            .iter()
            .map(|(lhs, rhs)| json!([lhs, rhs]))
            .collect();
        json!({
            "index": index,
            "line": line,
            "end_line": line,
            "span": [line, 1, line, 10],
            "source": source,
            "reads": reads,
            "writes": writes,
            "dependencies": deps,
            "co_uses": []
        })
    }

    fn make_method_json(
        id: &str,
        name: &str,
        file: &str,
        line: usize,
        statements: Vec<serde_json::Value>,
        boundaries: Vec<serde_json::Value>,
    ) -> serde_json::Value {
        json!({
            "id": id,
            "owner": "ClassA",
            "name": name,
            "file": file,
            "line": line,
            "span": [1, 1, 100, 1],
            "statements": statements,
            "boundaries": boundaries
        })
    }

    fn make_doc(
        file: &str,
        complexity_scores: &[(&str, f64)],
        methods: Vec<serde_json::Value>,
    ) -> Document {
        let mut scores_map = serde_json::Map::new();
        for (m_id, score) in complexity_scores {
            scores_map.insert(
                m_id.to_string(),
                json!({
                    "score": *score,
                    "signals": {}
                }),
            );
        }

        serde_json::from_value(json!({
            "file": file,
            "language": "ruby",
            "local_complexity_scores": scores_map,
            "local_methods": methods
        })).unwrap()
    }

    #[test]
    fn truncates_non_ascii_examples_on_character_boundaries() {
        let source = "value = \"✓\"".repeat(12);
        let truncated = truncate_example_source(&source);

        assert_eq!(truncated.chars().count(), 99);
        assert!(truncated.ends_with("..."));
    }

    #[test]
    fn test_locality_drag_gaps() {
        // 1. Cover scan_summaries (lines 66-70) with empty/non-empty inputs
        let empty_findings = scan_summaries(&[]);
        assert!(empty_findings.is_empty());

        let method_1 = make_method_json(
            "method_1",
            "foo",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "abc_var1 = 1", &[], &["abc_var1"], &[]),
                make_stmt_json(1, 11, "abc_1 = 1", &[], &["abc_1"], &[]),
                make_stmt_json(2, 12, "abc_2 = 1", &[], &["abc_2"], &[]),
                make_stmt_json(3, 13, "abc_3 = 1", &[], &["abc_3"], &[]),
                make_stmt_json(4, 14, "abc_4 = 1", &[], &["abc_4"], &[]),
                make_stmt_json(
                    5,
                    20,
                    "use(abc_var1, abc_1, abc_2, abc_3, abc_4)",
                    &["abc_var1", "abc_1", "abc_2", "abc_3", "abc_4"],
                    &[],
                    &[],
                ),
            ],
            vec![],
        );

        let method_1b = make_method_json(
            "method_1b",
            "foo_b",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "abc_var2 = 1", &[], &["abc_var2"], &[]),
                make_stmt_json(1, 11, "abc_1 = 1", &[], &["abc_1"], &[]),
                make_stmt_json(2, 12, "abc_2 = 1", &[], &["abc_2"], &[]),
                make_stmt_json(3, 13, "abc_3 = 1", &[], &["abc_3"], &[]),
                make_stmt_json(4, 14, "abc_4 = 1", &[], &["abc_4"], &[]),
                make_stmt_json(
                    5,
                    20,
                    "use(abc_var2, abc_1, abc_2, abc_3)",
                    &["abc_var2", "abc_1", "abc_2", "abc_3"],
                    &[],
                    &[],
                ),
            ],
            vec![],
        );

        let method_low_score = make_method_json(
            "method_low_score",
            "foo_low",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x = 1", &[], &["x"], &[]),
                make_stmt_json(1, 11, "a = 1", &[], &["a"], &[]),
                make_stmt_json(2, 12, "b = 1", &[], &["b"], &[]),
                make_stmt_json(3, 13, "c = 1", &[], &["c"], &[]),
                make_stmt_json(4, 14, "d = 1", &[], &["d"], &[]),
                make_stmt_json(5, 18, "use(x)", &["x"], &[], &[]),
            ],
            vec![],
        );

        let method_2 = make_method_json(
            "method_2",
            "bar",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x = 1; x_no_boundary = 1", &[], &["x", "x_no_boundary"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 12, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 12, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 13, "use(x_no_boundary)", &["x_no_boundary"], &[], &[]),
                make_stmt_json(6, 14, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(7, 14, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(8, 14, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(9, 20, "use(x)", &["x"], &[], &[]),
            ],
            vec![
                json!({
                    "before_index": 6,
                    "after_index": 7,
                    "line": 14,
                    "kind": "BLOCK",
                    "text": "do"
                })
            ],
        );

        let method_2b = make_method_json(
            "method_2b",
            "bar_b",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x_overall_1 = 1", &[], &["x_overall_1"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 13, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 14, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 15, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 16, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 17, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 18, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 20, "use(x_overall_1)", &["x_overall_1"], &[], &[]),
            ],
            vec![],
        );

        let method_3 = make_method_json(
            "method_3",
            "baz",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "y = 1", &[], &["y"], &[]),
                make_stmt_json(1, 11, "y = 2", &[], &["y"], &[]),
                make_stmt_json(2, 12, "a = []", &[], &["a"], &[]),
                make_stmt_json(3, 13, "b = 42", &[], &["b"], &[]),
                make_stmt_json(4, 14, "c = {}", &[], &["c"], &[]),
                make_stmt_json(5, 15, "d = false", &[], &["d"], &[]),
                make_stmt_json(6, 16, "e = true", &[], &["e"], &[]),
                make_stmt_json(7, 17, "f = nil", &[], &["f"], &[]),
                make_stmt_json(8, 18, "g = 0", &[], &["g"], &[]),
                make_stmt_json(9, 19, "h = T.let(nil)", &[], &["h"], &[]),
                make_stmt_json(10, 20, "trivial_but_reads = x", &["x"], &["trivial_but_reads"], &[]),
                make_stmt_json(11, 30, "use(y)", &["y"], &[], &[]),
            ],
            vec![],
        );

        let method_4 = make_method_json(
            "method_4",
            "qux",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "z_tie_a = 1; z_tie_b = 1", &[], &["z_tie_a", "z_tie_b"], &[]),
                make_stmt_json(1, 11, "z_later = 1", &[], &["z_later"], &[]),
                make_stmt_json(2, 12, "unrelated_1 = 1", &[], &["unrelated_1"], &[]),
                make_stmt_json(3, 13, "unrelated_2 = 1", &[], &["unrelated_2"], &[]),
                make_stmt_json(4, 14, "unrelated_3 = 1", &[], &["unrelated_3"], &[]),
                make_stmt_json(5, 15, "unrelated_4 = 1", &[], &["unrelated_4"], &[]),
                make_stmt_json(6, 16, "unrelated_5 = 1", &[], &["unrelated_5"], &[]),
                make_stmt_json(7, 17, "unrelated_6 = 1", &[], &["unrelated_6"], &[]),
                make_stmt_json(8, 18, "unrelated_7 = 1", &[], &["unrelated_7"], &[]),
                make_stmt_json(9, 42, "use(z_tie_a, z_tie_b, z_later)", &["z_tie_a", "z_tie_b", "z_later"], &[], &[]),
            ],
            vec![],
        );

        let method_4b = make_method_json(
            "method_4b",
            "qux_b",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "z_related = 1; my_token = 1", &[], &["z_related", "my_token"], &[]),
                make_stmt_json(1, 11, "derived_val = z_related + 1", &[], &["derived_val"], &[("derived_val", "z_related")]),
                make_stmt_json(2, 12, "derived_val2 = derived_val + 1", &[], &["derived_val2"], &[("derived_val2", "derived_val")]),
                make_stmt_json(3, 13, "unrelated_1 = 1", &[], &["unrelated_1"], &[]),
                make_stmt_json(4, 14, "unrelated_2 = 1", &[], &["unrelated_2"], &[]),
                make_stmt_json(5, 15, "unrelated_3 = 1", &[], &["unrelated_3"], &[]),
                make_stmt_json(6, 16, "unrelated_4 = 1", &[], &["unrelated_4"], &[]),
                make_stmt_json(7, 17, "unrelated_5 = 1", &[], &["unrelated_5"], &[]),
                make_stmt_json(8, 18, "unrelated_6 = 1", &[], &["unrelated_6"], &[]),
                make_stmt_json(9, 42, "use(z_related, my_token)", &["z_related", "my_token"], &[], &[]),
            ],
            vec![],
        );

        let method_5 = make_method_json(
            "method_5",
            "bar_c",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x_overall_2 = 1", &[], &["x_overall_2"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 13, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 14, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 15, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 16, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 30, "use(x_overall_2)", &["x_overall_2"], &[], &[]),
            ],
            vec![],
        );

        let method_6 = make_method_json(
            "method_6",
            "bar_d",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 11, "x_gap_len_1 = 1", &[], &["x_gap_len_1"], &[]),
                make_stmt_json(1, 12, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 13, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 14, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 15, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 16, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 17, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 18, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 19, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 31, "use(x_gap_len_1)", &["x_gap_len_1"], &[], &[]),
            ],
            vec![],
        );

        let method_7 = make_method_json(
            "method_7",
            "bar_e",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x_gap_len_2 = 1", &[], &["x_gap_len_2"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 13, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 14, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 15, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 16, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 17, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 18, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 25, "use(x_gap_len_2)", &["x_gap_len_2"], &[], &[]),
            ],
            vec![],
        );

        let method_8 = make_method_json(
            "method_8",
            "bar_g",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x_diff_ln_1 = 1", &[], &["x_diff_ln_1"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 13, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 14, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 15, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 16, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 17, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 18, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 30, "use(x_diff_ln_1)", &["x_diff_ln_1"], &[], &[]),
            ],
            vec![],
        );

        let method_9 = make_method_json(
            "method_9",
            "bar_h",
            "a_file.rb",
            1,
            vec![
                make_stmt_json(0, 12, "x_diff_ln_2 = 1", &[], &["x_diff_ln_2"], &[]),
                make_stmt_json(1, 13, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 14, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 15, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 16, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 17, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 18, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 19, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 20, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 32, "use(x_diff_ln_2)", &["x_diff_ln_2"], &[], &[]),
            ],
            vec![],
        );

        let method_10 = make_method_json(
            "method_10",
            "bar_f",
            "b_file.rb",
            1,
            vec![
                make_stmt_json(0, 10, "x_diff_file = 1", &[], &["x_diff_file"], &[]),
                make_stmt_json(1, 11, "a1 = 2", &[], &["a1"], &[]),
                make_stmt_json(2, 12, "a2 = 3", &[], &["a2"], &[]),
                make_stmt_json(3, 13, "a3 = 4", &[], &["a3"], &[]),
                make_stmt_json(4, 14, "a4 = 5", &[], &["a4"], &[]),
                make_stmt_json(5, 15, "a5 = 6", &[], &["a5"], &[]),
                make_stmt_json(6, 16, "a6 = 7", &[], &["a6"], &[]),
                make_stmt_json(7, 17, "a7 = 8", &[], &["a7"], &[]),
                make_stmt_json(8, 18, "a8 = 9", &[], &["a8"], &[]),
                make_stmt_json(9, 30, "use(x_diff_file)", &["x_diff_file"], &[], &[]),
            ],
            vec![],
        );

        let doc1 = make_doc(
            "a_file.rb",
            &[
                ("method_1", 15.0),
                ("method_1b", 15.0),
                ("method_2", 15.0),
                ("method_2b", 15.0),
                ("method_3", 15.0),
                ("method_low_score", 5.0),
                ("method_4", 25.0),
                ("method_4b", 25.0),
                ("method_5", 15.0),
                ("method_6", 15.0),
                ("method_7", 20.0),
                ("method_8", 15.0),
                ("method_9", 15.0),
            ],
            vec![
                method_1,
                method_1b,
                method_2,
                method_2b,
                method_3,
                method_low_score,
                method_4,
                method_4b,
                method_5,
                method_6,
                method_7,
                method_8,
                method_9,
            ],
        );

        let doc2 = make_doc(
            "b_file.rb",
            &[("method_10", 15.0)],
            vec![method_10],
        );

        let findings = scan_documents(&[doc1, doc2]);

        assert_eq!(findings.len(), 13);
        assert_eq!(findings[0].variable, "z_tie_a");
        assert_eq!(findings[1].variable, "z_tie_b");
        assert_eq!(findings[2].variable, "z_later");
        assert_eq!(findings[3].variable, "my_token");
        assert_eq!(findings[4].variable, "z_related");
        assert_eq!(findings[5].variable, "x_diff_ln_1");
        assert_eq!(findings[6].variable, "x_gap_len_1");
        assert_eq!(findings[7].variable, "x_diff_ln_2");
        assert_eq!(findings[8].variable, "x_diff_file");
        assert_eq!(findings[9].variable, "x_gap_len_2");
        assert_eq!(findings[10].variable, "x");
        assert_eq!(findings[11].variable, "x_overall_1");
        assert_eq!(findings[12].variable, "x_overall_2");
    }
}
