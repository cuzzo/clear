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

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiFile {
    pub path: String,
    pub units: i64,
    pub hazards: i64,
    pub distinct_tests: i64,
    pub mutant_killed_tests: i64,
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
    pub verified: bool,
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
    pub hazards: Vec<UiHazard>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct UiSourcePayload {
    pub path: String,
    pub commit: Option<String>,
    pub lines: Vec<String>,
    pub versions: Vec<UiVersion>,
    pub annotations: Vec<UiLineAnnotation>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct UiOverlays {
    dark_arms: HashMap<String, BTreeMap<u32, Vec<String>>>,
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
    hazards: Vec<UiHazard>,
}

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
        Ok(UiFile {
            path: row.get(0)?,
            units: row.get(1)?,
            hazards: row.get(2)?,
            distinct_tests: row.get(3)?,
            mutant_killed_tests: row.get(4)?,
            line_coverage: row.get(5)?,
            mutant_coverage: row.get(6)?,
        })
    })?;
    Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
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
    let repo = repo.as_ref();
    let file = read_source(repo, path, commit)?;
    Ok(UiSourcePayload {
        path: path.to_string(),
        commit: commit.map(str::to_string),
        lines: file.contents.lines().map(str::to_string).collect(),
        versions: file_versions(storage, path)?,
        annotations: line_annotations(storage, path, overlays)?,
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
            let storage = Storage::open(db)?;
            let selected = query.get("path").map(String::as_str);
            let commit = query
                .get("commit")
                .map(String::as_str)
                .filter(|value| !value.is_empty() && *value != "current");
            let filter = query.get("q").map(String::as_str).unwrap_or_default();
            let body = render_index_page(&storage, repo, overlays, selected, commit, filter)?;
            write_response(stream, 200, "text/html; charset=utf-8", &body)
        }
        "/api/files" => {
            let storage = Storage::open(db)?;
            let json = serde_json::to_string(&file_index(&storage)?)?;
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
            let storage = Storage::open(db)?;
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

fn line_annotations(
    storage: &Storage,
    path: &str,
    overlays: &UiOverlays,
) -> Result<Vec<UiLineAnnotation>> {
    let mut lines = BTreeMap::<u32, AnnotationBuilder>::new();
    let has_exact_line_coverage = apply_line_coverage(storage, path, &mut lines)?;
    apply_unit_quality(storage, path, &mut lines, !has_exact_line_coverage)?;
    apply_test_exposure(storage, path, &mut lines)?;
    apply_hazards(storage, path, &mut lines)?;
    apply_overlays(path, overlays, &mut lines);

    Ok(lines
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
            hazards: builder.hazards,
        })
        .collect())
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
        WITH latest AS (
          SELECT line, hits,
                 ROW_NUMBER() OVER (PARTITION BY line ORDER BY timestamp DESC, id DESC) AS rank
          FROM coverage_line_events
          WHERE path = ?1
        )
        SELECT line, hits
        FROM latest
        WHERE rank = 1
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
) -> Result<()> {
    let mut stmt = storage.connection().prepare(
        r#"
        SELECT line, test_type, COUNT(DISTINCT test_id),
               COUNT(DISTINCT CASE WHEN is_mutation_verified = 1 THEN test_id END),
               COUNT(DISTINCT CASE WHEN is_mutation_killed = 1 THEN test_id END)
        FROM test_exposure_events
        WHERE path = ?1 AND line IS NOT NULL AND is_verified = 1
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
        entry.covered = true;
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
        SELECT h.line, h.hazard_type, h.required_evidence, h.source,
               EXISTS(
                 SELECT 1
                 FROM test_exposure_events t
                 WHERE t.unit_id = h.unit_id
                   AND t.is_verified = 1
                   AND lower(t.test_type) = lower(h.required_evidence)
               ) AS verified
        FROM unit_hazards h
        WHERE h.path = ?1 AND h.is_active = 1
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
                verified: row.get::<_, i64>(4)? != 0,
            },
        ))
    })?;
    for row in rows {
        let (line, hazard) = row?;
        lines.entry(line).or_default().hazards.push(hazard);
    }
    Ok(())
}

fn apply_overlays(
    path: &str,
    overlays: &UiOverlays,
    lines: &mut BTreeMap<u32, AnnotationBuilder>,
) {
    if let Some(by_line) = overlays.dark_arms.get(path) {
        for (line, labels) in by_line {
            lines.entry(*line).or_default().dark_arms.extend(labels.clone());
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
                    .push(label);
            }
            for child in map.values() {
                collect_overlay_value(child, overlays);
            }
        }
        _ => {}
    }
}

fn overlay_label(value: &Value) -> Option<String> {
    let label = string_field(value, &["category", "kind", "rule_id", "ruleId", "message", "finding"])?;
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

fn string_field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn u32_field(value: &Value, keys: &[&str]) -> Option<u32> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_u64))
        .and_then(|number| u32::try_from(number).ok())
}

fn render_index_page(
    storage: &Storage,
    repo: &Path,
    overlays: &UiOverlays,
    selected: Option<&str>,
    commit: Option<&str>,
    filter: &str,
) -> Result<String> {
    let files = file_index(storage)?;
    let filtered = filtered_files(&files, filter);
    let path_available = |file: &&UiFile| commit.is_some() || repo.join(&file.path).is_file();
    let selected_path = selected
        .map(str::to_string)
        .or_else(|| {
            filtered
                .iter()
                .find(|file| file.line_coverage > 0.0 && path_available(file))
                .map(|file| file.path.clone())
        })
        .or_else(|| {
            filtered
                .iter()
                .find(|file| path_available(file))
                .map(|file| file.path.clone())
        })
        .or_else(|| filtered.first().map(|file| file.path.clone()));
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
    out.push_str(&format!("{} files", files.len()));
    out.push_str("</div></header>");
    out.push_str("<form class=\"toolbar\" method=\"get\" action=\"/\"><input name=\"q\" placeholder=\"Filter files\" value=\"");
    out.push_str(&html_escape(filter));
    out.push_str("\"><button type=\"submit\">Filter</button></form>");
    out.push_str("<nav class=\"files\">");
    for file in filtered {
        let active = selected_path.as_deref() == Some(file.path.as_str());
        out.push_str(&render_file_link(file, active, filter));
    }
    out.push_str("</nav></aside><main>");
    match payload {
        Ok(Some(payload)) => out.push_str(&render_source_view(&payload, filter)),
        Ok(None) => {
            out.push_str("<div class=\"topbar\"><div><div class=\"title\">No file selected</div>");
            out.push_str("<div class=\"subtle\">Build or ingest Lineage data first.</div></div></div>");
            out.push_str("<div class=\"viewer\"><div class=\"empty\">No source file selected.</div></div>");
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

fn render_source_view(payload: &UiSourcePayload, filter: &str) -> String {
    let annotations = payload
        .annotations
        .iter()
        .map(|annotation| (annotation.line, annotation))
        .collect::<BTreeMap<_, _>>();
    let covered = payload.annotations.iter().filter(|annotation| annotation.covered).count();
    let mutant = payload
        .annotations
        .iter()
        .filter(|annotation| annotation.mutant_tested)
        .count();
    let hazards: usize = payload.annotations.iter().map(|annotation| annotation.hazards.len()).sum();
    let dark_arms: usize = payload
        .annotations
        .iter()
        .map(|annotation| annotation.dark_arms.len())
        .sum();

    let mut out = String::new();
    out.push_str("<div class=\"topbar\"><div><div class=\"title\">");
    out.push_str(&html_escape(&payload.path));
    out.push_str("</div><div class=\"subtle\">");
    out.push_str(&format!(
        "{} covered lines | {} mutant lines | {} hazards | {} dark arms",
        covered, mutant, hazards, dark_arms
    ));
    out.push_str("</div></div>");
    out.push_str(&render_history(payload, filter));
    out.push_str("</div><div class=\"viewer\"><div class=\"code\">");
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
    if annotation.map(|a| !a.dark_arms.is_empty()).unwrap_or(false) {
        classes.push("dark-arm");
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

    let mut out = format!(
        "<div class=\"{}\"><span class=\"ln\">{}</span><span class=\"gutter\">",
        classes.join(" "),
        line_no
    );
    if let Some(annotation) = annotation {
        for hazard in &annotation.hazards {
            let mut title = format!(
                "{} requires {} {}",
                hazard.hazard_type,
                hazard.required_evidence,
                if hazard.verified { "coverage present" } else { "coverage missing" }
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
        if line_has_details(annotation) {
            out.push_str(&render_line_details(annotation));
        }
    }
    out.push_str("</span><pre>");
    out.push_str(&highlight_source_line(path, source));
    out.push_str("</pre></div>");
    out
}

fn render_line_details(annotation: &UiLineAnnotation) -> String {
    let mut rows = Vec::new();
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
    if !annotation.dark_arms.is_empty() {
        rows.push(format!("dark arms: {}", annotation.dark_arms.join(", ")));
    }
    if let Some(value) = annotation.line_coverage {
        rows.push(format!("unit line coverage {:.1}%", value));
    }
    if let Some(value) = annotation.mutant_coverage {
        rows.push(format!("unit mutant coverage {:.1}%", value));
    }
    let mut out = String::new();
    out.push_str("<details class=\"line-meta\"><summary title=\"line verification details\">i</summary><div>");
    for row in rows {
        out.push_str("<p>");
        out.push_str(&html_escape(&row));
        out.push_str("</p>");
    }
    out.push_str("</div></details>");
    out
}

fn line_has_details(annotation: &UiLineAnnotation) -> bool {
    annotation.covered
        || annotation.mutant_tested
        || !annotation.test_types.is_empty()
        || !annotation.dark_arms.is_empty()
        || annotation.line_hits.is_some()
        || annotation.line_coverage.is_some()
        || annotation.mutant_coverage.is_some()
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

fn highlight_source_line(path: &str, source: &str) -> String {
    let language = syntax_language(path);
    if language == SyntaxLanguage::Plain {
        return html_escape(source);
    }

    let mut out = String::new();
    let mut chars = source.char_indices().peekable();
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
            } else {
                out.push_str(&html_escape(word));
            }
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
  .subtle { color: var(--muted); font-size: 12px; }
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
  main { min-width: 0; min-height: 0; overflow: hidden; display: grid; grid-template-rows: auto minmax(0, 1fr); }
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
  .history {
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #fff;
    padding: 6px 8px;
  }
  .history summary { cursor: pointer; color: var(--muted); }
  .history-list { display: grid; gap: 4px; margin-top: 6px; max-height: 180px; overflow: auto; }
  .history-list a { color: var(--text); text-decoration: none; font-size: 12px; }
  .viewer { min-width: 0; min-height: 0; overflow: auto; background: #fbfcfd; }
  .code {
    min-width: max-content;
    padding: 10px 0 30px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
    line-height: 1.55;
  }
  .row {
    display: grid;
    grid-template-columns: 56px 52px minmax(760px, 1fr);
    min-height: 20px;
    border-left: 3px solid transparent;
  }
  .row.covered { background: var(--covered); }
  .row.mutant { background: var(--mutant); }
  .row.dark-arm { background: rgba(245, 158, 11, 0.10); }
  .row.hazard-open { border-left-color: var(--hazard); }
  .row.hazard-verified { border-left-color: #8b95a5; }
  .ln { color: #8b95a5; text-align: right; padding-right: 10px; user-select: none; }
  .gutter { min-width: 52px; text-align: center; user-select: none; }
  .bomb {
    cursor: help;
    display: inline-block;
    font-size: 13px;
    line-height: 18px;
    margin-right: 2px;
  }
  .bomb.verified { opacity: 0.35; filter: grayscale(1); }
  .line-meta { display: inline-block; position: relative; }
  .line-meta summary {
    cursor: pointer;
    color: var(--muted);
    display: inline;
    font-size: 11px;
  }
  .line-meta div {
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
  .line-meta p { margin: 0 0 4px; }
  pre { margin: 0; white-space: pre; padding-right: 24px; }
  .tok-comment { color: #7a8495; font-style: italic; }
  .tok-string { color: #8a4b08; }
  .tok-number { color: #0f766e; }
  .tok-keyword { color: #1d4ed8; font-weight: 600; }
  .empty { padding: 24px; color: var(--muted); }
  @media (max-width: 800px) {
    .app { grid-template-columns: 1fr; grid-template-rows: 36vh 64vh; }
    aside { border-right: 0; border-bottom: 1px solid var(--line); }
    .topbar { grid-template-columns: 1fr; }
    .row { grid-template-columns: 48px 48px minmax(620px, 1fr); }
  }
"#;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        CommitMetadata, Event, EventType, HazardEvent, LogicalUnit, TestExposureEvent, UnitKind,
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
    fn syntax_highlighter_marks_basic_tokens() {
        let html = highlight_source_line("src/demo.rb", "def run # hello");

        assert!(html.contains("<span class=\"tok-keyword\">def</span>"));
        assert!(html.contains("<span class=\"tok-comment\"># hello</span>"));
    }
}
