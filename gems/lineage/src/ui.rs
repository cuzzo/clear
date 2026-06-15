use crate::git::GitProvider;
use crate::model::BlobFile;
use crate::storage::Storage;
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use rusqlite::params;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverageScope {
    include_prefixes: Vec<String>,
    ignore_patterns: Vec<String>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct LineCoverageStats {
    tracked: i64,
    covered: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiFile {
    pub path: String,
    pub units: i64,
    pub hazards: i64,
    pub evidence_covered_hazards: i64,
    pub covered_hazards: i64,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
    pub tracked_lines: i64,
    pub covered_lines: i64,
    pub line_coverage: f64,
    pub mutant_coverage: f64,
    pub mutant_killed_covered_lines: i64,
    pub stochastic_mutant_killed_covered_lines: i64,
    pub invariant_mutant_killed_covered_lines: i64,
    pub multi_type_covered_lines: i64,
    #[serde(skip)]
    pub read_model: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiDirectory {
    pub path: String,
    pub files: i64,
    pub units: i64,
    pub hazards: i64,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
    pub tracked_lines: i64,
    pub covered_lines: i64,
    pub line_coverage: f64,
    pub mutant_coverage: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiVersion {
    pub commit_hash: String,
    pub timestamp: i64,
    pub event_type: String,
    pub path: String,
    pub name: String,
    pub start_line: u32,
    pub end_line: u32,
    pub semantic_change: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiHazard {
    pub hazard_type: String,
    pub required_evidence: String,
    pub source: String,
    pub evidence_present: bool,
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiWarning {
    pub level: String,
    pub label: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiDarkArm {
    pub label: String,
    pub span: Option<[u32; 4]>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiBugEvent {
    pub event_type: String,
    pub commit_hash: String,
    pub timestamp: i64,
    pub path: String,
    pub line: u32,
    pub label: String,
    pub weight: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiLineAnnotation {
    pub line: u32,
    pub covered: bool,
    pub mutant_tested: bool,
    pub test_types: Vec<String>,
    pub distinct_tests: i64,
    pub mutant_verified_tests: i64,
    pub mutant_killed_tests: i64,
    pub line_hits: Option<u32>,
    pub line_coverage: Option<f64>,
    pub mutant_coverage: Option<f64>,
    pub dark_arms: Vec<String>,
    pub dark_arm_spans: Vec<UiDarkArm>,
    pub hazards: Vec<UiHazard>,
    pub semantic_churn: f64,
    pub semantic_churn_events: i64,
    pub bug_weight: f64,
    pub bug_events: Vec<UiBugEvent>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiSourcePayload {
    pub path: String,
    pub commit: Option<String>,
    pub lines: Vec<String>,
    pub versions: Vec<UiVersion>,
    pub annotations: Vec<UiLineAnnotation>,
    pub warnings: Vec<UiWarning>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiDashboard {
    pub files: usize,
    pub tracked_lines: i64,
    pub covered_lines: i64,
    pub coverage_percent: f64,
    pub active_hazards: i64,
    pub evidence_covered_hazards: i64,
    pub hazard_evidence_percent: f64,
    pub covered_hazards: i64,
    pub hazard_coverage_percent: f64,
    pub mutant_killed_covered_lines: i64,
    pub mutant_killed_covered_percent: f64,
    pub stochastic_mutant_killed_covered_lines: i64,
    pub stochastic_mutant_killed_covered_percent: f64,
    pub invariant_mutant_killed_covered_lines: i64,
    pub invariant_mutant_killed_covered_percent: f64,
    pub multi_type_covered_lines: i64,
    pub multi_type_covered_percent: f64,
    pub files_with_coverage: i64,
    pub top_hazard_files: Vec<UiFile>,
    pub warnings: Vec<UiWarning>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct DashboardLineCounts {
    tracked: i64,
    covered: i64,
    mutant_killed: i64,
    stochastic_mutant_killed: i64,
    invariant_mutant_killed: i64,
    multi_type: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WarningUnit {
    current_path: String,
    current_distinct_tests: i64,
    current_mutant_verified_tests: i64,
    last_test_exposure_at: i64,
    last_mutant_run_at: i64,
    changes_after_test_exposure: i64,
    semantic_changes_after_mutant_run: i64,
    verification_stale_seconds: i64,
    reopened_count: i64,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct UiOverlays {
    dark_arms: HashMap<String, BTreeMap<u32, Vec<UiDarkArm>>>,
}

#[derive(Default)]
struct AnnotationBuilder {
    covered: bool,
    mutant_tested: bool,
    test_types: BTreeSet<String>,
    distinct_tests: i64,
    mutant_verified_tests: i64,
    mutant_killed_tests: i64,
    line_hits: Option<u32>,
    line_coverage: Option<f64>,
    mutant_coverage: Option<f64>,
    dark_arms: Vec<String>,
    dark_arm_spans: Vec<UiDarkArm>,
    hazards: Vec<UiHazard>,
    semantic_churn: f64,
    semantic_churn_events: i64,
    bug_weight: f64,
    bug_events: Vec<UiBugEvent>,
}

const MIN_HISTORY_WEIGHT: f64 = 0.001;

pub fn serve_ui(db: impl AsRef<Path>, repo: impl AsRef<Path>, host: &str, port: u16) -> Result<()> {
    serve_ui_with_overlays(db, repo, host, port, &[])
}

pub fn serve_ui_with_overlays(
    db: impl AsRef<Path>,
    repo: impl AsRef<Path>,
    host: &str,
    port: u16,
    overlay_paths: &[PathBuf],
) -> Result<()> {
    let db = db.as_ref().to_path_buf();
    let repo = repo.as_ref().to_path_buf();
    Storage::open(&db)?;
    let overlays = UiOverlays::load(overlay_paths)?;
    let addr = format!("{host}:{port}");
    let listener = TcpListener::bind(&addr).with_context(|| format!("bind {addr}"))?;
    println!("Lineage UI listening on http://{addr}");
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle_stream(stream, &db, &repo, &overlays) {
                    eprintln!("lineage ui request failed: {error:#}");
                }
            }
            Err(error) => eprintln!("lineage ui connection failed: {error}"),
        }
    }
    Ok(())
}

pub fn file_index(storage: &Storage) -> Result<Vec<UiFile>> {
    file_index_with_scope(storage, &CoverageScope::all())
}

pub fn file_index_with_scope(storage: &Storage, scope: &CoverageScope) -> Result<Vec<UiFile>> {
    let total_start = Instant::now();
    if let Some(files) = read_model_file_index_with_scope(storage, scope)? {
        profile_log("file_index.read_model_total", total_start);
        return Ok(files);
    }
    let line_start = Instant::now();
    let line_stats = line_coverage_by_file(storage, scope)?;
    profile_log("file_index.line_coverage_by_file", line_start);
    let query_start = Instant::now();
    let mut stmt = storage.connection().prepare(
        r#"
        WITH current_units AS (
          SELECT
            u.id,
          COALESCE((
            SELECT latest.path
            FROM events latest
            WHERE latest.unit_id = u.id
              ORDER BY latest.timestamp DESC, latest.id DESC
              LIMIT 1
            ), u.original_path) AS current_path,
            u.current_line_cov,
            u.current_mutant_cov,
            u.current_distinct_tests,
            u.current_mutant_killed_tests
          FROM logical_units u
        ),
        hazard_counts AS (
          SELECT unit_id, COUNT(*) AS hazards
          FROM unit_hazards
          WHERE is_active = 1
          GROUP BY unit_id
        )
        SELECT
          cu.current_path,
          COUNT(DISTINCT cu.id) AS units,
          COALESCE(SUM(hc.hazards), 0) AS hazards,
          COALESCE(SUM(cu.current_distinct_tests), 0) AS distinct_tests,
          COALESCE(SUM(cu.current_mutant_killed_tests), 0) AS mutant_killed_tests,
          COALESCE(AVG(cu.current_line_cov), 0.0) AS line_coverage,
          COALESCE(AVG(cu.current_mutant_cov), 0.0) AS mutant_coverage
        FROM current_units cu
        LEFT JOIN hazard_counts hc ON hc.unit_id = cu.id
        WHERE cu.current_path <> ''
        GROUP BY cu.current_path
        ORDER BY hazards DESC, mutant_killed_tests DESC, distinct_tests DESC, cu.current_path
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let path = row.get::<_, String>(0)?;
        let fallback_line_coverage = row.get::<_, f64>(5)?;
        let stats = line_stats.get(&path).copied().unwrap_or_default();
        Ok(UiFile {
            path,
            units: row.get(1)?,
            hazards: row.get(2)?,
            evidence_covered_hazards: 0,
            covered_hazards: 0,
            distinct_tests: row.get(3)?,
            mutant_killed_tests: row.get(4)?,
            tracked_lines: stats.tracked,
            covered_lines: stats.covered,
            line_coverage: if stats.tracked > 0 {
                percent(stats.covered, stats.tracked)
            } else {
                fallback_line_coverage
            },
            mutant_coverage: row.get(6)?,
            mutant_killed_covered_lines: 0,
            stochastic_mutant_killed_covered_lines: 0,
            invariant_mutant_killed_covered_lines: 0,
            multi_type_covered_lines: 0,
            read_model: false,
        })
    })?;
    let files = rows
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|file| scope.allows(&file.path))
        .collect();
    profile_log("file_index.current_units", query_start);
    profile_log("file_index.total", total_start);
    Ok(files)
}

fn read_model_file_index_with_scope(
    storage: &Storage,
    scope: &CoverageScope,
) -> Result<Option<Vec<UiFile>>> {
    let start = Instant::now();
    if storage.count_rows("ui_file_summaries")? == 0 {
        return Ok(None);
    }
    let mut stmt = storage.connection().prepare(
        r#"
        SELECT path,
               units,
               hazards,
               evidence_covered_hazards,
               covered_hazards,
               distinct_tests,
               mutant_killed_tests,
               tracked_lines,
               covered_lines,
               line_coverage,
               mutant_coverage,
               mutant_killed_covered_lines,
               stochastic_mutant_killed_covered_lines,
               invariant_mutant_killed_covered_lines,
               multi_type_covered_lines
        FROM ui_file_summaries
        ORDER BY hazards DESC, mutant_killed_tests DESC, distinct_tests DESC, path
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(UiFile {
            path: row.get(0)?,
            units: row.get(1)?,
            hazards: row.get(2)?,
            evidence_covered_hazards: row.get(3)?,
            covered_hazards: row.get(4)?,
            distinct_tests: row.get(5)?,
            mutant_killed_tests: row.get(6)?,
            tracked_lines: row.get(7)?,
            covered_lines: row.get(8)?,
            line_coverage: row.get(9)?,
            mutant_coverage: row.get(10)?,
            mutant_killed_covered_lines: row.get(11)?,
            stochastic_mutant_killed_covered_lines: row.get(12)?,
            invariant_mutant_killed_covered_lines: row.get(13)?,
            multi_type_covered_lines: row.get(14)?,
            read_model: true,
        })
    })?;
    let files = rows
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|file| scope.allows(&file.path))
        .collect();
    profile_log("file_index.read_model_query", start);
    Ok(Some(files))
}

impl CoverageScope {
    pub fn all() -> Self {
        Self {
            include_prefixes: Vec::new(),
            ignore_patterns: Vec::new(),
        }
    }

    pub fn from_repo(repo: &Path) -> Self {
        let path = repo.join("codecov.yml");
        let Ok(text) = fs::read_to_string(path) else {
            return Self::all();
        };
        let mut scope = Self::all();
        let mut section: Option<&str> = None;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if !line.starts_with(' ') && trimmed.ends_with(':') {
                section = Some(trimmed.trim_end_matches(':'));
                continue;
            }
            if trimmed == "paths:" {
                section = Some("paths");
                continue;
            }
            let Some(value) = yaml_list_value(trimmed) else {
                continue;
            };
            match section {
                Some("ignore") => scope.ignore_patterns.push(value),
                Some("paths") => scope.include_prefixes.push(normalize_directory(&value)),
                _ => {}
            }
        }
        scope.include_prefixes.retain(|value| !value.is_empty());
        scope.include_prefixes.sort();
        scope.include_prefixes.dedup();
        scope.ignore_patterns.sort();
        scope.ignore_patterns.dedup();
        scope
    }

    pub fn allows(&self, path: &str) -> bool {
        let path = normalize_source_path(path);
        let included = self.include_prefixes.is_empty()
            || self
                .include_prefixes
                .iter()
                .any(|prefix| path == *prefix || path.starts_with(&format!("{prefix}/")));
        included && !self.ignore_patterns.iter().any(|pattern| ignore_matches(pattern, &path))
    }
}

fn yaml_list_value(trimmed: &str) -> Option<String> {
    let value = trimmed.strip_prefix("- ")?;
    Some(value.trim().trim_matches('"').trim_matches('\'').to_string())
}

fn ignore_matches(pattern: &str, path: &str) -> bool {
    let pattern = pattern.trim().trim_matches('"').trim_matches('\'').trim_start_matches("./");
    if pattern.is_empty() {
        return false;
    }
    if pattern.ends_with('/') {
        let prefix = pattern.trim_end_matches('/');
        return path == prefix || path.starts_with(&format!("{prefix}/"));
    }
    wildcard_match(pattern, path)
        || path
            .rsplit_once('/')
            .map(|(_, basename)| wildcard_match(pattern, basename))
            .unwrap_or(false)
}

fn wildcard_match(pattern: &str, text: &str) -> bool {
    let pattern = pattern.as_bytes();
    let text = text.as_bytes();
    let (mut pi, mut ti) = (0, 0);
    let mut star = None;
    let mut star_text = 0;
    while ti < text.len() {
        if pi < pattern.len() && (pattern[pi] == text[ti] || pattern[pi] == b'?') {
            pi += 1;
            ti += 1;
        } else if pi < pattern.len() && pattern[pi] == b'*' {
            star = Some(pi);
            pi += 1;
            star_text = ti;
        } else if let Some(star_index) = star {
            pi = star_index + 1;
            star_text += 1;
            ti = star_text;
        } else {
            return false;
        }
    }
    while pi < pattern.len() && pattern[pi] == b'*' {
        pi += 1;
    }
    pi == pattern.len()
}

fn line_coverage_by_file(
    storage: &Storage,
    scope: &CoverageScope,
) -> Result<HashMap<String, LineCoverageStats>> {
    let mut by_file = HashMap::<String, LineCoverageStats>::new();
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_source_lines AS (
          SELECT path, line, hits
          FROM (
            SELECT path, line, source, hits,
                   ROW_NUMBER() OVER (
                     PARTITION BY path, line, source
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM coverage_line_events
          )
          WHERE rank = 1
        ),
        latest_lines AS (
          SELECT path, line, MAX(hits) AS hits
          FROM latest_source_lines
          GROUP BY path, line
        )
        SELECT path, hits
        FROM latest_lines
        ORDER BY path
        "#,
    )?;
    let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?)))?;
    for row in rows {
        let (path, hits) = row?;
        if !scope.allows(&path) {
            continue;
        }
        let entry = by_file.entry(path).or_default();
        entry.tracked += 1;
        if hits > 0 {
            entry.covered += 1;
        }
    }
    Ok(by_file)
}

pub fn dashboard_summary(storage: &Storage) -> Result<UiDashboard> {
    dashboard_summary_for_directory_with_scope(storage, "", &CoverageScope::all())
}

pub fn dashboard_summary_for_directory(storage: &Storage, directory: &str) -> Result<UiDashboard> {
    dashboard_summary_for_directory_with_scope(storage, directory, &CoverageScope::all())
}

pub fn dashboard_summary_for_directory_with_scope(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<UiDashboard> {
    let total_start = Instant::now();
    let directory = normalize_directory(directory);
    let files_start = Instant::now();
    let files = file_index_with_scope(storage, scope)?;
    let uses_read_model = files.iter().any(|file| file.read_model);
    profile_log("dashboard.file_index", files_start);
    let mut top_hazard_files = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory) && file.hazards > 0)
        .cloned()
        .collect::<Vec<_>>();
    top_hazard_files.sort_by(|left, right| {
        right
            .hazards
            .cmp(&left.hazards)
            .then_with(|| left.path.cmp(&right.path))
    });
    top_hazard_files.truncate(8);

    let line_start = Instant::now();
    let line_counts = if uses_read_model {
        dashboard_line_counts_from_files(&files, &directory)
    } else {
        let mut line_counts = dashboard_line_counts(storage, &directory, scope)?;
        for file in files.iter().filter(|file| path_in_directory(&file.path, &directory)) {
            line_counts.tracked += file.tracked_lines;
            line_counts.covered += file.covered_lines;
        }
        if line_counts.tracked == 0 {
            let fallback = dashboard_coverage_line_counts(storage, &directory, scope)?;
            line_counts.tracked = fallback.tracked;
            line_counts.covered = fallback.covered;
        }
        line_counts
    };
    profile_log("dashboard.line_counts", line_start);
    let hazard_start = Instant::now();
    let (active_hazards, evidence_covered_hazards, covered_hazards) = if uses_read_model {
        dashboard_hazard_counts_from_files(&files, &directory)
    } else {
        dashboard_hazard_counts(storage, &directory, scope)?
    };
    profile_log("dashboard.hazard_counts", hazard_start);
    let warning_start = Instant::now();
    let warnings = warnings_for_directory(storage, &directory, scope)?;
    profile_log("dashboard.warnings", warning_start);

    let files_with_coverage = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory) && file.line_coverage > 0.0)
        .count() as i64;
    let files_count = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory))
        .count();

    let dashboard = UiDashboard {
        files: files_count,
        tracked_lines: line_counts.tracked,
        covered_lines: line_counts.covered,
        coverage_percent: percent(line_counts.covered, line_counts.tracked),
        active_hazards,
        evidence_covered_hazards,
        hazard_evidence_percent: percent(evidence_covered_hazards, active_hazards),
        covered_hazards,
        hazard_coverage_percent: percent(covered_hazards, active_hazards),
        mutant_killed_covered_lines: line_counts.mutant_killed,
        mutant_killed_covered_percent: percent(line_counts.mutant_killed, line_counts.covered),
        stochastic_mutant_killed_covered_lines: line_counts.stochastic_mutant_killed,
        stochastic_mutant_killed_covered_percent: percent(
            line_counts.stochastic_mutant_killed,
            line_counts.covered,
        ),
        invariant_mutant_killed_covered_lines: line_counts.invariant_mutant_killed,
        invariant_mutant_killed_covered_percent: percent(
            line_counts.invariant_mutant_killed,
            line_counts.covered,
        ),
        multi_type_covered_lines: line_counts.multi_type,
        multi_type_covered_percent: percent(line_counts.multi_type, line_counts.covered),
        files_with_coverage,
        top_hazard_files,
        warnings,
    };
    profile_log("dashboard.total", total_start);
    Ok(dashboard)
}

fn warnings_for_directory(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<Vec<UiWarning>> {
    let units = warning_units(storage)?
        .into_iter()
        .filter(|unit| scope.allows(&unit.current_path) && path_in_directory(&unit.current_path, directory))
        .collect::<Vec<_>>();
    Ok(warnings_for_units(&units))
}

fn warnings_for_path(storage: &Storage, path: &str) -> Result<Vec<UiWarning>> {
    let units = warning_units(storage)?
        .into_iter()
        .filter(|unit| unit.current_path == path)
        .collect::<Vec<_>>();
    Ok(warnings_for_units(&units))
}

fn warning_units(storage: &Storage) -> Result<Vec<WarningUnit>> {
    let start = Instant::now();
    if storage.count_rows("ui_warning_units")? > 0 {
        let mut stmt = storage.connection().prepare(
            r#"
            SELECT current_path,
                   current_distinct_tests,
                   current_mutant_verified_tests,
                   last_test_exposure_at,
                   last_mutant_run_at,
                   changes_after_test_exposure,
                   semantic_changes_after_mutant_run,
                   verification_stale_seconds,
                   reopened_count
            FROM ui_warning_units
            "#,
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(WarningUnit {
                current_path: row.get(0)?,
                current_distinct_tests: row.get(1)?,
                current_mutant_verified_tests: row.get(2)?,
                last_test_exposure_at: row.get(3)?,
                last_mutant_run_at: row.get(4)?,
                changes_after_test_exposure: row.get(5)?,
                semantic_changes_after_mutant_run: row.get(6)?,
                verification_stale_seconds: row.get(7)?,
                reopened_count: row.get(8)?,
            })
        })?;
        let units = rows.collect::<std::result::Result<Vec<_>, _>>()?;
        profile_log("warnings.read_model_query", start);
        return Ok(units);
    }
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_events AS (
          SELECT unit_id, path
          FROM (
            SELECT unit_id, path,
                   ROW_NUMBER() OVER (
                     PARTITION BY unit_id
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM events
          )
          WHERE rank = 1
        ),
        current_units AS (
          SELECT u.id,
                 COALESCE(le.path, u.original_path) AS current_path,
                 u.current_distinct_tests,
                 u.current_mutant_verified_tests,
                 u.last_test_exposure_at
          FROM logical_units u
          LEFT JOIN latest_events le ON le.unit_id = u.id
        ),
        db_clock AS (
          SELECT COALESCE(MAX(timestamp), 0) AS observed_at
          FROM (
            SELECT timestamp FROM metadata
            UNION ALL SELECT timestamp FROM events
            UNION ALL SELECT timestamp FROM quality_events
            UNION ALL SELECT timestamp FROM crash_events
            UNION ALL SELECT timestamp FROM test_exposure_events
          )
        ),
        mutant_runs AS (
          SELECT unit_id, MAX(timestamp) AS last_mutant_run_at
          FROM test_exposure_events
          WHERE is_mutation_verified = 1 OR is_mutation_killed = 1
          GROUP BY unit_id
        ),
        event_counts AS (
          SELECT cu.id,
                 SUM(CASE
                   WHEN cu.last_test_exposure_at > 0
                    AND e.semantic_change = 1
                    AND e.event_type IN ('FIX', 'CHANGE')
                    AND e.timestamp > cu.last_test_exposure_at
                   THEN 1 ELSE 0
                 END) AS changes_after_test_exposure,
                 SUM(CASE
                   WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                    AND e.semantic_change = 1
                    AND e.event_type IN ('FIX', 'CHANGE')
                    AND e.timestamp > m.last_mutant_run_at
                   THEN 1 ELSE 0
                 END) AS semantic_changes_after_mutant_run
          FROM current_units cu
          LEFT JOIN mutant_runs m ON m.unit_id = cu.id
          LEFT JOIN events e ON e.unit_id = cu.id
          GROUP BY cu.id
        ),
        reopened AS (
          SELECT c.unit_id, COUNT(DISTINCT c.id) AS reopened_count
          FROM crash_events c
          WHERE EXISTS (
            SELECT 1
            FROM events fix
            WHERE fix.unit_id = c.unit_id
              AND fix.event_type = 'FIX'
              AND fix.semantic_change = 1
              AND fix.path = c.path
              AND c.line BETWEEN fix.start_line AND fix.end_line
              AND c.timestamp > fix.timestamp
          )
          GROUP BY c.unit_id
        )
        SELECT cu.current_path,
               cu.current_distinct_tests,
               cu.current_mutant_verified_tests,
               cu.last_test_exposure_at,
               COALESCE(m.last_mutant_run_at, 0) AS last_mutant_run_at,
               COALESCE(ec.changes_after_test_exposure, 0) AS changes_after_test_exposure,
               COALESCE(ec.semantic_changes_after_mutant_run, 0) AS semantic_changes_after_mutant_run,
               CASE
                 WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                  AND clock.observed_at > m.last_mutant_run_at
                 THEN clock.observed_at - m.last_mutant_run_at
                 ELSE 0
               END AS verification_stale_seconds,
               COALESCE(r.reopened_count, 0) AS reopened_count
        FROM current_units cu
        LEFT JOIN mutant_runs m ON m.unit_id = cu.id
        LEFT JOIN event_counts ec ON ec.id = cu.id
        LEFT JOIN reopened r ON r.unit_id = cu.id
        CROSS JOIN db_clock clock
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(WarningUnit {
            current_path: row.get(0)?,
            current_distinct_tests: row.get(1)?,
            current_mutant_verified_tests: row.get(2)?,
            last_test_exposure_at: row.get(3)?,
            last_mutant_run_at: row.get(4)?,
            changes_after_test_exposure: row.get(5)?,
            semantic_changes_after_mutant_run: row.get(6)?,
            verification_stale_seconds: row.get(7)?,
            reopened_count: row.get(8)?,
        })
    })?;
    let units = rows.collect::<std::result::Result<Vec<_>, _>>()?;
    profile_log("warnings.units_query", start);
    Ok(units)
}

fn warnings_for_units(units: &[WarningUnit]) -> Vec<UiWarning> {
    let coverage_stale = units
        .iter()
        .filter(|unit| {
            unit.last_test_exposure_at > 0 && unit.changes_after_test_exposure > 0
        })
        .collect::<Vec<_>>();
    let mutant_stale = units
        .iter()
        .filter(|unit| {
            unit.last_mutant_run_at > 0 && unit.semantic_changes_after_mutant_run > 0
        })
        .collect::<Vec<_>>();
    let missing_mutant = units
        .iter()
        .filter(|unit| unit.current_distinct_tests > 0 && unit.current_mutant_verified_tests == 0)
        .count();
    let reopened = units
        .iter()
        .filter(|unit| unit.reopened_count > 0)
        .collect::<Vec<_>>();

    let mut warnings = Vec::new();
    if !coverage_stale.is_empty() {
        let changes = coverage_stale
            .iter()
            .map(|unit| unit.changes_after_test_exposure)
            .sum::<i64>();
        warnings.push(UiWarning {
            level: "caution".to_string(),
            label: "Coverage data is stale".to_string(),
            detail: format!(
                "{} units changed after their latest test exposure; {} semantic changes need re-verification.",
                coverage_stale.len(),
                changes
            ),
        });
    }
    if !mutant_stale.is_empty() {
        let changes = mutant_stale
            .iter()
            .map(|unit| unit.semantic_changes_after_mutant_run)
            .sum::<i64>();
        let max_stale_days = mutant_stale
            .iter()
            .map(|unit| unit.verification_stale_seconds as f64 / 86_400.0)
            .fold(0.0, f64::max);
        warnings.push(UiWarning {
            level: "caution".to_string(),
            label: "Mutation verification is stale".to_string(),
            detail: format!(
                "{} units changed after their latest mutant run; max stale age {}; {} semantic changes need mutant re-run.",
                mutant_stale.len(),
                format_days(max_stale_days),
                changes
            ),
        });
    }
    if missing_mutant > 0 {
        warnings.push(UiWarning {
            level: "notice".to_string(),
            label: "Mutation verification is missing".to_string(),
            detail: format!("{missing_mutant} covered units have no mutant-verified test exposure."),
        });
    }
    if !reopened.is_empty() {
        let reopened_count = reopened.iter().map(|unit| unit.reopened_count).sum::<i64>();
        warnings.push(UiWarning {
            level: "caution".to_string(),
            label: "Fixes have reopened crashes".to_string(),
            detail: format!(
                "{} units have crash frames after a prior fix in the same unit span; {} reopened crash frames total.",
                reopened.len(),
                reopened_count
            ),
        });
    }
    warnings
}

fn dashboard_line_counts_from_files(files: &[UiFile], directory: &str) -> DashboardLineCounts {
    let mut counts = DashboardLineCounts::default();
    for file in files.iter().filter(|file| path_in_directory(&file.path, directory)) {
        counts.tracked += file.tracked_lines;
        counts.covered += file.covered_lines;
        counts.mutant_killed += file.mutant_killed_covered_lines;
        counts.stochastic_mutant_killed += file.stochastic_mutant_killed_covered_lines;
        counts.invariant_mutant_killed += file.invariant_mutant_killed_covered_lines;
        counts.multi_type += file.multi_type_covered_lines;
    }
    counts
}

fn dashboard_hazard_counts_from_files(files: &[UiFile], directory: &str) -> (i64, i64, i64) {
    files
        .iter()
        .filter(|file| path_in_directory(&file.path, directory))
        .fold((0, 0, 0), |(active, evidence, verified), file| {
            (
                active + file.hazards,
                evidence + file.evidence_covered_hazards,
                verified + file.covered_hazards,
            )
        })
}

fn dashboard_line_counts(
    storage: &Storage,
    _directory: &str,
    _scope: &CoverageScope,
) -> Result<DashboardLineCounts> {
    let total_start = Instant::now();
    let mut counts = DashboardLineCounts::default();
    let exposure_start = Instant::now();
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_source_lines AS (
          SELECT path, line, hits
          FROM (
            SELECT path, line, source, hits,
                   ROW_NUMBER() OVER (
                     PARTITION BY path, line, source
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM coverage_line_events
          )
          WHERE rank = 1
        ),
        latest_lines AS (
          SELECT path, line, MAX(hits) AS hits
          FROM latest_source_lines
          GROUP BY path, line
        ),
        ranked_exposure AS (
          SELECT path, line, branch_id, test_id, test_type, is_verified,
                 is_mutation_killed, mutation_kind,
                 ROW_NUMBER() OVER (
                   PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM test_exposure_events
          WHERE line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        )
        SELECT path,
               line,
               COUNT(DISTINCT CASE WHEN is_verified = 1 THEN test_type END) AS verified_test_types,
               MAX(CASE WHEN is_verified = 1 AND is_mutation_killed = 1 THEN 1 ELSE 0 END) AS mutant_killed,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_killed = 1
                  AND lower(COALESCE(mutation_kind, '')) = 'stochastic'
                 THEN 1 ELSE 0
               END) AS stochastic_mutant_killed,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_killed = 1
                  AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                 THEN 1 ELSE 0
               END) AS invariant_mutant_killed
        FROM latest_exposure
        JOIN latest_lines USING (path, line)
        WHERE latest_lines.hits > 0
        GROUP BY path, line
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
        ))
    })?;
    for row in rows {
        let (
            path,
            _line,
            verified_test_types,
            has_mutant_killed,
            has_stochastic_mutant_killed,
            has_invariant_mutant_killed,
        ) = row?;
        if !_scope.allows(&path) || !path_in_directory(&path, _directory) {
            continue;
        }
        if has_mutant_killed > 0 {
            counts.mutant_killed += 1;
        }
        if has_stochastic_mutant_killed > 0 {
            counts.stochastic_mutant_killed += 1;
        }
        if has_invariant_mutant_killed > 0 {
            counts.invariant_mutant_killed += 1;
        }
        if verified_test_types >= 2 {
            counts.multi_type += 1;
        }
    }

    profile_log("dashboard_line_counts.exposure", exposure_start);
    profile_log("dashboard_line_counts.total", total_start);
    Ok(counts)
}

fn dashboard_coverage_line_counts(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<DashboardLineCounts> {
    let start = Instant::now();
    let mut counts = DashboardLineCounts::default();
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_source_lines AS (
          SELECT path, line, hits
          FROM (
            SELECT path, line, source, hits,
                   ROW_NUMBER() OVER (
                     PARTITION BY path, line, source
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM coverage_line_events
          )
          WHERE rank = 1
        ),
        latest_lines AS (
          SELECT path, line, MAX(hits) AS hits
          FROM latest_source_lines
          GROUP BY path, line
        )
        SELECT path, hits
        FROM latest_lines
        "#,
    )?;
    let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?)))?;
    for row in rows {
        let (path, hits) = row?;
        if !scope.allows(&path) || !path_in_directory(&path, directory) {
            continue;
        }
        counts.tracked += 1;
        if hits > 0 {
            counts.covered += 1;
        }
    }
    profile_log("dashboard_coverage_line_counts.total", start);
    Ok(counts)
}

fn dashboard_hazard_counts(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<(i64, i64, i64)> {
    let start = Instant::now();
    let mut active = 0;
    let mut evidence_covered = 0;
    let mut verified = 0;
    let mut stmt = storage.connection().prepare(
        r#"
        WITH active_hazards AS (
          SELECT *
          FROM unit_hazards
          WHERE is_active = 1
        ),
        ranked_exposure AS (
          SELECT t.unit_id,
                 t.path,
                 t.line,
                 t.test_type,
                 t.is_verified,
                 t.is_mutation_killed,
                 t.mutation_kind,
                 ROW_NUMBER() OVER (
                   PARTITION BY t.path, t.line, COALESCE(t.branch_id, ''), t.test_id, t.test_type
                   ORDER BY t.timestamp DESC, t.id DESC
                 ) AS rank
          FROM test_exposure_events t
          JOIN active_hazards h
            ON h.unit_id = t.unit_id
           AND h.path = t.path
           AND h.line = t.line
          WHERE t.line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        ),
        evidence AS (
          SELECT unit_id,
                 path,
                 line,
                 lower(test_type) AS test_type,
                 MAX(CASE WHEN is_verified = 1 THEN 1 ELSE 0 END) AS has_evidence,
                 MAX(CASE
                   WHEN is_verified = 1
                    AND is_mutation_killed = 1
                    AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                   THEN 1 ELSE 0
                 END) AS has_invariant_mutation
          FROM latest_exposure
          GROUP BY unit_id, path, line, lower(test_type)
        )
        SELECT h.path,
               MAX(CASE
                 WHEN e.test_type = lower(h.required_evidence) AND e.has_evidence = 1
                 THEN 1 ELSE 0
               END) AS evidence_present,
               CASE
                 WHEN MAX(CASE
                        WHEN e.test_type = lower(h.required_evidence) AND e.has_evidence = 1
                        THEN 1 ELSE 0
                      END) = 1
                  AND MAX(COALESCE(e.has_invariant_mutation, 0)) = 1
                 THEN 1 ELSE 0
               END AS verified
        FROM active_hazards h
        LEFT JOIN evidence e
          ON e.unit_id = h.unit_id
         AND e.path = h.path
         AND e.line = h.line
        GROUP BY h.id, h.path
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    for row in rows {
        let (path, evidence_present, is_verified) = row?;
        if !scope.allows(&path) || !path_in_directory(&path, directory) {
            continue;
        }
        active += 1;
        if evidence_present != 0 {
            evidence_covered += 1;
        }
        if is_verified != 0 {
            verified += 1;
        }
    }
    profile_log("dashboard_hazard_counts.total", start);
    Ok((active, evidence_covered, verified))
}

pub fn directory_index(files: &[UiFile], directory: &str) -> Vec<UiDirectory> {
    let directory = normalize_directory(directory);
    let mut dirs = BTreeMap::<String, DirectoryBuilder>::new();
    for file in files.iter().filter(|file| path_in_directory(&file.path, &directory)) {
        let Some(child) = immediate_child_directory(&file.path, &directory) else {
            continue;
        };
        let entry = dirs.entry(child.clone()).or_default();
        entry.files += 1;
        entry.units += file.units;
        entry.hazards += file.hazards;
        entry.distinct_tests += file.distinct_tests;
        entry.mutant_killed_tests += file.mutant_killed_tests;
        entry.tracked_lines += file.tracked_lines;
        entry.covered_lines += file.covered_lines;
        entry.line_coverage_sum += file.line_coverage;
        entry.mutant_coverage_sum += file.mutant_coverage;
        if file.tracked_lines == 0 {
            entry.fallback_files += 1;
        }
    }
    dirs.into_iter()
        .map(|(path, builder)| {
            let files = builder.files.max(1) as f64;
            let line_coverage = if builder.tracked_lines > 0 {
                percent(builder.covered_lines, builder.tracked_lines)
            } else {
                builder.line_coverage_sum / files
            };
            UiDirectory {
                path,
                files: builder.files,
                units: builder.units,
                hazards: builder.hazards,
                distinct_tests: builder.distinct_tests,
                mutant_killed_tests: builder.mutant_killed_tests,
                tracked_lines: builder.tracked_lines,
                covered_lines: builder.covered_lines,
                line_coverage,
                mutant_coverage: builder.mutant_coverage_sum / files,
            }
        })
        .collect()
}

#[derive(Default)]
struct DirectoryBuilder {
    files: i64,
    units: i64,
    hazards: i64,
    distinct_tests: i64,
    mutant_killed_tests: i64,
    tracked_lines: i64,
    covered_lines: i64,
    fallback_files: i64,
    line_coverage_sum: f64,
    mutant_coverage_sum: f64,
}

pub fn source_payload(
    storage: &Storage,
    repo: impl AsRef<Path>,
    path: &str,
    commit: Option<&str>,
) -> Result<UiSourcePayload> {
    source_payload_with_overlays(storage, repo, path, commit, &UiOverlays::default())
}

pub fn source_payload_with_overlays(
    storage: &Storage,
    repo: impl AsRef<Path>,
    path: &str,
    commit: Option<&str>,
    overlays: &UiOverlays,
) -> Result<UiSourcePayload> {
    let total_start = Instant::now();
    let repo = repo.as_ref();
    let read_start = Instant::now();
    let file = read_source(repo, path, commit)?;
    profile_log("source.read_source", read_start);
    let lines = file.contents.lines().map(str::to_string).collect::<Vec<_>>();
    let annotation_start = Instant::now();
    let mut annotations = line_annotations(storage, path, overlays)?;
    profile_log("source.line_annotations", annotation_start);
    let paint_start = Instant::now();
    paint_statement_continuations(&lines, &mut annotations);
    profile_log("source.paint_continuations", paint_start);
    let versions_start = Instant::now();
    let versions = file_versions(storage, path)?;
    profile_log("source.file_versions", versions_start);
    let warnings_start = Instant::now();
    let warnings = warnings_for_path(storage, path)?;
    profile_log("source.warnings", warnings_start);
    profile_log("source.total", total_start);
    Ok(UiSourcePayload {
        path: path.to_string(),
        commit: commit.map(str::to_string),
        lines,
        versions,
        annotations,
        warnings,
    })
}

impl UiOverlays {
    pub fn load(paths: &[PathBuf]) -> Result<Self> {
        let mut overlays = Self::default();
        for path in paths {
            let text = fs::read_to_string(path)
                .with_context(|| format!("read overlay {}", path.display()))?;
            let value: Value = serde_json::from_str(&text)
                .with_context(|| format!("parse overlay {}", path.display()))?;
            collect_overlay_value(&value, &mut overlays);
        }
        Ok(overlays)
    }
}

fn handle_stream(
    mut stream: TcpStream,
    db: &Path,
    repo: &Path,
    overlays: &UiOverlays,
) -> Result<()> {
    let mut buffer = [0_u8; 8192];
    let read = stream.read(&mut buffer)?;
    if read == 0 {
        return Ok(());
    }
    let request = String::from_utf8_lossy(&buffer[..read]);
    let Some(first_line) = request.lines().next() else {
        return Ok(());
    };
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or("/");
    if method != "GET" {
        return write_response(&mut stream, 405, "text/plain; charset=utf-8", "method not allowed");
    }
    route(&mut stream, db, repo, overlays, target)
}

fn route(
    stream: &mut TcpStream,
    db: &Path,
    repo: &Path,
    overlays: &UiOverlays,
    target: &str,
) -> Result<()> {
    let (path, query) = split_target(target);
    match path {
        "/" | "/index.html" => {
            let storage = Storage::open_existing(db)?;
            let scope = CoverageScope::from_repo(repo);
            let selected = query.get("path").map(String::as_str);
            let directory = query.get("dir").map(String::as_str);
            let commit = query
                .get("commit")
                .map(String::as_str)
                .filter(|value| !value.is_empty() && *value != "current");
            let filter = query.get("q").map(String::as_str).unwrap_or_default();
            let body = render_index_page(&storage, repo, overlays, &scope, selected, directory, commit, filter)?;
            write_response(stream, 200, "text/html; charset=utf-8", &body)
        }
        "/api/files" => {
            let storage = Storage::open_existing(db)?;
            let scope = CoverageScope::from_repo(repo);
            let json = serde_json::to_string(&file_index_with_scope(&storage, &scope)?)?;
            write_response(stream, 200, "application/json", &json)
        }
        "/api/dashboard" => {
            let storage = Storage::open_existing(db)?;
            let scope = CoverageScope::from_repo(repo);
            let directory = query.get("dir").map(String::as_str).unwrap_or_default();
            let json = serde_json::to_string(&dashboard_summary_for_directory_with_scope(&storage, directory, &scope)?)?;
            write_response(stream, 200, "application/json", &json)
        }
        "/api/source" => {
            let Some(source_path) = query.get("path").map(String::as_str) else {
                return write_response(stream, 400, "application/json", r#"{"error":"missing path"}"#);
            };
            let commit = query
                .get("commit")
                .map(String::as_str)
                .filter(|value| !value.is_empty() && *value != "current");
            let storage = Storage::open_existing(db)?;
            match source_payload_with_overlays(&storage, repo, source_path, commit, overlays) {
                Ok(payload) => {
                    let json = serde_json::to_string(&payload)?;
                    write_response(stream, 200, "application/json", &json)
                }
                Err(error) => write_response(
                    stream,
                    404,
                    "application/json",
                    &serde_json::json!({ "error": error.to_string() }).to_string(),
                ),
            }
        }
        _ => write_response(stream, 404, "text/plain; charset=utf-8", "not found"),
    }
}

fn write_response(stream: &mut TcpStream, status: u16, content_type: &str, body: &str) -> Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "OK",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes())?;
    Ok(())
}

fn split_target(target: &str) -> (&str, HashMap<String, String>) {
    let Some((path, raw_query)) = target.split_once('?') else {
        return (target, HashMap::new());
    };
    let mut query = HashMap::new();
    for pair in raw_query.split('&') {
        let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
        query.insert(percent_decode(key), percent_decode(value));
    }
    (path, query)
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                let hex = &input[index + 1..index + 3];
                if let Ok(value) = u8::from_str_radix(hex, 16) {
                    out.push(value);
                    index += 3;
                } else {
                    out.push(bytes[index]);
                    index += 1;
                }
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn read_source(repo: &Path, path: &str, commit: Option<&str>) -> Result<BlobFile> {
    if let Some(commit) = commit {
        let git = GitProvider::open(repo)?;
        let target = path.to_string();
        let files = git.files_at_commit(commit, &|candidate| candidate == target)?;
        return files
            .into_iter()
            .next()
            .with_context(|| format!("{path} not found at {commit}"));
    }

    let full = safe_join(repo, path)?;
    let contents = fs::read_to_string(&full).with_context(|| format!("read {}", full.display()))?;
    Ok(BlobFile {
        path: path.to_string(),
        contents,
    })
}

fn safe_join(repo: &Path, path: &str) -> Result<PathBuf> {
    let rel = Path::new(path);
    if rel.is_absolute() || path.split('/').any(|part| part == "..") {
        anyhow::bail!("unsafe source path {path:?}");
    }
    Ok(repo.join(rel))
}

fn file_versions(storage: &Storage, path: &str) -> Result<Vec<UiVersion>> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH current_units AS (
          SELECT
            u.id,
            COALESCE((
              SELECT latest.path
              FROM events latest
              WHERE latest.unit_id = u.id
              ORDER BY latest.timestamp DESC, latest.id DESC
              LIMIT 1
            ), u.original_path) AS current_path
          FROM logical_units u
        )
        SELECT e.commit_hash, e.timestamp, e.event_type, e.path, e.name,
               e.start_line, e.end_line, e.semantic_change
        FROM events e
        JOIN current_units cu ON cu.id = e.unit_id
        WHERE cu.current_path = ?1 OR e.path = ?1
        ORDER BY e.timestamp DESC, e.id DESC
        LIMIT 200
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok(UiVersion {
            commit_hash: row.get(0)?,
            timestamp: row.get(1)?,
            event_type: row.get(2)?,
            path: row.get(3)?,
            name: row.get(4)?,
            start_line: row.get(5)?,
            end_line: row.get(6)?,
            semantic_change: row.get::<_, i64>(7)? != 0,
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

pub fn line_annotations(
    storage: &Storage,
    path: &str,
    overlays: &UiOverlays,
) -> Result<Vec<UiLineAnnotation>> {
    let total_start = Instant::now();
    let mut lines = BTreeMap::<u32, AnnotationBuilder>::new();
    let line_start = Instant::now();
    let has_exact_line_coverage = apply_line_coverage(storage, path, &mut lines)?;
    profile_log("line_annotations.line_coverage", line_start);
    let unit_start = Instant::now();
    apply_unit_quality(storage, path, &mut lines, !has_exact_line_coverage)?;
    profile_log("line_annotations.unit_quality", unit_start);
    let exposure_start = Instant::now();
    apply_test_exposure(storage, path, &mut lines, !has_exact_line_coverage)?;
    profile_log("line_annotations.test_exposure", exposure_start);
    let hazard_start = Instant::now();
    apply_hazards(storage, path, &mut lines)?;
    profile_log("line_annotations.hazards", hazard_start);
    let history_start = Instant::now();
    apply_history_heat(storage, path, &mut lines)?;
    profile_log("line_annotations.history_heat", history_start);
    let overlay_start = Instant::now();
    apply_overlays(path, overlays, &mut lines);
    profile_log("line_annotations.overlays", overlay_start);

    let annotations = lines
        .into_iter()
        .map(|(line, builder)| UiLineAnnotation {
            line,
            covered: builder.covered,
            mutant_tested: builder.mutant_tested,
            test_types: builder.test_types.into_iter().collect(),
            distinct_tests: builder.distinct_tests,
            mutant_verified_tests: builder.mutant_verified_tests,
            mutant_killed_tests: builder.mutant_killed_tests,
            line_hits: builder.line_hits,
            line_coverage: builder.line_coverage,
            mutant_coverage: builder.mutant_coverage,
            dark_arms: builder.dark_arms,
            dark_arm_spans: builder.dark_arm_spans,
            hazards: builder.hazards,
            semantic_churn: builder.semantic_churn.min(1.0),
            semantic_churn_events: builder.semantic_churn_events,
            bug_weight: builder.bug_weight.min(1.0),
            bug_events: builder.bug_events,
        })
        .collect();
    profile_log("line_annotations.total", total_start);
    Ok(annotations)
}

fn paint_statement_continuations(lines: &[String], annotations: &mut Vec<UiLineAnnotation>) {
    let mut by_line = annotations
        .drain(..)
        .map(|annotation| (annotation.line, annotation))
        .collect::<BTreeMap<_, _>>();
    let mut index = 0;
    while index < lines.len() {
        let line_no = (index + 1) as u32;
        let starts_covered_statement = by_line
            .get(&line_no)
            .map(|annotation| annotation.covered && annotation.line_hits.unwrap_or(1) > 0)
            .unwrap_or(false);
        if !starts_covered_statement || !line_opens_continuation(&lines[index]) {
            index += 1;
            continue;
        }

        let mut balance = delimiter_delta(&lines[index]).max(0);
        let mut cursor = index + 1;
        while cursor < lines.len() {
            let current_no = (cursor + 1) as u32;
            let trimmed = lines[cursor].trim();
            if trimmed.is_empty() {
                cursor += 1;
                continue;
            }
            let exact_uncovered = by_line
                .get(&current_no)
                .and_then(|annotation| annotation.line_hits)
                == Some(0);
            if exact_uncovered {
                break;
            }
            by_line
                .entry(current_no)
                .or_insert_with(|| visual_coverage_annotation(current_no))
                .covered = true;

            balance += delimiter_delta(&lines[cursor]);
            let continues = balance > 0 || line_opens_continuation(&lines[cursor]);
            cursor += 1;
            if !continues {
                break;
            }
        }
        index = cursor.max(index + 1);
    }
    *annotations = by_line.into_values().collect();
}

fn visual_coverage_annotation(line: u32) -> UiLineAnnotation {
    UiLineAnnotation {
        line,
        covered: true,
        mutant_tested: false,
        test_types: Vec::new(),
        distinct_tests: 0,
        mutant_verified_tests: 0,
        mutant_killed_tests: 0,
        line_hits: None,
        line_coverage: None,
        mutant_coverage: None,
        dark_arms: Vec::new(),
        dark_arm_spans: Vec::new(),
        hazards: Vec::new(),
        semantic_churn: 0.0,
        semantic_churn_events: 0,
        bug_weight: 0.0,
        bug_events: Vec::new(),
    }
}

fn line_opens_continuation(line: &str) -> bool {
    let code = strip_line_comment(line).trim_end();
    if code.is_empty() {
        return false;
    }
    delimiter_delta(code) > 0
        || matches!(
            code.chars().last(),
            Some(',' | '\\' | '.' | '+' | '-' | '*' | '/' | '%' | '=' | ':' | '|' | '&')
        )
        || code.ends_with("do")
        || code.ends_with("then")
}

fn delimiter_delta(line: &str) -> i32 {
    let mut delta = 0;
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for ch in strip_line_comment(line).chars() {
        if let Some(current) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == current {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' | '`' => quote = Some(ch),
            '(' | '[' | '{' => delta += 1,
            ')' | ']' | '}' => delta -= 1,
            _ => {}
        }
    }
    delta
}

fn strip_line_comment(line: &str) -> &str {
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for (index, ch) in line.char_indices() {
        if let Some(current) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == current {
                quote = None;
            }
            continue;
        }
        match ch {
            '"' | '\'' | '`' => quote = Some(ch),
            '#' => return &line[..index],
            '/' if line[index..].starts_with("//") => return &line[..index],
            _ => {}
        }
    }
    line
}

fn apply_unit_quality(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
    paint_line_coverage: bool,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_events AS (
          SELECT e.*
          FROM events e
          WHERE e.id = (
            SELECT latest.id
            FROM events latest
            WHERE latest.unit_id = e.unit_id
            ORDER BY latest.timestamp DESC, latest.id DESC
            LIMIT 1
          )
        )
        SELECT COALESCE(le.start_line, 1),
               COALESCE(le.end_line, le.start_line, 1),
               u.current_line_cov,
               u.current_mutant_cov,
               u.current_test_types
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, f64>(2)?,
            row.get::<_, f64>(3)?,
            row.get::<_, String>(4)?,
        ))
    })?;
    for row in rows {
        let (start, end, line_cov, mutant_cov, test_types) = row?;
        let end = end.max(start);
        for line in start..=end {
            let entry = lines.entry(line).or_default();
            if paint_line_coverage && line_cov > 0.0 {
                entry.covered = true;
                entry.line_coverage = Some(entry.line_coverage.unwrap_or(0.0).max(line_cov));
            }
            if mutant_cov > 0.0 {
                entry.mutant_coverage = Some(entry.mutant_coverage.unwrap_or(0.0).max(mutant_cov));
            }
            for test_type in test_types.split(',').map(str::trim).filter(|value| !value.is_empty()) {
                entry.test_types.insert(test_type.to_string());
            }
        }
    }
    Ok(())
}

fn apply_line_coverage(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) -> Result<bool> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_source AS (
          SELECT line, source, hits,
                 ROW_NUMBER() OVER (
                   PARTITION BY line, source
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM coverage_line_events
          WHERE path = ?1
        ),
        latest AS (
          SELECT line, MAX(hits) AS hits
          FROM latest_source
          WHERE rank = 1
          GROUP BY line
        )
        SELECT line, hits
        FROM latest
        ORDER BY line
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((row.get::<_, u32>(0)?, row.get::<_, u32>(1)?))
    })?;

    let mut has_exact_line_coverage = false;
    for row in rows {
        let (line, hits) = row?;
        has_exact_line_coverage = true;
        let entry = lines.entry(line).or_default();
        entry.line_hits = Some(hits);
        if hits > 0 {
            entry.covered = true;
        }
    }
    Ok(has_exact_line_coverage)
}

fn apply_test_exposure(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
    paint_line_coverage: bool,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH ranked_exposure AS (
          SELECT path, line, branch_id, test_id, test_type, is_verified,
                 is_mutation_verified, is_mutation_killed,
                 ROW_NUMBER() OVER (
                   PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM test_exposure_events
          WHERE path = ?1 AND line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        )
        SELECT line, test_type, COUNT(DISTINCT test_id),
               COUNT(DISTINCT CASE WHEN is_mutation_verified = 1 THEN test_id END),
               COUNT(DISTINCT CASE WHEN is_mutation_killed = 1 THEN test_id END)
        FROM latest_exposure
        WHERE is_verified = 1
        GROUP BY line, test_type
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })?;
    for row in rows {
        let (line, test_type, tests, mutation_verified, mutation_killed) = row?;
        let entry = lines.entry(line).or_default();
        if paint_line_coverage {
            entry.covered = true;
        }
        entry.test_types.insert(test_type);
        entry.distinct_tests += tests;
        entry.mutant_verified_tests += mutation_verified;
        entry.mutant_killed_tests += mutation_killed;
        entry.mutant_tested |= mutation_verified > 0 || mutation_killed > 0;
    }
    Ok(())
}

fn apply_hazards(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH ranked_exposure AS (
          SELECT unit_id, path, line, test_type, is_verified, is_mutation_killed, mutation_kind,
                 ROW_NUMBER() OVER (
                   PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM test_exposure_events
          WHERE path = ?1 AND line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        ),
        evidence AS (
          SELECT unit_id,
                 path,
                 line,
                 lower(test_type) AS test_type,
                 MAX(CASE WHEN is_verified = 1 THEN 1 ELSE 0 END) AS has_evidence,
                 MAX(CASE
                   WHEN is_verified = 1
                    AND is_mutation_killed = 1
                    AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                   THEN 1 ELSE 0
                 END) AS has_invariant_mutation
          FROM latest_exposure
          GROUP BY unit_id, path, line, lower(test_type)
        )
        SELECT h.line, h.hazard_type, h.required_evidence, h.source,
               MAX(CASE
                 WHEN e.test_type = lower(h.required_evidence) AND e.has_evidence = 1
                 THEN 1 ELSE 0
               END) AS evidence_present,
               CASE
                 WHEN MAX(CASE
                        WHEN e.test_type = lower(h.required_evidence) AND e.has_evidence = 1
                        THEN 1 ELSE 0
                      END) = 1
                  AND MAX(COALESCE(e.has_invariant_mutation, 0)) = 1
                 THEN 1 ELSE 0
               END AS verified
        FROM unit_hazards h
        LEFT JOIN evidence e
          ON e.unit_id = h.unit_id
         AND e.path = h.path
         AND e.line = h.line
        WHERE h.path = ?1 AND h.is_active = 1
        GROUP BY h.id, h.line, h.hazard_type, h.required_evidence, h.source
        ORDER BY h.line, h.hazard_type
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            UiHazard {
                hazard_type: row.get(1)?,
                required_evidence: row.get(2)?,
                source: row.get(3)?,
                evidence_present: row.get::<_, i64>(4)? != 0,
                verified: row.get::<_, i64>(5)? != 0,
            },
        ))
    })?;
    for row in rows {
        let (line, hazard) = row?;
        lines.entry(line).or_default().hazards.push(hazard);
    }
    Ok(())
}

fn apply_history_heat(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) -> Result<()> {
    let (first, last) = decay_bounds(storage)?;
    apply_semantic_churn(storage, path, lines, first, last)?;
    apply_crash_history(storage, path, lines, first, last)?;
    Ok(())
}

fn apply_semantic_churn(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
    first_timestamp: i64,
    last_timestamp: i64,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_events AS (
          SELECT e.*
          FROM events e
          WHERE e.id = (
            SELECT latest.id
            FROM events latest
            WHERE latest.unit_id = e.unit_id
            ORDER BY latest.timestamp DESC, latest.id DESC
            LIMIT 1
          )
        )
        SELECT COALESCE(le.start_line, 1) AS current_start,
               COALESCE(le.end_line, le.start_line, 1) AS current_end,
               e.path,
               e.start_line,
               e.end_line,
               e.event_type,
               e.commit_hash,
               e.timestamp,
               e.name,
               COALESCE(m.message, '') AS message
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        JOIN events e ON e.unit_id = u.id
        LEFT JOIN metadata m ON m.commit_hash = e.commit_hash
        WHERE COALESCE(le.path, u.original_path) = ?1
          AND e.semantic_change = 1
          AND e.event_type IN ('CHANGE', 'FIX')
        ORDER BY e.timestamp DESC, e.id DESC
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, u32>(3)?,
            row.get::<_, u32>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, i64>(7)?,
            row.get::<_, String>(8)?,
            row.get::<_, String>(9)?,
        ))
    })?;

    for row in rows {
        let (
            current_start,
            current_end,
            event_path,
            event_start,
            event_end,
            event_type,
            commit_hash,
            timestamp,
            name,
            message,
        ) = row?;
        let weight = fix_cache_decay(timestamp, first_timestamp, last_timestamp);
        let Some((first_line, last_line)) = mapped_history_range(
            path,
            current_start,
            current_end,
            &event_path,
            event_start,
            event_end,
        ) else {
            continue;
        };
        for line in first_line..=last_line {
            let entry = lines.entry(line).or_default();
            entry.semantic_churn += weight;
            entry.semantic_churn_events += 1;
            if event_type == "FIX" && weight >= MIN_HISTORY_WEIGHT {
                push_bug_event(
                    entry,
                    UiBugEvent {
                        event_type: "fix".to_string(),
                        commit_hash: commit_hash.clone(),
                        timestamp,
                        path: event_path.clone(),
                        line,
                        label: bug_event_label("fix", &name, &message),
                        weight,
                    },
                );
            }
        }
    }
    Ok(())
}

fn apply_crash_history(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
    first_timestamp: i64,
    last_timestamp: i64,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        WITH latest_events AS (
          SELECT e.*
          FROM events e
          WHERE e.id = (
            SELECT latest.id
            FROM events latest
            WHERE latest.unit_id = e.unit_id
            ORDER BY latest.timestamp DESC, latest.id DESC
            LIMIT 1
          )
        )
        SELECT COALESCE(le.start_line, 1) AS current_start,
               COALESCE(le.end_line, le.start_line, 1) AS current_end,
               c.path,
               c.line,
               c.commit_hash,
               c.timestamp,
               c.error_class,
               c.provider_id,
               c.function
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        JOIN crash_events c ON c.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        ORDER BY c.timestamp DESC, c.id DESC
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, u32>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, String>(8)?,
        ))
    })?;

    for row in rows {
        let (
            current_start,
            current_end,
            crash_path,
            crash_line,
            commit_hash,
            timestamp,
            error_class,
            provider_id,
            function,
        ) = row?;
        let weight = fix_cache_decay(timestamp, first_timestamp, last_timestamp);
        if weight < MIN_HISTORY_WEIGHT {
            continue;
        }
        let line = if crash_path == path && crash_line >= current_start && crash_line <= current_end
        {
            crash_line
        } else {
            current_start
        };
        let entry = lines.entry(line).or_default();
        push_bug_event(
            entry,
            UiBugEvent {
                event_type: "crash".to_string(),
                commit_hash,
                timestamp,
                path: crash_path,
                line: crash_line,
                label: bug_event_label(
                    "crash",
                    &function,
                    &format!("{error_class} {provider_id}"),
                ),
                weight,
            },
        );
    }
    Ok(())
}

fn decay_bounds(storage: &Storage) -> Result<(i64, i64)> {
    let mut stmt = storage.connection().prepare(
        r#"
        SELECT COALESCE(MIN(timestamp), 0), COALESCE(MAX(timestamp), 0)
        FROM (
          SELECT timestamp
          FROM events
          WHERE semantic_change = 1
            AND event_type IN ('CHANGE', 'FIX')
          UNION ALL
          SELECT timestamp
          FROM crash_events
        )
        "#,
    )?;
    Ok(stmt.query_row([], |row| Ok((row.get(0)?, row.get(1)?)))?)
}

fn fix_cache_decay(timestamp: i64, first_timestamp: i64, last_timestamp: i64) -> f64 {
    let span = (last_timestamp - first_timestamp) as f64;
    let t = if span <= 0.0 {
        1.0
    } else {
        ((timestamp - first_timestamp) as f64 / span).clamp(0.0, 1.0)
    };
    1.0 / (1.0 + ((-12.0 * t) + 12.0).exp())
}

fn mapped_history_range(
    current_path: &str,
    current_start: u32,
    current_end: u32,
    event_path: &str,
    event_start: u32,
    event_end: u32,
) -> Option<(u32, u32)> {
    let current_end = current_end.max(current_start);
    if event_path == current_path {
        let first = event_start.max(current_start);
        let last = event_end.max(event_start).min(current_end);
        (first <= last).then_some((first, last))
    } else {
        Some((current_start, current_end))
    }
}

fn push_bug_event(entry: &mut AnnotationBuilder, event: UiBugEvent) {
    entry.bug_weight += event.weight;
    entry.bug_events.push(event);
}

fn bug_event_label(kind: &str, name: &str, detail: &str) -> String {
    let mut parts = Vec::new();
    if !name.trim().is_empty() {
        parts.push(name.trim().to_string());
    }
    if !detail.trim().is_empty() {
        parts.push(detail.trim().to_string());
    }
    if parts.is_empty() {
        kind.to_string()
    } else {
        parts.join(": ")
    }
}

fn apply_overlays(
    path: &str,
    overlays: &UiOverlays,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) {
    if let Some(by_line) = overlays.dark_arms.get(path) {
        for (line, arms) in by_line {
            for arm in arms {
                let (first_line, last_line) = arm
                    .span
                    .map(|span| (span[0], span[2].max(span[0])))
                    .unwrap_or((*line, *line));
                for target_line in first_line..=last_line {
                    let entry = lines.entry(target_line).or_default();
                    if target_line == *line {
                        entry.dark_arms.push(arm.label.clone());
                    }
                    entry.dark_arm_spans.push(arm.clone());
                }
            }
        }
    }
}

fn collect_overlay_value(value: &Value, overlays: &mut UiOverlays) {
    match value {
        Value::Array(items) => {
            for item in items {
                collect_overlay_value(item, overlays);
            }
        }
        Value::Object(map) => {
            if is_sarif_document(value) {
                collect_sarif_document(value, overlays);
                return;
            }
            if value.get("locations").is_some() {
                collect_sarif_result(value, overlays);
                return;
            }
            if let (Some(path), Some(line), Some(label)) = (
                string_field(value, &["path", "file", "filename"]),
                u32_field(value, &["line", "arm_line", "start_line"]),
                overlay_label(value),
            ) {
                overlays
                    .dark_arms
                    .entry(path.trim_start_matches("./").to_string())
                    .or_default()
                    .entry(line)
                    .or_default()
                    .push(UiDarkArm {
                        label,
                        span: span_field(value, &["arm_span", "span"]),
                    });
            }
            for child in map.values() {
                collect_overlay_value(child, overlays);
            }
        }
        _ => {}
    }
}

fn is_sarif_document(value: &Value) -> bool {
    value.get("version").and_then(Value::as_str) == Some("2.1.0")
        && value.get("runs").and_then(Value::as_array).is_some()
}

fn collect_sarif_document(value: &Value, overlays: &mut UiOverlays) {
    let Some(runs) = value.get("runs").and_then(Value::as_array) else {
        return;
    };
    for run in runs {
        let Some(results) = run.get("results").and_then(Value::as_array) else {
            continue;
        };
        for result in results {
            collect_sarif_result(result, overlays);
        }
    }
}

fn collect_sarif_result(value: &Value, overlays: &mut UiOverlays) {
    let Some(locations) = value.get("locations").and_then(Value::as_array) else {
        return;
    };
    let Some(label) = sarif_overlay_label(value) else {
        return;
    };

    for location in locations {
        let physical = location.get("physicalLocation").unwrap_or(location);
        let path = physical
            .get("artifactLocation")
            .and_then(|artifact| artifact.get("uri"))
            .and_then(Value::as_str);
        let Some(path) = path else {
            continue;
        };
        let null_region = Value::Null;
        let region = physical.get("region").unwrap_or(&null_region);
        let Some(line) = u32_field(region, &["startLine"]) else {
            continue;
        };
        overlays
            .dark_arms
            .entry(path.trim_start_matches("./").to_string())
            .or_default()
            .entry(line)
            .or_default()
            .push(UiDarkArm {
                label: label.clone(),
                span: sarif_region_span(region),
            });
    }
}

fn overlay_label(value: &Value) -> Option<String> {
    let label = string_field(value, &["category", "kind", "rule_id", "ruleId", "message", "finding"])?;
    overlay_label_text(label)
}

fn overlay_label_text(label: &str) -> Option<String> {
    let normalized = label.to_ascii_lowercase();
    if ["dark", "gap", "branch", "genuine"]
        .iter()
        .any(|needle| normalized.contains(needle))
    {
        Some(label.to_string())
    } else {
        None
    }
}

fn sarif_overlay_label(value: &Value) -> Option<String> {
    let null_properties = Value::Null;
    let properties = value.get("properties").unwrap_or(&null_properties);
    if properties
        .get("dark_arm")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Some(
            string_field(properties, &["category", "arm_category", "kind"])
                .or_else(|| string_field(value, &["ruleId"]))
                .unwrap_or("dark arm")
                .to_string(),
        );
    }

    let message_text = value
        .get("message")
        .and_then(|message| message.get("text"))
        .and_then(Value::as_str);
    let result = [
        string_field(value, &["ruleId"]),
        message_text,
        string_field(properties, &["category", "arm_category", "kind", "rule_id", "ruleId"]),
    ]
    .into_iter()
    .flatten()
    .find_map(overlay_label_text);
    result
}

fn string_field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn u32_field(value: &Value, keys: &[&str]) -> Option<u32> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_u64))
        .and_then(|number| u32::try_from(number).ok())
}

fn span_field(value: &Value, keys: &[&str]) -> Option<[u32; 4]> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_array))
        .and_then(|items| {
            let values = items
                .iter()
                .map(Value::as_u64)
                .collect::<Option<Vec<_>>>()?
                .into_iter()
                .map(u32::try_from)
                .collect::<std::result::Result<Vec<_>, _>>()
                .ok()?;
            values.try_into().ok()
        })
}

fn sarif_region_span(region: &Value) -> Option<[u32; 4]> {
    let start_line = u32_field(region, &["startLine"])?;
    let start_column = u32_field(region, &["startColumn"]).map(|column| column.saturating_sub(1));
    let end_line = u32_field(region, &["endLine"]).unwrap_or(start_line);
    let end_column = u32_field(region, &["endColumn"]).map(|column| column.saturating_sub(1));
    if start_column.is_none() && end_column.is_none() && end_line == start_line {
        return None;
    }
    let start = start_column.unwrap_or(0);
    Some([start_line, start, end_line, end_column.unwrap_or(start)])
}

fn profile_enabled() -> bool {
    matches!(
        std::env::var("LINEAGE_UI_PROFILE").ok().as_deref(),
        Some("1" | "true" | "TRUE" | "yes" | "YES")
    )
}

fn profile_log(label: &str, start: Instant) {
    if profile_enabled() {
        eprintln!("lineage ui profile {label}: {:.3}s", start.elapsed().as_secs_f64());
    }
}

fn percent(numerator: i64, denominator: i64) -> f64 {
    if denominator <= 0 {
        0.0
    } else {
        numerator as f64 * 100.0 / denominator as f64
    }
}

fn format_days(days: f64) -> String {
    if days >= 1.0 {
        format!("{days:.1} days")
    } else {
        format!("{:.1} hours", days * 24.0)
    }
}

fn render_index_page(
    storage: &Storage,
    repo: &Path,
    overlays: &UiOverlays,
    scope: &CoverageScope,
    selected: Option<&str>,
    directory: Option<&str>,
    commit: Option<&str>,
    filter: &str,
) -> Result<String> {
    let files = file_index_with_scope(storage, scope)?;
    let selected_path = selected
        .map(normalize_source_path)
        .filter(|path| !path.is_empty());
    let requested_directory = directory.map(normalize_directory).unwrap_or_default();
    let current_directory = selected_path
        .as_deref()
        .map(parent_directory)
        .unwrap_or(requested_directory);
    let dashboard = dashboard_summary_for_directory_with_scope(storage, &current_directory, scope)?;
    let child_directories = directory_index(&files, &current_directory);
    let child_files = files_in_directory(&files, &current_directory);
    let filtered = filtered_files_in_directory(&files, filter, &current_directory);
    let payload = selected_path
        .as_deref()
        .map(|path| source_payload_with_overlays(storage, repo, path, commit, overlays))
        .transpose();

    let mut out = String::new();
    out.push_str("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    out.push_str("<title>Lineage</title><style>");
    out.push_str(STYLE);
    out.push_str("</style></head><body><div class=\"app\"><aside>");
    out.push_str("<header><h1>Lineage</h1><div class=\"subtle\">");
    out.push_str(&format!(
        "{} files{} | {:.1}% covered",
        dashboard.files,
        directory_label_suffix(&current_directory),
        dashboard.coverage_percent
    ));
    out.push_str("</div>");
    out.push_str(&render_sidebar_navigation(&current_directory, filter));
    out.push_str("</header>");
    out.push_str("<form class=\"toolbar\" method=\"get\" action=\"/\">");
    if !current_directory.is_empty() {
        out.push_str("<input type=\"hidden\" name=\"dir\" value=\"");
        out.push_str(&html_escape(&current_directory));
        out.push_str("\">");
    }
    out.push_str("<input name=\"q\" placeholder=\"Filter files\" value=\"");
    out.push_str(&html_escape(filter));
    out.push_str("\"><button type=\"submit\">Filter</button></form>");
    out.push_str("<nav class=\"files\">");
    if filter.trim().is_empty() {
        if !current_directory.is_empty() {
            out.push_str(&render_parent_directory_link(&current_directory, filter));
        }
        for directory in &child_directories {
            out.push_str(&render_directory_link(directory, false, filter));
        }
        for file in &child_files {
            let active = selected_path.as_deref() == Some(file.path.as_str());
            out.push_str(&render_file_link(file, active, filter));
        }
        if child_directories.is_empty() && child_files.is_empty() {
            out.push_str("<div class=\"empty\">No tracked files in this directory.</div>");
        }
    } else {
        for file in &filtered {
            let active = selected_path.as_deref() == Some(file.path.as_str());
            out.push_str(&render_file_link(file, active, filter));
        }
        if filtered.is_empty() {
            out.push_str("<div class=\"empty\">No matching files in this directory.</div>");
        }
    }
    out.push_str("</nav></aside><main>");
    match payload {
        Ok(Some(payload)) => out.push_str(&render_source_view(&payload, filter)),
        Ok(None) => {
            out.push_str(&render_dashboard(
                &dashboard,
                &current_directory,
                &child_directories,
                &child_files,
                filter,
            ));
        }
        Err(error) => {
            out.push_str("<div class=\"topbar\"><div><div class=\"title\">Source unavailable</div>");
            out.push_str("<div class=\"subtle\">");
            out.push_str(&html_escape(&error.to_string()));
            out.push_str("</div></div></div>");
            out.push_str("<div class=\"viewer\"><div class=\"empty\">The selected path is not available in the current checkout. Regenerate coverage for HEAD or open a historical commit view.</div></div>");
        }
    }
    out.push_str("</main></div></body></html>");
    Ok(out)
}

fn filtered_files<'a>(files: &'a [UiFile], filter: &str) -> Vec<&'a UiFile> {
    let normalized = filter.trim().to_ascii_lowercase();
    files
        .iter()
        .filter(|file| normalized.is_empty() || file.path.to_ascii_lowercase().contains(&normalized))
        .collect()
}

fn filtered_files_in_directory<'a>(
    files: &'a [UiFile],
    filter: &str,
    directory: &str,
) -> Vec<&'a UiFile> {
    filtered_files(files, filter)
        .into_iter()
        .filter(|file| path_in_directory(&file.path, directory))
        .collect()
}

fn files_in_directory<'a>(files: &'a [UiFile], directory: &str) -> Vec<&'a UiFile> {
    let directory = normalize_directory(directory);
    files
        .iter()
        .filter(|file| {
            path_in_directory(&file.path, &directory)
                && immediate_child_directory(&file.path, &directory).is_none()
        })
        .collect()
}

fn normalize_directory(directory: &str) -> String {
    directory
        .trim()
        .trim_start_matches("./")
        .trim_matches('/')
        .to_string()
}

fn normalize_source_path(path: &str) -> String {
    path.trim().trim_start_matches("./").trim_matches('/').to_string()
}

fn path_in_directory(path: &str, directory: &str) -> bool {
    let directory = normalize_directory(directory);
    if directory.is_empty() {
        return true;
    }
    path.starts_with(&format!("{directory}/"))
}

fn immediate_child_directory(path: &str, directory: &str) -> Option<String> {
    let directory = normalize_directory(directory);
    let rest = if directory.is_empty() {
        path
    } else {
        path.strip_prefix(&format!("{directory}/"))?
    };
    let (child, _) = rest.split_once('/')?;
    Some(if directory.is_empty() {
        child.to_string()
    } else {
        format!("{directory}/{child}")
    })
}

fn parent_directory(path: &str) -> String {
    path.rsplit_once('/').map(|(parent, _)| parent).unwrap_or("").to_string()
}

fn directory_label_suffix(directory: &str) -> String {
    let directory = normalize_directory(directory);
    if directory.is_empty() {
        "".to_string()
    } else {
        format!(" in {directory}/")
    }
}

fn render_sidebar_navigation(directory: &str, filter: &str) -> String {
    let directory = normalize_directory(directory);
    let mut out = String::new();
    out.push_str("<div class=\"nav-links\"><a class=\"home-link\" href=\"");
    out.push_str(&html_escape(&directory_href("", filter)));
    out.push_str("\">Root</a>");
    if !directory.is_empty() {
        out.push_str("<a class=\"home-link\" href=\"");
        out.push_str(&html_escape(&directory_href(&parent_directory(&directory), filter)));
        out.push_str("\">Up</a><a class=\"home-link\" href=\"");
        out.push_str(&html_escape(&directory_href(&directory, filter)));
        out.push_str("\">Directory</a>");
    }
    out.push_str("</div>");
    out
}

fn render_parent_directory_link(directory: &str, filter: &str) -> String {
    let parent = parent_directory(directory);
    format!(
        "<a class=\"file dir-up\" href=\"{}\"><span class=\"file-path\">../</span><span class=\"pills\"></span></a>",
        html_escape(&directory_href(&parent, filter))
    )
}

fn render_file_link(file: &UiFile, active: bool, filter: &str) -> String {
    let href = page_href(&file.path, None, filter);
    let mut out = format!(
        "<a class=\"file{}\" href=\"{}\"><span class=\"file-path\" title=\"{}\">{}</span><span class=\"pills\">",
        if active { " active" } else { "" },
        html_escape(&href),
        html_escape(&file.path),
        html_escape(&file.path)
    );
    if file.hazards > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"active hazards\">{}</span>",
            file.hazards
        ));
    }
    if file.line_coverage > 0.0 {
        out.push_str(&format!(
            "<span class=\"pill coverage-pill\" title=\"line coverage\">{:.0}%</span>",
            file.line_coverage
        ));
    }
    if file.mutant_killed_tests > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"mutant killed tests\">{}</span>",
            file.mutant_killed_tests
        ));
    }
    out.push_str("</span></a>");
    out
}

fn render_directory_link(directory: &UiDirectory, active: bool, filter: &str) -> String {
    let href = directory_href(&directory.path, filter);
    let mut out = format!(
        "<a class=\"file{}\" href=\"{}\"><span class=\"file-path\" title=\"{}\">{}/</span><span class=\"pills\">",
        if active { " active" } else { "" },
        html_escape(&href),
        html_escape(&directory.path),
        html_escape(&directory.path)
    );
    if directory.hazards > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"active hazards\">{}</span>",
            directory.hazards
        ));
    }
    if directory.line_coverage > 0.0 {
        out.push_str(&format!(
            "<span class=\"pill coverage-pill\" title=\"line coverage\">{:.0}%</span>",
            directory.line_coverage
        ));
    }
    if directory.mutant_killed_tests > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"mutant killed tests\">{}</span>",
            directory.mutant_killed_tests
        ));
    }
    out.push_str("</span></a>");
    out
}

fn render_dashboard(
    dashboard: &UiDashboard,
    directory: &str,
    directories: &[UiDirectory],
    files: &[&UiFile],
    filter: &str,
) -> String {
    let directory = normalize_directory(directory);
    let mut out = String::new();
    out.push_str("<div class=\"topbar\"><div><div class=\"title\">");
    if directory.is_empty() {
        out.push_str("Coverage Dashboard");
    } else {
        out.push_str("Directory: ");
        out.push_str(&html_escape(&directory));
        out.push('/');
    }
    out.push_str("</div><div class=\"subtle\">Current Lineage database snapshot");
    if !directory.is_empty() {
        out.push_str(" scoped to ");
        out.push_str(&html_escape(&directory));
        out.push('/');
    }
    out.push_str("</div></div>");
    out.push_str("<div class=\"crumbs\"><a href=\"");
    out.push_str(&html_escape(&directory_href("", filter)));
    out.push_str("\">root</a>");
    if !directory.is_empty() {
        out.push_str("<a href=\"");
        out.push_str(&html_escape(&directory_href(&parent_directory(&directory), filter)));
        out.push_str("\">up</a>");
    }
    out.push_str("</div></div>");
    out.push_str("<div class=\"viewer\"><section class=\"dashboard\">");
    out.push_str("<div class=\"metric-grid\">");
    out.push_str(&render_metric(
        "Line coverage",
        &format!("{:.1}%", dashboard.coverage_percent),
        &format!(
            "{} / {} tracked lines covered",
            dashboard.covered_lines, dashboard.tracked_lines
        ),
    ));
    out.push_str(&render_metric(
        "Hazard evidence",
        &format!("{:.1}%", dashboard.hazard_evidence_percent),
        &format!(
            "{} / {} active hazards have required systems evidence",
            dashboard.evidence_covered_hazards, dashboard.active_hazards
        ),
    ));
    out.push_str(&render_metric(
        "Hazard verification",
        &format!("{:.1}%", dashboard.hazard_coverage_percent),
        &format!(
            "{} / {} active hazards have evidence plus invariant mutants",
            dashboard.covered_hazards, dashboard.active_hazards
        ),
    ));
    out.push_str(&render_metric(
        "Mutant-backed lines",
        &format!("{:.1}%", dashboard.mutant_killed_covered_percent),
        &format!(
            "{} / {} covered lines have killed-mutant evidence",
            dashboard.mutant_killed_covered_lines, dashboard.covered_lines
        ),
    ));
    out.push_str(&render_metric(
        "Stochastic mutants",
        &format!("{:.1}%", dashboard.stochastic_mutant_killed_covered_percent),
        &format!(
            "{} / {} covered lines are stochastic-mutant backed",
            dashboard.stochastic_mutant_killed_covered_lines, dashboard.covered_lines
        ),
    ));
    out.push_str(&render_metric(
        "Invariant mutants",
        &format!("{:.1}%", dashboard.invariant_mutant_killed_covered_percent),
        &format!(
            "{} / {} covered lines are invariant-mutant backed",
            dashboard.invariant_mutant_killed_covered_lines, dashboard.covered_lines
        ),
    ));
    out.push_str(&render_metric(
        "Multi-type lines",
        &format!("{:.1}%", dashboard.multi_type_covered_percent),
        &format!(
            "{} / {} covered lines have multiple verified test types",
            dashboard.multi_type_covered_lines, dashboard.covered_lines
        ),
    ));
    out.push_str(&render_metric(
        "Files",
        &dashboard.files.to_string(),
        &format!("{} files currently report coverage", dashboard.files_with_coverage),
    ));
    out.push_str("</div>");
    out.push_str(&render_warning_banner(&dashboard.warnings));

    out.push_str("<section class=\"dashboard-section\"><h2>Directories</h2>");
    if directories.is_empty() {
        out.push_str("<p class=\"empty-inline\">No child directories are tracked here.</p>");
    } else {
        out.push_str("<div class=\"dashboard-files\">");
        for directory in directories {
            out.push_str(&render_directory_dashboard_row(directory, filter));
        }
        out.push_str("</div>");
    }
    out.push_str("</section>");

    out.push_str("<section class=\"dashboard-section\"><h2>Files</h2>");
    if files.is_empty() {
        out.push_str("<p class=\"empty-inline\">No files are tracked directly in this directory.</p>");
    } else {
        out.push_str("<div class=\"dashboard-files\">");
        for file in files {
            out.push_str(&render_file_dashboard_row(file, filter));
        }
        out.push_str("</div>");
    }
    out.push_str("</section>");

    out.push_str("<section class=\"dashboard-section\"><h2>Active Hazards</h2>");
    if dashboard.active_hazards == 0 {
        out.push_str("<p class=\"empty-inline\">No active systems hazards are recorded.</p>");
    } else {
        out.push_str("<div class=\"hazard-bar\"><span style=\"width:");
        out.push_str(&format!("{:.2}%", dashboard.hazard_coverage_percent));
        out.push_str("\"></span></div>");
        out.push_str("<p class=\"subtle\">");
        out.push_str(&format!(
            "{} hazards have required systems evidence; {} also have invariant-mutant proof.",
            dashboard.evidence_covered_hazards,
            dashboard.covered_hazards,
        ));
        out.push_str("</p>");
    }
    out.push_str("</section>");

    out.push_str("<section class=\"dashboard-section\"><h2>Highest Hazard Files</h2>");
    if dashboard.top_hazard_files.is_empty() {
        out.push_str("<p class=\"empty-inline\">No hazard-heavy files to show.</p>");
    } else {
        out.push_str("<div class=\"dashboard-files\">");
        for file in &dashboard.top_hazard_files {
            out.push_str("<a href=\"");
            out.push_str(&html_escape(&page_href(&file.path, None, filter)));
            out.push_str("\"><span class=\"row-label\"><span class=\"row-title\">");
            out.push_str(&html_escape(&file.path));
            out.push_str("</span><small>");
            out.push_str(&file_detail(file));
            out.push_str("</small></span><strong class=\"hazard-value\">");
            out.push_str(&file.hazards.to_string());
            out.push_str("</strong></a>");
        }
        out.push_str("</div>");
    }
    out.push_str("</section>");
    out.push_str("</section></div>");
    out
}

fn render_directory_dashboard_row(directory: &UiDirectory, filter: &str) -> String {
    let mut out = String::new();
    out.push_str("<a href=\"");
    out.push_str(&html_escape(&directory_href(&directory.path, filter)));
    out.push_str("\"><span class=\"row-label\"><span class=\"row-title\">");
    out.push_str(&html_escape(&directory.path));
    out.push_str("/</span><small>");
    out.push_str(&html_escape(&format!(
        "{} files | {} / {} lines | {} hazards | {} mutant-killed tests",
        directory.files,
        directory.covered_lines,
        directory.tracked_lines,
        directory.hazards,
        directory.mutant_killed_tests
    )));
    out.push_str("</small></span><strong class=\"metric-value\">");
    out.push_str(&format!("{:.0}%", directory.line_coverage));
    out.push_str("</strong></a>");
    out
}

fn render_file_dashboard_row(file: &UiFile, filter: &str) -> String {
    let mut out = String::new();
    out.push_str("<a href=\"");
    out.push_str(&html_escape(&page_href(&file.path, None, filter)));
    out.push_str("\"><span class=\"row-label\"><span class=\"row-title\">");
    out.push_str(&html_escape(&file.path));
    out.push_str("</span><small>");
    out.push_str(&file_detail(file));
    out.push_str("</small></span><strong class=\"metric-value\">");
    out.push_str(&format!("{:.0}%", file.line_coverage));
    out.push_str("</strong></a>");
    out
}

fn file_detail(file: &UiFile) -> String {
    html_escape(&format!(
        "{} units | {} / {} lines | {} hazards | {} tests | {} mutant-killed tests",
        file.units,
        file.covered_lines,
        file.tracked_lines,
        file.hazards,
        file.distinct_tests,
        file.mutant_killed_tests
    ))
}

fn render_metric(label: &str, value: &str, detail: &str) -> String {
    let mut out = String::new();
    out.push_str("<article class=\"metric\"><div>");
    out.push_str(&html_escape(label));
    out.push_str("</div><strong>");
    out.push_str(&html_escape(value));
    out.push_str("</strong><p>");
    out.push_str(&html_escape(detail));
    out.push_str("</p></article>");
    out
}

fn render_warning_banner(warnings: &[UiWarning]) -> String {
    if warnings.is_empty() {
        return String::new();
    }

    let mut out = String::new();
    out.push_str("<section class=\"warning-banner\" aria-label=\"verification warnings\">");
    for warning in warnings {
        out.push_str("<article class=\"warning ");
        out.push_str(&html_escape(&warning.level));
        out.push_str("\"><strong>");
        out.push_str(&html_escape(&warning.label));
        out.push_str("</strong><p>");
        out.push_str(&html_escape(&warning.detail));
        out.push_str("</p></article>");
    }
    out.push_str("</section>");
    out
}

fn render_source_view(payload: &UiSourcePayload, filter: &str) -> String {
    let annotations = payload
        .annotations
        .iter()
        .map(|annotation| (annotation.line, annotation))
        .collect::<BTreeMap<_, _>>();
    let covered = payload
        .annotations
        .iter()
        .filter(|annotation| annotation.line_hits.unwrap_or(0) > 0)
        .count();
    let mutant = payload
        .annotations
        .iter()
        .filter(|annotation| annotation.mutant_tested)
        .count();
    let hazards: usize = payload
        .annotations
        .iter()
        .map(|annotation| annotation.hazards.len())
        .sum();
    let dark_arms: usize = payload
        .annotations
        .iter()
        .map(|annotation| annotation.dark_arms.len())
        .sum();

    let mut out = String::new();
    out.push_str("<section class=\"source-view\">");
    out.push_str(
        "<input class=\"mode-radio\" type=\"radio\" name=\"lineage-view-mode\" id=\"mode-coverage\" checked>",
    );
    out.push_str(
        "<input class=\"mode-radio\" type=\"radio\" name=\"lineage-view-mode\" id=\"mode-churn\">",
    );
    out.push_str("<div class=\"topbar\"><div><div class=\"title\">");
    out.push_str(&html_escape(&payload.path));
    out.push_str("</div><div class=\"subtle\">");
    out.push_str(&format!(
        "{} covered lines | {} mutant lines | {} hazards | {} dark arms",
        covered, mutant, hazards, dark_arms
    ));
    out.push_str("</div></div><div class=\"source-actions\">");
    out.push_str(
        "<div class=\"view-toggle\" aria-label=\"line color mode\"><label for=\"mode-coverage\">Coverage Quality</label><label for=\"mode-churn\">Churn Heat</label></div>",
    );
    out.push_str(&render_history(payload, filter));
    out.push_str("</div></div>");
    out.push_str(&render_warning_banner(&payload.warnings));
    out.push_str("<div class=\"viewer\"><div class=\"code\">");
    for (index, line) in payload.lines.iter().enumerate() {
        let line_no = (index + 1) as u32;
        out.push_str(&render_code_line(
            &payload.path,
            line_no,
            line,
            annotations.get(&line_no).copied(),
        ));
    }
    out.push_str("</div></div>");
    out.push_str("</section>");
    out
}

fn render_history(payload: &UiSourcePayload, filter: &str) -> String {
    let mut out = String::new();
    out.push_str("<details class=\"history\"><summary>History");
    if !payload.versions.is_empty() {
        out.push_str(&format!(" ({})", payload.versions.len()));
    }
    out.push_str("</summary><div class=\"history-list\">");
    out.push_str(&format!(
        "<a href=\"{}\">current working tree</a>",
        html_escape(&page_href(&payload.path, None, filter))
    ));
    for version in &payload.versions {
        let href = page_href(&payload.path, Some(&version.commit_hash), filter);
        out.push_str("<a href=\"");
        out.push_str(&html_escape(&href));
        out.push_str("\"><code>");
        out.push_str(&html_escape(&short_commit(&version.commit_hash)));
        out.push_str("</code> ");
        out.push_str(&html_escape(&version.event_type.to_ascii_lowercase()));
        out.push_str(" ");
        out.push_str(&html_escape(&version.name));
        out.push_str("</a>");
    }
    out.push_str("</div></details>");
    out
}

fn render_code_line(
    path: &str,
    line_no: u32,
    source: &str,
    annotation: Option<&UiLineAnnotation>,
) -> String {
    let mut classes = vec!["row"];
    if annotation.map(|a| a.covered).unwrap_or(false) {
        classes.push("covered");
    }
    if annotation.map(|a| a.mutant_tested).unwrap_or(false) {
        classes.push("mutant");
    }
    if annotation.map(annotation_has_dark_arms).unwrap_or(false) {
        classes.push("dark-arm");
    }
    if annotation.map(|a| a.semantic_churn > 0.0).unwrap_or(false) {
        classes.push("has-churn");
    }
    if annotation.map(|a| !a.bug_events.is_empty()).unwrap_or(false) {
        classes.push("has-bugs");
    }
    if let Some(annotation) = annotation {
        if !annotation.hazards.is_empty() {
            if annotation.hazards.iter().all(|hazard| hazard.verified) {
                classes.push("hazard-verified");
            } else {
                classes.push("hazard-open");
            }
        }
    }

    let style = annotation
        .map(row_style)
        .filter(|style| !style.is_empty())
        .map(|style| format!(" style=\"{}\"", html_escape(&style)))
        .unwrap_or_default();
    let hazard_title = annotation
        .map(hazard_rail_title)
        .filter(|title| !title.is_empty())
        .map(|title| format!(" title=\"{}\"", html_escape(&title)))
        .unwrap_or_default();
    let gutter_title = annotation
        .map(gutter_title)
        .filter(|title| !title.is_empty())
        .map(|title| format!(" title=\"{}\"", html_escape(&title)))
        .unwrap_or_default();

    let mut out = format!(
        "<div class=\"{}\"{}><span class=\"hazard-rail\"{}></span><span class=\"gutter\"{}>",
        classes.join(" "),
        style,
        hazard_title,
        gutter_title,
    );
    if let Some(annotation) = annotation {
        for hazard in &annotation.hazards {
            let mut title = format!(
                "{} requires {} ({})",
                hazard.hazard_type,
                hazard.required_evidence,
                if hazard.verified {
                    "evidence plus invariant mutation present"
                } else if hazard.evidence_present {
                    "systems evidence present; invariant mutation missing"
                } else {
                    "systems evidence and invariant mutation missing"
                }
            );
            if !hazard.source.is_empty() {
                title.push('\n');
                title.push_str(&hazard.source);
            }
            out.push_str(&format!(
                "<span class=\"bomb{}\" title=\"{}\">&#128163;</span>",
                if hazard.verified { " verified" } else { "" },
                html_escape(&title)
            ));
        }
        if !annotation.bug_events.is_empty() {
            out.push_str(&render_bug_history(annotation));
        }
        if line_has_details(annotation) {
            out.push_str(&render_line_details(annotation));
        }
    }
    out.push_str("</span><span class=\"ln\">");
    out.push_str(&line_no.to_string());
    out.push_str("</span><pre>");
    out.push_str(&highlight_source_line_with_dark_arms(
        path, line_no, source, annotation,
    ));
    out.push_str("</pre></div>");
    out
}

fn render_line_details(annotation: &UiLineAnnotation) -> String {
    let mut rows = Vec::new();
    if annotation.covered && annotation.line_hits.is_none() && annotation.line_coverage.is_none() {
        rows.push(
            "covered as part of a multi-line statement; exact line-hit metadata is unavailable"
                .to_string(),
        );
    }
    if !annotation.test_types.is_empty() {
        rows.push(format!("tests: {}", annotation.test_types.join(", ")));
    }
    if annotation.distinct_tests > 0 {
        rows.push(format!("{} distinct test hits", annotation.distinct_tests));
    }
    if annotation.mutant_killed_tests > 0 {
        rows.push(format!("{} mutant killed", annotation.mutant_killed_tests));
    }
    if let Some(hits) = annotation.line_hits {
        rows.push(format!("line hits {hits}"));
    }
    let dark_arm_labels = dark_arm_labels(annotation);
    if !dark_arm_labels.is_empty() {
        rows.push(format!("dark arms: {}", dark_arm_labels.join(", ")));
    }
    if let Some(value) = annotation.line_coverage {
        rows.push(format!("unit line coverage {:.1}%", value));
    }
    if let Some(value) = annotation.mutant_coverage {
        rows.push(format!("unit mutant coverage {:.1}%", value));
    }
    if annotation.semantic_churn_events > 0 {
        rows.push(format!(
            "{} semantic churn event(s); decayed score {:.3}",
            annotation.semantic_churn_events,
            annotation.semantic_churn.min(1.0)
        ));
    }
    if annotation.bug_weight > 0.0 {
        rows.push(format!(
            "decayed bug/fix weight {:.3}",
            annotation.bug_weight.min(1.0)
        ));
    }
    let mut out = String::new();
    out.push_str(
        "<details class=\"line-meta\"><summary title=\"line verification details\">i</summary><div>",
    );
    for row in rows {
        out.push_str("<p>");
        out.push_str(&html_escape(&row));
        out.push_str("</p>");
    }
    out.push_str("</div></details>");
    out
}

fn render_bug_history(annotation: &UiLineAnnotation) -> String {
    let opacity = 0.18 + (annotation.bug_weight * 2.0).min(1.0) * 0.82;
    let mut out = String::new();
    out.push_str(
        "<details class=\"bug-history\"><summary title=\"decayed bug/fix history\" style=\"opacity:",
    );
    out.push_str(&format!("{opacity:.3}"));
    out.push_str("\">&#128027;</summary><div>");
    for event in &annotation.bug_events {
        out.push_str("<p><strong>");
        out.push_str(&html_escape(&event.event_type));
        out.push_str("</strong> <code>");
        out.push_str(&html_escape(&short_commit(&event.commit_hash)));
        out.push_str("</code> ");
        out.push_str(&html_escape(&format!(
            "{}:{} weight {:.3} @ {}",
            event.path, event.line, event.weight, event.timestamp
        )));
        if !event.label.is_empty() {
            out.push_str("<br>");
            out.push_str(&html_escape(&event.label));
        }
        out.push_str("</p>");
    }
    out.push_str("</div></details>");
    out
}

fn row_style(annotation: &UiLineAnnotation) -> String {
    let coverage = coverage_background(annotation, false);
    let gutter_coverage = coverage_background(annotation, true);
    let churn = heat_background(annotation.semantic_churn, false);
    let gutter_churn = heat_background(annotation.semantic_churn, true);
    format!(
        "--coverage-bg:{coverage};--gutter-coverage-bg:{gutter_coverage};--churn-bg:{churn};--gutter-churn-bg:{gutter_churn};"
    )
}

fn coverage_background(annotation: &UiLineAnnotation, gutter: bool) -> String {
    if annotation.mutant_tested || annotation.mutant_killed_tests > 0 {
        if gutter {
            "rgba(22, 101, 52, 0.34)".to_string()
        } else {
            "rgba(22, 101, 52, 0.24)".to_string()
        }
    } else if annotation.covered {
        if gutter {
            "rgba(34, 197, 94, 0.18)".to_string()
        } else {
            "rgba(34, 197, 94, 0.08)".to_string()
        }
    } else {
        "transparent".to_string()
    }
}

fn heat_background(weight: f64, gutter: bool) -> String {
    let weight = weight.clamp(0.0, 1.0);
    if weight <= 0.0 {
        return "transparent".to_string();
    }
    let (red, green, blue) = if weight < 0.20 {
        (254, 249, 195)
    } else if weight < 0.45 {
        (253, 186, 116)
    } else if weight < 0.75 {
        (248, 113, 113)
    } else {
        (220, 38, 38)
    };
    let base = if gutter { 0.18 } else { 0.08 };
    let spread = if gutter { 0.44 } else { 0.24 };
    let alpha = (base + weight * spread).min(if gutter { 0.70 } else { 0.42 });
    format!("rgba({red}, {green}, {blue}, {alpha:.3})")
}

fn hazard_rail_title(annotation: &UiLineAnnotation) -> String {
    let hazards = annotation
        .hazards
        .iter()
        .filter(|hazard| !hazard.verified)
        .map(|hazard| format!("{} requires {}", hazard.hazard_type, hazard.required_evidence))
        .collect::<Vec<_>>();
    hazards.join("\n")
}

fn gutter_title(annotation: &UiLineAnnotation) -> String {
    let mut rows = Vec::new();
    if annotation.semantic_churn_events > 0 {
        rows.push(format!(
            "{} semantic churn event(s), decayed score {:.3}",
            annotation.semantic_churn_events,
            annotation.semantic_churn.min(1.0)
        ));
    }
    if annotation.covered {
        rows.push(if annotation.mutant_tested {
            "coverage quality: mutant tested".to_string()
        } else {
            "coverage quality: covered".to_string()
        });
    }
    rows.join("\n")
}

fn line_has_details(annotation: &UiLineAnnotation) -> bool {
    annotation.covered
        || annotation.mutant_tested
        || !annotation.test_types.is_empty()
        || !annotation.dark_arms.is_empty()
        || !annotation.dark_arm_spans.is_empty()
        || annotation.line_hits.is_some()
        || annotation.line_coverage.is_some()
        || annotation.mutant_coverage.is_some()
        || annotation.semantic_churn_events > 0
        || !annotation.bug_events.is_empty()
}

fn annotation_has_dark_arms(annotation: &UiLineAnnotation) -> bool {
    !annotation.dark_arms.is_empty() || !annotation.dark_arm_spans.is_empty()
}

fn dark_arm_labels(annotation: &UiLineAnnotation) -> Vec<String> {
    let mut labels = annotation.dark_arms.clone();
    labels.extend(annotation.dark_arm_spans.iter().map(|arm| arm.label.clone()));
    labels.sort();
    labels.dedup();
    labels
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SyntaxLanguage {
    Ruby,
    Python,
    JavaScript,
    TypeScript,
    Go,
    Rust,
    Lua,
    Zig,
    C,
    Plain,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct InlineDarkArmRange {
    start: usize,
    end: usize,
    labels: Vec<String>,
}

fn highlight_source_line_with_dark_arms(
    path: &str,
    line_no: u32,
    source: &str,
    annotation: Option<&UiLineAnnotation>,
) -> String {
    let Some(annotation) = annotation else {
        return highlight_source_line(path, source);
    };
    let ranges = inline_dark_arm_ranges(line_no, source, annotation);
    if ranges.is_empty() {
        return highlight_source_line(path, source);
    }

    let mut out = String::new();
    let mut cursor = 0;
    for range in ranges {
        if range.start > cursor {
            out.push_str(&highlight_source_line(path, &source[cursor..range.start]));
        }
        out.push_str("<span class=\"dark-arm-span\" title=\"");
        out.push_str(&html_escape(&range.labels.join("\n")));
        out.push_str("\">");
        out.push_str(&highlight_source_line(path, &source[range.start..range.end]));
        out.push_str("</span>");
        cursor = range.end;
    }
    if cursor < source.len() {
        out.push_str(&highlight_source_line(path, &source[cursor..]));
    }
    out
}

fn inline_dark_arm_ranges(
    line_no: u32,
    source: &str,
    annotation: &UiLineAnnotation,
) -> Vec<InlineDarkArmRange> {
    let mut ranges = annotation
        .dark_arm_spans
        .iter()
        .filter_map(|arm| {
            let span = arm.span?;
            dark_arm_line_range(line_no, source, span).map(|(start, end)| InlineDarkArmRange {
                start,
                end,
                labels: vec![arm.label.clone()],
            })
        })
        .collect::<Vec<_>>();
    if ranges.is_empty() {
        return ranges;
    }

    ranges.sort_by_key(|range| (range.start, range.end));
    let mut merged = Vec::<InlineDarkArmRange>::new();
    for range in ranges {
        if let Some(last) = merged.last_mut() {
            if range.start <= last.end {
                last.end = last.end.max(range.end);
                last.labels.extend(range.labels);
                last.labels.sort();
                last.labels.dedup();
                continue;
            }
        }
        merged.push(range);
    }
    merged
}

fn dark_arm_line_range(line_no: u32, source: &str, span: [u32; 4]) -> Option<(usize, usize)> {
    let [start_line, start_col, end_line, end_col] = span;
    if line_no < start_line || line_no > end_line {
        return None;
    }
    let start = if line_no == start_line {
        start_col as usize
    } else {
        0
    };
    let end = if line_no == end_line {
        end_col as usize
    } else {
        source.len()
    };
    let start = clamp_to_char_boundary(source, start.min(source.len()));
    let end = clamp_to_char_boundary(source, end.min(source.len()));
    (end > start).then_some((start, end))
}

fn clamp_to_char_boundary(source: &str, mut index: usize) -> usize {
    while index > 0 && !source.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn highlight_source_line(path: &str, source: &str) -> String {
    let language = syntax_language(path);
    if language == SyntaxLanguage::Plain {
        return html_escape(source);
    }

    let mut out = String::new();
    let mut chars = source.char_indices().peekable();
    let mut previous_word: Option<String> = None;
    while let Some((start, ch)) = chars.next() {
        if let Some(prefix) = comment_prefix(language) {
            if source[start..].starts_with(prefix) {
                push_token(&mut out, "comment", &source[start..]);
                break;
            }
        }

        if is_string_delimiter(language, ch) {
            let end = scan_string(source, &mut chars, ch);
            push_token(&mut out, "string", &source[start..end]);
            continue;
        }

        if ch.is_ascii_digit() {
            let end = scan_while(source, &mut chars, |candidate| {
                candidate.is_ascii_alphanumeric() || matches!(candidate, '_' | '.' | ':')
            });
            push_token(&mut out, "number", &source[start..end]);
            continue;
        }

        if is_identifier_start(ch) {
            let end = scan_while(source, &mut chars, is_identifier_continue);
            let word = &source[start..end];
            if keywords(language).contains(&word) {
                push_token(&mut out, "keyword", word);
            } else if let Some(kind) = identifier_token_kind(
                language,
                word,
                previous_word.as_deref(),
                previous_non_whitespace(source, start),
                next_non_whitespace(source, end),
            ) {
                push_token(&mut out, kind, word);
            } else {
                out.push_str(&html_escape(word));
            }
            previous_word = Some(word.to_string());
            continue;
        }

        out.push_str(&html_escape(&source[start..start + ch.len_utf8()]));
    }

    out
}

fn syntax_language(path: &str) -> SyntaxLanguage {
    match Path::new(path).extension().and_then(|extension| extension.to_str()) {
        Some("rb") => SyntaxLanguage::Ruby,
        Some("py") => SyntaxLanguage::Python,
        Some("js" | "mjs" | "cjs" | "jsx") => SyntaxLanguage::JavaScript,
        Some("ts" | "tsx") => SyntaxLanguage::TypeScript,
        Some("go") => SyntaxLanguage::Go,
        Some("rs") => SyntaxLanguage::Rust,
        Some("lua") => SyntaxLanguage::Lua,
        Some("zig") => SyntaxLanguage::Zig,
        Some("c" | "h" | "cc" | "cpp" | "cxx" | "hpp") => SyntaxLanguage::C,
        _ => SyntaxLanguage::Plain,
    }
}

fn comment_prefix(language: SyntaxLanguage) -> Option<&'static str> {
    match language {
        SyntaxLanguage::Ruby | SyntaxLanguage::Python => Some("#"),
        SyntaxLanguage::Lua => Some("--"),
        SyntaxLanguage::JavaScript
        | SyntaxLanguage::TypeScript
        | SyntaxLanguage::Go
        | SyntaxLanguage::Rust
        | SyntaxLanguage::Zig
        | SyntaxLanguage::C => Some("//"),
        SyntaxLanguage::Plain => None,
    }
}

fn is_string_delimiter(language: SyntaxLanguage, ch: char) -> bool {
    matches!(ch, '"' | '\'') || matches!(language, SyntaxLanguage::JavaScript | SyntaxLanguage::TypeScript) && ch == '`'
}

fn scan_string(
    source: &str,
    chars: &mut std::iter::Peekable<std::str::CharIndices<'_>>,
    delimiter: char,
) -> usize {
    let mut escaped = false;
    while let Some((index, ch)) = chars.next() {
        if escaped {
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == delimiter {
            return index + ch.len_utf8();
        }
    }
    source.len()
}

fn scan_while(
    source: &str,
    chars: &mut std::iter::Peekable<std::str::CharIndices<'_>>,
    predicate: impl Fn(char) -> bool,
) -> usize {
    while let Some((_, candidate)) = chars.peek().copied() {
        if !predicate(candidate) {
            break;
        }
        chars.next();
    }

    chars.peek().map(|(index, _)| *index).unwrap_or(source.len())
}

fn is_identifier_start(ch: char) -> bool {
    ch == '_' || ch.is_ascii_alphabetic()
}

fn is_identifier_continue(ch: char) -> bool {
    ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric()
}

fn identifier_token_kind(
    language: SyntaxLanguage,
    word: &str,
    previous_word: Option<&str>,
    previous_char: Option<char>,
    next_char: Option<char>,
) -> Option<&'static str> {
    if matches!(previous_char, Some('.' | ':')) {
        return if next_char == Some('(') {
            Some("function")
        } else {
            Some("property")
        };
    }

    if let Some(previous_word) = previous_word {
        if is_type_declaration_keyword(previous_word) {
            return Some("type");
        }
        if is_function_declaration_keyword(previous_word) {
            return Some("function");
        }
        if is_constant_declaration_keyword(previous_word) {
            return if is_pascal_case(word) {
                Some("type")
            } else {
                Some("constant")
            };
        }
    }

    if is_all_caps_constant(word) {
        return Some("constant");
    }
    if is_pascal_case(word) {
        return Some("type");
    }
    if next_char == Some('(') {
        return Some("function");
    }
    if matches!(language, SyntaxLanguage::Ruby) && previous_char == Some('@') {
        return Some("property");
    }

    None
}

fn previous_non_whitespace(source: &str, start: usize) -> Option<char> {
    source[..start].chars().rev().find(|ch| !ch.is_whitespace())
}

fn next_non_whitespace(source: &str, end: usize) -> Option<char> {
    source[end..].chars().find(|ch| !ch.is_whitespace())
}

fn is_type_declaration_keyword(word: &str) -> bool {
    matches!(
        word,
        "class"
            | "module"
            | "struct"
            | "enum"
            | "union"
            | "interface"
            | "trait"
            | "type"
            | "impl"
    )
}

fn is_function_declaration_keyword(word: &str) -> bool {
    matches!(word, "def" | "fn" | "func" | "function")
}

fn is_constant_declaration_keyword(word: &str) -> bool {
    matches!(word, "const" | "static")
}

fn is_all_caps_constant(word: &str) -> bool {
    let mut has_alpha = false;
    let mut has_lower = false;
    for ch in word.chars() {
        if ch.is_ascii_alphabetic() {
            has_alpha = true;
            if ch.is_ascii_lowercase() {
                has_lower = true;
            }
        }
    }
    has_alpha && !has_lower && word.len() > 1
}

fn is_pascal_case(word: &str) -> bool {
    let mut chars = word.chars();
    matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
        && chars.any(|ch| ch.is_ascii_lowercase())
}

fn push_token(out: &mut String, kind: &str, value: &str) {
    out.push_str("<span class=\"tok-");
    out.push_str(kind);
    out.push_str("\">");
    out.push_str(&html_escape(value));
    out.push_str("</span>");
}

fn keywords(language: SyntaxLanguage) -> &'static [&'static str] {
    match language {
        SyntaxLanguage::Ruby => &[
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "private", "protected", "public", "redo", "require", "require_relative",
            "rescue", "retry", "return", "self", "super", "then", "true", "unless", "until",
            "when", "while", "yield",
        ],
        SyntaxLanguage::Python => &[
            "False", "None", "True", "and", "as", "async", "await", "break", "class", "continue",
            "def", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
            "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield",
        ],
        SyntaxLanguage::JavaScript | SyntaxLanguage::TypeScript => &[
            "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
            "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
            "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new",
            "null", "of", "private", "protected", "public", "return", "static", "super", "switch",
            "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while",
            "yield",
        ],
        SyntaxLanguage::Go => &[
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
            "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil",
            "package", "range", "return", "select", "struct", "switch", "true", "type", "var",
        ],
        SyntaxLanguage::Rust => &[
            "Self", "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
            "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match",
            "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super",
            "trait", "true", "type", "unsafe", "use", "where", "while",
        ],
        SyntaxLanguage::Lua => &[
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
            "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
        ],
        SyntaxLanguage::Zig => &[
            "align", "allowzero", "and", "anyerror", "asm", "async", "await", "break", "catch",
            "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export",
            "extern", "false", "fn", "for", "if", "inline", "noalias", "nosuspend", "null", "or",
            "orelse", "packed", "pub", "return", "resume", "struct", "suspend", "switch", "test",
            "threadlocal", "true", "try", "union", "unreachable", "usingnamespace", "var", "volatile",
            "while",
        ],
        SyntaxLanguage::C => &[
            "auto", "bool", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int",
            "long", "NULL", "register", "restrict", "return", "short", "signed", "sizeof", "static",
            "struct", "switch", "true", "typedef", "union", "unsigned", "void", "volatile", "while",
        ],
        SyntaxLanguage::Plain => &[],
    }
}

fn page_href(path: &str, commit: Option<&str>, filter: &str) -> String {
    let mut query = format!("/?path={}", percent_encode(path));
    if let Some(commit) = commit {
        query.push_str("&commit=");
        query.push_str(&percent_encode(commit));
    }
    if !filter.trim().is_empty() {
        query.push_str("&q=");
        query.push_str(&percent_encode(filter));
    }
    query
}

fn directory_href(directory: &str, filter: &str) -> String {
    let directory = normalize_directory(directory);
    let mut query = if directory.is_empty() {
        "/".to_string()
    } else {
        format!("/?dir={}", percent_encode(&directory))
    };
    if !filter.trim().is_empty() {
        query.push_str(if query.contains('?') { "&q=" } else { "?q=" });
        query.push_str(&percent_encode(filter));
    }
    query
}

fn percent_encode(input: &str) -> String {
    let mut out = String::new();
    for byte in input.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn html_escape(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn short_commit(commit: &str) -> String {
    commit.chars().take(12).collect()
}

const STYLE: &str = r#"
  :root {
    color-scheme: light;
    --bg: #f7f8fa;
    --panel: #ffffff;
    --line: #d9dee7;
    --text: #18202f;
    --muted: #657084;
    --covered: rgba(34, 197, 94, 0.08);
    --mutant: rgba(22, 101, 52, 0.24);
    --hazard: #b42318;
    --dark-arm: #374151;
    --dark-arm-bg: rgba(31, 41, 55, 0.22);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 13px/1.4 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  .app {
    display: grid;
    grid-template-columns: minmax(260px, 22vw) 1fr;
    height: 100vh;
    min-height: 0;
    overflow: hidden;
  }
  aside {
    border-right: 1px solid var(--line);
    background: var(--panel);
    min-width: 0;
    min-height: 0;
    display: grid;
    grid-template-rows: auto auto 1fr;
  }
  header { padding: 14px 14px 10px; border-bottom: 1px solid var(--line); }
  h1 { margin: 0; font-size: 15px; letter-spacing: 0; }
  h2 { margin: 0 0 10px; font-size: 13px; letter-spacing: 0; }
  .subtle { color: var(--muted); font-size: 12px; }
  .nav-links { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 6px; }
  .home-link { color: #1d4ed8; font-size: 12px; text-decoration: none; }
  .toolbar { display: flex; gap: 8px; padding: 10px 14px; border-bottom: 1px solid var(--line); }
  input {
    width: 100%;
    min-height: 32px;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
    color: var(--text);
    padding: 6px 8px;
    font: inherit;
  }
  button {
    min-height: 32px;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #eef2f7;
    color: var(--text);
    padding: 0 10px;
    font: inherit;
  }
  .files { min-height: 0; overflow: auto; padding: 6px; }
  .file {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 8px;
    border-radius: 6px;
    padding: 7px 8px;
    color: var(--text);
    text-decoration: none;
  }
  .file:hover, .file.active { background: #eef2f7; }
  .dir-up { color: var(--muted); }
  .file-path {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
  }
  .pills { display: inline-flex; gap: 4px; justify-content: end; align-items: center; }
  .pill {
    border: 1px solid var(--line);
    border-radius: 999px;
    color: var(--muted);
    font-size: 11px;
    padding: 1px 6px;
    min-width: 22px;
    text-align: center;
  }
  .coverage-pill { color: #166534; background: rgba(34, 197, 94, 0.08); }
  main { min-width: 0; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
  .topbar {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(260px, 34vw);
    gap: 12px;
    padding: 12px 16px;
    background: var(--panel);
    border-bottom: 1px solid var(--line);
    align-items: start;
  }
  .title {
    min-width: 0;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 13px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .source-view { display: contents; }
  .mode-radio {
    position: absolute;
    inline-size: 1px;
    block-size: 1px;
    opacity: 0;
    pointer-events: none;
  }
  .source-actions {
    display: grid;
    gap: 8px;
    align-content: start;
  }
  .view-toggle {
    display: inline-grid;
    grid-template-columns: 1fr 1fr;
    justify-self: start;
    border: 1px solid var(--line);
    border-radius: 6px;
    overflow: hidden;
    background: #fff;
  }
  .view-toggle label {
    min-height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0 10px;
    cursor: pointer;
    color: var(--muted);
    font-size: 12px;
    border-right: 1px solid var(--line);
  }
  .view-toggle label:last-child { border-right: 0; }
  #mode-coverage:checked ~ .topbar .view-toggle label[for="mode-coverage"],
  #mode-churn:checked ~ .topbar .view-toggle label[for="mode-churn"] {
    background: #eef2f7;
    color: var(--text);
    font-weight: 600;
  }
  .history {
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
    padding: 6px 8px;
  }
  .history summary { cursor: pointer; color: var(--muted); }
  .history-list { display: grid; gap: 4px; margin-top: 6px; max-height: 180px; overflow: auto; }
  .history-list a { color: var(--text); text-decoration: none; font-size: 12px; }
  .crumbs { display: flex; justify-content: end; gap: 8px; flex-wrap: wrap; }
  .crumbs a { color: #1d4ed8; text-decoration: none; font-size: 12px; }
  .viewer { flex: 1 1 auto; min-width: 0; min-height: 0; overflow: auto; background: #fbfcfd; }
  .dashboard {
    max-width: 1180px;
    padding: 18px;
  }
  .metric-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 10px;
  }
  .metric {
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
    padding: 12px;
  }
  .metric div { color: var(--muted); font-size: 12px; }
  .metric strong { display: block; margin-top: 4px; font-size: 24px; letter-spacing: 0; }
  .metric p { margin: 4px 0 0; color: var(--muted); font-size: 12px; }
  .warning-banner {
    display: grid;
    gap: 8px;
    margin-top: 12px;
  }
  main > .warning-banner {
    margin: 0;
    padding: 10px 16px;
    border-bottom: 1px solid var(--line);
    background: #fff7ed;
  }
  .warning {
    border: 1px solid #fed7aa;
    border-left: 3px solid #f97316;
    border-radius: 6px;
    background: #fff7ed;
    padding: 8px 10px;
  }
  .warning.notice {
    border-color: #bfdbfe;
    border-left-color: #2563eb;
    background: #eff6ff;
  }
  .warning strong { display: block; font-size: 12px; }
  .warning p { margin: 2px 0 0; color: var(--muted); font-size: 12px; }
  .dashboard-section {
    margin-top: 16px;
    border-top: 1px solid var(--line);
    padding-top: 14px;
  }
  .hazard-bar {
    height: 8px;
    max-width: 520px;
    border-radius: 999px;
    background: rgba(180, 35, 24, 0.14);
    overflow: hidden;
  }
  .hazard-bar span {
    display: block;
    height: 100%;
    background: #166534;
  }
  .dashboard-files {
    display: grid;
    max-width: 760px;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
  }
  .dashboard-files a {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 12px;
    padding: 8px 10px;
    border-bottom: 1px solid var(--line);
    color: var(--text);
    text-decoration: none;
  }
  .dashboard-files a:last-child { border-bottom: 0; }
  .dashboard-files .row-label { min-width: 0; display: grid; gap: 2px; }
  .dashboard-files .row-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .dashboard-files small { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }
  .dashboard-files .metric-value { color: #166534; }
  .dashboard-files .hazard-value { color: var(--hazard); }
  .empty-inline { margin: 0; color: var(--muted); }
  .code {
    min-width: max-content;
    padding: 10px 0 30px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.55;
  }
  .row {
    display: grid;
    grid-template-columns: 8px 100px 56px minmax(760px, 1fr);
    min-height: 20px;
  }
  #mode-coverage:checked ~ .viewer .row { background: var(--coverage-bg, transparent); }
  #mode-churn:checked ~ .viewer .row { background: var(--churn-bg, transparent); }
  .ln { color: #8b95a5; text-align: right; padding-right: 10px; user-select: none; }
  .hazard-rail {
    min-width: 8px;
    background: transparent;
  }
  .row.hazard-open .hazard-rail { background: #7f1d1d; }
  .row.hazard-verified .hazard-rail { background: #cbd5e1; }
  .gutter {
    min-width: 100px;
    text-align: right;
    padding-right: 8px;
    user-select: none;
    white-space: nowrap;
    overflow: visible;
  }
  #mode-coverage:checked ~ .viewer .gutter { background: var(--gutter-churn-bg, transparent); }
  #mode-churn:checked ~ .viewer .gutter { background: var(--gutter-coverage-bg, transparent); }
  .bomb {
    cursor: help;
    display: inline-block;
    font-size: 13px;
    line-height: 18px;
    margin-right: 2px;
  }
  .bomb.verified { opacity: 0.35; filter: grayscale(1); }
  .line-meta { display: inline-block; position: relative; }
  .line-meta summary,
  .bug-history summary {
    cursor: pointer;
    color: var(--muted);
    display: inline;
    font-size: 11px;
  }
  .row.dark-arm .line-meta summary {
    color: var(--dark-arm);
    font-weight: 700;
  }
  .dark-arm-span {
    background: var(--dark-arm-bg);
    box-shadow: inset 0 -1px 0 rgba(31, 41, 55, 0.48);
    border-radius: 2px;
  }
  .bug-history { display: inline-block; position: relative; margin-right: 2px; }
  .bug-history summary {
    color: #991b1b;
    font-size: 13px;
    line-height: 18px;
    list-style: none;
  }
  .bug-history summary::-webkit-details-marker { display: none; }
  .line-meta div,
  .bug-history div {
    position: absolute;
    z-index: 2;
    top: 18px;
    left: 0;
    min-width: 220px;
    max-width: 360px;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
    box-shadow: 0 8px 24px rgba(15, 23, 42, 0.16);
    padding: 8px;
    text-align: left;
    white-space: normal;
  }
  .line-meta p, .bug-history p { margin: 0 0 4px; }
  .bug-history strong { color: #991b1b; font-size: 11px; text-transform: uppercase; }
  pre { margin: 0; white-space: pre; padding-right: 24px; }
  .tok-comment { color: #7a8495; font-style: italic; }
  .tok-string { color: #8a4b08; }
  .tok-number { color: #0f766e; }
  .tok-keyword { color: #1d4ed8; font-weight: 600; }
  .tok-type { color: #7c3aed; font-weight: 600; }
  .tok-constant { color: #b45309; font-weight: 600; }
  .tok-function { color: #0369a1; }
  .tok-property { color: #64748b; }
  .empty { padding: 24px; color: var(--muted); }
  @media (max-width: 800px) {
    .app { grid-template-columns: 1fr; grid-template-rows: 36vh 64vh; }
    aside { border-right: 0; border-bottom: 1px solid var(--line); }
    .topbar { grid-template-columns: 1fr; }
    .row { grid-template-columns: 8px 86px 48px minmax(620px, 1fr); }
    .gutter { min-width: 86px; padding-right: 6px; }
  }
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        CommitMetadata, CrashEvent, Event, EventType, HazardEvent, LogicalUnit, TestExposureEvent,
        UnitKind,
    };
    use tempfile::tempdir;

    #[test]
    fn source_payload_includes_coverage_mutation_hazards_and_versions() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("zig/runtime")).unwrap();
        fs::write(
            dir.path().join("zig/runtime/a.zig"),
            "fn run() void {\n    value.store(1, .release);\n}\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "zig/runtime/a.zig",
            1,
            1,
            3,
            "fn run",
            "fn run() void {\nvalue.store(1, .release);\n}",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "add hazard".into(),
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                event_type: EventType::Change,
                path: "zig/runtime/a.zig".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "zig/runtime/a.zig".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "zig/runtime/a-loom-test.zig:1".into(),
                test_type: "loom".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("invariant".into()),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_hazard_event(&HazardEvent {
                unit_id: unit.id,
                language: "zig".into(),
                hazard_type: "zig_loom_atomic".into(),
                required_evidence: "loom".into(),
                path: "zig/runtime/a.zig".into(),
                line: 2,
                symbol: Some("run".into()),
                source: "value.store(1, .release);".into(),
                detected_at_hash: "abc".into(),
                is_active: true,
                payload_json: "{}".into(),
            })
            .unwrap();

        let payload = source_payload(&storage, dir.path(), "zig/runtime/a.zig", None).unwrap();
        let line = payload.annotations.iter().find(|line| line.line == 2).unwrap();

        assert_eq!(payload.lines.len(), 3);
        assert_eq!(payload.versions.len(), 1);
        assert!(line.covered);
        assert!(line.mutant_tested);
        assert_eq!(line.test_types, vec!["loom"]);
        assert_eq!(line.hazards.len(), 1);
        assert!(line.hazards[0].verified);
    }

    #[test]
    fn source_payload_can_overlay_dark_arm_json() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  1\nend\n").unwrap();
        let overlay = dir.path().join("overlay.json");
        fs::write(
            &overlay,
            r#"{"findings":[{"file":"src/demo.rb","line":2,"category":"genuine gap"}]}"#,
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        let overlays = UiOverlays::load(&[overlay]).unwrap();

        let payload =
            source_payload_with_overlays(&storage, dir.path(), "src/demo.rb", None, &overlays)
                .unwrap();
        let line = payload.annotations.iter().find(|line| line.line == 2).unwrap();

        assert_eq!(line.dark_arms, vec!["genuine gap"]);
    }

    #[test]
    fn source_payload_can_overlay_dark_arm_sarif() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  else\nend\n").unwrap();
        let overlay = dir.path().join("overlay.sarif");
        fs::write(
            &overlay,
            r#"{
              "version":"2.1.0",
              "runs":[{
                "tool":{"driver":{"name":"SlopCop","rules":[]}},
                "results":[{
                  "ruleId":"slopcop.dark-arm.genuine",
                  "message":{"text":"dark arm: genuine"},
                  "locations":[{
                    "physicalLocation":{
                      "artifactLocation":{"uri":"src/demo.rb"},
                      "region":{"startLine":2,"startColumn":3,"endLine":2,"endColumn":7}
                    }
                  }],
                  "properties":{
                    "dark_arm":true,
                    "category":"dark arm: genuine",
                    "file":"src/demo.rb",
                    "line":2
                  }
                }],
                "properties":{
                  "slopcop.dark_arms":{
                    "format":"slopcop.dark-arms.v1",
                    "dark_arms":[{
                      "file":"src/demo.rb",
                      "line":2,
                      "category":"dark arm: genuine"
                    }]
                  }
                }
              }]
            }"#,
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\nelse\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        let overlays = UiOverlays::load(&[overlay]).unwrap();

        let payload =
            source_payload_with_overlays(&storage, dir.path(), "src/demo.rb", None, &overlays)
                .unwrap();
        let line = payload.annotations.iter().find(|line| line.line == 2).unwrap();

        assert_eq!(line.dark_arms, vec!["dark arm: genuine"]);
        assert_eq!(line.dark_arms.len(), 1);
        assert_eq!(line.dark_arm_spans[0].span, Some([2, 2, 2, 6]));
    }

    #[test]
    fn source_payload_uses_exact_line_coverage_when_present() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  1\nend\n").unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id,
                commit_hash: "abc".into(),
                event_type: EventType::Change,
                path: "src/demo.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 3,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "src/demo.rb", 1, 0)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "src/demo.rb", 2, 1)
            .unwrap();

        let payload = source_payload(&storage, dir.path(), "src/demo.rb", None).unwrap();
        let line_one = payload.annotations.iter().find(|line| line.line == 1).unwrap();
        let line_two = payload.annotations.iter().find(|line| line.line == 2).unwrap();

        assert!(!line_one.covered);
        assert_eq!(line_one.line_hits, Some(0));
        assert!(line_two.covered);
        assert_eq!(line_two.line_hits, Some(1));
    }

    #[test]
    fn source_payload_adds_semantic_churn_and_decayed_bug_history() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  1\n  2\nend\n").unwrap();
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            4,
            "def run",
            "def run\n1\n2\nend",
        );
        storage.upsert_logical_unit(&unit, 1).unwrap();
        for (hash, event_type, start_line, end_line, semantic_change, timestamp) in [
            ("comment", EventType::Change, 2, 2, false, 10),
            ("move", EventType::Move, 1, 4, true, 20),
            ("change", EventType::Change, 2, 2, true, 30),
            ("fix", EventType::Fix, 1, 4, true, 40),
        ] {
            storage
                .insert_event(&Event {
                    unit_id: unit.id.clone(),
                    commit_hash: hash.into(),
                    event_type,
                    path: "src/demo.rb".into(),
                    name: "run".into(),
                    start_line,
                    end_line,
                    semantic_change,
                    lines_added: 1,
                    lines_removed: 0,
                    timestamp,
                })
                .unwrap();
        }
        storage
            .insert_crash_event(&CrashEvent {
                unit_id: unit.id,
                commit_hash: "crash".into(),
                timestamp: 50,
                error_class: "RuntimeError".into(),
                provider_id: "evt-1".into(),
                is_verified: true,
                path: "src/demo.rb".into(),
                line: 2,
                function: "run".into(),
            })
            .unwrap();

        let payload = source_payload(&storage, dir.path(), "src/demo.rb", None).unwrap();
        let line_one = payload.annotations.iter().find(|line| line.line == 1).unwrap();
        let line_two = payload.annotations.iter().find(|line| line.line == 2).unwrap();

        assert_eq!(line_one.semantic_churn_events, 1);
        assert_eq!(line_two.semantic_churn_events, 2);
        assert_eq!(
            line_one
                .bug_events
                .iter()
                .map(|event| event.event_type.as_str())
                .collect::<Vec<_>>(),
            vec!["fix"]
        );
        assert_eq!(
            line_two
                .bug_events
                .iter()
                .map(|event| event.event_type.as_str())
                .collect::<Vec<_>>(),
            vec!["fix", "crash"]
        );
        assert!(line_two.bug_weight > line_one.bug_weight);
    }

    #[test]
    fn source_view_renders_css_only_coverage_and_churn_modes() {
        let payload = UiSourcePayload {
            path: "src/demo.rb".into(),
            commit: None,
            lines: vec!["def run".into(), "  maybe_work".into(), "end".into()],
            versions: Vec::new(),
            annotations: vec![UiLineAnnotation {
                line: 2,
                covered: true,
                mutant_tested: false,
                test_types: vec!["unit".to_string()],
                distinct_tests: 1,
                mutant_verified_tests: 0,
                mutant_killed_tests: 0,
                line_hits: Some(3),
                line_coverage: Some(100.0),
                mutant_coverage: None,
                dark_arms: Vec::new(),
                dark_arm_spans: Vec::new(),
                hazards: vec![UiHazard {
                    hazard_type: "zig_loom_atomic".to_string(),
                    required_evidence: "loom".to_string(),
                    source: "atomic store".to_string(),
                    evidence_present: false,
                    verified: false,
                }],
                semantic_churn: 0.70,
                semantic_churn_events: 3,
                bug_weight: 0.50,
                bug_events: vec![UiBugEvent {
                    event_type: "fix".to_string(),
                    commit_hash: "abcdef1234567890".to_string(),
                    timestamp: 100,
                    path: "src/demo.rb".to_string(),
                    line: 2,
                    label: "fix crash".to_string(),
                    weight: 0.50,
                }],
            }],
            warnings: Vec::new(),
        };

        let html = render_source_view(&payload, "");

        assert!(html.contains("id=\"mode-coverage\" checked"));
        assert!(html.contains("id=\"mode-churn\""));
        assert!(html.contains("Coverage Quality"));
        assert!(html.contains("Churn Heat"));
        assert!(html.contains("hazard-rail"));
        assert!(html.contains("hazard-open"));
        assert!(html.contains("bug-history"));
        assert!(html.contains("decayed bug/fix history"));
        assert!(html.contains("--coverage-bg:rgba(34, 197, 94, 0.08)"));
        assert!(html.contains("--churn-bg:rgba(248, 113, 113"));
        assert!(html.contains("--gutter-coverage-bg:rgba(34, 197, 94, 0.18)"));
        assert!(html.contains("--gutter-churn-bg:rgba(248, 113, 113"));
    }

    #[test]
    fn dashboard_summary_tracks_current_coverage_hazards_and_test_strength() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "zig/runtime/a.zig",
            1,
            1,
            3,
            "fn run",
            "fn run() void {\nvalue.store(1, .release);\n}",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_metadata(&CommitMetadata {
                hash: "abc".into(),
                message: "coverage".into(),
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                event_type: EventType::Change,
                path: "zig/runtime/a.zig".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 3,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "zig/runtime/a.zig", 1, 1)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "zig/runtime/a.zig", 2, 0)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "zig/runtime/a.zig", 3, 2)
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "zig/runtime/a.zig".into(),
                function: Some("run".into()),
                line: Some(1),
                branch_id: None,
                test_id: "loom-test".into(),
                test_type: "loom".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("invariant".into()),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "zig/runtime/a.zig".into(),
                function: Some("run".into()),
                line: Some(3),
                branch_id: None,
                test_id: "unit-test".into(),
                test_type: "unit".into(),
                mutation_status: None,
                mutation_kind: None,
                is_mutation_verified: false,
                is_mutation_killed: false,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "zig/runtime/a.zig".into(),
                function: Some("run".into()),
                line: Some(3),
                branch_id: None,
                test_id: "integration-test".into(),
                test_type: "integration".into(),
                mutation_status: None,
                mutation_kind: None,
                is_mutation_verified: false,
                is_mutation_killed: false,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_hazard_event(&HazardEvent {
                unit_id: unit.id,
                language: "zig".into(),
                hazard_type: "zig_loom_atomic".into(),
                required_evidence: "loom".into(),
                path: "zig/runtime/a.zig".into(),
                line: 1,
                symbol: Some("run".into()),
                source: "value.store".into(),
                detected_at_hash: "abc".into(),
                is_active: true,
                payload_json: "{}".into(),
            })
            .unwrap();

        let dashboard = dashboard_summary(&storage).unwrap();

        assert_eq!(dashboard.tracked_lines, 3);
        assert_eq!(dashboard.covered_lines, 2);
        assert_eq!(dashboard.active_hazards, 1);
        assert_eq!(dashboard.covered_hazards, 1);
        assert_eq!(dashboard.mutant_killed_covered_lines, 1);
        assert_eq!(dashboard.stochastic_mutant_killed_covered_lines, 0);
        assert_eq!(dashboard.invariant_mutant_killed_covered_lines, 1);
        assert_eq!(dashboard.multi_type_covered_lines, 1);
        assert_eq!(dashboard.coverage_percent, 200.0 / 3.0);
        assert!(dashboard.warnings.is_empty());
    }

    #[test]
    fn dashboard_summary_warns_about_stale_verification_and_reopened_crashes() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "add".into(),
                event_type: EventType::Change,
                path: "src/a.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 3,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "cov".into(),
                timestamp: 20,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "spec/a_spec.rb:1".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "fix".into(),
                event_type: EventType::Fix,
                path: "src/a.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 0,
                timestamp: 30,
            })
            .unwrap();
        storage
            .insert_crash_event(&CrashEvent {
                unit_id: unit.id,
                commit_hash: "crash".into(),
                timestamp: 40,
                error_class: "RuntimeError".into(),
                provider_id: "evt-1".into(),
                is_verified: true,
                path: "src/a.rb".into(),
                line: 2,
                function: "run".into(),
            })
            .unwrap();

        let dashboard = dashboard_summary(&storage).unwrap();
        let labels = dashboard
            .warnings
            .iter()
            .map(|warning| warning.label.as_str())
            .collect::<Vec<_>>();

        assert!(labels.contains(&"Coverage data is stale"));
        assert!(labels.contains(&"Mutation verification is stale"));
        assert!(labels.contains(&"Fixes have reopened crashes"));
    }

    #[test]
    fn directory_index_groups_immediate_children() {
        let files = vec![
            UiFile {
                path: "src/a.rb".into(),
                units: 1,
                hazards: 2,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 3,
                mutant_killed_tests: 4,
                tracked_lines: 10,
                covered_lines: 5,
                line_coverage: 50.0,
                mutant_coverage: 25.0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            },
            UiFile {
                path: "src/internal/b.rb".into(),
                units: 2,
                hazards: 1,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 5,
                mutant_killed_tests: 6,
                tracked_lines: 30,
                covered_lines: 15,
                line_coverage: 75.0,
                mutant_coverage: 50.0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            },
            UiFile {
                path: "zig/c.zig".into(),
                units: 3,
                hazards: 7,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 8,
                mutant_killed_tests: 9,
                tracked_lines: 4,
                covered_lines: 4,
                line_coverage: 100.0,
                mutant_coverage: 0.0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            },
        ];

        let root = directory_index(&files, "");
        assert_eq!(root.iter().map(|directory| directory.path.as_str()).collect::<Vec<_>>(), vec!["src", "zig"]);
        assert_eq!(root[0].files, 2);
        assert_eq!(root[0].hazards, 3);
        assert_eq!(root[0].tracked_lines, 40);
        assert_eq!(root[0].covered_lines, 20);
        assert_eq!(root[0].line_coverage, 50.0);

        let src = directory_index(&files, "src");
        assert_eq!(src.len(), 1);
        assert_eq!(src[0].path, "src/internal");
        assert_eq!(files_in_directory(&files, "src")[0].path, "src/a.rb");
    }

    #[test]
    fn dashboard_summary_can_scope_to_directory() {
        let storage = Storage::open_memory().unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 1, 1)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 2, 0)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "zig/a.zig", 1, 1)
            .unwrap();

        let root = dashboard_summary_for_directory(&storage, "").unwrap();
        let src = dashboard_summary_for_directory(&storage, "src").unwrap();
        let zig = dashboard_summary_for_directory(&storage, "zig").unwrap();

        assert_eq!(root.tracked_lines, 3);
        assert_eq!(root.covered_lines, 2);
        assert_eq!(src.tracked_lines, 2);
        assert_eq!(src.covered_lines, 1);
        assert_eq!(src.coverage_percent, 50.0);
        assert_eq!(zig.tracked_lines, 1);
        assert_eq!(zig.covered_lines, 1);
    }

    #[test]
    fn refreshed_ui_summaries_drive_file_index_and_dashboard() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            2,
            "def run",
            "def run\n  1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 1, 1)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 2, 0)
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id,
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(1),
                branch_id: None,
                test_id: "spec/a_spec.rb:1".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();

        storage.refresh_ui_summaries().unwrap();

        let files = file_index(&storage).unwrap();
        assert_eq!(files.len(), 1);
        assert!(files[0].read_model);
        assert_eq!(files[0].tracked_lines, 2);
        assert_eq!(files[0].covered_lines, 1);
        assert_eq!(files[0].mutant_killed_covered_lines, 1);

        let dashboard = dashboard_summary(&storage).unwrap();
        assert_eq!(dashboard.tracked_lines, 2);
        assert_eq!(dashboard.covered_lines, 1);
        assert_eq!(dashboard.mutant_killed_covered_percent, 100.0);
    }

    #[test]
    fn coverage_scope_reads_codecov_paths_and_ignores() {
        let dir = tempdir().unwrap();
        fs::write(
            dir.path().join("codecov.yml"),
            r#"
ignore:
  - "gems/nil-kill/"
  - "**/*-test.zig"
flags:
  ruby:
    paths:
      - src/
  zig:
    paths:
      - zig/
"#,
        )
        .unwrap();

        let scope = CoverageScope::from_repo(dir.path());

        assert!(scope.allows("src/ast/type.rb"));
        assert!(scope.allows("zig/runtime/scheduler.zig"));
        assert!(!scope.allows("gems/decomplex/lib/decomplex.rb"));
        assert!(!scope.allows("zig/runtime/scheduler-test.zig"));
        assert!(!scope.allows("gems/nil-kill/lib/nil_kill.rb"));
    }

    #[test]
    fn dashboard_summary_respects_coverage_scope() {
        let storage = Storage::open_memory().unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 1, 1)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "src/a.rb", 2, 1)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "gems/a.rb", 1, 0)
            .unwrap();
        storage
            .record_coverage_line("abc", 10, "zig/a-test.zig", 1, 0)
            .unwrap();
        let scope = CoverageScope {
            include_prefixes: vec!["src".into(), "zig".into()],
            ignore_patterns: vec!["**/*-test.zig".into()],
        };

        let dashboard = dashboard_summary_for_directory_with_scope(&storage, "", &scope).unwrap();

        assert_eq!(dashboard.tracked_lines, 2);
        assert_eq!(dashboard.covered_lines, 2);
        assert_eq!(dashboard.coverage_percent, 100.0);
    }

    #[test]
    fn visual_coverage_paints_multiline_continuations_without_counting_hits() {
        let mut annotations = vec![UiLineAnnotation {
            line: 1,
            covered: true,
            mutant_tested: false,
            test_types: Vec::new(),
            distinct_tests: 0,
            mutant_verified_tests: 0,
            mutant_killed_tests: 0,
            line_hits: Some(1),
            line_coverage: None,
            mutant_coverage: None,
            dark_arms: Vec::new(),
            dark_arm_spans: Vec::new(),
            hazards: Vec::new(),
            semantic_churn: 0.0,
            semantic_churn_events: 0,
            bug_weight: 0.0,
            bug_events: Vec::new(),
        }];
        let lines = vec![
            "result = call(".to_string(),
            "  first,".to_string(),
            "  second".to_string(),
            ")".to_string(),
            "other".to_string(),
        ];

        paint_statement_continuations(&lines, &mut annotations);

        let covered = annotations
            .iter()
            .filter(|annotation| annotation.covered)
            .map(|annotation| annotation.line)
            .collect::<Vec<_>>();
        assert_eq!(covered, vec![1, 2, 3, 4]);
        assert_eq!(
            annotations
                .iter()
                .find(|annotation| annotation.line == 2)
                .unwrap()
                .line_hits,
            None
        );
        let line_two = annotations
            .iter()
            .find(|annotation| annotation.line == 2)
            .unwrap();
        assert!(
            render_line_details(line_two)
                .contains("covered as part of a multi-line statement")
        );
    }

    #[test]
    fn syntax_highlighter_marks_basic_tokens() {
        let html = highlight_source_line("src/demo.rb", "def run # hello");

        assert!(html.contains("<span class=\"tok-keyword\">def</span>"));
        assert!(html.contains("<span class=\"tok-comment\"># hello</span>"));
    }

    #[test]
    fn dark_arm_highlighter_wraps_only_the_arm_span() {
        let annotation = UiLineAnnotation {
            line: 1,
            covered: true,
            mutant_tested: false,
            test_types: Vec::new(),
            distinct_tests: 0,
            mutant_verified_tests: 0,
            mutant_killed_tests: 0,
            line_hits: Some(1),
            line_coverage: None,
            mutant_coverage: None,
            dark_arms: vec!["dark arm: else".to_string()],
            dark_arm_spans: vec![UiDarkArm {
                label: "dark arm: else".to_string(),
                span: Some([1, 4, 1, 8]),
            }],
            hazards: Vec::new(),
            semantic_churn: 0.0,
            semantic_churn_events: 0,
            bug_weight: 0.0,
            bug_events: Vec::new(),
        };

        let html =
            highlight_source_line_with_dark_arms("src/demo.rb", 1, "    else", Some(&annotation));

        assert!(html.starts_with("    <span class=\"dark-arm-span\""));
        assert!(html.contains("<span class=\"tok-keyword\">else</span>"));
        assert_eq!(html.matches("dark-arm-span").count(), 1);
    }

    #[test]
    fn overlay_attaches_multiline_dark_arm_spans_to_each_covered_line() {
        let mut overlays = UiOverlays::default();
        collect_overlay_value(
            &serde_json::json!({
                "path": "src/demo.rb",
                "line": 1,
                "category": "dark arm: else",
                "arm_span": [1, 4, 2, 3]
            }),
            &mut overlays,
        );
        let mut lines = BTreeMap::new();

        apply_overlays("src/demo.rb", &overlays, &mut lines);

        assert_eq!(lines.get(&1).unwrap().dark_arms, vec!["dark arm: else"]);
        assert_eq!(lines.get(&1).unwrap().dark_arm_spans.len(), 1);
        assert!(lines.get(&2).unwrap().dark_arms.is_empty());
        assert_eq!(lines.get(&2).unwrap().dark_arm_spans.len(), 1);
    }

    #[test]
    fn syntax_highlighter_marks_ruby_classes_and_constants() {
        let html = highlight_source_line("src/demo.rb", "class Widget; MAX_SIZE = Foo.new(); end");

        assert!(html.contains("<span class=\"tok-type\">Widget</span>"));
        assert!(html.contains("<span class=\"tok-constant\">MAX_SIZE</span>"));
        assert!(html.contains("<span class=\"tok-type\">Foo</span>"));
        assert!(html.contains("<span class=\"tok-function\">new</span>"));
    }

    #[test]
    fn syntax_highlighter_marks_zig_types_functions_and_constants() {
        let html = highlight_source_line(
            "zig/runtime/demo.zig",
            "pub const Scheduler = struct { fn run(MAX_SIZE: usize) void {} };",
        );

        assert!(html.contains("<span class=\"tok-keyword\">const</span>"));
        assert!(html.contains("<span class=\"tok-type\">Scheduler</span>"));
        assert!(html.contains("<span class=\"tok-function\">run</span>"));
        assert!(html.contains("<span class=\"tok-constant\">MAX_SIZE</span>"));
    }
}
