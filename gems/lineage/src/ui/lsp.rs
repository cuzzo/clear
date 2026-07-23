use crate::storage::Storage;
use crate::ui::{line_annotations, UiLineAnnotation, UiOverlays};
use anyhow::Result;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tower_lsp::jsonrpc::Result as LspResult;
use tower_lsp::lsp_types::notification::Notification;
use tower_lsp::lsp_types::{
    CodeLens, CodeLensOptions, CodeLensParams, Command, Diagnostic, DiagnosticSeverity,
    DidChangeTextDocumentParams, DidCloseTextDocumentParams, DidOpenTextDocumentParams,
    DidSaveTextDocumentParams, GotoDefinitionParams, GotoDefinitionResponse, Hover, HoverContents,
    HoverParams, InitializeParams, InitializeResult, InitializedParams, Location, MarkupContent,
    MarkupKind, MessageType, OneOf, Position, Range, ServerCapabilities,
    TextDocumentSyncCapability, TextDocumentSyncKind, Url,
};
use tower_lsp::{Client, LanguageServer, LspService, Server};

#[derive(Clone)]
struct LineageLsp {
    client: Client,
    db: PathBuf,
    repo: PathBuf,
    overlays: UiOverlays,
    /// Full text of currently open documents (FULL sync), keyed by URI.
    /// Needed to resolve the identifier under the cursor for go-to-definition
    /// - the LSP protocol only gives a position, not a word.
    documents: Arc<Mutex<HashMap<Url, String>>>,
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
    hotness_tier: Option<String>,
    hotness_share: f64,
    hotness_source: Option<String>,
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
        documents: Arc::new(Mutex::new(HashMap::new())),
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
                definition_provider: Some(OneOf::Left(true)),
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
        self.store_document(params.text_document.uri.clone(), params.text_document.text);
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        // FULL sync (advertised in `initialize`) sends exactly one change
        // event per notification carrying the entire document text.
        if let Some(change) = params.content_changes.into_iter().last() {
            self.store_document(params.text_document.uri.clone(), change.text);
        }
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_save(&self, params: DidSaveTextDocumentParams) {
        self.publish_document(params.text_document.uri).await;
    }

    async fn did_close(&self, params: DidCloseTextDocumentParams) {
        if let Ok(mut documents) = self.documents.lock() {
            documents.remove(&params.text_document.uri);
        }
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
                self.log_error(format!("lineage hover failed: {error:#}"))
                    .await;
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

    async fn goto_definition(
        &self,
        params: GotoDefinitionParams,
    ) -> LspResult<Option<GotoDefinitionResponse>> {
        let uri = params.text_document_position_params.text_document.uri;
        let position = params.text_document_position_params.position;
        let Some(word) = self.word_at_position(&uri, position) else {
            return Ok(None);
        };
        let current_path = match self.repo_path_for_uri(&uri) {
            Ok(Some(path)) => path,
            Ok(None) => return Ok(None),
            Err(error) => {
                self.log_error(format!("lineage definition failed: {error:#}"))
                    .await;
                return Ok(None);
            }
        };
        let storage = match Storage::open_existing(&self.db) {
            Ok(storage) => storage,
            Err(error) => {
                self.log_error(format!("lineage definition failed: {error:#}"))
                    .await;
                return Ok(None);
            }
        };
        let definitions = match storage.find_definitions(&word, None, Some(&current_path)) {
            Ok(definitions) => definitions,
            Err(error) => {
                self.log_error(format!("lineage definition failed: {error:#}"))
                    .await;
                return Ok(None);
            }
        };
        let locations: Vec<Location> = definitions
            .into_iter()
            .filter_map(|(path, line)| {
                self.uri_for_repo_path(&path).map(|uri| Location {
                    uri,
                    range: range_for_line(line),
                })
            })
            .collect();
        if locations.is_empty() {
            Ok(None)
        } else {
            Ok(Some(GotoDefinitionResponse::Array(locations)))
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
        let mut units = file_units(&storage, &path)?;
        apply_unit_hotness(&mut units, &annotations);
        Ok(Some(FileFacts {
            path,
            annotations,
            units,
        }))
    }

    fn store_document(&self, uri: Url, text: String) {
        if let Ok(mut documents) = self.documents.lock() {
            documents.insert(uri, text);
        }
    }

    /// The identifier under the cursor, from the tracked open-document text
    /// (falling back to disk if the document was never opened over LSP).
    fn word_at_position(&self, uri: &Url, position: Position) -> Option<String> {
        let tracked = self
            .documents
            .lock()
            .ok()
            .and_then(|documents| documents.get(uri).cloned());
        let text = tracked.or_else(|| {
            uri.to_file_path()
                .ok()
                .and_then(|path| std::fs::read_to_string(path).ok())
        })?;
        let line = text.lines().nth(position.line as usize)?;
        word_at_column(line, position.character as usize)
    }

    fn uri_for_repo_path(&self, path: &str) -> Option<Url> {
        let repo = self
            .repo
            .canonicalize()
            .unwrap_or_else(|_| self.repo.clone());
        Url::from_file_path(repo.join(path)).ok()
    }

    fn repo_path_for_uri(&self, uri: &Url) -> Result<Option<String>> {
        let file_path = uri
            .to_file_path()
            .map_err(|_| anyhow::anyhow!("unsupported non-file URI {uri}"))?;
        let repo = self
            .repo
            .canonicalize()
            .unwrap_or_else(|_| self.repo.clone());
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
    // A unit's creating commit records no `events` row (only later
    // changes/moves/fixes do), so `le.*` is NULL until then. Fall back to
    // `logical_units.start_line`, which the engine always sets at creation.
    // There is no persisted `end_line` on logical_units, so a pre-first-event
    // unit still degrades to a single-line range - narrow but correctly
    // positioned, rather than the previous unconditional line-1 default.
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
               COALESCE(le.start_line, u.start_line, 1),
               COALESCE(le.end_line, le.start_line, u.start_line, 1),
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
        GROUP BY u.id, u.name, u.type, le.start_line, le.end_line, u.start_line,
                 u.current_distinct_tests, u.current_test_types,
                 u.current_mutant_verified_tests, u.current_mutant_killed_tests
        ORDER BY COALESCE(le.start_line, u.start_line, 1), u.name
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
            hotness_tier: None,
            hotness_share: 0.0,
            hotness_source: None,
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
}

/// Roll line-level hotness up to each unit: the tier/share of whichever
/// annotated line within the unit's range has the highest cumulative share.
/// Mirrors the symbol-level rollup the HTML UI uses for its flame icon
/// (`apply_symbol_hotspots` in `src/ui/ui.rs`), so the LSP's notion of
/// "critical" matches the UI's exactly.
fn apply_unit_hotness(units: &mut [LspUnit], annotations: &[UiLineAnnotation]) {
    for unit in units.iter_mut() {
        let hottest = annotations
            .iter()
            .filter(|annotation| {
                annotation.line >= unit.start_line
                    && annotation.line <= unit.end_line
                    && annotation.hotness_tier.is_some()
            })
            .max_by(|left, right| {
                left.hotness_share
                    .partial_cmp(&right.hotness_share)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        if let Some(hottest) = hottest {
            unit.hotness_tier = hottest.hotness_tier.clone();
            unit.hotness_share = hottest.hotness_share;
            unit.hotness_source = hottest.hotness_source.clone();
        }
    }
}

/// The identifier (`[A-Za-z0-9_]+`) touching the given zero-based column.
/// If the column sits just past the end of a word (the common case when an
/// editor reports the cursor after the last character typed), resolves to
/// that word rather than nothing.
fn word_at_column(line: &str, column: usize) -> Option<String> {
    let chars: Vec<char> = line.chars().collect();
    if chars.is_empty() {
        return None;
    }
    let is_word_char = |c: char| c.is_alphanumeric() || c == '_';
    let column = column.min(chars.len());
    let anchor = if column < chars.len() && is_word_char(chars[column]) {
        column
    } else if column > 0 && is_word_char(chars[column - 1]) {
        column - 1
    } else {
        return None;
    };
    let mut start = anchor;
    while start > 0 && is_word_char(chars[start - 1]) {
        start -= 1;
    }
    let mut end = anchor + 1;
    while end < chars.len() && is_word_char(chars[end]) {
        end += 1;
    }
    Some(chars[start..end].iter().collect())
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
        if annotation.hotness_tier.as_deref() == Some("critical") {
            items.push(GutterItem {
                line: lsp_line(annotation.line),
                kind: "hotness_critical".to_string(),
                label: "critical hotpath".to_string(),
                verified: true,
                message: format!(
                    "critical: {:.1}% of runtime profile ({})",
                    annotation.hotness_share * 100.0,
                    annotation.hotness_source.as_deref().unwrap_or("profile")
                ),
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
    let annotation = facts
        .annotations
        .iter()
        .find(|annotation| annotation.line == line);
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
            lines.push(format!(
                "Reopened crash frames after fix: {}",
                unit.reopened_count
            ));
        }
        if unit.hotness_tier.as_deref() == Some("critical") {
            lines.push(format!(
                "Critical hotpath: {:.1}% of runtime profile",
                unit.hotness_share * 100.0
            ));
        }
    }
    if let Some(annotation) = annotation {
        if let Some(hits) = annotation.line_hits {
            lines.push(format!("Line hits: {hits}"));
        }
        if let Some(tier) = &annotation.hotness_tier {
            lines.push(format!(
                "Runtime profile: {} - {:.1}% cumulative ({})",
                tier,
                annotation.hotness_share * 100.0,
                annotation.hotness_source.as_deref().unwrap_or("profile")
            ));
        }
        if !annotation.test_types.is_empty() {
            lines.push(format!(
                "Line test types: {}",
                annotation.test_types.join(", ")
            ));
        }
        for hazard in &annotation.hazards {
            lines.push(format!(
                "Hazard: {} requires {} ({})",
                hazard.hazard_type,
                hazard.required_evidence,
                if hazard.verified {
                    "verified"
                } else {
                    "missing"
                }
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
        .map(|unit| {
            let mut title = format!(
                "Lineage: risk {:.1} | fixes {} | tests {} | mutant {}/{} | stale {} | reopened {}",
                unit.risk_score,
                unit.fixes,
                unit.current_distinct_tests,
                unit.current_mutant_killed_tests,
                unit.current_mutant_verified_tests,
                unit.semantic_changes_after_mutant_run,
                unit.reopened_count
            );
            if unit.hotness_tier.as_deref() == Some("critical") {
                title.push_str(&format!(
                    " | critical hotpath {:.1}%",
                    unit.hotness_share * 100.0
                ));
            }
            CodeLens {
                range: range_for_line(unit.start_line),
                command: Some(Command {
                    title,
                    command: "lineage.showUnit".to_string(),
                    arguments: Some(vec![serde_json::json!({
                        "path": facts.path,
                        "unit_id": unit.id,
                        "name": unit.name,
                        "kind": unit.kind,
                    })]),
                }),
                data: None,
            }
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
            hotness_tier: None,
            hotness_share: 0.0,
            hotness_source: None,
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

    #[test]
    fn gutter_items_emit_a_critical_hotness_marker() {
        let mut hot = annotation();
        hot.hotness_tier = Some("critical".to_string());
        hot.hotness_share = 0.62;
        hot.hotness_source = Some("pprof:cpu".to_string());

        let items = gutter_items_for_annotations(&[hot]);
        let hotness = items
            .iter()
            .find(|item| item.kind == "hotness_critical")
            .expect("critical hotness gutter item");
        assert!(hotness.verified);
        assert!(hotness.message.contains("62.0%"));
        assert!(hotness.message.contains("pprof:cpu"));

        // Warm/cold tiers are not flame-worthy - no gutter item for them.
        let mut warm = annotation();
        warm.hotness_tier = Some("warm".to_string());
        let warm_items = gutter_items_for_annotations(&[warm]);
        assert!(!warm_items
            .iter()
            .any(|item| item.kind == "hotness_critical"));
    }

    fn unit_fixture() -> LspUnit {
        LspUnit {
            id: "unit-1".to_string(),
            name: "process_order".to_string(),
            kind: "function".to_string(),
            start_line: 5,
            end_line: 20,
            total_events: 3,
            changes: 2,
            fixes: 1,
            risk_score: 4.2,
            current_distinct_tests: 3,
            current_test_types: "unit".to_string(),
            current_mutant_verified_tests: 2,
            current_mutant_killed_tests: 1,
            semantic_changes_after_mutant_run: 0,
            verification_staleness_score: 0.0,
            reopened_count: 0,
            hotness_tier: None,
            hotness_share: 0.0,
            hotness_source: None,
        }
    }

    fn file_facts_fixture(units: Vec<LspUnit>, annotations: Vec<UiLineAnnotation>) -> FileFacts {
        FileFacts {
            path: "src/orders.rb".to_string(),
            annotations,
            units,
        }
    }

    #[test]
    fn apply_unit_hotness_picks_the_highest_share_within_range_and_ignores_untiered_lines() {
        let mut units = vec![unit_fixture()]; // start_line 5, end_line 20

        let mut low = annotation();
        low.line = 6;
        low.hotness_tier = Some("warm".to_string());
        low.hotness_share = 0.02;

        let mut high = annotation();
        high.line = 10;
        high.hotness_tier = Some("critical".to_string());
        high.hotness_share = 0.55;
        high.hotness_source = Some("perf:zig".to_string());

        let mut untiered = annotation();
        untiered.line = 12;
        untiered.hotness_tier = None;
        untiered.hotness_share = 0.99; // no tier: must be ignored despite the high share

        let mut outside_range = annotation();
        outside_range.line = 25; // past unit.end_line = 20
        outside_range.hotness_tier = Some("critical".to_string());
        outside_range.hotness_share = 0.9;

        apply_unit_hotness(&mut units, &[low, high, untiered, outside_range]);

        assert_eq!(units[0].hotness_tier.as_deref(), Some("critical"));
        assert!((units[0].hotness_share - 0.55).abs() < 1e-9);
        assert_eq!(units[0].hotness_source.as_deref(), Some("perf:zig"));
    }

    #[test]
    fn hover_for_line_surfaces_unit_and_line_hotness() {
        let mut unit = unit_fixture();
        unit.hotness_tier = Some("critical".to_string());
        unit.hotness_share = 0.62;

        let mut line_annotation = annotation();
        line_annotation.line = 7;
        line_annotation.hotness_tier = Some("critical".to_string());
        line_annotation.hotness_share = 0.62;
        line_annotation.hotness_source = Some("pprof:cpu".to_string());

        let facts = file_facts_fixture(vec![unit], vec![line_annotation]);
        let hover = hover_for_line(&facts, 7).expect("hover for an annotated, hot line");
        let HoverContents::Markup(markup) = hover.contents else {
            panic!("expected markdown hover contents");
        };
        assert!(
            markup
                .value
                .contains("Critical hotpath: 62.0% of runtime profile"),
            "hover was: {}",
            markup.value
        );
        assert!(
            markup
                .value
                .contains("Runtime profile: critical - 62.0% cumulative (pprof:cpu)"),
            "hover was: {}",
            markup.value
        );
    }

    #[test]
    fn code_lens_title_includes_critical_hotpath_suffix_only_when_critical() {
        let mut hot_unit = unit_fixture();
        hot_unit.hotness_tier = Some("critical".to_string());
        hot_unit.hotness_share = 0.735;
        let hot_facts = file_facts_fixture(vec![hot_unit], Vec::new());
        let hot_lenses = code_lenses_for_units(&hot_facts);
        let hot_title = hot_lenses[0].command.as_ref().unwrap().title.clone();
        assert!(
            hot_title.contains("critical hotpath 73.5%"),
            "title was: {hot_title}"
        );

        let cold_facts = file_facts_fixture(vec![unit_fixture()], Vec::new());
        let cold_lenses = code_lenses_for_units(&cold_facts);
        let cold_title = cold_lenses[0].command.as_ref().unwrap().title.clone();
        assert!(!cold_title.contains("hotpath"), "title was: {cold_title}");
    }

    #[test]
    fn word_at_column_extracts_identifier_touching_cursor() {
        assert_eq!(
            word_at_column("def process_order(order)", 8),
            Some("process_order".to_string())
        );
    }

    #[test]
    fn word_at_column_resolves_cursor_immediately_after_word() {
        // Editors commonly report the cursor position just past the last
        // character of the word the user is standing on.
        let line = "order";
        assert_eq!(word_at_column(line, line.len()), Some("order".to_string()));
    }

    #[test]
    fn word_at_column_returns_none_on_whitespace_between_words() {
        assert_eq!(word_at_column("foo   bar", 4), None);
    }

    #[test]
    fn word_at_column_returns_none_for_empty_line() {
        assert_eq!(word_at_column("", 0), None);
    }

    #[test]
    fn word_at_column_matches_snake_case_identifiers_with_digits() {
        assert_eq!(
            word_at_column("let helper_2x = compute();", 6),
            Some("helper_2x".to_string())
        );
    }

    #[test]
    fn file_units_falls_back_to_logical_units_start_line_when_no_event_exists_yet() {
        // A unit's very first commit only calls upsert_logical_unit - no
        // `events` row exists until a later commit changes/moves/fixes it.
        // file_units must not silently collapse such units to line 1.
        use crate::model::{LogicalUnit, UnitKind};

        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/worker.rb",
            1,
            7,
            9,
            "def run",
            "def run\n  1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();

        let units = file_units(&storage, "src/worker.rb").unwrap();
        assert_eq!(units.len(), 1);
        assert_eq!(
            units[0].start_line, 7,
            "must fall back to logical_units.start_line, not 1"
        );
        // logical_units has no end_line column (only start_line survives the
        // upsert), so pre-first-event units degrade to a single-line range
        // rather than the true 7..=9 extent. Still strictly better than the
        // previous 1..=1: the position is now correct, only the span is
        // narrow. Fixing this fully needs an end_line column on
        // logical_units - out of scope here, tracked as a known gap.
        assert_eq!(units[0].end_line, 7);
    }
}
