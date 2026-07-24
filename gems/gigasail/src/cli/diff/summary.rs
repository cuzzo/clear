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
use crate::diff::{DiffPlan, SourceRole, VerificationSlices};

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

    /// Lines whose coverage status is actually known. Zero means the change has
    /// no coverage data (everything is `unknown`), so the bar reads
    /// "NO COVERAGE DATA" rather than showing an all-red bar.
    pub fn measured(&self) -> u32 {
        self.covered_killed + self.covered + self.partial + self.uncovered
    }

    pub fn has_coverage(&self) -> bool {
        self.measured() > 0
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

/// One language's production-code breakdown by visibility, with its coverage
/// and hazard/tier findings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LangRow {
    pub language: String,
    pub public: u32,
    pub private: u32,
    pub other: u32,
    pub bar: CoverageBar,
    pub hazards: HazardTotals,
}

/// One non-code file type in the OTHER section (Markdown, YAML, Dockerfile...).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OtherRow {
    pub type_label: String,
    pub added: u32,
    pub removed: u32,
}

/// Added / removed / version-changed dependency counts across all manifests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DepSummary {
    pub added: u32,
    pub removed: u32,
    pub changed: u32,
}

impl DepSummary {
    pub fn is_empty(&self) -> bool {
        self.added + self.removed + self.changed == 0
    }
}

/// A display type for a non-code file, from its name/extension. giga-core owns
/// the code-vs-non-code decision (the file's `role`); this only groups the
/// non-code files for the OTHER table.
pub fn other_type(path: &str) -> &'static str {
    let file = path.rsplit('/').next().unwrap_or(path);
    let lower = file.to_ascii_lowercase();
    let ext = lower.rsplit('.').next().unwrap_or("");
    if lower.starts_with("dockerfile") {
        return "Dockerfile";
    }
    if lower == "makefile" || lower == "gnumakefile" || ext == "mk" {
        return "Makefile";
    }
    if lower.starts_with("gemfile") {
        return "Gemfile";
    }
    if lower == "rakefile" {
        return "Rakefile";
    }
    if file == "BUILD" || file == "WORKSPACE" || ext == "bzl" || ext == "bazel" {
        return "Bazel";
    }
    match ext {
        "md" | "markdown" => "Markdown",
        "yml" | "yaml" => "YAML",
        "json" => "JSON",
        "toml" => "TOML",
        "xml" => "XML",
        "ini" | "cfg" | "conf" | "properties" => "Config",
        "txt" | "rst" | "adoc" => "Text",
        "sh" | "bash" | "zsh" | "fish" => "Shell",
        "lock" => "Lockfile",
        "" => "Other",
        other => match other {
            "gradle" => "Gradle",
            _ => "Other",
        },
    }
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
    /// Non-code file types (Markdown, YAML, Dockerfile, ...), by line delta.
    pub other: Vec<OtherRow>,
    /// Added/removed/changed dependencies across all manifests.
    pub deps: DepSummary,
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

    // Map each changed path to its language, then aggregate hazard/tier findings
    // per language (and overall) from the units, so they match the tree.
    let path_lang: std::collections::HashMap<&str, &str> = plan
        .files
        .iter()
        .filter_map(|f| f.language.as_deref().map(|l| (f.path.as_str(), l)))
        .collect();
    let mut lang_hazards: std::collections::HashMap<String, HazardTotals> =
        std::collections::HashMap::new();
    for change in changes {
        let lang = path_lang.get(change.path.as_str());
        for unit in &change.units {
            let ev = &unit.evidence;
            summary.hazards.hazards += ev.hazards_total;
            summary.hazards.t1 += ev.t1_findings;
            summary.hazards.t2 += ev.t2_findings;
            summary.hazards.t3 += ev.t3_findings;
            if let Some(lang) = lang {
                let h = lang_hazards.entry((*lang).to_string()).or_default();
                h.hazards += ev.hazards_total;
                h.t1 += ev.t1_findings;
                h.t2 += ev.t2_findings;
                h.t3 += ev.t3_findings;
            }
        }
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

        let mut bar = CoverageBar::default();
        bar.add_slices(&lang.production_verification);
        summary.langs.push(LangRow {
            language: lang.language.clone(),
            public,
            private,
            other,
            bar,
            hazards: lang_hazards.get(&lang.language).copied().unwrap_or_default(),
        });
    }

    // Non-code additions are whatever is left after the recognized source code.
    summary.other_added = summary.total_added.saturating_sub(summary.code_added);

    // OTHER section: aggregate non-code files (docs, config, generated, lockfiles)
    // by display type, using giga-core's per-file role to decide code vs not.
    let mut other: std::collections::BTreeMap<&'static str, OtherRow> =
        std::collections::BTreeMap::new();
    for file in &plan.files {
        if matches!(file.role, SourceRole::Production | SourceRole::Test) {
            continue;
        }
        let a = &file.added_lines;
        let r = &file.removed_lines;
        let row = other.entry(other_type(&file.path)).or_default();
        row.type_label = other_type(&file.path).to_string();
        row.added += (a.code + a.comments + a.other) as u32;
        row.removed += (r.code + r.comments + r.other) as u32;
    }
    summary.other = other.into_values().collect();
    summary
        .other
        .sort_by(|a, b| (b.added + b.removed).cmp(&(a.added + a.removed)));

    // Dependency changes across all manifests, from the plan.
    for change in &plan.dependency_changes {
        for entry in &change.entries {
            match (entry.before.is_some(), entry.after.is_some()) {
                (false, true) => summary.deps.added += 1,
                (true, false) => summary.deps.removed += 1,
                (true, true) if entry.before != entry.after => summary.deps.changed += 1,
                _ => {}
            }
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
