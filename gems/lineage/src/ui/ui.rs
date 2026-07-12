use crate::extract::{
    is_production_source_path, BoundaryExtractor, HeuristicExtractor, SourceFilter,
};
use crate::architecture::{architecture_search, node_neighborhood, owner_inventory, state_access};
use crate::git::GitProvider;
use crate::model::BlobFile;
use crate::storage::Storage;
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use askama::Template;
use axum::body::Body;
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::header::{self, HeaderValue};
use axum::http::{Response, StatusCode};
use axum::response::{Html, IntoResponse};
use axum::routing::get;
use axum::{Json, Router};
use git2::{BlameOptions, Oid, Repository};
use rusqlite::{params, OptionalExtension};
use rust_embed::RustEmbed;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;
use tower_http::set_header::SetResponseHeaderLayer;
use tower_http::trace::TraceLayer;

mod controllers;

const ARCHITECTURE_SYMBOLS_FOR_PATH_SQL: &str =
    include_str!("../../sql/ui/architecture_symbols_for_path.sql");
const ARCHITECTURE_OWNER_BY_NAME_SQL: &str =
    include_str!("../../sql/ui/architecture_owner_by_name.sql");

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverageScope {
    include_prefixes: Vec<String>,
    ignore_patterns: Vec<String>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq)]
struct LineCoverageStats {
    tracked: i64,
    covered: i64,
    partial: i64,
    coverage_percent_sum: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiFile {
    pub path: String,
    pub units: i64,
    pub hazards: i64,
    pub sarif_findings: i64,
    pub dark_arm_findings: i64,
    pub evidence_covered_hazards: i64,
    pub covered_hazards: i64,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
    pub tracked_lines: i64,
    pub covered_lines: i64,
    pub partial_lines: i64,
    pub line_coverage: f64,
    pub mutant_coverage: f64,
    pub mutant_verified_covered_lines: i64,
    pub mutant_killed_covered_lines: i64,
    pub stochastic_mutant_verified_covered_lines: i64,
    pub stochastic_mutant_killed_covered_lines: i64,
    pub invariant_mutant_verified_covered_lines: i64,
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
    pub evidence_covered_hazards: i64,
    pub covered_hazards: i64,
    pub sarif_findings: i64,
    pub dark_arm_findings: i64,
    pub partial_lines: i64,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
    pub tracked_lines: i64,
    pub covered_lines: i64,
    pub mutant_killed_covered_lines: i64,
    pub multi_type_covered_lines: i64,
    pub line_coverage: f64,
    pub mutant_coverage: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct UiBranchContext {
    branch: String,
    commit: String,
}

#[derive(Debug, Clone, PartialEq)]
struct UiCoverageContext {
    path: String,
    tracked_lines: i64,
    covered_lines: i64,
    partial_lines: i64,
    missed_lines: i64,
    multi_type_lines: i64,
    mutant_backed_lines: i64,
    stochastic_mutant_backed_lines: i64,
    invariant_mutant_backed_lines: i64,
    coverage_percent: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct LineQualityBar {
    tracked_lines: i64,
    covered_lines: i64,
    partial_lines: i64,
    multi_type_lines: i64,
    mutant_backed_lines: i64,
    coverage_percent: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct LineQualitySegments {
    multi: f64,
    covered: f64,
    partial: f64,
    missed: f64,
    mutant_multi: f64,
    mutant_covered: f64,
    mutant_partial: f64,
    mutant_gap: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CoverageSort {
    Path,
    Total,
    Covered,
    Partial,
    Missed,
    Percent,
}

impl CoverageSort {
    fn parse(value: &str) -> Self {
        match value {
            "total" => Self::Total,
            "covered" => Self::Covered,
            "partial" => Self::Partial,
            "missed" => Self::Missed,
            "percent" => Self::Percent,
            _ => Self::Path,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Path => "path",
            Self::Total => "total",
            Self::Covered => "covered",
            Self::Partial => "partial",
            Self::Missed => "missed",
            Self::Percent => "percent",
        }
    }
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

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiFinding {
    pub source: String,
    pub tool: String,
    pub rule_id: String,
    pub level: String,
    pub message: String,
    pub category: String,
    pub tier: Option<i64>,
    pub span: Option<[u32; 4]>,
    pub commit: String,
    pub stale: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FirstPartyFindingTool {
    Decomplex,
    SqlCov,
    Espalier,
    NilKill,
    Lint,
}

impl FirstPartyFindingTool {
    fn all() -> &'static [Self] {
        &[Self::Decomplex, Self::SqlCov, Self::Espalier, Self::NilKill, Self::Lint]
    }

    fn key(self) -> &'static str {
        match self {
            Self::Decomplex => "decomplex",
            Self::SqlCov => "sql-cov",
            Self::Espalier => "espalier",
            Self::NilKill => "nil-kill",
            Self::Lint => "lint",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::Decomplex => "Decomplex",
            Self::SqlCov => "SQL-COV",
            Self::Espalier => "Espalier",
            Self::NilKill => "Nil-Kill",
            Self::Lint => "Lint",
        }
    }

    fn icon_family(self) -> &'static str {
        match self {
            Self::Lint => "fa-regular",
            _ => "fa-solid",
        }
    }

    fn icon_class(self) -> &'static str {
        match self {
            Self::Decomplex | Self::SqlCov => "fa-puzzle-piece",
            Self::Espalier => "fa-tree",
            Self::NilKill => "fa-skull",
            Self::Lint => "fa-note-sticky",
        }
    }

    fn panel_class(self) -> &'static str {
        match self {
            Self::Decomplex => "decomplex-panel",
            Self::SqlCov => "sql-cov-panel",
            Self::Espalier => "espalier-panel",
            Self::NilKill => "nil-kill-panel",
            Self::Lint => "lint-panel",
        }
    }

    fn toggle_class(self) -> &'static str {
        match self {
            Self::Decomplex => "decomplex-toggle",
            Self::SqlCov => "sql-cov-toggle",
            Self::Espalier => "espalier-toggle",
            Self::NilKill => "nil-kill-toggle",
            Self::Lint => "lint-toggle",
        }
    }

    fn open_class(self) -> &'static str {
        match self {
            Self::Decomplex => "decomplex-open",
            Self::SqlCov => "sql-cov-open",
            Self::Espalier => "espalier-open",
            Self::NilKill => "nil-kill-open",
            Self::Lint => "lint-open",
        }
    }

    fn control_class(self) -> &'static str {
        match self {
            Self::Decomplex => "decomplex-finding",
            Self::SqlCov => "sql-cov-finding",
            Self::Espalier => "espalier-finding",
            Self::NilKill => "nil-kill-finding",
            Self::Lint => "lint-finding",
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiSourceSymbol {
    pub kind: String,
    pub name: String,
    pub start_line: u32,
    pub end_line: u32,
    pub effect_known: bool,
    pub impure: bool,
    pub effect_summary: Vec<String>,
    pub hotspot_score: f64,
    pub hotspot_level: String,
    pub sarif_findings: i64,
    pub dark_arms: i64,
    pub hazards: i64,
    pub unverified_hazards: i64,
    pub bug_weight: f64,
    pub semantic_churn: f64,
    pub architecture_id: Option<String>,
    pub architecture_owner_id: Option<String>,
    pub architecture_pressure: f64,
    pub architecture_band: String,
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

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiLineBlame {
    pub line: u32,
    pub commit_hash: String,
    pub ordinal: usize,
    pub total_commits: usize,
    pub timestamp: i64,
    pub author: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiEffectSpan {
    pub kind: String,
    pub label: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiLineAnnotation {
    pub line: u32,
    pub covered: bool,
    pub is_partial: bool,
    pub mutant_tested: bool,
    pub test_types: Vec<String>,
    pub distinct_tests: i64,
    pub mutant_verified_tests: i64,
    pub mutant_killed_tests: i64,
    pub stochastic_mutant_verified_tests: i64,
    pub invariant_mutant_verified_tests: i64,
    pub line_hits: Option<u32>,
    pub line_coverage: Option<f64>,
    pub mutant_coverage: Option<f64>,
    pub dark_arms: Vec<String>,
    pub dark_arm_spans: Vec<UiDarkArm>,
    pub effect_spans: Vec<UiEffectSpan>,
    pub findings: Vec<UiFinding>,
    pub hazards: Vec<UiHazard>,
    pub test_type_counts: BTreeMap<String, i64>,
    pub semantic_churn: f64,
    pub semantic_churn_events: i64,
    pub bug_weight: f64,
    pub bug_events: Vec<UiBugEvent>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiUnitHotspot {
    pub path: String,
    pub name: String,
    pub kind: String,
    pub start_line: u32,
    pub score: f64,
    pub risk_score: f64,
    pub sarif_findings: i64,
    pub dark_arms: i64,
    pub hazards: i64,
    pub fixes: i64,
    pub changes: i64,
    pub mutant_killed_tests: i64,
    pub mutant_verified_tests: i64,
    pub distinct_tests: i64,
    pub test_types: String,
    pub line_coverage: f64,
    pub integration_coverage: f64,
    pub is_hard_gated: bool,
    pub reopened_count: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UiAnalyzerHealth {
    pub analyzer: String,
    pub status: String,
    pub detail: String,
    pub scoped_findings: i64,
    pub total_findings: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiReviewNextItem {
    pub path: String,
    pub start_line: u32,
    pub title: String,
    pub detail: String,
    pub score: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiArchitectureRisk {
    pub path: String,
    pub owner: String,
    pub owner_kind: String,
    pub start_line: u32,
    pub score: f64,
    pub findings: i64,
    pub states: i64,
    pub functions: i64,
    pub impure_functions: i64,
    pub privacy_candidates: i64,
    pub architecture_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiComplexityFunction {
    pub name: String,
    pub path: String,
    pub start_line: u32,
    pub runtime_complexity: String,
    pub space_complexity: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommentFold {
    id: usize,
    start_line: u32,
    end_line: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommentFoldLine {
    id: usize,
    start_line: u32,
    end_line: u32,
    is_start: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FunctionFold {
    id: usize,
    start_line: u32,
    end_line: u32,
    is_private: bool,
    closing_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FunctionFoldLine {
    id: usize,
    start_line: u32,
    end_line: u32,
    is_start: bool,
    is_private: bool,
    closing_token: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiSourcePayload {
    pub path: String,
    pub commit: Option<String>,
    pub lines: Vec<String>,
    pub versions: Vec<UiVersion>,
    pub symbols: Vec<UiSourceSymbol>,
    pub blame: Vec<UiLineBlame>,
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
    pub sarif_findings: i64,
    pub new_findings: i64,
    pub resolved_findings: i64,
    pub persisted_findings: i64,
    pub evidence_covered_hazards: i64,
    pub hazard_evidence_percent: f64,
    pub covered_hazards: i64,
    pub hazard_coverage_percent: f64,
    pub mutant_verified_covered_lines: i64,
    pub mutant_verified_covered_percent: f64,
    pub mutant_killed_covered_lines: i64,
    pub mutant_killed_covered_percent: f64,
    pub stochastic_mutant_verified_covered_lines: i64,
    pub stochastic_mutant_verified_covered_percent: f64,
    pub stochastic_mutant_killed_covered_lines: i64,
    pub stochastic_mutant_killed_covered_percent: f64,
    pub invariant_mutant_verified_covered_lines: i64,
    pub invariant_mutant_verified_covered_percent: f64,
    pub invariant_mutant_killed_covered_lines: i64,
    pub invariant_mutant_killed_covered_percent: f64,
    pub multi_type_covered_lines: i64,
    pub multi_type_covered_percent: f64,
    pub files_with_coverage: i64,
    pub top_hazard_files: Vec<UiFile>,
    pub top_units: Vec<UiUnitHotspot>,
    pub review_next: Vec<UiReviewNextItem>,
    pub test_next_units: Vec<UiUnitHotspot>,
    pub top_architecture_risks: Vec<UiArchitectureRisk>,
    pub top_complexity_functions: Vec<UiComplexityFunction>,
    pub analyzer_health: Vec<UiAnalyzerHealth>,
    pub warnings: Vec<UiWarning>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct DashboardLineCounts {
    tracked: i64,
    covered: i64,
    mutant_verified: i64,
    mutant_killed: i64,
    stochastic_mutant_verified: i64,
    stochastic_mutant_killed: i64,
    invariant_mutant_verified: i64,
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

#[derive(RustEmbed)]
#[folder = "src/ui/"]
struct EmbeddedUi;

#[derive(Template)]
#[template(path = "index.html")]
struct IndexPageTemplate<'a> {
    title: &'a str,
    body: &'a str,
}

#[derive(Template)]
#[template(path = "app.html")]
struct AppTemplate<'a> {
    source_sidebar: bool,
    sidebar: &'a str,
    main: &'a str,
}

#[derive(Template)]
#[template(path = "dashboard_sidebar.html")]
struct DashboardSidebarTemplate<'a> {
    _summary: &'a str,
    _nav: &'a str,
    current_directory: &'a str,
    show_directory_input: bool,
    filter: &'a str,
    search_options: &'a str,
    files: &'a str,
}

#[derive(Template)]
#[template(path = "source_sidebar.html")]
struct SourceSidebarTemplate<'a> {
    _path: &'a str,
    _nav: &'a str,
    outline: &'a str,
    show_empty_outline: bool,
}

#[derive(Template)]
#[template(path = "source_unavailable.html")]
struct SourceUnavailableTemplate<'a> {
    error: &'a str,
}

#[derive(Template)]
#[template(path = "dashboard.html")]
struct DashboardTemplate<'a> {
    branch_context: &'a str,
    warnings: &'a str,
    active_hazards: &'a str,
    finding_changes: &'a str,
    review_next: &'a str,
    test_next: &'a str,
    highest_hazard_files: &'a str,
    highest_risk_units: &'a str,
    highest_architecture_risks: &'a str,
    highest_complexity_functions: &'a str,
    code_tree_heading: &'a str,
    code_tree: &'a str,
}

#[derive(Template)]
#[template(path = "dashboard_disclosure.html")]
struct DashboardDisclosureTemplate<'a> {
    id: &'a str,
    open: bool,
    body: &'a str,
}

#[derive(Template)]
#[template(path = "dashboard_ratio_bar.html")]
struct DashboardRatioBarTemplate<'a> {
    label: &'a str,
    detail: &'a str,
    bar: &'a str,
    total: i64,
    total_label: &'a str,
    covered: i64,
    covered_label: &'a str,
}

#[derive(Template)]
#[template(path = "dashboard_hazard_files.html")]
struct DashboardHazardFilesTemplate<'a> {
    files: &'a [DashboardHazardFileItem],
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DashboardHazardFileItem {
    href: String,
    path: String,
    detail: String,
    hazards: i64,
}

#[derive(Template)]
#[template(path = "hotspot_list.html")]
struct HotspotListTemplate<'a> {
    wrapper_class: &'a str,
    empty_message: &'a str,
    items: &'a [HotspotItem],
}

#[derive(Debug, Clone, PartialEq)]
struct HotspotItem {
    href: String,
    kind: String,
    name: String,
    path: String,
    detail: String,
    score: String,
}

#[derive(Template)]
#[template(path = "coverage_table.html")]
struct CoverageTableTemplate<'a> {
    name_header: &'a str,
    total_header: &'a str,
    covered_header: &'a str,
    partial_header: &'a str,
    missed_header: &'a str,
    percent_header: &'a str,
    rows: &'a str,
    empty: bool,
    subtotal: &'a str,
}

#[derive(Template)]
#[template(path = "branch_context.html")]
struct BranchContextTemplate<'a> {
    branch: &'a str,
    commit: &'a str,
    coverage_percent: &'a str,
    covered_lines: i64,
    tracked_lines: i64,
    partial_lines: i64,
    missed_lines: i64,
    mutant_backed_lines: i64,
    stochastic_mutant_backed_lines: i64,
    invariant_mutant_backed_lines: i64,
    line_quality_bar: &'a str,
    breadcrumbs: &'a str,
}

#[derive(Template)]
#[template(path = "source_view.html")]
struct SourceViewTemplate<'a> {
    path: &'a str,
    summary: &'a str,
    layers_menu: &'a str,
    branch_context: &'a str,
    warnings: &'a str,
    code_lines: &'a str,
    history: &'a str,
}

#[derive(Template)]
#[template(path = "layers_menu.html")]
struct LayersMenuTemplate;

#[derive(Template)]
#[template(path = "warning_banner.html")]
struct WarningBannerTemplate<'a> {
    warnings: &'a [WarningBannerItem],
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WarningBannerItem {
    input_id: String,
    key: String,
    level: String,
    label: String,
    detail: String,
}

#[derive(Clone)]
struct UiServerState {
    db: Arc<PathBuf>,
    repo: Arc<PathBuf>,
    overlays: Arc<UiOverlays>,
}

#[derive(Debug, Default, Deserialize)]
struct IndexQuery {
    path: Option<String>,
    dir: Option<String>,
    commit: Option<String>,
    q: Option<String>,
    sort: Option<String>,
    queue: Option<String>,
    page: Option<usize>,
}

#[derive(Debug, Default, Deserialize)]
struct DirectoryQuery {
    dir: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct SourceQuery {
    path: Option<String>,
    commit: Option<String>,
}

#[derive(Default)]
struct AnnotationBuilder {
    covered: bool,
    is_partial: bool,
    mutant_tested: bool,
    test_types: BTreeSet<String>,
    distinct_tests: i64,
    mutant_verified_tests: i64,
    mutant_killed_tests: i64,
    stochastic_mutant_verified_tests: i64,
    invariant_mutant_verified_tests: i64,
    line_hits: Option<u32>,
    line_coverage: Option<f64>,
    mutant_coverage: Option<f64>,
    dark_arms: Vec<String>,
    dark_arm_spans: Vec<UiDarkArm>,
    effect_spans: Vec<UiEffectSpan>,
    findings: Vec<UiFinding>,
    hazards: Vec<UiHazard>,
    test_type_counts: BTreeMap<String, i64>,
    semantic_churn: f64,
    semantic_churn_events: i64,
    bug_weight: f64,
    bug_events: Vec<UiBugEvent>,
}

const MIN_HISTORY_WEIGHT: f64 = 0.001;
const BUG_HISTORY_ROW_BUDGET: usize = 120;
const DECOMPLEX_DOC_BASE: &str = "https://github.com/cuzzo/clear/blob/master/gems/decomplex";

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
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(serve_ui_async(db, repo, host.to_string(), port, overlays))
}

async fn serve_ui_async(
    db: PathBuf,
    repo: PathBuf,
    host: String,
    port: u16,
    overlays: UiOverlays,
) -> Result<()> {
    let addr = format!("{host}:{port}");
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .with_context(|| format!("bind {addr}"))?;
    let state = UiServerState {
        db: Arc::new(db),
        repo: Arc::new(repo),
        overlays: Arc::new(overlays),
    };
    let app = ui_router(state);
    println!("Lineage UI listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

fn ui_router(state: UiServerState) -> Router {
    controllers::router(state)
        .layer(SetResponseHeaderLayer::if_not_present(
            header::CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ))
        .layer(TraceLayer::new_for_http())
}

#[derive(Debug, Default, Deserialize)]
struct ArchitecturePageQuery {
    lens: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Default, Deserialize)]
struct ArchitectureSearchQuery {
    owner: Option<String>,
    q: Option<String>,
}












pub fn file_index(storage: &Storage, repo: Option<&Path>) -> Result<Vec<UiFile>> {
    file_index_with_scope(storage, &CoverageScope::all(), repo)
}

pub fn file_index_with_scope(
    storage: &Storage,
    scope: &CoverageScope,
    repo: Option<&Path>,
) -> Result<Vec<UiFile>> {
    let total_start = Instant::now();
    let sarif_counts = storage.sarif_finding_counts_by_file()?;
    let dark_arm_counts = sarif_dark_arm_counts_by_file(storage)?;
    let mut files = if let Some(files) =
        read_model_file_index_with_scope(storage, scope, &sarif_counts, &dark_arm_counts)?
    {
        profile_log("file_index.read_model_total", total_start);
        append_sarif_only_files(
            files,
            scope,
            &sarif_counts,
            &dark_arm_counts,
            true,
        )
    } else {
        let line_start = Instant::now();
        let line_stats = line_coverage_by_file(storage, scope)?;
        profile_log("file_index.line_coverage_by_file", line_start);
        let query_start = Instant::now();
        let mut stmt = storage.connection().prepare(
            include_str!("../../sql/ui/runtime/file_index_with_scope.sql"),
        )?;
        let rows = stmt.query_map([], |row| {
            let path = row.get::<_, String>(0)?;
            let fallback_line_coverage = row.get::<_, f64>(5)?;
            let stats = line_stats.get(&path).copied().unwrap_or_default();
            let sarif_findings = sarif_counts.get(&path).copied().unwrap_or_default();
            let dark_arm_findings = dark_arm_counts.get(&path).copied().unwrap_or_default();
            Ok(UiFile {
                path,
                units: row.get(1)?,
                hazards: row.get(2)?,
                sarif_findings,
                dark_arm_findings,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: row.get(3)?,
                mutant_killed_tests: row.get(4)?,
                tracked_lines: stats.tracked,
                covered_lines: stats.covered,
                partial_lines: stats.partial,
                line_coverage: if stats.tracked > 0 {
                    stats.coverage_percent_sum / stats.tracked as f64
                } else {
                    fallback_line_coverage
                },
                mutant_coverage: row.get(6)?,
                mutant_verified_covered_lines: 0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_verified_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_verified_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            })
        })?;
        let files = rows
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|file| scope.allows(&file.path) && is_production_source_path(&file.path))
            .collect();
        profile_log("file_index.current_units", query_start);
        profile_log("file_index.total", total_start);
        append_sarif_only_files(
            files,
            scope,
            &sarif_counts,
            &dark_arm_counts,
            false,
        )
    };

    if let Some(r) = repo {
        files.retain(|f| {
            let full_path = r.join(&f.path);
            if !full_path.is_file() {
                return false;
            }
            if let Ok(metadata) = std::fs::metadata(&full_path) {
                if metadata.len() == 0 {
                    return false;
                }
            }
            true
        });
    }

    Ok(files)
}

fn append_sarif_only_files(
    mut files: Vec<UiFile>,
    scope: &CoverageScope,
    sarif_counts: &HashMap<String, i64>,
    dark_arm_counts: &HashMap<String, i64>,
    read_model: bool,
) -> Vec<UiFile> {
    let existing = files
        .iter()
        .map(|file| file.path.clone())
        .collect::<BTreeSet<_>>();
    for (path, count) in sarif_counts {
        if *count <= 0
            || existing.contains(path)
            || !scope.allows(path)
            || !is_production_source_path(path)
        {
            continue;
        }
        files.push(UiFile {
            path: path.clone(),
            units: 0,
            hazards: 0,
            sarif_findings: *count,
            dark_arm_findings: dark_arm_counts.get(path).copied().unwrap_or_default(),
            evidence_covered_hazards: 0,
            covered_hazards: 0,
            distinct_tests: 0,
            mutant_killed_tests: 0,
            tracked_lines: 0,
            covered_lines: 0,
            partial_lines: 0,
            line_coverage: 0.0,
            mutant_coverage: 0.0,
            mutant_verified_covered_lines: 0,
            mutant_killed_covered_lines: 0,
            stochastic_mutant_verified_covered_lines: 0,
            stochastic_mutant_killed_covered_lines: 0,
            invariant_mutant_verified_covered_lines: 0,
            invariant_mutant_killed_covered_lines: 0,
            multi_type_covered_lines: 0,
            read_model,
        });
    }
    files.sort_by(|left, right| {
        right
            .hazards
            .cmp(&left.hazards)
            .then_with(|| right.sarif_findings.cmp(&left.sarif_findings))
            .then_with(|| right.mutant_killed_tests.cmp(&left.mutant_killed_tests))
            .then_with(|| right.distinct_tests.cmp(&left.distinct_tests))
            .then_with(|| left.path.cmp(&right.path))
    });
    files
}

fn sarif_dark_arm_counts_by_file(storage: &Storage) -> Result<HashMap<String, i64>> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/sarif_dark_arm_counts_by_file.sql"),
    )?;
    let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?;
    Ok(rows.collect::<std::result::Result<HashMap<_, _>, _>>()?)
}

fn read_model_file_index_with_scope(
    storage: &Storage,
    scope: &CoverageScope,
    sarif_counts: &HashMap<String, i64>,
    dark_arm_counts: &HashMap<String, i64>,
) -> Result<Option<Vec<UiFile>>> {
    let start = Instant::now();
    if storage.count_rows("ui_file_summaries")? == 0 {
        return Ok(None);
    }
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/read_model_file_index_with_scope.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        let path = row.get::<_, String>(0)?;
        let sarif_findings = sarif_counts.get(&path).copied().unwrap_or_default();
        let dark_arm_findings = dark_arm_counts.get(&path).copied().unwrap_or_default();
        Ok(UiFile {
            path,
            units: row.get(1)?,
            hazards: row.get(2)?,
            sarif_findings,
            dark_arm_findings,
            evidence_covered_hazards: row.get(3)?,
            covered_hazards: row.get(4)?,
            distinct_tests: row.get(5)?,
            mutant_killed_tests: row.get(6)?,
            tracked_lines: row.get(7)?,
            covered_lines: row.get(8)?,
            partial_lines: row.get(9)?,
            line_coverage: row.get(10)?,
            mutant_coverage: row.get(11)?,
            mutant_verified_covered_lines: row.get(12)?,
            mutant_killed_covered_lines: row.get(13)?,
            stochastic_mutant_verified_covered_lines: row.get(14)?,
            stochastic_mutant_killed_covered_lines: row.get(15)?,
            invariant_mutant_verified_covered_lines: row.get(16)?,
            invariant_mutant_killed_covered_lines: row.get(17)?,
            multi_type_covered_lines: row.get(18)?,
            read_model: true,
        })
    })?;
    let files = rows
        .collect::<std::result::Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|file| scope.allows(&file.path) && is_production_source_path(&file.path))
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
        include_str!("../../sql/ui/runtime/line_coverage_by_file.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, i64>(2)? != 0,
            row.get::<_, f64>(3)?,
        ))
    })?;
    for row in rows {
        let (path, hits, is_partial, coverage_percent) = row?;
        if !scope.allows(&path) || !is_production_source_path(&path) {
            continue;
        }
        let entry = by_file.entry(path).or_default();
        entry.tracked += 1;
        if hits > 0 {
            entry.covered += 1;
            if is_partial {
                entry.partial += 1;
            }
        }
        entry.coverage_percent_sum += coverage_percent;
    }
    Ok(by_file)
}

pub fn dashboard_summary(storage: &Storage) -> Result<UiDashboard> {
    dashboard_summary_for_directory_with_scope_and_repo(storage, "", &CoverageScope::all(), None, 12)
}

pub fn dashboard_summary_for_directory(storage: &Storage, directory: &str) -> Result<UiDashboard> {
    dashboard_summary_for_directory_with_scope_and_repo(
        storage,
        directory,
        &CoverageScope::all(),
        None,
        12,
    )
}

pub fn dashboard_summary_for_directory_with_scope(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<UiDashboard> {
    dashboard_summary_for_directory_with_scope_and_repo(storage, directory, scope, None, 200)
}

fn dashboard_summary_for_directory_with_scope_and_repo(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
    repo: Option<&Path>,
    hotspots_limit: usize,
) -> Result<UiDashboard> {
    let total_start = Instant::now();
    let directory = normalize_directory(directory);
    let files_start = Instant::now();
    let files = file_index_with_scope(storage, scope, repo)?;
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
    let unit_start = Instant::now();
    let test_next_units = test_next_hotspots(storage, &directory, scope, repo, hotspots_limit)?;
    let top_units = test_next_units
        .iter()
        .filter(|unit| unit.score > 0.0)
        .take(12)
        .cloned()
        .collect();
    let review_next = review_next_items(storage, &directory, scope)?;
    profile_log("dashboard.top_units", unit_start);
    let architecture_start = Instant::now();
    let top_architecture_risks = top_architecture_risks(storage, &directory, scope)?;
    profile_log("dashboard.top_architecture_risks", architecture_start);

    let files_with_coverage = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory) && file.line_coverage > 0.0)
        .count() as i64;
    let files_count = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory))
        .count();
    let sarif_findings = files
        .iter()
        .filter(|file| path_in_directory(&file.path, &directory))
        .map(|file| file.sarif_findings)
        .sum();

    let complexity_start = Instant::now();
    let top_complexity_functions = top_complexity_functions(storage, &directory, scope)?;
    profile_log("dashboard.top_complexity_functions", complexity_start);
    let health_start = Instant::now();
    let analyzer_health = analyzer_health(storage, &directory, scope)?;
    profile_log("dashboard.analyzer_health", health_start);
    let lifecycle = if directory.is_empty() {
        storage.sarif_lifecycle_summary()?
    } else {
        Default::default()
    };

    let dashboard = UiDashboard {
        files: files_count,
        tracked_lines: line_counts.tracked,
        covered_lines: line_counts.covered,
        coverage_percent: percent(line_counts.covered, line_counts.tracked),
        active_hazards,
        sarif_findings,
        new_findings: lifecycle.new_findings,
        resolved_findings: lifecycle.resolved_findings,
        persisted_findings: lifecycle.persisted_findings,
        evidence_covered_hazards,
        hazard_evidence_percent: percent(evidence_covered_hazards, active_hazards),
        covered_hazards,
        hazard_coverage_percent: percent(covered_hazards, active_hazards),
        mutant_verified_covered_lines: line_counts.mutant_verified,
        mutant_verified_covered_percent: percent(line_counts.mutant_verified, line_counts.covered),
        mutant_killed_covered_lines: line_counts.mutant_killed,
        mutant_killed_covered_percent: percent(line_counts.mutant_killed, line_counts.covered),
        stochastic_mutant_verified_covered_lines: line_counts.stochastic_mutant_verified,
        stochastic_mutant_verified_covered_percent: percent(
            line_counts.stochastic_mutant_verified,
            line_counts.covered,
        ),
        stochastic_mutant_killed_covered_lines: line_counts.stochastic_mutant_killed,
        stochastic_mutant_killed_covered_percent: percent(
            line_counts.stochastic_mutant_killed,
            line_counts.covered,
        ),
        invariant_mutant_verified_covered_lines: line_counts.invariant_mutant_verified,
        invariant_mutant_verified_covered_percent: percent(
            line_counts.invariant_mutant_verified,
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
        top_units,
        review_next,
        test_next_units,
        top_architecture_risks,
        top_complexity_functions,
        analyzer_health,
        warnings,
    };
    profile_log("dashboard.total", total_start);
    Ok(dashboard)
}

fn analyzer_health(
    storage: &Storage,
    directory: &str,
    _scope: &CoverageScope,
) -> Result<Vec<UiAnalyzerHealth>> {
    let mut scoped_counts = HashMap::<String, i64>::new();
    let mut total_counts = HashMap::<String, i64>::new();
    let finding_high_watermark: i64 = storage.connection().query_row(
        "SELECT COALESCE(MAX(id), 0) FROM sarif_findings",
        [],
        |row| row.get(0),
    )?;
    let count_findings = finding_high_watermark <= 50_000;
    if count_findings {
        let mut findings = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/analyzer_health.sql"),
        )?;
        let rows = findings.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;
        for row in rows {
            let (source, tool, count) = row?;
            let analyzer = canonical_analyzer_name(&source, &tool);
            *total_counts.entry(analyzer.clone()).or_default() += count;
        }
        let directory = normalize_directory(directory);
        if directory.is_empty() {
            scoped_counts.clone_from(&total_counts);
        } else {
            let prefix = format!("{directory}/%");
            let mut scoped = storage.connection().prepare(
                include_str!("../../sql/ui/runtime/analyzer_health_2.sql"),
            )?;
            let rows = scoped.query_map(params![directory, prefix], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?;
            for row in rows {
                let (source, tool, count) = row?;
                *scoped_counts
                    .entry(canonical_analyzer_name(&source, &tool))
                    .or_default() += count;
            }
        }
    }

    let current_commit: String = storage.connection().query_row(
        "SELECT COALESCE((SELECT commit_hash FROM metadata ORDER BY timestamp DESC LIMIT 1), '')",
        [],
        |row| row.get(0),
    )?;
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/analyzer_health_3.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, i64>(3)?,
        ))
    })?;
    let mut health = Vec::new();
    let mut present = BTreeSet::new();
    for row in rows {
        let (source, tool, commit, timestamp) = row?;
        let analyzer = canonical_analyzer_name(&source, &tool);
        present.insert(analyzer.clone());
        let scoped_findings = scoped_counts.get(&analyzer).copied().unwrap_or(if count_findings { 0 } else { -1 });
        let total_findings = total_counts.get(&analyzer).copied().unwrap_or(if count_findings { 0 } else { -1 });
        let reached_default_cap = analyzer == "Decomplex" && total_findings == 1_000;
        let stale = !current_commit.is_empty() && commit != current_commit;
        let (status, detail) = if stale {
            (
                "stale",
                format!("artifact is for {}, not current {}", short_hash(&commit), short_hash(&current_commit)),
            )
        } else if reached_default_cap {
            ("degraded", "artifact reached the default 1,000-finding cap".to_string())
        } else if total_findings == 0 {
            ("healthy", "completed with no findings".to_string())
        } else {
            ("healthy", format!("current artifact timestamp {timestamp}"))
        };
        health.push(UiAnalyzerHealth {
            analyzer,
            status: status.to_string(),
            detail,
            scoped_findings,
            total_findings,
        });
    }
    for expected in ["Decomplex", "SlopCop", "Nil-Kill", "Espalier"] {
        if !present.contains(expected) {
            health.push(UiAnalyzerHealth {
                analyzer: expected.to_string(),
                status: "missing".to_string(),
                detail: "no artifact has been ingested".to_string(),
                scoped_findings: if count_findings { 0 } else { -1 },
                total_findings: if count_findings { 0 } else { -1 },
            });
        }
    }
    health.sort_by(|left, right| {
        analyzer_status_rank(&left.status)
            .cmp(&analyzer_status_rank(&right.status))
            .then_with(|| left.analyzer.cmp(&right.analyzer))
    });
    Ok(health)
}

fn review_next_items(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<Vec<UiReviewNextItem>> {
    let directory = normalize_directory(directory);
    let prefix = format!("{directory}/%");
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/review_next_items.sql"),
    )?;
    let rows = stmt.query_map(params![directory, prefix], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, i64>(8)?,
            row.get::<_, f64>(9)?,
        ))
    })?;
    let mut items = Vec::new();
    for row in rows {
        let (path, start_line, title, tools, findings, warnings, dark_arms, example, tool_count, score) = row?;
        if !scope.allows(&path) || !is_production_source_path(&path) {
            continue;
        }
        let mut reasons = vec![format!("{findings} current findings from {tools}")];
        if tool_count > 1 {
            reasons.push(format!("{tool_count} analyzers agree"));
        }
        if warnings > 0 {
            reasons.push(format!("{warnings} warning/error"));
        }
        if dark_arms > 0 {
            reasons.push(format!("{dark_arms} uncovered branches"));
        }
        reasons.push(example);
        items.push(UiReviewNextItem {
            path,
            start_line,
            title,
            detail: reasons.join("; "),
            score,
        });
    }
    items.truncate(200);
    Ok(items)
}

fn canonical_analyzer_name(source: &str, tool: &str) -> String {
    let identity = format!("{source} {tool}").to_lowercase();
    if identity.contains("decomplex") {
        "Decomplex".to_string()
    } else if identity.contains("slopcop") {
        "SlopCop".to_string()
    } else if identity.contains("nil-kill") || identity.contains("nil_kill") {
        "Nil-Kill".to_string()
    } else if identity.contains("espalier") {
        "Espalier".to_string()
    } else {
        tool.to_string()
    }
}

fn analyzer_status_rank(status: &str) -> u8 {
    match status {
        "unhealthy" => 0,
        "missing" => 1,
        "stale" => 2,
        "degraded" => 3,
        _ => 4,
    }
}

fn short_hash(hash: &str) -> &str {
    hash.get(..hash.len().min(8)).unwrap_or(hash)
}

fn warnings_for_directory(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<Vec<UiWarning>> {
    let units = warning_units(storage)?
        .into_iter()
        .filter(|unit| {
            scope.allows(&unit.current_path)
                && is_production_source_path(&unit.current_path)
                && path_in_directory(&unit.current_path, directory)
        })
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
            include_str!("../../sql/ui/runtime/warning_units.sql"),
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
        include_str!("../../sql/ui/runtime/warning_units_2.sql"),
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

#[derive(Clone, Default)]
struct UnitSignalCounts {
    sarif_findings: i64,
    lint_findings: i64,
    dark_arms: i64,
    hazards: i64,
}

#[derive(Clone, Copy, Default)]
struct UnitTestProfile {
    line_coverage: f64,
    integration_coverage: f64,
    is_hard_gated: bool,
}

fn test_next_hotspots(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
    repo: Option<&Path>,
    limit: usize,
) -> Result<Vec<UiUnitHotspot>> {
    unit_hotspots(storage, directory, scope, repo, limit, true)
}

fn unit_hotspots(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
    repo: Option<&Path>,
    limit: usize,
    include_test_risk: bool,
) -> Result<Vec<UiUnitHotspot>> {
    let prefixes = if directory.is_empty() {
        Vec::new()
    } else {
        vec![format!("{}/", normalize_directory(directory))]
    };
    let mut summaries = storage.top_units(2_000, &prefixes)?;
    summaries.retain(|summary| {
        scope.allows(&summary.current_path)
            && is_production_source_path(&summary.current_path)
            && path_in_directory(&summary.current_path, directory)
    });
    let unit_ids: Vec<String> = summaries.iter().map(|summary| summary.id.clone()).collect();
    let signals = unit_signal_counts(storage, &unit_ids)?;
    let test_profiles = unit_test_profiles(storage, &unit_ids)?;
    let mut candidates = summaries
        .into_iter()
        .map(|summary| {
            let signal = signals.get(&summary.id).cloned().unwrap_or_default();
            let score = unit_hotspot_score(&summary, &signal);
            (summary, signal, score)
        })
        .filter(|(summary, _, score)| {
            let profile = test_profiles.get(&summary.id).copied().unwrap_or_default();
            *score > 0.0
                || (include_test_risk
                    && (profile.is_hard_gated
                        || summary.current_distinct_tests == 0
                        || summary.current_mutant_verified_tests == 0))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        right.2
            .partial_cmp(&left.2)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| right.1.hazards.cmp(&left.1.hazards))
            .then_with(|| right.1.sarif_findings.cmp(&left.1.sarif_findings))
            .then_with(|| left.0.current_path.cmp(&right.0.current_path))
            .then_with(|| left.0.name.cmp(&right.0.name))
    });
    candidates.truncate(limit);

    let top_summaries: Vec<_> = candidates.iter().map(|(s, _, _)| s.clone()).collect();
    let top_ids: Vec<String> = top_summaries.iter().map(|s| s.id.clone()).collect();
    let spans = storage
        .current_unit_spans_for_ids(&top_ids)?
        .into_iter()
        .map(|span| (span.id, span.start_line))
        .collect::<HashMap<_, _>>();
    let current_spans = repo
        .map(|repo| current_source_start_lines(repo, &top_summaries))
        .unwrap_or_default();

    let final_units = candidates
        .into_iter()
        .map(|(summary, signal, score)| {
            let test_profile = test_profiles.get(&summary.id).copied().unwrap_or_default();
            let key = (
                summary.current_path.clone(),
                summary.name.clone(),
                summary.kind.clone(),
            );
            let start_line = current_spans
                .get(&key)
                .copied()
                .or_else(|| spans.get(&summary.id).copied())
                .unwrap_or(1);
            UiUnitHotspot {
                path: summary.current_path,
                name: summary.name,
                kind: summary.kind,
                start_line,
                score,
                risk_score: summary.risk_score,
                sarif_findings: signal.sarif_findings,
                dark_arms: signal.dark_arms,
                hazards: signal.hazards,
                fixes: summary.fixes,
                changes: summary.changes,
                mutant_killed_tests: summary.current_mutant_killed_tests,
                mutant_verified_tests: summary.current_mutant_verified_tests,
                distinct_tests: summary.current_distinct_tests,
                test_types: summary.current_test_types,
                line_coverage: test_profile.line_coverage,
                integration_coverage: test_profile.integration_coverage,
                is_hard_gated: test_profile.is_hard_gated,
                reopened_count: summary.reopened_count,
            }
        })
        .collect::<Vec<_>>();

    Ok(final_units)
}

fn unit_test_profiles(
    storage: &Storage,
    unit_ids: &[String],
) -> Result<HashMap<String, UnitTestProfile>> {
    if unit_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let placeholders = unit_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let query = format!(
        "SELECT id, current_line_cov, current_integration_cov, is_hard_gated
         FROM logical_units
         WHERE id IN ({})",
        placeholders
    );
    let mut stmt = storage.connection().prepare(&query)?;
    let params = rusqlite::params_from_iter(unit_ids);
    let rows = stmt.query_map(params, |row| {
        Ok((
            row.get::<_, String>(0)?,
            UnitTestProfile {
                line_coverage: row.get(1)?,
                integration_coverage: row.get(2)?,
                is_hard_gated: row.get::<_, i64>(3)? != 0,
            },
        ))
    })?;
    Ok(rows.collect::<std::result::Result<HashMap<_, _>, _>>()?)
}

#[derive(Debug, Default, Clone)]
struct ArchitectureRiskAccumulator {
    path: String,
    owner: String,
    owner_kind: String,
    start_line: u32,
    findings: i64,
    states: i64,
    functions: i64,
    impure_functions: i64,
    privacy_candidates: i64,
}

fn top_architecture_risks(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<Vec<UiArchitectureRisk>> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/top_architecture_risks.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
        ))
    })?;

    let mut risks = BTreeMap::<(String, String), ArchitectureRiskAccumulator>::new();
    for row in rows {
        let (path, start_line, rule_id, level, message, properties_json) = row?;
        if !scope.allows(&path)
            || !is_production_source_path(&path)
            || !path_in_directory(&path, directory)
        {
            continue;
        }
        let properties = serde_json::from_str::<Value>(&properties_json).unwrap_or(Value::Null);
        let Some(owner) = espalier_owner_name(&properties, &message) else {
            continue;
        };
        let owner_kind = string_field(&properties, &["type"])
            .or_else(|| string_field(&properties, &["kind"]))
            .unwrap_or("owner")
            .to_string();
        let key = (path.clone(), owner.clone());
        let entry = risks.entry(key).or_insert_with(|| ArchitectureRiskAccumulator {
            path: path.clone(),
            owner: owner.clone(),
            owner_kind: owner_kind.clone(),
            start_line: 0,
            ..ArchitectureRiskAccumulator::default()
        });
        if entry.owner_kind == "owner" && owner_kind != "owner" {
            entry.owner_kind = owner_kind;
        }
        let line = espalier_finding_start_line(&properties).unwrap_or(start_line).max(1);
        if entry.start_line == 0 || line < entry.start_line {
            entry.start_line = line;
        }
        entry.findings += 1;
        match rule_id.as_str() {
            "espalier.state" => entry.states += 1,
            "espalier.function" => {
                entry.functions += 1;
                if espalier_function_impure(&properties) {
                    entry.impure_functions += 1;
                }
            }
            "espalier.privacy-candidate" => entry.privacy_candidates += 1,
            _ => {
                if level == "warning" {
                    entry.privacy_candidates += 1;
                }
            }
        }
    }

    let mut out = risks
        .into_values()
        .map(|risk| {
            let score = architecture_risk_score(&risk);
            UiArchitectureRisk {
                architecture_id: architecture_owner_id_by_name(storage, &risk.path, &risk.owner),
                path: risk.path,
                owner: risk.owner,
                owner_kind: risk.owner_kind,
                start_line: risk.start_line.max(1),
                score,
                findings: risk.findings,
                states: risk.states,
                functions: risk.functions,
                impure_functions: risk.impure_functions,
                privacy_candidates: risk.privacy_candidates,
            }
        })
        .filter(|risk| risk.score > 0.0)
        .collect::<Vec<_>>();
    out.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| right.privacy_candidates.cmp(&left.privacy_candidates))
            .then_with(|| right.impure_functions.cmp(&left.impure_functions))
            .then_with(|| left.path.cmp(&right.path))
            .then_with(|| left.owner.cmp(&right.owner))
    });
    out.truncate(12);
    Ok(out)
}

fn top_complexity_functions(
    storage: &Storage,
    directory: &str,
    scope: &CoverageScope,
) -> Result<Vec<UiComplexityFunction>> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/top_complexity_functions.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;

    let mut functions = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for row in rows {
        let (path, start_line, properties_json, message) = row?;
        if !scope.allows(&path)
            || !is_production_source_path(&path)
            || !path_in_directory(&path, directory)
        {
            continue;
        }

        let properties = serde_json::from_str::<Value>(&properties_json).unwrap_or(Value::Null);
        let func_val = match properties.get("function") {
            Some(v) => v,
            None => continue,
        };

        let name = string_field(func_val, &["name"])
            .or_else(|| string_field(&properties, &["function"]))
            .or_else(|| message.rsplit('#').next())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("*")
            .to_string();

        let key = (path.clone(), name.clone(), start_line);
        if seen.contains(&key) {
            continue;
        }

        let metrics = match func_val.get("quality_metrics") {
            Some(m) => m,
            None => continue,
        };

        let big_o = metrics
            .get("big_o")
            .and_then(|v| v.as_str())
            .unwrap_or("O(1)")
            .to_string();

        let big_o_space = metrics
            .get("big_o_space")
            .and_then(|v| v.as_str())
            .unwrap_or("O(1)")
            .to_string();

        let is_dynamic = metrics
            .get("big_o_dynamic")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);

        let trigger = metrics
            .get("complexity_trigger")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let rank = complexity_display_rank(&big_o);

        if rank > 10 {
            seen.insert(key);
            functions.push((path, start_line, name, big_o, big_o_space, is_dynamic, trigger, rank));
        }
    }

    functions.sort_by(|left, right| {
        right.7.cmp(&left.7)
            .then_with(|| left.0.cmp(&right.0))
            .then_with(|| left.2.cmp(&right.2))
    });

    let result = functions
        .into_iter()
        .map(|(path, start_line, name, big_o, big_o_space, is_dynamic, trigger, _)| {
            let complexity_type = if is_dynamic {
                if !trigger.is_empty() {
                    format!("Dynamic, triggered by {}", trigger)
                } else {
                    "Dynamic".to_string()
                }
            } else {
                "Static/Fixed".to_string()
            };
            let detail = format!("Runtime: {} ({}) | Space: {}", big_o, complexity_type, big_o_space);
            UiComplexityFunction {
                name,
                path,
                start_line,
                runtime_complexity: big_o,
                space_complexity: big_o_space,
                detail,
            }
        })
        .collect();

    Ok(result)
}

fn complexity_display_rank(complexity: &str) -> u32 {
    match complexity {
        "O(1)" => 1,
        "O(log N)" => 2,
        "O(N)" => 10,
        "O(N log N)" => 11,
        "O(N * M)" => 14,
        "O(2^N)" => 100,
        "O(N!)" => 200,
        value => value
            .strip_prefix("O(N^")
            .and_then(|tail| tail.split_once(')'))
            .and_then(|(power, suffix)| {
                power
                    .strip_suffix(" log N")
                    .map(|power| (power, 1))
                    .or(Some((power, 0)))
                    .filter(|(_, _)| suffix.is_empty())
            })
            .and_then(|(power, log)| power.parse::<u32>().ok().map(|power| 10 + power * 2 + log))
            .unwrap_or(1),
    }
}


fn espalier_owner_name(properties: &Value, message: &str) -> Option<String> {
    string_field(properties, &["module"])
        .or_else(|| object_field(properties, &["function"]).and_then(|function| string_field(function, &["owner"])))
        .map(str::trim)
        .filter(|owner| !owner.is_empty())
        .map(str::to_string)
        .or_else(|| {
            message
                .strip_prefix("owner:")
                .or_else(|| message.strip_prefix("function:"))
                .and_then(|tail| tail.trim().split('#').next())
                .map(str::trim)
                .filter(|owner| !owner.is_empty())
                .map(str::to_string)
        })
}

fn espalier_finding_start_line(properties: &Value) -> Option<u32> {
    u32_field(properties, &["line"])
        .or_else(|| span_field(properties, &["span"]).map(|span| span[0]))
        .or_else(|| {
            object_field(properties, &["function"])
                .and_then(|function| u32_field(function, &["line"]).or_else(|| span_field(function, &["span"]).map(|span| span[0])))
        })
}

fn espalier_function_impure(properties: &Value) -> bool {
    let Some(function) = object_field(properties, &["function"]) else {
        return false;
    };
    !normalized_effect_list(function, &["EFFECTS", "effects"], "writes").is_empty()
}

fn architecture_risk_score(risk: &ArchitectureRiskAccumulator) -> f64 {
    risk.privacy_candidates as f64 * 4.0
        + risk.impure_functions as f64 * 2.0
        + risk.states as f64 * 0.75
        + risk.findings as f64 * 0.2
}

fn current_source_start_lines(
    repo: &Path,
    summaries: &[crate::storage::UnitSummary],
) -> HashMap<(String, String, String), u32> {
    use rayon::prelude::*;

    let paths = summaries
        .iter()
        .map(|summary| summary.current_path.as_str())
        .collect::<BTreeSet<_>>();

    let results: Vec<_> = paths
        .into_par_iter()
        .filter_map(|path| {
            let file = read_source(repo, path, None).ok()?;
            let symbols = source_symbols_from_current_file(&file);
            Some((path.to_string(), symbols))
        })
        .collect();

    let mut spans = HashMap::new();
    for (path, symbols) in results {
        for symbol in symbols {
            let key = (path.clone(), symbol.name, symbol.kind);
            spans
                .entry(key)
                .and_modify(|line: &mut u32| *line = (*line).min(symbol.start_line))
                .or_insert(symbol.start_line);
        }
    }
    spans
}

fn unit_signal_counts(
    storage: &Storage,
    unit_ids: &[String],
) -> Result<HashMap<String, UnitSignalCounts>> {
    if unit_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let mut counts = HashMap::<String, UnitSignalCounts>::new();
    let placeholders = unit_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    {
        let query = format!(
            "SELECT unit_id,
                    SUM(CASE WHEN NOT (
                      lower(category) = 'lint'
                      OR lower(source) LIKE '%lint%'
                      OR lower(tool_name) IN ('rubocop', 'clippy', 'zig ast check')
                      OR lower(rule_id) LIKE 'lint/%'
                      OR lower(rule_id) LIKE 'security/%'
                      OR lower(rule_id) LIKE 'clippy::%'
                      OR lower(rule_id) LIKE 'zig.ast-check%'
                    ) THEN 1 ELSE 0 END) AS sarif_findings,
                    SUM(CASE WHEN (
                      lower(category) = 'lint'
                      OR lower(source) LIKE '%lint%'
                      OR lower(tool_name) IN ('rubocop', 'clippy', 'zig ast check')
                      OR lower(rule_id) LIKE 'lint/%'
                      OR lower(rule_id) LIKE 'security/%'
                      OR lower(rule_id) LIKE 'clippy::%'
                      OR lower(rule_id) LIKE 'zig.ast-check%'
                    ) THEN 1 ELSE 0 END) AS lint_findings,
                    SUM(CASE WHEN is_dark_arm = 1 THEN 1 ELSE 0 END) AS dark_arms
             FROM current_sarif_findings
             WHERE unit_id IN ({})
             GROUP BY unit_id",
            placeholders
        );
        let mut stmt = storage.connection().prepare(&query)?;
        let params = rusqlite::params_from_iter(unit_ids);
        let rows = stmt.query_map(params, |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        for row in rows {
            let (unit_id, sarif_findings, lint_findings, dark_arms) = row?;
            let entry = counts.entry(unit_id).or_default();
            entry.sarif_findings = sarif_findings;
            entry.lint_findings = lint_findings;
            entry.dark_arms = dark_arms;
        }
    }
    {
        let query = format!(
            "SELECT unit_id, COUNT(*) AS hazards
             FROM unit_hazards
             WHERE is_active = 1 AND unit_id IN ({})
             GROUP BY unit_id",
            placeholders
        );
        let mut stmt = storage.connection().prepare(&query)?;
        let params = rusqlite::params_from_iter(unit_ids);
        let rows = stmt.query_map(params, |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        for row in rows {
            let (unit_id, hazards) = row?;
            counts.entry(unit_id).or_default().hazards = hazards;
        }
    }
    Ok(counts)
}

fn unit_hotspot_score(summary: &crate::storage::UnitSummary, signal: &UnitSignalCounts) -> f64 {
    summary.risk_score
        + signal.sarif_findings as f64 * 0.35
        + signal.lint_findings as f64 * 0.08
        + signal.dark_arms as f64 * 1.2
        + signal.hazards as f64 * 2.0
}

fn dashboard_line_counts_from_files(files: &[UiFile], directory: &str) -> DashboardLineCounts {
    let mut counts = DashboardLineCounts::default();
    for file in files.iter().filter(|file| path_in_directory(&file.path, directory)) {
        counts.tracked += file.tracked_lines;
        counts.covered += file.covered_lines;
        counts.mutant_verified += file.mutant_verified_covered_lines;
        counts.mutant_killed += file.mutant_killed_covered_lines;
        counts.stochastic_mutant_verified += file.stochastic_mutant_verified_covered_lines;
        counts.stochastic_mutant_killed += file.stochastic_mutant_killed_covered_lines;
        counts.invariant_mutant_verified += file.invariant_mutant_verified_covered_lines;
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
        include_str!("../../sql/ui/runtime/dashboard_line_counts.sql"),
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u32>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, i64>(7)?,
            row.get::<_, i64>(8)?,
            row.get::<_, i64>(9)?,
        ))
    })?;
    for row in rows {
        let (
            path,
            _line,
            hits,
            verified_test_types,
            has_mutant_verified,
            has_mutant_killed,
            has_stochastic_mutant_verified,
            has_stochastic_mutant_killed,
            has_invariant_mutant_killed,
            has_invariant_mutant_verified,
        ) = row?;
        if !_scope.allows(&path)
            || !is_production_source_path(&path)
            || !path_in_directory(&path, _directory)
        {
            continue;
        }
        if has_mutant_verified > 0 {
            counts.mutant_verified += 1;
        }
        if has_mutant_killed > 0 {
            counts.mutant_killed += 1;
        }
        if has_stochastic_mutant_verified > 0 {
            counts.stochastic_mutant_verified += 1;
        }
        if has_stochastic_mutant_killed > 0 {
            counts.stochastic_mutant_killed += 1;
        }
        if has_invariant_mutant_verified > 0 {
            counts.invariant_mutant_verified += 1;
        }
        if has_invariant_mutant_killed > 0 {
            counts.invariant_mutant_killed += 1;
        }
        if verified_test_types >= 2 || hits > 1 {
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
        include_str!("../../sql/ui/runtime/dashboard_coverage_line_counts.sql"),
    )?;
    let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, u32>(1)?)))?;
    for row in rows {
        let (path, hits) = row?;
        if !scope.allows(&path)
            || !is_production_source_path(&path)
            || !path_in_directory(&path, directory)
        {
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
        include_str!("../../sql/ui/runtime/dashboard_hazard_counts.sql"),
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
        if !scope.allows(&path)
            || !is_production_source_path(&path)
            || !path_in_directory(&path, directory)
        {
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
        entry.evidence_covered_hazards += file.evidence_covered_hazards;
        entry.covered_hazards += file.covered_hazards;
        entry.sarif_findings += file.sarif_findings;
        entry.dark_arm_findings += file.dark_arm_findings;
        entry.partial_lines += file_partial_line_count(file);
        entry.distinct_tests += file.distinct_tests;
        entry.mutant_killed_tests += file.mutant_killed_tests;
        entry.tracked_lines += file.tracked_lines;
        entry.covered_lines += file.covered_lines;
        entry.mutant_killed_covered_lines += file.mutant_killed_covered_lines;
        entry.multi_type_covered_lines += file.multi_type_covered_lines;
        entry.line_coverage_sum += file.line_coverage * file.tracked_lines.max(1) as f64;
        entry.mutant_coverage_sum += file.mutant_coverage;
        if file.tracked_lines == 0 {
            entry.fallback_files += 1;
        }
    }
    dirs.into_iter()
        .map(|(path, builder)| {
            let files = builder.files.max(1) as f64;
            let line_coverage = if builder.tracked_lines > 0 {
                builder.line_coverage_sum / builder.tracked_lines as f64
            } else {
                builder.line_coverage_sum / files
            };
            UiDirectory {
                path,
                files: builder.files,
                units: builder.units,
                hazards: builder.hazards,
                evidence_covered_hazards: builder.evidence_covered_hazards,
                covered_hazards: builder.covered_hazards,
                sarif_findings: builder.sarif_findings,
                dark_arm_findings: builder.dark_arm_findings,
                partial_lines: builder.partial_lines,
                distinct_tests: builder.distinct_tests,
                mutant_killed_tests: builder.mutant_killed_tests,
                tracked_lines: builder.tracked_lines,
                covered_lines: builder.covered_lines,
                mutant_killed_covered_lines: builder.mutant_killed_covered_lines,
                multi_type_covered_lines: builder.multi_type_covered_lines,
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
    evidence_covered_hazards: i64,
    covered_hazards: i64,
    sarif_findings: i64,
    dark_arm_findings: i64,
    partial_lines: i64,
    distinct_tests: i64,
    mutant_killed_tests: i64,
    tracked_lines: i64,
    covered_lines: i64,
    mutant_killed_covered_lines: i64,
    multi_type_covered_lines: i64,
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
    annotate_sarif_freshness(repo, path, &file.contents, &mut annotations);
    profile_log("source.line_annotations", annotation_start);
    let paint_start = Instant::now();
    paint_statement_continuations(&lines, &mut annotations);
    profile_log("source.paint_continuations", paint_start);
    let versions_start = Instant::now();
    let versions = file_versions(storage, path)?;
    profile_log("source.file_versions", versions_start);
    let symbols_start = Instant::now();
    let mut symbols = source_symbols(storage, &file)?;
    apply_architecture_symbol_links(storage, path, &mut symbols);
    profile_log("source.symbols", symbols_start);
    let effects_start = Instant::now();
    let effects = espalier_function_effects(storage, path)?;
    apply_espalier_symbol_effects(&mut symbols, &effects);
    apply_espalier_effect_spans(path, &lines, &mut annotations, &effects);
    apply_symbol_hotspots(&mut symbols, &annotations);
    profile_log("source.espalier_effects", effects_start);
    let blame_start = Instant::now();
    let blame = source_blame(repo, path, commit, lines.len()).unwrap_or_default();
    profile_log("source.blame", blame_start);
    let warnings_start = Instant::now();
    let warnings = warnings_for_path(storage, path)?;
    profile_log("source.warnings", warnings_start);
    profile_log("source.total", total_start);
    Ok(UiSourcePayload {
        path: path.to_string(),
        commit: commit.map(str::to_string),
        lines,
        versions,
        symbols,
        blame,
        annotations,
        warnings,
    })
}

fn annotate_sarif_freshness(
    repo: &Path,
    path: &str,
    viewed_source: &str,
    annotations: &mut [UiLineAnnotation],
) {
    let commits = annotations
        .iter()
        .flat_map(|annotation| annotation.findings.iter())
        .map(|finding| finding.commit.clone())
        .filter(|commit| !commit.is_empty())
        .collect::<BTreeSet<_>>();
    let stale_by_commit = commits
        .into_iter()
        .map(|commit| {
            let stale = read_source(repo, path, Some(&commit))
                .ok()
                .is_some_and(|analyzed| analyzed.contents != viewed_source);
            (commit, stale)
        })
        .collect::<HashMap<_, _>>();
    for finding in annotations
        .iter_mut()
        .flat_map(|annotation| annotation.findings.iter_mut())
    {
        finding.stale = stale_by_commit.get(&finding.commit).copied().unwrap_or(false);
    }
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


#[derive(Debug, serde::Deserialize)]
struct DefinitionQuery {
    name: String,
    commit: Option<String>,
    path: Option<String>,
}

#[derive(Debug, serde::Serialize)]
struct DefinitionResult {
    path: String,
    line: u32,
}


fn error_response(status: StatusCode, error: impl std::fmt::Display) -> Response<Body> {
    (status, Html(format!("<p>{}</p>", html_escape(&error.to_string())))).into_response()
}

fn error_json(status: StatusCode, error: impl std::fmt::Display) -> Response<Body> {
    (status, Json(serde_json::json!({ "error": error.to_string() }))).into_response()
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
        include_str!("../../sql/ui/runtime/file_versions.sql"),
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

fn source_symbols(storage: &Storage, file: &BlobFile) -> Result<Vec<UiSourceSymbol>> {
    let current_symbols = source_symbols_from_current_file(file);
    if !current_symbols.is_empty() {
        return Ok(current_symbols);
    }

    persisted_source_symbols(storage, &file.path)
}

fn source_symbols_from_current_file(file: &BlobFile) -> Vec<UiSourceSymbol> {
    let extractor = HeuristicExtractor::new(SourceFilter::code_defaults());
    extractor
        .extract_units(file)
        .into_iter()
        .map(|unit| empty_source_symbol(unit.kind.as_str(), unit.name, unit.start_line, unit.end_line))
        .collect()
}

fn empty_source_symbol(
    kind: impl Into<String>,
    name: impl Into<String>,
    start_line: u32,
    end_line: u32,
) -> UiSourceSymbol {
    UiSourceSymbol {
        kind: kind.into(),
        name: name.into(),
        start_line,
        end_line,
        effect_known: false,
        impure: false,
        effect_summary: Vec::new(),
        hotspot_score: 0.0,
        hotspot_level: "green".to_string(),
        sarif_findings: 0,
        dark_arms: 0,
        hazards: 0,
        unverified_hazards: 0,
        bug_weight: 0.0,
        semantic_churn: 0.0,
        architecture_id: None,
        architecture_owner_id: None,
        architecture_pressure: 0.0,
        architecture_band: "ordinary".to_string(),
    }
}

fn persisted_source_symbols(storage: &Storage, path: &str) -> Result<Vec<UiSourceSymbol>> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/persisted_source_symbols.sql"),
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok(empty_source_symbol(
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, u32>(2)?,
            row.get::<_, u32>(3)?,
        ))
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

fn apply_architecture_symbol_links(storage: &Storage, path: &str, symbols: &mut [UiSourceSymbol]) {
    let Ok(mut stmt) = storage.connection().prepare(ARCHITECTURE_SYMBOLS_FOR_PATH_SQL) else {
        return;
    };
    let Ok(rows) = stmt.query_map(params![path], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?, row.get::<_, String>(2)?,
            row.get::<_, String>(3)?, row.get::<_, u32>(4)?, row.get::<_, u32>(5)?,
            row.get::<_, f64>(6)?, row.get::<_, String>(7)?, row.get::<_, String>(8)?, row.get::<_, String>(9)?))
    }) else {
        return;
    };
    let records = rows.filter_map(std::result::Result::ok).collect::<Vec<_>>();
    for symbol in symbols {
        let wanted_kind = if is_outline_container(symbol) { "owner" } else { "function" };
        let short_name = outline_short_name(&symbol.name);
        let matched = records.iter().filter(|record| record.2 == wanted_kind).min_by_key(|record| {
            let name_penalty = if record.3 == symbol.name || record.3 == short_name { 0 } else { 10_000 };
            name_penalty + record.4.abs_diff(symbol.start_line)
        });
        if let Some((id, owner_id, _, _, _, _, score, band, reads, writes)) = matched {
            symbol.architecture_id = Some(id.clone());
            symbol.architecture_owner_id = owner_id.clone().or_else(|| Some(id.clone()));
            symbol.architecture_pressure = *score;
            symbol.architecture_band = band.clone();
            if wanted_kind == "function" {
                let reads = reads.split(',').filter(|value| !value.is_empty()).collect::<Vec<_>>();
                let writes = writes.split(',').filter(|value| !value.is_empty()).collect::<Vec<_>>();
                symbol.effect_known = true;
                symbol.impure = !writes.is_empty();
                symbol.effect_summary.clear();
                if !reads.is_empty() { symbol.effect_summary.push(format!("reads {}", reads.join(", "))); }
                if !writes.is_empty() { symbol.effect_summary.push(format!("writes {}", writes.join(", "))); }
                if reads.is_empty() && writes.is_empty() { symbol.effect_summary.push("pure (no state effects)".to_string()); }
            }
        }
    }
}

fn architecture_owner_id_by_name(storage: &Storage, path: &str, owner: &str) -> Option<String> {
    storage.connection().query_row(
        ARCHITECTURE_OWNER_BY_NAME_SQL,
        params![path, owner, format!("%{owner}")],
        |row| row.get(0),
    ).optional().ok().flatten()
}

fn source_blame(
    repo: &Path,
    path: &str,
    commit: Option<&str>,
    line_count: usize,
) -> Result<Vec<UiLineBlame>> {
    if line_count == 0 {
        return Ok(Vec::new());
    }

    let repository = Repository::open(repo)?;
    let mut options = BlameOptions::new();
    options
        .track_copies_same_file(true)
        .ignore_whitespace(true)
        .min_line(1)
        .max_line(line_count);
    if let Some(commit) = commit {
        if let Some(oid) = resolve_commit_oid(&repository, commit) {
            options.newest_commit(oid);
        }
    }

    let blame = repository.blame_file(Path::new(path), Some(&mut options))?;
    let mut raw = Vec::<(u32, String, i64, String)>::new();
    for line in 1..=line_count {
        let Some(hunk) = blame.get_line(line) else {
            continue;
        };
        let commit_hash = hunk.final_commit_id().to_string();
        let signature = hunk.final_signature();
        let timestamp = signature.when().seconds();
        let author = signature
            .name()
            .map(str::to_string)
            .filter(|name| !name.trim().is_empty())
            .or_else(|| commit_author(&repository, &commit_hash))
            .unwrap_or_else(|| "unknown".to_string());
        raw.push((line as u32, commit_hash, timestamp, author));
    }

    let mut commits = raw
        .iter()
        .map(|(_, hash, timestamp, _)| (hash.clone(), *timestamp))
        .collect::<BTreeMap<_, _>>()
        .into_iter()
        .collect::<Vec<_>>();
    commits.sort_by(|left, right| left.1.cmp(&right.1).then_with(|| left.0.cmp(&right.0)));
    let total_commits = commits.len().max(1);
    let ordinals = commits
        .into_iter()
        .enumerate()
        .map(|(index, (hash, _))| (hash, index + 1))
        .collect::<HashMap<_, _>>();

    Ok(raw
        .into_iter()
        .map(|(line, commit_hash, timestamp, author)| UiLineBlame {
            line,
            ordinal: ordinals.get(&commit_hash).copied().unwrap_or(1),
            total_commits,
            commit_hash,
            timestamp,
            author,
        })
        .collect())
}

fn resolve_commit_oid(repository: &Repository, commit: &str) -> Option<Oid> {
    Oid::from_str(commit)
        .ok()
        .or_else(|| repository.revparse_single(commit).ok().map(|object| object.id()))
}

fn commit_author(repository: &Repository, commit_hash: &str) -> Option<String> {
    resolve_commit_oid(repository, commit_hash).and_then(|oid| {
        repository
            .find_commit(oid)
            .ok()
            .and_then(|commit| commit.author().name().map(str::to_string))
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct EspalierFunctionEffect {
    name: String,
    start_line: u32,
    end_line: u32,
    reads: Vec<String>,
    writes: Vec<String>,
    internal_calls: Vec<String>,
    impure_calls: Vec<String>,
}

impl EspalierFunctionEffect {
    fn effect_known(&self) -> bool {
        true
    }

    fn impure(&self) -> bool {
        !self.writes.is_empty() || !self.impure_calls.is_empty()
    }

    fn summary(&self) -> Vec<String> {
        let mut rows = Vec::new();
        if self.reads.is_empty() && self.writes.is_empty() && self.impure_calls.is_empty() {
            rows.push("pure (no state effects)".to_string());
        }
        if !self.reads.is_empty() {
            rows.push(format!("reads {}", self.reads.join(", ")));
        }
        if !self.writes.is_empty() {
            rows.push(format!("writes {}", self.writes.join(", ")));
        }
        if !self.impure_calls.is_empty() {
            rows.push(format!("calls impure {}", self.impure_calls.join(", ")));
        }
        rows
    }
}

fn espalier_function_effects(
    storage: &Storage,
    path: &str,
) -> Result<Vec<EspalierFunctionEffect>> {
    let mut effects = storage
        .sarif_findings_for_path(path)?
        .into_iter()
        .filter(is_espalier_function_finding)
        .filter_map(|finding| espalier_effect_from_finding(&finding))
        .collect::<Vec<_>>();
    if effects.is_empty() {
        return Ok(effects);
    }

    let impure_names = effects
        .iter()
        .filter(|effect| !effect.writes.is_empty())
        .map(|effect| effect.name.clone())
        .collect::<BTreeSet<_>>();
    for effect in &mut effects {
        let calls = effect
            .internal_calls
            .iter()
            .filter(|call| impure_names.contains(*call))
            .cloned()
            .collect::<Vec<_>>();
        effect.impure_calls = calls;
    }
    Ok(effects)
}

fn is_espalier_function_finding(finding: &crate::model::SarifFinding) -> bool {
    finding.rule_id == "espalier.function"
        || (finding.tool_name.eq_ignore_ascii_case("espalier")
            && finding
                .run_format
                .eq_ignore_ascii_case("espalier.manifest.sarif.v1")
            && finding.rule_id.ends_with(".function"))
}

fn espalier_effect_from_finding(
    finding: &crate::model::SarifFinding,
) -> Option<EspalierFunctionEffect> {
    let properties = serde_json::from_str::<Value>(&finding.properties_json).ok()?;
    let function = properties.get("function")?;
    let name = string_field(function, &["name"])
        .or_else(|| string_field(&properties, &["function"]))
        .or_else(|| finding.message.rsplit('#').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())?
        .to_string();
    let span = span_field(function, &["span"]);
    let start_line = span
        .map(|span| span[0])
        .unwrap_or(finding.start_line)
        .max(1);
    let end_line = span
        .map(|span| span[2].max(start_line))
        .or(finding.end_line)
        .unwrap_or(start_line)
        .max(start_line);
    Some(EspalierFunctionEffect {
        name,
        start_line,
        end_line,
        reads: normalized_effect_list(function, &["EFFECTS", "effects"], "reads"),
        writes: normalized_effect_list(function, &["EFFECTS", "effects"], "writes"),
        internal_calls: object_field(function, &["CALL_GRAPH", "call_graph"])
            .map(|call_graph| string_list_field(call_graph, "internal_calls"))
            .unwrap_or_default(),
        impure_calls: Vec::new(),
    })
}

fn normalized_effect_list(function: &Value, effect_keys: &[&str], key: &str) -> Vec<String> {
    effect_keys
        .iter()
        .find_map(|effect_key| function.get(*effect_key))
        .map(|effects| string_list_field(effects, key))
        .unwrap_or_default()
}

fn object_field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key).filter(|child| child.is_object()))
}

fn string_list_field(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|item| !item.is_empty())
                .map(str::to_string)
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect()
        })
        .unwrap_or_default()
}

fn apply_espalier_symbol_effects(
    symbols: &mut [UiSourceSymbol],
    effects: &[EspalierFunctionEffect],
) {
    for symbol in symbols {
        let Some(effect) = effects
            .iter()
            .find(|effect| effect.name == symbol.name)
            .or_else(|| {
                effects.iter().find(|effect| {
                    symbol.start_line >= effect.start_line && symbol.start_line <= effect.end_line
                })
            })
        else {
            continue;
        };
        symbol.effect_known = effect.effect_known();
        symbol.impure = effect.impure();
        symbol.effect_summary = effect.summary();
    }
}

fn apply_symbol_hotspots(symbols: &mut [UiSourceSymbol], annotations: &[UiLineAnnotation]) {
    for symbol in symbols {
        let end_line = symbol.end_line.max(symbol.start_line);
        let mut sarif_findings = 0_i64;
        let mut lint_findings = 0_i64;
        let mut dark_arms = 0_i64;
        let mut hazards = 0_i64;
        let mut unverified_hazards = 0_i64;
        let mut bug_weight = 0.0_f64;
        let mut semantic_churn = 0.0_f64;

        for annotation in annotations
            .iter()
            .filter(|annotation| annotation.line >= symbol.start_line && annotation.line <= end_line)
        {
            let lint_count = annotation
                .findings
                .iter()
                .filter(|finding| is_lint_finding(finding))
                .count() as i64;
            lint_findings += lint_count;
            sarif_findings += annotation.findings.len() as i64 - lint_count;
            dark_arms += annotation.dark_arms.len().max(annotation.dark_arm_spans.len()) as i64;
            hazards += annotation.hazards.len() as i64;
            unverified_hazards += annotation
                .hazards
                .iter()
                .filter(|hazard| !hazard.verified)
                .count() as i64;
            bug_weight += annotation.bug_weight;
            semantic_churn += annotation.semantic_churn;
        }

        let line_count = (end_line.saturating_sub(symbol.start_line) + 1).max(1) as f64;
        let density = (sarif_findings as f64 * 0.45
            + lint_findings as f64 * 0.08
            + dark_arms as f64 * 1.2
            + hazards as f64 * 1.6
            + unverified_hazards as f64 * 1.5)
            / line_count.sqrt();
        let history = bug_weight * 3.0 + semantic_churn.min(line_count) / line_count.max(1.0);
        let score = density + history;

        symbol.sarif_findings = sarif_findings + lint_findings;
        symbol.dark_arms = dark_arms;
        symbol.hazards = hazards;
        symbol.unverified_hazards = unverified_hazards;
        symbol.bug_weight = bug_weight.min(1.0);
        symbol.semantic_churn = semantic_churn.min(1.0);
        symbol.hotspot_score = score;
        symbol.hotspot_level = hotspot_level(score).to_string();
    }
}

fn hotspot_level(score: f64) -> &'static str {
    if score >= 8.0 {
        "deep-red"
    } else if score >= 5.0 {
        "red"
    } else if score >= 3.5 {
        "light-red"
    } else if score >= 2.0 {
        "orange"
    } else if score >= 1.0 {
        "yellow"
    } else if score >= 0.35 {
        "light-green"
    } else if score > 0.0 {
        "green"
    } else {
        "dark-green"
    }
}

fn apply_espalier_effect_spans(
    path: &str,
    source_lines: &[String],
    annotations: &mut Vec<UiLineAnnotation>,
    effects: &[EspalierFunctionEffect],
) {
    if effects.is_empty() {
        return;
    }

    let mut by_line = annotations
        .drain(..)
        .map(|annotation| (annotation.line, annotation))
        .collect::<BTreeMap<_, _>>();
    for effect in effects {
        let tokens = effect_tokens(effect);
        for line_no in effect.start_line..=effect.end_line {
            let Some(source) = source_lines.get(line_no.saturating_sub(1) as usize) else {
                continue;
            };
            let mut spans = Vec::new();
            for (kind, label, token) in &tokens {
                spans.extend(find_effect_token_ranges(path, source, token).into_iter().map(
                    |(start, end)| UiEffectSpan {
                        kind: kind.clone(),
                        label: label.clone(),
                        start,
                        end,
                    },
                ));
            }
            if spans.is_empty() {
                continue;
            }
            by_line
                .entry(line_no)
                .or_insert_with(|| empty_annotation(line_no))
                .effect_spans
                .extend(spans);
        }
    }

    *annotations = by_line.into_values().collect();
}

fn effect_tokens(effect: &EspalierFunctionEffect) -> Vec<(String, String, String)> {
    let mut tokens = Vec::new();
    tokens.extend(effect.reads.iter().map(|name| {
        (
            "state-read".to_string(),
            format!("state read {name}"),
            name.clone(),
        )
    }));
    tokens.extend(effect.writes.iter().map(|name| {
        (
            "state-write".to_string(),
            format!("state write {name}"),
            name.clone(),
        )
    }));
    tokens.extend(effect.impure_calls.iter().map(|name| {
        (
            "impure-call".to_string(),
            format!("impure call {name}"),
            name.clone(),
        )
    }));
    tokens
}

fn find_effect_token_ranges(path: &str, source: &str, token: &str) -> Vec<(usize, usize)> {
    let token = token.trim();
    if token.is_empty() {
        return Vec::new();
    }

    let mut ranges = Vec::new();
    let mut offset = 0;
    while let Some(relative) = source[offset..].find(token) {
        let start = offset + relative;
        let end = start + token.len();
        if token_boundaries_ok(source, start, end) && !is_in_string_or_comment(path, source, start, end) {
            ranges.push((start, end));
        }
        offset = end;
    }
    ranges
}

fn is_in_string_or_comment(path: &str, source: &str, range_start: usize, _range_end: usize) -> bool {
    let language = syntax_language(path);
    if language == SyntaxLanguage::Plain {
        return false;
    }
    let mut chars = source.char_indices().peekable();
    while let Some((start, ch)) = chars.next() {
        if let Some(prefix) = comment_prefix(language) {
            if source[start..].starts_with(prefix) {
                if range_start >= start {
                    return true;
                }
                break;
            }
        }
        if is_string_delimiter(language, ch) {
            let end = scan_string(source, &mut chars, ch);
            if range_start >= start && range_start < end {
                return true;
            }
            continue;
        }
        if ch.is_ascii_digit() {
            let _ = scan_while(source, &mut chars, |candidate| {
                candidate.is_ascii_alphanumeric() || matches!(candidate, '_' | '.' | ':')
            });
            continue;
        }
        if is_identifier_start(ch) {
            let _ = scan_while(source, &mut chars, is_identifier_continue);
            continue;
        }
    }
    false
}

fn token_boundaries_ok(source: &str, start: usize, end: usize) -> bool {
    let before = source[..start].chars().next_back();
    let after = source[end..].chars().next();
    !before.map(is_effect_identifier_continue).unwrap_or(false)
        && !after.map(is_effect_identifier_continue).unwrap_or(false)
}

fn is_effect_identifier_continue(ch: char) -> bool {
    ch == '_' || ch == '@' || ch == '$' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric()
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
    let sarif_start = Instant::now();
    apply_sarif_findings(storage, path, &mut lines)?;
    profile_log("line_annotations.sarif_findings", sarif_start);
    let overlay_start = Instant::now();
    apply_overlays(path, overlays, &mut lines);
    profile_log("line_annotations.overlays", overlay_start);

    let annotations = lines
        .into_iter()
        .map(|(line, builder)| UiLineAnnotation {
            line,
            covered: builder.covered,
            is_partial: builder.is_partial,
            mutant_tested: builder.mutant_tested,
            test_types: builder.test_types.into_iter().collect(),
            distinct_tests: builder.distinct_tests,
            mutant_verified_tests: builder.mutant_verified_tests,
            mutant_killed_tests: builder.mutant_killed_tests,
            stochastic_mutant_verified_tests: builder.stochastic_mutant_verified_tests,
            invariant_mutant_verified_tests: builder.invariant_mutant_verified_tests,
            line_hits: builder.line_hits,
            line_coverage: builder.line_coverage,
            mutant_coverage: builder.mutant_coverage,
            dark_arms: builder.dark_arms,
            dark_arm_spans: builder.dark_arm_spans,
            effect_spans: builder.effect_spans,
            findings: builder.findings,
            hazards: builder.hazards,
            test_type_counts: builder.test_type_counts,
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
    let mut annotation = empty_annotation(line);
    annotation.covered = true;
    annotation
}

fn empty_annotation(line: u32) -> UiLineAnnotation {
    UiLineAnnotation {
        line,
        covered: false,
        is_partial: false,
        mutant_tested: false,
        test_types: Vec::new(),
        distinct_tests: 0,
        mutant_verified_tests: 0,
        mutant_killed_tests: 0,
        stochastic_mutant_verified_tests: 0,
        invariant_mutant_verified_tests: 0,
        line_hits: None,
        line_coverage: None,
        mutant_coverage: None,
        dark_arms: Vec::new(),
        dark_arm_spans: Vec::new(),
        effect_spans: Vec::new(),
        findings: Vec::new(),
        hazards: Vec::new(),
        test_type_counts: BTreeMap::new(),
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
        include_str!("../../sql/ui/runtime/apply_unit_quality.sql"),
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
        include_str!("../../sql/ui/runtime/apply_line_coverage.sql"),
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((row.get::<_, u32>(0)?, row.get::<_, u32>(1)?, row.get::<_, i64>(2)?))
    })?;

    let mut has_exact_line_coverage = false;
    for row in rows {
        let (line, hits, is_partial) = row?;
        has_exact_line_coverage = true;
        let entry = lines.entry(line).or_default();
        entry.line_hits = Some(hits);
        if hits > 0 {
            entry.covered = true;
        }
        if is_partial != 0 {
            entry.is_partial = true;
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
        include_str!("../../sql/ui/runtime/apply_test_exposure.sql"),
    )?;
    let rows = stmt.query_map(params![path], |row| {
        Ok((
            row.get::<_, u32>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
        ))
    })?;
    for row in rows {
        let (
            line,
            test_type,
            tests,
            mutation_verified,
            mutation_killed,
            stochastic_mutation_verified,
            invariant_mutation_verified,
        ) = row?;
        let entry = lines.entry(line).or_default();
        if paint_line_coverage {
            entry.covered = true;
        }
        entry.test_types.insert(test_type.clone());
        *entry.test_type_counts.entry(test_type).or_insert(0) += tests;
        entry.distinct_tests += tests;
        entry.mutant_verified_tests += mutation_verified;
        entry.mutant_killed_tests += mutation_killed;
        entry.stochastic_mutant_verified_tests += stochastic_mutation_verified;
        entry.invariant_mutant_verified_tests += invariant_mutation_verified;
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
        include_str!("../../sql/ui/runtime/apply_hazards.sql"),
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
    let (fix_first, fix_last) = fix_decay_bounds(storage)?.unwrap_or((first, last));
    let discount_old_fixes_after_quality_jumps = has_multicommit_quality_history(storage)?;
    apply_semantic_churn(
        storage,
        path,
        lines,
        first,
        last,
        fix_first,
        fix_last,
        discount_old_fixes_after_quality_jumps,
    )?;
    apply_crash_history(storage, path, lines, first, last)?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn apply_semantic_churn(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
    first_timestamp: i64,
    last_timestamp: i64,
    fix_first_timestamp: i64,
    fix_last_timestamp: i64,
    discount_old_fixes_after_quality_jumps: bool,
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/apply_semantic_churn.sql"),
    )?;
    let quality_discount_enabled = if discount_old_fixes_after_quality_jumps {
        1
    } else {
        0
    };
    let rows = stmt.query_map(params![path, quality_discount_enabled], |row| {
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
            row.get::<_, f64>(10)?,
            row.get::<_, f64>(11)?,
            row.get::<_, f64>(12)?,
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
            protection_factor,
            target_factor,
            mutation_hardening_factor,
        ) = row?;
        let churn_weight = fix_cache_decay(timestamp, first_timestamp, last_timestamp);
        let fix_weight = if event_type == "FIX" {
            fix_cache_decay(timestamp, fix_first_timestamp, fix_last_timestamp)
                * protection_factor
                * target_factor
                * mutation_hardening_factor
        } else {
            churn_weight
        };
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
            entry.semantic_churn += churn_weight;
            entry.semantic_churn_events += 1;
            if event_type == "FIX" && fix_weight >= MIN_HISTORY_WEIGHT {
                push_bug_event(
                    entry,
                    UiBugEvent {
                        event_type: "fix".to_string(),
                        commit_hash: commit_hash.clone(),
                        timestamp,
                        path: event_path.clone(),
                        line,
                        label: fix_event_label(&name, &message),
                        weight: fix_weight,
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
        include_str!("../../sql/ui/runtime/apply_crash_history.sql"),
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
        include_str!("../../sql/ui/runtime/decay_bounds.sql"),
    )?;
    Ok(stmt.query_row([], |row| Ok((row.get(0)?, row.get(1)?)))?)
}

fn fix_decay_bounds(storage: &Storage) -> Result<Option<(i64, i64)>> {
    let mut stmt = storage.connection().prepare(
        include_str!("../../sql/ui/runtime/fix_decay_bounds.sql"),
    )?;
    let (first, last) = stmt.query_row([], |row| {
        Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?))
    })?;
    Ok(first.zip(last))
}

fn has_multicommit_quality_history(storage: &Storage) -> Result<bool> {
    let count: i64 = storage.connection().query_row(
        include_str!("../../sql/ui/runtime/has_multicommit_quality_history.sql"),
        [],
        |row| row.get(0),
    )?;
    Ok(count > 1)
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

fn fix_event_label(name: &str, message: &str) -> String {
    let first_line = message.lines().next().unwrap_or_default().trim();
    if first_line.is_empty() {
        name.trim().to_string()
    } else {
        first_line.to_string()
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

fn apply_sarif_findings(
    storage: &Storage,
    path: &str,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) -> Result<()> {
    for finding in storage.sarif_findings_for_path(path)? {
        let span = sarif_finding_span(
            finding.start_line,
            finding.start_column,
            finding.end_line,
            finding.end_column,
        );
        let label = sarif_finding_label(&finding.rule_id, &finding.category, &finding.message);
        let ui_finding = UiFinding {
            source: finding.source.clone(),
            tool: finding.tool_name.clone(),
            rule_id: finding.rule_id.clone(),
            level: finding.level.clone(),
            message: finding.message.clone(),
            category: finding.category.clone(),
            tier: sarif_finding_tier(&finding.properties_json),
            span,
            commit: finding.commit_hash.clone(),
            stale: false,
        };
        lines
            .entry(finding.start_line)
            .or_default()
            .findings
            .push(ui_finding);

        if finding.is_dark_arm {
            let arm = UiDarkArm {
                label,
                span,
            };
            let (first_line, last_line) = span
                .map(|span| (span[0], span[2].max(span[0])))
                .unwrap_or((finding.start_line, finding.start_line));
            for target_line in first_line..=last_line {
                let entry = lines.entry(target_line).or_default();
                if target_line == finding.start_line {
                    entry.dark_arms.push(arm.label.clone());
                }
                entry.dark_arm_spans.push(arm.clone());
            }
        }
    }
    Ok(())
}

fn sarif_finding_span(
    start_line: u32,
    start_column: Option<u32>,
    end_line: Option<u32>,
    end_column: Option<u32>,
) -> Option<[u32; 4]> {
    let end_line = end_line.unwrap_or(start_line);
    if start_column.is_none() && end_column.is_none() && end_line == start_line {
        return None;
    }
    let start = start_column.unwrap_or(1).saturating_sub(1);
    let end = end_column.unwrap_or(start + 1).saturating_sub(1);
    Some([start_line, start, end_line, end])
}

fn sarif_finding_label(rule_id: &str, category: &str, message: &str) -> String {
    if !category.trim().is_empty() {
        category.to_string()
    } else if !rule_id.trim().is_empty() {
        rule_id.to_string()
    } else {
        message.to_string()
    }
}

fn sarif_finding_tier(properties_json: &str) -> Option<i64> {
    let properties = serde_json::from_str::<Value>(properties_json).ok()?;
    properties
        .get("tier")
        .and_then(Value::as_i64)
        .or_else(|| {
            properties
                .get("decomplex_finding")
                .and_then(|finding| finding.get("tier"))
                .and_then(Value::as_i64)
        })
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

fn branch_context(repo: &Path) -> UiBranchContext {
    Repository::open(repo)
        .ok()
        .and_then(|repository| {
            let head = repository.head().ok()?;
            let branch = head.shorthand().unwrap_or("HEAD").to_string();
            let commit = head
                .target()
                .or_else(|| head.peel_to_commit().ok().map(|commit| commit.id()))
                .map(|oid| short_commit(&oid.to_string()))
                .unwrap_or_else(|| "unknown".to_string());
            Some(UiBranchContext { branch, commit })
        })
        .unwrap_or_else(|| UiBranchContext {
            branch: "unknown".to_string(),
            commit: "unknown".to_string(),
        })
}

#[allow(clippy::too_many_arguments)]
fn render_index_page(
    storage: &Storage,
    repo: &Path,
    overlays: &UiOverlays,
    scope: &CoverageScope,
    selected: Option<&str>,
    directory: Option<&str>,
    commit: Option<&str>,
    filter: &str,
    sort: CoverageSort,
    queue: Option<&str>,
    queue_page: usize,
) -> Result<String> {
    let files = file_index_with_scope(storage, scope, Some(repo))?;
    let selected_path = selected
        .map(normalize_source_path)
        .filter(|path| !path.is_empty());
    let requested_directory = directory.map(normalize_directory).unwrap_or_default();
    let current_directory = selected_path
        .as_deref()
        .map(parent_directory)
        .unwrap_or(requested_directory);
    let hotspots_limit = if queue.is_some() { 200 } else { 12 };
    let dashboard = dashboard_summary_for_directory_with_scope_and_repo(
        storage,
        &current_directory,
        scope,
        Some(repo),
        hotspots_limit,
    )?;
    let child_directories = directory_index(&files, &current_directory);
    let child_files = files_in_directory(&files, &current_directory);
    let filtered = filtered_files_in_directory(&files, filter, &current_directory);
    let branch_context = branch_context(repo);
    let payload = selected_path
        .as_deref()
        .map(|path| source_payload_with_overlays(storage, repo, path, commit, overlays))
        .transpose();

    let source_sidebar = matches!(&payload, Ok(Some(_)));
    let sidebar = match &payload {
        Ok(Some(payload)) => render_source_sidebar(payload, &current_directory, filter),
        _ => render_dashboard_sidebar(DashboardSidebarArgs {
            dashboard: &dashboard,
            current_directory: &current_directory,
            filter,
            files: &files,
            child_directories: &child_directories,
            child_files: &child_files,
            filtered_files: &filtered,
            selected_path: selected_path.as_deref(),
        }),
    };
    let main = match &payload {
        Ok(Some(payload)) => render_source_view(payload, filter, &branch_context),
        Ok(None) => match queue {
            Some("review-next") | Some("test-next") => render_queue_page(
                &dashboard,
                queue.unwrap_or_default(),
                &current_directory,
                filter,
                queue_page,
            ),
            _ => render_dashboard(
                &dashboard,
                &current_directory,
                &child_directories,
                &child_files,
                filter,
                sort,
                &branch_context,
            ),
        },
        Err(error) => render_source_unavailable(&error.to_string()),
    };
    let app = AppTemplate {
        source_sidebar,
        sidebar: &sidebar,
        main: &main,
    }
    .render()
    .context("render lineage app template")?;
    render_page("Lineage", &app)
}

fn render_page(title: &str, body: &str) -> Result<String> {
    IndexPageTemplate { title, body }
        .render()
        .context("render lineage index template")
}

struct DashboardSidebarArgs<'a> {
    dashboard: &'a UiDashboard,
    current_directory: &'a str,
    filter: &'a str,
    files: &'a [UiFile],
    child_directories: &'a [UiDirectory],
    child_files: &'a [&'a UiFile],
    filtered_files: &'a [&'a UiFile],
    selected_path: Option<&'a str>,
}

fn render_dashboard_sidebar(args: DashboardSidebarArgs<'_>) -> String {
    let summary = format!(
        "{} files{} | {:.1}% covered",
        args.dashboard.files,
        directory_label_suffix(args.current_directory),
        args.dashboard.coverage_percent
    );
    let nav = render_sidebar_navigation(args.current_directory, args.filter);
    let search_options =
        render_search_options(args.files, args.child_directories, args.current_directory);
    let file_links = render_sidebar_file_links(&args);
    render_template_string(
        DashboardSidebarTemplate {
            _summary: &summary,
            _nav: &nav,
            current_directory: args.current_directory,
            show_directory_input: !args.current_directory.is_empty(),
            filter: args.filter,
            search_options: &search_options,
            files: &file_links,
        },
        "dashboard sidebar template",
    )
}

fn render_sidebar_file_links(args: &DashboardSidebarArgs<'_>) -> String {
    let mut out = String::new();
    if args.filter.trim().is_empty() {
        if !args.current_directory.is_empty() {
            out.push_str(&render_parent_directory_link(
                args.current_directory,
                args.filter,
            ));
        }
        for directory in args.child_directories {
            out.push_str(&render_directory_link(directory, false, args.filter));
        }
        for file in args.child_files {
            let active = args.selected_path == Some(file.path.as_str());
            out.push_str(&render_file_link(file, active, args.filter));
        }
        if args.child_directories.is_empty() && args.child_files.is_empty() {
            out.push_str("<div class=\"empty\">No tracked files in this directory.</div>");
        }
    } else {
        for file in args.filtered_files {
            let active = args.selected_path == Some(file.path.as_str());
            out.push_str(&render_file_link(file, active, args.filter));
        }
        if args.filtered_files.is_empty() {
            out.push_str("<div class=\"empty\">No matching files in this directory.</div>");
        }
    }
    out
}

fn render_source_sidebar(payload: &UiSourcePayload, current_directory: &str, filter: &str) -> String {
    let nav = render_sidebar_navigation(current_directory, filter);
    let outline = render_source_outline(payload);
    render_template_string(
        SourceSidebarTemplate {
            _path: &payload.path,
            _nav: &nav,
            outline: &outline,
            show_empty_outline: outline.is_empty(),
        },
        "source sidebar template",
    )
}

fn render_source_unavailable(error: &str) -> String {
    render_template_string(SourceUnavailableTemplate { error }, "source unavailable template")
}

fn render_template_string<T: Template>(template: T, name: &str) -> String {
    template.render().unwrap_or_else(|error| {
        panic!("failed to render {name}: {error}");
    })
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

fn render_search_options(files: &[UiFile], directories: &[UiDirectory], directory: &str) -> String {
    let mut values = BTreeSet::new();
    for directory in directories {
        values.insert(format!("{}/", directory.path));
    }
    for file in files.iter().filter(|file| path_in_directory(&file.path, directory)) {
        values.insert(file.path.clone());
        if let Some(name) = file.path.rsplit('/').next() {
            values.insert(name.to_string());
        }
    }
    let mut out = String::new();
    out.push_str("<datalist id=\"lineage-search-options\">");
    for value in values {
        out.push_str("<option value=\"");
        out.push_str(&html_escape(&value));
        out.push_str("\"></option>");
    }
    out.push_str("</datalist>");
    out
}

fn render_source_outline(payload: &UiSourcePayload) -> String {
    if payload.symbols.is_empty() {
        return String::new();
    }

    let containers = outline_containers(&payload.symbols);
    let functions = outline_functions(&payload.symbols, &containers);
    let mut out = String::new();
    out.push_str("<nav class=\"outline\" aria-label=\"source outline\"><div class=\"outline-title\">Outline</div>");
    for entry in root_outline_entries(&containers, &functions) {
        render_outline_entry(&mut out, entry, &containers, &functions, payload);
    }
    out.push_str("</nav>");
    out
}

#[derive(Debug, Clone)]
struct OutlineContainer<'a> {
    symbol: &'a UiSourceSymbol,
    full_name: String,
    display_name: String,
    parent: Option<String>,
    depth: usize,
}

#[derive(Debug, Clone)]
struct OutlineFunction<'a> {
    symbol: &'a UiSourceSymbol,
    owner: Option<String>,
    display_name: String,
    depth: usize,
}

#[derive(Debug, Clone, Copy)]
enum OutlineEntry<'a> {
    Container(&'a OutlineContainer<'a>),
    Function(&'a OutlineFunction<'a>),
}

impl OutlineEntry<'_> {
    fn start_line(self) -> u32 {
        match self {
            OutlineEntry::Container(container) => container.symbol.start_line,
            OutlineEntry::Function(function) => function.symbol.start_line,
        }
    }

    fn kind_rank(self) -> u8 {
        match self {
            OutlineEntry::Container(_) => 0,
            OutlineEntry::Function(_) => 1,
        }
    }
}

fn outline_containers(symbols: &[UiSourceSymbol]) -> Vec<OutlineContainer<'_>> {
    let mut containers = Vec::new();
    for symbol in symbols.iter().filter(|symbol| is_outline_container(symbol)) {
        let parent = containers
            .iter()
            .filter(|container: &&OutlineContainer<'_>| outline_contains(container.symbol, symbol))
            .max_by_key(|container| container.symbol.start_line);
        let display_name = outline_short_name(&symbol.name);
        let full_name = parent
            .map(|container| format!("{}.{}", container.full_name, display_name))
            .unwrap_or_else(|| normalize_outline_owner(&symbol.name));
        containers.push(OutlineContainer {
            symbol,
            full_name,
            display_name,
            parent: parent.map(|container| container.full_name.clone()),
            depth: parent.map(|container| container.depth + 1).unwrap_or(0),
        });
    }
    containers
}

fn outline_functions<'a>(
    symbols: &'a [UiSourceSymbol],
    containers: &[OutlineContainer<'a>],
) -> Vec<OutlineFunction<'a>> {
    symbols
        .iter()
        .filter(|symbol| !is_outline_container(symbol))
        .map(|symbol| {
            let (qualified_owner, display_name) = outline_function_owner_and_name(symbol);
            let owner = qualified_owner
                .and_then(|owner| resolve_outline_owner(&owner, containers))
                .or_else(|| containing_outline_owner(symbol, containers));
            let depth = owner
                .as_ref()
                .and_then(|owner| containers.iter().find(|container| &container.full_name == owner))
                .map(|container| container.depth + 1)
                .unwrap_or(0);
            OutlineFunction {
                symbol,
                owner,
                display_name,
                depth,
            }
        })
        .collect()
}

fn is_outline_container(symbol: &UiSourceSymbol) -> bool {
    matches!(symbol.kind.as_str(), "module" | "class")
}

fn outline_contains(container: &UiSourceSymbol, child: &UiSourceSymbol) -> bool {
    container.start_line <= child.start_line
        && container.end_line >= child.end_line
        && (container.start_line, container.end_line) != (child.start_line, child.end_line)
}

fn outline_function_owner_and_name(symbol: &UiSourceSymbol) -> (Option<String>, String) {
    let normalized = normalize_outline_owner(&symbol.name);
    if let Some((owner, name)) = normalized.rsplit_once('.') {
        if owner == "self" {
            return (None, name.to_string());
        }
        return (Some(owner.to_string()), name.to_string());
    }
    (None, outline_short_name(&symbol.name))
}

fn outline_short_name(name: &str) -> String {
    normalize_outline_owner(name)
        .rsplit('.')
        .next()
        .unwrap_or(name)
        .trim_start_matches("self.")
        .to_string()
}

fn normalize_outline_owner(name: &str) -> String {
    name.replace("::", ".")
}

fn resolve_outline_owner(owner: &str, containers: &[OutlineContainer<'_>]) -> Option<String> {
    let normalized = normalize_outline_owner(owner);
    containers
        .iter()
        .find(|container| container.full_name == normalized)
        .or_else(|| {
            containers
                .iter()
                .find(|container| container.full_name.ends_with(&format!(".{normalized}")))
        })
        .or_else(|| containers.iter().find(|container| container.display_name == normalized))
        .map(|container| container.full_name.clone())
}

fn containing_outline_owner(
    symbol: &UiSourceSymbol,
    containers: &[OutlineContainer<'_>],
) -> Option<String> {
    containers
        .iter()
        .filter(|container| outline_contains(container.symbol, symbol))
        .max_by_key(|container| container.depth)
        .map(|container| container.full_name.clone())
}

fn root_outline_entries<'a>(
    containers: &'a [OutlineContainer<'a>],
    functions: &'a [OutlineFunction<'a>],
) -> Vec<OutlineEntry<'a>> {
    sorted_outline_entries(
        containers
            .iter()
            .filter(|container| container.parent.is_none())
            .map(OutlineEntry::Container)
            .chain(
                functions
                    .iter()
                    .filter(|function| function.owner.is_none())
                    .map(OutlineEntry::Function),
            ),
    )
}

fn child_outline_entries<'a>(
    owner: &str,
    containers: &'a [OutlineContainer<'a>],
    functions: &'a [OutlineFunction<'a>],
) -> Vec<OutlineEntry<'a>> {
    sorted_outline_entries(
        containers
            .iter()
            .filter(|container| container.parent.as_deref() == Some(owner))
            .map(OutlineEntry::Container)
            .chain(
                functions
                    .iter()
                    .filter(|function| function.owner.as_deref() == Some(owner))
                    .map(OutlineEntry::Function),
            ),
    )
}

fn sorted_outline_entries<'a>(
    entries: impl Iterator<Item = OutlineEntry<'a>>,
) -> Vec<OutlineEntry<'a>> {
    let mut entries = entries.collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        left.start_line()
            .cmp(&right.start_line())
            .then_with(|| left.kind_rank().cmp(&right.kind_rank()))
    });
    entries
}

fn render_outline_entry(
    out: &mut String,
    entry: OutlineEntry<'_>,
    containers: &[OutlineContainer<'_>],
    functions: &[OutlineFunction<'_>],
    payload: &UiSourcePayload,
) {
    match entry {
        OutlineEntry::Container(container) => {
            render_outline_symbol_link(out, container.symbol, &container.display_name, container.depth, payload);
            for child in child_outline_entries(&container.full_name, containers, functions) {
                render_outline_entry(out, child, containers, functions, payload);
            }
        }
        OutlineEntry::Function(function) => {
            render_outline_symbol_link(
                out,
                function.symbol,
                &function.display_name,
                function.depth,
                payload,
            );
        }
    }
}

fn render_outline_symbol_link(
    out: &mut String,
    symbol: &UiSourceSymbol,
    display_name: &str,
    depth: usize,
    payload: &UiSourcePayload,
) {
    let is_fn = symbol.kind == "function" || symbol.kind == "method";
    let is_reentrant = is_fn && (symbol.start_line as usize..=symbol.end_line as usize)
        .take(4)
        .any(|l| {
            payload.lines.get(l - 1)
                .map(|line| line.to_uppercase().contains("REENTRANT"))
                .unwrap_or(false)
        });
    let is_private = is_fn && {
        let path = &payload.path;
        if path.ends_with(".zig") {
            let def_line = payload.lines.get(symbol.start_line as usize - 1).map(|s| s.trim()).unwrap_or("");
            def_line.contains("fn ") && !def_line.contains("pub fn")
        } else if path.ends_with(".clear") {
            let def_line = payload.lines.get(symbol.start_line as usize - 1).map(|s| s.trim()).unwrap_or("");
            let upper = def_line.to_uppercase();
            upper.contains("FN ") && !upper.contains("PUB FN")
        } else if path.ends_with(".rb") {
            if symbol.name.starts_with('_') {
                true
            } else {
                let mut found_private = false;
                let start_idx = symbol.start_line as usize - 1;
                for idx in (0..start_idx).rev() {
                    if let Some(line) = payload.lines.get(idx) {
                        let trimmed = line.trim();
                        if trimmed == "private" {
                            found_private = true;
                            break;
                        }
                        if trimmed.starts_with("class ") || trimmed.starts_with("module ") || trimmed.starts_with("def ") {
                            break;
                        }
                    }
                }
                found_private
            }
        } else {
            symbol.name.starts_with('_')
        }
    };

    out.push_str("<a href=\"#L");
    out.push_str(&symbol.start_line.to_string());
    out.push('"');
    let effect_title = outline_effect_title(symbol);
    if !effect_title.is_empty() {
        out.push_str(" title=\"");
        out.push_str(&html_escape(&effect_title));
        out.push('"');
    }
    out.push_str(" class=\"");
    if symbol.impure {
        out.push_str("impure-symbol");
    } else if symbol.effect_known {
        out.push_str("pure-symbol");
    } else {
        out.push_str("unknown-symbol");
    }
    if is_private {
        out.push_str(" private-symbol");
    }
    out.push_str(" hotspot-");
    out.push_str(&html_escape(&symbol.hotspot_level));
    out.push_str(" outline-depth-");
    out.push_str(&depth.min(4).to_string());
    out.push_str("\"><span class=\"outline-rail\"><span class=\"outline-impure\" aria-label=\"");
    out.push_str(if symbol.impure { "impure" } else { "no recorded effects" });
    out.push_str("\">");
    if symbol.impure {
        out.push_str("<i class=\"fa-solid fa-link\" aria-hidden=\"true\"></i>");
    }
    out.push_str("</span><span class=\"outline-hotspot\" title=\"");
    out.push_str(&html_escape(&outline_hotspot_title(symbol)));
    out.push_str("\"></span></span><span class=\"outline-kind\">");
    out.push_str(&html_escape(&outline_kind_label(symbol)));
    out.push_str("</span><span class=\"outline-name\">");
    out.push_str(&html_escape(display_name));
    if is_reentrant {
        out.push_str(" <i class=\"fa-solid fa-recycle reentrant-icon\" title=\"Re-entrant\"></i>");
    }
    out.push_str("</span></a>");
    if let Some(architecture_id) = &symbol.architecture_id {
        out.push_str("<a class=\"outline-architecture architecture-band-");
        out.push_str(&html_escape(&symbol.architecture_band));
        out.push_str("\" href=\"/architecture/unit/");
        out.push_str(&percent_encode(architecture_id));
        out.push_str("\" title=\"Architecture pressure ");
        out.push_str(&format!("{:.1}", symbol.architecture_pressure));
        out.push_str("\" aria-label=\"Open architecture view for ");
        out.push_str(&html_escape(display_name));
        out.push_str("\">A</a>");
    }
}

fn outline_kind_label(symbol: &UiSourceSymbol) -> String {
    unit_kind_label(&symbol.kind, &symbol.name)
}

fn is_class_method_name(name: &str) -> bool {
    name.contains('.') || name.contains("::") || name.starts_with("self.")
}

fn outline_hotspot_title(symbol: &UiSourceSymbol) -> String {
    format!(
        "hotspot {:.2}: {} SARIF, {} partial, {} hazards ({} unverified), bug {:.2}, churn {:.2}",
        symbol.hotspot_score,
        symbol.sarif_findings,
        symbol.dark_arms,
        symbol.hazards,
        symbol.unverified_hazards,
        symbol.bug_weight,
        symbol.semantic_churn
    )
}

fn outline_effect_title(symbol: &UiSourceSymbol) -> String {
    if !symbol.effect_summary.is_empty() {
        return symbol.effect_summary.join("\n");
    }
    if symbol.effect_known {
        "pure (no state effects)".to_string()
    } else {
        String::new()
    }
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
    if file.sarif_findings > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"SARIF findings\">{}</span>",
            file.sarif_findings
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
    if directory.sarif_findings > 0 {
        out.push_str(&format!(
            "<span class=\"pill\" title=\"SARIF findings\">{}</span>",
            directory.sarif_findings
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

fn render_line_quality_bar(bar: LineQualityBar) -> String {
    let segments = line_quality_segments(bar);
    let title = format!(
        "{:.1}% covered; {} total, {} covered, {} multi-covered, {} partial, {} missed, {} mutant-backed",
        bar.coverage_percent.clamp(0.0, 100.0),
        bar.tracked_lines.max(0),
        bar.covered_lines.clamp(0, bar.tracked_lines.max(0)),
        bar.multi_type_lines.max(0),
        bar.partial_lines.max(0),
        missed_line_count(bar.tracked_lines, bar.covered_lines),
        bar.mutant_backed_lines.max(0)
    );
    format!(
        concat!(
            "<span class=\"coverage-bar line-quality-bar\" title=\"{}\">",
            "<span class=\"coverage-track\">",
            "<span class=\"coverage-multi\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-covered\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-partial\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-missed\" style=\"width:{:.3}%\"></span>",
            "</span><span class=\"mutant-track\">",
            "<span class=\"coverage-multi\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-covered\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-partial\" style=\"width:{:.3}%\"></span>",
            "<span class=\"coverage-missed\" style=\"width:{:.3}%\"></span>",
            "</span></span>"
        ),
        html_escape(&title),
        segments.multi,
        segments.covered,
        segments.partial,
        segments.missed,
        segments.mutant_multi,
        segments.mutant_covered,
        segments.mutant_partial,
        segments.mutant_gap
    )
}

fn line_quality_segments(bar: LineQualityBar) -> LineQualitySegments {
    let tracked_lines = bar.tracked_lines.max(0);
    if tracked_lines == 0 {
        let covered: f64 = bar.coverage_percent.clamp(0.0, 100.0);
        return LineQualitySegments {
            multi: 0.0,
            covered,
            partial: 0.0,
            missed: (100.0 - covered).max(0.0),
            mutant_multi: 0.0,
            mutant_covered: 0.0,
            mutant_partial: 0.0,
            mutant_gap: 100.0,
        };
    }
    let covered_lines = bar.covered_lines.clamp(0, tracked_lines);
    let partial_lines = bar.partial_lines.clamp(0, covered_lines);
    let full_covered_lines = covered_lines.saturating_sub(partial_lines);
    let multi_type_lines = bar.multi_type_lines.clamp(0, full_covered_lines);
    let covered_single_lines = full_covered_lines.saturating_sub(multi_type_lines);
    let missed_lines = tracked_lines.saturating_sub(covered_lines);
    let mutant_backed_lines = bar.mutant_backed_lines.clamp(0, covered_lines);
    let mutant_multi_lines = mutant_backed_lines.min(multi_type_lines);
    let remaining_mutant = mutant_backed_lines.saturating_sub(mutant_multi_lines);
    let mutant_covered_lines = remaining_mutant.min(covered_single_lines);
    let remaining_mutant = remaining_mutant.saturating_sub(mutant_covered_lines);
    let mutant_partial_lines = remaining_mutant.min(partial_lines);
    let mutant_painted_lines = mutant_multi_lines + mutant_covered_lines + mutant_partial_lines;
    LineQualitySegments {
        multi: percent(multi_type_lines, tracked_lines),
        covered: percent(covered_single_lines, tracked_lines),
        partial: percent(partial_lines, tracked_lines),
        missed: percent(missed_lines, tracked_lines),
        mutant_multi: percent(mutant_multi_lines, tracked_lines),
        mutant_covered: percent(mutant_covered_lines, tracked_lines),
        mutant_partial: percent(mutant_partial_lines, tracked_lines),
        mutant_gap: percent(tracked_lines.saturating_sub(mutant_painted_lines), tracked_lines),
    }
}

fn render_dashboard(
    dashboard: &UiDashboard,
    directory: &str,
    directories: &[UiDirectory],
    files: &[&UiFile],
    filter: &str,
    sort: CoverageSort,
    branch_context: &UiBranchContext,
) -> String {
    let directory = normalize_directory(directory);
    let coverage_context = dashboard_coverage_context(dashboard, directory.as_str(), files);
    let branch_context = render_branch_context(branch_context, &coverage_context, filter);
    let warnings = render_warning_banner(&dashboard.warnings);
    let active_hazards = render_active_hazards_section(dashboard);
    let finding_changes = render_finding_changes_section(dashboard);
    let review_next = render_review_next_section(dashboard, &directory, filter);
    let test_next = render_test_next_section(dashboard, &directory, filter);
    let highest_hazard_files = render_highest_hazard_files_section(dashboard, filter);
    let highest_risk_units = render_dashboard_disclosure(
        "Risky Units",
        false,
        &render_unit_hotspots(&dashboard.top_units, filter),
    );
    let highest_architecture_risks = render_dashboard_disclosure(
        "Architectural Risks",
        false,
        &render_architecture_risks(&dashboard.top_architecture_risks, filter),
    );
    let highest_complexity_functions = render_complexity_functions_section(dashboard, filter);
    let code_tree_heading = format!(
        "Directory entries ({} dirs - {} files - {} SARIF findings)",
        directories.len(),
        files.len(),
        dashboard.sarif_findings
    );
    let code_tree = render_code_tree_table(
        dashboard,
        &directory,
        directories,
        files,
        filter,
        sort,
    );
    render_template_string(
        DashboardTemplate {
            branch_context: &branch_context,
            warnings: &warnings,
            active_hazards: &active_hazards,
            finding_changes: &finding_changes,
            review_next: &review_next,
            test_next: &test_next,
            highest_hazard_files: &highest_hazard_files,
            highest_risk_units: &highest_risk_units,
            highest_architecture_risks: &highest_architecture_risks,
            highest_complexity_functions: &highest_complexity_functions,
            code_tree_heading: &code_tree_heading,
            code_tree: &code_tree,
        },
        "dashboard template",
    )
}

fn render_review_next_section(dashboard: &UiDashboard, directory: &str, filter: &str) -> String {
    let items = dashboard
        .review_next
        .iter()
        .take(10)
        .map(|item| {
            HotspotItem {
                href: format!("{}#L{}", page_href(&item.path, None, filter), item.start_line),
                kind: "review".to_string(),
                name: item.title.clone(),
                path: item.path.clone(),
                detail: item.detail.clone(),
                score: format!("{:.1}", item.score),
            }
        })
        .collect::<Vec<_>>();
    let mut body = render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots review-next",
            empty_message: "No current analyzer findings or hazards need review in this folder.",
            items: &items,
        },
        "review next template",
    );
    if dashboard.review_next.len() > 10 {
        body.push_str(&render_queue_see_more("review-next", directory));
    }
    render_dashboard_disclosure("Review Next", false, &body)
}

fn render_test_next_section(dashboard: &UiDashboard, directory: &str, filter: &str) -> String {
    let mut candidates = dashboard
        .test_next_units
        .iter()
        .filter_map(|unit| {
            let (test_type, rationale, priority) = test_next_recommendation(unit)?;
            Some((unit, test_type, rationale, priority))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        right
            .3
            .partial_cmp(&left.3)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.0.path.cmp(&right.0.path))
            .then_with(|| left.0.name.cmp(&right.0.name))
    });
    let has_more = candidates.len() > 10;
    let items = candidates
        .into_iter()
        .take(10)
        .map(|(unit, test_type, rationale, priority)| HotspotItem {
            href: format!("{}#L{}", page_href(&unit.path, None, filter), unit.start_line),
            kind: test_type.to_string(),
            name: unit.name.clone(),
            path: unit.path.clone(),
            detail: rationale,
            score: format!("{priority:.1}"),
        })
        .collect::<Vec<_>>();
    let mut body = render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots test-next",
            empty_message: "No high-value testing recommendation is available in this folder.",
            items: &items,
        },
        "test next template",
    );
    if has_more {
        body.push_str(&render_queue_see_more("test-next", directory));
    }
    render_dashboard_disclosure("Test Next", false, &body)
}

fn test_next_recommendation(unit: &UiUnitHotspot) -> Option<(&'static str, String, f64)> {
    let normalized_types = unit.test_types.to_lowercase();
    let only_sparse_unit_tests = unit.distinct_tests <= 2
        && !normalized_types.is_empty()
        && normalized_types
            .split(',')
            .all(|test_type| test_type.trim() == "unit");
    let uncovered = unit.line_coverage <= 0.0;
    let historically_buggy = unit.fixes > 0 || unit.reopened_count > 0;
    let base = unit.score + if unit.is_hard_gated { 5.0 } else { 0.0 };

    if unit.is_hard_gated && (unit.integration_coverage < 80.0 || only_sparse_unit_tests) {
        return Some((
            "integration",
            format!(
                "critical path; {}; {}; {} - add integration tests",
                if uncovered { "uncovered" } else { "coverage is incomplete" },
                if historically_buggy { "historically buggy" } else { "high-risk behavior" },
                if only_sparse_unit_tests { "only sparse unit tests" } else { "integration coverage is weak" },
            ),
            base + 8.0,
        ));
    }
    if unit.reopened_count > 0 {
        return Some((
            "regression",
            format!("{} fixes reopened; add a regression test for the failing workflow", unit.reopened_count),
            base + 7.0,
        ));
    }
    if unit.dark_arms > 0
        && !normalized_types.contains("property")
        && !normalized_types.contains("fuzz")
    {
        return Some((
            "property",
            format!("{} uncovered branch arms; add property or fuzz tests", unit.dark_arms),
            base + 5.0,
        ));
    }
    if unit.distinct_tests > 0 && unit.mutant_verified_tests == 0 {
        return Some((
            "mutation",
            "covered, but no test is mutation-verified; add assertions that kill representative mutants".to_string(),
            base + 3.0,
        ));
    }
    if uncovered || unit.distinct_tests == 0 {
        return Some((
            "unit",
            format!("{}; add focused unit tests before refactoring", if historically_buggy { "historically buggy and uncovered" } else { "uncovered behavior" }),
            base + 2.0,
        ));
    }
    None
}

const QUEUE_PAGE_SIZE: usize = 25;
const QUEUE_RESULT_LIMIT: usize = 200;

fn render_queue_see_more(queue: &str, directory: &str) -> String {
    format!(
        "<p class=\"queue-see-more\"><a href=\"{}\">See more <span aria-hidden=\"true\">&rarr;</span></a></p>",
        html_escape(&queue_href(queue, directory, 1))
    )
}

fn queue_href(queue: &str, directory: &str, page: usize) -> String {
    let mut pairs = vec![format!("queue={}", percent_encode(queue))];
    let directory = normalize_directory(directory);
    if !directory.is_empty() {
        pairs.push(format!("dir={}", percent_encode(&directory)));
    }
    if page > 1 {
        pairs.push(format!("page={page}"));
    }
    format!("/?{}", pairs.join("&"))
}

fn render_queue_page(
    dashboard: &UiDashboard,
    queue: &str,
    directory: &str,
    filter: &str,
    requested_page: usize,
) -> String {
    let (title, intro, items) = if queue == "review-next" {
        let items = dashboard
            .review_next
            .iter()
            .take(QUEUE_RESULT_LIMIT)
            .map(|item| HotspotItem {
                href: format!("{}#L{}", page_href(&item.path, None, filter), item.start_line),
                kind: "review".to_string(),
                name: item.title.clone(),
                path: item.path.clone(),
                detail: item.detail.clone(),
                score: format!("{:.1}", item.score),
            })
            .collect::<Vec<_>>();
        (
            "Review Next",
            "Current analyzer findings ranked by severity, uncovered behavior, and cross-analyzer agreement.",
            items,
        )
    } else {
        let mut candidates = dashboard
            .test_next_units
            .iter()
            .filter_map(|unit| {
                let (test_type, rationale, priority) = test_next_recommendation(unit)?;
                Some((unit, test_type, rationale, priority))
            })
            .collect::<Vec<_>>();
        candidates.sort_by(|left, right| {
            right
                .3
                .partial_cmp(&left.3)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| left.0.path.cmp(&right.0.path))
                .then_with(|| left.0.name.cmp(&right.0.name))
        });
        let items = candidates
            .into_iter()
            .take(QUEUE_RESULT_LIMIT)
            .map(|(unit, test_type, rationale, priority)| HotspotItem {
                href: format!("{}#L{}", page_href(&unit.path, None, filter), unit.start_line),
                kind: test_type.to_string(),
                name: unit.name.clone(),
                path: unit.path.clone(),
                detail: rationale,
                score: format!("{priority:.1}"),
            })
            .collect::<Vec<_>>();
        (
            "Test Next",
            "High-value testing work ranked by risk, coverage gaps, and the recommended testing type.",
            items,
        )
    };

    let page_count = items.len().div_ceil(QUEUE_PAGE_SIZE).max(1);
    let page = requested_page.clamp(1, page_count);
    let start = (page - 1) * QUEUE_PAGE_SIZE;
    let end = (start + QUEUE_PAGE_SIZE).min(items.len());
    let visible = &items[start..end];
    let list = render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots queue-page-items",
            empty_message: "No queue items are available in this folder.",
            items: visible,
        },
        "queue page items template",
    );
    let scope_label = if directory.is_empty() {
        "entire repository".to_string()
    } else {
        normalize_directory(directory)
    };
    let pagination = render_queue_pagination(queue, directory, page, page_count, items.len());
    format!(
        concat!(
            "<div class=\"viewer\"><section class=\"dashboard queue-page\">",
            "<header class=\"queue-page-header\">",
            "<a class=\"queue-back\" href=\"{}\">&larr; Back to directory</a>",
            "<h1>{}</h1><p>{} Scope: <strong>{}</strong>. Showing up to {} results.</p>",
            "</header>{}{}</section></div>"
        ),
        html_escape(&directory_href(directory, filter)),
        html_escape(title),
        html_escape(intro),
        html_escape(&scope_label),
        QUEUE_RESULT_LIMIT,
        list,
        pagination,
    )
}

fn render_queue_pagination(
    queue: &str,
    directory: &str,
    page: usize,
    page_count: usize,
    total: usize,
) -> String {
    if total == 0 {
        return render_dashboard_disclosure(
            "Finding Changes",
            false,
            "<p class=\"empty-inline\">No finding changes are recorded in this scope.</p>",
        );
    }
    let previous = if page > 1 {
        format!(
            "<a rel=\"prev\" href=\"{}\">&larr; Previous</a>",
            html_escape(&queue_href(queue, directory, page - 1))
        )
    } else {
        "<span></span>".to_string()
    };
    let next = if page < page_count {
        format!(
            "<a rel=\"next\" href=\"{}\">Next &rarr;</a>",
            html_escape(&queue_href(queue, directory, page + 1))
        )
    } else {
        "<span></span>".to_string()
    };
    format!(
        "<nav class=\"queue-pagination\" aria-label=\"Queue pages\">{}<span>Page {} of {} &middot; {} results</span>{}</nav>",
        previous, page, page_count, total, next
    )
}

fn render_directory_analyzer_status(dashboard: &UiDashboard) -> String {
    let mut problems = BTreeMap::<&str, &UiAnalyzerHealth>::new();
    for health in dashboard
        .analyzer_health
        .iter()
        .filter(|health| health.status != "healthy")
    {
        problems.entry(&health.analyzer).or_insert(health);
    }
    if problems.is_empty() {
        return concat!(
            "<span class=\"directory-health directory-health-current\" tabindex=\"0\" ",
            "aria-label=\"Analyzer artifacts for this directory are up to date\">",
            "<i class=\"fa-solid fa-circle-check\" aria-hidden=\"true\"></i>",
            "<span class=\"directory-health-tooltip\" role=\"tooltip\">",
            "All configured analyzer artifacts match the current indexed commit.",
            "</span></span>"
        )
        .to_string();
    }

    let detail = problems
        .into_values()
        .map(|health| {
            let fix = match health.status.as_str() {
                "missing" => "run lineage-import with first-party SARIF enabled",
                "stale" => "rerun lineage-import for the current commit",
                "degraded" => "regenerate the artifact with a higher result cap",
                _ => "regenerate and ingest the analyzer artifact",
            };
            format!("{}: {}. Fix: {fix}.", health.analyzer, health.detail)
        })
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        concat!(
            "<span class=\"directory-health directory-health-caution\" tabindex=\"0\" ",
            "aria-label=\"Analyzer artifacts for this directory need attention\">",
            "<i class=\"fa-solid fa-triangle-exclamation\" aria-hidden=\"true\"></i>",
            "<span class=\"directory-health-tooltip\" role=\"tooltip\">{}</span>",
            "</span>"
        ),
        html_escape(&detail)
    )
}

fn render_finding_changes_section(dashboard: &UiDashboard) -> String {
    if dashboard.new_findings == 0
        && dashboard.resolved_findings == 0
        && dashboard.persisted_findings == 0
    {
        return render_dashboard_disclosure(
            "Finding Changes",
            false,
            "<p class=\"empty-inline\">No finding changes are recorded in this scope.</p>",
        );
    }

    let body = format!(
        concat!(
            "<p class=\"finding-lifecycle\">",
            "<strong>{}</strong> new / ",
            "<strong>{}</strong> resolved / ",
            "<strong>{}</strong> persisted",
            "</p>"
        ),
        dashboard.new_findings,
        dashboard.resolved_findings,
        dashboard.persisted_findings,
    );
    render_dashboard_disclosure("Finding Changes", false, &body)
}

fn render_dashboard_disclosure(title: &str, open: bool, body: &str) -> String {
    let id = dashboard_panel_id(title);
    render_template_string(
        DashboardDisclosureTemplate {
            id,
            open,
            body,
        },
        "dashboard disclosure template",
    )
}

fn dashboard_panel_id(title: &str) -> &'static str {
    match title {
        "Active Hazards" => "dashboard-panel-active-hazards",
        "Finding Changes" => "dashboard-panel-finding-changes",
        "Review Next" => "dashboard-panel-review-next",
        "Test Next" => "dashboard-panel-test-next",
        "Hazard Files" => "dashboard-panel-highest-hazard-files",
        "Risky Units" => "dashboard-panel-highest-risk-units",
        "Architectural Risks" => "dashboard-panel-highest-architectural-risks",
        "Expensive Functions" => "dashboard-panel-high-complexity-functions",
        _ => "dashboard-panel-other",
    }
}

fn render_active_hazards_section(dashboard: &UiDashboard) -> String {
    let mut body = String::new();
    if dashboard.active_hazards == 0 {
        body.push_str("<p class=\"empty-inline\">No active systems hazards are recorded.</p>");
    } else {
        body.push_str(&render_dashboard_ratio_bar_row(
            "Hazard verification",
            dashboard.active_hazards,
            dashboard.covered_hazards,
            &format!(
                "{} total hazards / {} covered / {} with required systems evidence",
                dashboard.active_hazards,
                dashboard.covered_hazards,
                dashboard.evidence_covered_hazards
            ),
            "active hazards",
            "covered hazards",
            "hazard-bar",
        ));
    }
    render_dashboard_disclosure("Active Hazards", true, &body)
}

fn render_highest_hazard_files_section(dashboard: &UiDashboard, filter: &str) -> String {
    let files = dashboard
        .top_hazard_files
        .iter()
        .map(|file| DashboardHazardFileItem {
            href: page_href(&file.path, None, filter),
            path: file.path.clone(),
            detail: file_detail_text(file),
            hazards: file.hazards,
        })
        .collect::<Vec<_>>();
    let body = render_template_string(
        DashboardHazardFilesTemplate { files: &files },
        "dashboard hazard files template",
    );
    render_dashboard_disclosure(
        "Hazard Files",
        false,
        &body,
    )
}

fn render_dashboard_ratio_bar_row(
    label: &str,
    total: i64,
    covered: i64,
    detail: &str,
    total_label: &str,
    covered_label: &str,
    bar_class: &str,
) -> String {
    let bar = render_ratio_bar(total, covered, bar_class);
    render_template_string(
        DashboardRatioBarTemplate {
            label,
            detail,
            bar: &bar,
            total: total.max(0),
            total_label,
            covered: covered.max(0),
            covered_label,
        },
        "dashboard ratio bar template",
    )
}

fn render_ratio_bar(total: i64, covered: i64, bar_class: &str) -> String {
    let total = total.max(0);
    let covered = covered.clamp(0, total);
    let covered_percent = percent(covered, total);
    let missed_percent = 100.0 - covered_percent;
    format!(
        "<span class=\"ratio-bar {}\" title=\"{} of {} covered\"><span class=\"ratio-covered\" style=\"width:{:.3}%\"></span><span class=\"ratio-missed\" style=\"width:{:.3}%\"></span></span>",
        html_escape(bar_class),
        covered,
        total,
        covered_percent,
        missed_percent.max(0.0)
    )
}

fn dashboard_coverage_context(
    dashboard: &UiDashboard,
    directory: &str,
    files: &[&UiFile],
) -> UiCoverageContext {
    let partial_lines = files
        .iter()
        .map(|file| partial_line_count(file.covered_lines, file.dark_arm_findings))
        .sum::<i64>();
    let partial_lines = partial_lines.clamp(0, dashboard.covered_lines);
    UiCoverageContext {
        path: normalize_directory(directory),
        tracked_lines: dashboard.tracked_lines,
        covered_lines: dashboard.covered_lines,
        partial_lines,
        missed_lines: missed_line_count(dashboard.tracked_lines, dashboard.covered_lines),
        multi_type_lines: dashboard.multi_type_covered_lines,
        mutant_backed_lines: dashboard.mutant_verified_covered_lines,
        stochastic_mutant_backed_lines: dashboard.stochastic_mutant_verified_covered_lines,
        invariant_mutant_backed_lines: dashboard.invariant_mutant_verified_covered_lines,
        coverage_percent: dashboard.coverage_percent,
    }
}

fn source_coverage_context(payload: &UiSourcePayload) -> UiCoverageContext {
    let has_exact_line_hits = payload
        .annotations
        .iter()
        .any(|annotation| annotation.line_hits.is_some());
    let tracked_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            if has_exact_line_hits {
                annotation.line_hits.is_some()
            } else {
                annotation.line_coverage.is_some()
                    || annotation.covered
                    || !annotation.test_types.is_empty()
                    || !annotation.findings.is_empty()
                    || !annotation.hazards.is_empty()
            }
        })
        .count() as i64;
    let covered_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            if has_exact_line_hits {
                annotation.line_hits.unwrap_or(0) > 0
            } else {
                annotation.line_hits.unwrap_or(if annotation.covered { 1 } else { 0 }) > 0
            }
        })
        .count() as i64;
    let partial_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            (!has_exact_line_hits || annotation.line_hits.is_some())
                && annotation.is_partial
        })
        .count() as i64;
    let partial_lines = partial_lines.clamp(0, covered_lines);
    let multi_type_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            annotation_counts_for_coverage_context(annotation, has_exact_line_hits)
                && (annotation.line_hits.unwrap_or(0) > 1
                    || annotation.test_types.len() >= 2
                    || annotation.distinct_tests >= 2)
        })
        .count() as i64;
    let mutant_backed_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            annotation_counts_for_coverage_context(annotation, has_exact_line_hits)
                && annotation.mutant_verified_tests > 0
        })
        .count() as i64;
    let stochastic_mutant_backed_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            annotation_counts_for_coverage_context(annotation, has_exact_line_hits)
                && annotation.stochastic_mutant_verified_tests > 0
        })
        .count() as i64;
    let invariant_mutant_backed_lines = payload
        .annotations
        .iter()
        .filter(|annotation| {
            annotation_counts_for_coverage_context(annotation, has_exact_line_hits)
                && annotation.invariant_mutant_verified_tests > 0
        })
        .count() as i64;
    UiCoverageContext {
        path: payload.path.clone(),
        tracked_lines,
        covered_lines,
        partial_lines,
        missed_lines: missed_line_count(tracked_lines, covered_lines),
        multi_type_lines: multi_type_lines.clamp(0, covered_lines),
        mutant_backed_lines: mutant_backed_lines.clamp(0, covered_lines),
        stochastic_mutant_backed_lines: stochastic_mutant_backed_lines.clamp(0, covered_lines),
        invariant_mutant_backed_lines: invariant_mutant_backed_lines.clamp(0, covered_lines),
        coverage_percent: percent(covered_lines, tracked_lines),
    }
}

fn annotation_counts_for_coverage_context(
    annotation: &UiLineAnnotation,
    has_exact_line_hits: bool,
) -> bool {
    if has_exact_line_hits {
        annotation.line_hits.unwrap_or(0) > 0
    } else {
        annotation.line_hits.unwrap_or(if annotation.covered { 1 } else { 0 }) > 0
    }
}

fn partial_line_count(covered_lines: i64, partial_findings: i64) -> i64 {
    partial_findings.clamp(0, covered_lines.max(0))
}

fn file_partial_line_count(file: &UiFile) -> i64 {
    partial_line_count(
        file.covered_lines,
        file.partial_lines.max(file.dark_arm_findings),
    )
}

fn missed_line_count(tracked_lines: i64, covered_lines: i64) -> i64 {
    tracked_lines.saturating_sub(covered_lines.clamp(0, tracked_lines.max(0)))
}

fn render_branch_context(
    context: &UiBranchContext,
    coverage: &UiCoverageContext,
    filter: &str,
) -> String {
    let line_quality_bar = render_line_quality_bar(LineQualityBar {
        tracked_lines: coverage.tracked_lines,
        covered_lines: coverage.covered_lines,
        partial_lines: coverage.partial_lines,
        multi_type_lines: coverage.multi_type_lines,
        mutant_backed_lines: coverage.mutant_backed_lines,
        coverage_percent: coverage.coverage_percent,
    });
    let breadcrumbs = render_path_breadcrumb(&coverage.path, filter);
    let coverage_percent = format!("{:.2}", coverage.coverage_percent);
    render_template_string(
        BranchContextTemplate {
            branch: &context.branch,
            commit: &context.commit,
            coverage_percent: &coverage_percent,
            covered_lines: coverage.covered_lines,
            tracked_lines: coverage.tracked_lines,
            partial_lines: coverage.partial_lines,
            missed_lines: coverage.missed_lines,
            mutant_backed_lines: coverage.mutant_backed_lines.max(0),
            stochastic_mutant_backed_lines: coverage.stochastic_mutant_backed_lines.max(0),
            invariant_mutant_backed_lines: coverage.invariant_mutant_backed_lines.max(0),
            line_quality_bar: &line_quality_bar,
            breadcrumbs: &breadcrumbs,
        },
        "branch context template",
    )
}

fn render_path_breadcrumb(path: &str, filter: &str) -> String {
    let path = normalize_source_path(path);
    let mut out = String::new();
    out.push_str("<a href=\"");
    out.push_str(&html_escape(&directory_href("", filter)));
    out.push_str("\">clear</a>");
    if path.is_empty() {
        return out;
    }

    let parts = path.split('/').collect::<Vec<_>>();
    let mut current = String::new();
    for (index, part) in parts.iter().enumerate() {
        out.push_str("<span>/</span>");
        if !current.is_empty() {
            current.push('/');
        }
        current.push_str(part);
        if index + 1 == parts.len() {
            out.push_str("<strong>");
            out.push_str(&html_escape(part));
            out.push_str("</strong>");
        } else {
            out.push_str("<a href=\"");
            out.push_str(&html_escape(&directory_href(&current, filter)));
            out.push_str("\">");
            out.push_str(&html_escape(part));
            out.push_str("</a>");
        }
    }
    out
}

fn render_code_tree_table(
    dashboard: &UiDashboard,
    directory: &str,
    directories: &[UiDirectory],
    files: &[&UiFile],
    filter: &str,
    sort: CoverageSort,
) -> String {
    let name_header = render_sort_link("Name", CoverageSort::Path, sort, directory, filter);
    let total_header = render_sort_link("Total", CoverageSort::Total, sort, directory, filter);
    let covered_header = render_sort_link("Covered", CoverageSort::Covered, sort, directory, filter);
    let partial_header = render_sort_link("Partial", CoverageSort::Partial, sort, directory, filter);
    let missed_header = render_sort_link("Missed", CoverageSort::Missed, sort, directory, filter);
    let percent_header = render_sort_link("%", CoverageSort::Percent, sort, directory, filter);
    let directory_status = render_directory_analyzer_status(dashboard);
    let mut rows = String::new();
    for entry in sorted_code_tree_entries(directories, files, sort) {
        rows.push_str(&render_code_tree_row(
            &entry,
            directory,
            filter,
            &directory_status,
        ));
    }
    let empty = directories.is_empty() && files.is_empty();
    let partial = files
        .iter()
        .map(|file| partial_line_count(file.covered_lines, file.dark_arm_findings))
        .sum::<i64>();
    let partial = partial.clamp(0, dashboard.covered_lines);
    let subtotal = render_coverage_table_row(
        None,
        None,
        "",
        "Subtotal",
        "",
        dashboard.tracked_lines,
        dashboard.covered_lines,
        partial,
        dashboard.multi_type_covered_lines,
        dashboard.mutant_verified_covered_lines,
        dashboard.coverage_percent,
        dashboard.active_hazards,
        dashboard.evidence_covered_hazards,
        dashboard.covered_hazards,
    );
    render_template_string(
        CoverageTableTemplate {
            name_header: &name_header,
            total_header: &total_header,
            covered_header: &covered_header,
            partial_header: &partial_header,
            missed_header: &missed_header,
            percent_header: &percent_header,
            rows: &rows,
            empty,
            subtotal: &subtotal,
        },
        "coverage table template",
    )
}

#[derive(Debug, Clone, PartialEq)]
enum CodeTreeEntry<'a> {
    Directory(&'a UiDirectory),
    File(&'a UiFile),
}

impl CodeTreeEntry<'_> {
    fn name(&self) -> &str {
        match self {
            CodeTreeEntry::Directory(directory) => &directory.path,
            CodeTreeEntry::File(file) => &file.path,
        }
    }

    fn tracked_lines(&self) -> i64 {
        match self {
            CodeTreeEntry::Directory(directory) => directory.tracked_lines,
            CodeTreeEntry::File(file) => file.tracked_lines,
        }
    }

    fn covered_lines(&self) -> i64 {
        match self {
            CodeTreeEntry::Directory(directory) => directory.covered_lines,
            CodeTreeEntry::File(file) => file.covered_lines,
        }
    }

    fn partial_findings(&self) -> i64 {
        match self {
            CodeTreeEntry::Directory(directory) => directory.dark_arm_findings,
            CodeTreeEntry::File(file) => file.dark_arm_findings,
        }
    }

    fn missed_lines(&self) -> i64 {
        missed_line_count(self.tracked_lines(), self.covered_lines())
    }

    fn line_coverage(&self) -> f64 {
        match self {
            CodeTreeEntry::Directory(directory) => directory.line_coverage,
            CodeTreeEntry::File(file) => file.line_coverage,
        }
    }

    fn path_for_tiebreak(&self) -> &str {
        self.name()
    }
}

fn sorted_code_tree_entries<'a>(
    directories: &'a [UiDirectory],
    files: &'a [&'a UiFile],
    sort: CoverageSort,
) -> Vec<CodeTreeEntry<'a>> {
    let mut entries = directories
        .iter()
        .map(CodeTreeEntry::Directory)
        .chain(files.iter().copied().map(CodeTreeEntry::File))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| match sort {
        CoverageSort::Path => code_tree_entry_kind_rank(left)
            .cmp(&code_tree_entry_kind_rank(right))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
        CoverageSort::Total => right
            .tracked_lines()
            .cmp(&left.tracked_lines())
            .then_with(|| code_tree_entry_kind_rank(left).cmp(&code_tree_entry_kind_rank(right)))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
        CoverageSort::Covered => right
            .covered_lines()
            .cmp(&left.covered_lines())
            .then_with(|| code_tree_entry_kind_rank(left).cmp(&code_tree_entry_kind_rank(right)))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
        CoverageSort::Partial => partial_line_count(right.covered_lines(), right.partial_findings())
            .cmp(&partial_line_count(left.covered_lines(), left.partial_findings()))
            .then_with(|| code_tree_entry_kind_rank(left).cmp(&code_tree_entry_kind_rank(right)))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
        CoverageSort::Missed => right
            .missed_lines()
            .cmp(&left.missed_lines())
            .then_with(|| code_tree_entry_kind_rank(left).cmp(&code_tree_entry_kind_rank(right)))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
        CoverageSort::Percent => right
            .line_coverage()
            .partial_cmp(&left.line_coverage())
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| code_tree_entry_kind_rank(left).cmp(&code_tree_entry_kind_rank(right)))
            .then_with(|| left.path_for_tiebreak().cmp(right.path_for_tiebreak())),
    });
    entries
}

fn code_tree_entry_kind_rank(entry: &CodeTreeEntry<'_>) -> u8 {
    match entry {
        CodeTreeEntry::Directory(_) => 0,
        CodeTreeEntry::File(_) => 1,
    }
}

fn render_code_tree_row(
    entry: &CodeTreeEntry<'_>,
    directory: &str,
    filter: &str,
    directory_status: &str,
) -> String {
    match entry {
        CodeTreeEntry::Directory(child) => {
            render_directory_coverage_row(child, directory, filter, directory_status)
        }
        CodeTreeEntry::File(file) => render_file_coverage_row(file, directory, filter),
    }
}

fn render_sort_link(
    label: &str,
    target: CoverageSort,
    active: CoverageSort,
    directory: &str,
    filter: &str,
) -> String {
    let mut out = String::new();
    out.push_str("<a class=\"sort-link");
    if target == active {
        out.push_str(" active-sort");
    }
    out.push_str("\" href=\"");
    out.push_str(&html_escape(&directory_sort_href(directory, filter, target)));
    out.push_str("\">");
    out.push_str(&html_escape(label));
    if target == active {
        let marker = if target == CoverageSort::Path {
            "asc"
        } else {
            "desc"
        };
        out.push_str("<span class=\"sort-marker\">");
        out.push_str(marker);
        out.push_str("</span>");
    }
    out.push_str("</a>");
    out
}

fn render_file_coverage_row(file: &UiFile, directory: &str, filter: &str) -> String {
    let display_path = file_display_path(&file.path, directory);
    let detail = format!(
        "{} hazards, {} SARIF, {} tests, {} mutant killed",
        file.hazards, file.sarif_findings, file.distinct_tests, file.mutant_killed_tests
    );
    render_coverage_table_row(
        None,
        Some(&page_href(&file.path, None, filter)),
        "fa-regular fa-file-lines",
        &display_path,
        &detail,
        file.tracked_lines,
        file.covered_lines,
        file_partial_line_count(file),
        file.multi_type_covered_lines,
        file.mutant_verified_covered_lines,
        file.line_coverage,
        file.hazards,
        file.evidence_covered_hazards,
        file.covered_hazards,
    )
}

fn render_directory_coverage_row(
    directory: &UiDirectory,
    parent: &str,
    filter: &str,
    analyzer_status: &str,
) -> String {
    let mut display_path = file_display_path(&directory.path, parent);
    if !display_path.ends_with('/') {
        display_path.push('/');
    }
    let detail = format!(
        "{} files, {} units, {} hazards, {} SARIF, {} tests, {} mutant killed",
        directory.files,
        directory.units,
        directory.hazards,
        directory.sarif_findings,
        directory.distinct_tests,
        directory.mutant_killed_tests
    );
    render_coverage_table_row(
        Some(analyzer_status),
        Some(&directory_href(&directory.path, filter)),
        "fa-regular fa-folder",
        &display_path,
        &detail,
        directory.tracked_lines,
        directory.covered_lines,
        directory.partial_lines,
        directory.multi_type_covered_lines,
        directory.mutant_killed_covered_lines,
        directory.line_coverage,
        directory.hazards,
        directory.evidence_covered_hazards,
        directory.covered_hazards,
    )
}

fn render_unit_hotspots(units: &[UiUnitHotspot], filter: &str) -> String {
    let items = units
        .iter()
        .map(|unit| HotspotItem {
            href: format!("{}#L{}", page_href(&unit.path, None, filter), unit.start_line),
            kind: unit_kind_label(&unit.kind, &unit.name),
            name: unit.name.clone(),
            path: unit.path.clone(),
            detail: format!(
            "{} SARIF, {} partial, {} hazards, {} fixes, {} tests, {} killed",
            unit.sarif_findings,
            unit.dark_arms,
            unit.hazards,
            unit.fixes,
            unit.distinct_tests,
            unit.mutant_killed_tests
            ),
            score: format!("{:.1}", unit.score),
        })
        .collect::<Vec<_>>();
    render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots",
            empty_message: "No function or class hotspots to show.",
            items: &items,
        },
        "unit hotspot template",
    )
}

fn render_architecture_risks(risks: &[UiArchitectureRisk], filter: &str) -> String {
    let items = risks
        .iter()
        .map(|risk| HotspotItem {
            href: risk.architecture_id.as_ref().map(|id| format!("/architecture/unit/{}", percent_encode(id))).unwrap_or_else(|| format!("{}#L{}", page_href(&risk.path, None, filter), risk.start_line)),
            kind: unit_kind_label(&risk.owner_kind, &risk.owner),
            name: risk.owner.clone(),
            path: risk.path.clone(),
            detail: format!(
            "{} Espalier, {} states, {} functions, {} impure, {} privacy",
            risk.findings,
            risk.states,
            risk.functions,
            risk.impure_functions,
            risk.privacy_candidates
            ),
            score: format!("{:.1}", risk.score),
        })
        .collect::<Vec<_>>();
    render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots architecture-hotspots",
            empty_message: "No Espalier architectural risks to show.",
            items: &items,
        },
        "architecture hotspot template",
    )
}

fn render_complexity_functions_section(dashboard: &UiDashboard, filter: &str) -> String {
    let items = dashboard
        .top_complexity_functions
        .iter()
        .map(|func| HotspotItem {
            href: format!("{}#L{}", page_href(&func.path, None, filter), func.start_line),
            kind: unit_kind_label("function", &func.name),
            name: func.name.clone(),
            path: func.path.clone(),
            detail: func.detail.clone(),
            score: func.runtime_complexity.clone(),
        })
        .collect::<Vec<_>>();

    let body = render_template_string(
        HotspotListTemplate {
            wrapper_class: "unit-hotspots complexity-hotspots",
            empty_message: "No high complexity functions to show.",
            items: &items,
        },
        "complexity functions template",
    );

    render_dashboard_disclosure(
        "Expensive Functions",
        false,
        &body,
    )
}

fn unit_kind_label(kind: &str, name: &str) -> String {
    match kind {
        "module" => "mod".to_string(),
        "class" => "class".to_string(),
        "function" if is_class_method_name(name) => "meth".to_string(),
        "function" => "func".to_string(),
        other => other.chars().take(5).collect(),
    }
}

fn percent_color_class(pct: f64) -> &'static str {
    if pct < 60.0 {
        "pct-dark-red"
    } else if pct < 70.0 {
        "pct-light-red"
    } else if pct < 80.0 {
        "pct-orange"
    } else if pct < 90.0 {
        "pct-yellow"
    } else {
        "pct-green"
    }
}

fn render_hazard_quality_bar(hazards: i64, covered_hazards: i64, killed_hazards: i64) -> String {
    let covered_percent = if hazards > 0 {
        percent(covered_hazards, hazards)
    } else {
        0.0
    };
    let mutant_killed_percent = if hazards > 0 {
        percent(killed_hazards, hazards)
    } else {
        0.0
    };
    let covered_only_percent = (covered_percent - mutant_killed_percent).max(0.0);
    let missed_percent = (100.0 - covered_percent).max(0.0);

    let title = format!(
        "{:.1}% hazard coverage; {} total, {} covered, {} mutant killed",
        if hazards > 0 { covered_percent } else { 100.0 },
        hazards,
        covered_hazards,
        killed_hazards
    );

    format!(
        concat!(
            "<span class=\"hazard-bar\" title=\"{}\">",
            "<span class=\"hazard-mutant-killed\" style=\"width:{:.3}%\"></span>",
            "<span class=\"hazard-covered-only\" style=\"width:{:.3}%\"></span>",
            "<span class=\"hazard-missed\" style=\"width:{:.3}%\"></span>",
            "</span>"
        ),
        html_escape(&title),
        mutant_killed_percent,
        covered_only_percent,
        missed_percent
    )
}

#[allow(clippy::too_many_arguments)]
fn render_coverage_table_row(
    analyzer_status: Option<&str>,
    href: Option<&str>,
    icon_class: &str,
    name: &str,
    detail: &str,
    tracked_lines: i64,
    covered_lines: i64,
    partial_findings: i64,
    multi_type_lines: i64,
    mutant_backed_lines: i64,
    line_coverage: f64,
    hazards: i64,
    evidence_covered_hazards: i64,
    covered_hazards: i64,
) -> String {
    let partial = partial_line_count(covered_lines, partial_findings);
    let covered = covered_lines.saturating_sub(partial);
    let missed = missed_line_count(tracked_lines, covered_lines);
    let percent_value = if tracked_lines > 0 && line_coverage.is_finite() {
        line_coverage.clamp(0.0, 100.0)
    } else {
        line_coverage
    };
    let hazard_percent_value = if hazards > 0 {
        percent(covered_hazards, hazards)
    } else {
        100.0
    };
    let mut out = String::new();
    out.push_str("<tr><td class=\"directory-status-cell\">");
    if let Some(analyzer_status) = analyzer_status {
        out.push_str(analyzer_status);
    }
    out.push_str("</td>");
    out.push_str("<th scope=\"row\" class=\"coverage-name\">");
    if let Some(href) = href {
        out.push_str("<a href=\"");
        out.push_str(&html_escape(href));
        out.push_str("\" class=\"coverage-name-link\"><i class=\"");
        out.push_str(&html_escape(icon_class));
        out.push_str("\" aria-hidden=\"true\"></i><span>");
        out.push_str(&html_escape(name));
        out.push_str("</span></a>");
    } else {
        out.push_str("<span>");
        out.push_str(&html_escape(name));
        out.push_str("</span>");
    }
    if !detail.is_empty() {
        out.push_str("<small>");
        out.push_str(&html_escape(detail));
        out.push_str("</small>");
    }
    // Coverage mode columns
    out.push_str("</th><td class=\"cov-col\">");
    out.push_str(&tracked_lines.to_string());
    out.push_str("</td><td class=\"cov-col\">");
    out.push_str(&covered.to_string());
    out.push_str("</td><td class=\"cov-col\">");
    out.push_str(&partial.to_string());
    out.push_str("</td><td class=\"cov-col\">");
    out.push_str(&missed.to_string());
    // Hazards mode columns
    out.push_str("</td><td class=\"haz-col\">");
    out.push_str(&hazards.to_string());
    out.push_str("</td><td class=\"haz-col\">");
    out.push_str(&covered_hazards.to_string());
    out.push_str("</td><td class=\"haz-col\">");
    out.push_str(&evidence_covered_hazards.to_string());
    // Coverage bar td
    out.push_str("</td><td class=\"coverage-cell\">");
    out.push_str("<div class=\"cov-bar-wrapper\">");
    out.push_str(&render_line_quality_bar(LineQualityBar {
        tracked_lines,
        covered_lines,
        partial_lines: partial,
        multi_type_lines,
        mutant_backed_lines,
        coverage_percent: percent_value,
    }));
    out.push_str("</div>");
    out.push_str("<div class=\"haz-bar-wrapper\">");
    out.push_str(&render_hazard_quality_bar(
        hazards,
        covered_hazards,
        evidence_covered_hazards,
    ));
    out.push_str("</div>");
    // Percentage tds (cov-col and haz-col)
    let cov_color = percent_color_class(percent_value);
    let haz_color = percent_color_class(hazard_percent_value);
    out.push_str("</td><td class=\"coverage-percent cov-col ");
    out.push_str(cov_color);
    out.push_str("\">");
    out.push_str(&format!("{percent_value:.2}%"));
    out.push_str("</td><td class=\"coverage-percent haz-col ");
    out.push_str(haz_color);
    out.push_str("\">");
    out.push_str(&format!("{hazard_percent_value:.2}%"));
    out.push_str("</td></tr>");
    out
}

fn file_display_path(path: &str, directory: &str) -> String {
    let directory = normalize_directory(directory);
    if directory.is_empty() {
        path.to_string()
    } else {
        path.strip_prefix(&format!("{directory}/"))
            .unwrap_or(path)
            .to_string()
    }
}

fn file_detail_text(file: &UiFile) -> String {
    format!(
        "{} units | {} / {} lines | {} hazards | {} SARIF | {} tests | {} mutant-killed tests",
        file.units,
        file.covered_lines,
        file.tracked_lines,
        file.hazards,
        file.sarif_findings,
        file.distinct_tests,
        file.mutant_killed_tests
    )
}

fn render_warning_banner(warnings: &[UiWarning]) -> String {
    let items = warnings
        .iter()
        .enumerate()
        .map(|(index, warning)| {
        let key = warning_dismiss_key(warning);
        let input_id = format!("warning-dismiss-{index}-{}", stable_slug(&key));
        WarningBannerItem {
            input_id,
            key,
            level: warning.level.clone(),
            label: warning.label.clone(),
            detail: warning.detail.clone(),
        }
        })
        .collect::<Vec<_>>();
    render_template_string(
        WarningBannerTemplate { warnings: &items },
        "warning banner template",
    )
}

fn warning_dismiss_key(warning: &UiWarning) -> String {
    let raw = format!("{}:{}:{}", warning.level, warning.label, warning.detail);
    format!("lineage.warning.{}", stable_slug(&raw))
}

fn stable_slug(input: &str) -> String {
    let mut out = String::new();
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_matches('-').chars().take(96).collect()
}

fn render_source_view(
    payload: &UiSourcePayload,
    filter: &str,
    branch_context: &UiBranchContext,
) -> String {
    let annotations = payload
        .annotations
        .iter()
        .map(|annotation| (annotation.line, annotation))
        .collect::<BTreeMap<_, _>>();
    let blame = payload
        .blame
        .iter()
        .map(|blame| (blame.line, blame))
        .collect::<BTreeMap<_, _>>();
    let comment_folds = detect_comment_folds(&payload.path, &payload.lines);
    let comment_fold_lines = comment_fold_lines(&comment_folds);
    let fn_folds = payload.symbols.iter()
        .filter(|symbol| {
            (symbol.kind == "function" || symbol.kind == "method")
                && symbol.start_line < symbol.end_line
        })
        .enumerate()
        .map(|(idx, symbol)| {
            let is_private = {
                let path = &payload.path;
                if path.ends_with(".zig") {
                    let def_line = payload.lines.get(symbol.start_line as usize - 1).map(|s| s.trim()).unwrap_or("");
                    def_line.contains("fn ") && !def_line.contains("pub fn")
                } else if path.ends_with(".clear") {
                    let def_line = payload.lines.get(symbol.start_line as usize - 1).map(|s| s.trim()).unwrap_or("");
                    let upper = def_line.to_uppercase();
                    upper.contains("FN ") && !upper.contains("PUB FN")
                } else if path.ends_with(".rb") {
                    if symbol.name.starts_with('_') {
                        true
                    } else {
                        let mut found_private = false;
                        let start_idx = symbol.start_line as usize - 1;
                        for idx in (0..start_idx).rev() {
                            if let Some(line) = payload.lines.get(idx) {
                                let trimmed = line.trim();
                                if trimmed == "private" {
                                    found_private = true;
                                    break;
                               }
                               if trimmed.starts_with("class ") || trimmed.starts_with("module ") || trimmed.starts_with("def ") {
                                   break;
                               }
                            }
                        }
                        found_private
                    }
                } else {
                    symbol.name.starts_with('_')
                }
            };
            let closing_token = {
                if symbol.end_line as usize <= payload.lines.len() {
                    let last_line = payload.lines.get(symbol.end_line as usize - 1).map(|s| s.trim()).unwrap_or("");
                    if last_line == "}" || last_line == "end" {
                        last_line.to_string()
                    } else if last_line.ends_with('}') {
                        "}".to_string()
                    } else if last_line.ends_with("end") {
                        "end".to_string()
                    } else {
                        String::new()
                    }
                } else {
                    String::new()
                }
            };
            FunctionFold {
                id: idx + 1,
                start_line: symbol.start_line,
                end_line: symbol.end_line,
                is_private,
                closing_token,
            }
        })
        .collect::<Vec<_>>();
    let fn_fold_lines = {
        let mut by_line = BTreeMap::new();
        for fold in &fn_folds {
            for line in fold.start_line..=fold.end_line {
                by_line.insert(
                    line,
                    FunctionFoldLine {
                        id: fold.id,
                        start_line: fold.start_line,
                        end_line: fold.end_line,
                        is_start: line == fold.start_line,
                        is_private: fold.is_private,
                        closing_token: fold.closing_token.clone(),
                    },
                );
            }
        }
        by_line
    };
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
    let findings: usize = payload
        .annotations
        .iter()
        .map(|annotation| annotation.findings.len())
        .sum();

    let summary = format!(
        "{} covered lines | {} mutant lines | {} hazards | {} partial | {} SARIF",
        covered, mutant, hazards, dark_arms, findings
    );
    let layers_menu = render_layers_menu();
    let branch_context = render_branch_context(
        branch_context,
        &source_coverage_context(payload),
        filter,
    );
    let warnings = render_warning_banner(&payload.warnings);
    let mut code_lines = String::new();
    for (index, line) in payload.lines.iter().enumerate() {
        let line_no = (index + 1) as u32;
        code_lines.push_str(&render_code_line(
            &payload.path,
            line_no,
            line,
            annotations.get(&line_no).copied(),
            blame.get(&line_no).copied(),
            comment_fold_lines.get(&line_no),
            fn_fold_lines.get(&line_no),
        ));
    }
    let history = render_history(payload, filter);
    render_template_string(
        SourceViewTemplate {
            path: &payload.path,
            summary: &summary,
            layers_menu: &layers_menu,
            branch_context: &branch_context,
            warnings: &warnings,
            code_lines: &code_lines,
            history: &history,
        },
        "source view template",
    )
}

fn render_layers_menu() -> String {
    render_template_string(LayersMenuTemplate, "layers menu template")
}

fn render_history(payload: &UiSourcePayload, filter: &str) -> String {
    let mut out = String::new();
    out.push_str("<details class=\"history-drawer\"><summary><span>File history");
    if !payload.versions.is_empty() {
        out.push_str(&format!(" ({})", payload.versions.len()));
    }
    out.push_str("</span><span>Open history</span></summary><div class=\"history-list\">");
    out.push_str("<a class=\"history-row current\" href=\"");
    out.push_str(&html_escape(&page_href(&payload.path, None, filter)));
    out.push_str("\"><code>current</code><span>working tree</span><span></span><span>");
    out.push_str(&html_escape(&payload.path));
    out.push_str("</span><span></span></a>");
    for version in &payload.versions {
        let href = page_href(&payload.path, Some(&version.commit_hash), filter);
        out.push_str("<a href=\"");
        out.push_str(&html_escape(&href));
        out.push_str("\" class=\"history-row\"><code>");
        out.push_str(&html_escape(&short_commit(&version.commit_hash)));
        out.push_str("</code><span>");
        out.push_str(&html_escape(&date_utc(version.timestamp)));
        out.push_str("</span><span>");
        out.push_str(&html_escape(&version.event_type.to_ascii_lowercase()));
        out.push_str("</span><span>");
        out.push_str(&html_escape(&version.name));
        out.push_str("</span><span>");
        out.push_str(&format!(
            "{}-{} {}",
            version.start_line,
            version.end_line,
            if version.semantic_change { "semantic" } else { "non-semantic" }
        ));
        out.push_str("</span>");
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
    blame: Option<&UiLineBlame>,
    comment_fold: Option<&CommentFoldLine>,
    fn_fold: Option<&FunctionFoldLine>,
) -> String {
    let mut classes = vec!["row"];
    if annotation.map(|a| a.covered).unwrap_or(false) {
        classes.push("covered");
    }
    if annotation.map(|a| a.mutant_tested).unwrap_or(false) {
        classes.push("mutant");
    }
    if annotation.map(|a| a.covered && a.is_partial).unwrap_or(false) {
        classes.push("dark-arm");
    }
    if annotation.map(|a| a.semantic_churn > 0.0).unwrap_or(false) {
        classes.push("has-churn");
    }
    if annotation.map(|a| !a.bug_events.is_empty()).unwrap_or(false) {
        classes.push("has-bugs");
    }
    if comment_fold.map(|fold| !fold.is_start).unwrap_or(false) {
        classes.push("comment-fold-child");
    }
    if fn_fold.map(|fold| !fold.is_start).unwrap_or(false) {
        classes.push("fn-fold-child");
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

    let bug_id = format!("L{line_no}-fixes");
    let meta_id = format!("L{line_no}-details");
    let hazard_id = format!("L{line_no}-hazards");
    let has_bug_history = annotation.map(|a| !a.bug_events.is_empty()).unwrap_or(false);
    let has_line_details = annotation.map(line_has_details).unwrap_or(false);
    let has_hazards = annotation.map(|a| !a.hazards.is_empty()).unwrap_or(false);
    let finding_tools = annotation
        .map(first_party_finding_tools)
        .unwrap_or_default();
    let fold_input_id = comment_fold
        .filter(|fold| fold.is_start)
        .map(|fold| format!("comment-fold-{}", fold.id));
    let fn_fold_input_id = fn_fold
        .filter(|fold| fold.is_start)
        .map(|fold| format!("fn-fold-{}", fold.id));

    let fold_child_attr = comment_fold
        .filter(|fold| !fold.is_start)
        .map(|fold| format!(" data-comment-fold-child=\"{}\"", fold.id))
        .unwrap_or_default();
    let fn_fold_child_attr = fn_fold
        .filter(|fold| !fold.is_start)
        .map(|fold| format!(" data-fn-fold-child=\"{}\"", fold.id))
        .unwrap_or_default();
    let mut out = format!(
        "<div id=\"L{}\" class=\"{}\"{}{}{}>",
        line_no,
        classes.join(" "),
        fold_child_attr,
        fn_fold_child_attr,
        style,
    );
    if let Some(input_id) = &fold_input_id {
        out.push_str("<input class=\"comment-fold-toggle\" type=\"checkbox\" id=\"");
        out.push_str(&html_escape(input_id));
        out.push_str("\" checked data-persist-key=\"lineage.comment-fold.");
        out.push_str(&html_escape(path));
        out.push('.');
        out.push_str(&line_no.to_string());
        out.push_str("\" data-fold-id=\"");
        out.push_str(&comment_fold.map(|fold| fold.id).unwrap_or_default().to_string());
        out.push_str("\">");
    }
    if let Some(input_id) = &fn_fold_input_id {
        out.push_str("<input class=\"fn-fold-toggle");
        if fn_fold.map(|f| f.is_private).unwrap_or(false) {
            out.push_str(" private-fn-fold");
        }
        out.push_str("\" type=\"checkbox\" id=\"");
        out.push_str(&html_escape(input_id));
        if fn_fold.map(|f| f.is_private).unwrap_or(false) {
            out.push_str("\" checked");
        } else {
            out.push('"');
        }
        out.push_str(" data-persist-key=\"lineage.fn-fold.");
        out.push_str(&html_escape(path));
        out.push('.');
        out.push_str(&line_no.to_string());
        out.push_str("\" data-fold-id=\"");
        out.push_str(&fn_fold.map(|fold| fold.id).unwrap_or_default().to_string());
        out.push_str("\">");
    }
    if has_bug_history {
        out.push_str("<input class=\"line-toggle bug-toggle\" type=\"checkbox\" id=\"");
        out.push_str(&bug_id);
        out.push_str("\">");
    }
    if has_line_details {
        out.push_str("<input class=\"line-toggle meta-toggle\" type=\"checkbox\" id=\"");
        out.push_str(&meta_id);
        out.push_str("\">");
    }
    if has_hazards {
        out.push_str("<input class=\"line-toggle hazard-toggle\" type=\"checkbox\" id=\"");
        out.push_str(&hazard_id);
        out.push_str("\" data-panel-class=\"hazard-panel-open\">");
    }
    for tool in &finding_tools {
        let id = finding_panel_id(line_no, *tool);
        out.push_str("<input class=\"line-toggle tool-toggle ");
        out.push_str(tool.toggle_class());
        out.push_str("\" type=\"checkbox\" id=\"");
        out.push_str(&id);
        out.push_str("\" data-panel-class=\"");
        out.push_str(tool.open_class());
        out.push_str("\">");
    }
    out.push_str("<span class=\"hazard-rail\"");
    out.push_str(&hazard_title);
    out.push_str("></span><span class=\"gutter\"");
    out.push_str(&gutter_title);
    out.push('>');
    if let Some(annotation) = annotation {
        if has_hazards {
            out.push_str(&render_hazard_control(annotation, &hazard_id));
        }
        for tool in &finding_tools {
            let id = finding_panel_id(line_no, *tool);
            out.push_str(&render_finding_control(annotation, *tool, &id));
        }
        if has_bug_history {
            out.push_str(&render_bug_history_control(annotation, &bug_id));
        }
        if has_line_details {
            out.push_str(&render_line_details_control(&meta_id));
        }
    }
    out.push_str("</span><span class=\"ln\">");
    if let (Some(input_id), Some(fold)) = (&fold_input_id, comment_fold) {
        out.push_str("<label class=\"comment-fold-control\" for=\"");
        out.push_str(&html_escape(input_id));
        out.push_str("\" title=\"expand/collapse ");
        out.push_str(&format!(
            "{}-line comment",
            fold.end_line.saturating_sub(fold.start_line) + 1
        ));
        out.push_str("\"><span class=\"comment-fold-arrow\"></span></label>");
    } else if let (Some(input_id), Some(_fold)) = (&fn_fold_input_id, fn_fold) {
        out.push_str("<label class=\"fn-fold-control\" for=\"");
        out.push_str(&html_escape(input_id));
        out.push_str("\" title=\"expand/collapse function\"><span class=\"fn-fold-arrow\"></span></label>");
    } else {
        out.push_str("<span class=\"comment-fold-slot\"></span>");
    }
    out.push_str("<span class=\"line-number\">");
    out.push_str(&line_no.to_string());
    out.push_str("</span>");
    out.push_str("</span><pre class=\"source-text\">");
    if let Some(fold) = comment_fold {
        if fold.is_start {
            out.push_str("<span class=\"fold-full-source\">");
            out.push_str(&highlight_source_line_with_dark_arms(
                path, line_no, source, annotation,
            ));
            out.push_str("</span><span class=\"fold-collapsed-source\">");
            out.push_str(&highlight_source_line_with_dark_arms(
                path,
                line_no,
                &collapsed_comment_source(source),
                annotation,
            ));
            out.push_str("</span>");
        } else {
            out.push_str(&highlight_source_line_with_dark_arms(
                path, line_no, source, annotation,
            ));
        }
    } else if let Some(fold) = fn_fold {
        if fold.is_start {
            out.push_str("<span class=\"fold-full-source\">");
            out.push_str(&highlight_source_line_with_dark_arms(
                path, line_no, source, annotation,
            ));
            out.push_str("</span><span class=\"fold-collapsed-source\">");
            out.push_str(&highlight_source_line_with_dark_arms(
                path,
                line_no,
                &collapsed_function_source(source, &fold.closing_token),
                annotation,
            ));
            out.push_str("</span>");
        } else {
            out.push_str(&highlight_source_line_with_dark_arms(
                path, line_no, source, annotation,
            ));
        }
    } else {
        out.push_str(&highlight_source_line_with_dark_arms(
            path, line_no, source, annotation,
        ));
    }
    out.push_str("</pre>");
    out.push_str(&render_blame_cell(blame));
    if let Some(annotation) = annotation {
        if has_hazards {
            out.push_str(&render_hazard_panel(annotation));
        }
        if has_bug_history {
            out.push_str(&render_bug_history_panel(annotation));
        }
        if has_line_details {
            out.push_str(&render_line_details_panel(annotation));
        }
        for tool in &finding_tools {
            out.push_str(&render_finding_panel(annotation, *tool));
        }
    }
    out.push_str("</div>");
    out
}

fn render_blame_cell(blame: Option<&UiLineBlame>) -> String {
    let Some(blame) = blame else {
        return "<span class=\"blame-cell empty-blame\"></span>".to_string();
    };
    let commits_after = blame.total_commits.saturating_sub(blame.ordinal);
    let title = format!(
        "commit #{} of {}; {} commit(s) after this in file blame\n{}\n{}",
        blame.ordinal,
        blame.total_commits,
        commits_after,
        blame.commit_hash,
        blame.author
    );
    let mut out = String::new();
    out.push_str("<span class=\"blame-cell\" title=\"");
    out.push_str(&html_escape(&title));
    out.push_str("\"><code>#");
    out.push_str(&blame.ordinal.to_string());
    out.push(' ');
    out.push_str(&html_escape(&short_commit(&blame.commit_hash)));
    out.push_str("</code><span>");
    out.push_str(&html_escape(&date_utc(blame.timestamp)));
    out.push_str("</span><span>");
    out.push_str(&html_escape(&blame.author));
    out.push_str("</span></span>");
    out
}

fn detect_comment_folds(path: &str, lines: &[String]) -> Vec<CommentFold> {
    let language = syntax_language(path);
    let mut folds = Vec::new();
    let mut index = 0;
    let mut id = 0;
    while index < lines.len() {
        if let Some(end) = block_comment_end(lines, index, language) {
            if end > index + 2 {
                id += 1;
                folds.push(CommentFold {
                    id,
                    start_line: (index + 1) as u32,
                    end_line: (end + 1) as u32,
                });
            }
            index = end + 1;
            continue;
        }

        if is_line_comment_line(&lines[index], language) {
            let start = index;
            index += 1;
            while index < lines.len() && is_line_comment_line(&lines[index], language) {
                index += 1;
            }
            if index.saturating_sub(start) > 3 {
                id += 1;
                folds.push(CommentFold {
                    id,
                    start_line: (start + 1) as u32,
                    end_line: index as u32,
                });
            }
            continue;
        }
        index += 1;
    }
    folds
}

fn block_comment_end(
    lines: &[String],
    start_index: usize,
    language: SyntaxLanguage,
) -> Option<usize> {
    let line = lines.get(start_index)?;
    let trimmed = line.trim_start();
    for (start_marker, end_marker) in block_comment_markers(language) {
        if !trimmed.starts_with(start_marker) {
            continue;
        }
        for (index, candidate) in lines.iter().enumerate().skip(start_index) {
            let search_start = if index == start_index {
                candidate
                    .find(start_marker)
                    .map(|offset| offset + start_marker.len())
                    .unwrap_or(0)
            } else {
                0
            };
            if candidate[search_start..].contains(end_marker) {
                return Some(index);
            }
        }
        return Some(lines.len().saturating_sub(1));
    }
    None
}

fn block_comment_markers(language: SyntaxLanguage) -> &'static [(&'static str, &'static str)] {
    match language {
        SyntaxLanguage::Ruby => &[("=begin", "=end")],
        SyntaxLanguage::Python => &[("\"\"\"", "\"\"\""), ("'''", "'''")],
        SyntaxLanguage::Lua => &[("--[[", "]]")],
        SyntaxLanguage::JavaScript
        | SyntaxLanguage::TypeScript
        | SyntaxLanguage::Go
        | SyntaxLanguage::Rust
        | SyntaxLanguage::Zig
        | SyntaxLanguage::C
        | SyntaxLanguage::Cpp
        | SyntaxLanguage::Java
        | SyntaxLanguage::Kotlin
        | SyntaxLanguage::Swift
        | SyntaxLanguage::CSharp
        | SyntaxLanguage::Php => &[("/*", "*/")],
        SyntaxLanguage::Plain => &[],
    }
}

fn is_line_comment_line(line: &str, language: SyntaxLanguage) -> bool {
    let trimmed = line.trim_start();
    if trimmed.is_empty() {
        return false;
    }
    match language {
        SyntaxLanguage::Ruby | SyntaxLanguage::Python => trimmed.starts_with('#'),
        SyntaxLanguage::Lua => trimmed.starts_with("--") && !trimmed.starts_with("--[["),
        SyntaxLanguage::JavaScript
        | SyntaxLanguage::TypeScript
        | SyntaxLanguage::Go
        | SyntaxLanguage::Rust
        | SyntaxLanguage::Zig
        | SyntaxLanguage::C
        | SyntaxLanguage::Cpp
        | SyntaxLanguage::Java
        | SyntaxLanguage::Kotlin
        | SyntaxLanguage::Swift
        | SyntaxLanguage::CSharp
        | SyntaxLanguage::Php => trimmed.starts_with("//"),
        SyntaxLanguage::Plain => false,
    }
}

fn comment_fold_lines(folds: &[CommentFold]) -> BTreeMap<u32, CommentFoldLine> {
    let mut by_line = BTreeMap::new();
    for fold in folds {
        for line in fold.start_line..=fold.end_line {
            by_line.insert(
                line,
                CommentFoldLine {
                    id: fold.id,
                    start_line: fold.start_line,
                    end_line: fold.end_line,
                    is_start: line == fold.start_line,
                },
            );
        }
    }
    by_line
}

fn collapsed_comment_source(source: &str) -> String {
    format!("{} ...", source.trim_end())
}

fn collapsed_function_source(source: &str, closing_token: &str) -> String {
    let trimmed = source.trim_end();
    if closing_token.is_empty() {
        format!("{} ...", trimmed)
    } else {
        format!("{} ... {}", trimmed, closing_token)
    }
}

fn render_line_details_control(meta_id: &str) -> String {
    let mut out = String::new();
    out.push_str("<label class=\"line-meta line-icon\" for=\"");
    out.push_str(&html_escape(meta_id));
    out.push_str("\" title=\"line verification details\" aria-label=\"line verification details\"><i class=\"fa-solid fa-circle-info\" aria-hidden=\"true\"></i></label>");
    out
}

fn render_line_details_panel(annotation: &UiLineAnnotation) -> String {
    let rows = line_detail_rows(annotation);
    let mut out = String::new();
    out.push_str("<div class=\"line-panel meta-panel\">");
    for row in rows {
        out.push_str("<p>");
        out.push_str(&html_escape(&row));
        out.push_str("</p>");
    }
    out.push_str("</div>");
    out
}

fn render_hazard_control(annotation: &UiLineAnnotation, hazard_id: &str) -> String {
    let mut classes = "bomb line-icon".to_string();
    if annotation.hazards.iter().all(|hazard| hazard.verified) {
        classes.push_str(" verified");
    }
    let title = hazard_panel_title(annotation);
    let mut out = String::new();
    out.push_str("<label class=\"");
    out.push_str(&classes);
    out.push_str("\" for=\"");
    out.push_str(&html_escape(hazard_id));
    out.push_str("\" title=\"");
    out.push_str(&html_escape(&title));
    out.push_str("\" aria-label=\"concurrency hazard details\"><i class=\"fa-solid fa-bomb\" aria-hidden=\"true\"></i></label>");
    out
}

fn render_hazard_panel(annotation: &UiLineAnnotation) -> String {
    let mut hazards = annotation.hazards.iter().collect::<Vec<_>>();
    hazards.sort_by(|left, right| {
        left.verified
            .cmp(&right.verified)
            .then_with(|| left.required_evidence.cmp(&right.required_evidence))
            .then_with(|| left.hazard_type.cmp(&right.hazard_type))
            .then_with(|| left.source.cmp(&right.source))
    });

    let mut out = String::new();
    out.push_str("<div class=\"line-panel hazard-panel\">");
    for hazard in hazards {
        out.push_str("<p><strong>");
        out.push_str(&html_escape(&hazard.hazard_type));
        out.push_str("</strong> requires <strong>");
        out.push_str(&html_escape(&hazard.required_evidence));
        out.push_str("</strong>: ");
        out.push_str(hazard_status_text(hazard));
        out.push_str("</p>");
        if !hazard.source.is_empty() {
            out.push_str("<p class=\"hazard-source\">");
            out.push_str(&html_escape(&hazard.source));
            out.push_str("</p>");
        }
    }
    out.push_str("</div>");
    out
}

fn hazard_panel_title(annotation: &UiLineAnnotation) -> String {
    annotation
        .hazards
        .iter()
        .map(|hazard| {
            let mut title = format!(
                "{} requires {} ({})",
                hazard.hazard_type,
                hazard.required_evidence,
                hazard_status_text(hazard)
            );
            if !hazard.source.is_empty() {
                title.push('\n');
                title.push_str(&hazard.source);
            }
            title
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn hazard_status_text(hazard: &UiHazard) -> &'static str {
    if hazard.verified {
        "evidence plus invariant mutation present"
    } else if hazard.evidence_present {
        "systems evidence present; invariant mutation missing"
    } else {
        "systems evidence and invariant mutation missing"
    }
}

fn line_detail_rows(annotation: &UiLineAnnotation) -> Vec<String> {
    let mut rows = Vec::new();
    if let Some(summary) = test_type_summary(annotation) {
        rows.push(summary);
    }
    if annotation.covered && annotation.line_hits.is_none() && annotation.line_coverage.is_none() {
        rows.push(
            "covered as part of a multi-line statement; exact line-hit metadata is unavailable"
                .to_string(),
        );
    }
    if annotation.test_type_counts.is_empty() && !annotation.test_types.is_empty() {
        let mut detail = format!("tests by type: {}", annotation.test_types.join(", "));
        if annotation.distinct_tests > 0 {
            detail.push_str(&format!(" - {} total", annotation.distinct_tests));
        }
        rows.push(detail);
    }
    if annotation.test_type_counts.is_empty() && annotation.distinct_tests > 0 {
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
        rows.push(format!("partial coverage: {}", dark_arm_labels.join(", ")));
    }
    let effect_labels = effect_span_labels(annotation);
    if !effect_labels.is_empty() {
        rows.push(format!("effects: {}", effect_labels.join(", ")));
    }
    for finding in &annotation.findings {
        if is_decomplex_finding(finding) {
            rows.push(format!(
                "SARIF {} {}: {}",
                finding.tool,
                finding.rule_id,
                decomplex_display_message(finding)
            ));
        } else {
            rows.push(format!(
                "SARIF {} {}: {}{}",
                finding.tool,
                finding.rule_id,
                finding.message,
                if finding.source.is_empty() {
                    String::new()
                } else {
                    format!(" ({})", finding.source)
                }
            ));
        }
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
            "decayed fix/crash weight {:.3}",
            annotation.bug_weight.min(1.0)
        ));
    }
    rows
}

fn render_bug_history_control(annotation: &UiLineAnnotation, bug_id: &str) -> String {
    let opacity = 0.18 + (annotation.bug_weight * 2.0).min(1.0) * 0.82;
    let mut out = String::new();
    out.push_str("<label class=\"bug-history line-icon\" for=\"");
    out.push_str(&html_escape(bug_id));
    out.push_str("\" aria-label=\"decayed fix history\" style=\"opacity:");
    out.push_str(&format!("{opacity:.3}"));
    out.push_str("\"><i class=\"fa-solid fa-bug\" aria-hidden=\"true\"></i></label>");
    out
}

fn render_bug_history_panel(annotation: &UiLineAnnotation) -> String {
    let events = sorted_bug_events(annotation);
    let mut out = String::new();
    out.push_str("<div class=\"line-panel bug-panel\">");
    for event in events {
        out.push_str("<p>");
        out.push_str(&html_escape(&bug_event_summary(event)));
        out.push_str("</p>");
    }
    out.push_str("</div>");
    out
}

fn test_type_summary(annotation: &UiLineAnnotation) -> Option<String> {
    if annotation.test_type_counts.is_empty() {
        return None;
    }

    let mut entries = annotation
        .test_type_counts
        .iter()
        .map(|(test_type, count)| (test_type.as_str(), *count))
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        test_type_rank(left.0)
            .cmp(&test_type_rank(right.0))
            .then_with(|| left.0.cmp(right.0))
    });
    let total: i64 = entries.iter().map(|(_, count)| *count).sum();
    let parts = entries
        .into_iter()
        .map(|(test_type, count)| format!("{test_type} ({count})"))
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!("tests by type: {parts} - {total} total"))
}

fn test_type_rank(test_type: &str) -> usize {
    match test_type {
        "fuzz" => 0,
        "integration" => 1,
        "unit" => 2,
        "loom" => 3,
        "vopr" => 4,
        "tsan" => 5,
        _ => 100,
    }
}

fn finding_panel_id(line_no: u32, tool: FirstPartyFindingTool) -> String {
    format!("L{}-{}", line_no, tool.key())
}

fn first_party_finding_tools(annotation: &UiLineAnnotation) -> Vec<FirstPartyFindingTool> {
    FirstPartyFindingTool::all()
        .iter()
        .copied()
        .filter(|tool| !tool_findings(annotation, *tool).is_empty())
        .collect()
}

fn render_finding_control(
    annotation: &UiLineAnnotation,
    tool: FirstPartyFindingTool,
    panel_id: &str,
) -> String {
    let findings = tool_findings(annotation, tool);
    if findings.is_empty() {
        return String::new();
    }

    let mut title = format!("{} {} SARIF signal(s)", findings.len(), tool.title());
    let rules = findings
        .iter()
        .map(|finding| finding.rule_id.as_str())
        .collect::<BTreeSet<_>>();
    for rule in rules {
        title.push('\n');
        title.push_str(rule);
    }
    let stale = findings.iter().any(|finding| finding.stale);
    if stale {
        title.push_str("\nout of date: source changed since SARIF ingestion");
    }

    let mut out = String::new();
    out.push_str("<label class=\"");
    out.push_str(tool.control_class());
    out.push_str(" line-icon");
    if stale {
        out.push_str(" finding-stale");
    }
    out.push_str("\" for=\"");
    out.push_str(&html_escape(panel_id));
    out.push_str("\" title=\"");
    out.push_str(&html_escape(&title));
    out.push_str("\" aria-label=\"");
    out.push_str(tool.title());
    out.push_str(" SARIF signals\"><i class=\"");
    out.push_str(tool.icon_family());
    out.push(' ');
    out.push_str(tool.icon_class());
    out.push_str("\" aria-hidden=\"true\"></i></label>");
    out
}

fn render_finding_panel(annotation: &UiLineAnnotation, tool: FirstPartyFindingTool) -> String {
    let findings = tool_findings(annotation, tool);
    let mut out = String::new();
    out.push_str("<div class=\"line-panel finding-panel ");
    out.push_str(tool.panel_class());
    out.push_str("\">");
    for finding in findings {
        out.push_str("<p>");
        if finding.stale {
            out.push_str("<span class=\"finding-stale-badge\">out of date</span> ");
        }
        if let Some(tier) = finding.tier {
            out.push_str("<span class=\"finding-tier\">tier ");
            out.push_str(&tier.to_string());
            out.push_str("</span> ");
        }
        if tool == FirstPartyFindingTool::Decomplex {
            out.push_str("<a href=\"");
            out.push_str(&html_escape(&decomplex_doc_url(finding)));
            out.push_str("\" target=\"_blank\" rel=\"noopener\">");
            out.push_str(&html_escape(&finding.rule_id));
            out.push_str("</a>");
        } else {
            out.push_str("<strong>");
            out.push_str(&html_escape(&finding.rule_id));
            out.push_str("</strong>");
        }
        out.push_str(": ");
        out.push_str(&html_escape(&finding_display_message(finding, tool)));
        out.push_str("</p>");
    }
    out.push_str("</div>");
    out
}

fn finding_display_message(finding: &UiFinding, tool: FirstPartyFindingTool) -> String {
    match tool {
        FirstPartyFindingTool::Decomplex => decomplex_display_message(finding),
        _ => finding.message.trim().to_string(),
    }
}

fn decomplex_display_message(finding: &UiFinding) -> String {
    let mut message = finding.message.trim().to_string();
    if let Some(title) = decomplex_rule_title(&finding.rule_id) {
        let prefix = format!("{title}:");
        if message
            .get(..prefix.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(&prefix))
        {
            message = message[prefix.len()..].trim_start().to_string();
        }
    }
    message
}

fn decomplex_rule_title(rule_id: &str) -> Option<String> {
    let slug = rule_id.rsplit('.').next()?.trim();
    if slug.is_empty() {
        return None;
    }
    let words = slug
        .split('-')
        .filter(|word| !word.is_empty())
        .map(title_case_ascii)
        .collect::<Vec<_>>();
    (!words.is_empty()).then(|| words.join(" "))
}

fn title_case_ascii(word: &str) -> String {
    let mut chars = word.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };
    let mut out = String::new();
    out.push(first.to_ascii_uppercase());
    out.extend(chars.map(|character| character.to_ascii_lowercase()));
    out
}

fn tool_findings(annotation: &UiLineAnnotation, tool: FirstPartyFindingTool) -> Vec<&UiFinding> {
    let mut findings = annotation
        .findings
        .iter()
        .filter(|finding| is_tool_finding(finding, tool))
        .collect::<Vec<_>>();
    findings.sort_by(|left, right| {
        left.tier
            .unwrap_or(i64::MAX)
            .cmp(&right.tier.unwrap_or(i64::MAX))
            .then_with(|| left.rule_id.cmp(&right.rule_id))
            .then_with(|| left.message.cmp(&right.message))
    });
    findings
}

fn is_decomplex_finding(finding: &UiFinding) -> bool {
    is_tool_finding(finding, FirstPartyFindingTool::Decomplex)
}

fn is_tool_finding(finding: &UiFinding, tool: FirstPartyFindingTool) -> bool {
    if tool == FirstPartyFindingTool::Lint {
        return is_lint_finding(finding);
    }
    let needle = tool.key();
    [finding.source.as_str(), finding.tool.as_str(), finding.rule_id.as_str()]
        .iter()
        .any(|value| value.to_ascii_lowercase().contains(needle))
}

fn is_lint_finding(finding: &UiFinding) -> bool {
    let source = finding.source.to_ascii_lowercase();
    let tool = finding.tool.to_ascii_lowercase();
    let rule = finding.rule_id.to_ascii_lowercase();
    finding.category.eq_ignore_ascii_case("lint")
        || source.contains("lint")
        || matches!(tool.as_str(), "rubocop" | "clippy" | "zig ast check")
        || rule.starts_with("lint/")
        || rule.starts_with("security/")
        || rule.starts_with("clippy::")
        || rule.starts_with("zig.ast-check")
}

fn decomplex_doc_url(finding: &UiFinding) -> String {
    let rule = finding.rule_id.to_ascii_lowercase();
    if rule.contains("false-simplicity") {
        format!("{DECOMPLEX_DOC_BASE}/docs/false-simplicity.md")
    } else if rule.contains("complexity") {
        format!("{DECOMPLEX_DOC_BASE}/docs/agents/metrics-expo.md")
    } else {
        format!("{DECOMPLEX_DOC_BASE}/docs/agents/design.md")
    }
}

fn bug_event_summary(event: &UiBugEvent) -> String {
    let hash = short_commit(&event.commit_hash);
    let date = date_utc(event.timestamp);
    let weight = format!("{:.2}", event.weight);
    let prefix = format!("{hash} {date} weight {weight}: ");
    let message_budget = BUG_HISTORY_ROW_BUDGET.saturating_sub(prefix.chars().count());
    format!(
        "{prefix}{}",
        truncate_chars(&one_line_text(&event.label), message_budget)
    )
}

fn one_line_text(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn truncate_chars(input: &str, max_chars: usize) -> String {
    if input.chars().count() <= max_chars {
        return input.to_string();
    }
    if max_chars <= 3 {
        return "...".chars().take(max_chars).collect();
    }
    let mut out = input.chars().take(max_chars - 3).collect::<String>();
    out.push_str("...");
    out
}

fn sorted_bug_events(annotation: &UiLineAnnotation) -> Vec<&UiBugEvent> {
    let mut events = annotation.bug_events.iter().collect::<Vec<_>>();
    events.sort_by(|left, right| {
        right
            .timestamp
            .cmp(&left.timestamp)
            .then_with(|| right.commit_hash.cmp(&left.commit_hash))
            .then_with(|| right.line.cmp(&left.line))
    });
    events
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
    if annotation.covered && annotation.is_partial {
        if gutter {
            "rgba(31, 41, 55, 0.32)".to_string()
        } else {
            "rgba(31, 41, 55, 0.16)".to_string()
        }
    } else if annotation.covered && (annotation.mutant_tested || annotation.mutant_killed_tests > 0) {
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
        rows.push(if annotation.is_partial {
            "coverage quality: partial".to_string()
        } else if annotation.mutant_tested {
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
        || !annotation.effect_spans.is_empty()
        || !annotation.findings.is_empty()
        || annotation.line_hits.is_some()
        || annotation.line_coverage.is_some()
        || annotation.mutant_coverage.is_some()
        || annotation.semantic_churn_events > 0
        || !annotation.bug_events.is_empty()
}

fn dark_arm_labels(annotation: &UiLineAnnotation) -> Vec<String> {
    let mut labels = annotation.dark_arms.clone();
    labels.extend(annotation.dark_arm_spans.iter().map(|arm| arm.label.clone()));
    labels.sort();
    labels.dedup();
    labels
}

fn effect_span_labels(annotation: &UiLineAnnotation) -> Vec<String> {
    let mut labels = annotation
        .effect_spans
        .iter()
        .map(|span| span.label.clone())
        .collect::<Vec<_>>();
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
    Cpp,
    Java,
    Kotlin,
    Swift,
    CSharp,
    Php,
    Plain,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct InlineOverlayRange {
    start: usize,
    end: usize,
    classes: BTreeSet<String>,
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
    let ranges = inline_overlay_ranges(line_no, source, annotation);
    if ranges.is_empty() {
        return highlight_source_line(path, source);
    }

    let mut out = String::new();
    let mut cursor = 0;
    for range in ranges {
        if range.start > cursor {
            out.push_str(&highlight_source_line(path, &source[cursor..range.start]));
        }
        out.push_str("<span class=\"");
        out.push_str(&html_escape(&range.classes.into_iter().collect::<Vec<_>>().join(" ")));
        out.push_str("\" title=\"");
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

fn inline_overlay_ranges(
    line_no: u32,
    source: &str,
    annotation: &UiLineAnnotation,
) -> Vec<InlineOverlayRange> {
    let mut ranges = if annotation.covered {
        annotation
            .dark_arm_spans
            .iter()
            .filter_map(|arm| {
                let span = arm.span?;
                dark_arm_line_range(line_no, source, span).map(|(start, end)| InlineOverlayRange {
                    start,
                    end,
                    classes: BTreeSet::from(["dark-arm-span".to_string()]),
                    labels: vec![arm.label.clone()],
                })
            })
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    ranges.extend(annotation.effect_spans.iter().filter_map(|span| {
        let start = clamp_to_char_boundary(source, span.start.min(source.len()));
        let end = clamp_to_char_boundary(source, span.end.min(source.len()));
        (end > start).then(|| InlineOverlayRange {
            start,
            end,
            classes: BTreeSet::from([
                "effect-span".to_string(),
                format!("effect-{}", span.kind),
            ]),
            labels: vec![span.label.clone()],
        })
    }));
    if ranges.is_empty() {
        return ranges;
    }

    ranges.sort_by_key(|range| (range.start, range.end));
    let mut merged = Vec::<InlineOverlayRange>::new();
    for range in ranges {
        if let Some(last) = merged.last_mut() {
            if range.start <= last.end {
                last.end = last.end.max(range.end);
                last.classes.extend(range.classes);
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
        Some("c" | "h") => SyntaxLanguage::C,
        Some("cc" | "cpp" | "cxx" | "hpp" | "hh" | "hxx") => SyntaxLanguage::Cpp,
        Some("java") => SyntaxLanguage::Java,
        Some("kt" | "kts") => SyntaxLanguage::Kotlin,
        Some("swift") => SyntaxLanguage::Swift,
        Some("cs") => SyntaxLanguage::CSharp,
        Some("php") => SyntaxLanguage::Php,
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
        | SyntaxLanguage::C
        | SyntaxLanguage::Cpp
        | SyntaxLanguage::Java
        | SyntaxLanguage::Kotlin
        | SyntaxLanguage::Swift
        | SyntaxLanguage::CSharp
        | SyntaxLanguage::Php => Some("//"),
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
    for (index, ch) in chars.by_ref() {
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
        SyntaxLanguage::Cpp => &[
            "auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "delete",
            "do", "double", "else", "enum", "explicit", "export", "extern", "false", "float", "for",
            "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace", "new", "operator",
            "private", "protected", "public", "register", "reinterpret_cast", "return", "short",
            "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true",
            "try", "typedef", "typeid", "typename", "union", "unsigned", "using", "virtual", "void",
            "volatile", "wchar_t", "while",
        ],
        SyntaxLanguage::Java => &[
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
            "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
            "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
            "new", "null", "package", "private", "protected", "public", "return", "short", "static",
            "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true",
            "try", "void", "volatile", "while",
        ],
        SyntaxLanguage::Kotlin => &[
            "as", "as?", "break", "class", "val", "var", "fun", "for", "if", "else", "while", "do",
            "return", "this", "super", "try", "catch", "finally", "throw", "package", "import", "object",
            "interface", "typealias", "typeof", "when", "is", "!is", "in", "!in", "true", "false", "null",
        ],
        SyntaxLanguage::Swift => &[
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
            "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
            "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue",
            "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
            "return", "switch", "where", "while", "as", "any", "false", "is", "nil", "self", "super",
            "true", "try",
        ],
        SyntaxLanguage::CSharp => &[
            "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
            "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
            "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
            "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
            "long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
            "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
            "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
            "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual",
            "void", "volatile", "while",
        ],
        SyntaxLanguage::Php => &[
            "__halt_compiler", "abstract", "and", "array", "as", "break", "callable", "case", "catch",
            "class", "clone", "const", "continue", "declare", "default", "die", "do", "echo", "else",
            "elsif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
            "eval", "exit", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
            "goto", "if", "implements", "include", "include_once", "instanceof", "insteadof",
            "interface", "isset", "list", "match", "namespace", "new", "or", "print", "private",
            "protected", "public", "readonly", "require", "require_once", "return", "static", "switch",
            "throw", "trait", "try", "unset", "use", "var", "while", "xor", "yield",
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

fn directory_sort_href(directory: &str, filter: &str, sort: CoverageSort) -> String {
    let directory = normalize_directory(directory);
    let mut pairs = Vec::new();
    if !directory.is_empty() {
        pairs.push(("dir", directory));
    }
    if !filter.trim().is_empty() {
        pairs.push(("q", filter.trim().to_string()));
    }
    if sort != CoverageSort::Path {
        pairs.push(("sort", sort.as_str().to_string()));
    }
    if pairs.is_empty() {
        return "/".to_string();
    }

    let query = pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={}", percent_encode(&value)))
        .collect::<Vec<_>>()
        .join("&");
    format!("/?{query}")
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

fn date_utc(timestamp: i64) -> String {
    let days = timestamp.div_euclid(86_400);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    let year = y + if month <= 2 { 1 } else { 0 };
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
const STYLE: &str = include_str!("assets/app.css");

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        CommitMetadata, CrashEvent, Event, EventType, HazardEvent, LogicalUnit, QualityEvent,
        QualityMetric, SarifArtifact, SarifFinding, TestExposureEvent, UnitKind,
    };
    use tempfile::tempdir;

    #[test]
    fn sarif_staleness_tracks_file_content_instead_of_head_age() {
        let dir = tempdir().unwrap();
        let repo = Repository::init(dir.path()).unwrap();
        fs::create_dir_all(dir.path().join("sql")).unwrap();
        fs::write(dir.path().join("sql/query.sql"), "SELECT 1;\n").unwrap();
        let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(Path::new("sql/query.sql")).unwrap();
        index.write().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        let analyzed_commit = repo
            .commit(Some("HEAD"), &signature, &signature, "analyze", &tree, &[])
            .unwrap();
        drop(tree);

        fs::write(dir.path().join("README.md"), "unrelated\n").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(Path::new("README.md")).unwrap();
        index.write().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        let parent = repo.find_commit(analyzed_commit).unwrap();
        repo.commit(Some("HEAD"), &signature, &signature, "unrelated", &tree, &[&parent])
            .unwrap();
        drop(tree);

        let mut annotation = empty_annotation(1);
        annotation.findings.push(UiFinding {
            source: "sql-cov".to_string(),
            tool: "SQL-COV".to_string(),
            rule_id: "SQL007".to_string(),
            level: "warning".to_string(),
            message: "nullable equality".to_string(),
            category: "nullable".to_string(),
            tier: None,
            span: None,
            commit: analyzed_commit.to_string(),
            stale: false,
        });
        let mut annotations = vec![annotation];
        annotate_sarif_freshness(dir.path(), "sql/query.sql", "SELECT 1;\n", &mut annotations);
        assert!(!annotations[0].findings[0].stale);

        annotate_sarif_freshness(dir.path(), "sql/query.sql", "SELECT 2;\n", &mut annotations);
        assert!(annotations[0].findings[0].stale);
    }

    #[test]
    fn standalone_architecture_ui_sql_prepares_against_the_real_schema() {
        let storage = Storage::open_memory().unwrap();
        storage.connection().prepare(ARCHITECTURE_SYMBOLS_FOR_PATH_SQL).unwrap();
        storage.connection().prepare(ARCHITECTURE_OWNER_BY_NAME_SQL).unwrap();
    }

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
        assert_eq!(payload.symbols.len(), 1);
        assert_eq!(payload.symbols[0].name, "run");
        assert!(line.covered);
        assert!(line.mutant_tested);
        assert_eq!(line.test_types, vec!["loom"]);
        assert_eq!(line.test_type_counts.get("loom"), Some(&1));
        assert_eq!(line.hazards.len(), 1);
        assert!(line.hazards[0].verified);
    }

    #[test]
    fn source_payload_uses_current_source_for_outline_lines_when_db_is_stale() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src/annotator/helpers")).unwrap();
        fs::write(
            dir.path().join("src/annotator/helpers/fixable_helpers.rb"),
            "# typed: strict\n\
             # comment\n\
             # comment\n\
             # comment\n\
             # comment\n\
             # comment\n\
             # comment\n\
             def closest_name(input)\n\
               input\n\
             end\n\
             \n\
             sig { params(a: String, b: String).returns(Integer) }\n\
             def levenshtein(a, b)\n\
               0\n\
             end\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();
        let path = "src/annotator/helpers/fixable_helpers.rb";
        let closest = LogicalUnit::new(
            "closest_name",
            UnitKind::Function,
            path,
            1,
            1,
            2,
            "def closest_name",
            "def closest_name(input)\nend",
        );
        let levenshtein = LogicalUnit::new(
            "levenshtein",
            UnitKind::Function,
            path,
            1,
            3,
            4,
            "def levenshtein",
            "def levenshtein(a, b)\nend",
        );
        storage.upsert_logical_unit(&closest, 10).unwrap();
        storage.upsert_logical_unit(&levenshtein, 10).unwrap();
        for (unit, stale_start, stale_end) in [(&closest, 1, 2), (&levenshtein, 3, 4)] {
            storage
                .insert_event(&Event {
                    unit_id: unit.id.clone(),
                    commit_hash: "abc".into(),
                    event_type: EventType::Change,
                    path: path.into(),
                    name: unit.name.clone(),
                    start_line: stale_start,
                    end_line: stale_end,
                    semantic_change: true,
                    lines_added: 1,
                    lines_removed: 0,
                    timestamp: 10,
                })
                .unwrap();
        }

        let payload = source_payload(&storage, dir.path(), path, None).unwrap();
        let closest = payload
            .symbols
            .iter()
            .find(|symbol| symbol.name == "closest_name")
            .unwrap();
        let levenshtein = payload
            .symbols
            .iter()
            .find(|symbol| symbol.name == "levenshtein")
            .unwrap();

        assert_eq!(closest.start_line, 8);
        assert_eq!(levenshtein.start_line, 13);
        let outline = render_source_outline(&payload);
        assert!(outline.contains("href=\"#L8\""));
        assert!(outline.contains("href=\"#L13\""));

        let hotspots =
            unit_hotspots(
                &storage,
                "src",
                &CoverageScope::all(),
                Some(dir.path()),
                12,
                false,
            )
            .unwrap();
        let closest_hotspot = hotspots
            .iter()
            .find(|unit| unit.name == "closest_name")
            .unwrap();
        let levenshtein_hotspot = hotspots
            .iter()
            .find(|unit| unit.name == "levenshtein")
            .unwrap();
        assert_eq!(closest_hotspot.start_line, 8);
        assert_eq!(levenshtein_hotspot.start_line, 13);
        let links = render_unit_hotspots(&hotspots, "");
        assert!(links.contains("src%2Fannotator%2Fhelpers%2Ffixable_helpers.rb#L8"));
        assert!(links.contains("src%2Fannotator%2Fhelpers%2Ffixable_helpers.rb#L13"));
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
    fn source_outline_groups_qualified_methods_under_containers() {
        let payload = UiSourcePayload {
            path: "gems/slopcop/lib/slopcop/dark_arm_overlay.rb".into(),
            commit: None,
            lines: Vec::new(),
            versions: Vec::new(),
            symbols: vec![
                empty_source_symbol("module", "SlopCop", 1, 20),
                empty_source_symbol("class", "DarkArmOverlay", 3, 19),
                empty_source_symbol("function", "SlopCop.DarkArmOverlay.build", 4, 5),
                empty_source_symbol("function", "SlopCop.DarkArmOverlay.to_json", 7, 8),
                empty_source_symbol("function", "SlopCop.DarkArmOverlay.to_sarif", 11, 12),
            ],
            blame: Vec::new(),
            annotations: Vec::new(),
            warnings: Vec::new(),
        };

        let outline = render_source_outline(&payload);

        assert!(outline.contains("outline-depth-0"));
        assert!(outline.contains("outline-depth-1"));
        assert!(outline.contains("outline-depth-2"));
        assert!(outline.contains("<span class=\"outline-name\">SlopCop</span>"));
        assert!(outline.contains("<span class=\"outline-name\">DarkArmOverlay</span>"));
        assert!(outline.contains("<span class=\"outline-name\">build</span>"));
        assert!(outline.contains("<span class=\"outline-name\">to_json</span>"));
        assert!(outline.contains("<span class=\"outline-name\">to_sarif</span>"));
        assert!(!outline.contains("SlopCop.DarkArmOverlay.build"));
        assert!(
            outline.find(">build</span>").unwrap() < outline.find(">to_json</span>").unwrap()
        );
        assert!(
            outline.find(">to_json</span>").unwrap() < outline.find(">to_sarif</span>").unwrap()
        );
    }

    #[test]
    fn source_payload_includes_persisted_sarif_findings() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/demo.rb"), "def run\n  else\nend\n").unwrap();
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
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
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
        let artifact_id = storage
            .insert_sarif_artifact(&SarifArtifact {
                source: "slopcop".into(),
                tool_name: "SlopCop".into(),
                run_format: "slopcop.report.sarif.v1".into(),
                artifact_path: "tmp/slopcop.sarif#run0".into(),
                artifact_sha256: "abc123".into(),
                commit_hash: "abc".into(),
                timestamp: 20,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_sarif_finding(&SarifFinding {
                artifact_id,
                finding_key: "finding-1".into(),
                source: "slopcop".into(),
                tool_name: "SlopCop".into(),
                run_format: "slopcop.report.sarif.v1".into(),
                commit_hash: "abc".into(),
                timestamp: 20,
                rule_id: "slopcop.dark-arm.genuine".into(),
                level: "warning".into(),
                message: "dark arm: genuine".into(),
                path: "src/demo.rb".into(),
                start_line: 2,
                start_column: Some(3),
                end_line: Some(2),
                end_column: Some(7),
                category: "genuine".into(),
                is_dark_arm: true,
                unit_id: Some(unit.id),
                fingerprint: "fp".into(),
                properties_json: "{}".into(),
                raw_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_sarif_finding(&SarifFinding {
                artifact_id,
                finding_key: "finding-2".into(),
                source: "slopcop".into(),
                tool_name: "SlopCop".into(),
                run_format: "slopcop.report.sarif.v1".into(),
                commit_hash: "abc".into(),
                timestamp: 20,
                rule_id: "slopcop.dark-arm.dead".into(),
                level: "note".into(),
                message: "dark arm: dead".into(),
                path: "other/other.rb".into(),
                start_line: 1,
                start_column: None,
                end_line: None,
                end_column: None,
                category: "dead".into(),
                is_dark_arm: true,
                unit_id: None,
                fingerprint: "fp2".into(),
                properties_json: "{}".into(),
                raw_json: "{}".into(),
            })
            .unwrap();

        storage.refresh_current_sarif_findings_view().unwrap();

        let payload =
            source_payload_with_overlays(&storage, dir.path(), "src/demo.rb", None, &UiOverlays::default())
                .unwrap();
        let line = payload.annotations.iter().find(|line| line.line == 2).unwrap();
        let dashboard = dashboard_summary(&storage).unwrap();
        let files = file_index(&storage, None).unwrap();
        let scoped_review = review_next_items(&storage, "src", &CoverageScope::all()).unwrap();
        let scoped_health = analyzer_health(&storage, "src", &CoverageScope::all()).unwrap();
        let slopcop_health = scoped_health
            .iter()
            .find(|health| health.analyzer == "SlopCop")
            .unwrap();

        assert_eq!(line.findings.len(), 1);
        assert_eq!(line.findings[0].tool, "SlopCop");
        assert_eq!(line.dark_arm_spans[0].span, Some([2, 2, 2, 6]));
        assert_eq!(dashboard.sarif_findings, 2);
        assert_eq!(scoped_review.len(), 1);
        assert_eq!(scoped_review[0].path, "src/demo.rb");
        assert!(scoped_review[0].detail.contains("SlopCop"));
        assert_eq!(slopcop_health.scoped_findings, 1);
        assert_eq!(slopcop_health.total_findings, 2);
        assert!(files.iter().any(|file| file.path == "other/other.rb" && file.sarif_findings == 1));
    }

    #[test]
    fn source_payload_uses_espalier_sarif_for_symbol_purity_and_effect_spans() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(
            dir.path().join("src/demo.rb"),
            "def pure\n  1\nend\ndef read_state\n  @state\nend\ndef prepare\n  @state = compute(@state)\nend\ndef run\n  prepare\n  read_state\nend\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();
        let pure = LogicalUnit::new(
            "pure",
            UnitKind::Function,
            "src/demo.rb",
            1,
            1,
            3,
            "def pure",
            "def pure\n1\nend",
        );
        let prepare = LogicalUnit::new(
            "prepare",
            UnitKind::Function,
            "src/demo.rb",
            7,
            7,
            9,
            "def prepare",
            "def prepare\n@state = compute(@state)\nend",
        );
        let read_state = LogicalUnit::new(
            "read_state",
            UnitKind::Function,
            "src/demo.rb",
            4,
            4,
            6,
            "def read_state",
            "def read_state\n@state\nend",
        );
        let run = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/demo.rb",
            10,
            10,
            13,
            "def run",
            "def run\nprepare\nread_state\nend",
        );
        storage.upsert_logical_unit(&pure, 10).unwrap();
        storage.upsert_logical_unit(&read_state, 10).unwrap();
        storage.upsert_logical_unit(&prepare, 10).unwrap();
        storage.upsert_logical_unit(&run, 10).unwrap();
        let artifact_id = storage
            .insert_sarif_artifact(&SarifArtifact {
                source: "espalier".into(),
                tool_name: "Espalier".into(),
                run_format: "espalier.manifest.sarif.v1".into(),
                artifact_path: "tmp/espalier.sarif#run0".into(),
                artifact_sha256: "esp123".into(),
                commit_hash: "abc".into(),
                timestamp: 20,
                payload_json: "{}".into(),
            })
            .unwrap();
        for (key, unit, function) in [
            (
                "pure",
                &pure,
                serde_json::json!({
                    "name": "pure",
                    "span": [1, 0, 3, 3],
                    "EFFECTS": { "reads": [], "writes": [] },
                    "CALL_GRAPH": { "internal_calls": [] }
                }),
            ),
            (
                "read_state",
                &read_state,
                serde_json::json!({
                    "name": "read_state",
                    "span": [4, 0, 6, 3],
                    "EFFECTS": { "reads": ["@state"], "writes": [] },
                    "CALL_GRAPH": { "internal_calls": [] }
                }),
            ),
            (
                "prepare",
                &prepare,
                serde_json::json!({
                    "name": "prepare",
                    "span": [7, 0, 9, 3],
                    "EFFECTS": { "reads": ["@state"], "writes": ["@state"] },
                    "CALL_GRAPH": { "internal_calls": [] }
                }),
            ),
            (
                "run",
                &run,
                serde_json::json!({
                    "name": "run",
                    "span": [10, 0, 13, 3],
                    "EFFECTS": { "reads": [], "writes": [] },
                    "CALL_GRAPH": { "internal_calls": ["prepare", "read_state"] }
                }),
            ),
        ] {
            storage
                .insert_sarif_finding(&SarifFinding {
                    artifact_id,
                    finding_key: format!("espalier-{key}"),
                    source: "espalier".into(),
                    tool_name: "Espalier".into(),
                    run_format: "espalier.manifest.sarif.v1".into(),
                    commit_hash: "abc".into(),
                    timestamp: 20,
                    rule_id: "espalier.function".into(),
                    level: "note".into(),
                    message: format!("function: Demo#{key}"),
                    path: "src/demo.rb".into(),
                    start_line: function
                        .get("span")
                        .and_then(Value::as_array)
                        .and_then(|span| span.first())
                        .and_then(Value::as_u64)
                        .unwrap() as u32,
                    start_column: None,
                    end_line: function
                        .get("span")
                        .and_then(Value::as_array)
                        .and_then(|span| span.get(2))
                        .and_then(Value::as_u64)
                        .map(|line| line as u32),
                    end_column: None,
                    category: "architecture".into(),
                    is_dark_arm: false,
                    unit_id: Some(unit.id.clone()),
                    fingerprint: format!("espalier-{key}-fp"),
                    properties_json: serde_json::json!({
                        "module": "Demo",
                        "function": function,
                        "source_format": "espalier.manifest.v1"
                    })
                    .to_string(),
                    raw_json: "{}".into(),
                })
                .unwrap();
        }

        storage.refresh_current_sarif_findings_view().unwrap();

        let payload = source_payload(&storage, dir.path(), "src/demo.rb", None).unwrap();
        let pure_symbol = payload.symbols.iter().find(|symbol| symbol.name == "pure").unwrap();
        let prepare_symbol = payload
            .symbols
            .iter()
            .find(|symbol| symbol.name == "prepare")
            .unwrap();
        let read_symbol = payload
            .symbols
            .iter()
            .find(|symbol| symbol.name == "read_state")
            .unwrap();
        let run_symbol = payload.symbols.iter().find(|symbol| symbol.name == "run").unwrap();
        let read_line = payload.annotations.iter().find(|line| line.line == 5).unwrap();
        let state_line = payload.annotations.iter().find(|line| line.line == 8).unwrap();
        let call_line = payload.annotations.iter().find(|line| line.line == 11).unwrap();
        let read_call_line = payload.annotations.iter().find(|line| line.line == 12);
        let read_labels = effect_span_labels(read_line);
        let state_labels = effect_span_labels(state_line);
        let call_labels = effect_span_labels(call_line);
        let branch_context = UiBranchContext {
            branch: "master".to_string(),
            commit: "abc".to_string(),
        };
        let html = render_source_view(&payload, "", &branch_context);
        let outline = render_source_outline(&payload);

        assert!(pure_symbol.effect_known);
        assert!(!pure_symbol.impure);
        assert_eq!(pure_symbol.start_line, 1);
        assert!(read_symbol.effect_known);
        assert!(!read_symbol.impure);
        assert_eq!(read_symbol.start_line, 4);
        assert!(prepare_symbol.impure);
        assert_eq!(prepare_symbol.start_line, 7);
        assert!(run_symbol.impure);
        assert_eq!(run_symbol.start_line, 10);
        assert_eq!(read_labels, vec!["state read @state"]);
        assert!(state_labels.contains(&"state read @state".to_string()));
        assert!(state_labels.contains(&"state write @state".to_string()));
        assert_eq!(call_labels, vec!["impure call prepare"]);
        assert!(read_call_line
            .map(|line| effect_span_labels(line).is_empty())
            .unwrap_or(true));
        assert!(outline.contains("fa-link"));
        assert!(html.contains("effect-state-read"));
        assert!(html.contains("effect-state-write"));
        assert!(html.contains("effect-impure-call"));
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
                unit_id: unit.id.clone(),
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
            .record_coverage_line("abc", 10, "src/demo.rb", 2, 2)
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "src/demo.rb".into(),
                function: Some("run".into()),
                line: Some(3),
                branch_id: None,
                test_id: "spec/demo_spec.rb:1".into(),
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
                path: "src/demo.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "spec/demo_spec.rb:2".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("invariant".into()),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        let payload = source_payload(&storage, dir.path(), "src/demo.rb", None).unwrap();
        let line_one = payload.annotations.iter().find(|line| line.line == 1).unwrap();
        let line_two = payload.annotations.iter().find(|line| line.line == 2).unwrap();
        let line_three = payload.annotations.iter().find(|line| line.line == 3).unwrap();
        let coverage = source_coverage_context(&payload);

        assert!(!line_one.covered);
        assert_eq!(line_one.line_hits, Some(0));
        assert!(line_two.covered);
        assert_eq!(line_two.line_hits, Some(2));
        assert!(line_three.test_types.contains(&"unit".to_string()));
        assert_eq!(coverage.tracked_lines, 2);
        assert_eq!(coverage.covered_lines, 1);
        assert_eq!(coverage.missed_lines, 1);
        assert_eq!(coverage.multi_type_lines, 1);
        assert_eq!(coverage.mutant_backed_lines, 1);
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
    fn source_payload_discounts_fix_history_after_large_coverage_gain() {
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
        storage.upsert_logical_unit(&unit, 1).unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "fix".into(),
                event_type: EventType::Fix,
                path: "src/demo.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 0,
                timestamp: 20,
            })
            .unwrap();
        storage
            .record_quality_metric(&QualityEvent {
                unit_id: unit.id.clone(),
                commit_hash: "coverage-low".into(),
                timestamp: 30,
                metric_type: QualityMetric::LineCoverage,
                old_value: None,
                new_value: 20.0,
            })
            .unwrap();
        storage
            .record_quality_metric(&QualityEvent {
                unit_id: unit.id,
                commit_hash: "coverage-high".into(),
                timestamp: 40,
                metric_type: QualityMetric::LineCoverage,
                old_value: None,
                new_value: 90.0,
            })
            .unwrap();

        let payload = source_payload(&storage, dir.path(), "src/demo.rb", None).unwrap();
        let line = payload.annotations.iter().find(|line| line.line == 1).unwrap();

        assert_eq!(line.bug_events.len(), 1);
        assert!(
            (line.bug_events[0].weight - 0.175).abs() < 0.001,
            "unexpected fix weight {}",
            line.bug_events[0].weight
        );
        assert!(
            (line.bug_weight - 0.175).abs() < 0.001,
            "unexpected aggregate bug weight {}",
            line.bug_weight
        );
    }

    #[test]
    fn source_view_renders_css_only_coverage_and_churn_modes() {
        let payload = UiSourcePayload {
            path: "src/demo.rb".into(),
            commit: None,
            lines: vec!["def run".into(), "  maybe_work".into(), "end".into()],
            versions: Vec::new(),
            symbols: vec![empty_source_symbol("function", "run", 1, 3)],
            blame: vec![UiLineBlame {
                line: 2,
                commit_hash: "1234567890abcdef".to_string(),
                ordinal: 2,
                total_commits: 5,
                timestamp: 86_400,
                author: "Ada Lovelace".to_string(),
            }],
            annotations: vec![UiLineAnnotation {
                line: 2,
                covered: true,
                is_partial: false,
                mutant_tested: false,
                test_types: vec!["fuzz".to_string(), "integration".to_string(), "unit".to_string()],
                distinct_tests: 9,
                mutant_verified_tests: 0,
                mutant_killed_tests: 0,
                stochastic_mutant_verified_tests: 0,
                invariant_mutant_verified_tests: 0,
                line_hits: Some(3),
                line_coverage: Some(100.0),
                mutant_coverage: None,
                dark_arms: Vec::new(),
                dark_arm_spans: Vec::new(),
                effect_spans: Vec::new(),
                findings: vec![
                    UiFinding {
                        source: "decomplex".to_string(),
                        tool: "Decomplex".to_string(),
                        rule_id: "decomplex.false-simplicity".to_string(),
                        level: "warning".to_string(),
                        message: "False Simplicity: recursive_cleanup_shape?".to_string(),
                        category: "complexity".to_string(),
                        tier: Some(2),
                        span: None,
                        commit: "abc".to_string(),
                        stale: false,
                    },
                    UiFinding {
                        source: "sql-cov-hazards".to_string(),
                        tool: "sql-cov-hazards".to_string(),
                        rule_id: "SQL007".to_string(),
                        level: "warning".to_string(),
                        message: "nullable join equality has an implicit UNKNOWN policy".to_string(),
                        category: "nullable_join_key".to_string(),
                        tier: None,
                        span: Some([2, 2, 2, 12]),
                        commit: "abc".to_string(),
                        stale: true,
                    },
                    UiFinding {
                        source: "first-party".to_string(),
                        tool: "Decomplex".to_string(),
                        rule_id: "decomplex.decision-pressure".to_string(),
                        level: "warning".to_string(),
                        message: "decision pressure".to_string(),
                        category: "complexity".to_string(),
                        tier: Some(1),
                        span: None,
                        commit: "abc".to_string(),
                        stale: false,
                    },
                    UiFinding {
                        source: "espalier".to_string(),
                        tool: "Espalier".to_string(),
                        rule_id: "espalier.function".to_string(),
                        level: "note".to_string(),
                        message: "function: Demo#run".to_string(),
                        category: "architecture".to_string(),
                        tier: None,
                        span: None,
                        commit: "abc".to_string(),
                        stale: false,
                    },
                    UiFinding {
                        source: "nil-kill".to_string(),
                        tool: "Nil-Kill".to_string(),
                        rule_id: "nil-kill.static.untyped-signature".to_string(),
                        level: "warning".to_string(),
                        message: "static signature includes an untyped or unknown type for Demo#run".to_string(),
                        category: "nil-kill.static.untyped-signature".to_string(),
                        tier: None,
                        span: None,
                        commit: "abc".to_string(),
                        stale: false,
                    },
                    UiFinding {
                        source: "lint".to_string(),
                        tool: "RuboCop".to_string(),
                        rule_id: "Lint/DuplicateBranch".to_string(),
                        level: "warning".to_string(),
                        message: "Duplicate branch body detected.".to_string(),
                        category: "lint".to_string(),
                        tier: None,
                        span: None,
                        commit: "abc".to_string(),
                        stale: false,
                    },
                ],
                hazards: vec![UiHazard {
                    hazard_type: "zig_loom_atomic".to_string(),
                    required_evidence: "loom".to_string(),
                    source: "atomic store".to_string(),
                    evidence_present: false,
                    verified: false,
                }],
                test_type_counts: BTreeMap::from([
                    ("fuzz".to_string(), 2),
                    ("integration".to_string(), 1),
                    ("unit".to_string(), 6),
                ]),
                semantic_churn: 0.70,
                semantic_churn_events: 3,
                bug_weight: 0.75,
                bug_events: vec![
                    UiBugEvent {
                        event_type: "fix".to_string(),
                        commit_hash: "abcdef1234567890".to_string(),
                        timestamp: 100,
                        path: "src/demo.rb".to_string(),
                        line: 2,
                        label: "old noisy commit body".to_string(),
                        weight: 0.50,
                    },
                    UiBugEvent {
                        event_type: "fix".to_string(),
                        commit_hash: "fedcba9876543210".to_string(),
                        timestamp: 86_500,
                        path: "src/demo.rb".to_string(),
                        line: 2,
                        label: "new noisy commit body".to_string(),
                        weight: 0.25,
                    },
                ],
            }],
            warnings: Vec::new(),
        };

        let branch_context = UiBranchContext {
            branch: "master".to_string(),
            commit: "abcdef123456".to_string(),
        };
        let html = render_source_view(&payload, "", &branch_context);

        assert!(html.contains("id=\"mode-coverage\" checked"));
        assert!(html.contains("id=\"mode-churn\""));
        assert!(html.contains("Coverage Quality"));
        assert!(html.contains("Churn Heat"));
        assert!(html.contains("<details class=\"layers-menu\""));
        assert!(html.contains("id=\"layer-gutter-highlights\" checked"));
        assert!(html.contains("id=\"layer-gutter-icons\" checked"));
        assert!(html.contains("id=\"layer-blame\""));
        assert!(html.contains("id=\"layer-comment-folding\" checked"));
        assert!(html.contains("data-persist-key=\"lineage.view.mode\""));
        assert!(html.contains("data-persist-key=\"lineage.layer.comment-folding\""));
        assert!(html.contains("Gutter highlights (Churn)"));
        assert!(html.contains("Gutter highlights (Coverage)"));
        assert!(html.contains("<span>Blame</span>"));
        assert!(html.contains("Expand/collapse comments"));
        assert!(html.contains("Branch Context"));
        assert!(html.contains("Source: latest commit <code>abcdef123456</code>"));
        assert!(!html.contains("All flags"));
        assert!(html.contains("<details class=\"history-drawer\""));
        assert!(html.contains("File history"));
        assert!(html.contains("class=\"blame-cell\""));
        assert!(html.contains("#2 1234567890ab"));
        assert!(html.contains("1970-01-02"));
        assert!(html.contains("Ada Lovelace"));
        assert!(html.contains("hazard-rail"));
        assert!(html.contains("hazard-open"));
        assert!(html.contains("class=\"line-toggle hazard-toggle\""));
        assert!(html.contains("data-panel-class=\"hazard-panel-open\""));
        assert!(html.contains("class=\"bomb line-icon\""));
        assert!(html.contains("<i class=\"fa-solid fa-bomb\" aria-hidden=\"true\"></i>"));
        assert!(html.contains("class=\"line-panel hazard-panel\""));
        assert!(html.contains("<strong>zig_loom_atomic</strong> requires <strong>loom</strong>"));
        assert!(html.contains("systems evidence and invariant mutation missing"));
        assert!(html.contains("atomic store"));
        assert!(html.contains("bug-history"));
        assert!(html.contains("decayed fix history"));
        assert!(html.contains("<i class=\"fa-solid fa-bug\" aria-hidden=\"true\"></i>"));
        assert!(
            html.contains("<i class=\"fa-solid fa-circle-info\" aria-hidden=\"true\"></i>")
        );
        assert!(html.contains("<i class=\"fa-solid fa-puzzle-piece\" aria-hidden=\"true\"></i>"));
        assert!(html.contains("<i class=\"fa-solid fa-tree\" aria-hidden=\"true\"></i>"));
        assert!(html.contains("<i class=\"fa-solid fa-skull\" aria-hidden=\"true\"></i>"));
        assert!(html.contains("<i class=\"fa-regular fa-note-sticky\" aria-hidden=\"true\"></i>"));
        assert!(html.contains("class=\"line-toggle tool-toggle decomplex-toggle\""));
        assert!(html.contains("class=\"line-toggle tool-toggle sql-cov-toggle\""));
        assert!(html.contains("class=\"line-toggle tool-toggle espalier-toggle\""));
        assert!(html.contains("class=\"line-toggle tool-toggle nil-kill-toggle\""));
        assert!(html.contains("class=\"line-toggle tool-toggle lint-toggle\""));
        assert!(html.contains("class=\"decomplex-finding line-icon\""));
        assert!(html.contains("class=\"sql-cov-finding line-icon finding-stale\""));
        assert!(html.contains("class=\"espalier-finding line-icon\""));
        assert!(html.contains("class=\"nil-kill-finding line-icon\""));
        assert!(html.contains("class=\"lint-finding line-icon\""));
        assert!(html.contains("class=\"line-panel finding-panel decomplex-panel\""));
        assert!(html.contains("class=\"line-panel finding-panel sql-cov-panel\""));
        assert!(html.contains("class=\"line-panel finding-panel espalier-panel\""));
        assert!(html.contains("class=\"line-panel finding-panel nil-kill-panel\""));
        assert!(html.contains("class=\"line-panel finding-panel lint-panel\""));
        assert!(html.contains("Decomplex SARIF signals"));
        assert!(html.contains("SQL-COV SARIF signals"));
        assert!(html.contains("out of date: source changed since SARIF ingestion"));
        assert!(html.contains("class=\"finding-stale-badge\">out of date</span>"));
        assert!(html.contains("<strong>SQL007</strong>: nullable join equality has an implicit UNKNOWN policy"));
        assert!(html.contains("Espalier SARIF signals"));
        assert!(html.contains("Nil-Kill SARIF signals"));
        assert!(html.contains("Lint SARIF signals"));
        assert!(html.contains("tier 1"));
        assert!(html.contains("tier 2"));
        assert!(
            html.find("tier 1").unwrap() < html.find("tier 2").unwrap(),
            "Decomplex findings should be ordered by tier"
        );
        assert!(html.contains("decomplex.decision-pressure</a>: decision pressure"));
        assert!(html.contains("decomplex.false-simplicity</a>: recursive_cleanup_shape?"));
        assert!(!html.contains("False Simplicity: recursive_cleanup_shape?"));
        assert!(!html.contains("recursive_cleanup_shape? (decomplex)"));
        assert!(!html.contains("decomplex.decision-pressure</a> warning ["));
        assert!(html.contains("gems/decomplex/docs/false-simplicity.md"));
        assert!(html.contains("tests by type: fuzz (2), integration (1), unit (6) - 9 total"));
        let newer_fix = "fedcba987654 1970-01-02 weight 0.25: new noisy commit body";
        let older_fix = "abcdef123456 1970-01-01 weight 0.50: old noisy commit body";
        assert!(html.contains(newer_fix));
        assert!(html.contains(older_fix));
        assert!(html.find(newer_fix).unwrap() < html.find(older_fix).unwrap());
        assert!(!html.contains("data-tooltip="));
        assert!(html.contains("class=\"line-panel bug-panel\""));
        assert!(html.contains("class=\"line-panel meta-panel\""));
        assert!(html.contains("<pre class=\"source-text\">"));
        assert!(STYLE.contains("#mode-coverage:checked ~ .viewer .source-text"));
        assert!(STYLE.contains("#mode-churn:checked ~ .viewer .source-text"));
        assert!(STYLE.contains("#layer-gutter-highlights:checked ~ #mode-coverage:checked ~ .viewer .gutter"));
        assert!(STYLE.contains("#layer-gutter-icons:not(:checked) ~ .viewer .line-icon"));
        assert!(STYLE.contains("#layer-blame:checked ~ .viewer .blame-cell"));
        assert!(STYLE.contains(".source-view.layer-blame-on .viewer .blame-cell"));
        assert!(STYLE.contains("#layer-comment-folding:checked ~ .viewer .row.comment-fold-hidden"));
        assert!(STYLE.contains("#layer-comment-folding:checked ~ .viewer .comment-fold-toggle:checked ~ .ln .comment-fold-arrow::before"));
        assert!(STYLE.contains(".row.comment-fold-expanded .comment-fold-arrow::before"));
        assert!(STYLE.contains(".comment-fold-control:hover"));
        assert!(STYLE.contains("justify-content: space-between"));
        assert!(STYLE.contains("margin-left: auto"));
        assert!(!STYLE.contains("branch-path-summary"));
        assert!(!STYLE.contains(".bug-history summary::after"));
        assert!(!STYLE.contains(".bug-history summary:hover"));
        assert!(!STYLE.contains(".bug-history summary:focus"));
        assert!(STYLE.contains(".line-panel"));
        assert!(STYLE.contains("max-width: 120ch"));
        assert!(STYLE.contains(".bug-toggle:checked ~ .bug-panel"));
        assert!(STYLE.contains(".meta-toggle:checked ~ .meta-panel"));
        assert!(STYLE.contains(".hazard-toggle:checked ~ .hazard-panel"));
        assert!(STYLE.contains(".decomplex-toggle:checked ~ .decomplex-panel"));
        assert!(STYLE.contains(".sql-cov-toggle:checked ~ .sql-cov-panel"));
        assert!(STYLE.contains(".espalier-toggle:checked ~ .espalier-panel"));
        assert!(STYLE.contains(".nil-kill-toggle:checked ~ .nil-kill-panel"));
        assert!(STYLE.contains(".row.hazard-panel-open .hazard-panel"));
        assert!(STYLE.contains(".row.decomplex-open .decomplex-panel"));
        assert!(STYLE.contains(".row.sql-cov-open .sql-cov-panel"));
        assert!(STYLE.contains(".row.espalier-open .espalier-panel"));
        assert!(STYLE.contains(".row.nil-kill-open .nil-kill-panel"));
        assert!(STYLE.contains(".decomplex-finding,"));
        assert!(STYLE.contains(".finding-panel p"));
        assert!(STYLE.contains("white-space: normal;"));
        assert!(STYLE.contains(".row:target"));
        assert!(STYLE.contains(".history-drawer[open]"));
        assert!(!html.contains("&#128027;"));
        assert!(!html.contains("&#128163;"));
        assert!(!STYLE.contains("#mode-coverage:checked ~ .viewer .row { background"));
        assert!(!STYLE.contains("#mode-churn:checked ~ .viewer .row { background"));
        assert!(html.contains("--coverage-bg:rgba(34, 197, 94, 0.08)"));
        assert!(html.contains("--churn-bg:rgba(248, 113, 113"));
        assert!(html.contains("--gutter-coverage-bg:rgba(34, 197, 94, 0.18)"));
        assert!(html.contains("--gutter-churn-bg:rgba(248, 113, 113"));
    }

    #[test]
    fn source_view_collapses_long_comment_runs_with_persisted_controls() {
        let payload = UiSourcePayload {
            path: "src/demo.rb".into(),
            commit: None,
            lines: vec![
                "# one".into(),
                "# two".into(),
                "# three".into(),
                "# four".into(),
                "def run".into(),
                "end".into(),
            ],
            versions: Vec::new(),
            symbols: Vec::new(),
            blame: Vec::new(),
            annotations: Vec::new(),
            warnings: Vec::new(),
        };
        let branch_context = UiBranchContext {
            branch: "master".to_string(),
            commit: "abcdef123456".to_string(),
        };
        let folds = detect_comment_folds(&payload.path, &payload.lines);
        let html = render_source_view(&payload, "", &branch_context);

        assert_eq!(folds.len(), 1);
        assert_eq!(folds[0].start_line, 1);
        assert_eq!(folds[0].end_line, 4);
        assert!(html.contains("class=\"comment-fold-toggle\""));
        assert!(html.contains("data-persist-key=\"lineage.comment-fold.src/demo.rb.1\""));
        assert!(html.contains("data-comment-fold-child=\"1\""));
        assert!(html.contains("</span><span class=\"ln\"><label class=\"comment-fold-control\""));
        assert!(!html.contains("comment-fold-control line-icon"));
        assert!(html.contains("class=\"fold-collapsed-source\""));
        assert!(html.contains("# one ..."));

        let js_lines = vec![
            "/* start".to_string(),
            " * middle".to_string(),
            " * middle".to_string(),
            " * end".to_string(),
            " */".to_string(),
        ];
        let js_folds = detect_comment_folds("src/demo.js", &js_lines);
        assert_eq!(js_folds.len(), 1);
        assert_eq!(js_folds[0].end_line, 5);
    }

    #[test]
    fn warning_banner_items_are_dismissible_and_persisted() {
        let html = render_warning_banner(&[UiWarning {
            level: "notice".to_string(),
            label: "Mutation verification is missing".to_string(),
            detail: "7 covered units have no mutant-verified test exposure.".to_string(),
        }]);
        let js = include_str!("assets/app.js");

        assert!(html.contains("data-dismiss-key=\"lineage.warning."));
        assert!(html.contains("class=\"warning-dismiss-toggle\""));
        assert!(html.contains("class=\"warning-dismiss\""));
        assert!(html.contains("Dismiss warning"));
        assert!(STYLE.contains(".warning-dismiss-toggle:checked + .warning"));
        let dismiss_style = STYLE
            .split(".warning-dismiss {")
            .nth(1)
            .and_then(|style| style.split('}').next())
            .unwrap();
        assert!(dismiss_style.contains("cursor: pointer;"));
        assert!(js.contains("warning-dismiss"));
        assert!(js.contains("control.closest(\".warning\")"));
        assert!(js.contains("input.checked = true"));
        assert!(js.contains("bindLayerLabel"));
        assert!(js.contains("bindLineToggleLabel"));
        assert!(js.contains("input.dataset.panelClass"));
        assert!(js.contains("sourceView.classList.toggle(`${input.id}-on`, input.checked)"));
        assert!(js.contains("write(key, \"true\")"));
        assert!(js.contains("comment-fold-expanded"));
    }

    #[test]
    fn index_page_loads_font_awesome_for_gutter_icons() {
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
            .record_coverage_line("abc", 10, "src/demo.rb", 1, 1)
            .unwrap();
        let scope = CoverageScope::all();

        let html = render_index_page(
            &storage,
            dir.path(),
            &UiOverlays::default(),
            &scope,
            Some("src/demo.rb"),
            None,
            None,
            "",
            CoverageSort::Path,
            None,
            1,
        )
        .unwrap();

        assert!(html.contains("cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css"));
        assert!(html.contains("<aside class=\"source-sidebar\">"));
        assert!(!html.contains("list=\"lineage-search-options\""));
        assert!(!html.contains("<nav class=\"files\">"));
        assert!(html.contains("<nav class=\"outline\""));
        assert!(html.contains("href=\"#L1\""));
        assert!(html.contains("<span class=\"outline-kind\">func</span>"));
        assert!(html.contains("class=\"outline-hotspot\""));
        assert!(html.contains("<span class=\"outline-name\">run</span>"));
        assert!(html.contains("class=\"coverage-bar line-quality-bar\""));
    }

    #[test]
    fn line_quality_segments_split_coverage_and_mutant_backing() {
        let segments = line_quality_segments(LineQualityBar {
            tracked_lines: 10,
            covered_lines: 8,
            partial_lines: 2,
            multi_type_lines: 3,
            mutant_backed_lines: 4,
            coverage_percent: 80.0,
        });

        assert_eq!(segments.multi, 30.0);
        assert_eq!(segments.covered, 30.0);
        assert_eq!(segments.partial, 20.0);
        assert_eq!(segments.missed, 20.0);
        assert_eq!(segments.mutant_multi, 30.0);
        assert_eq!(segments.mutant_covered, 10.0);
        assert_eq!(segments.mutant_partial, 0.0);
        assert_eq!(segments.mutant_gap, 60.0);

        let html = render_line_quality_bar(LineQualityBar {
            tracked_lines: 10,
            covered_lines: 8,
            partial_lines: 2,
            multi_type_lines: 3,
            mutant_backed_lines: 4,
            coverage_percent: 80.0,
        });

        assert!(html.contains("line-quality-bar"));
        assert!(html.contains("coverage-track"));
        assert!(html.contains("mutant-track"));
        assert!(html.contains("coverage-partial"));
    }

    #[test]
    fn dashboard_renders_collapsible_risks_hazards_first_and_stacked_bars() {
        let dashboard = UiDashboard {
            files: 2,
            tracked_lines: 10,
            covered_lines: 8,
            coverage_percent: 80.0,
            active_hazards: 2,
            sarif_findings: 7,
            new_findings: 3,
            resolved_findings: 2,
            persisted_findings: 4,
            evidence_covered_hazards: 2,
            hazard_evidence_percent: 100.0,
            covered_hazards: 1,
            hazard_coverage_percent: 50.0,
            mutant_verified_covered_lines: 4,
            mutant_verified_covered_percent: 50.0,
            mutant_killed_covered_lines: 4,
            mutant_killed_covered_percent: 50.0,
            stochastic_mutant_verified_covered_lines: 1,
            stochastic_mutant_verified_covered_percent: 12.5,
            stochastic_mutant_killed_covered_lines: 1,
            stochastic_mutant_killed_covered_percent: 12.5,
            invariant_mutant_verified_covered_lines: 2,
            invariant_mutant_verified_covered_percent: 25.0,
            invariant_mutant_killed_covered_lines: 2,
            invariant_mutant_killed_covered_percent: 25.0,
            multi_type_covered_lines: 3,
            multi_type_covered_percent: 37.5,
            files_with_coverage: 2,
            top_hazard_files: vec![UiFile {
                hazards: 2,
                ..ui_file_for_sort("zig/runtime/a.zig", 10, 8, 1)
            }],
            top_units: Vec::new(),
            review_next: (1..=30)
                .map(|index| UiReviewNextItem {
                    path: format!("src/review_{index}.rb"),
                    start_line: index,
                    title: format!("review_{index}"),
                    detail: "current warning".to_string(),
                    score: f64::from(31 - index),
                })
                .collect(),
            test_next_units: Vec::new(),
            top_architecture_risks: Vec::new(),
            top_complexity_functions: Vec::new(),
            analyzer_health: vec![UiAnalyzerHealth {
                analyzer: "Decomplex".to_string(),
                status: "degraded".to_string(),
                detail: "12 findings were truncated by artifact limits".to_string(),
                scoped_findings: 4,
                total_findings: 20,
            }],
            warnings: Vec::new(),
        };
        let files = dashboard.top_hazard_files.iter().collect::<Vec<_>>();
        let directories = directory_index(&dashboard.top_hazard_files, "");
        let branch_context = UiBranchContext {
            branch: "feature".to_string(),
            commit: "abcdef123456".to_string(),
        };
        let html = render_dashboard(
            &dashboard,
            "",
            &directories,
            &files,
            "",
            CoverageSort::Path,
            &branch_context,
        );

        assert!(html.contains("class=\"dashboard-section dashboard-panel\""));
        assert!(html.contains("class=\"dashboard-section-bar\" role=\"tablist\""));
        assert!(html.contains("data-dashboard-panel=\"dashboard-panel-active-hazards\""));
        assert!(html.contains("role=\"tab\" class=\"active\" aria-selected=\"true\""));
        assert!(html.contains("id=\"dashboard-panel-active-hazards\""));
        assert!(!html.contains("<details id=\"dashboard-panel-"));
        assert!(html.contains("3</strong> new"));
        assert!(html.contains(">Review Next</button>"));
        assert!(html.contains(">Test Next</button>"));
        assert!(!html.contains("<h2>Analyzer and Artifact Health</h2>"));
        assert!(!html.contains("class=\"analyzer-status"));
        assert!(html.contains("class=\"directory-status-cell\""));
        assert!(html.contains("class=\"directory-health directory-health-caution\""));
        assert!(html.contains("fa-triangle-exclamation"));
        assert!(html.contains("regenerate the artifact with a higher result cap"));
        assert!(html.contains("queue=review-next"));
        assert!(html.contains(">Risky Units</button>"));
        assert!(html.contains(">Architectural Risks</button>"));
        assert!(html.contains(">Expensive Functions</button>"));
        assert!(html.contains("class=\"coverage-bar line-quality-bar\""));
        assert!(html.contains("8 of 10 lines covered; 1 partial, 2 missed"));
        assert!(!html.contains(">8 covered lines</span>"));
        assert!(html.contains("4 mutant-backed / 1 stochastic / 2 invariant"));
        assert!(html.contains("class=\"ratio-bar hazard-bar\""));
        assert!(html.contains("Directory entries (1 dirs - 1 files - 7 SARIF findings)"));
        assert!(html.contains("class=\"coverage-name-link\"><i class=\"fa-regular fa-file-lines\""));
        assert!(!html.contains("class=\"metric\""));
        assert!(!html.contains("class=\"dashboard-bars\""));
        assert!(!html.contains("dashboard-line-quality"));
        assert!(!html.contains("<strong>Lines</strong>"));
        assert!(!html.contains("<strong>Mutants</strong>"));
        assert_eq!(html.matches("class=\"ratio-bar hazard-bar\"").count(), 1);
        assert_eq!(html.matches("class=\"ratio-bar mutant-bar\"").count(), 0);
        assert!(
            html.find("4 mutant-backed / 1 stochastic / 2 invariant").unwrap()
                < html.find("Active Hazards").unwrap(),
            "mutant detail should live in the top branch-context bar, not between dashboard sections"
        );
        assert!(
            html.find("Active Hazards").unwrap() < html.find("Directory entries").unwrap(),
            "hazards should render above code tree"
        );
        assert!(
            html.find("Hazard Files").unwrap() < html.find("Risky Units").unwrap(),
            "hazard files should render above risk sections"
        );

        let queue_page = render_queue_page(&dashboard, "review-next", "src", "", 2);
        assert!(queue_page.contains("Page 2 of 2 &middot; 30 results"));
        assert!(queue_page.contains("review_26"));
        assert!(queue_page.contains("rel=\"prev\""));
        assert!(!queue_page.contains("rel=\"next\""));

        let no_hazard = UiDashboard {
            active_hazards: 0,
            covered_hazards: 0,
            evidence_covered_hazards: 0,
            top_hazard_files: Vec::new(),
            ..dashboard
        };
        let hazards = render_active_hazards_section(&no_hazard);
        assert!(hazards.contains("class=\"dashboard-section dashboard-panel\""));
        assert!(!hazards.contains(" hidden"));
        assert!(hazards.contains("No active systems hazards are recorded."));
    }

    #[test]
    fn test_next_prioritizes_integration_for_sparse_critical_path_testing() {
        let unit = UiUnitHotspot {
            path: "src/payments.rb".to_string(),
            name: "charge".to_string(),
            kind: "function".to_string(),
            start_line: 12,
            score: 9.0,
            risk_score: 7.0,
            sarif_findings: 2,
            dark_arms: 1,
            hazards: 1,
            fixes: 3,
            changes: 8,
            mutant_killed_tests: 0,
            mutant_verified_tests: 0,
            distinct_tests: 1,
            test_types: "unit".to_string(),
            line_coverage: 0.0,
            integration_coverage: 0.0,
            is_hard_gated: true,
            reopened_count: 0,
        };

        let (test_type, rationale, _) = test_next_recommendation(&unit).unwrap();
        assert_eq!(test_type, "integration");
        assert!(rationale.contains("critical path"));
        assert!(rationale.contains("uncovered"));
        assert!(rationale.contains("historically buggy"));
        assert!(rationale.contains("only sparse unit tests"));
        assert!(rationale.contains("add integration tests"));
    }

    #[test]
    fn review_and_test_candidates_stay_inside_the_current_directory() {
        let storage = Storage::open_memory().unwrap();
        for (name, path) in [("inside", "src/inside.rb"), ("outside", "other/outside.rb")] {
            let signature = format!("def {name}");
            let body = format!("def {name}\n1\nend");
            let unit = LogicalUnit::new(
                name,
                UnitKind::Function,
                path,
                1,
                1,
                3,
                signature,
                &body,
            );
            storage.upsert_logical_unit(&unit, 10).unwrap();
            storage
                .insert_event(&Event {
                    unit_id: unit.id,
                    commit_hash: "abc".to_string(),
                    event_type: EventType::Fix,
                    path: path.to_string(),
                    name: name.to_string(),
                    start_line: 1,
                    end_line: 3,
                    semantic_change: true,
                    lines_added: 1,
                    lines_removed: 1,
                    timestamp: 10,
                })
                .unwrap();
        }

        let review = unit_hotspots(&storage, "src", &CoverageScope::all(), None, 12, false).unwrap();
        let test = test_next_hotspots(&storage, "src", &CoverageScope::all(), None, 200).unwrap();
        assert_eq!(review.len(), 1);
        assert_eq!(test.len(), 1);
        assert_eq!(review[0].path, "src/inside.rb");
        assert_eq!(test[0].path, "src/inside.rb");
    }

    #[test]
    fn complexity_display_rank_orders_all_emitted_complexities() {
        assert_eq!(complexity_display_rank("O(N)"), 10);
        assert_eq!(complexity_display_rank("O(N log N)"), 11);
        assert_eq!(complexity_display_rank("O(N^4)"), 18);
        assert_eq!(complexity_display_rank("O(N^4 log N)"), 19);
        assert_eq!(complexity_display_rank("O(2^N)"), 100);
        assert_eq!(complexity_display_rank("O(N!)"), 200);
    }

    #[test]
    fn branch_context_legend_lists_coverage_states_without_hazard_marker() {
        let context = UiBranchContext {
            branch: "feature".to_string(),
            commit: "abcdef123456".to_string(),
        };
        let coverage = UiCoverageContext {
            path: "src/demo.rb".to_string(),
            tracked_lines: 4,
            covered_lines: 3,
            partial_lines: 1,
            missed_lines: 1,
            multi_type_lines: 1,
            mutant_backed_lines: 1,
            stochastic_mutant_backed_lines: 1,
            invariant_mutant_backed_lines: 0,
            coverage_percent: 75.0,
        };
        let html = render_branch_context(&context, &coverage, "");

        assert!(html.contains("coverage-multi\" style=\"width:25.000%"));
        assert!(html.contains("Multi-covered"));
        assert!(html.contains(">covered</span>"));
        assert!(html.contains(">partial</span>"));
        assert!(html.contains(">missed</span>"));
        assert!(!html.contains("legend-alert"));
        assert!(!html.contains(">hazard</span>"));
        assert!(html.find("Multi-covered").unwrap() < html.find(">covered</span>").unwrap());
        assert!(html.find(">covered</span>").unwrap() < html.find(">partial</span>").unwrap());
        assert!(html.find(">partial</span>").unwrap() < html.find(">missed</span>").unwrap());
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
                sarif_findings: 0,
                dark_arm_findings: 0,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 3,
                mutant_killed_tests: 4,
                tracked_lines: 10,
                covered_lines: 5,
                partial_lines: 0,
                line_coverage: 50.0,
                mutant_coverage: 25.0,
                mutant_verified_covered_lines: 0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_verified_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_verified_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            },
            UiFile {
                path: "src/internal/b.rb".into(),
                units: 2,
                hazards: 1,
                sarif_findings: 0,
                dark_arm_findings: 0,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 5,
                mutant_killed_tests: 6,
                tracked_lines: 30,
                covered_lines: 15,
                partial_lines: 0,
                line_coverage: 75.0,
                mutant_coverage: 50.0,
                mutant_verified_covered_lines: 0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_verified_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_verified_covered_lines: 0,
                invariant_mutant_killed_covered_lines: 0,
                multi_type_covered_lines: 0,
                read_model: false,
            },
            UiFile {
                path: "zig/c.zig".into(),
                units: 3,
                hazards: 7,
                sarif_findings: 0,
                dark_arm_findings: 0,
                evidence_covered_hazards: 0,
                covered_hazards: 0,
                distinct_tests: 8,
                mutant_killed_tests: 9,
                tracked_lines: 4,
                covered_lines: 4,
                partial_lines: 0,
                line_coverage: 100.0,
                mutant_coverage: 0.0,
                mutant_verified_covered_lines: 0,
                mutant_killed_covered_lines: 0,
                stochastic_mutant_verified_covered_lines: 0,
                stochastic_mutant_killed_covered_lines: 0,
                invariant_mutant_verified_covered_lines: 0,
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
        assert_eq!(root[0].line_coverage, 68.75);

        let src = directory_index(&files, "src");
        assert_eq!(src.len(), 1);
        assert_eq!(src[0].path, "src/internal");
        assert_eq!(files_in_directory(&files, "src")[0].path, "src/a.rb");
    }

    #[test]
    fn sorted_code_tree_entries_list_immediate_directories_before_files() {
        let files = vec![
            ui_file_for_sort("src/a.rb", 10, 9, 1),
            ui_file_for_sort("src/internal/b.rb", 20, 10, 2),
            ui_file_for_sort("src/internal/deeper/c.rb", 4, 4, 0),
            ui_file_for_sort("zig/runtime/a.zig", 8, 1, 0),
        ];
        let directories = directory_index(&files, "src");
        let files = files_in_directory(&files, "src");

        let by_path = sorted_code_tree_entries(&directories, &files, CoverageSort::Path)
            .into_iter()
            .map(|entry| entry.name().to_string())
            .collect::<Vec<_>>();
        let by_missed = sorted_code_tree_entries(&directories, &files, CoverageSort::Missed)
            .into_iter()
            .map(|entry| entry.name().to_string())
            .collect::<Vec<_>>();
        let by_percent = sorted_code_tree_entries(&directories, &files, CoverageSort::Percent)
            .into_iter()
            .map(|entry| entry.name().to_string())
            .collect::<Vec<_>>();

        assert_eq!(by_path, vec!["src/internal", "src/a.rb"]);
        assert_eq!(by_missed, vec!["src/internal", "src/a.rb"]);
        assert_eq!(by_percent, vec!["src/a.rb", "src/internal"]);
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
            .record_coverage_line("abc", 10, "src/a.rb", 1, 2)
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
        let test_unit = LogicalUnit::new(
            "test_run",
            UnitKind::Function,
            "gems/decomplex/test/report_test.rb",
            1,
            1,
            2,
            "def test_run",
            "def test_run\nend",
        );
        storage.upsert_logical_unit(&test_unit, 10).unwrap();

        storage.refresh_ui_summaries().unwrap();

        let files = file_index(&storage, None).unwrap();
        assert_eq!(files.len(), 1);
        assert!(files[0].read_model);
        assert_eq!(files[0].path, "src/a.rb");
        assert_eq!(files[0].tracked_lines, 2);
        assert_eq!(files[0].covered_lines, 1);
        assert_eq!(files[0].mutant_killed_covered_lines, 1);
        assert_eq!(files[0].multi_type_covered_lines, 1);

        let dashboard = dashboard_summary(&storage).unwrap();
        assert_eq!(dashboard.files, 1);
        assert_eq!(dashboard.tracked_lines, 2);
        assert_eq!(dashboard.covered_lines, 1);
        assert_eq!(dashboard.multi_type_covered_lines, 1);
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
            is_partial: false,
            mutant_tested: false,
            test_types: Vec::new(),
            distinct_tests: 0,
            mutant_verified_tests: 0,
            mutant_killed_tests: 0,
            stochastic_mutant_verified_tests: 0,
            invariant_mutant_verified_tests: 0,
            line_hits: Some(1),
            line_coverage: None,
            mutant_coverage: None,
            dark_arms: Vec::new(),
            dark_arm_spans: Vec::new(),
            effect_spans: Vec::new(),
            findings: Vec::new(),
            hazards: Vec::new(),
            test_type_counts: BTreeMap::new(),
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
            render_line_details_panel(line_two)
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
            is_partial: true,
            mutant_tested: false,
            test_types: Vec::new(),
            distinct_tests: 0,
            mutant_verified_tests: 0,
            mutant_killed_tests: 0,
            stochastic_mutant_verified_tests: 0,
            invariant_mutant_verified_tests: 0,
            line_hits: Some(1),
            line_coverage: None,
            mutant_coverage: None,
            dark_arms: vec!["dark arm: else".to_string()],
            dark_arm_spans: vec![UiDarkArm {
                label: "dark arm: else".to_string(),
                span: Some([1, 4, 1, 8]),
            }],
            effect_spans: Vec::new(),
            findings: Vec::new(),
            hazards: Vec::new(),
            test_type_counts: BTreeMap::new(),
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

    #[test]
    fn coverage_background_paints_partial_coverage_when_dark_arms_exist() {
        let mut annotation = empty_annotation(1);
        annotation.covered = true;
        annotation.is_partial = true;
        annotation.dark_arms = vec!["dark arm: else".to_string()];

        let bg = coverage_background(&annotation, false);
        assert_eq!(bg, "rgba(31, 41, 55, 0.16)");

        let gutter_bg = coverage_background(&annotation, true);
        assert_eq!(gutter_bg, "rgba(31, 41, 55, 0.32)");
        assert_eq!(gutter_title(&annotation), "coverage quality: partial");
    }

    #[test]
    fn coverage_background_unpainted_when_uncovered_even_with_dark_arms() {
        let mut annotation = empty_annotation(1);
        annotation.covered = false;
        annotation.dark_arms = vec!["dark arm: else".to_string()];

        let bg = coverage_background(&annotation, false);
        assert_eq!(bg, "transparent");

        let gutter_bg = coverage_background(&annotation, true);
        assert_eq!(gutter_bg, "transparent");
    }

    #[test]
    fn coverage_background_unpainted_when_uncovered_even_with_mutant_tested() {
        let mut annotation = empty_annotation(1);
        annotation.covered = false;
        annotation.mutant_tested = true;

        let bg = coverage_background(&annotation, false);
        assert_eq!(bg, "transparent");

        let gutter_bg = coverage_background(&annotation, true);
        assert_eq!(gutter_bg, "transparent");
    }

    #[test]
    fn highlight_source_line_with_dark_arms_skips_uncovered_lines() {
        let mut annotation = empty_annotation(1);
        annotation.covered = false;
        annotation.dark_arm_spans = vec![UiDarkArm {
            label: "dark arm: else".to_string(),
            span: Some([0, 0, 0, 5]),
        }];

        let html = highlight_source_line_with_dark_arms("src/demo.rb", 1, "return x;", Some(&annotation));
        assert!(!html.contains("dark-arm-span"));
    }

    fn ui_file_for_sort(path: &str, tracked_lines: i64, covered_lines: i64, partial: i64) -> UiFile {
        UiFile {
            path: path.to_string(),
            units: 1,
            hazards: 0,
            sarif_findings: 0,
            dark_arm_findings: partial,
            evidence_covered_hazards: 0,
            covered_hazards: 0,
            distinct_tests: 0,
            mutant_killed_tests: 0,
            tracked_lines,
            covered_lines,
            partial_lines: partial,
            line_coverage: percent(covered_lines, tracked_lines),
            mutant_coverage: 0.0,
            mutant_verified_covered_lines: 0,
            mutant_killed_covered_lines: 0,
            stochastic_mutant_verified_covered_lines: 0,
            stochastic_mutant_killed_covered_lines: 0,
            invariant_mutant_verified_covered_lines: 0,
            invariant_mutant_killed_covered_lines: 0,
            multi_type_covered_lines: 0,
            read_model: false,
        }
    }
}
