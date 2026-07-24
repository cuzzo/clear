//! Logical-unit gigasail tracking for historical risk scoring.
//!
//! The crate is intentionally split around replaceable boundaries:
//! VCS traversal, source boundary extraction, analysis, and storage.

#[path = "db/architecture.rs"]
pub mod architecture;
pub mod diff;
pub mod diff_render;
pub mod diff_service;
#[path = "db/engine.rs"]
pub mod engine;
#[path = "db/extract.rs"]
pub mod extract;
#[path = "db/git.rs"]
pub mod git;
#[path = "db/hazard.rs"]
pub mod hazard;
#[path = "db/hotness.rs"]
pub mod hotness;
pub mod ingest_service;
pub mod lock;
#[path = "db/model.rs"]
pub mod model;
#[path = "db/mutant.rs"]
pub mod mutant;
pub mod pipeline;
#[path = "db/quality.rs"]
pub mod quality;
pub mod review;
#[path = "db/sarif.rs"]
pub mod sarif;
#[path = "db/stack_trace.rs"]
pub mod stack_trace;
#[path = "db/storage.rs"]
pub mod storage;
#[path = "db/test_exposure.rs"]
pub mod test_exposure;
#[path = "db/vcs.rs"]
pub mod vcs;
pub use architecture::{
    architecture_search, ingest_architecture_json, node_neighborhood, owner_inventory,
    state_access, ArchitectureIngestStats,
};
pub use diff::{
    build_diff_plan, build_diff_plan_with_renames, with_evidence_scope, ChangeInventory,
    DependencyChange, DiffFile, DiffPlan, DiffScope, EvidenceScopeFingerprint, RevisionFile,
};
pub use diff_render::{
    render_structured_diff_json, render_structured_diff_text, structured_diff_document,
    StructuredDiffDocument, STRUCTURED_DIFF_FORMAT_VERSION,
};
pub use diff_service::{build_structured_diff, DiffRequest};
pub use engine::{EngineStats, LineageEngine};
pub use extract::{BoundaryExtractor, HeuristicExtractor, SourceFilter};
pub use git::GitProvider;
pub use hazard::{ingest_hazards, HazardIngestStats};
pub use hotness::{ingest_hotness_json, HotnessIngestStats};
pub use model::{
    BlobFile, CommitMetadata, CrashEvent, Event, EventType, HazardEvent, LogicalUnit, QualityEvent,
    QualityMetric, SarifArtifact, SarifFinding, TestExposureEvent, UnitKind,
};
pub use mutant::{
    ingest_mutant_facts_json, ingest_mutant_facts_json_with_options, parse_mutant_facts,
    MutantFact, MutantIngestOptions, MutantIngestStats,
};
pub use pipeline::{
    latest_run_directory, load_config, load_config_contents, load_run_manifest, publish_run,
    read_manifest_artifact, recover_workspace_transactions, repository_identity, run_manifest_hash,
    seal_published_run, validate_run_artifacts, ArtifactCompression, ArtifactKind, CompletedRun,
    LineageConfig, ProfileExecutionSession, ProfileRunKind, RunManifest, RunStatus,
};
pub use quality::{
    coverage_records_to_test_exposure_json, ingest_coverage_json,
    ingest_coverage_json_with_options, parse_coverage_input, resolve_coverage_record_paths,
    CoverageIngestOptions, CoverageIngestStats, CoverageRecord,
};
pub use sarif::{
    ingest_sarif_paths, normalize_sarif_document, NormalizedSarifFinding, SarifIngestStats,
};
pub use stack_trace::{
    ingest_stack_traces, LanguageNormalizer, RepoPathNormalizer, SentryProvider, StackIngestStats,
    StackPayload, StackTraceProvider,
};
pub use storage::{CiRunRecord, EvidenceArtifactScope, Storage, UnitSummary};
pub use test_exposure::{
    ingest_test_exposure_json, parse_test_exposure_records, TestExposureIngestStats,
    TestExposureRecord,
};
pub use vcs::VcsProvider;
