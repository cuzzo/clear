use crate::decomplex::ast::{Span};
use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct OperationalDiscontinuityRow {
    pub file: String,
    pub defn: String,
    pub owner: String,
    pub method: String,
    pub line: usize,
    pub at: String,
    pub score: isize,
    pub resets: usize,
    pub dead_total: usize,
    pub new_total: usize,
    pub reset_points: Vec<ResetPoint>,
    pub confidence: String,
    pub confidence_reasons: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ResetPoint {
    pub line: usize,
    pub kind: String,
    pub text: String,
    pub before_statement: usize,
    pub after_statement: usize,
    pub dead: Vec<String>,
    pub new: Vec<String>,
    pub continuing: Vec<String>,
}

struct RangeInfo {
    first: usize,
    last: usize,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<Vec<OperationalDiscontinuityRow>> {
    let summaries = local_flow::scan_files(files, _language)?;
    let detector = OperationalDiscontinuity::new(summaries);
    Ok(detector.findings())
}

struct OperationalDiscontinuity {
    summaries: Vec<local_flow::MethodSummary>,
    min_dead: usize,
    min_new: usize,
    max_continuing: usize,
    min_score: isize,
}

impl OperationalDiscontinuity {
    fn new(summaries: Vec<local_flow::MethodSummary>) -> Self {
        Self {
            summaries,
            min_dead: 2,
            min_new: 2,
            max_continuing: 1,
            min_score: 12,
        }
    }

    fn findings(&self) -> Vec<OperationalDiscontinuityRow> {
        let mut out: Vec<_> = self.summaries.iter().filter_map(|s| self.finding_for(s)).collect();
        out.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.file.cmp(&b.file)).then_with(|| a.line.cmp(&b.line)));
        out
    }

    fn finding_for(&self, summary: &local_flow::MethodSummary) -> Option<OperationalDiscontinuityRow> {
        if summary.boundaries.is_empty() { return None }

        let ranges = self.variable_ranges(summary);
        let resets: Vec<_> = summary.boundaries.iter().filter_map(|b| self.reset_at(b, &ranges)).collect();
        if resets.is_empty() { return None }

        let score = resets.iter().map(|r| (r.dead.len() as isize + r.new.len() as isize - r.continuing.len() as isize)).sum::<isize>() + (resets.len() as isize * 8);
        if score < self.min_score { return None }

        let confidence_reasons = self.confidence_reasons_for(&summary.name, score, &resets);
        let at = format!("{}:{}:{}", summary.file, summary.name, summary.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), summary.span);

        Some(OperationalDiscontinuityRow {
            file: summary.file.clone(),
            defn: summary.name.clone(),
            owner: summary.owner.clone(),
            method: summary.name.clone(),
            line: summary.line,
            at,
            score,
            resets: resets.len(),
            dead_total: resets.iter().map(|r| r.dead.len()).sum(),
            new_total: resets.iter().map(|r| r.new.len()).sum(),
            reset_points: resets,
            confidence: if confidence_reasons.is_empty() { "review".to_string() } else { "high".to_string() },
            confidence_reasons,
            spans,
        })
    }

    fn confidence_reasons_for(&self, method_name: &str, score: isize, resets: &[ResetPoint]) -> Vec<String> {
        let explicit_phase = resets.iter().any(|r| self.phase_marker(r));
        let mut reasons = Vec::new();
        if resets.len() >= 2 { reasons.push("repeated_resets".to_string()); }
        if explicit_phase { reasons.push("explicit_phase_marker".to_string()); }
        if score >= 20 { reasons.push("high_score".to_string()); }
        
        if self.grammar_method(method_name) && !explicit_phase {
            reasons.retain(|r| r != "repeated_resets" && r != "high_score");
        }
        reasons
    }

    fn phase_marker(&self, reset: &ResetPoint) -> bool {
        let re = regex::Regex::new(r"(?i)^\#\s*(?:\d+[a-z]?\s*[.)]|(?:phase|step|stage)\b)").unwrap();
        re.is_match(&reset.text)
    }

    fn grammar_method(&self, method_name: &str) -> bool {
        let re = regex::Regex::new(r"^parse(?:_|$)").unwrap();
        re.is_match(method_name)
    }

    fn reset_at(&self, boundary: &local_flow::Boundary, ranges: &BTreeMap<String, RangeInfo>) -> Option<ResetPoint> {
        let before = boundary.before_index;
        let after = boundary.after_index;
        
        let mut dead = Vec::new();
        let mut continuing = Vec::new();
        let mut new_vars = Vec::new();

        for (name, range) in ranges {
            if range.first <= before {
                if range.last <= before {
                    dead.push(name.clone());
                }
                if range.last >= after {
                    continuing.push(name.clone());
                }
            }
            if range.first >= after {
                new_vars.push(name.clone());
            }
        }

        if dead.len() < self.min_dead || new_vars.len() < self.min_new || continuing.len() > self.max_continuing {
            return None;
        }

        dead.sort();
        new_vars.sort();
        continuing.sort();

        Some(ResetPoint {
            line: boundary.line,
            kind: boundary.kind.clone(),
            text: boundary.text.clone(),
            before_statement: before,
            after_statement: after,
            dead,
            new: new_vars,
            continuing,
        })
    }

    fn variable_ranges(&self, summary: &local_flow::MethodSummary) -> BTreeMap<String, RangeInfo> {
        let mut ranges = BTreeMap::new();
        for statement in &summary.statements {
            let touched: BTreeSet<_> = statement.reads.union(&statement.writes).cloned().collect();
            for name in touched {
                ranges.entry(name).and_modify(|r: &mut RangeInfo| r.last = statement.index).or_insert(RangeInfo { first: statement.index, last: statement.index });
            }
        }
        ranges
    }
}
