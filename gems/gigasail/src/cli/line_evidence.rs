//! Per-line evidence view-model for the diff review right pane.
//!
//! Distilled from the plan's line annotations and SARIF findings. `LineEvidence`
//! carries only what the renderer needs (coverage mark, gutter glyphs, drop-down
//! detail); `aggregate_unit_evidence` folds a unit's line span into the
//! risk-scoring `Evidence` used by the collapse tree.

use crate::cli::diff::risk::{CoverageState, Evidence};
use crate::cli::diff::units::ChangedUnit;
use crate::cli::gutter::GutterKind;

/// One SARIF finding on a line, for the drop-down detail.
#[derive(Debug, Clone, PartialEq)]
pub struct FindingDetail {
    pub gutter: GutterKind,
    pub tool: String,
    pub rule: String,
    pub message: String,
    pub tier: Option<i64>,
}

/// One hazard on a line, for the drop-down detail.
#[derive(Debug, Clone, PartialEq)]
pub struct HazardDetail {
    pub hazard_type: String,
    pub verified: bool,
    pub required_evidence: String,
}

/// A single source line's evidence.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LineEvidence {
    pub line: u32,
    pub covered: bool,
    /// Whether coverage was actually measured for this line. When false, `covered`
    /// is meaningless (no data), so the UI shows no coverage mark rather than a
    /// misleading "uncovered".
    pub covered_known: bool,
    pub is_partial: bool,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
    pub dark_arms: Vec<String>,
    pub hazards: Vec<HazardDetail>,
    pub findings: Vec<FindingDetail>,
    /// De-duplicated gutter categories to draw for this line.
    pub gutters: Vec<GutterKind>,
}

/// Aggregate the evidence of the lines within a unit's span into `Evidence`.
pub fn aggregate_unit_evidence(unit: &ChangedUnit, lines: &[LineEvidence]) -> Evidence {
    let span: Vec<&LineEvidence> = lines
        .iter()
        .filter(|l| l.line >= unit.start_line && l.line <= unit.end_line)
        .collect();

    if span.is_empty() {
        return Evidence::default();
    }

    let mut ev = Evidence::default();
    let mut covered = false;
    let mut is_partial = false;
    let mut distinct_tests = 0i64;
    let mut mutant_killed = 0i64;
    let mut span_uncovered = 0u32;
    let mut has_coverage = false;

    for line in &span {
        is_partial |= line.is_partial;
        distinct_tests = distinct_tests.max(line.distinct_tests);
        mutant_killed = mutant_killed.max(line.mutant_killed_tests);
        // Only count coverage where it was actually measured.
        if line.covered_known {
            has_coverage = true;
            if line.covered {
                covered = true;
            } else {
                span_uncovered += 1;
            }
        }
        ev.dark_arm_findings += line.dark_arms.len() as u32;
        for hazard in &line.hazards {
            ev.hazards_total += 1;
            if !hazard.verified {
                ev.hazards_uncovered += 1;
            }
        }
        for finding in &line.findings {
            match finding.tier {
                Some(1) => ev.t1_findings += 1,
                Some(2) => ev.t2_findings += 1,
                _ => ev.t3_findings += 1,
            }
        }
    }

    // Uncovered *changed* LoC: only the unit's actually-added lines that were
    // measured-and-not-covered (pre-existing uncovered lines are excluded).
    ev.uncovered_changed_loc = unit
        .added_lines
        .iter()
        .filter(|n| {
            span.iter()
                .find(|l| l.line == **n)
                .map(|l| l.covered_known && !l.covered)
                .unwrap_or(false)
        })
        .count() as u32;
    // A unit with both covered and uncovered lines is partially covered.
    let partial = is_partial || (covered && span_uncovered > 0);
    // Evidence exists if coverage was measured or a test/mutant touched the unit.
    let has_evidence = has_coverage || distinct_tests > 0 || mutant_killed > 0;
    ev.coverage = CoverageState::derive(
        covered,
        partial,
        distinct_tests,
        mutant_killed,
        has_evidence,
    );
    ev
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::risk::Evidence;
    use crate::cli::diff::visibility::Visibility;
    use crate::model::UnitKind;

    fn unit(start: u32, end: u32, added: u32) -> ChangedUnit {
        ChangedUnit {
            name: "f".into(),
            kind: UnitKind::Function,
            path: "a.rs".into(),
            start_line: start,
            end_line: end,
            signature: String::new(),
            visibility: Visibility::Public,
            is_test: false,
            added,
            removed: 0,
            // The added lines are the first `added` lines of the span.
            added_lines: (start..start + added).collect(),
            evidence: Evidence::default(),
        }
    }

    fn line(n: u32) -> LineEvidence {
        LineEvidence {
            line: n,
            covered: true,
            covered_known: true,
            ..Default::default()
        }
    }

    fn hazard(verified: bool) -> HazardDetail {
        HazardDetail {
            hazard_type: "null-deref".into(),
            verified,
            required_evidence: "loom".into(),
        }
    }

    fn finding(tier: Option<i64>) -> FindingDetail {
        FindingDetail {
            gutter: GutterKind::Sarif,
            tool: "t".into(),
            rule: "r".into(),
            message: "m".into(),
            tier,
        }
    }

    #[test]
    fn no_lines_in_span_is_unknown() {
        let u = unit(10, 20, 5);
        let ev = aggregate_unit_evidence(&u, &[line(1), line(2)]);
        assert_eq!(ev.coverage, CoverageState::Unknown);
    }

    #[test]
    fn counts_hazards_tiers_and_dark_arms() {
        let u = unit(1, 3, 3);
        let lines = vec![
            LineEvidence {
                line: 1,
                covered: false,
                hazards: vec![hazard(false), hazard(true)],
                findings: vec![finding(Some(1)), finding(Some(2))],
                dark_arms: vec!["arm".into()],
                ..Default::default()
            },
            LineEvidence {
                line: 2,
                covered: true,
                findings: vec![finding(Some(3)), finding(None)],
                ..Default::default()
            },
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        assert_eq!(ev.hazards_total, 2);
        assert_eq!(ev.hazards_uncovered, 1);
        assert_eq!(ev.t1_findings, 1);
        assert_eq!(ev.t2_findings, 1);
        assert_eq!(ev.t3_findings, 2); // Some(3) and None both count as T3
        assert_eq!(ev.dark_arm_findings, 1);
    }

    #[test]
    fn coverage_state_and_uncovered_loc() {
        let u = unit(1, 4, 2);
        let known = |line, covered| LineEvidence {
            line,
            covered,
            covered_known: true,
            ..Default::default()
        };
        let lines = vec![
            known(1, false),
            known(2, false),
            known(3, false),
            known(4, true),
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        // 3 uncovered lines, but only 2 lines were added -> capped at added.
        assert_eq!(ev.uncovered_changed_loc, 2);
        // At least one covered line, some uncovered -> partial.
        assert_eq!(ev.coverage, CoverageState::Partial);
    }

    #[test]
    fn uncovered_changed_loc_ignores_preexisting_uncovered_lines() {
        // Unit spans 1..=5. Lines 1-3 are pre-existing uncovered; only lines
        // 4-5 were actually added, and they ARE covered. uncovered_changed_loc
        // must be 0, not 3.
        let mut u = unit(1, 5, 2);
        u.added_lines = vec![4, 5];
        let known = |line, covered| LineEvidence {
            line,
            covered,
            covered_known: true,
            ..Default::default()
        };
        let lines = vec![
            known(1, false),
            known(2, false),
            known(3, false),
            known(4, true),
            known(5, true),
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        assert_eq!(ev.uncovered_changed_loc, 0);
    }

    #[test]
    fn uncovered_changed_loc_counts_only_added_uncovered() {
        // Added lines 4-5 are uncovered; pre-existing uncovered lines 1-3 do not
        // inflate the count.
        let mut u = unit(1, 5, 2);
        u.added_lines = vec![4, 5];
        let known = |line, covered| LineEvidence {
            line,
            covered,
            covered_known: true,
            ..Default::default()
        };
        let lines = vec![
            known(1, false),
            known(2, false),
            known(3, false),
            known(4, false),
            known(5, false),
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        assert_eq!(ev.uncovered_changed_loc, 2);
    }

    #[test]
    fn unmeasured_coverage_is_unknown_not_uncovered() {
        // Lines with findings but no coverage measurement must not read as
        // "uncovered" (this was the ✗-on-every-line bug).
        let u = unit(1, 2, 2);
        let lines = vec![
            LineEvidence {
                line: 1,
                covered: false,
                covered_known: false,
                ..Default::default()
            },
            LineEvidence {
                line: 2,
                covered: false,
                covered_known: false,
                ..Default::default()
            },
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        assert_eq!(ev.coverage, CoverageState::Unknown);
        assert_eq!(ev.uncovered_changed_loc, 0);
    }

    #[test]
    fn killed_mutant_lifts_state() {
        let u = unit(1, 2, 2);
        let lines = vec![
            LineEvidence {
                line: 1,
                covered: true,
                covered_known: true,
                distinct_tests: 2,
                mutant_killed_tests: 1,
                ..Default::default()
            },
            LineEvidence {
                line: 2,
                covered: true,
                covered_known: true,
                ..Default::default()
            },
        ];
        let ev = aggregate_unit_evidence(&u, &lines);
        assert_eq!(ev.coverage, CoverageState::CoveredKilled);
        assert_eq!(ev.uncovered_changed_loc, 0);
    }
}
