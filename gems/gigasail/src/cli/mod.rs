//! `gigasail diff` — an interactive terminal UI for reviewing changes by risk.
//!
//! The TUI is a pure renderer over master's [`DiffPlan`]. `run_diff` prepares
//! the plan via `application::diff::prepare`, adapts it into the view-model the
//! app consumes (`plan_to_view`), and either prints the collapse tree
//! (`--no-tui` / non-tty) or launches the ratatui app.

pub mod diff;
pub mod gutter;
pub mod highlight;
pub mod line_evidence;
pub mod tui;

use crate::application::diff::DiffCommandRequest;
use crate::cli::diff::gitdiff::{diff_lines, ChangeStatus, FileDiff, LineOrigin};
use crate::cli::diff::risk::{CoverageState, Evidence};
use crate::cli::diff::tree::{build_tree, Node, NodeKind};
use crate::cli::diff::units::{ChangedUnit, FileChange};
use crate::cli::diff::visibility::Visibility;
use crate::cli::gutter::{tool_gutter, GutterKind};
use crate::cli::line_evidence::{FindingDetail, LineEvidence};
use crate::diff::{
    DiffFile, DiffGroup, DiffPlan, FileChangeKind, LineVerification, SarifFindingSummary,
    SourceRole, VerificationSlices,
};
use crate::model::UnitKind;
use anyhow::Result;
use std::collections::{BTreeSet, HashMap};
use std::io::IsTerminal;
use std::path::Path;

type View = (
    Node,
    Vec<FileChange>,
    HashMap<String, FileDiff>,
    HashMap<String, String>,
    HashMap<String, Vec<LineEvidence>>,
    crate::cli::diff::summary::DiffSummary,
);

/// Entry point for the `diff` subcommand's interactive renderer.
pub fn run_diff(
    repo: &Path,
    db: &Path,
    base: Option<String>,
    head: Option<String>,
    all: bool,
    analyse: bool,
    no_tui: bool,
) -> Result<()> {
    // `all` is retained for CLI compatibility; the plan is already scoped by
    // base/head, so there is no separate working-tree selection to make here.
    let _ = all;
    let label = target_label(&base, &head);
    let result = crate::application::diff::prepare(DiffCommandRequest {
        repo: repo.to_path_buf(),
        db: db.to_path_buf(),
        base,
        head,
        full: false,
        coverage_source: None,
        sarif_source: None,
        selection: None,
        mutant_corpus: None,
        test_set: None,
        analyse,
        trust_current_config: false,
        require_profile: None,
        require_complete: false,
    })?;

    if result.plan.files.is_empty() {
        println!("No changes.");
        return Ok(());
    }

    let (root, changes, files, sources, line_ev, summary) = plan_to_view(&result.plan);

    if no_tui || !std::io::stdout().is_terminal() {
        print_tree(&label, &root);
        return Ok(());
    }

    let mut app = tui::app::App::new(
        repo.to_path_buf(),
        db.to_path_buf(),
        root,
        changes,
        files.into_values().collect(),
        sources,
        line_ev,
        label,
    );
    app.ascii = tui::detect_ascii();
    app.truecolor = tui::detect_truecolor();
    // Populate the funnel and start on the `[SUMMARY]` row.
    app.summary = summary;
    app.refresh_rows();
    app.selected = 0;
    let _ = tui::run(app)?;
    Ok(())
}

/// Block while a `giga watch` holds the `.giga/` lock for the exact commit being
/// diffed, so the render sees a fully ingested database. Best-effort: outside a
/// Git repo, or if the target rev cannot be resolved, it returns without waiting.
pub fn wait_for_in_flight_analysis(repo: &Path, db: &Path, head: Option<&str>) {
    let Ok(provider) = crate::git::GitProvider::open(repo) else {
        return;
    };
    let Ok(commit) = provider.resolve_commit(head.unwrap_or("HEAD")) else {
        return;
    };
    let giga_dir = crate::watch::giga_dir(db);
    let mut announced = false;
    let _ = giga_core::lock::wait_while_locked_for(
        &giga_dir,
        &commit,
        std::time::Duration::from_secs(600),
        std::time::Duration::from_millis(250),
        |info| {
            if !announced {
                eprintln!(
                    "giga diff: waiting for analysis of {} ({})...",
                    &commit[..commit.len().min(12)],
                    info.operation
                );
                announced = true;
            }
        },
    );
}

/// Adapt a `DiffPlan` into the TUI view-model: the collapse tree, per-file
/// changes with logical units, the line-level diffs, new-side sources, and
/// per-line evidence.
pub fn plan_to_view(plan: &DiffPlan) -> View {
    let mut sources = HashMap::new();
    let mut files = HashMap::new();
    let mut changes = Vec::new();
    let mut line_ev = HashMap::new();

    for file in &plan.files {
        let head_source = file.head_source.clone().unwrap_or_default();
        let base_source = file.base_source.clone().unwrap_or_default();
        sources.insert(file.path.clone(), head_source.clone());

        let status = map_status(file.change);
        let file_diff = FileDiff {
            path: file.path.clone(),
            old_path: file.previous_path.clone(),
            status,
            hunks: diff_lines(&base_source, &head_source),
        };

        // New-side line numbers that the differ marked as added, for accurate
        // per-unit uncovered-changed-LoC attribution.
        let added_line_numbers: BTreeSet<u32> = file_diff
            .hunks
            .iter()
            .flat_map(|hunk| &hunk.lines)
            .filter(|line| line.origin == LineOrigin::Add)
            .filter_map(|line| line.new_lineno)
            .collect();

        let mut units: Vec<ChangedUnit> = file
            .groups
            .iter()
            .map(|group| group_to_unit(file, group, &added_line_numbers))
            .collect();
        units.sort_by(|a, b| {
            b.risk()
                .partial_cmp(&a.risk())
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.start_line.cmp(&b.start_line))
        });

        let is_test = file.role == SourceRole::Test;
        changes.push(FileChange {
            path: file.path.clone(),
            old_path: file.previous_path.clone(),
            status,
            is_test,
            units,
            file_added: file.added_lines.code as u32,
            file_removed: file.removed_lines.code as u32,
            unattributed_added: 0,
            unattributed_removed: 0,
        });

        line_ev.insert(file.path.clone(), line_evidence_for(file));
        files.insert(file.path.clone(), file_diff);
    }

    let root = build_tree(&changes, project_root_of);
    let summary = crate::cli::diff::summary::build_summary(plan, &changes);
    (root, changes, files, sources, line_ev, summary)
}

/// Convert a plan `DiffGroup` into a view-model `ChangedUnit`.
fn group_to_unit(
    file: &DiffFile,
    group: &DiffGroup,
    added_line_numbers: &BTreeSet<u32>,
) -> ChangedUnit {
    let added_lines: Vec<u32> = added_line_numbers
        .range(group.start_line..=group.end_line)
        .copied()
        .collect();
    let evidence = Evidence {
        uncovered_changed_loc: group.verification.not_covered as u32,
        hazards_total: group.risk.tier_one_hazards as u32,
        hazards_uncovered: group.risk.tier_one_hazards as u32,
        t1_findings: count_tier(&group.sarif_findings, 1),
        t2_findings: count_tier(&group.sarif_findings, 2),
        t3_findings: count_tier(&group.sarif_findings, 3),
        dark_arm_findings: 0,
        coverage: coverage_from(&group.verification),
    };
    ChangedUnit {
        name: group.name.clone(),
        kind: map_kind(&group.kind),
        path: file.path.clone(),
        start_line: group.start_line,
        end_line: group.end_line,
        signature: String::new(),
        visibility: map_visibility(group.visibility),
        is_test: file.role == SourceRole::Test,
        added: group.added_lines.code as u32,
        removed: 0,
        added_lines,
        evidence,
    }
}

/// Tier-1 hazards from a group's findings count as tier one whether tagged by
/// the explicit `tier` field or the `tier_one` flag.
fn count_tier(findings: &[SarifFindingSummary], tier: u8) -> u32 {
    findings
        .iter()
        .filter(|finding| {
            if tier == 1 {
                finding.tier == Some(1) || finding.tier_one
            } else {
                finding.tier == Some(tier)
            }
        })
        .count() as u32
}

/// Derive a coverage state from a verification slice count.
fn coverage_from(verification: &VerificationSlices) -> CoverageState {
    let covered = verification.covered_and_killed + verification.covered > 0;
    let is_partial = verification.partially_covered > 0;
    let mutant_killed = verification.covered_and_killed as i64;
    let has_evidence = verification.covered_and_killed
        + verification.covered
        + verification.partially_covered
        + verification.not_covered
        > 0;
    CoverageState::derive(covered, is_partial, 0, mutant_killed, has_evidence)
}

/// Build per-line evidence from a file's line annotations and SARIF findings.
fn line_evidence_for(file: &DiffFile) -> Vec<LineEvidence> {
    file.line_annotations
        .iter()
        .map(|annotation| {
            let covered = matches!(
                annotation.verification,
                LineVerification::Covered | LineVerification::CoveredAndKilled
            );
            let is_partial = matches!(annotation.verification, LineVerification::PartiallyCovered);
            let covered_known = annotation.verification != LineVerification::Unknown;
            let mutant_killed_tests =
                matches!(annotation.verification, LineVerification::CoveredAndKilled) as i64;
            let findings: Vec<FindingDetail> = file
                .sarif_findings
                .iter()
                .filter(|finding| {
                    finding.start_line <= annotation.line && annotation.line <= finding.end_line
                })
                .map(finding_detail)
                .collect();
            let mut gutters: Vec<GutterKind> = findings.iter().map(|f| f.gutter).collect();
            gutters.sort_by_key(|g| g.order());
            gutters.dedup();
            LineEvidence {
                line: annotation.line,
                covered,
                covered_known,
                is_partial,
                distinct_tests: 0,
                mutant_killed_tests,
                dark_arms: Vec::new(),
                hazards: Vec::new(),
                findings,
                gutters,
            }
        })
        .collect()
}

fn finding_detail(finding: &SarifFindingSummary) -> FindingDetail {
    FindingDetail {
        gutter: tool_gutter(&finding.tool, &finding.category),
        tool: finding.tool.clone(),
        rule: finding.rule_id.clone(),
        message: finding.message.clone(),
        tier: finding.tier.map(i64::from),
    }
}

fn map_status(change: FileChangeKind) -> ChangeStatus {
    match change {
        FileChangeKind::Added => ChangeStatus::Added,
        FileChangeKind::Modified => ChangeStatus::Modified,
        FileChangeKind::Deleted => ChangeStatus::Deleted,
        FileChangeKind::Renamed => ChangeStatus::Renamed,
    }
}

fn map_kind(kind: &str) -> UnitKind {
    match kind {
        "class" => UnitKind::Class,
        "module" => UnitKind::Module,
        _ => UnitKind::Function,
    }
}

fn map_visibility(visibility: crate::diff::Visibility) -> Visibility {
    match visibility {
        crate::diff::Visibility::Private => Visibility::Private,
        // Public and Unknown both surface as public so nothing is hidden by
        // accident (the view-model has no Unknown visibility).
        _ => Visibility::Public,
    }
}

/// A file path's top-level project label: its first path segment, or "" for a
/// top-level file. Keeps the collapse tree grouping sensible without a manifest
/// scan (the plan is already repo-relative).
pub(crate) fn project_root_of(path: &str) -> String {
    path.split_once('/')
        .map(|(head, _)| head.to_string())
        .unwrap_or_default()
}

/// A short human label for the diff header, derived from base/head revisions.
fn target_label(base: &Option<String>, head: &Option<String>) -> String {
    match (base, head) {
        (Some(base), Some(head)) => format!("{base}..{head}"),
        (None, Some(head)) => format!("commit {head}"),
        (Some(base), None) => format!("{base}..working tree"),
        (None, None) => "working tree".to_string(),
    }
}

/// Render the collapse tree as indented text (used by `--no-tui` and tests).
fn print_tree(label: &str, root: &Node) {
    println!("giga diff — {label}");
    for child in &root.children {
        print_node(child, 0);
    }
}

fn print_node(node: &Node, depth: usize) {
    let indent = "  ".repeat(depth);
    let marker = match node.kind {
        NodeKind::Function => "-",
        NodeKind::PrivateGroup | NodeKind::TestGroup => "*",
        _ => "+",
    };
    println!(
        "{indent}{marker} {:<40} +{} -{}  risk={:.1}",
        node.label, node.added, node.removed, node.risk.0
    );
    for child in &node.children {
        print_node(child, depth + 1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::{build_diff_plan, RevisionFile};
    use std::path::Path;
    use std::process::Command;

    fn revision_file(path: &str, contents: &str) -> RevisionFile {
        RevisionFile {
            path: path.to_string(),
            contents: Some(contents.to_string()),
        }
    }

    #[test]
    fn project_root_of_returns_first_segment() {
        assert_eq!(project_root_of("proj/src/a.rs"), "proj");
        assert_eq!(project_root_of("README.md"), "");
    }

    #[test]
    fn target_label_describes_revision_scope() {
        assert_eq!(target_label(&None, &None), "working tree");
        assert_eq!(target_label(&None, &Some("HEAD".into())), "commit HEAD");
        assert_eq!(
            target_label(&Some("a".into()), &Some("b".into())),
            "a..b"
        );
        assert_eq!(
            target_label(&Some("a".into()), &None),
            "a..working tree"
        );
    }

    #[test]
    fn plan_to_view_maps_groups_and_sources() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![revision_file("proj/a.rs", "pub fn a() {}\n")],
            vec![revision_file(
                "proj/a.rs",
                "pub fn a() {}\npub fn b() {}\n",
            )],
        );
        let (root, changes, files, sources, _line_ev, _summary) = plan_to_view(&plan);
        // The added function surfaces as a changed unit.
        assert!(changes
            .iter()
            .any(|change| change.units.iter().any(|unit| unit.name == "b")));
        // Source and line diff are carried for the file.
        assert!(sources["proj/a.rs"].contains("fn b"));
        assert!(!files["proj/a.rs"].hunks.is_empty());
        // The collapse tree groups under the first path segment.
        assert!(root.children.iter().any(|child| child.label == "proj"));
    }

    #[test]
    fn plan_to_view_marks_test_files() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![],
            vec![revision_file(
                "proj/a_test.rs",
                "fn it_works() {\n    assert!(true);\n}\n",
            )],
        );
        let (_, changes, _, _, _, _) = plan_to_view(&plan);
        assert!(changes.iter().all(|change| change.is_test));
    }

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    fn repo_with_two_commits() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]);
        git(dir.path(), &["config", "user.email", "t@t"]);
        git(dir.path(), &["config", "user.name", "t"]);
        std::fs::write(dir.path().join("a.rs"), "pub fn a() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        std::fs::write(dir.path().join("a.rs"), "pub fn a() {}\npub fn b() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "second"]);
        dir
    }

    #[test]
    fn run_diff_no_tui_renders_changes() {
        let dir = repo_with_two_commits();
        let db = dir.path().join("gigasail.db");
        // no_tui forces the text path; a missing DB is fine.
        run_diff(
            dir.path(),
            &db,
            Some("HEAD~1".into()),
            Some("HEAD".into()),
            false,
            false,
            true,
        )
        .unwrap();
    }

    #[test]
    fn run_diff_no_changes_is_ok() {
        let dir = repo_with_two_commits();
        let db = dir.path().join("gigasail.db");
        // A revision compared against itself has no changed files.
        run_diff(
            dir.path(),
            &db,
            Some("HEAD".into()),
            Some("HEAD".into()),
            false,
            false,
            true,
        )
        .unwrap();
    }
}
