//! Stable presentation formats for structured Gigasail diffs.

use crate::diff::{DiffGroup, DiffPlan, EvidenceState, FileChangeKind, SourceRole, Visibility};
use serde::Serialize;
use std::fmt::Write;

pub const STRUCTURED_DIFF_FORMAT_VERSION: &str = "gigasail-diff/v1";

/// Versioned JSON envelope for CI and editor integrations.
#[derive(Debug, Serialize)]
pub struct StructuredDiffDocument<'a> {
    pub format_version: &'static str,
    pub plan: &'a DiffPlan,
}

pub fn structured_diff_document(plan: &DiffPlan) -> StructuredDiffDocument<'_> {
    StructuredDiffDocument {
        format_version: STRUCTURED_DIFF_FORMAT_VERSION,
        plan,
    }
}

pub fn render_structured_diff_json(plan: &DiffPlan) -> serde_json::Result<String> {
    serde_json::to_string_pretty(&structured_diff_document(plan))
}

pub fn render_structured_diff_text(plan: &DiffPlan, full: bool) -> String {
    let mut output = String::new();
    let _ = writeln!(
        output,
        "Gigasail diff {}..{} ({})",
        plan.scope.base_oid, plan.scope.head_oid, plan.scope.policy_version
    );
    let _ = writeln!(
        output,
        "Evidence: coverage={} mutation={} hazards={} sarif={}",
        evidence_label(plan.evidence.coverage),
        evidence_label(plan.evidence.mutation),
        evidence_label(plan.evidence.hazards),
        evidence_label(plan.evidence.sarif)
    );
    if full {
        let evidence = [
            ("coverage", plan.evidence.coverage),
            ("mutation", plan.evidence.mutation),
            ("hazards", plan.evidence.hazards),
            ("sarif", plan.evidence.sarif),
        ];
        let exact = evidence
            .iter()
            .filter(|(_, state)| *state == EvidenceState::Exact)
            .count();
        let _ = writeln!(
            output,
            "Evidence completeness: {}/{} exact categories",
            exact,
            evidence.len()
        );
        for (category, state) in evidence {
            let _ = writeln!(output, "  {:<9} {}", evidence_label(state), category);
        }
    }
    let _ = writeln!(
        output,
        "Inventory: {} directories, {} files ({} added, {} modified, {} deleted, {} renamed)",
        plan.inventory.changed_directories,
        plan.inventory.changed_files,
        plan.inventory.added_files,
        plan.inventory.modified_files,
        plan.inventory.deleted_files,
        plan.inventory.renamed_files,
    );
    for summary in &plan.language_summaries {
        let _ = writeln!(
            output,
            "Language {}: production +{} code/+{} comments; test +{} code/+{} comments; assertions={}",
            summary.language,
            summary.production.code,
            summary.production.comments,
            summary.test.code,
            summary.test.comments,
            summary
                .test_assertions
                .map_or_else(|| "unavailable".to_string(), |count| count.to_string()),
        );
    }
    for test in &plan.test_summaries {
        let mut churn: Vec<String> = Vec::new();
        if test.inventory_available {
            churn.push(format!("+{} added", test.added));
            churn.push(format!("-{} deleted", test.deleted));
            churn.push(format!("{} changed", test.changed));
        }
        churn.push(format!("{} pending", test.pending));
        let mut quality: Vec<String> = Vec::new();
        if test.mutation_available {
            quality.push(format!("{} kill no mutants", test.kill_no_mutants));
            quality.push(format!("{} kill no distinct mutants", test.kill_no_distinct));
        }
        quality.push(format!("{} add no coverage", test.no_coverage));
        let mut line = format!(
            "Tests {}:{}: {}",
            test.language,
            test.test_set,
            churn.join(", ")
        );
        line.push_str(&format!("; {}", quality.join(", ")));
        if !test.inventory_available {
            line.push_str(" (churn n/a: no base test evidence)");
        }
        if let Some(timing) = &test.timing {
            if timing.pending {
                line.push_str("; time [ PENDING ]");
            } else if timing.baseline_n == 0 {
                line.push_str(&format!(
                    "; time measured (n={}, baseline building)",
                    timing.samples
                ));
            } else {
                let sign = if timing.pct >= 0.0 { "+" } else { "" };
                line.push_str(&format!(
                    "; time {sign}{:.1}% ±{:.1}% (n={})",
                    timing.pct, timing.ci_pct, timing.samples
                ));
            }
        }
        let _ = writeln!(output, "{line}");
    }
    for dependency in &plan.dependency_changes {
        let detail = if dependency.status == crate::diff::DependencyStatus::Exact {
            format!("{} declared changes", dependency.entries.len())
        } else {
            "unknown package-file change".into()
        };
        let _ = writeln!(output, "Dependency {}: {detail}", dependency.manifest_path);
        if full {
            for entry in &dependency.entries {
                let _ = writeln!(
                    output,
                    "  {} ({}): {} -> {}",
                    entry.name,
                    entry.scope,
                    entry.before.as_deref().unwrap_or("not declared"),
                    entry.after.as_deref().unwrap_or("not declared"),
                );
            }
        }
    }
    for file in &plan.files {
        let _ = writeln!(
            output,
            "{:>7.1} {} [{} {}] +{} code (covered+killed={} covered={} partial={} uncovered={} unknown={})",
            file.risk.score,
            file.path,
            source_role_label(file.role),
            change_kind_label(file.change),
            file.added_lines.code,
            file.verification.covered_and_killed,
            file.verification.covered,
            file.verification.partially_covered,
            file.verification.not_covered,
            file.verification.unknown,
        );
        if full {
            render_file_detail(&mut output, file);
        }
    }
    output
}

fn evidence_label(state: EvidenceState) -> &'static str {
    match state {
        EvidenceState::Exact => "exact",
        EvidenceState::Stale => "stale",
        EvidenceState::Missing => "missing",
        EvidenceState::Partial => "partial",
        EvidenceState::Unknown => "unknown",
    }
}

fn source_role_label(role: SourceRole) -> &'static str {
    match role {
        SourceRole::Production => "production",
        SourceRole::Test => "test",
        SourceRole::Documentation => "documentation",
        SourceRole::Configuration => "configuration",
        SourceRole::Generated => "generated",
        SourceRole::Lockfile => "lockfile",
        SourceRole::Other => "other",
    }
}

fn change_kind_label(change: FileChangeKind) -> &'static str {
    match change {
        FileChangeKind::Added => "added",
        FileChangeKind::Modified => "modified",
        FileChangeKind::Deleted => "deleted",
        FileChangeKind::Renamed => "renamed",
    }
}

fn render_file_detail(output: &mut String, file: &crate::diff::DiffFile) {
    let mut groups = file.groups.iter().collect::<Vec<_>>();
    groups.sort_by(|left, right| compare_groups_for_review(left, right));
    for group in groups {
        let _ = writeln!(
            output,
            "  {} {} risk={:.1} +{} code",
            group.kind, group.name, group.risk.score, group.added_lines.code
        );
    }
    for finding in &file.sarif_findings {
        let _ = writeln!(
            output,
            "  SARIF {} {}/{} {} line {}: {}",
            finding.status,
            finding.tool,
            finding.rule_id,
            finding.level,
            finding.start_line,
            finding.message
        );
    }
}

fn compare_groups_for_review(left: &&DiffGroup, right: &&DiffGroup) -> std::cmp::Ordering {
    visibility_rank(left.visibility)
        .cmp(&visibility_rank(right.visibility))
        .then_with(|| right.risk.score.total_cmp(&left.risk.score))
        .then_with(|| right.risk.tier_one_hazards.cmp(&left.risk.tier_one_hazards))
        .then_with(|| right.risk.not_covered.cmp(&left.risk.not_covered))
        .then_with(|| right.added_lines.code.cmp(&left.added_lines.code))
        .then_with(|| left.name.cmp(&right.name))
}

fn visibility_rank(visibility: Visibility) -> u8 {
    match visibility {
        Visibility::Public | Visibility::Unknown => 0,
        Visibility::Private => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{DependencyChange, DependencyEntry, DependencyStatus, SarifFindingSummary};
    use crate::{build_diff_plan, RevisionFile};
    use std::collections::BTreeMap;

    #[test]
    fn renders_versioned_json_without_losing_the_plan() {
        let plan = sample_plan();

        let output = render_structured_diff_json(&plan).unwrap();
        let json: serde_json::Value = serde_json::from_str(&output).unwrap();

        assert_eq!(json["format_version"], STRUCTURED_DIFF_FORMAT_VERSION);
        assert_eq!(json["plan"]["scope"]["base_oid"], "base");
        assert_eq!(json["plan"]["files"][0]["path"], "lib/app.rb");
    }

    #[test]
    fn renders_the_tests_section_per_language_and_tag() {
        let mut plan = sample_plan();
        plan.test_summaries.push(crate::test_summary::TestSummary {
            language: "ruby".into(),
            test_set: "unit".into(),
            added: 3,
            deleted: 1,
            changed: 2,
            pending: 1,
            kill_no_mutants: 2,
            no_coverage: 1,
            kill_no_distinct: 4,
            inventory_available: true,
            mutation_available: true,
            timing: None,
        });
        // A group with no base evidence: churn is suppressed, not fabricated.
        plan.test_summaries.push(crate::test_summary::TestSummary {
            language: "go".into(),
            test_set: "integration".into(),
            pending: 1,
            no_coverage: 2,
            inventory_available: false,
            mutation_available: false,
            ..Default::default()
        });
        // A measured timing delta and a pending timing.
        plan.test_summaries.push(crate::test_summary::TestSummary {
            language: "rust".into(),
            test_set: "unit".into(),
            added: 2,
            inventory_available: true,
            timing: Some(crate::test_summary::TestTiming {
                pending: false,
                pct: 2.1,
                ci_pct: 0.8,
                samples: 4,
                baseline_n: 5,
            }),
            ..Default::default()
        });
        plan.test_summaries.push(crate::test_summary::TestSummary {
            language: "zig".into(),
            test_set: "unit".into(),
            added: 1,
            inventory_available: true,
            timing: Some(crate::test_summary::TestTiming {
                pending: true,
                ..Default::default()
            }),
            ..Default::default()
        });

        let text = render_structured_diff_text(&plan, false);
        assert!(text.contains(
            "Tests ruby:unit: +3 added, -1 deleted, 2 changed, 1 pending; \
             2 kill no mutants, 4 kill no distinct mutants, 1 add no coverage"
        ));
        // No base evidence -> only head-derived counts, with the caveat note.
        assert!(text.contains(
            "Tests go:integration: 1 pending; 2 add no coverage (churn n/a: no base test evidence)"
        ));
        // Timing: measured delta with the ± sign, and the pending caption.
        assert!(text.contains("time +2.1% ±0.8% (n=4)"), "measured timing: {text}");
        assert!(text.contains("Tests zig:unit:") && text.contains("time [ PENDING ]"));
    }

    #[test]
    fn renders_risk_and_full_group_detail_for_humans() {
        let mut plan = sample_plan();
        plan.files[0].sarif_findings.push(SarifFindingSummary {
            source: "scanner".into(),
            tool: "Scanner".into(),
            rule_id: "unsafe-call".into(),
            level: "warning".into(),
            category: "hazard".into(),
            message: "unsafe call".into(),
            fingerprint: "finding-1".into(),
            tier: Some(1),
            tier_one: true,
            status: "new".into(),
            provenance: BTreeMap::new(),
            proof_boundary: Vec::new(),
            start_line: 1,
            end_line: 1,
        });

        let concise = render_structured_diff_text(&plan, false);
        let detailed = render_structured_diff_text(&plan, true);

        assert!(concise.contains("Gigasail diff base..head"));
        assert!(concise.contains("lib/app.rb"));
        assert!(!concise.contains("function run risk="));
        assert!(detailed.contains("function run risk="));
        assert!(detailed.contains("SARIF new Scanner/unsafe-call"));
    }

    #[test]
    fn puts_private_groups_after_public_groups_even_when_source_order_differs() {
        let mut plan = sample_plan();
        let public = plan.files[0]
            .groups
            .iter()
            .position(|group| group.visibility == Visibility::Public)
            .expect("sample contains a public function");
        plan.files[0].groups[public].visibility = Visibility::Private;
        plan.files[0].groups.push(DiffGroup {
            name: "visible".into(),
            kind: "function".into(),
            start_line: 1,
            end_line: 1,
            base_start_line: None,
            base_end_line: None,
            visibility: Visibility::Public,
            added_lines: Default::default(),
            verification: Default::default(),
            sarif_findings: Vec::new(),
            added_dependencies: Vec::new(),
            added_state: Vec::new(),
            risk: Default::default(),
        });

        let output = render_structured_diff_text(&plan, true);
        assert!(output.find("function visible").unwrap() < output.find("function run").unwrap());
    }

    #[test]
    fn renders_all_evidence_labels_and_dependency_forms() {
        let mut plan = sample_plan();
        plan.evidence.coverage = EvidenceState::Exact;
        plan.evidence.mutation = EvidenceState::Stale;
        plan.evidence.hazards = EvidenceState::Partial;
        plan.evidence.sarif = EvidenceState::Unknown;
        plan.dependency_changes = vec![
            DependencyChange {
                manifest_path: "Cargo.toml".into(),
                status: DependencyStatus::Exact,
                entries: vec![DependencyEntry {
                    name: "serde".into(),
                    scope: "dependencies".into(),
                    before: Some("1.0".into()),
                    after: None,
                }],
            },
            DependencyChange {
                manifest_path: "unknown.lock".into(),
                status: DependencyStatus::UnknownPackageFile,
                entries: Vec::new(),
            },
        ];

        let output = render_structured_diff_text(&plan, true);

        assert!(output.contains("coverage=exact mutation=stale hazards=partial sarif=unknown"));
        assert!(output.contains("Dependency Cargo.toml: 1 declared changes"));
        assert!(output.contains("serde (dependencies): 1.0 -> not declared"));
        assert!(output.contains("Dependency unknown.lock: unknown package-file change"));

        let concise = render_structured_diff_text(&plan, false);
        assert!(concise.contains("Dependency Cargo.toml: 1 declared changes"));
        assert!(!concise.contains("serde (dependencies): 1.0 -> not declared"));
    }

    #[test]
    fn labels_every_source_role_and_change_kind() {
        let roles = [
            (SourceRole::Production, "production"),
            (SourceRole::Test, "test"),
            (SourceRole::Documentation, "documentation"),
            (SourceRole::Configuration, "configuration"),
            (SourceRole::Generated, "generated"),
            (SourceRole::Lockfile, "lockfile"),
            (SourceRole::Other, "other"),
        ];
        for (role, label) in roles {
            assert_eq!(source_role_label(role), label);
        }
        let changes = [
            (FileChangeKind::Added, "added"),
            (FileChangeKind::Modified, "modified"),
            (FileChangeKind::Deleted, "deleted"),
            (FileChangeKind::Renamed, "renamed"),
        ];
        for (change, label) in changes {
            assert_eq!(change_kind_label(change), label);
        }
        assert_eq!(evidence_label(EvidenceState::Missing), "missing");
    }

    fn sample_plan() -> DiffPlan {
        build_diff_plan(
            "base",
            "head",
            vec![RevisionFile {
                path: "lib/app.rb".into(),
                contents: Some("def run\n  :old\nend\n".into()),
            }],
            vec![RevisionFile {
                path: "lib/app.rb".into(),
                contents: Some("def run\n  :new\nend\n".into()),
            }],
        )
    }
}
