//! Revision-pinned, render-independent change inventory for the diff UI.

use crate::extract::{BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, UnitKind};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use ts_rs::TS;

pub const DIFF_API_VERSION: &str = "v1";
pub const DIFF_POLICY_VERSION: &str = "diff-risk/v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionFile {
    pub path: String,
    pub contents: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct DiffScope {
    pub base_oid: String,
    pub head_oid: String,
    pub policy_version: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize, TS)]
pub struct DiffPlan {
    pub scope: DiffScope,
    pub inventory: ChangeInventory,
    pub dependency_changes: Vec<DependencyChange>,
    pub language_summaries: Vec<LanguageSummary>,
    pub evidence: EvidenceAvailability,
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
    pub base_source: Option<String>,
    pub head_source: Option<String>,
    pub added_lines: AddedLines,
    pub verification: VerificationSlices,
    pub residual_lines: AddedLines,
    pub groups: Vec<DiffGroup>,
    /// Commit-matching SARIF observations. They are intentionally kept out of
    /// risk scoring until their artifact scope can prove completeness.
    pub sarif_findings: Vec<SarifFindingSummary>,
    pub risk: RiskSummary,
    #[serde(skip)]
    #[ts(skip)]
    line_verification: BTreeMap<u32, LineVerification>,
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
pub struct MutationKillObservation {
    pub path: String,
    pub line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, TS)]
pub struct SarifFindingSummary {
    pub source: String,
    pub tool: String,
    pub rule_id: String,
    pub level: String,
    pub message: String,
    pub start_line: u32,
    pub end_line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SarifObservation {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LineVerification {
    CoveredAndKilled,
    Covered,
    PartiallyCovered,
    Unknown,
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
    let base = file_map(base_files);
    let head = file_map(head_files);
    let renamed = renamed_paths(&base, &head);
    let mut files = changed_paths(&base, &head)
        .into_iter()
        .filter_map(|path| plan_file(&path, &base, &head, &renamed))
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
            base_oid: base_oid.into(),
            head_oid: head_oid.into(),
            policy_version: DIFF_POLICY_VERSION,
        },
        inventory,
        dependency_changes,
        language_summaries,
        evidence: unavailable_evidence(),
        files,
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
) -> Option<DiffFile> {
    let base_file = base.get(path);
    let head_file = head.get(path);
    if base_file == head_file || is_renamed_source(path, renamed) {
        return None;
    }
    let previous_path = previous_path(path, renamed);
    let change = change_kind(base_file, head_file, previous_path.as_ref());
    let base_source = base_file.and_then(|file| file.contents.clone());
    let head_source = head_file.and_then(|file| file.contents.clone());
    let added_line_numbers = added_line_numbers(base_source.as_deref(), head_source.as_deref());
    let added_lines = summarize_added_lines(head_source.as_deref(), &added_line_numbers, path);
    let groups = semantic_groups(
        path,
        base_source.as_deref(),
        head_source.as_deref(),
        &added_line_numbers,
    );
    let verification = unavailable_verification(&added_lines);
    let line_verification =
        unknown_line_verification(head_source.as_deref(), &added_line_numbers, path);
    let mut file = DiffFile {
        path: path.to_string(),
        previous_path,
        change,
        role: source_role(path),
        language: language_for_path(path),
        residual_lines: residual_lines(head_source.as_deref(), &added_line_numbers, path, &groups),
        risk: risk_summary(head_source.as_deref(), &added_line_numbers, &verification),
        verification,
        groups,
        sarif_findings: Vec::new(),
        base_source,
        head_source,
        added_lines,
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

fn spans_overlap(left_start: u32, left_end: u32, right_start: u32, right_end: u32) -> bool {
    left_start <= right_end && right_start <= left_end
}

fn code_line_numbers(source: Option<&str>, added: &BTreeSet<u32>, path: &str) -> BTreeSet<u32> {
    source
        .unwrap_or_default()
        .lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let line_number = index as u32 + 1;
            (added.contains(&line_number) && matches!(line_kind(line, path), LineKind::Code))
                .then_some(line_number)
        })
        .collect()
}

fn unknown_line_verification(
    source: Option<&str>,
    added: &BTreeSet<u32>,
    path: &str,
) -> BTreeMap<u32, LineVerification> {
    code_line_numbers(source, added, path)
        .into_iter()
        .map(|line| (line, LineVerification::Unknown))
        .collect()
}

fn refresh_file_verification(file: &mut DiffFile) {
    file.verification = verification_slices(file.line_verification.values().copied());
    let added = added_line_numbers(file.base_source.as_deref(), file.head_source.as_deref());
    file.risk = risk_summary(file.head_source.as_deref(), &added, &file.verification);
    for group in &mut file.groups {
        let lines = file
            .line_verification
            .range(group.start_line..=group.end_line)
            .map(|(_, state)| *state);
        group.verification = verification_slices(lines);
        let group_added = group_added_line_numbers(&added, group.start_line, group.end_line);
        group.risk = risk_summary(
            file.head_source.as_deref(),
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
            LineVerification::Unknown => slices.unknown += 1,
        }
    }
    slices
}

fn risk_summary(
    source: Option<&str>,
    added: &BTreeSet<u32>,
    verification: &VerificationSlices,
) -> RiskSummary {
    let added_complexity = source
        .unwrap_or_default()
        .lines()
        .enumerate()
        .filter(|(index, line)| added.contains(&(*index as u32 + 1)) && is_decision_line(line))
        .count();
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

fn is_decision_line(line: &str) -> bool {
    let line = line.trim();
    [
        "if ", "unless ", "while ", "for ", "case ", "match ", " rescue ", "&&", "||",
    ]
    .iter()
    .any(|token| line.starts_with(token) || line.contains(token))
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

fn summarize_added_lines(source: Option<&str>, added: &BTreeSet<u32>, path: &str) -> AddedLines {
    let mut summary = AddedLines::default();
    for (index, line) in source.unwrap_or_default().lines().enumerate() {
        if !added.contains(&(index as u32 + 1)) {
            continue;
        }
        match line_kind(line, path) {
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
                summarize_group_lines(source, added, path, unit.start_line, unit.end_line);
            let base_unit = base_units
                .as_ref()
                .and_then(|units| matching_base_unit(units, &unit));
            include_semantic_group(&unit, base_unit, &added_lines).then(|| {
                let verification = unavailable_verification(&added_lines);
                let group_added = group_added_line_numbers(added, unit.start_line, unit.end_line);
                let visibility = visibility_for(path, source, &unit);
                let risk = risk_summary(Some(source), &group_added, &verification);
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
    source: &str,
    added: &BTreeSet<u32>,
    path: &str,
    start: u32,
    end: u32,
) -> AddedLines {
    let lines = group_added_line_numbers(added, start, end);
    summarize_added_lines(Some(source), &lines, path)
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
    source: Option<&str>,
    added: &BTreeSet<u32>,
    path: &str,
    groups: &[DiffGroup],
) -> AddedLines {
    let assigned = groups
        .iter()
        .flat_map(|group| group.start_line..=group.end_line)
        .collect();
    let residual = added.difference(&assigned).copied().collect();
    summarize_added_lines(source, &residual, path)
}

enum LineKind {
    Code,
    Comment,
    Other,
}

fn line_kind(line: &str, path: &str) -> LineKind {
    let line = line.trim();
    if line.is_empty() || line == "end" || matches!(line, "{" | "}" | "};" | "{}") {
        return LineKind::Other;
    }
    if line.starts_with('#')
        || line.starts_with("//")
        || line.starts_with("/*")
        || line.starts_with('*')
        || line.starts_with("<!--")
    {
        return LineKind::Comment;
    }
    if path.ends_with(".rb") && line == "=begin" {
        return LineKind::Comment;
    }
    LineKind::Code
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
    match file.path.as_str() {
        "package.json" | _ if file.path.ends_with("/package.json") => {
            Some(package_json_dependencies(file))
        }
        "Cargo.toml" | _ if file.path.ends_with("/Cargo.toml") => {
            Some(cargo_toml_dependencies(file))
        }
        path if is_manifest_path(path) => Some(DependencyChange {
            manifest_path: file.path.clone(),
            status: DependencyStatus::UnknownPackageFile,
            entries: Vec::new(),
        }),
        _ => None,
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

fn source_role(path: &str) -> SourceRole {
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

fn is_test_path(path: &str) -> bool {
    path.contains("/test/")
        || path.contains("/spec/")
        || path.starts_with("test/")
        || path.starts_with("spec/")
        || path.ends_with("_test.rb")
        || path.ends_with("_spec.rb")
        || path.ends_with("_test.go")
        || path.ends_with(".test.ts")
        || path.ends_with(".test.tsx")
        || path.ends_with(".spec.ts")
        || path.ends_with(".spec.tsx")
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
                "gems/lineage/Cargo.toml",
                "[dependencies]\nserde = \"1\"\n[dev-dependencies]\ntempfile = \"3\"\n",
            )],
            vec![file(
                "gems/lineage/Cargo.toml",
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
    fn excludes_closure_only_lines_across_brace_languages() {
        for (path, line) in [("main.zig", "}"), ("main.go", "}"), ("main.rs", "};")] {
            assert!(matches!(line_kind(line, path), LineKind::Other));
        }
        assert!(matches!(
            line_kind("// intent", "main.go"),
            LineKind::Comment
        ));
        assert!(matches!(
            line_kind("return value", "main.go"),
            LineKind::Code
        ));
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

    fn sarif_finding(start_line: u32, end_line: u32, message: &str) -> SarifFindingSummary {
        SarifFindingSummary {
            source: "scanner".into(),
            tool: "Scanner".into(),
            rule_id: "scanner.rule".into(),
            level: "warning".into(),
            message: message.into(),
            start_line,
            end_line,
        }
    }

    #[test]
    fn recognizes_catalog_entries_and_raw_file_fallbacks() {
        assert_eq!(source_role("src/main.zig"), SourceRole::Production);
        assert_eq!(source_role("spec/model_spec.rb"), SourceRole::Test);
        assert_eq!(source_role("generated/api.ts"), SourceRole::Generated);
        assert_eq!(source_role("README.md"), SourceRole::Documentation);
        assert_eq!(source_role(".gitignore"), SourceRole::Configuration);
        assert_eq!(source_role("go.sum"), SourceRole::Lockfile);
        assert_eq!(source_role("image.avif"), SourceRole::Other);
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
}
