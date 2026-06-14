//! Logical-unit lineage tracking for historical risk scoring.
//!
//! The crate is intentionally split around replaceable boundaries:
//! VCS traversal, source boundary extraction, analysis, and storage.

pub mod engine;
pub mod extract;
pub mod git;
pub mod hazard;
pub mod model;
pub mod quality;
pub mod stack_trace;
pub mod storage;
pub mod test_exposure;
pub mod ui;
pub mod vcs;

pub use engine::{EngineStats, LineageEngine};
pub use extract::{BoundaryExtractor, HeuristicExtractor, SourceFilter};
pub use git::GitProvider;
pub use hazard::{ingest_hazards, HazardIngestStats};
pub use model::{
    BlobFile, CommitMetadata, CrashEvent, Event, EventType, LogicalUnit, QualityEvent,
    HazardEvent, QualityMetric, TestExposureEvent, UnitKind,
};
pub use quality::{ingest_coverage_json, CoverageIngestStats, CoverageRecord};
pub use stack_trace::{
    ingest_stack_traces, LanguageNormalizer, RepoPathNormalizer, SentryProvider,
    StackIngestStats, StackPayload, StackTraceProvider,
};
pub use storage::{Storage, UnitSummary};
pub use test_exposure::{
    ingest_test_exposure_json, parse_test_exposure_records, TestExposureIngestStats,
    TestExposureRecord,
};
pub use ui::{
    file_index, serve_ui, serve_ui_with_overlays, source_payload, source_payload_with_overlays,
    UiFile, UiLineAnnotation, UiOverlays, UiSourcePayload,
};
pub use vcs::VcsProvider;
