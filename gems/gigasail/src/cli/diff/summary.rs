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

/// How a dependency changed between the two revisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepKind {
    Added,
    Removed,
    Changed,
}

/// One dependency that changed between the two revisions, with its versions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DepChange {
    pub name: String,
    pub scope: String,
    pub kind: DepKind,
    pub before: Option<String>,
    pub after: Option<String>,
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
    /// Number of commits the diff range spans (0 when unknown).
    pub commits: usize,
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
    /// Dependencies changed between the two revisions, across all manifests.
    pub deps: Vec<DepChange>,
    /// Per language:test_set test-suite churn + quality + timing (the change's
    /// effect on the tests), for the TESTS section.
    pub tests: Vec<crate::test_summary::TestSummary>,
    /// Binary files newly added by the change (count + total bytes). Rendered as
    /// a red warning - added binaries in a source diff are almost always wrong.
    pub binaries_added: usize,
    pub binaries_bytes: u64,
}

/// Build the funnel from the plan (line splits, coverage, visibility) and the
/// changed units (hazard/tier totals, so they match the tree).
pub fn build_summary(plan: &DiffPlan, changes: &[FileChange]) -> DiffSummary {
    let mut summary = DiffSummary::default();

    // Real per-file added/removed counts (from the actual diff), keyed by path.
    // The plan's `added_lines` only counts recognized source code, so config,
    // docs, and other non-code files would otherwise read as zero.
    let counts: std::collections::HashMap<&str, (u32, u32)> = changes
        .iter()
        .map(|c| (c.path.as_str(), (c.file_added, c.file_removed)))
        .collect();
    for (added, removed) in counts.values() {
        summary.total_added += added;
        summary.total_removed += removed;
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
        let (added, removed) = counts.get(file.path.as_str()).copied().unwrap_or((0, 0));
        let row = other.entry(other_type(&file.path)).or_default();
        row.type_label = other_type(&file.path).to_string();
        row.added += added;
        row.removed += removed;
    }
    summary.other = other.into_values().collect();
    summary
        .other
        .sort_by(|a, b| (b.added + b.removed).cmp(&(a.added + a.removed)));

    // Dependency changes across all manifests, from the plan: the actual
    // dependencies added/removed/version-changed between the two revisions.
    for change in &plan.dependency_changes {
        for entry in &change.entries {
            let kind = match (entry.before.is_some(), entry.after.is_some()) {
                (false, true) => DepKind::Added,
                (true, false) => DepKind::Removed,
                (true, true) if entry.before != entry.after => DepKind::Changed,
                _ => continue,
            };
            summary.deps.push(DepChange {
                name: entry.name.clone(),
                scope: entry.scope.clone(),
                kind,
                before: entry.before.clone(),
                after: entry.after.clone(),
            });
        }
    }
    // Added first, then removed, then changed; alphabetical within each.
    summary.deps.sort_by(|a, b| {
        let order = |k: DepKind| match k {
            DepKind::Added => 0,
            DepKind::Removed => 1,
            DepKind::Changed => 2,
        };
        order(a.kind)
            .cmp(&order(b.kind))
            .then_with(|| a.name.cmp(&b.name))
    });

    // Riskiest / largest languages first.
    summary
        .langs
        .sort_by(|a, b| (b.public + b.private + b.other).cmp(&(a.public + a.private + a.other)));

    // TESTS: the change's effect on the test suite (already scoped to changed
    // test files and only the groups it touched).
    summary.tests = plan.test_summaries.clone();

    // Binaries: warn loudly when a source diff adds binary files.
    summary.binaries_added = plan.inventory.binary_added.len();
    summary.binaries_bytes = plan.inventory.binary_added.iter().map(|b| b.bytes).sum();
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
                added_dependencies: Vec::new(),
                added_state: Vec::new(),
                big_o_time: String::new(),
                big_o_time_status: "unknown".into(),
                big_o_space: String::new(),
                big_o_space_status: "unknown".into(),
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
            added_imports: Vec::new(),
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
        // measured excludes unknown; has_coverage reflects it.
        assert_eq!(bar.measured(), 10);
        assert!(bar.has_coverage());
        let unknown_only = CoverageBar {
            unknown: 5,
            ..Default::default()
        };
        assert_eq!(unknown_only.measured(), 0);
        assert!(!unknown_only.has_coverage());
        // VisibilityVerificationSlices default is all-zero.
        let vis = VisibilityVerificationSlices::default();
        assert_eq!(slice_total(&vis.public), 0);
    }

    #[test]
    fn other_type_maps_common_file_kinds() {
        for (path, kind) in [
            ("docs/README.md", "Markdown"),
            ("notes.markdown", "Markdown"),
            ("ci/build.yml", "YAML"),
            ("k8s/pod.yaml", "YAML"),
            ("pkg/data.json", "JSON"),
            ("Cargo.toml", "TOML"),
            ("pom.xml", "XML"),
            ("app.ini", "Config"),
            ("server.conf", "Config"),
            ("notes.txt", "Text"),
            ("scripts/run.sh", "Shell"),
            ("Dockerfile", "Dockerfile"),
            ("Dockerfile.prod", "Dockerfile"),
            ("Makefile", "Makefile"),
            ("rules.mk", "Makefile"),
            ("Gemfile", "Gemfile"),
            ("Gemfile.lock", "Gemfile"),
            ("Rakefile", "Rakefile"),
            ("BUILD", "Bazel"),
            ("lib.bzl", "Bazel"),
            ("app.bazel", "Bazel"),
            ("build.gradle", "Gradle"),
            ("deps.lock", "Lockfile"),
            ("LICENSE", "Other"),
            ("weird.xyz", "Other"),
        ] {
            assert_eq!(other_type(path), kind, "other_type({path})");
        }
    }

    #[test]
    fn build_summary_aggregates_other_files_and_dependencies() {
        // package.json: left-pad removed, keep bumped, tokio added.
        let base_pkg = r#"{"dependencies":{"left-pad":"1.0.0","keep":"1.0.0"}}"#;
        let head_pkg = r#"{"dependencies":{"keep":"2.0.0","tokio":"1.0.0"}}"#;
        let plan = build_diff_plan_with_renames(
            "b".repeat(40),
            "h".repeat(40),
            vec![
                RevisionFile {
                    path: "package.json".into(),
                    contents: Some(base_pkg.into()),
                },
                RevisionFile {
                    path: "README.md".into(),
                    contents: Some("# Title\n".into()),
                },
            ],
            vec![
                RevisionFile {
                    path: "package.json".into(),
                    contents: Some(head_pkg.into()),
                },
                RevisionFile {
                    path: "README.md".into(),
                    contents: Some("# Title\nNew line.\nMore.\n".into()),
                },
            ],
            BTreeMap::new(),
        );
        // The summary reads real per-file counts from the changes.
        let mk = |path: &str, added: u32, removed: u32| FileChange {
            path: path.into(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test: false,
            units: vec![],
            file_added: added,
            file_removed: removed,
            unattributed_added: 0,
            unattributed_removed: 0,
            added_imports: Vec::new(),
        };
        let changes = vec![mk("README.md", 2, 0), mk("package.json", 1, 1)];
        let summary = build_summary(&plan, &changes);

        // OTHER: a Markdown row with the real line delta.
        let md = summary
            .other
            .iter()
            .find(|o| o.type_label == "Markdown")
            .expect("markdown row");
        assert_eq!((md.added, md.removed), (2, 0));
        assert!(summary.total_added >= 3);

        // Dependencies: tokio added, left-pad removed, keep changed.
        let kinds: std::collections::HashMap<&str, DepKind> =
            summary.deps.iter().map(|d| (d.name.as_str(), d.kind)).collect();
        assert_eq!(kinds.get("tokio"), Some(&DepKind::Added));
        assert_eq!(kinds.get("left-pad"), Some(&DepKind::Removed));
        assert_eq!(kinds.get("keep"), Some(&DepKind::Changed));
    }
}
