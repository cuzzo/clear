use crate::storage::Storage;
use crate::ui::{line_annotations, UiLineAnnotation, UiOverlays};
use anyhow::Result;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tower_lsp::jsonrpc::Result as LspResult;
use tower_lsp::lsp_types::notification::Notification;
use tower_lsp::lsp_types::{
    CodeLens, CodeLensOptions, CodeLensParams, Command, Diagnostic, DiagnosticSeverity,
    DidChangeTextDocumentParams, DidCloseTextDocumentParams, DidOpenTextDocumentParams,
    DidSaveTextDocumentParams, Hover, HoverContents, HoverParams, InitializeParams,
    InitializeResult, InitializedParams, MarkupContent, MarkupKind, MessageType, Position, Range,
    ServerCapabilities, TextDocumentSyncCapability, TextDocumentSyncKind, Url,
};
use tower_lsp::{Client, LanguageServer, LspService, Server};

#[derive(Clone)]
struct LineageLsp {
    client: Client,
    db: PathBuf,
    repo: PathBuf,
    overlays: UiOverlays,
}

#[derive(Debug)]
struct FileFacts {
    path: String,
    annotations: Vec<UiLineAnnotation>,
    units: Vec<LspUnit>,
}

#[derive(Debug, Clone)]
struct LspUnit {
    id: String,
    name: String,
    kind: String,
    start_line: u32,
    end_line: u32,
    total_events: i64,
    changes: i64,
    fixes: i64,
    risk_score: f64,
    current_distinct_tests: i64,
    current_test_types: String,
    current_mutant_verified_tests: i64,
    current_mutant_killed_tests: i64,
    semantic_changes_after_mutant_run: i64,
    verification_staleness_score: f64,
    reopened_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GutterUpdateParams {
    pub uri: Url,
    pub items: Vec<GutterItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GutterItem {
    pub line: u32,
    pub kind: String,
    pub label: String,
    pub verified: bool,
    pub message: String,
}

enum GutterUpdate {}

impl Notification for GutterUpdate {
    type Params = GutterUpdateParams;
    const METHOD: &'static str = "lineage/gutterUpdate";
}

pub async fn serve_lsp(
    db: impl AsRef<Path>,
    repo: impl AsRef<Path>,
    overlay_paths: &[PathBuf],
) -> Result<()> {
    let db = db.as_ref().to_path_buf();
    let repo = repo.as_ref().to_path_buf();
    let overlays = UiOverlays::load(overlay_paths)?;
    Storage::open(&db)?;
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();
    let (service, socket) = LspService::new(move |client| LineageLsp {
        client,
        db: db.clone(),
        repo: repo.clone(),
        overlays: overlays.clone(),
    });
    Server::new(stdin, stdout, socket).serve(service).await;
    Ok(())
}

#[tower_lsp::async_trait]
impl LanguageServer for LineageLsp {
    async fn initialize(&self, _: InitializeParams) -> LspResult<InitializeResult> {
        Ok(InitializeResult {
            capabilities: ServerCapabilities {
                text_document_sync: Some(TextDocumentSyncCapability::Kind(
                    TextDocumentSyncKind::FULL,
                )),
                hover_provider: Some(tower_lsp::lsp_types::HoverProviderCapability::Simple(true)),
                code_lens_provider: Some(CodeLensOptions {
                    resolve_provider: Some(false),
                }),
                ..ServerCapabilities::default()
            },
            server_info: None,
        })
    }

    async fn initialized(&self, _: InitializedParams) {
        self.client
            .log_message(MessageType::INFO, "Lineage LSP initialized")
            .await;
    }

    async fn shutdown(&self) -> LspResult<()> {
        Ok(())
    }

    async fn did_open(&self, params: DidOpenTextDocumentParams) {
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_save(&self, params: DidSaveTextDocumentParams) {
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_close(&self, params: DidCloseTextDocumentParams) {
        self.client
            .publish_diagnostics(params.text_document.uri, Vec::new(), None)
            .await;
    }

    async fn hover(&self, params: HoverParams) -> LspResult<Option<Hover>> {
        let uri = params.text_document_position_params.text_document.uri;
        let line = params.text_document_position_params.position.line + 1;
        match self.file_facts(&uri) {
            Ok(Some(facts)) => Ok(hover_for_line(&facts, line)),
            Ok(None) => Ok(None),
            Err(error) => {
                self.log_error(format!("lineage hover failed: {error:#}")).await;
                Ok(None)
            }
        }
    }

    async fn code_lens(&self, params: CodeLensParams) -> LspResult<Option<Vec<CodeLens>>> {
        match self.file_facts(&params.text_document.uri) {
            Ok(Some(facts)) => Ok(Some(code_lenses_for_units(&facts))),
            Ok(None) => Ok(Some(Vec::new())),
            Err(error) => {
                self.log_error(format!("lineage codeLens failed: {error:#}"))
                    .await;
                Ok(Some(Vec::new()))
            }
        }
    }
}

impl LineageLsp {
    async fn publish_document(&self, uri: Url) {
        match self.file_facts(&uri) {
            Ok(Some(facts)) => {
                let diagnostics = diagnostics_for_annotations(&facts.annotations);
                let gutter_items = gutter_items_for_annotations(&facts.annotations);
                self.client
                    .publish_diagnostics(uri.clone(), diagnostics, None)
                    .await;
                self.client
                    .send_notification::<GutterUpdate>(GutterUpdateParams {
                        uri,
                        items: gutter_items,
                    })
                    .await;
            }
            Ok(None) => {}
            Err(error) => {
                self.log_error(format!("lineage diagnostics failed: {error:#}"))
                    .await;
            }
        }
    }

    async fn log_error(&self, message: String) {
        self.client.log_message(MessageType::ERROR, message).await;
    }

    fn file_facts(&self, uri: &Url) -> Result<Option<FileFacts>> {
        let Some(path) = self.repo_path_for_uri(uri)? else {
            return Ok(None);
        };
        let storage = Storage::open_existing(&self.db)?;
        let annotations = line_annotations(&storage, &path, &self.overlays)?;
        let units = file_units(&storage, &path)?;
        Ok(Some(FileFacts {
            path,
            annotations,
            units,
        }))
    }

    fn repo_path_for_uri(&self, uri: &Url) -> Result<Option<String>> {
        let file_path = uri
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("unsupported non-file URI {uri}"))?;
        let repo = self.repo.canonicalize().unwrap_or_else(|_| self.repo.clone());
        let full = file_path
            .canonicalize()
            .unwrap_or_else(|_| file_path.clone());
        let rel = full
            .strip_prefix(&repo)
            .or_else(|_| file_path.strip_prefix(&self.repo));
        match rel {
            Ok(path) => Ok(Some(path_to_repo_string(path))),
            Err(_) => Ok(None),
        }
    }
}

fn file_units(storage: &Storage, path: &str) -> Result<Vec<LspUnit>> {
    let risk_by_id = storage
        .top_units(100_000, &[])?
        .into_iter()
        .map(|unit| (unit.id.clone(), unit))
        .collect::<HashMap<_, _>>();
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
        SELECT u.id,
               u.name,
               u.type,
               COALESCE(le.start_line, 1),
               COALESCE(le.end_line, le.start_line, 1),
               COUNT(e.id),
               COALESCE(SUM(CASE WHEN e.event_type = 'CHANGE' THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN e.event_type = 'FIX' THEN 1 ELSE 0 END), 0),
               u.current_distinct_tests,
               u.current_test_types,
               u.current_mutant_verified_tests,
               u.current_mutant_killed_tests
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        LEFT JOIN events e ON e.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        GROUP BY u.id, u.name, u.type, le.start_line, le.end_line,
                 u.current_distinct_tests, u.current_test_types,
                 u.current_mutant_verified_tests, u.current_mutant_killed_tests
        ORDER BY COALESCE(le.start_line, 1), u.name
        "#,
    )?;
    let rows = stmt.query_map(params![path], |row| {
        let id: String = row.get(0)?;
        let summary = risk_by_id.get(&id);
        let risk_score = summary.map(|unit| unit.risk_score).unwrap_or_default();
        Ok(LspUnit {
            id,
            name: row.get(1)?,
            kind: row.get(2)?,
            start_line: row.get(3)?,
            end_line: row.get(4)?,
            total_events: row.get(5)?,
            changes: row.get(6)?,
            fixes: row.get(7)?,
            risk_score,
            current_distinct_tests: row.get(8)?,
            current_test_types: row.get(9)?,
            current_mutant_verified_tests: row.get(10)?,
            current_mutant_killed_tests: row.get(11)?,
            semantic_changes_after_mutant_run: summary
                .map(|unit| unit.semantic_changes_after_mutant_run)
                .unwrap_or_default(),
            verification_staleness_score: summary
                .map(|unit| unit.verification_staleness_score)
                .unwrap_or_default(),
            reopened_count: summary.map(|unit| unit.reopened_count).unwrap_or_default(),
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

pub fn diagnostics_for_annotations(annotations: &[UiLineAnnotation]) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();
    for annotation in annotations {
        for hazard in annotation.hazards.iter().filter(|hazard| !hazard.verified) {
            diagnostics.push(Diagnostic {
                range: range_for_line(annotation.line),
                severity: Some(DiagnosticSeverity::WARNING),
                code: Some(tower_lsp::lsp_types::NumberOrString::String(
                    "lineage.hazard".to_string(),
                )),
                source: Some("lineage".to_string()),
                message: format!(
                    "{} requires {} coverage",
                    hazard.hazard_type, hazard.required_evidence
                ),
                ..Diagnostic::default()
            });
        }
        for dark_arm in &annotation.dark_arms {
            diagnostics.push(Diagnostic {
                range: range_for_line(annotation.line),
                severity: Some(DiagnosticSeverity::HINT),
                code: Some(tower_lsp::lsp_types::NumberOrString::String(
                    "lineage.darkArm".to_string(),
                )),
                source: Some("lineage".to_string()),
                message: format!("uncovered branch arm: {dark_arm}"),
                ..Diagnostic::default()
            });
        }
        for finding in &annotation.findings {
            diagnostics.push(Diagnostic {
                range: range_for_line(annotation.line),
                severity: Some(diagnostic_severity(&finding.level)),
                code: Some(tower_lsp::lsp_types::NumberOrString::String(
                    finding.rule_id.clone(),
                )),
                source: Some(format!("lineage:{}", finding.tool)),
                message: finding.message.clone(),
                ..Diagnostic::default()
            });
        }
    }
    diagnostics
}

pub fn gutter_items_for_annotations(annotations: &[UiLineAnnotation]) -> Vec<GutterItem> {
    let mut items = Vec::new();
    for annotation in annotations {
        if annotation.covered {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: "covered".to_string(),
                label: "covered".to_string(),
                verified: true,
                message: annotation
                    .line_hits
                    .map(|hits| format!("line hits {hits}"))
                    .unwrap_or_else(|| "covered by tests".to_string()),
            });
        }
        if annotation.mutant_tested {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: "mutant".to_string(),
                label: "mutant tested".to_string(),
                verified: true,
                message: format!(
                    "{} mutant killed / {} verified",
                    annotation.mutant_killed_tests, annotation.mutant_verified_tests
                ),
            });
        }
        for hazard in &annotation.hazards {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: if hazard.verified {
                    "hazard_verified"
                } else {
                    "hazard_open"
                }
                .to_string(),
                label: "hazard".to_string(),
                verified: hazard.verified,
                message: format!(
                    "{} requires {} coverage",
                    hazard.hazard_type, hazard.required_evidence
                ),
            });
        }
        for dark_arm in &annotation.dark_arms {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: "dark_arm".to_string(),
                label: "dark arm".to_string(),
                verified: false,
                message: format!("uncovered branch arm: {dark_arm}"),
            });
        }
        for finding in &annotation.findings {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: "sarif".to_string(),
                label: finding.tool.clone(),
                verified: false,
                message: format!("{}: {}", finding.rule_id, finding.message),
            });
        }
    }
    items
}

fn diagnostic_severity(level: &str) -> DiagnosticSeverity {
    match level.to_ascii_lowercase().as_str() {
        "error" => DiagnosticSeverity::ERROR,
        "warning" => DiagnosticSeverity::WARNING,
        "note" => DiagnosticSeverity::INFORMATION,
        _ => DiagnosticSeverity::HINT,
    }
}

fn hover_for_line(facts: &FileFacts, line: u32) -> Option<Hover> {
    let unit = facts
        .units
        .iter()
        .filter(|unit| unit.start_line <= line && line <= unit.end_line)
        .min_by_key(|unit| unit.end_line.saturating_sub(unit.start_line));
    let annotation = facts.annotations.iter().find(|annotation| annotation.line == line);
    if unit.is_none() && annotation.is_none() {
        return None;
    }

    let mut lines = Vec::new();
    lines.push("### Lineage".to_string());
    lines.push(format!("`{}` line {}", facts.path, line));
    if let Some(unit) = unit {
        lines.push(format!(
            "**{} {}**: risk {:.1}, fixes {}, changes {}, events {}",
            unit.kind, unit.name, unit.risk_score, unit.fixes, unit.changes, unit.total_events
        ));
        lines.push(format!(
            "Tests: {} distinct, mutant killed {}/{}",
            unit.current_distinct_tests,
            unit.current_mutant_killed_tests,
            unit.current_mutant_verified_tests
        ));
        if !unit.current_test_types.trim().is_empty() {
            lines.push(format!("Test types: {}", unit.current_test_types));
        }
        if unit.semantic_changes_after_mutant_run > 0 {
            lines.push(format!(
                "Mutation verification stale: {} semantic changes since latest mutant run, age {:.1} days",
                unit.semantic_changes_after_mutant_run, unit.verification_staleness_score
            ));
        }
        if unit.reopened_count > 0 {
            lines.push(format!("Reopened crash frames after fix: {}", unit.reopened_count));
        }
    }
    if let Some(annotation) = annotation {
        if let Some(hits) = annotation.line_hits {
            lines.push(format!("Line hits: {hits}"));
        }
        if !annotation.test_types.is_empty() {
            lines.push(format!("Line test types: {}", annotation.test_types.join(", ")));
        }
        for hazard in &annotation.hazards {
            lines.push(format!(
                "Hazard: {} requires {} ({})",
                hazard.hazard_type,
                hazard.required_evidence,
                if hazard.verified { "verified" } else { "missing" }
            ));
        }
        for dark_arm in &annotation.dark_arms {
            lines.push(format!("Dark arm: {dark_arm}"));
        }
        for finding in &annotation.findings {
            lines.push(format!(
                "SARIF {} `{}`: {}",
                finding.tool, finding.rule_id, finding.message
            ));
        }
    }

    let range = unit.map(|unit| Range {
        start: Position::new(lsp_line(unit.start_line), 0),
        end: Position::new(lsp_line(unit.end_line), 0),
    });
    Some(Hover {
        contents: HoverContents::Markup(MarkupContent {
            kind: MarkupKind::Markdown,
            value: lines.join("\n\n"),
        }),
        range,
    })
}

fn code_lenses_for_units(facts: &FileFacts) -> Vec<CodeLens> {
    facts
        .units
        .iter()
        .map(|unit| CodeLens {
            range: range_for_line(unit.start_line),
            command: Some(Command {
                title: format!(
                    "Lineage: risk {:.1} | fixes {} | tests {} | mutant {}/{} | stale {} | reopened {}",
                    unit.risk_score,
                    unit.fixes,
                    unit.current_distinct_tests,
                    unit.current_mutant_killed_tests,
                    unit.current_mutant_verified_tests,
                    unit.semantic_changes_after_mutant_run,
                    unit.reopened_count
                ),
                command: "lineage.showUnit".to_string(),
                arguments: Some(vec![serde_json::json!({
                    "path": facts.path,
                    "unit_id": unit.id,
                    "name": unit.name,
                    "kind": unit.kind,
                })]),
            }),
            data: None,
        })
        .collect()
}

fn range_for_line(line: u32) -> Range {
    let line = lsp_line(line);
    Range {
        start: Position::new(line, 0),
        end: Position::new(line, 1),
    }
}

fn lsp_line(line: u32) -> u32 {
    line.saturating_sub(1)
}

fn path_to_repo_string(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::UiHazard;

    fn annotation() -> UiLineAnnotation {
        UiLineAnnotation {
            line: 7,
            covered: true,
            is_partial: false,
            mutant_tested: true,
            test_types: vec!["unit".to_string()],
            distinct_tests: 2,
            mutant_verified_tests: 1,
            mutant_killed_tests: 1,
            stochastic_mutant_verified_tests: 1,
            invariant_mutant_verified_tests: 0,
            line_hits: Some(4),
            line_coverage: None,
            mutant_coverage: None,
            dark_arms: vec!["else".to_string()],
            dark_arm_spans: Vec::new(),
            effect_spans: Vec::new(),
            findings: Vec::new(),
            hazards: vec![UiHazard {
                hazard_type: "zig_loom_atomic".to_string(),
                required_evidence: "loom".to_string(),
                source: "atomic load".to_string(),
                evidence_present: false,
                verified: false,
            }],
            test_type_counts: std::collections::BTreeMap::new(),
            semantic_churn: 0.0,
            semantic_churn_events: 0,
            bug_weight: 0.0,
            bug_events: Vec::new(),
        }
    }

    #[test]
    fn diagnostics_include_unverified_hazards_and_dark_arms() {
        let diagnostics = diagnostics_for_annotations(&[annotation()]);
        assert_eq!(diagnostics.len(), 2);
        assert_eq!(diagnostics[0].range.start.line, 6);
        assert_eq!(diagnostics[0].severity, Some(DiagnosticSeverity::WARNING));
        assert!(diagnostics[0].message.contains("zig_loom_atomic"));
        assert_eq!(diagnostics[1].severity, Some(DiagnosticSeverity::HINT));
        assert!(diagnostics[1].message.contains("else"));
    }

    #[test]
    fn gutter_items_include_coverage_mutation_hazards_and_dark_arms() {
        let items = gutter_items_for_annotations(&[annotation()]);
        assert_eq!(items.len(), 4);
        assert!(items.iter().any(|item| item.kind == "covered"));
        assert!(items.iter().any(|item| item.kind == "mutant"));
        assert!(items.iter().any(|item| item.kind == "hazard_open"));
        assert!(items.iter().any(|item| item.kind == "dark_arm"));
        assert!(items.iter().all(|item| item.line == 6));
    }
}
