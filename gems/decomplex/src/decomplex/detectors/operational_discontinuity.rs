use crate::decomplex::detectors::local_flow;
use crate::decomplex::syntax::{Document, Language, Span};
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

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
) -> Result<Vec<OperationalDiscontinuityRow>> {
    let summaries = local_flow::scan_files(files, language)?;
    Ok(scan_summaries(&summaries))
}

pub fn scan_documents(documents: &[Document]) -> Vec<OperationalDiscontinuityRow> {
    let summaries = local_flow::scan_documents(documents);
    scan_summaries(&summaries)
}

pub fn scan_summaries(summaries: &[local_flow::MethodSummary]) -> Vec<OperationalDiscontinuityRow> {
    let detector = OperationalDiscontinuity::new(summaries);
    detector.findings()
}

struct OperationalDiscontinuity<'a> {
    summaries: &'a [local_flow::MethodSummary],
    min_dead: usize,
    min_new: usize,
    max_continuing: usize,
    min_score: isize,
}

impl<'a> OperationalDiscontinuity<'a> {
    fn new(summaries: &'a [local_flow::MethodSummary]) -> Self {
        Self {
            summaries,
            min_dead: 2,
            min_new: 2,
            max_continuing: 1,
            min_score: 12,
        }
    }

    fn findings(&self) -> Vec<OperationalDiscontinuityRow> {
        let mut out: Vec<_> = self
            .summaries
            .iter()
            .filter_map(|s| self.finding_for(s))
            .collect();
        out.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.line.cmp(&b.line))
        });
        out
    }

    fn finding_for(
        &self,
        summary: &local_flow::MethodSummary,
    ) -> Option<OperationalDiscontinuityRow> {
        if summary.boundaries.is_empty() {
            return None;
        }

        let ranges = self.variable_ranges(summary);
        let resets: Vec<_> = summary
            .boundaries
            .iter()
            .filter_map(|b| self.reset_at(b, &ranges))
            .collect();
        if resets.is_empty() {
            return None;
        }

        let score = resets
            .iter()
            .map(|r| r.dead.len() as isize + r.new.len() as isize - r.continuing.len() as isize)
            .sum::<isize>()
            + (resets.len() as isize * 8);
        if score < self.min_score {
            return None;
        }

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
            confidence: if confidence_reasons.is_empty() {
                "review".to_string()
            } else {
                "high".to_string()
            },
            confidence_reasons,
            spans,
        })
    }

    fn confidence_reasons_for(
        &self,
        method_name: &str,
        score: isize,
        resets: &[ResetPoint],
    ) -> Vec<String> {
        let explicit_phase = resets.iter().any(|r| self.phase_marker(r));
        let mut reasons = Vec::new();
        if resets.len() >= 2 {
            reasons.push("repeated_resets".to_string());
        }
        if explicit_phase {
            reasons.push("explicit_phase_marker".to_string());
        }
        if score >= 20 {
            reasons.push("high_score".to_string());
        }

        if self.grammar_method(method_name) && !explicit_phase {
            reasons.retain(|r| r != "repeated_resets" && r != "high_score");
        }
        reasons
    }

    fn phase_marker(&self, reset: &ResetPoint) -> bool {
        let re =
            regex::Regex::new(r"(?i)^(?:#|//|--)\s*(?:\d+[a-z]?\s*[.)]|(?:phase|step|stage)\b)")
                .unwrap();
        re.is_match(&reset.text)
    }

    fn grammar_method(&self, method_name: &str) -> bool {
        let re = regex::Regex::new(r"^parse(?:_|$)").unwrap();
        re.is_match(method_name)
    }

    fn reset_at(
        &self,
        boundary: &local_flow::Boundary,
        ranges: &BTreeMap<String, RangeInfo>,
    ) -> Option<ResetPoint> {
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

        if dead.len() < self.min_dead
            || new_vars.len() < self.min_new
            || continuing.len() > self.max_continuing
        {
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
                ranges
                    .entry(name)
                    .and_modify(|r: &mut RangeInfo| r.last = statement.index)
                    .or_insert(RangeInfo {
                        first: statement.index,
                        last: statement.index,
                    });
            }
        }
        ranges
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_operational_discontinuity_gaps() {
        // 1. Create a Document with a method that gets filtered out due to score < 12 (score = 11)
        // dead = 2, new = 2, continuing = 1. score = 2+2-1+8 = 11.
        let doc_low_score: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "local_methods": [
                {
                    "id": "m1",
                    "owner": "Class",
                    "name": "low_score_method",
                    "file": "a.rb",
                    "line": 10,
                    "span": [10, 1, 15, 1],
                    "statements": [
                        {
                            "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                            "reads": ["d1", "d2", "c"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 1, "line": 11, "end_line": 11, "span": [11, 1, 11, 10], "source": "x",
                            "reads": ["d1", "d2", "c"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 3, "line": 13, "end_line": 13, "span": [13, 1, 13, 10], "source": "x",
                            "reads": ["n1", "n2", "c"], "writes": [], "dependencies": [], "co_uses": []
                        }
                    ],
                    "boundaries": [
                        {
                            "before_index": 1,
                            "after_index": 3,
                            "line": 12,
                            "kind": "comment",
                            "text": "# Step 1"
                        }
                    ]
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc_low_score]);
        assert!(report.is_empty());

        // 2. Create multiple documents to test sorting and confidence categories
        // Method A: score = 12 (review)
        // Method B: score = 20 (high_score, parse method -> reasons filtered)
        // Method C: repeated resets, phase marker -> score = 24
        let doc_main: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "local_methods": [
                {
                    "id": "mA",
                    "owner": "Class",
                    "name": "method_a",
                    "file": "a.rb",
                    "line": 10,
                    "span": [10, 1, 15, 1],
                    "statements": [
                        {
                            "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                            "reads": ["d1", "d2"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 2, "line": 12, "end_line": 12, "span": [12, 1, 12, 10], "source": "x",
                            "reads": ["n1", "n2"], "writes": [], "dependencies": [], "co_uses": []
                        }
                    ],
                    "boundaries": [
                        {
                            "before_index": 0,
                            "after_index": 2,
                            "line": 11,
                            "kind": "comment",
                            "text": "normal comment"
                        }
                    ]
                },
                {
                    "id": "mB",
                    "owner": "Class",
                    "name": "parse_method", // starts with parse, checks retain branch on line 168
                    "file": "a.rb",
                    "line": 20,
                    "span": [20, 1, 25, 1],
                    "statements": [
                        {
                            "index": 0, "line": 20, "end_line": 20, "span": [20, 1, 20, 10], "source": "x",
                            "reads": ["d1", "d2", "d3", "d4", "d5", "d6"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 2, "line": 22, "end_line": 22, "span": [22, 1, 22, 10], "source": "x",
                            "reads": ["n1", "n2", "n3", "n4", "n5", "n6"], "writes": [], "dependencies": [], "co_uses": []
                        }
                    ],
                    "boundaries": [
                        {
                            "before_index": 0,
                            "after_index": 2,
                            "line": 21,
                            "kind": "comment",
                            "text": "normal comment" // explicit_phase is false
                        }
                    ]
                }
            ]
        })).unwrap();

        let doc_main2: Document = serde_json::from_value(json!({
            "file": "b.rb",
            "language": "ruby",
            "local_methods": [
                {
                    "id": "mC",
                    "owner": "Class",
                    "name": "method_c",
                    "file": "b.rb",
                    "line": 10,
                    "span": [10, 1, 15, 1],
                    "statements": [
                        {
                            "index": 0, "line": 10, "end_line": 10, "span": [10, 1, 10, 10], "source": "x",
                            "reads": ["a1", "a2"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 2, "line": 12, "end_line": 12, "span": [12, 1, 12, 10], "source": "x",
                            "reads": ["b1", "b2"], "writes": [], "dependencies": [], "co_uses": []
                        },
                        {
                            "index": 4, "line": 14, "end_line": 14, "span": [14, 1, 14, 10], "source": "x",
                            "reads": ["c1", "c2"], "writes": [], "dependencies": [], "co_uses": []
                        }
                    ],
                    "boundaries": [
                        {
                            "before_index": 0,
                            "after_index": 2,
                            "line": 11,
                            "kind": "comment",
                            "text": "# 1. First Phase" // matches phase_marker
                        },
                        {
                            "before_index": 2,
                            "after_index": 4,
                            "line": 13,
                            "kind": "comment",
                            "text": "# Step 2" // matches phase_marker
                        }
                    ]
                }
            ]
        })).unwrap();

        let report = scan_documents(&[doc_main, doc_main2]);
        assert_eq!(report.len(), 3);

        // Sorting check: b.rb:method_c has 2 resets, score = 28.
        // parse_method has score = 20.
        // method_a has score = 12.
        assert_eq!(report[0].defn, "method_c");
        assert_eq!(report[0].score, 28);
        assert_eq!(report[0].confidence, "high");
        assert!(report[0].confidence_reasons.contains(&"repeated_resets".to_string()));
        assert!(report[0].confidence_reasons.contains(&"explicit_phase_marker".to_string()));
        assert!(report[0].confidence_reasons.contains(&"high_score".to_string()));

        assert_eq!(report[1].defn, "parse_method");
        assert_eq!(report[1].score, 20);
        // high_score should have been retained but grammar_method cleans it up since explicit_phase is false
        assert!(report[1].confidence_reasons.is_empty());
        assert_eq!(report[1].confidence, "review");

        assert_eq!(report[2].defn, "method_a");
        assert_eq!(report[2].score, 12);
        assert_eq!(report[2].confidence, "review");
    }
}
