//! Logical-unit gigasail tracking for historical risk scoring.
//!
//! This package is the CLI/TUI frontend. The data/analysis backend lives in
//! `giga-core`; its modules and symbols are re-exported here so downstream
//! `gigasail::` references and internal `crate::` paths keep resolving.

pub use giga_core::*;
pub use giga_core::{
    architecture, diff, diff_render, diff_service, engine, extract, git, hazard, hotness,
    ingest_service, model, mutant, pipeline, quality, sarif, stack_trace, storage, test_exposure,
    vcs,
};

pub mod application;
pub mod cli;
