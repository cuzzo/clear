//! Logical-unit lineage tracking for historical risk scoring.
//!
//! The crate is intentionally split around replaceable boundaries:
//! VCS traversal, source boundary extraction, analysis, and storage.

pub mod engine;
pub mod extract;
pub mod git;
pub mod model;
pub mod storage;
pub mod vcs;

pub use engine::{EngineStats, LineageEngine};
pub use extract::{BoundaryExtractor, HeuristicExtractor, SourceFilter};
pub use git::GitProvider;
pub use model::{BlobFile, CommitMetadata, Event, EventType, LogicalUnit, UnitKind};
pub use storage::{Storage, UnitSummary};
pub use vcs::VcsProvider;
