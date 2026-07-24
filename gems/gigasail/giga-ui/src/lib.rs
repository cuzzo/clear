//! Gigasail web UI, language server, and MCP surfaces.
//!
//! Re-exports the giga-core modules the UI code references via `crate::` so
//! the moved source keeps its internal paths.

pub use giga_core::*;
pub use giga_core::{architecture, diff, extract, git, hazard, model, storage, vcs};

#[path = "ui/ui.rs"]
pub mod ui;
#[path = "ui/lsp.rs"]
pub mod lsp;
#[path = "ui/mcp.rs"]
pub mod mcp;

pub use lsp::{
    diagnostics_for_annotations, gutter_items_for_annotations, serve_lsp, GutterItem,
    GutterUpdateParams,
};
pub use mcp::serve_mcp;
pub use ui::{
    dashboard_summary, file_index, line_annotations, serve_ui, serve_ui_with_overlays,
    source_payload, source_payload_with_overlays, UiBugEvent, UiDashboard, UiFile,
    UiLineAnnotation, UiOverlays, UiSourcePayload,
};
