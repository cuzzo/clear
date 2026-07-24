//! The top-level diff summary ("funnel"): a language-aware breakdown of the
//! change, from total lines down to per-language public/private/other code,
//! with a coverage bar and hazard/finding totals.
//!
//! All counts are derived from the render-independent [`DiffPlan`]: the
//! `language_summaries` carry production/test line splits, verification slices,
//! and public/private/unknown breakdowns; the per-file `added_lines`/
//! `removed_lines` carry the overall totals. Hazard and tier-finding totals are
//! aggregated from the changed units so they match the tree.

use crate::cli::diff::units::FileChange;
use crate::diff::{DiffPlan, VerificationSlices};

/// Proportional coverage of changed production code, in line counts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CoverageBar {
    pub covered_killed: u32,
    pub covered: u32,
    pub partial: u32,
    pub uncovered: u32,
    pub unknown: u32,
}

impl CoverageBar {
    fn add_slices(&mut self, s: &VerificationSlices) {
        self.covered_killed += s.covered_and_killed as u32;
        self.covered += s.covered as u32;
        self.partial += s.partially_covered as u32;
        self.uncovered += s.not_covered as u32;
        self.unknown += s.unknown as u32;
    }

    pub fn total(&self) -> u32 {
        self.covered_killed + self.covered + self.partial + self.uncovered + self.unknown
    }
}

fn slice_total(s: &VerificationSlices) -> u32 {
    (s.covered_and_killed + s.covered + s.partially_covered + s.not_covered + s.unknown) as u32
}

/// Aggregated hazard and tier-finding totals across the change.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HazardTotals {
    pub hazards: u32,
    pub t1: u32,
    pub t2: u32,
    pub t3: u32,
}

impl HazardTotals {
    pub fn is_empty(&self) -> bool {
        self.hazards + self.t1 + self.t2 + self.t3 == 0
    }
}

/// One language's production-code breakdown by visibility, with its coverage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LangRow {
    pub language: String,
    pub public: u32,
    pub private: u32,
    pub other: u32,
    pub bar: CoverageBar,
}

/// The funnel, widest row first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DiffSummary {
    pub total_added: u32,
    pub total_removed: u32,
    /// Added source-code lines (production + test).
    pub code_added: u32,
    /// Added non-code lines (comments, docs, config, other).
    pub other_added: u32,
    pub prod_code: u32,
    pub test_code: u32,
    /// Production code lines by visibility.
    pub public: u32,
    pub private: u32,
    pub other_vis: u32,
    /// Coverage of all production code.
    pub bar: CoverageBar,
    pub hazards: HazardTotals,
    pub langs: Vec<LangRow>,
}

/// Build the funnel from the plan (line splits, coverage, visibility) and the
/// changed units (hazard/tier totals, so they match the tree).
pub fn build_summary(plan: &DiffPlan, changes: &[FileChange]) -> DiffSummary {
    let mut summary = DiffSummary::default();

    for file in &plan.files {
        let a = &file.added_lines;
        summary.total_added += (a.code + a.comments + a.other) as u32;
        let r = &file.removed_lines;
        summary.total_removed += (r.code + r.comments + r.other) as u32;
    }

    for lang in &plan.language_summaries {
        let prod = lang.production.code as u32;
        let test = lang.test.code as u32;
        summary.prod_code += prod;
        summary.test_code += test;
        summary.code_added += prod + test;

        let vis = &lang.production_by_visibility;
        let public = slice_total(&vis.public);
        let private = slice_total(&vis.private);
        let other = slice_total(&vis.unknown);
        summary.public += public;
        summary.private += private;
        summary.other_vis += other;
        summary.bar.add_slices(&lang.production_verification);

        summary.langs.push(LangRow {
            language: lang.language.clone(),
            public,
            private,
            other,
            bar: {
                let mut bar = CoverageBar::default();
                bar.add_slices(&lang.production_verification);
                bar
            },
        });
    }

    // Non-code additions are whatever is left after the recognized source code.
    summary.other_added = summary.total_added.saturating_sub(summary.code_added);

    // Hazards and tier findings from the changed units, matching the tree.
    for change in changes {
        for unit in &change.units {
            let ev = &unit.evidence;
            summary.hazards.hazards += ev.hazards_total;
            summary.hazards.t1 += ev.t1_findings;
            summary.hazards.t2 += ev.t2_findings;
            summary.hazards.t3 += ev.t3_findings;
        }
    }

    // Riskiest / largest languages first.
    summary
        .langs
        .sort_by(|a, b| (b.public + b.private + b.other).cmp(&(a.public + a.private + a.other)));
    summary
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::gitdiff::ChangeStatus;
    use crate::cli::diff::risk::Evidence;
    use crate::cli::diff::units::ChangedUnit;
    use crate::cli::diff::visibility::Visibility;
    use crate::diff::{
        build_diff_plan_with_renames, RevisionFile, VisibilityVerificationSlices,
    };
    use crate::model::UnitKind;
    use std::collections::BTreeMap;

    fn change_with_hazards() -> FileChange {
        FileChange {
            path: "a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![ChangedUnit {
                name: "f".into(),
                kind: UnitKind::Function,
                path: "a.rs".into(),
                start_line: 1,
                end_line: 2,
                signature: String::new(),
                visibility: Visibility::Public,
                is_test: false,
                added: 1,
                removed: 0,
                added_lines: vec![1],
                evidence: Evidence {
                    hazards_total: 4,
                    t1_findings: 10,
                    t2_findings: 3,
                    t3_findings: 1,
                    ..Default::default()
                },
            }],
            file_added: 1,
            file_removed: 0,
            unattributed_added: 0,
            unattributed_removed: 0,
        }
    }

    #[test]
    fn aggregates_totals_code_and_hazards() {
        // A real plan across two commits gives line splits and language summaries.
        let base = "pub fn a() {\n    let x = 1;\n}\n";
        let head =
            "pub fn a() {\n    let x = 1;\n    let y = 2;\n}\n\nfn helper() {\n    3;\n}\n";
        let plan = build_diff_plan_with_renames(
            "b".repeat(40),
            "h".repeat(40),
            vec![RevisionFile {
                path: "a.rs".into(),
                contents: Some(base.into()),
            }],
            vec![RevisionFile {
                path: "a.rs".into(),
                contents: Some(head.into()),
            }],
            BTreeMap::new(),
        );
        let summary = build_summary(&plan, &[change_with_hazards()]);
        assert!(summary.total_added > 0);
        assert!(summary.code_added > 0);
        assert_eq!(summary.hazards.hazards, 4);
        assert_eq!(summary.hazards.t1, 10);
        assert_eq!(summary.hazards.t2, 3);
        assert_eq!(summary.hazards.t3, 1);
        assert!(summary.langs.iter().any(|l| l.language == "rust"));
    }

    #[test]
    fn coverage_bar_sums_slices() {
        let mut bar = CoverageBar::default();
        bar.add_slices(&VerificationSlices {
            covered_and_killed: 2,
            covered: 3,
            partially_covered: 1,
            not_covered: 4,
            unknown: 0,
        });
        assert_eq!(bar.total(), 10);
        assert_eq!(bar.covered_killed, 2);
        assert_eq!(bar.uncovered, 4);
        // VisibilityVerificationSlices default is all-zero.
        let vis = VisibilityVerificationSlices::default();
        assert_eq!(slice_total(&vis.public), 0);
    }
}
