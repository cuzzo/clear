//! Language-neutral language-server-backed SCIP production.
//!
//! Language adapters supply only their language ID, SCIP coordinate, external
//! symbol descriptor, and proof of standard-library ownership. Transport,
//! range conversion, occurrence construction, and project declaration joins
//! stay shared.

use crate::profile::{self, CallRecord, MethodRecord, Profile};
use crate::syntax::{self, Language};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct GenerationStats {
    pub calls: usize,
    pub semantic_occurrences: usize,
    pub project_definitions: usize,
    pub external_definitions: usize,
    pub unresolved_calls: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneratedIndex {
    pub json: String,
    pub stats: GenerationStats,
}

pub trait LspScipAdapter {
    fn language(&self) -> Language;
    fn language_id(&self) -> &'static str;
    fn scheme(&self) -> &'static str;
    fn package_manager(&self) -> &'static str;
    fn is_stdlib_definition(&self, path: &Path) -> bool;
    fn external_descriptor(
        &self,
        call: &CallRecord,
        definition_path: &Path,
        definition_source: &str,
        definition_range: [usize; 4],
    ) -> String;
    fn stdlib_package(&self) -> &'static str;
    fn workspace_settings(&self) -> Value {
        Value::Null
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PositionEncoding {
    Utf8,
    Utf16,
    Utf32,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
struct ScipOccurrence {
    range: Vec<usize>,
    symbol: String,
    #[serde(rename = "symbolRoles")]
    symbol_roles: u32,
}

#[derive(Serialize)]
struct ScipDocument {
    language: &'static str,
    #[serde(rename = "relativePath")]
    relative_path: String,
    occurrences: Vec<ScipOccurrence>,
    symbols: Vec<Value>,
}

#[derive(Clone, Debug)]
struct Location {
    uri: String,
    range: [usize; 4],
}

struct LspClient {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
    root_uri: String,
    encoding: PositionEncoding,
}

impl LspClient {
    fn start(server: &Path, root: &Path, workspace_settings: Value) -> Result<Self> {
        let mut child = Command::new(server)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("failed to start language server {}", server.display()))?;
        let input = child
            .stdin
            .take()
            .context("language server did not expose stdin")?;
        let output = BufReader::new(
            child
                .stdout
                .take()
                .context("language server did not expose stdout")?,
        );
        let root_uri = path_to_file_uri(root);
        let mut client = Self {
            child,
            input,
            output,
            next_id: 1,
            root_uri: root_uri.clone(),
            encoding: PositionEncoding::Utf16,
        };
        let response = client.request(
            "initialize",
            json!({
                "processId": std::process::id(),
                "rootUri": root_uri,
                "workspaceFolders": [{"uri": client.root_uri, "name": root.file_name().and_then(|value| value.to_str()).unwrap_or("workspace")}],
                "capabilities": {
                    "general": {"positionEncodings": ["utf-8", "utf-16"]},
                    "offsetEncoding": ["utf-8", "utf-16"],
                    "textDocument": {"definition": {"dynamicRegistration": false}},
                    "workspace": {"configuration": false, "workspaceFolders": true}
                },
                "clientInfo": {"name": "fact-mine-lsp-scip", "version": env!("CARGO_PKG_VERSION")}
            }),
        )?;
        client.encoding = response
            .pointer("/capabilities/positionEncoding")
            .and_then(Value::as_str)
            .map(position_encoding)
            .unwrap_or(PositionEncoding::Utf16);
        client.notify("initialized", json!({}))?;
        client.notify(
            "workspace/didChangeConfiguration",
            json!({"settings": workspace_settings}),
        )?;
        Ok(client)
    }

    fn open(&mut self, path: &Path, text: &str, language_id: &str) -> Result<()> {
        self.notify(
            "textDocument/didOpen",
            json!({"textDocument": {
                "uri": path_to_file_uri(path),
                "languageId": language_id,
                "version": 1,
                "text": text
            }}),
        )
    }

    fn definitions(
        &mut self,
        path: &Path,
        line: usize,
        byte_column: usize,
        source: &str,
    ) -> Result<Vec<Location>> {
        let character = byte_to_lsp_column(source, line, byte_column, self.encoding);
        let response = self.request(
            "textDocument/definition",
            json!({
                "textDocument": {"uri": path_to_file_uri(path)},
                "position": {"line": line, "character": character}
            }),
        )?;
        Ok(parse_locations(&response))
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))?;
        loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_u64) == Some(id) {
                if let Some(error) = message.get("error") {
                    bail!("language server {method} failed: {error}");
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
            if message.get("method").is_some() && message.get("id").is_some() {
                self.answer_server_request(&message)?;
            }
        }
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        self.send(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
    }

    fn answer_server_request(&mut self, message: &Value) -> Result<()> {
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        let method = message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let result = match method {
            "workspace/workspaceFolders" => json!([{"uri": self.root_uri, "name": "workspace"}]),
            "workspace/configuration" => {
                let count = message
                    .pointer("/params/items")
                    .and_then(Value::as_array)
                    .map(Vec::len)
                    .unwrap_or(0);
                Value::Array((0..count).map(|_| Value::Null).collect())
            }
            "workspace/applyEdit" => json!({"applied": false}),
            _ => Value::Null,
        };
        self.send(&json!({"jsonrpc": "2.0", "id": id, "result": result}))
    }

    fn send(&mut self, message: &Value) -> Result<()> {
        let body = serde_json::to_vec(message)?;
        write!(self.input, "Content-Length: {}\r\n\r\n", body.len())?;
        self.input.write_all(&body)?;
        self.input.flush()?;
        Ok(())
    }

    fn read_message(&mut self) -> Result<Value> {
        let mut length = None;
        loop {
            let mut header = String::new();
            let read = self.output.read_line(&mut header)?;
            if read == 0 {
                bail!("language server closed stdout before completing a response");
            }
            if header == "\r\n" || header == "\n" {
                break;
            }
            if let Some(value) = header.strip_prefix("Content-Length:") {
                length = Some(value.trim().parse::<usize>()?);
            }
        }
        let length = length.context("language-server response omitted Content-Length")?;
        let mut body = vec![0; length];
        self.output.read_exact(&mut body)?;
        serde_json::from_slice(&body).context("language server returned invalid JSON-RPC")
    }
}

impl Drop for LspClient {
    fn drop(&mut self) {
        let id = self.next_id;
        let _ =
            self.send(&json!({"jsonrpc": "2.0", "id": id, "method": "shutdown", "params": null}));
        let _ = self.notify("exit", Value::Null);
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn generate(
    files: &[PathBuf],
    root: Option<&Path>,
    server: &Path,
    adapter: &dyn LspScipAdapter,
) -> Result<GeneratedIndex> {
    let files = canonical_files(files, adapter.language())?;
    let root = root
        .map(fs::canonicalize)
        .transpose()
        .context("failed to canonicalize SCIP root")?
        .unwrap_or_else(|| common_root(&files));
    if files.iter().any(|file| !file.starts_with(&root)) {
        bail!("every SCIP input must be inside root {}", root.display());
    }
    let outputs = files
        .iter()
        .map(|file| {
            let document = syntax::parse_file(file.clone(), adapter.language())?;
            Ok(profile::extract(&document, Profile::Espalier))
        })
        .collect::<Result<Vec<_>>>()?;
    let profile = profile::merge(outputs, Profile::Espalier);
    let file_set = files.iter().cloned().collect::<BTreeSet<_>>();
    let source_by_path = files
        .iter()
        .map(|path| Ok((path.clone(), fs::read_to_string(path)?)))
        .collect::<Result<BTreeMap<_, _>>>()?;
    let mut client = LspClient::start(server, &root, adapter.workspace_settings())?;
    for (path, source) in &source_by_path {
        client.open(path, source, adapter.language_id())?;
    }

    let project_package = scip_atom(
        root.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("workspace"),
    );
    let mut documents = files
        .iter()
        .map(|path| {
            (
                relative_path(&root, path),
                BTreeSet::<ScipOccurrence>::new(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut target_sources = source_by_path.clone();
    let mut stats = GenerationStats {
        calls: profile.calls.len(),
        ..GenerationStats::default()
    };

    for call in &profile.calls {
        let Some(path) = canonical_call_path(call) else {
            stats.unresolved_calls += 1;
            continue;
        };
        let Some(source) = source_by_path.get(&path) else {
            stats.unresolved_calls += 1;
            continue;
        };
        let Some(callee) = callee_range(call, source) else {
            stats.unresolved_calls += 1;
            continue;
        };
        let locations = client.definitions(&path, callee[0], callee[1], source)?;
        if locations.is_empty() {
            stats.unresolved_calls += 1;
            continue;
        }
        let caller_document = relative_path(&root, &path);
        let mut emitted = false;
        for location in locations {
            let Some(target_path) =
                file_uri_to_path(&location.uri).and_then(|path| fs::canonicalize(path).ok())
            else {
                continue;
            };
            let target_source = if let Some(source) = target_sources.get(&target_path) {
                source.clone()
            } else {
                let Ok(source) = fs::read_to_string(&target_path) else {
                    continue;
                };
                target_sources.insert(target_path.clone(), source.clone());
                source
            };
            let target_range = lsp_range_to_utf8(&target_source, location.range, client.encoding);
            let project_method = file_set
                .contains(&target_path)
                .then(|| {
                    project_method_at(&profile.methods, &target_path, target_range, &target_source)
                })
                .flatten();
            let (symbol, definition) = if let Some(method) = project_method {
                let target_document = relative_path(&root, &target_path);
                let descriptor =
                    project_descriptor(&target_document, target_range, &method.dispatch_name);
                (
                    format!(
                        "{} {} {project_package} workspace {descriptor}",
                        adapter.scheme(),
                        adapter.package_manager()
                    ),
                    Some((target_document, target_range)),
                )
            } else if file_set.contains(&target_path) {
                // A definition inside an analyzed file that is not an emitted
                // callable is commonly a table slot or local value. Mapping it
                // to its enclosing function would be unsound.
                continue;
            } else {
                let package = if adapter.is_stdlib_definition(&target_path) {
                    adapter.stdlib_package()
                } else {
                    "dependency"
                };
                let descriptor =
                    adapter.external_descriptor(call, &target_path, &target_source, target_range);
                (
                    format!(
                        "{} {} {package} . {descriptor}",
                        adapter.scheme(),
                        adapter.package_manager()
                    ),
                    None,
                )
            };
            documents
                .entry(caller_document.clone())
                .or_default()
                .insert(ScipOccurrence {
                    range: compact_range(callee),
                    symbol: symbol.clone(),
                    symbol_roles: 0,
                });
            if let Some((target_document, definition_range)) = definition {
                documents
                    .entry(target_document)
                    .or_default()
                    .insert(ScipOccurrence {
                        range: compact_range(definition_range),
                        symbol,
                        symbol_roles: 1,
                    });
                stats.project_definitions += 1;
            } else {
                stats.external_definitions += 1;
            }
            stats.semantic_occurrences += 1;
            emitted = true;
        }
        if !emitted {
            stats.unresolved_calls += 1;
        }
    }

    let index = json!({
        "metadata": {
            "version": 0,
            "toolInfo": {"name": "fact-mine-lsp-scip", "version": env!("CARGO_PKG_VERSION")},
            "projectRoot": path_to_file_uri(&root),
            "textDocumentEncoding": 1
        },
        "documents": documents.into_iter().map(|(relative_path, occurrences)| ScipDocument {
            language: adapter.language_id(),
            relative_path,
            occurrences: occurrences.into_iter().collect(),
            symbols: Vec::new(),
        }).collect::<Vec<_>>(),
        "externalSymbols": []
    });
    Ok(GeneratedIndex {
        json: serde_json::to_string_pretty(&index)?,
        stats,
    })
}

fn canonical_files(files: &[PathBuf], language: Language) -> Result<Vec<PathBuf>> {
    files
        .iter()
        .map(|file| {
            if Language::for_path(file) != Some(language) {
                bail!(
                    "SCIP input does not match {}: {}",
                    language.as_str(),
                    file.display()
                );
            }
            fs::canonicalize(file)
                .with_context(|| format!("failed to canonicalize {}", file.display()))
        })
        .collect()
}

fn common_root(files: &[PathBuf]) -> PathBuf {
    let mut root = files
        .first()
        .and_then(|path| path.parent())
        .unwrap_or(Path::new("."))
        .to_path_buf();
    for file in files.iter().skip(1) {
        while !file.starts_with(&root) && root.pop() {}
    }
    root
}

fn relative_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn canonical_call_path(call: &CallRecord) -> Option<PathBuf> {
    fs::canonicalize(&call.path).ok()
}

fn project_method_at<'a>(
    methods: &'a [MethodRecord],
    path: &Path,
    range: [usize; 4],
    source: &str,
) -> Option<&'a MethodRecord> {
    let one_based = [range[0] + 1, range[1], range[2] + 1, range[3]];
    let declaration = text_at_range(source, range);
    methods
        .iter()
        .filter(|method| {
            Path::new(&method.path) == path
                && method.span.is_some_and(|span| contains(span, one_based))
                && (declaration == method.name || declaration == method.dispatch_name)
        })
        .min_by_key(|method| method.span.map(span_size).unwrap_or(usize::MAX))
}

fn contains(outer: [usize; 4], inner: [usize; 4]) -> bool {
    (outer[0], outer[1]) <= (inner[0], inner[1]) && (inner[2], inner[3]) <= (outer[2], outer[3])
}

fn span_size(span: [usize; 4]) -> usize {
    span[2].saturating_sub(span[0]) * 1_000_000 + span[3].saturating_sub(span[1])
}

fn project_descriptor(document: &str, range: [usize; 4], name: &str) -> String {
    format!(
        "{}/L{}C{}/{}().",
        scip_path(document),
        range[0],
        range[1],
        scip_atom(name)
    )
}

pub(crate) fn scip_atom(value: &str) -> String {
    let value = value.trim().trim_matches('`');
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
    {
        value.to_string()
    } else {
        format!("`{}`", value.replace('`', "_"))
    }
}

pub(crate) fn scip_path(value: &str) -> String {
    value
        .split(['/', '\\', '.', ':'])
        .filter(|part| !part.is_empty())
        .map(scip_atom)
        .collect::<Vec<_>>()
        .join("/")
}

fn callee_range(call: &CallRecord, source: &str) -> Option<[usize; 4]> {
    let message = call
        .message
        .rsplit(['.', ':'])
        .next()
        .unwrap_or(&call.message);
    if message.is_empty() {
        return None;
    }
    let lines = source.split('\n').collect::<Vec<_>>();
    let first_line = call.span[0].saturating_sub(1);
    let last_line = call.span[2]
        .saturating_sub(1)
        .min(lines.len().saturating_sub(1));
    for line_index in first_line..=last_line {
        let line = *lines.get(line_index)?;
        let start = if line_index == first_line {
            call.span[1].min(line.len())
        } else {
            0
        };
        let end = if line_index == last_line {
            call.span[3].min(line.len())
        } else {
            line.len()
        };
        if start > end || !line.is_char_boundary(start) || !line.is_char_boundary(end) {
            continue;
        }
        for (offset, _) in line[start..end].match_indices(message) {
            let column = start + offset;
            let before = line[..column].chars().next_back();
            let after = line[column + message.len()..].chars().next();
            if before.is_some_and(identifier_character) || after.is_some_and(identifier_character) {
                continue;
            }
            return Some([line_index, column, line_index, column + message.len()]);
        }
    }
    None
}

fn identifier_character(character: char) -> bool {
    character == '_' || character.is_alphanumeric()
}

fn position_encoding(value: &str) -> PositionEncoding {
    match value.to_ascii_lowercase().as_str() {
        "utf-8" | "utf8" => PositionEncoding::Utf8,
        "utf-32" | "utf32" => PositionEncoding::Utf32,
        _ => PositionEncoding::Utf16,
    }
}

fn byte_to_lsp_column(
    source: &str,
    line: usize,
    byte_column: usize,
    encoding: PositionEncoding,
) -> usize {
    let text = source.split('\n').nth(line).unwrap_or_default();
    let column = byte_column.min(text.len());
    let prefix = text.get(..column).unwrap_or_default();
    match encoding {
        PositionEncoding::Utf8 => prefix.len(),
        PositionEncoding::Utf16 => prefix.encode_utf16().count(),
        PositionEncoding::Utf32 => prefix.chars().count(),
    }
}

fn lsp_to_byte_column(
    source: &str,
    line: usize,
    column: usize,
    encoding: PositionEncoding,
) -> usize {
    let text = source.split('\n').nth(line).unwrap_or_default();
    match encoding {
        PositionEncoding::Utf8 => column.min(text.len()),
        PositionEncoding::Utf16 => units_to_byte(text, column, |character| character.len_utf16()),
        PositionEncoding::Utf32 => units_to_byte(text, column, |_| 1),
    }
}

fn units_to_byte(text: &str, units: usize, width: impl Fn(char) -> usize) -> usize {
    let mut consumed = 0;
    for (offset, character) in text.char_indices() {
        if consumed >= units {
            return offset;
        }
        consumed += width(character);
        if consumed > units {
            return offset;
        }
    }
    text.len()
}

fn lsp_range_to_utf8(source: &str, range: [usize; 4], encoding: PositionEncoding) -> [usize; 4] {
    [
        range[0],
        lsp_to_byte_column(source, range[0], range[1], encoding),
        range[2],
        lsp_to_byte_column(source, range[2], range[3], encoding),
    ]
}

fn compact_range(range: [usize; 4]) -> Vec<usize> {
    if range[0] == range[2] {
        vec![range[0], range[1], range[3]]
    } else {
        range.to_vec()
    }
}

fn text_at_range(source: &str, range: [usize; 4]) -> String {
    if range[0] != range[2] {
        return String::new();
    }
    source
        .split('\n')
        .nth(range[0])
        .and_then(|line| line.get(range[1]..range[3]))
        .unwrap_or_default()
        .to_string()
}

fn parse_locations(value: &Value) -> Vec<Location> {
    let rows = match value {
        Value::Array(rows) => rows.clone(),
        Value::Object(_) => vec![value.clone()],
        _ => Vec::new(),
    };
    rows.into_iter()
        .filter_map(|row| {
            let uri = row
                .get("targetUri")
                .or_else(|| row.get("uri"))?
                .as_str()?
                .to_string();
            let range = row
                .get("targetSelectionRange")
                .or_else(|| row.get("targetRange"))
                .or_else(|| row.get("range"))?;
            Some(Location {
                uri,
                range: parse_range(range)?,
            })
        })
        .collect()
}

fn parse_range(value: &Value) -> Option<[usize; 4]> {
    Some([
        value.pointer("/start/line")?.as_u64()? as usize,
        value.pointer("/start/character")?.as_u64()? as usize,
        value.pointer("/end/line")?.as_u64()? as usize,
        value.pointer("/end/character")?.as_u64()? as usize,
    ])
}

fn path_to_file_uri(path: &Path) -> String {
    let path = path.to_string_lossy();
    let encoded = path
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.' | b'~') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect::<String>();
    format!("file://{encoded}")
}

fn file_uri_to_path(uri: &str) -> Option<PathBuf> {
    let encoded = uri.strip_prefix("file://")?;
    let bytes = encoded.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let value =
                u8::from_str_radix(std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?, 16)
                    .ok()?;
            decoded.push(value);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok().map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callee_ranges_select_the_native_message() {
        let source = "local value = café:transform(inner())\n";
        let call = CallRecord {
            message: "transform".into(),
            span: [1, 14, 1, 37],
            ..test_call()
        };
        assert_eq!(callee_range(&call, source), Some([0, 20, 0, 29]));
    }

    #[test]
    fn lsp_utf16_columns_round_trip_to_scip_utf8() {
        let source = "é😀value()\n";
        assert_eq!(byte_to_lsp_column(source, 0, 6, PositionEncoding::Utf16), 3);
        assert_eq!(lsp_to_byte_column(source, 0, 3, PositionEncoding::Utf16), 6);
    }

    #[test]
    fn parses_location_and_location_link_results() {
        let value = json!([
            {"uri": "file:///tmp/a.lua", "range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 3}}},
            {"targetUri": "file:///tmp/b.lua", "targetSelectionRange": {"start": {"line": 4, "character": 5}, "end": {"line": 4, "character": 8}}}
        ]);
        assert_eq!(parse_locations(&value).len(), 2);
        assert_eq!(parse_locations(&value)[1].range, [4, 5, 4, 8]);
    }

    #[test]
    fn file_uris_preserve_spaces_and_unicode() {
        let path = Path::new("/tmp/a b/é.lua");
        assert_eq!(
            file_uri_to_path(&path_to_file_uri(path)).as_deref(),
            Some(path)
        );
    }

    fn test_call() -> CallRecord {
        CallRecord {
            id: String::new(),
            source: String::new(),
            target: None,
            semantic_symbol: None,
            external_symbol_scope: None,
            complexity_missing_kind: None,
            target_provenance: None,
            candidate_targets: Vec::new(),
            candidate_reason: None,
            kind: String::new(),
            owner: String::new(),
            function: String::new(),
            receiver: String::new(),
            receiver_kind: String::new(),
            receiver_binding_kind: String::new(),
            symbol_namespace: None,
            lexical_symbol: None,
            lexical_symbol_origin: None,
            receiver_call_span: None,
            receiver_definition_call_spans: Vec::new(),
            receiver_symbol: None,
            receiver_type: None,
            receiver_type_origin: None,
            receiver_symbol_origin: None,
            implicit_receiver: false,
            state_receiver: false,
            callback_receiver: false,
            preprocessor_callable: false,
            dispatch_boundary: None,
            constructor_target: None,
            known_time_complexity: None,
            known_space_complexity: None,
            complexity_provenance: None,
            complexity_bound_quality: None,
            complexity_candidates: Vec::new(),
            complexity_assumptions: Vec::new(),
            message: String::new(),
            argument_count: 0,
            arguments: Vec::new(),
            path: String::new(),
            line: 1,
            span: [1, 0, 1, 0],
            conditional: false,
            confidence: String::new(),
            unresolved_reason: None,
            resolution_missing_proof: None,
            empty_domain_cause: None,
        }
    }
}
