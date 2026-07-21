use anyhow::{bail, Context, Result};
use serde::Deserialize;

use crate::stack_trace::{LanguageNormalizer, RepoPathNormalizer};
use crate::storage::Storage;

/// One profile-hotness/v1 entry: a function's share of a runtime profile.
#[derive(Clone, Debug, Deserialize)]
pub struct HotnessEntry {
    pub function: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub flat_share: f64,
    #[serde(default)]
    pub cum_share: f64,
    pub tier: String,
}

#[derive(Clone, Debug, Deserialize)]
struct HotnessDocument {
    schema: String,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    commit: Option<String>,
    entries: Vec<HotnessEntry>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HotnessIngestStats {
    pub entries: usize,
    pub critical: usize,
    pub skipped: usize,
}

const TIERS: &[&str] = &["critical", "warm", "cold"];

/// Ingest a profile-hotness/v1 document.
///
/// Rows are replaced per profile `source` so re-ingesting a fresh profile of
/// the same workload never double-counts, while profiles of different
/// workloads coexist; consumers take the maximum tier across sources - hot in
/// any real workload means hot.
pub fn ingest_hotness_json(
    storage: &Storage,
    normalizer: &RepoPathNormalizer,
    payload: &str,
    source_override: Option<&str>,
    commit_override: Option<&str>,
) -> Result<HotnessIngestStats> {
    let document: HotnessDocument =
        serde_json::from_str(payload).with_context(|| "invalid profile-hotness JSON")?;
    if document.schema != "profile-hotness/v1" {
        bail!("unsupported hotness schema: {}", document.schema);
    }
    let source = source_override
        .map(str::to_string)
        .or(document.source.clone())
        .unwrap_or_else(|| "profile".to_string());
    let commit = commit_override
        .map(str::to_string)
        .or(document.commit.clone());

    storage.deactivate_hotness_for_source(&source)?;

    let mut stats = HotnessIngestStats::default();
    for entry in &document.entries {
        if entry.function.trim().is_empty() || !TIERS.contains(&entry.tier.as_str()) {
            stats.skipped += 1;
            continue;
        }
        let path = entry
            .path
            .as_deref()
            .map(|raw| normalizer.normalize_path(raw))
            .filter(|normalized| !normalized.is_empty());
        storage.insert_unit_hotness(
            path.as_deref(),
            &entry.function,
            entry.line,
            entry.flat_share,
            entry.cum_share,
            &entry.tier,
            &source,
            commit.as_deref(),
        )?;
        stats.entries += 1;
        if entry.tier == "critical" {
            stats.critical += 1;
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn open_storage(dir: &std::path::Path) -> Storage {
        Storage::open(&dir.join("lineage.db")).unwrap()
    }

    fn payload(entries: &str) -> String {
        format!(
            r#"{{"schema":"profile-hotness/v1","source":"pprof:cpu","commit":"abc","entries":[{entries}]}}"#
        )
    }

    #[test]
    fn ingests_entries_and_replaces_same_source() {
        let dir = tempdir().unwrap();
        let storage = open_storage(dir.path());
        let normalizer = RepoPathNormalizer::new(dir.path());

        let stats = ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Server#handle","path":"src/server.rb","line":42,"flat_share":0.4,"cum_share":0.6,"tier":"critical"},
                   {"function":"Parser#parse","path":"src/parse.rb","line":10,"flat_share":0.01,"cum_share":0.02,"tier":"warm"},
                   {"function":"","tier":"critical"},
                   {"function":"Bad#tier","tier":"scorching"}"#,
            ),
            None,
            None,
        )
        .unwrap();
        assert_eq!(stats.entries, 2);
        assert_eq!(stats.critical, 1);
        assert_eq!(stats.skipped, 2);

        // Re-ingest the same source: previous rows deactivate, no double count.
        let stats = ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Server#handle","path":"src/server.rb","line":42,"flat_share":0.5,"cum_share":0.7,"tier":"critical"}"#,
            ),
            None,
            None,
        )
        .unwrap();
        assert_eq!(stats.entries, 1);

        let rows = storage.active_hotness().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].function, "Server#handle");
        assert!((rows[0].cum_share - 0.7).abs() < 1e-9);

        // A different source coexists.
        ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Worker#drain","path":"src/worker.rb","flat_share":0.2,"cum_share":0.3,"tier":"critical"}"#,
            ),
            Some("pprof:io"),
            None,
        )
        .unwrap();
        assert_eq!(storage.active_hotness().unwrap().len(), 2);
    }

    #[test]
    fn rejects_unknown_schema() {
        let dir = tempdir().unwrap();
        let storage = open_storage(dir.path());
        let normalizer = RepoPathNormalizer::new(dir.path());
        let error = ingest_hotness_json(
            &storage,
            &normalizer,
            r#"{"schema":"profile-hotness/v2","entries":[]}"#,
            None,
            None,
        )
        .unwrap_err();
        assert!(error.to_string().contains("unsupported hotness schema"));
    }
}
