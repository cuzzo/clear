use crate::extract::BoundaryExtractor;
use crate::git::GitProvider;
use crate::model::{BlobFile, CrashEvent};
use crate::storage::Storage;
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::HashSet;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawStackFrame {
    pub path: String,
    pub line: u32,
    pub function: String,
    pub context_line: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StackPayload {
    pub provider_id: String,
    pub commit_hash: String,
    pub timestamp: i64,
    pub error_class: String,
    pub frames: Vec<RawStackFrame>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct StackIngestStats {
    pub payloads: usize,
    pub frames: usize,
    pub events: usize,
    pub unverified: usize,
    pub skipped_frames: usize,
}

pub trait StackTraceProvider {
    fn parse_payloads(&self, input: &str) -> Result<Vec<StackPayload>>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SentryProvider;

impl StackTraceProvider for SentryProvider {
    fn parse_payloads(&self, input: &str) -> Result<Vec<StackPayload>> {
        let value: Value = serde_json::from_str(input).context("parse stack trace JSON")?;
        if let Some(values) = value.as_array() {
            values.iter().map(parse_sentry_payload).collect()
        } else if let Some(values) = value.get("events").and_then(Value::as_array) {
            values.iter().map(parse_sentry_payload).collect()
        } else {
            Ok(vec![parse_sentry_payload(&value)?])
        }
    }
}

pub trait LanguageNormalizer {
    fn normalize_path(&self, raw_path: &str) -> String;
}

#[derive(Debug, Clone)]
pub struct RepoPathNormalizer {
    repo_root: String,
}

impl RepoPathNormalizer {
    pub fn new(repo_root: impl AsRef<Path>) -> Self {
        Self {
            repo_root: repo_root.as_ref().to_string_lossy().replace('\\', "/"),
        }
    }
}

impl LanguageNormalizer for RepoPathNormalizer {
    fn normalize_path(&self, raw_path: &str) -> String {
        let mut path = raw_path.replace('\\', "/");
        if let Some(rest) = path.strip_prefix(&self.repo_root) {
            path = rest.trim_start_matches('/').to_string();
        }
        for prefix in ["/github/workspace/", "/workspace/", "/app/"] {
            if let Some(rest) = path.strip_prefix(prefix) {
                path = rest.to_string();
            }
        }
        if path.starts_with('/') {
            let mut best_match: Option<(usize, &str)> = None;
            for marker in ["/src/", "/gems/", "/zig/"] {
                if let Some(index) = path.find(marker) {
                    let actual_idx = index + 1;
                    if best_match.map_or(true, |(best_idx, _)| actual_idx < best_idx) {
                        best_match = Some((actual_idx, marker));
                    }
                }
            }
            if let Some((idx, _)) = best_match {
                return path[idx..].to_string();
            }
            path = path.trim_start_matches('/').to_string();
        }
        path.trim_start_matches("./").to_string()
    }
}

pub fn ingest_stack_traces<E>(
    storage: &Storage,
    provider: &dyn StackTraceProvider,
    normalizer: &dyn LanguageNormalizer,
    git: &GitProvider,
    extractor: &E,
    input: &str,
    replace: bool,
) -> Result<StackIngestStats>
where
    E: BoundaryExtractor,
{
    let payloads = provider.parse_payloads(input)?;
    let mut stats = StackIngestStats {
        payloads: payloads.len(),
        ..StackIngestStats::default()
    };

    storage.begin_transaction()?;
    let result = ingest_payloads(
        storage,
        normalizer,
        git,
        extractor,
        payloads,
        replace,
        &mut stats,
    );
    match result {
        Ok(()) => {
            storage.commit_transaction()?;
            Ok(stats)
        }
        Err(error) => {
            let _ = storage.rollback_transaction();
            Err(error)
        }
    }
}

fn ingest_payloads<E>(
    storage: &Storage,
    normalizer: &dyn LanguageNormalizer,
    git: &GitProvider,
    extractor: &E,
    payloads: Vec<StackPayload>,
    replace: bool,
    stats: &mut StackIngestStats,
) -> Result<()>
where
    E: BoundaryExtractor,
{
    let mut replaced_commits = HashSet::<String>::new();
    for payload in payloads {
        if !storage.commit_exists(&payload.commit_hash)? {
            anyhow::bail!(
                "commit {} is not present in lineage metadata",
                payload.commit_hash
            );
        }
        if replace && replaced_commits.insert(payload.commit_hash.clone()) {
            storage.delete_crash_events_for_commit(&payload.commit_hash)?;
        }
        for frame in payload.frames {
            stats.frames += 1;
            let path = normalizer.normalize_path(&frame.path);
            let Some(file) = file_at_commit(git, &payload.commit_hash, &path)? else {
                stats.skipped_frames += 1;
                continue;
            };
            let Some(unit) = extractor
                .extract_units(&file)
                .into_iter()
                .find(|unit| unit.start_line <= frame.line && frame.line <= unit.end_line)
            else {
                stats.skipped_frames += 1;
                continue;
            };
            let Some(unit_id) = storage.resolve_unit_id(&unit.id, &path, &unit.name)? else {
                stats.skipped_frames += 1;
                continue;
            };
            let verified = verify_context_line(&file, frame.line, frame.context_line.as_deref());
            if !verified {
                stats.unverified += 1;
            }
            if storage.insert_crash_event(&CrashEvent {
                unit_id,
                commit_hash: payload.commit_hash.clone(),
                timestamp: payload.timestamp,
                error_class: payload.error_class.clone(),
                provider_id: payload.provider_id.clone(),
                is_verified: verified,
                path,
                line: frame.line,
                function: frame.function,
            })? {
                stats.events += 1;
            }
        }
    }

    Ok(())
}

fn parse_sentry_payload(value: &Value) -> Result<StackPayload> {
    let provider_id = string_at(value, &["event_id", "id", "provider_id"])
        .unwrap_or("unknown")
        .to_string();
    let commit_hash = string_at(value, &["commit_hash"])
        .or_else(|| value.pointer("/release/commit").and_then(Value::as_str))
        .or_else(|| value.pointer("/tags/commit").and_then(Value::as_str))
        .or_else(|| value.get("release").and_then(Value::as_str))
        .context("Sentry payload missing commit hash")?
        .to_string();
    let timestamp = value
        .get("timestamp")
        .and_then(Value::as_i64)
        .unwrap_or_default();
    let error_class = string_at(value, &["error_class"])
        .or_else(|| value.pointer("/exception/values/0/type").and_then(Value::as_str))
        .unwrap_or("Error")
        .to_string();
    let frames = value
        .get("frames")
        .and_then(Value::as_array)
        .or_else(|| {
            value
                .pointer("/exception/values/0/stacktrace/frames")
                .and_then(Value::as_array)
        })
        .context("Sentry payload missing frames")?
        .iter()
        .filter_map(parse_sentry_frame)
        .collect::<Vec<_>>();

    Ok(StackPayload {
        provider_id,
        commit_hash,
        timestamp,
        error_class,
        frames,
    })
}

fn parse_sentry_frame(value: &Value) -> Option<RawStackFrame> {
    let path = string_at(value, &["filename", "abs_path", "path"])?.to_string();
    let line = value
        .get("lineno")
        .or_else(|| value.get("line"))
        .and_then(Value::as_u64)? as u32;
    let function = string_at(value, &["function"]).unwrap_or("(unknown)").to_string();
    let context_line = string_at(value, &["context_line"])
        .or_else(|| value.get("pre_context").and_then(Value::as_array)?.last()?.as_str())
        .map(str::to_string);

    Some(RawStackFrame {
        path,
        line,
        function,
        context_line,
    })
}

fn string_at<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn file_at_commit(git: &GitProvider, commit_hash: &str, path: &str) -> Result<Option<BlobFile>> {
    let target = path.to_string();
    let files = git.files_at_commit(commit_hash, &|candidate| candidate == target)?;
    Ok(files.into_iter().next())
}

fn verify_context_line(file: &BlobFile, line: u32, context_line: Option<&str>) -> bool {
    let Some(context) = context_line else {
        return true;
    };
    let Some(actual) = file.contents.lines().nth(line.saturating_sub(1) as usize) else {
        return false;
    };
    actual.trim() == context.trim()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_sentry_exception_payload() {
        let payload = json!({
          "event_id": "evt-1",
          "release": "abc123",
          "timestamp": 10,
          "exception": {
            "values": [{
              "type": "ZeroDivisionError",
              "stacktrace": {
                "frames": [{
                  "filename": "/app/src/demo.rb",
                  "function": "run",
                  "lineno": 2,
                  "context_line": "1 / x"
                }]
              }
            }]
          }
        });

        let provider = SentryProvider;
        let parsed = provider.parse_payloads(&payload.to_string()).unwrap();

        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].provider_id, "evt-1");
        assert_eq!(parsed[0].commit_hash, "abc123");
        assert_eq!(parsed[0].error_class, "ZeroDivisionError");
        assert_eq!(parsed[0].frames[0].path, "/app/src/demo.rb");
    }

    #[test]
    fn normalizes_common_runtime_prefixes() {
        let normalizer = RepoPathNormalizer::new("/home/runner/work/clear/clear");

        assert_eq!(
            normalizer.normalize_path("/home/runner/work/clear/clear/src/demo.rb"),
            "src/demo.rb"
        );
        assert_eq!(
            normalizer.normalize_path("/app/gems/demo/lib/demo.rb"),
            "gems/demo/lib/demo.rb"
        );
    }
}
