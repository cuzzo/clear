//! Revision-pinned, render-independent change inventory for the diff UI.

use crate::extract::{is_test_source_path, BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, UnitKind};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use tree_sitter::{Language, Node, Parser};
use ts_rs::TS;

pub const DIFF_API_VERSION: &str = "v1";
pub const DIFF_POLICY_VERSION: &str = "diff-risk/v1";
pub const DIFF_FILE_PAGE_SIZE: usize = 50;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionFile {
    pub path: String,
    pub contents: Option<String>,
}

/// Repository-local source-role overrides, parsed from the immutable head
/// revision's `.giga/diff.toml`. They are intentionally limited to exact
/// paths and directory prefixes so classification remains auditable and does
/// not need a second glob language.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ClassificationOverrides {
    exact: BTreeMap<String, SourceRole>,
    prefixes: Vec<(String, SourceRole)>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct DiffScope {
    pub base_oid: String,
    pub head_oid: String,
    pub evidence_scope: EvidenceScopeFingerprint,
    pub policy_version: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct EvidenceScopeFingerprint {
    pub revision: String,
    pub selection: String,
    pub mutant_corpus: String,
    pub test_set: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, TS)]
pub struct DiffPlan {
    pub scope: DiffScope,
    pub inventory: ChangeInventory,
    pub dependency_changes: Vec<DependencyChange>,
    pub language_summaries: Vec<LanguageSummary>,
    /// Per `language:test_set` test-suite churn + quality, for the "Tests"
    /// section. Only groups the change touched appear. Empty when no test files
    /// changed or no test evidence is ingested.
    #[serde(default)]
    pub test_summaries: Vec<crate::test_summary::TestSummary>,
    pub evidence: EvidenceAvailability,
    pub resolved_sarif_findings: Vec<ResolvedSarifFinding>,
    pub files: Vec<DiffFile>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, TS)]
pub struct ChangeInventory {
    pub changed_directories: usize,
    pub changed_files: usize,
    pub added_files: usize,
    pub modified_files: usize,
    pub deleted_files: usize,
    pub renamed_files: usize,
    pub by_role: BTreeMap<String, usize>,
    pub configuration_paths: Vec<ConfigFile>,
    pub documentation_paths: Vec<String>,
    pub generated_paths: Vec<String>,
    pub lockfile_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct ConfigFile {
    pub path: String,
    pub kind: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum FileChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum SourceRole {
    Production,
    Test,
    Documentation,
    Configuration,
    Generated,
    Lockfile,
    Other,
}

impl SourceRole {
    fn key(self) -> String {
        match self {
            Self::Production => "production",
            Self::Test => "test",
            Self::Documentation => "documentation",
            Self::Configuration => "configuration",
            Self::Generated => "generated",
            Self::Lockfile => "lockfile",
            Self::Other => "other",
        }
        .to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, TS)]
pub struct DiffFile {
    pub path: String,
    pub previous_path: Option<String>,
    pub change: FileChangeKind,
    pub role: SourceRole,
    pub language: Option<String>,
    pub semantic_classification_available: bool,
    pub base_source: Option<String>,
    pub head_source: Option<String>,
    pub added_lines: AddedLines,
    pub removed_lines: AddedLines,
    pub verification: VerificationSlices,
    pub line_annotations: Vec<LineAnnotation>,
    pub residual_lines: AddedLines,
    pub groups: Vec<DiffGroup>,
    /// Modules imported/required on this file's added lines, from the ingested
    /// architecture graph. Empty when no graph is available.
    pub added_imports: Vec<String>,
    /// Commit-matching SARIF observations. They are intentionally kept out of
    /// risk scoring until their artifact scope can prove completeness.
    pub sarif_findings: Vec<SarifFindingSummary>,
    pub risk: RiskSummary,
    #[serde(skip)]
    #[ts(skip)]
    line_verification: BTreeMap<u32, LineVerification>,
}

impl DiffFile {
    /// New-side code line numbers this diff introduced (added source lines).
    /// Used to decide which architecture facts are *newly* added.
    pub fn added_line_numbers(&self) -> BTreeSet<u32> {
        self.line_verification.keys().copied().collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct EvidenceAvailability {
    pub coverage: EvidenceState,
    pub mutation: EvidenceState,
    pub hazards: EvidenceState,
    pub sarif: EvidenceState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum EvidenceState {
    Exact,
    Stale,
    Missing,
    Partial,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverageObservation {
    pub path: String,
    pub line: u32,
    pub hits: u32,
    pub is_partial: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedCoverageArtifact {
    pub scope: EvidenceScopeFingerprint,
    pub complete: bool,
    pub expected_lines: BTreeSet<(String, u32)>,
    pub observations: Vec<CoverageObservation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MutationKillObservation {
    pub path: String,
    pub line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedMutationArtifact {
    pub scope: EvidenceScopeFingerprint,
    pub complete: bool,
    pub observations: Vec<MutationKillObservation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct SarifFindingSummary {
    pub source: String,
    pub tool: String,
    pub rule_id: String,
    pub level: String,
    pub category: String,
    pub message: String,
    pub fingerprint: String,
    pub tier: Option<u8>,
    pub tier_one: bool,
    pub status: String,
    /// Provider result properties preserved as stable strings so a transient
    /// analysis overlay keeps its proof boundary and classification context.
    pub provenance: BTreeMap<String, String>,
    /// Explicit limits or incompleteness declarations supplied by the
    /// analysis provider. An empty list means the provider supplied none.
    pub proof_boundary: Vec<String>,
    pub start_line: u32,
    pub end_line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SarifObservation {
    pub path: String,
    pub finding: SarifFindingSummary,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct ResolvedSarifFinding {
    pub path: String,
    pub finding: SarifFindingSummary,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, TS)]
pub struct VerificationSlices {
    pub covered_and_killed: usize,
    pub covered: usize,
    pub partially_covered: usize,
    pub not_covered: usize,
    pub unknown: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum LineVerification {
    CoveredAndKilled,
    Covered,
    PartiallyCovered,
    NotCovered,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct LineAnnotation {
    pub line: u32,
    pub verification: LineVerification,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, TS)]
pub struct RiskSummary {
    pub score: f64,
    pub not_covered: usize,
    pub partially_covered: usize,
    pub added_complexity: usize,
    pub tier_one_hazards: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, TS)]
pub struct AddedLines {
    pub code: usize,
    pub comments: usize,
    pub other: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct LanguageSummary {
    pub language: String,
    pub production: AddedLines,
    pub test: AddedLines,
    pub production_verification: VerificationSlices,
    pub production_by_visibility: VisibilityVerificationSlices,
    pub test_assertions: Option<usize>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, TS)]
pub struct VisibilityVerificationSlices {
    pub public: VerificationSlices,
    pub private: VerificationSlices,
    pub unknown: VerificationSlices,
}

#[derive(Debug, Clone, PartialEq, Serialize, TS)]
pub struct DiffGroup {
    pub name: String,
    pub kind: String,
    pub start_line: u32,
    pub end_line: u32,
    pub base_start_line: Option<u32>,
    pub base_end_line: Option<u32>,
    pub visibility: Visibility,
    pub added_lines: AddedLines,
    pub verification: VerificationSlices,
    pub sarif_findings: Vec<SarifFindingSummary>,
    /// Collaboration targets (`Owner#name`, or a bare name for externals) whose
    /// call site first appears on this group's added lines. Sourced from the
    /// ingested architecture graph; empty when none is available.
    pub added_dependencies: Vec<String>,
    /// State accesses (`read:field` / `write:field`) whose site first appears on
    /// this group's added lines. Sourced from the ingested architecture graph.
    pub added_state: Vec<String>,
    /// Big-O time/space complexity of this function + status (complete | partial
    /// | unknown), from the architecture graph. Empty/unknown when unavailable.
    #[serde(default)]
    pub big_o_time: String,
    #[serde(default)]
    pub big_o_time_status: String,
    #[serde(default)]
    pub big_o_space: String,
    #[serde(default)]
    pub big_o_space_status: String,
    pub risk: RiskSummary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum Visibility {
    Public,
    Private,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct DependencyChange {
    pub manifest_path: String,
    pub status: DependencyStatus,
    pub entries: Vec<DependencyEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
#[ts(rename_all = "snake_case")]
pub enum DependencyStatus {
    Exact,
    UnknownPackageFile,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct DependencyEntry {
    pub name: String,
    pub scope: String,
    pub before: Option<String>,
    pub after: Option<String>,
}

/// Builds a stable plan from immutable revision snapshots. Callers must resolve
/// symbolic revisions before invoking this function.
pub fn build_diff_plan(
    base_oid: impl Into<String>,
    head_oid: impl Into<String>,
    base_files: Vec<RevisionFile>,
    head_files: Vec<RevisionFile>,
) -> DiffPlan {
    build_diff_plan_with_renames(base_oid, head_oid, base_files, head_files, BTreeMap::new())
}

/// Builds a plan with Git-provided rename identity. Content-identical fallback
/// detection remains available for callers that only have two snapshots.
pub fn build_diff_plan_with_renames(
    base_oid: impl Into<String>,
    head_oid: impl Into<String>,
    base_files: Vec<RevisionFile>,
    head_files: Vec<RevisionFile>,
    git_renames: BTreeMap<String, String>,
) -> DiffPlan {
    build_diff_plan_with_renames_and_overrides(
        base_oid,
        head_oid,
        base_files,
        head_files,
        git_renames,
        ClassificationOverrides::default(),
    )
}

pub fn build_diff_plan_with_renames_and_overrides(
    base_oid: impl Into<String>,
    head_oid: impl Into<String>,
    base_files: Vec<RevisionFile>,
    head_files: Vec<RevisionFile>,
    git_renames: BTreeMap<String, String>,
    overrides: ClassificationOverrides,
) -> DiffPlan {
    let base_oid = base_oid.into();
    let head_oid = head_oid.into();
    let base = file_map(base_files);
    let head = file_map(head_files);
    let mut renamed = renamed_paths(&base, &head);
    renamed.extend(git_renames);
    let mut files = changed_paths(&base, &head)
        .into_iter()
        .filter_map(|path| plan_file(&path, &base, &head, &renamed, &overrides))
        .collect::<Vec<_>>();
    files.sort_by(|left, right| {
        right
            .risk
            .score
            .total_cmp(&left.risk.score)
            .then_with(|| right.risk.tier_one_hazards.cmp(&left.risk.tier_one_hazards))
            .then_with(|| right.risk.not_covered.cmp(&left.risk.not_covered))
            .then_with(|| right.added_lines.code.cmp(&left.added_lines.code))
            .then_with(|| left.path.cmp(&right.path))
    });
    let inventory = build_inventory(&files);
    let dependency_changes = dependency_changes(&files);
    let language_summaries = language_summaries(&files);

    DiffPlan {
        scope: DiffScope {
            base_oid,
            evidence_scope: EvidenceScopeFingerprint {
                revision: head_oid.clone(),
                selection: "unknown".into(),
                mutant_corpus: "unknown".into(),
                test_set: "unknown".into(),
            },
            head_oid,
            policy_version: DIFF_POLICY_VERSION,
        },
        inventory,
        dependency_changes,
        language_summaries,
        test_summaries: Vec::new(),
        evidence: unavailable_evidence(),
        resolved_sarif_findings: Vec::new(),
        files,
    }
}

/// Binds a plan to the explicit selection that its evidence artifacts must
/// share. Callers that only have legacy event rows leave the default unknown
/// scope in place and therefore cannot manufacture exact findings.
pub fn with_evidence_scope(mut plan: DiffPlan, scope: EvidenceScopeFingerprint) -> DiffPlan {
    plan.scope.evidence_scope = scope;
    plan
}

/// Keeps ranking and aggregate data for every file while bounding the source
/// blobs carried by a plan response. Source is included for the selected
/// deterministic page and for an explicitly requested raw file; `/api/diff/file`
/// remains the single-file path for any other on-demand expansion.
pub fn retain_plan_sources_for_page(
    plan: &mut DiffPlan,
    requested_page: Option<usize>,
    requested_path: Option<&str>,
) {
    let page = requested_page.unwrap_or(1).max(1);
    let start = page.saturating_sub(1).saturating_mul(DIFF_FILE_PAGE_SIZE);
    let visible = plan
        .files
        .iter()
        .skip(start)
        .take(DIFF_FILE_PAGE_SIZE)
        .map(|file| file.path.clone())
        .collect::<BTreeSet<_>>();
    for file in &mut plan.files {
        if !visible.contains(&file.path) && Some(file.path.as_str()) != requested_path {
            file.base_source = None;
            file.head_source = None;
        }
    }
}

fn changed_paths(
    base: &BTreeMap<String, RevisionFile>,
    head: &BTreeMap<String, RevisionFile>,
) -> BTreeSet<String> {
    base.keys().chain(head.keys()).cloned().collect()
}

fn plan_file(
    path: &str,
    base: &BTreeMap<String, RevisionFile>,
    head: &BTreeMap<String, RevisionFile>,
    renamed: &BTreeMap<String, String>,
    overrides: &ClassificationOverrides,
) -> Option<DiffFile> {
    let previous_path = previous_path(path, renamed);
    let base_file = base.get(path).or_else(|| {
        previous_path
            .as_ref()
            .and_then(|previous| base.get(previous))
    });
    let head_file = head.get(path);
    if base_file == head_file || is_renamed_source(path, renamed) {
        return None;
    }
    let change = change_kind(base_file, head_file, previous_path.as_ref());
    let base_source = base_file.and_then(|file| file.contents.clone());
    let head_source = head_file.and_then(|file| file.contents.clone());
    let added_lines_set = added_line_numbers(base_source.as_deref(), head_source.as_deref());
    let classification = classify_source_lines(head_source.as_deref(), path);
    let semantic_classification_available = classification.is_some();
    let line_kinds = classification.unwrap_or_default();
    let added_lines = summarize_added_lines(&line_kinds, &added_lines_set);
    let removed_line_numbers = added_line_numbers(head_source.as_deref(), base_source.as_deref());
    let base_line_kinds = classify_source_lines(
        base_source.as_deref(),
        previous_path.as_deref().unwrap_or(path),
    )
    .unwrap_or_default();
    let removed_lines = summarize_added_lines(&base_line_kinds, &removed_line_numbers);
    let groups = semantic_classification_available
        .then(|| {
            semantic_groups(
                path,
                base_source.as_deref(),
                head_source.as_deref(),
                &added_lines_set,
                &line_kinds,
            )
        })
        .unwrap_or_default();
    let verification = unavailable_verification(&added_lines);
    let line_verification = unknown_line_verification(&line_kinds, &added_lines_set);
    let mut file = DiffFile {
        path: path.to_string(),
        previous_path,
        change,
        role: source_role_with_overrides(path, overrides),
        language: language_for_path(path),
        semantic_classification_available,
        residual_lines: residual_lines(&line_kinds, &added_lines_set, &groups),
        risk: risk_summary(
            head_source.as_deref(),
            path,
            &added_lines_set,
            &verification,
        ),
        verification,
        line_annotations: Vec::new(),
        groups,
        added_imports: Vec::new(),
        sarif_findings: Vec::new(),
        base_source,
        head_source,
        added_lines,
        removed_lines,
        line_verification,
    };
    refresh_file_verification(&mut file);
    Some(file)
}

fn is_renamed_source(path: &str, renamed: &BTreeMap<String, String>) -> bool {
    renamed.contains_key(path)
}

fn previous_path(path: &str, renamed: &BTreeMap<String, String>) -> Option<String> {
    renamed
        .iter()
        .find_map(|(old, new)| (new == path).then(|| old.clone()))
}

fn change_kind(
    base_file: Option<&RevisionFile>,
    head_file: Option<&RevisionFile>,
    previous_path: Option<&String>,
) -> FileChangeKind {
    if previous_path.is_some() && head_file.is_some() {
        return FileChangeKind::Renamed;
    }
    match (base_file, head_file, previous_path) {
        (None, Some(_), Some(_)) => FileChangeKind::Renamed,
        (None, Some(_), None) => FileChangeKind::Added,
        (Some(_), None, _) => FileChangeKind::Deleted,
        (Some(_), Some(_), _) => FileChangeKind::Modified,
        (None, None, _) => unreachable!("paths come from one snapshot"),
    }
}

fn unavailable_evidence() -> EvidenceAvailability {
    EvidenceAvailability {
        coverage: EvidenceState::Missing,
        mutation: EvidenceState::Missing,
        hazards: EvidenceState::Missing,
        sarif: EvidenceState::Missing,
    }
}

/// Applies commit-matching coverage rows conservatively. Existing coverage
/// storage has no corpus-completeness fingerprint, so observations are partial:
/// they can establish known execution but never establish an uncovered line.
pub fn apply_partial_coverage(plan: &mut DiffPlan, observations: &[CoverageObservation]) {
    if observations.is_empty() {
        return;
    }
    let rows = observations
        .iter()
        .filter(|row| row.hits > 0)
        .map(|row| ((row.path.as_str(), row.line), row.is_partial))
        .collect::<BTreeMap<_, _>>();
    if rows.is_empty() {
        return;
    }
    plan.evidence.coverage = EvidenceState::Partial;
    for file in &mut plan.files {
        for (line, state) in &mut file.line_verification {
            if let Some(is_partial) = rows.get(&(file.path.as_str(), *line)) {
                *state = if *is_partial {
                    LineVerification::PartiallyCovered
                } else {
                    LineVerification::Covered
                };
            }
        }
        refresh_file_verification(file);
    }
    plan.language_summaries = language_summaries(&plan.files);
}

/// Applies a complete, revision and corpus scoped coverage artifact. Unlike
/// legacy ledger rows, this contract carries explicit expected membership, so
/// a zero-hit observation can become a truthful not-covered finding.
pub fn apply_scoped_coverage(plan: &mut DiffPlan, artifact: &ScopedCoverageArtifact) {
    if !same_common_evidence_scope(&artifact.scope, &plan.scope.evidence_scope) {
        plan.evidence.coverage = EvidenceState::Stale;
        return;
    }
    let expected = plan
        .files
        .iter()
        .flat_map(|file| {
            file.line_verification
                .keys()
                .map(|line| (file.path.clone(), *line))
        })
        .collect::<BTreeSet<_>>();
    // A complete run naturally records every line in its selected corpus,
    // while a review examines only the changed subset. Exact review coverage
    // therefore requires that the artifact's declared membership contains
    // every reviewed line, not that both sets are identical.
    if !artifact.complete || !expected.is_subset(&artifact.expected_lines) {
        apply_partial_coverage(plan, &artifact.observations);
        return;
    }
    let rows = artifact
        .observations
        .iter()
        .map(|row| ((row.path.as_str(), row.line), (row.hits, row.is_partial)))
        .collect::<BTreeMap<_, _>>();
    for file in &mut plan.files {
        for (line, state) in &mut file.line_verification {
            *state = match rows.get(&(file.path.as_str(), *line)) {
                Some((hits, true)) if *hits > 0 => LineVerification::PartiallyCovered,
                Some((hits, false)) if *hits > 0 => LineVerification::Covered,
                Some(_) => LineVerification::NotCovered,
                None => LineVerification::Unknown,
            };
        }
        refresh_file_verification(file);
    }
    plan.evidence.coverage = EvidenceState::Exact;
    plan.language_summaries = language_summaries(&plan.files);
}

fn same_common_evidence_scope(
    left: &EvidenceScopeFingerprint,
    right: &EvidenceScopeFingerprint,
) -> bool {
    left.revision == right.revision
        && left.selection == right.selection
        && left.test_set == right.test_set
}

/// Upgrades only already-observed covered lines. The mutation event ledger has
/// no corpus-completeness fingerprint, so this remains partial attribution.
pub fn apply_partial_mutation_kills(plan: &mut DiffPlan, observations: &[MutationKillObservation]) {
    if observations.is_empty() {
        return;
    }
    let kills = observations
        .iter()
        .map(|observation| (observation.path.as_str(), observation.line))
        .collect::<BTreeSet<_>>();
    plan.evidence.mutation = EvidenceState::Partial;
    for file in &mut plan.files {
        for (line, state) in &mut file.line_verification {
            if kills.contains(&(file.path.as_str(), *line)) && *state == LineVerification::Covered {
                *state = LineVerification::CoveredAndKilled;
            }
        }
        refresh_file_verification(file);
    }
    plan.language_summaries = language_summaries(&plan.files);
}

/// Applies corpus-complete mutation evidence. Mutation facts are positive
/// evidence only: an absent kill never changes a covered line into a negative
/// finding, even when the corpus is complete.
pub fn apply_scoped_mutation_kills(plan: &mut DiffPlan, artifact: &ScopedMutationArtifact) {
    if artifact.scope != plan.scope.evidence_scope {
        plan.evidence.mutation = EvidenceState::Stale;
        return;
    }
    if !artifact.complete {
        apply_partial_mutation_kills(plan, &artifact.observations);
        return;
    }
    let kills = artifact
        .observations
        .iter()
        .map(|observation| (observation.path.as_str(), observation.line))
        .collect::<BTreeSet<_>>();
    for file in &mut plan.files {
        for (line, state) in &mut file.line_verification {
            if kills.contains(&(file.path.as_str(), *line)) && *state == LineVerification::Covered {
                *state = LineVerification::CoveredAndKilled;
            }
        }
        refresh_file_verification(file);
    }
    plan.evidence.mutation = EvidenceState::Exact;
    plan.language_summaries = language_summaries(&plan.files);
}

/// Attaches SARIF rows only when they were produced for the immutable head
/// revision. A finding is evidence of a reported location, not evidence that
/// all hazards were searched for, so it remains partial and does not affect
/// the H1 risk term.
pub fn apply_partial_sarif_findings(plan: &mut DiffPlan, observations: &[SarifObservation]) {
    if observations.is_empty() {
        return;
    }
    plan.evidence.sarif = EvidenceState::Partial;
    plan.evidence.hazards = EvidenceState::Partial;
    for file in &mut plan.files {
        let findings = observations
            .iter()
            .filter(|observation| observation.path == file.path)
            .map(|observation| observation.finding.clone())
            .collect::<Vec<_>>();
        if findings.is_empty() {
            continue;
        }
        file.sarif_findings = findings.clone();
        for group in &mut file.groups {
            group.sarif_findings = findings
                .iter()
                .filter(|finding| {
                    spans_overlap(
                        finding.start_line,
                        finding.end_line,
                        group.start_line,
                        group.end_line,
                    )
                })
                .cloned()
                .collect();
        }
    }
}

/// A complete head report without a matching complete baseline is useful
/// location evidence, but it cannot distinguish a new finding from one that
/// simply was not observed in the baseline. Keep it visible and explicitly
/// incomparable rather than assigning it risk.
pub fn apply_head_only_sarif_findings(plan: &mut DiffPlan, observations: &[SarifObservation]) {
    // An empty complete head report is still meaningful: it establishes that
    // this analyzer ran, even though there is no comparable baseline for an
    // exact new/resolved classification.
    plan.evidence.sarif = EvidenceState::Partial;
    plan.evidence.hazards = EvidenceState::Partial;
    let mut observations = observations.to_vec();
    for observation in &mut observations {
        observation.finding.status = "uncompared".into();
    }
    apply_partial_sarif_findings(plan, &observations);
}

/// Applies a complete SARIF comparison. Only newly introduced tier-one
/// findings may contribute to the policy's H1 term; persisted findings remain
/// visible but are not re-counted as review risk.
pub fn apply_exact_sarif_findings(
    plan: &mut DiffPlan,
    observations: &[SarifObservation],
    base_observations: &[SarifObservation],
) {
    plan.evidence.sarif = EvidenceState::Exact;
    plan.evidence.hazards = EvidenceState::Exact;
    let base_by_identity = base_observations.iter().fold(
        BTreeMap::<String, Vec<&SarifObservation>>::new(),
        |mut grouped, observation| {
            grouped
                .entry(sarif_identity(&observation.finding))
                .or_default()
                .push(observation);
            grouped
        },
    );
    let head_identities = observations
        .iter()
        .map(|observation| sarif_identity(&observation.finding))
        .collect::<BTreeSet<_>>();
    plan.resolved_sarif_findings = base_observations
        .iter()
        .filter(|observation| !head_identities.contains(&sarif_identity(&observation.finding)))
        .map(|observation| {
            let mut finding = observation.finding.clone();
            finding.status = "resolved".into();
            ResolvedSarifFinding {
                path: observation.path.clone(),
                finding,
            }
        })
        .collect();
    for file in &mut plan.files {
        let findings = observations
            .iter()
            .filter(|observation| observation.path == file.path)
            .map(|observation| {
                let mut finding = observation.finding.clone();
                finding.status = match base_by_identity.get(&sarif_identity(&finding)) {
                    None => "new",
                    Some(base)
                        if base.iter().any(|candidate| {
                            candidate.path == observation.path
                                && candidate.finding.start_line == finding.start_line
                                && candidate.finding.end_line == finding.end_line
                        }) =>
                    {
                        "persisted"
                    }
                    Some(_) => "moved",
                }
                .into();
                finding
            })
            .collect::<Vec<_>>();
        file.sarif_findings = findings.clone();
        let h1 = findings
            .iter()
            .filter(|finding| finding.status == "new" && finding.tier_one)
            .count();
        apply_tier_one_hazards(&mut file.risk, h1);
        for group in &mut file.groups {
            group.sarif_findings = findings
                .iter()
                .filter(|finding| {
                    spans_overlap(
                        finding.start_line,
                        finding.end_line,
                        group.start_line,
                        group.end_line,
                    )
                })
                .cloned()
                .collect();
            let group_h1 = group
                .sarif_findings
                .iter()
                .filter(|finding| finding.status == "new" && finding.tier_one)
                .count();
            apply_tier_one_hazards(&mut group.risk, group_h1);
        }
    }
}

pub fn sarif_identity(finding: &SarifFindingSummary) -> String {
    format!(
        "{}\u{1f}{}\u{1f}{}\u{1f}{}",
        finding.source, finding.tool, finding.rule_id, finding.fingerprint
    )
}

fn apply_tier_one_hazards(risk: &mut RiskSummary, tier_one_hazards: usize) {
    risk.tier_one_hazards = tier_one_hazards;
    risk.score = risk.not_covered as f64
        + risk.partially_covered as f64 * 0.5
        + risk.added_complexity as f64 * 2.0
        + tier_one_hazards as f64 * 8.0;
}

fn spans_overlap(left_start: u32, left_end: u32, right_start: u32, right_end: u32) -> bool {
    left_start <= right_end && right_start <= left_end
}

fn code_line_numbers(line_kinds: &[LineKind], added: &BTreeSet<u32>) -> BTreeSet<u32> {
    line_kinds
        .iter()
        .enumerate()
        .filter_map(|(index, kind)| {
            let line_number = index as u32 + 1;
            (added.contains(&line_number) && *kind == LineKind::Code).then_some(line_number)
        })
        .collect()
}

fn unknown_line_verification(
    line_kinds: &[LineKind],
    added: &BTreeSet<u32>,
) -> BTreeMap<u32, LineVerification> {
    code_line_numbers(line_kinds, added)
        .into_iter()
        .map(|line| (line, LineVerification::Unknown))
        .collect()
}

fn refresh_file_verification(file: &mut DiffFile) {
    file.verification = verification_slices(file.line_verification.values().copied());
    file.line_annotations = file
        .line_verification
        .iter()
        .map(|(line, verification)| LineAnnotation {
            line: *line,
            verification: *verification,
        })
        .collect();
    let added = added_line_numbers(file.base_source.as_deref(), file.head_source.as_deref());
    file.risk = risk_summary(
        file.head_source.as_deref(),
        &file.path,
        &added,
        &file.verification,
    );
    for group in &mut file.groups {
        let lines = file
            .line_verification
            .range(group.start_line..=group.end_line)
            .map(|(_, state)| *state);
        group.verification = verification_slices(lines);
        let group_added = group_added_line_numbers(&added, group.start_line, group.end_line);
        group.risk = risk_summary(
            file.head_source.as_deref(),
            &file.path,
            &group_added,
            &group.verification,
        );
    }
}

fn verification_slices(states: impl IntoIterator<Item = LineVerification>) -> VerificationSlices {
    let mut slices = VerificationSlices::default();
    for state in states {
        match state {
            LineVerification::CoveredAndKilled => slices.covered_and_killed += 1,
            LineVerification::Covered => slices.covered += 1,
            LineVerification::PartiallyCovered => slices.partially_covered += 1,
            LineVerification::NotCovered => slices.not_covered += 1,
            LineVerification::Unknown => slices.unknown += 1,
        }
    }
    slices
}

fn risk_summary(
    source: Option<&str>,
    path: &str,
    added: &BTreeSet<u32>,
    verification: &VerificationSlices,
) -> RiskSummary {
    let added_complexity = decision_complexity(source, path, added);
    let tier_one_hazards = 0;
    RiskSummary {
        score: verification.not_covered as f64
            + added_complexity as f64 * 2.0
            + tier_one_hazards as f64 * 8.0,
        not_covered: verification.not_covered,
        partially_covered: verification.partially_covered,
        added_complexity,
        tier_one_hazards,
    }
}

fn unavailable_verification(lines: &AddedLines) -> VerificationSlices {
    VerificationSlices {
        unknown: lines.code,
        ..VerificationSlices::default()
    }
}

fn decision_complexity(source: Option<&str>, path: &str, added: &BTreeSet<u32>) -> usize {
    let Some(source) = source else {
        return 0;
    };
    let Some(language) = parser_language(path) else {
        return 0;
    };
    let mut parser = Parser::new();
    if parser.set_language(&language).is_err() {
        return 0;
    }
    let Some(tree) = parser.parse(source, None) else {
        return 0;
    };
    if tree.root_node().has_error() {
        return 0;
    }
    decision_nodes(tree.root_node(), added)
}

fn decision_nodes(node: Node<'_>, added: &BTreeSet<u32>) -> usize {
    let line = node.start_position().row as u32 + 1;
    let own = (node.is_named() && added.contains(&line) && is_decision_node(node.kind())) as usize;
    own + (0..node.child_count())
        .filter_map(|index| node.child(index))
        .map(|child| decision_nodes(child, added))
        .sum::<usize>()
}

fn is_decision_node(kind: &str) -> bool {
    matches!(
        kind,
        "if" | "if_statement"
            | "unless"
            | "unless_statement"
            | "while"
            | "while_statement"
            | "for"
            | "for_statement"
            | "case"
            | "case_statement"
            | "when"
            | "match"
            | "match_expression"
            | "switch_statement"
            | "catch_clause"
            | "rescue"
    )
}

fn language_summaries(files: &[DiffFile]) -> Vec<LanguageSummary> {
    let mut summaries = BTreeMap::<String, LanguageSummary>::new();
    for file in files {
        let Some(language) = &file.language else {
            continue;
        };
        let summary = summaries
            .entry(language.clone())
            .or_insert_with(|| LanguageSummary {
                language: language.clone(),
                production: AddedLines::default(),
                test: AddedLines::default(),
                production_verification: VerificationSlices::default(),
                production_by_visibility: VisibilityVerificationSlices::default(),
                test_assertions: None,
            });
        match file.role {
            SourceRole::Production => {
                add_lines(&mut summary.production, &file.added_lines);
                add_file_language_verification(summary, file);
            }
            SourceRole::Test => add_lines(&mut summary.test, &file.added_lines),
            _ => {}
        }
    }
    summaries.into_values().collect()
}

fn add_file_language_verification(summary: &mut LanguageSummary, file: &DiffFile) {
    for (line, state) in &file.line_verification {
        add_verification_slice(&mut summary.production_verification, *state);
        let visibility = visibility_at_line(file, *line);
        let target = match visibility {
            Visibility::Public => &mut summary.production_by_visibility.public,
            Visibility::Private => &mut summary.production_by_visibility.private,
            Visibility::Unknown => &mut summary.production_by_visibility.unknown,
        };
        add_verification_slice(target, *state);
    }
}

fn visibility_at_line(file: &DiffFile, line: u32) -> Visibility {
    file.groups
        .iter()
        .filter(|group| group.start_line <= line && line <= group.end_line)
        .min_by_key(|group| group.end_line - group.start_line)
        .map(|group| group.visibility)
        .unwrap_or(Visibility::Unknown)
}

fn add_verification_slice(target: &mut VerificationSlices, state: LineVerification) {
    match state {
        LineVerification::CoveredAndKilled => target.covered_and_killed += 1,
        LineVerification::Covered => target.covered += 1,
        LineVerification::PartiallyCovered => target.partially_covered += 1,
        LineVerification::NotCovered => target.not_covered += 1,
        LineVerification::Unknown => target.unknown += 1,
    }
}

fn add_lines(target: &mut AddedLines, source: &AddedLines) {
    target.code += source.code;
    target.comments += source.comments;
    target.other += source.other;
}

fn added_line_numbers(base: Option<&str>, head: Option<&str>) -> BTreeSet<u32> {
    let mut remaining = BTreeMap::<&str, usize>::new();
    for line in base.unwrap_or_default().lines() {
        *remaining.entry(line).or_default() += 1;
    }
    head.unwrap_or_default()
        .lines()
        .enumerate()
        .filter_map(|(index, line)| match remaining.get_mut(line) {
            Some(count) if *count > 0 => {
                *count -= 1;
                None
            }
            _ => Some(index as u32 + 1),
        })
        .collect()
}

fn summarize_added_lines(line_kinds: &[LineKind], added: &BTreeSet<u32>) -> AddedLines {
    let mut summary = AddedLines::default();
    for (index, kind) in line_kinds.iter().enumerate() {
        if !added.contains(&(index as u32 + 1)) {
            continue;
        }
        match kind {
            LineKind::Code => summary.code += 1,
            LineKind::Comment => summary.comments += 1,
            LineKind::Other => summary.other += 1,
        }
    }
    summary
}

fn semantic_groups(
    path: &str,
    base_source: Option<&str>,
    head_source: Option<&str>,
    added: &BTreeSet<u32>,
    line_kinds: &[LineKind],
) -> Vec<DiffGroup> {
    let Some(source) = head_source else {
        return Vec::new();
    };
    let extractor = HeuristicExtractor::default();
    let file = BlobFile {
        path: path.to_string(),
        contents: source.to_string(),
    };
    let base_units = base_source.map(|contents| {
        extractor.extract_units(&BlobFile {
            path: path.to_string(),
            contents: contents.to_string(),
        })
    });
    extractor
        .extract_units(&file)
        .into_iter()
        .filter_map(|unit| {
            let added_lines =
                summarize_group_lines(line_kinds, added, unit.start_line, unit.end_line);
            let base_unit = base_units
                .as_ref()
                .and_then(|units| matching_base_unit(units, &unit));
            include_semantic_group(&unit, base_unit, &added_lines).then(|| {
                let verification = unavailable_verification(&added_lines);
                let group_added = group_added_line_numbers(added, unit.start_line, unit.end_line);
                let visibility = visibility_for(path, source, &unit);
                let risk = risk_summary(Some(source), path, &group_added, &verification);
                DiffGroup {
                    name: unit.name,
                    kind: unit.kind.as_str().to_string(),
                    start_line: unit.start_line,
                    end_line: unit.end_line,
                    base_start_line: base_unit.map(|base| base.start_line),
                    base_end_line: base_unit.map(|base| base.end_line),
                    visibility,
                    risk,
                    verification,
                    sarif_findings: Vec::new(),
                    added_dependencies: Vec::new(),
                    added_state: Vec::new(),
                    big_o_time: String::new(),
                    big_o_time_status: "unknown".to_string(),
                    big_o_space: String::new(),
                    big_o_space_status: "unknown".to_string(),
                    added_lines,
                }
            })
        })
        .collect()
}

fn matching_base_unit<'a>(
    base_units: &'a [crate::model::LogicalUnit],
    head: &crate::model::LogicalUnit,
) -> Option<&'a crate::model::LogicalUnit> {
    base_units
        .iter()
        .find(|base| base.kind == head.kind && base.name == head.name)
}

fn include_semantic_group(
    unit: &crate::model::LogicalUnit,
    base_unit: Option<&crate::model::LogicalUnit>,
    added_lines: &AddedLines,
) -> bool {
    let has_change = added_lines.code + added_lines.comments + added_lines.other > 0;
    matches!(
        (has_change, unit.kind, base_unit.is_some()),
        (true, UnitKind::Function, _) | (true, _, false)
    )
}

fn group_added_line_numbers(added: &BTreeSet<u32>, start: u32, end: u32) -> BTreeSet<u32> {
    added.range(start..=end).copied().collect()
}

fn summarize_group_lines(
    line_kinds: &[LineKind],
    added: &BTreeSet<u32>,
    start: u32,
    end: u32,
) -> AddedLines {
    let lines = group_added_line_numbers(added, start, end);
    summarize_added_lines(line_kinds, &lines)
}

fn visibility_for(path: &str, source: &str, unit: &crate::model::LogicalUnit) -> Visibility {
    if unit.kind != UnitKind::Function {
        return Visibility::Unknown;
    }
    let signature = unit.signature.as_str();
    match language_for_path(path).as_deref() {
        Some("ruby") => {
            if ruby_private_context(source, unit.start_line) || signature.contains("private") {
                Visibility::Private
            } else {
                Visibility::Public
            }
        }
        Some("go") => go_exported_name(&unit.name)
            .then_some(Visibility::Public)
            .unwrap_or(Visibility::Private),
        Some("zig") | Some("rust") => signature
            .contains("pub ")
            .then_some(Visibility::Public)
            .unwrap_or(Visibility::Private),
        Some("typescript") | Some("javascript") => signature
            .contains("export ")
            .then_some(Visibility::Public)
            .unwrap_or(Visibility::Private),
        _ => Visibility::Unknown,
    }
}

fn go_exported_name(name: &str) -> bool {
    name.chars().next().is_some_and(char::is_uppercase)
}

fn ruby_private_context(source: &str, start_line: u32) -> bool {
    let preceding = source
        .lines()
        .take(start_line.saturating_sub(1) as usize)
        .collect::<Vec<_>>();
    preceding
        .into_iter()
        .rev()
        .find_map(|line| match line.trim() {
            "private" | "protected" => Some(true),
            "public" => Some(false),
            _ => None,
        })
        .unwrap_or(false)
}

fn residual_lines(
    line_kinds: &[LineKind],
    added: &BTreeSet<u32>,
    groups: &[DiffGroup],
) -> AddedLines {
    let assigned = groups
        .iter()
        .flat_map(|group| group.start_line..=group.end_line)
        .collect();
    let residual = added.difference(&assigned).copied().collect();
    summarize_added_lines(line_kinds, &residual)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LineKind {
    Code,
    Comment,
    Other,
}

fn classify_source_lines(source: Option<&str>, path: &str) -> Option<Vec<LineKind>> {
    let source = source?;
    let language = parser_language(path)?;
    let mut parser = Parser::new();
    parser.set_language(&language).ok()?;
    let tree = parser.parse(source, None)?;
    if tree.root_node().has_error() {
        return None;
    }
    let mut lines = vec![LineKind::Other; source.lines().count()];
    classify_node_lines(tree.root_node(), &mut lines);
    Some(lines)
}

fn parser_language(path: &str) -> Option<Language> {
    let extension = path.rsplit('.').next()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "c" | "h" => tree_sitter_c::LANGUAGE.into(),
        "cc" | "cpp" | "cxx" | "hh" | "hpp" | "hxx" => tree_sitter_cpp::LANGUAGE.into(),
        "cs" => tree_sitter_c_sharp::LANGUAGE.into(),
        "go" => tree_sitter_go::LANGUAGE.into(),
        "java" => tree_sitter_java::LANGUAGE.into(),
        "js" | "jsx" | "mjs" | "cjs" => tree_sitter_javascript::LANGUAGE.into(),
        "kt" | "kts" => tree_sitter_kotlin_ng::LANGUAGE.into(),
        "lua" => tree_sitter_lua::LANGUAGE.into(),
        "php" => tree_sitter_php::LANGUAGE_PHP.into(),
        "py" | "pyi" => tree_sitter_python::LANGUAGE.into(),
        "rb" => tree_sitter_ruby::LANGUAGE.into(),
        "rs" => tree_sitter_rust::LANGUAGE.into(),
        "swift" => tree_sitter_swift::LANGUAGE.into(),
        "ts" => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        "tsx" => tree_sitter_typescript::LANGUAGE_TSX.into(),
        "zig" => tree_sitter_zig::LANGUAGE.into(),
        _ => return None,
    })
}

fn classify_node_lines(node: Node<'_>, lines: &mut [LineKind]) {
    if lines.is_empty() {
        return;
    }
    if node.is_named() && node.child_count() == 0 {
        let kind = node
            .kind()
            .contains("comment")
            .then_some(LineKind::Comment)
            .unwrap_or(LineKind::Code);
        let start = node.start_position().row;
        let end = node.end_position().row;
        for line in start..=end.min(lines.len().saturating_sub(1)) {
            if kind == LineKind::Code || lines[line] == LineKind::Other {
                lines[line] = kind;
            }
        }
    }
    for index in 0..node.child_count() {
        if let Some(child) = node.child(index) {
            classify_node_lines(child, lines);
        }
    }
}

fn file_map(files: Vec<RevisionFile>) -> BTreeMap<String, RevisionFile> {
    files
        .into_iter()
        .map(|file| (file.path.clone(), file))
        .collect()
}

fn renamed_paths(
    base: &BTreeMap<String, RevisionFile>,
    head: &BTreeMap<String, RevisionFile>,
) -> BTreeMap<String, String> {
    let mut renamed = BTreeMap::new();
    for (old_path, old_file) in base {
        if head.contains_key(old_path) {
            continue;
        }
        if let Some((new_path, _)) = head.iter().find(|(new_path, new_file)| {
            !base.contains_key(*new_path) && new_file.contents == old_file.contents
        }) {
            renamed.insert(old_path.clone(), (*new_path).clone());
        }
    }
    renamed
}

fn build_inventory(files: &[DiffFile]) -> ChangeInventory {
    let mut inventory = ChangeInventory::default();
    let mut directories = BTreeSet::new();
    for file in files {
        inventory.changed_files += 1;
        *inventory.by_role.entry(file.role.key()).or_default() += 1;
        if let Some(directory) = file.path.rsplit_once('/').map(|(directory, _)| directory) {
            directories.insert(directory.to_string());
        }
        match file.change {
            FileChangeKind::Added => inventory.added_files += 1,
            FileChangeKind::Modified => inventory.modified_files += 1,
            FileChangeKind::Deleted => inventory.deleted_files += 1,
            FileChangeKind::Renamed => inventory.renamed_files += 1,
        }
        match file.role {
            SourceRole::Configuration => inventory.configuration_paths.push(ConfigFile {
                path: file.path.clone(),
                kind: config_kind(&file.path)
                    .unwrap_or("configuration")
                    .to_string(),
            }),
            SourceRole::Documentation => inventory.documentation_paths.push(file.path.clone()),
            SourceRole::Generated => inventory.generated_paths.push(file.path.clone()),
            SourceRole::Lockfile => inventory.lockfile_paths.push(file.path.clone()),
            _ => {}
        }
    }
    inventory.changed_directories = directories.len();
    inventory
}

fn dependency_changes(files: &[DiffFile]) -> Vec<DependencyChange> {
    files
        .iter()
        .filter_map(|file| dependency_change(file))
        .collect()
}

fn dependency_change(file: &DiffFile) -> Option<DependencyChange> {
    let path = file.path.as_str();
    if path == "package.json" || path.ends_with("/package.json") {
        Some(package_json_dependencies(file))
    } else if path == "Cargo.toml" || path.ends_with("/Cargo.toml") {
        Some(cargo_toml_dependencies(file))
    } else if path == "pyproject.toml" || path.ends_with("/pyproject.toml") {
        Some(pyproject_toml_dependencies(file))
    } else if path == "go.mod" || path.ends_with("/go.mod") {
        Some(go_mod_dependencies(file))
    } else if path == "composer.json" || path.ends_with("/composer.json") {
        Some(composer_dependencies(file))
    } else if path == "Package.resolved" || path.ends_with("/Package.resolved") {
        Some(package_resolved_dependencies(file))
    } else if path.ends_with(".csproj") || path.ends_with(".fsproj") {
        Some(dotnet_project_dependencies(file))
    } else if path == "pom.xml" || path.ends_with("/pom.xml") {
        Some(maven_dependencies(file))
    } else if is_requirements_path(path) {
        Some(requirements_dependencies(file))
    } else if is_manifest_path(path) {
        Some(DependencyChange {
            manifest_path: file.path.clone(),
            status: DependencyStatus::UnknownPackageFile,
            entries: Vec::new(),
        })
    } else {
        None
    }
}

fn cargo_toml_dependencies(file: &DiffFile) -> DependencyChange {
    let before = file
        .base_source
        .as_deref()
        .map(parse_cargo_toml)
        .transpose();
    let after = file
        .head_source
        .as_deref()
        .map(parse_cargo_toml)
        .transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return unknown_dependency_change(file);
    };
    exact_dependency_change(file, before.unwrap_or_default(), after.unwrap_or_default())
}

fn package_json_dependencies(file: &DiffFile) -> DependencyChange {
    let before = file
        .base_source
        .as_deref()
        .map(parse_package_json)
        .transpose();
    let after = file
        .head_source
        .as_deref()
        .map(parse_package_json)
        .transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return unknown_dependency_change(file);
    };
    exact_dependency_change(file, before.unwrap_or_default(), after.unwrap_or_default())
}

fn pyproject_toml_dependencies(file: &DiffFile) -> DependencyChange {
    let before = file
        .base_source
        .as_deref()
        .map(parse_pyproject_toml)
        .transpose();
    let after = file
        .head_source
        .as_deref()
        .map(parse_pyproject_toml)
        .transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return unknown_dependency_change(file);
    };
    exact_dependency_change(file, before.unwrap_or_default(), after.unwrap_or_default())
}

fn go_mod_dependencies(file: &DiffFile) -> DependencyChange {
    let before = file.base_source.as_deref().map(parse_go_mod).transpose();
    let after = file.head_source.as_deref().map(parse_go_mod).transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return unknown_dependency_change(file);
    };
    exact_dependency_change(file, before.unwrap_or_default(), after.unwrap_or_default())
}

fn composer_dependencies(file: &DiffFile) -> DependencyChange {
    dependency_change_from_sources(file, parse_composer_json)
}

fn package_resolved_dependencies(file: &DiffFile) -> DependencyChange {
    dependency_change_from_sources(file, parse_package_resolved)
}

fn dotnet_project_dependencies(file: &DiffFile) -> DependencyChange {
    dependency_change_from_sources(file, parse_dotnet_project)
}

fn maven_dependencies(file: &DiffFile) -> DependencyChange {
    dependency_change_from_sources(file, parse_maven_pom)
}

fn requirements_dependencies(file: &DiffFile) -> DependencyChange {
    dependency_change_from_sources(file, parse_requirements)
}

fn dependency_change_from_sources(
    file: &DiffFile,
    parser: fn(&str) -> Result<BTreeMap<(String, String), String>, ()>,
) -> DependencyChange {
    let before = file.base_source.as_deref().map(parser).transpose();
    let after = file.head_source.as_deref().map(parser).transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return unknown_dependency_change(file);
    };
    exact_dependency_change(file, before.unwrap_or_default(), after.unwrap_or_default())
}

fn unknown_dependency_change(file: &DiffFile) -> DependencyChange {
    DependencyChange {
        manifest_path: file.path.clone(),
        status: DependencyStatus::UnknownPackageFile,
        entries: Vec::new(),
    }
}

fn exact_dependency_change(
    file: &DiffFile,
    before: BTreeMap<(String, String), String>,
    after: BTreeMap<(String, String), String>,
) -> DependencyChange {
    let names = before
        .keys()
        .chain(after.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    let entries = names
        .into_iter()
        .filter_map(|key| {
            let before_entry = before.get(&key);
            let after_entry = after.get(&key);
            (before_entry != after_entry).then(|| DependencyEntry {
                name: key.1,
                scope: key.0,
                before: before_entry.cloned(),
                after: after_entry.cloned(),
            })
        })
        .collect();
    DependencyChange {
        manifest_path: file.path.clone(),
        status: DependencyStatus::Exact,
        entries,
    }
}

fn parse_package_json(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: serde_json::Value = serde_json::from_str(contents).map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    let mut dependencies = BTreeMap::new();
    for scope in [
        "dependencies",
        "devDependencies",
        "optionalDependencies",
        "peerDependencies",
    ] {
        if let Some(values) = object.get(scope).and_then(serde_json::Value::as_object) {
            for (name, version) in values {
                let version = version.as_str().ok_or(())?;
                dependencies.insert((scope.to_string(), name.clone()), version.to_string());
            }
        }
    }
    Ok(dependencies)
}

fn parse_composer_json(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: serde_json::Value = serde_json::from_str(contents).map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    let mut dependencies = BTreeMap::new();
    for scope in ["require", "require-dev"] {
        let Some(values) = object.get(scope) else {
            continue;
        };
        for (name, version) in values.as_object().ok_or(())? {
            let version = version.as_str().ok_or(())?;
            dependencies.insert((scope.to_string(), name.clone()), version.to_string());
        }
    }
    Ok(dependencies)
}

fn parse_package_resolved(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: serde_json::Value = serde_json::from_str(contents).map_err(|_| ())?;
    let packages = value
        .get("pins")
        .or_else(|| value.get("object").and_then(|object| object.get("pins")))
        .or_else(|| value.get("pins"))
        .or_else(|| value.get("packages"))
        .and_then(serde_json::Value::as_array)
        .ok_or(())?;
    let mut dependencies = BTreeMap::new();
    for package in packages {
        let object = package.as_object().ok_or(())?;
        let name = object
            .get("identity")
            .or_else(|| object.get("package"))
            .or_else(|| object.get("name"))
            .and_then(serde_json::Value::as_str)
            .filter(|name| !name.trim().is_empty())
            .ok_or(())?;
        let state = object
            .get("state")
            .and_then(serde_json::Value::as_object)
            .ok_or(())?;
        let version = state
            .get("version")
            .or_else(|| state.get("revision"))
            .and_then(serde_json::Value::as_str)
            .filter(|version| !version.trim().is_empty())
            .ok_or(())?;
        dependencies.insert(("resolved".into(), name.to_string()), version.to_string());
    }
    Ok(dependencies)
}

fn parse_dotnet_project(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let document = roxmltree::Document::parse(contents).map_err(|_| ())?;
    let mut dependencies = BTreeMap::new();
    for node in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "PackageReference")
    {
        let name = node
            .attribute("Include")
            .or_else(|| node.attribute("Update"))
            .filter(|name| !name.trim().is_empty())
            .ok_or(())?;
        let version = node
            .attribute("Version")
            .or_else(|| xml_child_text(node, "Version"))
            .filter(|version| !version.trim().is_empty())
            .ok_or(())?;
        if version.contains('$') || version.contains('{') {
            return Err(());
        }
        dependencies.insert(("package".into(), name.to_string()), version.to_string());
    }
    Ok(dependencies)
}

fn parse_maven_pom(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let document = roxmltree::Document::parse(contents).map_err(|_| ())?;
    let mut dependencies = BTreeMap::new();
    for node in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "dependency")
    {
        let group = xml_child_text(node, "groupId").ok_or(())?;
        let artifact = xml_child_text(node, "artifactId").ok_or(())?;
        let version = xml_child_text(node, "version").ok_or(())?;
        if [group, artifact, version]
            .iter()
            .any(|value| value.contains("${") || value.trim().is_empty())
        {
            return Err(());
        }
        let scope = xml_child_text(node, "scope").unwrap_or("compile");
        let scope = if has_dependency_management_ancestor(node) {
            format!("managed:{scope}")
        } else {
            scope.to_string()
        };
        dependencies.insert((scope, format!("{group}:{artifact}")), version.to_string());
    }
    Ok(dependencies)
}

fn xml_child_text<'a>(node: roxmltree::Node<'a, 'a>, name: &str) -> Option<&'a str> {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .and_then(|child| child.text())
        .map(str::trim)
}

fn has_dependency_management_ancestor(node: roxmltree::Node<'_, '_>) -> bool {
    node.ancestors().any(|ancestor| {
        ancestor.is_element() && ancestor.tag_name().name() == "dependencyManagement"
    })
}

fn parse_requirements(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let mut dependencies = BTreeMap::new();
    for original in contents.lines() {
        let requirement = original.split('#').next().unwrap_or_default().trim();
        if requirement.is_empty() {
            continue;
        }
        if requirement.starts_with('-') || requirement.contains("://") || requirement.contains('@')
        {
            return Err(());
        }
        let name_end = requirement
            .find(|character: char| {
                matches!(character, ' ' | '<' | '>' | '=' | '!' | '~' | ';' | '[')
            })
            .unwrap_or(requirement.len());
        let name = &requirement[..name_end];
        if name.is_empty()
            || !name.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.')
            })
        {
            return Err(());
        }
        dependencies.insert(
            ("requirements".into(), name.to_string()),
            requirement.to_string(),
        );
    }
    Ok(dependencies)
}

fn parse_cargo_toml(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: toml::Value = contents.parse().map_err(|_| ())?;
    let root = value.as_table().ok_or(())?;
    let mut dependencies = BTreeMap::new();
    for scope in ["dependencies", "dev-dependencies", "build-dependencies"] {
        let Some(entries) = root.get(scope) else {
            continue;
        };
        let entries = entries.as_table().ok_or(())?;
        for (name, value) in entries {
            dependencies.insert(
                (scope.to_string(), name.clone()),
                cargo_dependency_requirement(value)?,
            );
        }
    }
    Ok(dependencies)
}

fn cargo_dependency_requirement(value: &toml::Value) -> Result<String, ()> {
    match value {
        toml::Value::String(version) => Ok(version.clone()),
        toml::Value::Table(table) => table
            .get("version")
            .and_then(toml::Value::as_str)
            .map(str::to_string)
            .ok_or(()),
        _ => Err(()),
    }
}

fn parse_pyproject_toml(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: toml::Value = contents.parse().map_err(|_| ())?;
    let root = value.as_table().ok_or(())?;
    let mut dependencies = BTreeMap::new();
    if let Some(project) = root.get("project").and_then(toml::Value::as_table) {
        if let Some(entries) = project.get("dependencies") {
            python_dependency_array(entries, "dependencies", &mut dependencies)?;
        }
        if let Some(optional) = project.get("optional-dependencies") {
            for (name, entries) in optional.as_table().ok_or(())? {
                python_dependency_array(entries, &format!("optional:{name}"), &mut dependencies)?;
            }
        }
    }
    if let Some(poetry) = root
        .get("tool")
        .and_then(toml::Value::as_table)
        .and_then(|tool| tool.get("poetry"))
        .and_then(toml::Value::as_table)
    {
        for scope in ["dependencies", "dev-dependencies"] {
            if let Some(entries) = poetry.get(scope) {
                for (name, value) in entries.as_table().ok_or(())? {
                    dependencies.insert(
                        (format!("poetry:{scope}"), name.clone()),
                        cargo_dependency_requirement(value)?,
                    );
                }
            }
        }
    }
    Ok(dependencies)
}

fn python_dependency_array(
    value: &toml::Value,
    scope: &str,
    dependencies: &mut BTreeMap<(String, String), String>,
) -> Result<(), ()> {
    for requirement in value.as_array().ok_or(())? {
        let requirement = requirement.as_str().ok_or(())?;
        let name_end = requirement
            .find(|character: char| {
                matches!(character, ' ' | '<' | '>' | '=' | '!' | '~' | ';' | '[')
            })
            .unwrap_or(requirement.len());
        if name_end == 0 {
            return Err(());
        }
        dependencies.insert(
            (scope.to_string(), requirement[..name_end].to_string()),
            requirement.to_string(),
        );
    }
    Ok(())
}

fn parse_go_mod(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let mut dependencies = BTreeMap::new();
    let mut in_require_block = false;
    for original in contents.lines() {
        let line = original.split("//").next().unwrap_or_default().trim();
        if line.is_empty() {
            continue;
        }
        if line == "require (" {
            in_require_block = true;
            continue;
        }
        if in_require_block && line == ")" {
            in_require_block = false;
            continue;
        }
        if line.starts_with("replace ")
            || line.starts_with("exclude ")
            || line.starts_with("retract ")
        {
            return Err(());
        }
        let requirement = if let Some(value) = line.strip_prefix("require ") {
            value
        } else if in_require_block {
            line
        } else {
            continue;
        };
        let mut parts = requirement.split_whitespace();
        let (Some(name), Some(version), None) = (parts.next(), parts.next(), parts.next()) else {
            return Err(());
        };
        if !version.starts_with('v') {
            return Err(());
        }
        dependencies.insert(
            ("require".to_string(), name.to_string()),
            version.to_string(),
        );
    }
    (!in_require_block).then_some(dependencies).ok_or(())
}

fn source_role_with_overrides(path: &str, overrides: &ClassificationOverrides) -> SourceRole {
    if let Some(role) = overrides.role_for(path) {
        return role;
    }
    if is_lockfile(path) {
        SourceRole::Lockfile
    } else if is_generated(path) {
        SourceRole::Generated
    } else if path.ends_with(".md") {
        SourceRole::Documentation
    } else if config_kind(path).is_some() {
        SourceRole::Configuration
    } else if is_test_path(path) {
        SourceRole::Test
    } else if language_for_path(path).is_some() {
        SourceRole::Production
    } else {
        SourceRole::Other
    }
}

impl ClassificationOverrides {
    fn role_for(&self, path: &str) -> Option<SourceRole> {
        self.exact.get(path).copied().or_else(|| {
            self.prefixes
                .iter()
                .filter(|(prefix, _)| path.starts_with(prefix))
                .max_by_key(|(prefix, _)| prefix.len())
                .map(|(_, role)| *role)
        })
    }
}

/// Parses `.giga/diff.toml` from the selected head revision. Invalid,
/// absolute, and traversal paths are ignored rather than applying a broad
/// classification to an unintended file.
pub fn classification_overrides(contents: Option<&str>) -> ClassificationOverrides {
    let Some(contents) = contents else {
        return ClassificationOverrides::default();
    };
    let Ok(document) = contents.parse::<toml::Value>() else {
        return ClassificationOverrides::default();
    };
    let Some(rules) = document.get("overrides").and_then(toml::Value::as_array) else {
        return ClassificationOverrides::default();
    };
    let mut output = ClassificationOverrides::default();
    for rule in rules {
        let Some(table) = rule.as_table() else {
            continue;
        };
        let Some(role) = table
            .get("role")
            .and_then(toml::Value::as_str)
            .and_then(source_role_from_name)
        else {
            continue;
        };
        if let Some(path) = table.get("path").and_then(toml::Value::as_str) {
            if let Some(path) = normalized_override_path(path, false) {
                output.exact.insert(path, role);
            }
        }
        if let Some(prefix) = table.get("prefix").and_then(toml::Value::as_str) {
            if let Some(prefix) = normalized_override_path(prefix, true) {
                output.prefixes.push((prefix, role));
            }
        }
    }
    output
}

fn normalized_override_path(value: &str, is_prefix: bool) -> Option<String> {
    let normalized = value.trim().trim_matches('/');
    if normalized.is_empty()
        || value.starts_with('/')
        || normalized
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return None;
    }
    Some(if is_prefix {
        format!("{normalized}/")
    } else {
        normalized.to_string()
    })
}

fn source_role_from_name(value: &str) -> Option<SourceRole> {
    match value {
        "production" => Some(SourceRole::Production),
        "test" => Some(SourceRole::Test),
        "documentation" => Some(SourceRole::Documentation),
        "configuration" => Some(SourceRole::Configuration),
        "generated" => Some(SourceRole::Generated),
        "lockfile" => Some(SourceRole::Lockfile),
        "other" => Some(SourceRole::Other),
        _ => None,
    }
}

fn is_test_path(path: &str) -> bool {
    is_test_source_path(path)
}

fn is_generated(path: &str) -> bool {
    path.contains("/generated/")
        || path.starts_with("generated/")
        || path.contains("/vendor/")
        || path.starts_with("vendor/")
        || path.contains("/target/")
        || path.starts_with("target/")
        || path.ends_with(".min.js")
        || path.ends_with(".generated.ts")
}

fn is_lockfile(path: &str) -> bool {
    matches!(
        path.rsplit('/').next().unwrap_or(path),
        "Gemfile.lock"
            | "Cargo.lock"
            | "package-lock.json"
            | "pnpm-lock.yaml"
            | "yarn.lock"
            | "bun.lockb"
            | "poetry.lock"
            | "uv.lock"
            | "Pipfile.lock"
            | "go.sum"
            | "composer.lock"
            | "Package.resolved"
            | "packages.lock.json"
            | "gradle.lockfile"
    )
}

fn config_kind(path: &str) -> Option<&'static str> {
    let file = path.rsplit('/').next().unwrap_or(path);
    if path == ".giga/diff.toml" {
        return Some("gigasail");
    }
    if path.starts_with(".github/workflows/") && (file.ends_with(".yml") || file.ends_with(".yaml"))
    {
        return Some("github_workflow");
    }
    if path.starts_with(".github/actions/") {
        return Some("github_action");
    }
    if is_repository_config(file) || is_container_config(file) {
        return Some("repository");
    }
    if is_ruby_config(path, file) {
        return Some("ruby_manifest");
    }
    if is_rust_config(path, file) {
        return Some("rust_manifest");
    }
    if is_javascript_config(file) {
        return Some("javascript_manifest");
    }
    if is_python_config(file) {
        return Some("python_manifest");
    }
    if is_go_config(file) {
        return Some("go_manifest");
    }
    if is_zig_config(file) {
        return Some("zig_manifest");
    }
    if is_native_config(file) {
        return Some("native_build");
    }
    if is_jvm_config(path, file) {
        return Some("jvm_manifest");
    }
    if is_dotnet_config(file) {
        return Some("dotnet_manifest");
    }
    match file {
        "Package.swift" => Some("swift_manifest"),
        "composer.json" => Some("php_manifest"),
        ".luacheckrc" | "config.lua" => Some("lua_manifest"),
        _ if file.ends_with(".rockspec") => Some("lua_manifest"),
        _ => None,
    }
}

fn is_repository_config(file: &str) -> bool {
    matches!(
        file,
        ".gitignore" | ".gitattributes" | ".editorconfig" | ".rspec" | ".ruby-version"
    )
}

fn is_container_config(file: &str) -> bool {
    file == "Dockerfile"
        || file.starts_with("compose") && (file.ends_with(".yml") || file.ends_with(".yaml"))
}

fn is_ruby_config(path: &str, file: &str) -> bool {
    matches!(file, "Gemfile" | "Rakefile")
        || file.ends_with(".gemspec")
        || file.starts_with(".rubocop") && (file.ends_with(".yml") || file.ends_with(".yaml"))
        || path.starts_with("config/") && (file.ends_with(".yml") || file.ends_with(".yaml"))
}

fn is_rust_config(path: &str, file: &str) -> bool {
    matches!(
        file,
        "Cargo.toml" | "rust-toolchain" | "rust-toolchain.toml"
    ) || path.starts_with(".cargo/") && file.ends_with(".toml")
}

fn is_javascript_config(file: &str) -> bool {
    matches!(
        file,
        "package.json" | "eslint.config.js" | "eslint.config.mjs" | "eslint.config.cjs"
    ) || file.starts_with("tsconfig") && file.ends_with(".json")
        || file.starts_with(".eslintrc")
        || file.starts_with("vite.config.")
        || file.starts_with("webpack.config.")
}

fn is_python_config(file: &str) -> bool {
    matches!(
        file,
        "pyproject.toml" | "setup.cfg" | "setup.py" | "Pipfile" | "tox.ini" | "noxfile.py"
    ) || file.starts_with("requirements") && file.ends_with(".txt")
}

fn is_requirements_path(path: &str) -> bool {
    let file = path.rsplit('/').next().unwrap_or(path);
    file.starts_with("requirements") && file.ends_with(".txt")
}

fn is_go_config(file: &str) -> bool {
    file == "go.mod" || file.starts_with(".golangci.") || file == "Makefile"
}

fn is_zig_config(file: &str) -> bool {
    matches!(file, "build.zig" | "build.zig.zon" | "zig.mod")
}

fn is_native_config(file: &str) -> bool {
    matches!(file, "CMakeLists.txt" | "meson.build" | "vcpkg.json")
        || file.ends_with(".cmake")
        || file.starts_with("conanfile.")
}

fn is_jvm_config(path: &str, file: &str) -> bool {
    matches!(
        file,
        "pom.xml"
            | "build.gradle"
            | "build.gradle.kts"
            | "settings.gradle"
            | "settings.gradle.kts"
            | "gradle.properties"
    ) || path.ends_with("/gradle/libs.versions.toml")
}

fn is_dotnet_config(file: &str) -> bool {
    file.ends_with(".csproj")
        || file.ends_with(".fsproj")
        || file.ends_with(".sln")
        || file.starts_with("Directory.Build.")
        || file == "NuGet.config"
}

fn is_manifest_path(path: &str) -> bool {
    config_kind(path).is_some()
        && !matches!(
            config_kind(path),
            Some("repository") | Some("github_workflow")
        )
}

fn language_for_path(path: &str) -> Option<String> {
    let extension = path.rsplit('.').next()?.to_ascii_lowercase();
    let language = match extension.as_str() {
        "c" | "h" => "c",
        "cc" | "cpp" | "cxx" | "hpp" => "cpp",
        "cs" => "csharp",
        "go" => "go",
        "java" => "java",
        "js" | "jsx" => "javascript",
        "kt" | "kts" => "kotlin",
        "lua" => "lua",
        "php" => "php",
        "py" => "python",
        "rb" => "ruby",
        "rs" => "rust",
        "swift" => "swift",
        "ts" | "tsx" => "typescript",
        "zig" => "zig",
        _ => return None,
    };
    Some(language.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, contents: &str) -> RevisionFile {
        RevisionFile {
            path: path.to_string(),
            contents: Some(contents.to_string()),
        }
    }

    fn binary(path: &str) -> RevisionFile {
        RevisionFile {
            path: path.to_string(),
            contents: None,
        }
    }

    #[test]
    fn builds_a_revision_pinned_inventory_with_source_roles() {
        let plan = build_diff_plan(
            "a".repeat(40),
            "b".repeat(40),
            vec![
                file("lib/old.rb", "def old; end\n"),
                file("Gemfile", "source\n"),
            ],
            vec![
                file("lib/new.rb", "def old; end\n"),
                file("generated/client.generated.ts", "export {}\n"),
                file("test/new_test.rb", "assert true\n"),
                file("docs/readme.md", "# docs\n"),
                file(".github/workflows/ci.yml", "name: CI\n"),
                file("Cargo.lock", "lock\n"),
                binary("assets/chart.png"),
            ],
        );

        assert_eq!(plan.scope.base_oid, "a".repeat(40));
        assert_eq!(plan.scope.head_oid, "b".repeat(40));
        assert_eq!(plan.scope.policy_version, DIFF_POLICY_VERSION);
        assert_eq!(plan.inventory.changed_files, 8);
        assert_eq!(plan.inventory.renamed_files, 1);
        assert_eq!(plan.inventory.deleted_files, 1);
        assert_eq!(plan.inventory.documentation_paths, vec!["docs/readme.md"]);
        assert_eq!(plan.inventory.lockfile_paths, vec!["Cargo.lock"]);
        assert_eq!(
            plan.inventory.generated_paths,
            vec!["generated/client.generated.ts"]
        );
        assert!(plan
            .inventory
            .configuration_paths
            .iter()
            .any(|config| config.kind == "ruby_manifest"));
        assert!(plan
            .inventory
            .configuration_paths
            .iter()
            .any(|config| config.kind == "github_workflow"));
        assert_eq!(
            plan.files
                .iter()
                .find(|file| file.path == "lib/new.rb")
                .unwrap()
                .previous_path
                .as_deref(),
            Some("lib/old.rb")
        );
        assert_eq!(
            plan.files
                .iter()
                .find(|file| file.path == "assets/chart.png")
                .unwrap()
                .role,
            SourceRole::Other
        );
    }

    #[test]
    fn reports_package_json_dependency_changes_exactly() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file(
                "web/package.json",
                r#"{"dependencies":{"react":"18"},"devDependencies":{"vite":"5"}}"#,
            )],
            vec![file(
                "web/package.json",
                r#"{"dependencies":{"react":"19","zod":"4"},"devDependencies":{}}"#,
            )],
        );

        assert_eq!(plan.dependency_changes.len(), 1);
        let change = &plan.dependency_changes[0];
        assert_eq!(change.status, DependencyStatus::Exact);
        assert_eq!(change.entries.len(), 3);
        assert!(change.entries.iter().any(|entry| entry.name == "react"
            && entry.before.as_deref() == Some("18")
            && entry.after.as_deref() == Some("19")));
        assert!(change
            .entries
            .iter()
            .any(|entry| entry.name == "vite" && entry.after.is_none()));
        assert!(change
            .entries
            .iter()
            .any(|entry| entry.name == "zod" && entry.before.is_none()));
    }

    #[test]
    fn reports_static_cargo_toml_dependency_changes_exactly() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file(
                "gems/gigasail/Cargo.toml",
                "[dependencies]\nserde = \"1\"\n[dev-dependencies]\ntempfile = \"3\"\n",
            )],
            vec![file(
                "gems/gigasail/Cargo.toml",
                "[dependencies]\nserde = { version = \"1.0\" }\ntoml = \"0.8\"\n",
            )],
        );

        let change = &plan.dependency_changes[0];
        assert_eq!(change.status, DependencyStatus::Exact);
        assert!(change.entries.iter().any(|entry| entry.name == "serde"
            && entry.before.as_deref() == Some("1")
            && entry.after.as_deref() == Some("1.0")));
        assert!(change.entries.iter().any(|entry| entry.name == "toml"));
        assert!(change.entries.iter().any(|entry| entry.name == "tempfile"
            && entry.scope == "dev-dependencies"
            && entry.after.is_none()));
    }

    #[test]
    fn reports_dynamic_cargo_toml_dependencies_as_unknown() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file(
                "Cargo.toml",
                "[dependencies]\nserde = { workspace = true }\n",
            )],
            vec![file(
                "Cargo.toml",
                "[dependencies]\nserde = { workspace = true }\n",
            )],
        );

        assert_eq!(plan.dependency_changes.len(), 0);
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file("Cargo.toml", "[dependencies]\nserde = \"1\"\n")],
            vec![file(
                "Cargo.toml",
                "[dependencies]\nserde = { workspace = true }\n",
            )],
        );
        assert_eq!(
            plan.dependency_changes[0].status,
            DependencyStatus::UnknownPackageFile
        );
    }

    #[test]
    fn reports_static_pyproject_and_go_mod_dependencies_exactly() {
        assert!(parse_pyproject_toml("[project]\ndependencies = [\"requests>=2\"]\n[project.optional-dependencies]\ntest = [\"pytest>=7\"]\n").is_ok());
        assert!(parse_go_mod("module example.test/app\n\nrequire example.test/old v1.0.0\nrequire (\n  example.test/keep v1.0.0\n)\n").is_ok());
        assert!(parse_pyproject_toml("[project]\ndependencies = [\"requests>=3\", \"httpx>=1\"]\n[project.optional-dependencies]\ntest = [\"pytest>=8\"]\n").is_ok());
        assert!(parse_go_mod("module example.test/app\n\nrequire (\n  example.test/keep v1.1.0\n  example.test/new v0.1.0\n)\n").is_ok());
        let plan = build_diff_plan(
            "base", "head",
            vec![
                file("pyproject.toml", "[project]\ndependencies = [\"requests>=2\"]\n[project.optional-dependencies]\ntest = [\"pytest>=7\"]\n"),
                file("go.mod", "module example.test/app\n\nrequire example.test/old v1.0.0\nrequire (\n  example.test/keep v1.0.0\n)\n"),
            ],
            vec![
                file("pyproject.toml", "[project]\ndependencies = [\"requests>=3\", \"httpx>=1\"]\n[project.optional-dependencies]\ntest = [\"pytest>=8\"]\n"),
                file("go.mod", "module example.test/app\n\nrequire (\n  example.test/keep v1.1.0\n  example.test/new v0.1.0\n)\n"),
            ],
        );
        assert_eq!(plan.dependency_changes.len(), 2);
        assert!(
            plan.dependency_changes
                .iter()
                .all(|change| change.status == DependencyStatus::Exact),
            "{:#?}",
            plan.dependency_changes
        );
        let python = plan
            .dependency_changes
            .iter()
            .find(|change| change.manifest_path == "pyproject.toml")
            .unwrap();
        assert!(
            python
                .entries
                .iter()
                .any(|entry| entry.name == "requests"
                    && entry.after.as_deref() == Some("requests>=3"))
        );
        assert!(python
            .entries
            .iter()
            .any(|entry| entry.name == "pytest" && entry.scope == "optional:test"));
        let go = plan
            .dependency_changes
            .iter()
            .find(|change| change.manifest_path == "go.mod")
            .unwrap();
        assert!(go
            .entries
            .iter()
            .any(|entry| entry.name == "example.test/old" && entry.after.is_none()));
        assert!(go
            .entries
            .iter()
            .any(|entry| entry.name == "example.test/new" && entry.before.is_none()));
    }

    #[test]
    fn reports_structured_composer_swift_dotnet_maven_and_requirements_dependencies() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("composer.json", "{\"require\":{\"vendor/old\":\"^1\"}}"),
                file("Package.resolved", "{\"pins\":[{\"package\":\"Old\",\"state\":{\"version\":\"1.0.0\"}}]}"),
                file("app.csproj", "<Project><ItemGroup><PackageReference Include=\"Old\" Version=\"1.0\" /></ItemGroup></Project>"),
                file("pom.xml", "<project><dependencies><dependency><groupId>org.old</groupId><artifactId>old</artifactId><version>1.0</version></dependency></dependencies></project>"),
                file("requirements.txt", "old==1\n"),
            ],
            vec![
                file("composer.json", "{\"require\":{\"vendor/new\":\"^2\"},\"require-dev\":{\"vendor/test\":\"^1\"}}"),
                file("Package.resolved", "{\"pins\":[{\"identity\":\"new\",\"state\":{\"version\":\"2.0.0\"}}]}"),
                file("app.csproj", "<Project><ItemGroup><PackageReference Include=\"New\"><Version>2.0</Version></PackageReference></ItemGroup></Project>"),
                file("pom.xml", "<project><dependencies><dependency><groupId>org.new</groupId><artifactId>new</artifactId><version>2.0</version><scope>test</scope></dependency></dependencies></project>"),
                file("requirements.txt", "new>=2\n"),
            ],
        );

        assert_eq!(plan.dependency_changes.len(), 5);
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.status == DependencyStatus::Exact));
        let names = plan
            .dependency_changes
            .iter()
            .flat_map(|change| change.entries.iter().map(|entry| entry.name.as_str()))
            .collect::<Vec<_>>();
        assert!(names.contains(&"vendor/new"));
        assert!(names.contains(&"new"));
        assert!(names.contains(&"New"));
        assert!(names.contains(&"org.new:new"));
    }

    #[test]
    fn keeps_dynamic_structured_manifest_versions_and_requirements_unknown() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("app.csproj", "<Project><ItemGroup><PackageReference Include=\"Example\" Version=\"$(Version)\" /></ItemGroup></Project>"),
                file("pom.xml", "<project><dependencies><dependency><groupId>org.example</groupId><artifactId>example</artifactId><version>${version}</version></dependency></dependencies></project>"),
                file("requirements.txt", "-r common.txt\n"),
            ],
            vec![
                file("app.csproj", "<Project><ItemGroup><PackageReference Include=\"Example\" Version=\"2\" /></ItemGroup></Project>"),
                file("pom.xml", "<project><dependencies><dependency><groupId>org.example</groupId><artifactId>example</artifactId><version>2</version></dependency></dependencies></project>"),
                file("requirements.txt", "example==2\n"),
            ],
        );

        assert_eq!(plan.dependency_changes.len(), 3);
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.status == DependencyStatus::UnknownPackageFile));
    }

    #[test]
    fn keeps_dynamic_python_and_go_module_changes_unknown() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("pyproject.toml", "[project]\ndependencies = [1]\n"),
                file(
                    "go.mod",
                    "module example.test/app\nreplace example.test/a => example.test/b v1.0.0\n",
                ),
            ],
            vec![
                file(
                    "pyproject.toml",
                    "[project]\ndependencies = [\"requests\"]\n",
                ),
                file(
                    "go.mod",
                    "module example.test/app\nrequire example.test/a v1.0.0\n",
                ),
            ],
        );
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.status == DependencyStatus::UnknownPackageFile));
    }

    #[test]
    fn reports_dynamic_or_invalid_manifests_as_unknown_package_file_changes() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("Gemfile", "gem 'old'\n"),
                file("package.json", "not json"),
            ],
            vec![
                file("Gemfile", "gem name_from_env\n"),
                file("package.json", "still not json"),
            ],
        );

        assert_eq!(plan.dependency_changes.len(), 2);
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.status == DependencyStatus::UnknownPackageFile));
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.entries.is_empty()));
    }

    #[test]
    fn excludes_unchanged_files_and_invalid_exact_dependency_values() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("same.rb", "unchanged\n"),
                file("package.json", r#"{"dependencies":{"bad":3}}"#),
            ],
            vec![
                file("same.rb", "unchanged\n"),
                file("package.json", r#"{"dependencies":{"bad":"3"}}"#),
            ],
        );

        assert_eq!(plan.files.len(), 1);
        assert_eq!(
            plan.dependency_changes[0].status,
            DependencyStatus::UnknownPackageFile
        );
    }

    #[test]
    fn summarizes_meaningful_added_lines_and_symbol_groups() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file("lib/app.rb", "def run\nend\n")],
            vec![file(
                "lib/app.rb",
                "# prepares output\ndef run\n  work\nend\n",
            )],
        );

        let changed = &plan.files[0];
        assert_eq!(
            changed.added_lines,
            AddedLines {
                code: 1,
                comments: 1,
                other: 0
            }
        );
        assert_eq!(changed.groups.len(), 1);
        assert_eq!(changed.groups[0].kind, "function");
        assert_eq!(changed.groups[0].visibility, Visibility::Public);
        assert_eq!(changed.groups[0].added_lines.code, 1);
        assert_eq!(plan.language_summaries[0].language, "ruby");
        assert_eq!(plan.language_summaries[0].production.comments, 1);
    }

    #[test]
    fn ranks_changed_files_by_added_meaningful_code_and_decisions() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file("lib/safe.rb", "def safe\nend\n")],
            vec![
                file("lib/safe.rb", "def safe\n  value\nend\n"),
                file(
                    "lib/risky.rb",
                    "def risky\n  if condition\n    value\n  end\nend\n",
                ),
            ],
        );

        assert_eq!(plan.files[0].path, "lib/risky.rb");
        assert_eq!(plan.files[0].risk.added_complexity, 1);
        assert_eq!(plan.files[0].risk.score, 2.0);
        assert_eq!(plan.files[1].path, "lib/safe.rb");
        assert_eq!(plan.files[1].risk.score, 0.0);
    }

    #[test]
    fn counts_only_tree_sitter_decisions_on_added_code() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![],
            vec![
                file("lib/comment.rb", "# if condition\ndef value\n  1\nend\n"),
                file(
                    "web/value.js",
                    "export function value(input) {\n  if (input) return 1;\n  return 0;\n}\n",
                ),
            ],
        );
        let ruby = plan
            .files
            .iter()
            .find(|file| file.path == "lib/comment.rb")
            .unwrap();
        let javascript = plan
            .files
            .iter()
            .find(|file| file.path == "web/value.js")
            .unwrap();
        assert_eq!(ruby.risk.added_complexity, 0);
        assert_eq!(javascript.risk.added_complexity, 1);
    }

    #[test]
    fn marks_evidence_unknown_without_revision_scoped_artifacts() {
        let plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "def app\nend\n")],
        );

        assert_eq!(plan.evidence, unavailable_evidence());
        assert_eq!(plan.files[0].risk.tier_one_hazards, 0);
    }

    #[test]
    fn bounds_plan_source_blobs_to_the_requested_page_and_raw_path() {
        let files = (0..(DIFF_FILE_PAGE_SIZE + 1))
            .map(|index| file(&format!("lib/{index}.rb"), "puts :value\n"))
            .collect();
        let mut plan = build_diff_plan("base", "head", Vec::new(), files);
        let paged_path = plan.files[DIFF_FILE_PAGE_SIZE].path.clone();
        retain_plan_sources_for_page(&mut plan, Some(2), Some("lib/0.rb"));
        assert!(plan.files.iter().any(|file| {
            file.path == "lib/0.rb" && file.head_source.as_deref() == Some("puts :value\n")
        }));
        assert!(plan.files.iter().any(|file| {
            file.path == paged_path && file.head_source.as_deref() == Some("puts :value\n")
        }));
        assert!(plan.files.iter().all(|file| {
            file.path == "lib/0.rb" || file.path == paged_path || file.head_source.is_none()
        }));
    }

    #[test]
    fn groups_changed_public_and_private_ruby_methods_with_matched_base_ranges() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file(
                "lib/app.rb",
                "class App\n  def run\n    old\n  end\n\n  private\n\n  def hide\n    old\n  end\nend\n",
            )],
            vec![file(
                "lib/app.rb",
                "class App\n  def run\n    new\n  end\n\n  private\n\n  def hide\n    new\n  end\nend\n",
            )],
        );

        let groups = &plan.files[0].groups;
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].visibility, Visibility::Public);
        assert_eq!(groups[0].base_start_line, Some(2));
        assert_eq!(groups[1].visibility, Visibility::Private);
        assert_eq!(groups[1].base_start_line, Some(8));
        assert_eq!(groups[0].verification.unknown, 1);
        assert_eq!(plan.files[0].residual_lines, AddedLines::default());
    }

    #[test]
    fn keeps_unassigned_added_lines_in_the_residual_raw_diff_bucket() {
        let plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file(
                "lib/app.rb",
                "require \"json\"\n\ndef run\n  value\nend\n",
            )],
        );

        let changed = &plan.files[0];
        assert_eq!(changed.groups.len(), 1);
        assert_eq!(changed.residual_lines.code, 1);
        assert_eq!(changed.verification.unknown, 3);
        assert_eq!(changed.risk.not_covered, 0);
    }

    #[test]
    fn classifies_supported_language_function_visibility_conservatively() {
        let plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![
                file("main.go", "func Public() {}\nfunc private() {}\n"),
                file(
                    "main.zig",
                    "pub fn visible() void {}\nfn hidden() void {}\n",
                ),
                file("lib.rs", "pub fn visible() {}\nfn hidden() {}\n"),
                file(
                    "app.ts",
                    "export function visible() {}\nfunction hidden() {}\n",
                ),
            ],
        );

        let visibility = |path: &str| {
            plan.files
                .iter()
                .find(|file| file.path == path)
                .unwrap()
                .groups
                .iter()
                .map(|group| (group.name.as_str(), group.visibility))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            visibility("main.go"),
            vec![
                ("Public", Visibility::Public),
                ("private", Visibility::Private)
            ]
        );
        assert_eq!(
            visibility("main.zig"),
            vec![
                ("visible", Visibility::Public),
                ("hidden", Visibility::Private)
            ]
        );
        assert_eq!(
            visibility("lib.rs"),
            vec![
                ("visible", Visibility::Public),
                ("hidden", Visibility::Private)
            ]
        );
        assert_eq!(
            visibility("app.ts"),
            vec![
                ("visible", Visibility::Public),
                ("hidden", Visibility::Private)
            ]
        );
    }

    #[test]
    fn summarizes_production_by_language_visibility_and_verification_state() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file(
                "lib/app.rb",
                "def run\n  value\nend\n\nprivate\ndef hide\n  secret\nend\n",
            )],
        );
        apply_partial_coverage(
            &mut plan,
            &[
                CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                    hits: 1,
                    is_partial: false,
                },
                CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 6,
                    hits: 1,
                    is_partial: true,
                },
            ],
        );
        apply_partial_mutation_kills(
            &mut plan,
            &[MutationKillObservation {
                path: "lib/app.rb".into(),
                line: 1,
            }],
        );

        let summary = &plan.language_summaries[0];
        assert_eq!(summary.production_verification.covered_and_killed, 1);
        assert_eq!(summary.production_verification.partially_covered, 1);
        assert_eq!(summary.production_verification.unknown, 3);
        assert_eq!(
            summary.production_by_visibility.public.covered_and_killed,
            1
        );
        assert_eq!(
            summary.production_by_visibility.private.partially_covered,
            1
        );
        assert_eq!(summary.production_by_visibility.private.unknown, 1);
        assert_eq!(summary.production_by_visibility.unknown.unknown, 1);
        assert_eq!(summary.test_assertions, None);
    }

    #[test]
    fn applies_matching_coverage_as_partial_without_inventing_negative_evidence() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "def run\n  value\nend\n")],
        );
        apply_partial_coverage(
            &mut plan,
            &[
                CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                    hits: 1,
                    is_partial: false,
                },
                CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 2,
                    hits: 1,
                    is_partial: true,
                },
            ],
        );

        let file = &plan.files[0];
        assert_eq!(plan.evidence.coverage, EvidenceState::Partial);
        assert_eq!(file.verification.covered, 1);
        assert_eq!(file.verification.partially_covered, 1);
        assert_eq!(file.verification.unknown, 0);
        assert_eq!(file.verification.not_covered, 0);
        assert_eq!(file.risk.not_covered, 0);
    }

    #[test]
    fn requires_complete_matching_scope_before_reporting_not_covered() {
        let scope = EvidenceScopeFingerprint {
            revision: "head".into(),
            selection: "production".into(),
            mutant_corpus: "mutants-v1".into(),
            test_set: "suite-v1".into(),
        };
        let mut plan = with_evidence_scope(
            build_diff_plan(
                "base",
                "head",
                Vec::new(),
                vec![file("lib/app.rb", "def run\n  value\nend\n")],
            ),
            scope.clone(),
        );
        let expected = plan.files[0]
            .line_verification
            .keys()
            .map(|line| ("lib/app.rb".to_string(), *line))
            .collect();
        apply_scoped_coverage(
            &mut plan,
            &ScopedCoverageArtifact {
                scope,
                complete: true,
                expected_lines: expected,
                observations: vec![CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                    hits: 0,
                    is_partial: false,
                }],
            },
        );
        assert_eq!(plan.evidence.coverage, EvidenceState::Exact);
        assert_eq!(plan.files[0].verification.not_covered, 1);
        assert_eq!(plan.files[0].verification.unknown, 1);

        let mut stale = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "value\n")],
        );
        apply_scoped_coverage(
            &mut stale,
            &ScopedCoverageArtifact {
                scope: EvidenceScopeFingerprint {
                    revision: "elsewhere".into(),
                    selection: "production".into(),
                    mutant_corpus: "mutants-v1".into(),
                    test_set: "suite-v1".into(),
                },
                complete: true,
                expected_lines: BTreeSet::new(),
                observations: Vec::new(),
            },
        );
        assert_eq!(stale.evidence.coverage, EvidenceState::Stale);
    }

    #[test]
    fn complete_coverage_for_a_larger_corpus_is_exact_for_the_reviewed_subset() {
        let scope = EvidenceScopeFingerprint {
            revision: "head".into(),
            selection: "full".into(),
            mutant_corpus: "not-applicable".into(),
            test_set: "unit".into(),
        };
        let mut plan = with_evidence_scope(
            build_diff_plan(
                "base",
                "head",
                Vec::new(),
                vec![file("lib/app.rb", "def run\n  value\nend\n")],
            ),
            scope.clone(),
        );
        let mut expected = plan.files[0]
            .line_verification
            .keys()
            .map(|line| ("lib/app.rb".to_string(), *line))
            .collect::<BTreeSet<_>>();
        expected.insert(("lib/unchanged.rb".to_string(), 1));
        apply_scoped_coverage(
            &mut plan,
            &ScopedCoverageArtifact {
                scope,
                complete: true,
                expected_lines: expected,
                observations: vec![CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                    hits: 1,
                    is_partial: false,
                }],
            },
        );
        assert_eq!(plan.evidence.coverage, EvidenceState::Exact);
    }

    #[test]
    fn upgrades_only_known_covered_lines_with_partial_mutation_kills() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "def run\n  value\nend\n")],
        );
        apply_partial_coverage(
            &mut plan,
            &[CoverageObservation {
                path: "lib/app.rb".into(),
                line: 1,
                hits: 1,
                is_partial: false,
            }],
        );
        apply_partial_mutation_kills(
            &mut plan,
            &[
                MutationKillObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                },
                MutationKillObservation {
                    path: "lib/app.rb".into(),
                    line: 2,
                },
            ],
        );

        let verification = &plan.files[0].verification;
        assert_eq!(plan.evidence.mutation, EvidenceState::Partial);
        assert_eq!(verification.covered_and_killed, 1);
        assert_eq!(verification.covered, 0);
        assert_eq!(verification.unknown, 1);
    }

    #[test]
    fn applies_complete_scoped_mutation_kills_without_creating_negative_claims() {
        let scope = EvidenceScopeFingerprint {
            revision: "head".into(),
            selection: "production".into(),
            mutant_corpus: "mutants-v1".into(),
            test_set: "suite-v1".into(),
        };
        let mut plan = with_evidence_scope(
            build_diff_plan(
                "base",
                "head",
                Vec::new(),
                vec![file("lib/app.rb", "def run\n  value\nend\n")],
            ),
            scope.clone(),
        );
        let expected_lines = plan.files[0]
            .line_verification
            .keys()
            .map(|line| ("lib/app.rb".to_string(), *line))
            .collect();
        apply_scoped_coverage(
            &mut plan,
            &ScopedCoverageArtifact {
                scope: scope.clone(),
                complete: true,
                expected_lines,
                observations: vec![CoverageObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                    hits: 1,
                    is_partial: false,
                }],
            },
        );
        apply_scoped_mutation_kills(
            &mut plan,
            &ScopedMutationArtifact {
                scope,
                complete: true,
                observations: vec![MutationKillObservation {
                    path: "lib/app.rb".into(),
                    line: 1,
                }],
            },
        );

        assert_eq!(plan.evidence.mutation, EvidenceState::Exact);
        assert_eq!(plan.files[0].verification.covered_and_killed, 1);
        assert_eq!(plan.files[0].verification.not_covered, 0);
        assert_eq!(
            plan.files[0].line_annotations,
            vec![
                LineAnnotation {
                    line: 1,
                    verification: LineVerification::CoveredAndKilled,
                },
                LineAnnotation {
                    line: 2,
                    verification: LineVerification::Unknown,
                },
            ]
        );
    }

    #[test]
    fn rejects_mismatched_or_incomplete_scoped_mutation_evidence() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "value\n")],
        );
        let stale_scope = EvidenceScopeFingerprint {
            revision: "elsewhere".into(),
            selection: "production".into(),
            mutant_corpus: "mutants-v1".into(),
            test_set: "suite-v1".into(),
        };
        apply_scoped_mutation_kills(
            &mut plan,
            &ScopedMutationArtifact {
                scope: stale_scope,
                complete: true,
                observations: Vec::new(),
            },
        );
        assert_eq!(plan.evidence.mutation, EvidenceState::Stale);

        let scope = plan.scope.evidence_scope.clone();
        apply_scoped_mutation_kills(
            &mut plan,
            &ScopedMutationArtifact {
                scope,
                complete: false,
                observations: Vec::new(),
            },
        );
        assert_eq!(plan.evidence.mutation, EvidenceState::Stale);
    }

    #[test]
    fn excludes_closure_only_lines_across_brace_languages() {
        for (path, source, closing_line) in [
            ("main.zig", "pub fn run() void {\n}\n", 2),
            ("main.go", "func run() {\n}\n", 2),
            ("main.rs", "fn run() {\n}\n", 2),
        ] {
            assert_eq!(
                classify_source_lines(Some(source), path).unwrap()[closing_line - 1],
                LineKind::Other
            );
        }
        let lines =
            classify_source_lines(Some("// intent\nfunc run() { return value }\n"), "main.go")
                .unwrap();
        assert_eq!(lines[0], LineKind::Comment);
        assert_eq!(lines[1], LineKind::Code);
    }

    #[test]
    fn makes_parse_errors_and_unsupported_files_raw_only() {
        assert!(classify_source_lines(Some("def broken("), "lib/app.rb").is_none());
        assert!(classify_source_lines(Some("# heading"), "README.md").is_none());
        let plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/broken.rb", "def broken(")],
        );
        assert!(!plan.files[0].semantic_classification_available);
        assert_eq!(plan.files[0].added_lines, AddedLines::default());
        assert!(plan.files[0].groups.is_empty());
    }

    #[test]
    fn classifies_empty_supported_source_without_indexing_an_absent_line() {
        assert_eq!(
            classify_source_lines(Some(""), "empty.go"),
            Some(Vec::new())
        );
        let plan = build_diff_plan("base", "head", Vec::new(), vec![file("empty.go", "")]);
        assert_eq!(plan.files.len(), 1);
        assert!(plan.files[0].semantic_classification_available);
        assert_eq!(plan.files[0].added_lines, AddedLines::default());
    }

    #[test]
    fn classifies_supported_tree_sitter_languages_from_syntax() {
        let fixtures = [
            ("value.c", "int value(void) { return 1; }\n"),
            ("value.cpp", "int value() { return 1; }\n"),
            ("Value.cs", "class Value { int Get() { return 1; } }\n"),
            ("value.go", "package value\nfunc Get() int { return 1 }\n"),
            ("Value.java", "class Value { int get() { return 1; } }\n"),
            ("value.js", "function value() { return 1; }\n"),
            ("Value.kt", "fun value(): Int { return 1 }\n"),
            ("value.lua", "function value() return 1 end\n"),
            ("value.php", "<?php function value() { return 1; }\n"),
            ("value.py", "def value():\n    return 1\n"),
            ("value.rb", "def value\n  1\nend\n"),
            ("value.rs", "fn value() -> i32 { 1 }\n"),
            ("value.swift", "func value() -> Int { return 1 }\n"),
            ("value.ts", "function value(): number { return 1; }\n"),
            ("value.tsx", "const value = <div />;\n"),
            ("value.zig", "pub fn value() i32 { return 1; }\n"),
        ];
        for (path, source) in fixtures {
            assert!(
                classify_source_lines(Some(source), path)
                    .unwrap()
                    .contains(&LineKind::Code),
                "{path} should contain semantic code"
            );
        }
    }

    #[test]
    fn attaches_partial_sarif_findings_only_to_matching_file_and_group_spans() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file(
                "lib/app.rb",
                "def first\n  value\nend\n\ndef second\n  other\nend\n",
            )],
        );
        apply_partial_sarif_findings(
            &mut plan,
            &[
                SarifObservation {
                    path: "lib/app.rb".into(),
                    finding: sarif_finding(2, 2, "first"),
                },
                SarifObservation {
                    path: "other.rb".into(),
                    finding: sarif_finding(1, 1, "other"),
                },
            ],
        );

        let file = &plan.files[0];
        assert_eq!(plan.evidence.sarif, EvidenceState::Partial);
        assert_eq!(plan.evidence.hazards, EvidenceState::Partial);
        assert_eq!(file.sarif_findings.len(), 1);
        assert_eq!(file.sarif_findings[0].message, "first");
        assert_eq!(file.groups[0].sarif_findings.len(), 1);
        assert!(file.groups[1].sarif_findings.is_empty());
        assert_eq!(file.risk.tier_one_hazards, 0);
    }

    #[test]
    fn complete_head_only_sarif_stays_uncompared_and_out_of_risk() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "def run\n  value\nend\n")],
        );
        let mut finding = sarif_finding(2, 2, "uncompared");
        finding.tier_one = true;
        apply_head_only_sarif_findings(
            &mut plan,
            &[SarifObservation {
                path: "lib/app.rb".into(),
                finding,
            }],
        );
        assert_eq!(plan.evidence.sarif, EvidenceState::Partial);
        assert_eq!(plan.files[0].sarif_findings[0].status, "uncompared");
        assert_eq!(plan.files[0].risk.tier_one_hazards, 0);
    }

    #[test]
    fn exact_sarif_counts_only_new_tier_one_findings_in_risk() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            Vec::new(),
            vec![file("lib/app.rb", "def run\n  value\nend\n")],
        );
        let mut persisted = sarif_finding(2, 2, "persisted");
        persisted.tier_one = true;
        let mut introduced = sarif_finding(2, 2, "introduced");
        introduced.tier_one = true;
        let base = [SarifObservation {
            path: "lib/app.rb".into(),
            finding: persisted.clone(),
        }];
        apply_exact_sarif_findings(
            &mut plan,
            &[
                SarifObservation {
                    path: "lib/app.rb".into(),
                    finding: persisted,
                },
                SarifObservation {
                    path: "lib/app.rb".into(),
                    finding: introduced,
                },
            ],
            &base,
        );
        let file = &plan.files[0];
        assert_eq!(plan.evidence.sarif, EvidenceState::Exact);
        assert_eq!(file.risk.tier_one_hazards, 1);
        assert_eq!(file.risk.score, 8.0);
        assert_eq!(file.sarif_findings[0].status, "persisted");
        assert_eq!(file.sarif_findings[1].status, "new");
        assert_eq!(file.groups[0].risk.tier_one_hazards, 1);
    }

    #[test]
    fn exact_sarif_distinguishes_moved_and_resolved_findings() {
        let mut plan = build_diff_plan(
            "base",
            "head",
            vec![file("lib/old.rb", "def run\n  old\nend\n")],
            vec![file("lib/new.rb", "def run\n  new\nend\n")],
        );
        let moved = sarif_finding(2, 2, "moved");
        let resolved = sarif_finding(2, 2, "resolved");
        apply_exact_sarif_findings(
            &mut plan,
            &[SarifObservation {
                path: "lib/new.rb".into(),
                finding: moved.clone(),
            }],
            &[
                SarifObservation {
                    path: "lib/old.rb".into(),
                    finding: moved,
                },
                SarifObservation {
                    path: "lib/old.rb".into(),
                    finding: resolved,
                },
            ],
        );
        assert_eq!(plan.files[0].sarif_findings[0].status, "moved");
        assert_eq!(plan.resolved_sarif_findings.len(), 1);
        assert_eq!(plan.resolved_sarif_findings[0].finding.status, "resolved");
    }

    fn sarif_finding(start_line: u32, end_line: u32, message: &str) -> SarifFindingSummary {
        SarifFindingSummary {
            source: "scanner".into(),
            tool: "Scanner".into(),
            rule_id: "scanner.rule".into(),
            level: "warning".into(),
            category: "hazard".into(),
            message: message.into(),
            fingerprint: message.into(),
            tier: None,
            tier_one: false,
            status: "partial".into(),
            provenance: BTreeMap::new(),
            proof_boundary: Vec::new(),
            start_line,
            end_line,
        }
    }

    #[test]
    fn recognizes_catalog_entries_and_raw_file_fallbacks() {
        let overrides = ClassificationOverrides::default();
        assert_eq!(
            source_role_with_overrides("src/main.zig", &overrides),
            SourceRole::Production
        );
        assert_eq!(
            source_role_with_overrides("spec/model_spec.rb", &overrides),
            SourceRole::Test
        );
        assert_eq!(
            source_role_with_overrides("generated/api.ts", &overrides),
            SourceRole::Generated
        );
        assert_eq!(
            source_role_with_overrides("README.md", &overrides),
            SourceRole::Documentation
        );
        assert_eq!(
            source_role_with_overrides(".gitignore", &overrides),
            SourceRole::Configuration
        );
        assert_eq!(
            source_role_with_overrides("go.sum", &overrides),
            SourceRole::Lockfile
        );
        assert_eq!(
            source_role_with_overrides("image.avif", &overrides),
            SourceRole::Other
        );
        assert_eq!(config_kind("Library.gemspec"), Some("ruby_manifest"));
        assert_eq!(
            config_kind(".github/actions/setup/action.yml"),
            Some("github_action")
        );
        assert_eq!(
            config_kind("apps/web/tsconfig.build.json"),
            Some("javascript_manifest")
        );
        assert_eq!(
            config_kind("services/api/requirements-dev.txt"),
            Some("python_manifest")
        );
        assert_eq!(config_kind("native/toolchain.cmake"), Some("native_build"));
        assert_eq!(
            config_kind("src/Directory.Build.props"),
            Some("dotnet_manifest")
        );
        assert_eq!(config_kind("config/database.yml"), Some("ruby_manifest"));
        assert!(is_lockfile("src/gradle.lockfile"));
        assert!(is_generated("vendor/dependency.rb"));
        assert_eq!(config_kind("src/app.rs"), None);
    }

    #[test]
    fn repository_overrides_win_over_conventional_source_roles() {
        let overrides = classification_overrides(Some(
            r#"
                [[overrides]]
                prefix = "spec/"
                role = "production"

                [[overrides]]
                path = "lib/generated.rb"
                role = "test"

                [[overrides]]
                prefix = "../outside"
                role = "generated"
            "#,
        ));
        assert_eq!(
            source_role_with_overrides("spec/model_spec.rb", &overrides),
            SourceRole::Production
        );
        assert_eq!(
            source_role_with_overrides("lib/generated.rb", &overrides),
            SourceRole::Test
        );
        assert_eq!(
            source_role_with_overrides("lib/ordinary.rb", &overrides),
            SourceRole::Production
        );
        assert_eq!(
            source_role_with_overrides("outside/file.rb", &overrides),
            SourceRole::Production
        );
        assert_eq!(
            source_role_with_overrides(".giga/diff.toml", &overrides),
            SourceRole::Configuration
        );
    }
}
