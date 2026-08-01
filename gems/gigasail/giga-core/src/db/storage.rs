use crate::diff::{
    CoverageObservation, EvidenceScopeFingerprint, MutationKillObservation, SarifFindingSummary,
    SarifObservation, ScopedCoverageArtifact, ScopedMutationArtifact,
};
use crate::model::{
    CommitMetadata, CrashEvent, Event, HazardEvent, LogicalUnit, QualityEvent, QualityMetric,
    SarifArtifact, SarifFinding, TestExposureEvent,
};
use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::Path;

/// The hotness overlay query, shared by core summary materialization and the
/// giga-ui runtime overlay. Exposed as a const so consumers across the crate
/// boundary reuse the single source instead of a cross-crate `include_str!`.
pub const APPLY_HOTNESS_SQL: &str = include_str!("../../sql/core/apply_hotness.sql");
/// Per-line active-hazard overlay. Shared by the web UI, the LSP, and the MCP
/// `giga_unit_context` tool — it is a Storage runtime query, so it lives here.
pub const APPLY_HAZARDS_SQL: &str = include_str!("../../sql/core/apply_hazards.sql");

pub struct Storage {
    conn: Connection,
}

#[derive(Debug, Clone)]
pub struct CoverageLineBulk {
    pub commit_hash: String,
    pub timestamp: i64,
    pub path: String,
    pub line: u32,
    pub hits: u32,
    pub is_partial: bool,
    pub coverage_percent: Option<f64>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvidenceArtifactScope {
    pub family: String,
    pub source: String,
    pub scope: EvidenceScopeFingerprint,
    pub complete: bool,
    pub expected_lines: BTreeSet<(String, u32)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentUnitSpan {
    pub id: String,
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SarifLifecycleSummary {
    pub new_findings: i64,
    pub resolved_findings: i64,
    pub persisted_findings: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CiRunRecord {
    pub revision: String,
    pub profile: String,
    pub configuration_hash: String,
    pub repository_identity: String,
    pub manifest_hash: String,
    pub state: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UnitSummary {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub original_path: String,
    pub current_path: String,
    pub total_events: i64,
    pub changes: i64,
    pub moves: i64,
    pub fixes: i64,
    pub risk_score: f64,
    pub current_distinct_tests: i64,
    pub current_test_types: String,
    pub current_mutant_verified_tests: i64,
    pub current_mutant_killed_tests: i64,
    pub last_test_exposure_at: i64,
    pub last_mutant_run_at: i64,
    pub latest_fix_at: i64,
    pub latest_change_at: i64,
    pub fixes_after_test_exposure: i64,
    pub changes_after_test_exposure: i64,
    pub semantic_changes_after_mutant_run: i64,
    pub verification_stale_seconds: i64,
    pub verification_staleness_score: f64,
    pub reopened_count: i64,
    /// Big-O time/space complexity from the architecture graph, with status
    /// complete | partial | unknown (unknown = no analysis available).
    pub big_o_time: String,
    pub big_o_time_status: String,
    pub big_o_space: String,
    pub big_o_space_status: String,
}

impl Storage {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)?;
            // Make the state directory self-ignoring so the database, its WAL/SHM
            // sidecars, run artifacts, and the coordination lock never surface as
            // Git changes (in `giga diff`, the clean-worktree gate, or `git status`).
            let ignore = parent.join(".gitignore");
            if !ignore.exists() {
                let _ = std::fs::write(&ignore, "*\n");
            }
        }
        let conn = Connection::open(path)?;
        configure_connection(&conn)?;
        let storage = Self { conn };

        // Check if schema needs to be initialized by verifying if logical_units table exists
        let has_schema = {
            let mut stmt = storage.conn.prepare(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='logical_units'",
            )?;
            stmt.exists([])?
        };
        if !has_schema {
            storage.init_schema()?;
        }
        Ok(storage)
    }

    pub fn open_existing(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        configure_connection(&conn)?;
        Ok(Self { conn })
    }

    pub fn open_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        configure_connection(&conn)?;
        let storage = Self { conn };
        storage.init_schema()?;
        Ok(storage)
    }

    pub fn init_schema(&self) -> Result<()> {
        let _ = self.conn.execute_batch("PRAGMA journal_mode = WAL;");
        self.begin_transaction()?;
        match self.init_schema_impl() {
            Ok(()) => {
                self.commit_transaction()?;
                Ok(())
            }
            Err(e) => {
                let _ = self.rollback_transaction();
                Err(e)
            }
        }
    }

    fn init_schema_impl(&self) -> Result<()> {
        self.conn
            .execute_batch(include_str!("../../sql/storage/init_schema.sql"))?;
        self.ensure_logical_unit_column("start_line", "INTEGER DEFAULT 1")?;
        self.ensure_logical_unit_column("current_line_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("current_integration_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("current_mutant_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("is_hard_gated", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_distinct_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_test_types", "TEXT DEFAULT ''")?;
        self.ensure_logical_unit_column("current_mutant_verified_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_mutant_killed_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("last_test_exposure_at", "INTEGER DEFAULT 0")?;
        self.ensure_big_o_columns()?;
        self.ensure_column(
            "test_exposure_events",
            "mutation_kind",
            "TEXT NOT NULL DEFAULT ''",
        )?;
        self.ensure_column(
            "test_exposure_events",
            "mutation_corpus",
            "TEXT NOT NULL DEFAULT ''",
        )?;
        self.ensure_column(
            "coverage_line_events",
            "is_partial",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        self.ensure_column("coverage_line_events", "coverage_percent", "REAL")?;
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS evidence_artifact_scopes (\
              family TEXT NOT NULL, source TEXT NOT NULL, revision TEXT NOT NULL, \
              selection_scope TEXT NOT NULL, mutant_corpus TEXT NOT NULL, test_set TEXT NOT NULL, \
              complete INTEGER NOT NULL CHECK (complete IN (0, 1)), expected_lines_json TEXT NOT NULL, \
              PRIMARY KEY(family, source, revision, selection_scope, mutant_corpus, test_set)\
            );\
            CREATE INDEX IF NOT EXISTS idx_evidence_artifact_scopes_lookup \
              ON evidence_artifact_scopes(family, revision, source);",
        )?;
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS ci_runs (\
              run_path TEXT PRIMARY KEY, revision TEXT NOT NULL, profile TEXT NOT NULL, \
              configuration_hash TEXT NOT NULL, repository_identity TEXT NOT NULL, \
              manifest_hash TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('ingesting', 'ingested', 'published')), \
              updated_at_ms INTEGER NOT NULL\
            );\
            CREATE INDEX IF NOT EXISTS idx_ci_runs_revision_profile \
              ON ci_runs(revision, profile, state);",
        )?;
        self.ensure_column(
            "ui_file_summaries",
            "partial_lines",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        self.ensure_column(
            "ui_file_summaries",
            "mutant_verified_covered_lines",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        self.ensure_column(
            "ui_file_summaries",
            "stochastic_mutant_verified_covered_lines",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        self.ensure_column(
            "ui_file_summaries",
            "invariant_mutant_verified_covered_lines",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        self.refresh_current_sarif_findings_view()?;
        self.backfill_mutation_kind()?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_test_exposure_events_mutation_kind ON test_exposure_events(mutation_kind)",
            [],
        )?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_test_exposure_events_mutation_corpus ON test_exposure_events(commit_hash, mutation_corpus)",
            [],
        )?;
        self.ensure_natural_key_indexes()?;
        Ok(())
    }

    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    fn ensure_logical_unit_column(&self, name: &str, definition: &str) -> Result<()> {
        self.ensure_column("logical_units", name, definition)
    }

    pub fn refresh_current_sarif_findings_view(&self) -> Result<()> {
        let _ = self
            .conn
            .execute("DROP VIEW IF EXISTS current_sarif_findings", []);
        self.conn.execute_batch(include_str!(
            "../../sql/storage/refresh_current_sarif_findings_view.sql"
        ))?;
        Ok(())
    }

    fn ensure_column(&self, table: &str, name: &str, definition: &str) -> Result<()> {
        let table = checked_table(table)?;
        let mut stmt = self.conn.prepare(&format!("PRAGMA table_info({table})"))?;
        let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
        for column in columns {
            if column? == name {
                return Ok(());
            }
        }
        self.conn.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {name} {definition}"),
            [],
        )?;
        Ok(())
    }

    fn ensure_natural_key_indexes(&self) -> Result<()> {
        self.conn.execute_batch(include_str!(
            "../../sql/storage/ensure_natural_key_indexes.sql"
        ))?;
        Ok(())
    }

    fn backfill_mutation_kind(&self) -> Result<()> {
        self.conn.execute(
            include_str!("../../sql/storage/backfill_mutation_kind.sql"),
            [],
        )?;
        Ok(())
    }

    pub fn begin_transaction(&self) -> Result<()> {
        self.conn.execute_batch("BEGIN IMMEDIATE TRANSACTION;")?;
        Ok(())
    }

    /// Returns whether a caller already owns the connection transaction.
    ///
    /// Importers use this to participate in a run-wide transaction without
    /// committing evidence independently. Stand-alone importer calls retain
    /// their existing transactional behavior.
    pub fn transaction_active(&self) -> bool {
        !self.conn.is_autocommit()
    }

    pub fn commit_transaction(&self) -> Result<()> {
        self.conn.execute_batch("COMMIT;")?;
        Ok(())
    }

    pub fn rollback_transaction(&self) -> Result<()> {
        self.conn.execute_batch("ROLLBACK;")?;
        Ok(())
    }

    /// Durable database-side counterpart to the filesystem publication state.
    /// The run path is repository-relative to the configured artifact store.
    pub fn record_ci_run(
        &self,
        run_path: &str,
        manifest: &crate::pipeline::RunManifest,
        state: &str,
        updated_at_ms: u128,
    ) -> Result<()> {
        let manifest_hash = crate::pipeline::run_manifest_hash(manifest)?;
        self.conn.execute(
            "INSERT INTO ci_runs \
             (run_path, revision, profile, configuration_hash, repository_identity, manifest_hash, state, updated_at_ms) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
             ON CONFLICT(run_path) DO UPDATE SET revision = excluded.revision, profile = excluded.profile, \
             configuration_hash = excluded.configuration_hash, repository_identity = excluded.repository_identity, \
             manifest_hash = excluded.manifest_hash, state = excluded.state, updated_at_ms = excluded.updated_at_ms",
            params![
                run_path,
                manifest.revision,
                manifest.profile,
                manifest.configuration_hash,
                manifest.repository_identity,
                manifest_hash,
                state,
                i64::try_from(updated_at_ms).unwrap_or(i64::MAX),
            ],
        )?;
        Ok(())
    }

    pub fn ci_run_state(&self, run_path: &str) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT state FROM ci_runs WHERE run_path = ?1",
                params![run_path],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn ci_run_record(&self, run_path: &str) -> Result<Option<CiRunRecord>> {
        self.conn
            .query_row(
                "SELECT revision, profile, configuration_hash, repository_identity, manifest_hash, state \
                 FROM ci_runs WHERE run_path = ?1",
                params![run_path],
                |row| {
                    Ok(CiRunRecord {
                        revision: row.get(0)?,
                        profile: row.get(1)?,
                        configuration_hash: row.get(2)?,
                        repository_identity: row.get(3)?,
                        manifest_hash: row.get(4)?,
                        state: row.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn insert_metadata(&self, metadata: &CommitMetadata) -> Result<()> {
        self.conn.execute(
            include_str!("../../sql/storage/insert_metadata.sql"),
            params![metadata.hash, metadata.message, metadata.timestamp],
        )?;
        Ok(())
    }

    pub fn commit_exists(&self, commit_hash: &str) -> Result<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM metadata WHERE commit_hash = ?1",
            params![commit_hash],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn commit_timestamp(&self, commit_hash: &str) -> Result<Option<i64>> {
        let mut stmt = self
            .conn
            .prepare("SELECT timestamp FROM metadata WHERE commit_hash = ?1")?;
        let mut rows = stmt.query(params![commit_hash])?;
        Ok(rows.next()?.map(|row| row.get(0)).transpose()?)
    }

    pub fn save_engine_state(&self, commit_hash: &str, state_json: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_state (commit_hash, state_json) VALUES (?1, ?2)",
            params![commit_hash, state_json],
        )?;
        Ok(())
    }

    pub fn load_engine_state(&self, commit_hash: &str) -> Result<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT state_json FROM engine_state WHERE commit_hash = ?1")?;
        let mut rows = stmt.query(params![commit_hash])?;
        Ok(rows.next()?.map(|row| row.get(0)).transpose()?)
    }

    pub fn upsert_logical_unit(&self, unit: &LogicalUnit, created_at: i64) -> Result<()> {
        self.conn.execute(
            include_str!("../../sql/storage/upsert_logical_unit.sql"),
            params![
                unit.id,
                unit.name,
                unit.kind.as_str(),
                unit.path,
                created_at,
                unit.start_line
            ],
        )?;
        Ok(())
    }

    pub fn find_definitions(
        &self,
        name: &str,
        commit_hash: Option<&str>,
        current_path: Option<&str>,
    ) -> Result<Vec<(String, u32)>> {
        let target_commit = match commit_hash {
            Some(hash) => Some(hash.to_string()),
            None => {
                let mut stmt = self
                    .conn
                    .prepare("SELECT commit_hash FROM metadata ORDER BY timestamp DESC LIMIT 1")?;
                let mut rows = stmt.query([])?;
                rows.next()?
                    .map(|row| row.get::<_, String>(0))
                    .transpose()?
            }
        };

        // Try to load engine state first for exact current paths and lines
        if let Some(ref hash) = target_commit {
            if let Ok(Some(state_json)) = self.load_engine_state(hash) {
                if let Ok(state) = serde_json::from_str::<serde_json::Value>(&state_json) {
                    if let Some(previous) = state.get("previous").and_then(|p| p.as_object()) {
                        let mut results = Vec::new();
                        for (_id, val) in previous {
                            let Some(uname) = val.get("name").and_then(|n| n.as_str()) else {
                                continue;
                            };

                            // Check if name matches (exactly or qualified suffix)
                            let name_matches = uname == name
                                || uname.ends_with(&format!(".{name}"))
                                || uname.ends_with(&format!("::{name}"))
                                || uname.ends_with(&format!("#{name}"));

                            if name_matches {
                                let Some(upath) = val.get("path").and_then(|p| p.as_str()) else {
                                    continue;
                                };
                                let Some(ustart) = val.get("start_line").and_then(|l| l.as_u64())
                                else {
                                    continue;
                                };
                                results.push((upath.to_string(), ustart as u32));
                            }
                        }

                        if !results.is_empty() {
                            // Sort results to prioritize proximity to current_path if provided
                            if let Some(cur_path) = current_path {
                                let normalized_cur =
                                    cur_path.trim().trim_start_matches("./").trim_matches('/');
                                let cur_dir = if let Some(idx) = normalized_cur.rfind('/') {
                                    &normalized_cur[..idx]
                                } else {
                                    ""
                                };
                                results.sort_by(|a, b| {
                                    let a_norm =
                                        a.0.trim().trim_start_matches("./").trim_matches('/');
                                    let b_norm =
                                        b.0.trim().trim_start_matches("./").trim_matches('/');

                                    let a_exact = a_norm == normalized_cur;
                                    let b_exact = b_norm == normalized_cur;
                                    if a_exact != b_exact {
                                        return b_exact.cmp(&a_exact);
                                    }

                                    let a_in_dir = !cur_dir.is_empty()
                                        && a_norm.starts_with(&format!("{}/", cur_dir));
                                    let b_in_dir = !cur_dir.is_empty()
                                        && b_norm.starts_with(&format!("{}/", cur_dir));
                                    if a_in_dir != b_in_dir {
                                        return b_in_dir.cmp(&a_in_dir);
                                    }

                                    a.0.cmp(&b.0).then(a.1.cmp(&b.1))
                                });
                            } else {
                                results.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
                            }
                            return Ok(results);
                        }
                    }
                }
            }
        }

        let active_ids = if let Some(ref hash) = target_commit {
            if let Ok(Some(state_json)) = self.load_engine_state(hash) {
                if let Ok(state) = serde_json::from_str::<serde_json::Value>(&state_json) {
                    state
                        .get("previous")
                        .and_then(|previous| previous.as_object())
                        .map(|previous| previous.keys().cloned().collect::<HashSet<_>>())
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        let mut stmt = self
            .conn
            .prepare(include_str!("../../sql/storage/find_definitions.sql"))?;
        let rows = stmt.query_map(params![name], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
            ))
        })?;
        let mut results = Vec::new();
        for row in rows {
            let (id, path, line) = row?;
            if let Some(ref active) = active_ids {
                if active.contains(&id) {
                    results.push((path, line));
                }
            } else {
                results.push((path, line));
            }
        }

        // Sort results to prioritize proximity to current_path if provided
        if let Some(cur_path) = current_path {
            let normalized_cur = cur_path.trim().trim_start_matches("./").trim_matches('/');
            let cur_dir = if let Some(idx) = normalized_cur.rfind('/') {
                &normalized_cur[..idx]
            } else {
                ""
            };
            results.sort_by(|a, b| {
                let a_norm = a.0.trim().trim_start_matches("./").trim_matches('/');
                let b_norm = b.0.trim().trim_start_matches("./").trim_matches('/');

                let a_exact = a_norm == normalized_cur;
                let b_exact = b_norm == normalized_cur;
                if a_exact != b_exact {
                    return b_exact.cmp(&a_exact); // exact match first
                }

                let a_in_dir = !cur_dir.is_empty() && a_norm.starts_with(&format!("{}/", cur_dir));
                let b_in_dir = !cur_dir.is_empty() && b_norm.starts_with(&format!("{}/", cur_dir));
                if a_in_dir != b_in_dir {
                    return b_in_dir.cmp(&a_in_dir); // same directory first
                }

                a.0.cmp(&b.0).then(a.1.cmp(&b.1))
            });
        } else {
            results.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        }

        Ok(results)
    }

    pub fn insert_event(&self, event: &Event) -> Result<()> {
        self.conn.execute(
            include_str!("../../sql/storage/insert_event.sql"),
            params![
                event.unit_id,
                event.commit_hash,
                event.event_type.as_str(),
                event.path,
                event.name,
                event.start_line,
                event.end_line,
                if event.semantic_change { 1 } else { 0 },
                event.lines_added,
                event.lines_removed,
                event.timestamp
            ],
        )?;
        Ok(())
    }

    pub fn unit_ids_for_current_path(&self, path: &str) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare_cached(include_str!(
            "../../sql/storage/unit_ids_for_current_path.sql"
        ))?;
        let rows = stmt.query_map(params![path], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn resolve_current_path(&self, path: &str) -> Result<Option<String>> {
        let normalized = path.trim_start_matches("./");
        let mut stmt = self
            .conn
            .prepare_cached(include_str!("../../sql/storage/resolve_current_path.sql"))?;
        let exact = stmt
            .query_map(params![normalized], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if let Some(path) = exact.into_iter().next() {
            return Ok(Some(path));
        }

        let suffix = format!("%/{normalized}");
        let mut stmt = self
            .conn
            .prepare_cached(include_str!("../../sql/storage/resolve_current_path_2.sql"))?;
        let candidates = stmt
            .query_map(params![suffix], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(if candidates.len() == 1 {
            candidates.into_iter().next()
        } else {
            None
        })
    }

    pub fn resolve_unit_id(
        &self,
        observed_id: &str,
        path: &str,
        name: &str,
    ) -> Result<Option<String>> {
        if self.logical_unit_exists(observed_id)? {
            return Ok(Some(observed_id.to_string()));
        }

        let mut stmt = self
            .conn
            .prepare(include_str!("../../sql/storage/resolve_unit_id.sql"))?;
        let mut rows = stmt.query(params![path, name])?;
        Ok(rows.next()?.map(|row| row.get(0)).transpose()?)
    }

    fn logical_unit_exists(&self, unit_id: &str) -> Result<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM logical_units WHERE id = ?1",
            params![unit_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    pub fn record_quality_metric(&self, event: &QualityEvent) -> Result<bool> {
        let (column, old_value) = self.current_quality_value(&event.unit_id, event.metric_type)?;
        if let Some((id, previous_new_value)) =
            self.existing_quality_event(&event.unit_id, &event.commit_hash, event.metric_type)?
        {
            let merged_value = previous_new_value.max(event.new_value);
            self.conn
                .prepare_cached(&format!(
                    "UPDATE logical_units SET {column} = ?2 WHERE id = ?1"
                ))?
                .execute(params![event.unit_id, merged_value])?;
            if (previous_new_value - merged_value).abs() < 0.0001 {
                return Ok(false);
            }

            self.conn
                .prepare_cached(include_str!("../../sql/storage/record_quality_metric.sql"))?
                .execute(params![id, event.timestamp, merged_value])?;
            return Ok(true);
        }

        if old_value
            .map(|value| (value - event.new_value).abs() < 0.0001)
            .unwrap_or(false)
        {
            return Ok(false);
        }

        self.conn
            .prepare_cached(include_str!(
                "../../sql/storage/record_quality_metric_2.sql"
            ))?
            .execute(params![
                event.unit_id,
                event.commit_hash,
                event.timestamp,
                event.metric_type.as_str(),
                old_value,
                event.new_value
            ])?;
        self.conn
            .prepare_cached(&format!(
                "UPDATE logical_units SET {column} = ?2 WHERE id = ?1"
            ))?
            .execute(params![event.unit_id, event.new_value])?;
        Ok(true)
    }

    fn existing_quality_event(
        &self,
        unit_id: &str,
        commit_hash: &str,
        metric: QualityMetric,
    ) -> Result<Option<(i64, f64)>> {
        let mut stmt = self
            .conn
            .prepare_cached(include_str!("../../sql/storage/existing_quality_event.sql"))?;
        Ok(stmt
            .query_row(params![unit_id, commit_hash, metric.as_str()], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .optional()?)
    }

    pub fn delete_coverage_for_commit(&self, commit_hash: &str) -> Result<usize> {
        let quality = self.conn.execute(
            include_str!("../../sql/storage/delete_coverage_for_commit.sql"),
            params![commit_hash],
        )?;
        let lines = self.conn.execute(
            "DELETE FROM coverage_line_events WHERE commit_hash = ?1",
            params![commit_hash],
        )?;
        self.refresh_current_quality_metrics()?;
        Ok(quality + lines)
    }

    pub fn delete_coverage_lines_for_commit_source(
        &self,
        commit_hash: &str,
        source: &str,
    ) -> Result<usize> {
        Ok(self.conn.execute(
            "DELETE FROM coverage_line_events WHERE commit_hash = ?1 AND source = ?2",
            params![commit_hash, source],
        )?)
    }

    pub fn delete_test_exposure_for_commit_test(
        &self,
        commit_hash: &str,
        test_type: &str,
        test_id: &str,
    ) -> Result<usize> {
        let mut stmt = self.conn.prepare(include_str!(
            "../../sql/storage/delete_test_exposure_for_commit_test.sql"
        ))?;
        let unit_ids = stmt
            .query_map(params![commit_hash, test_type, test_id], |row| {
                row.get::<_, String>(0)
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let deleted = self.conn.execute(
            include_str!("../../sql/storage/delete_test_exposure_for_commit_test_2.sql"),
            params![commit_hash, test_type, test_id],
        )?;
        for unit_id in unit_ids {
            self.refresh_test_exposure_summary(&unit_id)?;
        }
        Ok(deleted)
    }

    pub fn delete_sarif_for_commit_source(&self, commit_hash: &str, source: &str) -> Result<usize> {
        let findings = self.conn.execute(
            "DELETE FROM sarif_findings WHERE commit_hash = ?1 AND source = ?2",
            params![commit_hash, source],
        )?;
        let artifacts = self.conn.execute(
            "DELETE FROM sarif_artifacts WHERE commit_hash = ?1 AND source = ?2",
            params![commit_hash, source],
        )?;
        Ok(findings + artifacts)
    }

    pub fn prune_stale_sarif_data(&self) -> Result<()> {
        // Delete findings for files that have been modified in a newer commit
        self.conn.execute(
            r#"
            DELETE FROM sarif_findings
            WHERE EXISTS (
              SELECT 1 FROM events e
              WHERE e.path = sarif_findings.path
                AND e.timestamp > sarif_findings.timestamp
            )
            "#,
            [],
        )?;

        // Delete findings belonging to snapshots older than 2 (rank >= 3)
        self.conn.execute(
            r#"
            WITH commit_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     MAX(timestamp) AS timestamp, MAX(id) AS id
              FROM sarif_findings
              GROUP BY path, source, tool_name, commit_hash
            ),
            ranked_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     ROW_NUMBER() OVER (
                       PARTITION BY path, source, tool_name
                       ORDER BY timestamp DESC, id DESC
                     ) AS snapshot_rank
              FROM commit_snapshots
            ),
            stale_snapshots AS (
              SELECT path, source, tool_name, commit_hash
              FROM ranked_snapshots
              WHERE snapshot_rank >= 3
            )
            DELETE FROM sarif_findings
            WHERE EXISTS (
              SELECT 1 FROM stale_snapshots s
              WHERE s.path = sarif_findings.path
                AND s.source = sarif_findings.source
                AND s.tool_name = sarif_findings.tool_name
                AND s.commit_hash = sarif_findings.commit_hash
            )
            "#,
            [],
        )?;

        // Delete orphan artifacts whose findings have been pruned
        self.conn.execute(
            "DELETE FROM sarif_artifacts WHERE id NOT IN (SELECT DISTINCT artifact_id FROM sarif_findings)",
            [],
        )?;

        Ok(())
    }

    pub fn insert_sarif_artifact(&self, artifact: &SarifArtifact) -> Result<i64> {
        self.conn.execute(
            include_str!("../../sql/storage/insert_sarif_artifact.sql"),
            params![
                artifact.source,
                artifact.tool_name,
                artifact.run_format,
                artifact.artifact_path,
                artifact.artifact_sha256,
                artifact.commit_hash,
                artifact.timestamp,
                // Never read back (findings are normalized into sarif_findings;
                // the gzipped run-store artifact is the durable raw copy), so we
                // do not persist the full document text here.
                ""
            ],
        )?;
        let id = self.conn.query_row(
            include_str!("../../sql/storage/insert_sarif_artifact_2.sql"),
            params![
                artifact.source,
                artifact.commit_hash,
                artifact.artifact_path,
                artifact.artifact_sha256
            ],
            |row| row.get(0),
        )?;
        Ok(id)
    }

    pub fn insert_sarif_finding(&self, finding: &SarifFinding) -> Result<bool> {
        let inserted = self.conn.execute(
            include_str!("../../sql/storage/insert_sarif_finding.sql"),
            params![
                finding.artifact_id,
                finding.finding_key,
                finding.source,
                finding.tool_name,
                finding.run_format,
                finding.commit_hash,
                finding.timestamp,
                finding.rule_id,
                finding.level,
                finding.message,
                finding.path,
                finding.start_line,
                finding.start_column,
                finding.end_line,
                finding.end_column,
                finding.category,
                if finding.is_dark_arm { 1 } else { 0 },
                finding.unit_id,
                finding.fingerprint,
                finding.properties_json,
                finding.raw_json
            ],
        )?;
        Ok(inserted > 0)
    }

    pub fn current_unit_id_for_path_line(&self, path: &str, line: u32) -> Result<Option<String>> {
        Ok(self
            .current_unit_spans_for_path(path)?
            .into_iter()
            .filter(|span| span.path == path && line >= span.start_line && line <= span.end_line)
            .min_by_key(|span| {
                (
                    span.end_line.saturating_sub(span.start_line),
                    span.id.clone(),
                )
            })
            .map(|span| span.id))
    }

    pub fn current_unit_spans_for_path(&self, path: &str) -> Result<Vec<CurrentUnitSpan>> {
        let mut stmt = self.conn.prepare(include_str!(
            "../../sql/storage/current_unit_spans_for_path.sql"
        ))?;
        let rows = stmt.query_map(params![path], |row| {
            Ok(CurrentUnitSpan {
                id: row.get(0)?,
                path: row.get(1)?,
                start_line: row.get::<_, i64>(2)?.max(1) as u32,
                end_line: row.get::<_, i64>(3)?.max(1) as u32,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn current_unit_spans(&self) -> Result<Vec<CurrentUnitSpan>> {
        let mut stmt = self
            .conn
            .prepare(include_str!("../../sql/storage/current_unit_spans.sql"))?;
        let rows = stmt.query_map([], |row| {
            Ok(CurrentUnitSpan {
                id: row.get(0)?,
                path: row.get(1)?,
                start_line: row.get::<_, i64>(2)?.max(1) as u32,
                end_line: row.get::<_, i64>(3)?.max(1) as u32,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn current_unit_spans_for_ids(&self, ids: &[String]) -> Result<Vec<CurrentUnitSpan>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let mut sql = String::new();
        sql.push_str(
            r#"
            WITH latest_events AS (
              SELECT *
              FROM (
                SELECT e.*,
                       ROW_NUMBER() OVER (
                         PARTITION BY e.unit_id
                         ORDER BY e.timestamp DESC, e.id DESC
                       ) AS rank
                FROM events e
                WHERE e.unit_id IN (
        "#,
        );
        for i in 0..ids.len() {
            if i > 0 {
                sql.push_str(", ");
            }
            sql.push_str(&format!("?{}", i + 1));
        }
        sql.push_str(
            r#"
                )
              )
              WHERE rank = 1
            ),
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     COALESCE(le.start_line, 1) AS start_line,
                     COALESCE(le.end_line, le.start_line, 1) AS end_line
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
              WHERE u.id IN (
        "#,
        );
        for i in 0..ids.len() {
            if i > 0 {
                sql.push_str(", ");
            }
            sql.push_str(&format!("?{}", i + 1));
        }
        sql.push_str(
            r#"
              )
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path <> ''
        "#,
        );

        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(ids), |row| {
            Ok(CurrentUnitSpan {
                id: row.get(0)?,
                path: row.get(1)?,
                start_line: row.get::<_, i64>(2)?.max(1) as u32,
                end_line: row.get::<_, i64>(3)?.max(1) as u32,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn sarif_findings_for_path(&self, path: &str) -> Result<Vec<SarifFinding>> {
        let mut stmt = self.conn.prepare(include_str!(
            "../../sql/storage/sarif_findings_for_path.sql"
        ))?;
        let rows = stmt.query_map(params![path], |row| {
            Ok(SarifFinding {
                artifact_id: row.get(0)?,
                finding_key: row.get(1)?,
                source: row.get(2)?,
                tool_name: row.get(3)?,
                run_format: row.get(4)?,
                commit_hash: row.get(5)?,
                timestamp: row.get(6)?,
                rule_id: row.get(7)?,
                level: row.get(8)?,
                message: row.get(9)?,
                path: row.get(10)?,
                start_line: row.get(11)?,
                start_column: row.get(12)?,
                end_line: row.get(13)?,
                end_column: row.get(14)?,
                category: row.get(15)?,
                is_dark_arm: row.get::<_, i64>(16)? != 0,
                unit_id: row.get(17)?,
                fingerprint: row.get(18)?,
                properties_json: row.get(19)?,
                raw_json: row.get(20)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn sarif_finding_counts_by_file(&self) -> Result<HashMap<String, i64>> {
        let mut stmt = self.conn.prepare(include_str!(
            "../../sql/storage/sarif_finding_counts_by_file.sql"
        ))?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        Ok(rows.collect::<std::result::Result<HashMap<_, _>, _>>()?)
    }

    pub fn sarif_lifecycle_summary(&self) -> Result<SarifLifecycleSummary> {
        self.conn
            .query_row(
                include_str!("../../sql/storage/sarif_lifecycle_summary.sql"),
                [],
                |row| {
                    Ok(SarifLifecycleSummary {
                        new_findings: row.get(0)?,
                        resolved_findings: row.get(1)?,
                        persisted_findings: row.get(2)?,
                    })
                },
            )
            .map_err(Into::into)
    }

    fn refresh_current_quality_metrics(&self) -> Result<()> {
        self.conn.execute_batch(include_str!(
            "../../sql/storage/refresh_current_quality_metrics.sql"
        ))?;
        for (metric, column) in [
            (QualityMetric::LineCoverage, "current_line_cov"),
            (
                QualityMetric::IntegrationCoverage,
                "current_integration_cov",
            ),
            (QualityMetric::MutantCoverage, "current_mutant_cov"),
            (QualityMetric::GateStatus, "is_hard_gated"),
        ] {
            self.conn.execute(
                &format!(
                    include_str!("../../sql/storage/refresh_current_quality_metrics_2.sql"),
                    column = column
                ),
                params![metric.as_str()],
            )?;
        }
        Ok(())
    }

    pub fn record_coverage_line(
        &self,
        commit_hash: &str,
        timestamp: i64,
        path: &str,
        line: u32,
        hits: u32,
    ) -> Result<bool> {
        self.record_coverage_line_with_source(
            commit_hash,
            timestamp,
            path,
            line,
            hits,
            false,
            "coverage",
        )
    }

    pub fn coverage_observations_for_commit_paths(
        &self,
        commit_hash: &str,
        paths: &[String],
    ) -> Result<Vec<CoverageObservation>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut observations = Vec::new();
        for paths in paths.chunks(500) {
            let placeholders = std::iter::repeat("?")
                .take(paths.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT path, line, MAX(hits), MAX(is_partial) FROM coverage_line_events WHERE commit_hash = ? AND path IN ({placeholders}) GROUP BY path, line"
            );
            let mut values = Vec::<rusqlite::types::Value>::with_capacity(paths.len() + 1);
            values.push(rusqlite::types::Value::Text(commit_hash.to_string()));
            values.extend(paths.iter().cloned().map(rusqlite::types::Value::Text));
            let mut statement = self.conn.prepare(&sql)?;
            let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
                Ok(CoverageObservation {
                    path: row.get(0)?,
                    line: row.get::<_, i64>(1)?.max(1) as u32,
                    hits: row.get::<_, i64>(2)?.max(0) as u32,
                    is_partial: row.get::<_, i64>(3)? != 0,
                })
            })?;
            observations.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);
        }
        Ok(observations)
    }

    pub fn record_evidence_artifact_scope(&self, artifact: &EvidenceArtifactScope) -> Result<()> {
        let expected_lines =
            serde_json::to_string(&artifact.expected_lines.iter().collect::<Vec<_>>())?;
        self.conn.execute(
            "INSERT INTO evidence_artifact_scopes \
             (family, source, revision, selection_scope, mutant_corpus, test_set, complete, expected_lines_json) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
             ON CONFLICT(family, source, revision, selection_scope, mutant_corpus, test_set) DO UPDATE SET \
             complete = excluded.complete, expected_lines_json = excluded.expected_lines_json",
            params![artifact.family, artifact.source, artifact.scope.revision, artifact.scope.selection,
                artifact.scope.mutant_corpus, artifact.scope.test_set, if artifact.complete { 1 } else { 0 }, expected_lines],
        )?;
        Ok(())
    }

    pub fn scoped_coverage_artifact(
        &self,
        source: &str,
        scope: &EvidenceScopeFingerprint,
        paths: &[String],
    ) -> Result<Option<ScopedCoverageArtifact>> {
        let encoded = self
            .conn
            .query_row(
                "SELECT complete, expected_lines_json FROM evidence_artifact_scopes \
             WHERE family = 'coverage' AND source = ?1 AND revision = ?2 AND selection_scope = ?3 \
             AND mutant_corpus = ?4 AND test_set = ?5",
                params![
                    source,
                    scope.revision,
                    scope.selection,
                    scope.mutant_corpus,
                    scope.test_set
                ],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        let Some((complete, expected_lines_json)) = encoded else {
            return Ok(None);
        };
        let expected_lines = serde_json::from_str::<Vec<(String, u32)>>(&expected_lines_json)?
            .into_iter()
            .collect();
        let observations =
            self.coverage_observations_for_commit_paths_source(&scope.revision, paths, source)?;
        Ok(Some(ScopedCoverageArtifact {
            scope: scope.clone(),
            complete: complete != 0,
            expected_lines,
            observations,
        }))
    }

    /// Coverage has the common CI scope (revision, selection, test set), but
    /// no inherent mutation corpus. Accept exactly one matching family scope
    /// so a complete coverage run can compose with a separate mutation corpus.
    pub fn scoped_coverage_artifact_common(
        &self,
        source: &str,
        scope: &EvidenceScopeFingerprint,
        paths: &[String],
    ) -> Result<Option<ScopedCoverageArtifact>> {
        let candidates = self.evidence_scope_candidates("coverage", source, scope)?;
        let Some((artifact_scope, complete, expected_lines_json)) = candidates.into_iter().next()
        else {
            return Ok(None);
        };
        let expected_lines = serde_json::from_str::<Vec<(String, u32)>>(&expected_lines_json)?
            .into_iter()
            .collect();
        let observations = self.coverage_observations_for_commit_paths_source(
            &artifact_scope.revision,
            paths,
            source,
        )?;
        Ok(Some(ScopedCoverageArtifact {
            scope: artifact_scope,
            complete,
            expected_lines,
            observations,
        }))
    }

    fn coverage_observations_for_commit_paths_source(
        &self,
        commit_hash: &str,
        paths: &[String],
        source: &str,
    ) -> Result<Vec<CoverageObservation>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut observations = Vec::new();
        for paths in paths.chunks(499) {
            let placeholders = std::iter::repeat("?")
                .take(paths.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT path, line, hits, is_partial FROM coverage_line_events WHERE commit_hash = ? AND source = ? AND path IN ({placeholders})"
            );
            let mut values = vec![
                rusqlite::types::Value::Text(commit_hash.to_string()),
                rusqlite::types::Value::Text(source.to_string()),
            ];
            values.extend(paths.iter().cloned().map(rusqlite::types::Value::Text));
            let mut statement = self.conn.prepare(&sql)?;
            let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
                Ok(CoverageObservation {
                    path: row.get(0)?,
                    line: row.get::<_, i64>(1)?.max(1) as u32,
                    hits: row.get::<_, i64>(2)?.max(0) as u32,
                    is_partial: row.get::<_, i64>(3)? != 0,
                })
            })?;
            observations.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);
        }
        Ok(observations)
    }

    pub fn mutation_kill_observations_for_commit_paths(
        &self,
        commit_hash: &str,
        paths: &[String],
    ) -> Result<Vec<MutationKillObservation>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut observations = Vec::new();
        for paths in paths.chunks(500) {
            let placeholders = std::iter::repeat("?")
                .take(paths.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT DISTINCT path, line FROM test_exposure_events WHERE commit_hash = ? AND is_mutation_killed = 1 AND line IS NOT NULL AND path IN ({placeholders})"
            );
            let mut values = Vec::<rusqlite::types::Value>::with_capacity(paths.len() + 1);
            values.push(rusqlite::types::Value::Text(commit_hash.to_string()));
            values.extend(paths.iter().cloned().map(rusqlite::types::Value::Text));
            let mut statement = self.conn.prepare(&sql)?;
            let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
                Ok(MutationKillObservation {
                    path: row.get(0)?,
                    line: row.get::<_, i64>(1)?.max(1) as u32,
                })
            })?;
            observations.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);
        }
        Ok(observations)
    }

    /// Returns a mutation artifact only when its immutable scope was recorded
    /// as complete. Legacy and differently-scoped rows cannot make exact
    /// claims in a diff.
    pub fn scoped_mutation_artifact(
        &self,
        scope: &EvidenceScopeFingerprint,
        paths: &[String],
    ) -> Result<Option<ScopedMutationArtifact>> {
        if scope.mutant_corpus.trim().is_empty() || scope.mutant_corpus == "unknown" {
            return Ok(None);
        }
        let complete = self
            .conn
            .query_row(
                "SELECT complete FROM evidence_artifact_scopes WHERE family = 'mutation' \
                 AND source = ?1 AND revision = ?2 AND selection_scope = ?3 \
                 AND mutant_corpus = ?4 AND test_set = ?5",
                params![
                    scope.mutant_corpus,
                    scope.revision,
                    scope.selection,
                    scope.mutant_corpus,
                    scope.test_set
                ],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        let Some(complete) = complete else {
            return Ok(None);
        };
        let observations = self.mutation_kill_observations_for_commit_paths_corpus(
            &scope.revision,
            paths,
            &scope.mutant_corpus,
        )?;
        Ok(Some(ScopedMutationArtifact {
            scope: scope.clone(),
            complete: complete != 0,
            observations,
        }))
    }

    fn mutation_kill_observations_for_commit_paths_corpus(
        &self,
        commit_hash: &str,
        paths: &[String],
        mutation_corpus: &str,
    ) -> Result<Vec<MutationKillObservation>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut observations = Vec::new();
        for paths in paths.chunks(499) {
            let placeholders = std::iter::repeat("?")
                .take(paths.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT DISTINCT path, line FROM test_exposure_events WHERE commit_hash = ? \
                 AND mutation_corpus = ? AND is_mutation_killed = 1 AND line IS NOT NULL \
                 AND path IN ({placeholders})"
            );
            let mut values = vec![
                rusqlite::types::Value::Text(commit_hash.to_string()),
                rusqlite::types::Value::Text(mutation_corpus.to_string()),
            ];
            values.extend(paths.iter().cloned().map(rusqlite::types::Value::Text));
            let mut statement = self.conn.prepare(&sql)?;
            let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
                Ok(MutationKillObservation {
                    path: row.get(0)?,
                    line: row.get::<_, i64>(1)?.max(1) as u32,
                })
            })?;
            observations.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);
        }
        Ok(observations)
    }

    /// Reads only SARIF rows that declare the requested immutable revision.
    /// The diff layer treats these as partial, because a stored artifact does
    /// not itself establish analyzer/configuration completeness.
    pub fn sarif_observations_for_commit_paths(
        &self,
        commit_hash: &str,
        paths: &[String],
    ) -> Result<Vec<SarifObservation>> {
        self.sarif_observations_for_commit_paths_source(commit_hash, paths, None)
    }

    pub fn scoped_sarif_observations(
        &self,
        source: &str,
        scope: &EvidenceScopeFingerprint,
        paths: &[String],
    ) -> Result<Option<Vec<SarifObservation>>> {
        let complete = self.conn.query_row(
            "SELECT complete FROM evidence_artifact_scopes WHERE family = 'sarif' AND source = ?1 \
             AND revision = ?2 AND selection_scope = ?3 AND mutant_corpus = ?4 AND test_set = ?5",
            params![source, scope.revision, scope.selection, scope.mutant_corpus, scope.test_set],
            |row| row.get::<_, i64>(0),
        ).optional()?;
        (complete == Some(1))
            .then(|| {
                self.sarif_observations_for_commit_paths_source(
                    &scope.revision,
                    paths,
                    Some(source),
                )
            })
            .transpose()
    }

    /// SARIF analysis is scoped by the shared revision/selection/test set.
    /// It must not inherit mutation-corpus identity merely because mutation
    /// evidence is also present in the same profile.
    pub fn scoped_sarif_observations_common(
        &self,
        source: &str,
        scope: &EvidenceScopeFingerprint,
        paths: &[String],
    ) -> Result<Option<Vec<SarifObservation>>> {
        let candidates = self.evidence_scope_candidates("sarif", source, scope)?;
        let Some((_artifact_scope, complete, _)) = candidates.into_iter().next() else {
            return Ok(None);
        };
        complete
            .then(|| {
                self.sarif_observations_for_commit_paths_source(
                    &scope.revision,
                    paths,
                    Some(source),
                )
            })
            .transpose()
    }

    fn evidence_scope_candidates(
        &self,
        family: &str,
        source: &str,
        scope: &EvidenceScopeFingerprint,
    ) -> Result<Vec<(EvidenceScopeFingerprint, bool, String)>> {
        let mut statement = self.conn.prepare(
            "SELECT mutant_corpus, complete, expected_lines_json FROM evidence_artifact_scopes \
             WHERE family = ?1 AND source = ?2 AND revision = ?3 AND selection_scope = ?4 AND test_set = ?5",
        )?;
        let rows = statement.query_map(
            params![
                family,
                source,
                scope.revision,
                scope.selection,
                scope.test_set
            ],
            |row| {
                Ok((
                    EvidenceScopeFingerprint {
                        revision: scope.revision.clone(),
                        selection: scope.selection.clone(),
                        mutant_corpus: row.get(0)?,
                        test_set: scope.test_set.clone(),
                    },
                    row.get::<_, i64>(1)? != 0,
                    row.get(2)?,
                ))
            },
        )?;
        let candidates = rows.collect::<std::result::Result<Vec<_>, _>>()?;
        if candidates.len() > 1 {
            anyhow::bail!(
                "multiple {family} evidence scopes match source {source:?}; choose a distinct source or configure one family scope"
            );
        }
        Ok(candidates)
    }

    /// Returns whether this source has declared any scoped SARIF artifact.
    /// Callers use this to distinguish absent legacy evidence from evidence
    /// that exists but belongs to another immutable comparison scope.
    pub fn has_scoped_sarif_source(&self, source: &str) -> Result<bool> {
        self.conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM evidence_artifact_scopes WHERE family = 'sarif' AND source = ?1)",
                params![source],
                |row| row.get::<_, i64>(0),
            )
            .map(|exists| exists != 0)
            .map_err(Into::into)
    }

    pub fn sarif_identities_for_commit_source(
        &self,
        commit_hash: &str,
        source: &str,
    ) -> Result<HashSet<String>> {
        let mut statement = self.conn.prepare(
            "SELECT source, tool_name, rule_id, fingerprint FROM sarif_findings WHERE commit_hash = ?1 AND source = ?2",
        )?;
        let rows = statement.query_map(params![commit_hash, source], |row| {
            Ok(format!(
                "{}\u{1f}{}\u{1f}{}\u{1f}{}",
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?
            ))
        })?;
        Ok(rows.collect::<std::result::Result<HashSet<_>, _>>()?)
    }

    fn sarif_observations_for_commit_paths_source(
        &self,
        commit_hash: &str,
        paths: &[String],
        source: Option<&str>,
    ) -> Result<Vec<SarifObservation>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut observations = Vec::new();
        for paths in paths.chunks(500) {
            let placeholders = std::iter::repeat("?")
                .take(paths.len())
                .collect::<Vec<_>>()
                .join(", ");
            let source_filter = source.map(|_| " AND source = ?").unwrap_or("");
            let sql = format!(
                "SELECT path, source, tool_name, rule_id, level, category, message, fingerprint, properties_json, start_line, \
                 COALESCE(end_line, start_line) FROM sarif_findings \
                 WHERE commit_hash = ?{source_filter} AND path IN ({placeholders}) \
                 ORDER BY path, start_line, rule_id, finding_key"
            );
            let mut values = Vec::<rusqlite::types::Value>::with_capacity(paths.len() + 2);
            values.push(rusqlite::types::Value::Text(commit_hash.to_string()));
            if let Some(source) = source {
                values.push(rusqlite::types::Value::Text(source.to_string()));
            }
            values.extend(paths.iter().cloned().map(rusqlite::types::Value::Text));
            let mut statement = self.conn.prepare(&sql)?;
            let rows = statement.query_map(rusqlite::params_from_iter(values), |row| {
                let properties_json: String = row.get(8)?;
                let tier = Self::sarif_tier(&properties_json);
                Ok(SarifObservation {
                    path: row.get(0)?,
                    finding: SarifFindingSummary {
                        source: row.get(1)?,
                        tool: row.get(2)?,
                        rule_id: row.get(3)?,
                        level: row.get(4)?,
                        category: row.get(5)?,
                        message: row.get(6)?,
                        fingerprint: row.get(7)?,
                        tier,
                        tier_one: tier == Some(1),
                        status: "partial".into(),
                        provenance: BTreeMap::new(),
                        proof_boundary: Vec::new(),
                        start_line: row.get::<_, i64>(9)?.max(1) as u32,
                        end_line: row.get::<_, i64>(10)?.max(1) as u32,
                    },
                })
            })?;
            observations.extend(rows.collect::<std::result::Result<Vec<_>, _>>()?);
        }
        Ok(observations)
    }

    fn sarif_tier(properties_json: &str) -> Option<u8> {
        serde_json::from_str::<serde_json::Value>(properties_json)
            .ok()
            .and_then(|value| {
                value
                    .get("tier")
                    .and_then(serde_json::Value::as_i64)
                    .or_else(|| value.get("risk_tier").and_then(serde_json::Value::as_i64))
            })
            .and_then(|tier| u8::try_from(tier).ok())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record_coverage_line_with_source(
        &self,
        commit_hash: &str,
        timestamp: i64,
        path: &str,
        line: u32,
        hits: u32,
        is_partial: bool,
        source: &str,
    ) -> Result<bool> {
        self.record_coverage_line_with_details(
            commit_hash,
            timestamp,
            path,
            line,
            hits,
            is_partial,
            None,
            source,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record_coverage_line_with_details(
        &self,
        commit_hash: &str,
        timestamp: i64,
        path: &str,
        line: u32,
        hits: u32,
        is_partial: bool,
        coverage_percent: Option<f64>,
        source: &str,
    ) -> Result<bool> {
        let changed = self
            .conn
            .prepare_cached(include_str!(
                "../../sql/storage/record_coverage_line_with_details.sql"
            ))?
            .execute(params![
                commit_hash,
                timestamp,
                path,
                line,
                hits,
                if is_partial { 1 } else { 0 },
                coverage_percent,
                source
            ])?;
        Ok(changed > 0)
    }

    pub fn record_coverage_lines_bulk(&self, lines: &[CoverageLineBulk]) -> Result<usize> {
        if lines.is_empty() {
            return Ok(0);
        }

        let chunk_size = 500;
        let mut total_changed = 0;

        for chunk in lines.chunks(chunk_size) {
            let mut sql = String::from(
                "INSERT INTO coverage_line_events (commit_hash, timestamp, path, line, hits, is_partial, coverage_percent, source) VALUES "
            );

            for i in 0..chunk.len() {
                if i > 0 {
                    sql.push_str(", ");
                }
                sql.push_str("(?, ?, ?, ?, ?, ?, ?, ?)");
            }

            sql.push_str(
                " ON CONFLICT(commit_hash, path, line, source) DO UPDATE SET \
                timestamp = MAX(coverage_line_events.timestamp, excluded.timestamp), \
                hits = MAX(coverage_line_events.hits, excluded.hits), \
                is_partial = MAX(coverage_line_events.is_partial, excluded.is_partial), \
                coverage_percent = COALESCE(excluded.coverage_percent, coverage_line_events.coverage_percent) \
                WHERE excluded.timestamp > coverage_line_events.timestamp \
                   OR excluded.hits > coverage_line_events.hits \
                   OR excluded.is_partial > coverage_line_events.is_partial \
                   OR COALESCE(excluded.coverage_percent, -1) <> COALESCE(coverage_line_events.coverage_percent, -1)"
            );

            let mut stmt = self.conn.prepare_cached(&sql)?;

            let mut params: Vec<rusqlite::types::Value> = Vec::with_capacity(chunk.len() * 8);
            for row in chunk {
                params.push(rusqlite::types::Value::Text(row.commit_hash.clone()));
                params.push(rusqlite::types::Value::Integer(row.timestamp));
                params.push(rusqlite::types::Value::Text(row.path.clone()));
                params.push(rusqlite::types::Value::Integer(row.line as i64));
                params.push(rusqlite::types::Value::Integer(row.hits as i64));
                params.push(rusqlite::types::Value::Integer(if row.is_partial {
                    1
                } else {
                    0
                }));
                if let Some(pct) = row.coverage_percent {
                    params.push(rusqlite::types::Value::Real(pct));
                } else {
                    params.push(rusqlite::types::Value::Null);
                }
                params.push(rusqlite::types::Value::Text(row.source.clone()));
            }

            let param_refs: Vec<&dyn rusqlite::ToSql> =
                params.iter().map(|p| p as &dyn rusqlite::ToSql).collect();

            let changed = stmt.execute(&param_refs[..])?;
            total_changed += changed;
        }

        Ok(total_changed)
    }

    fn current_quality_value(
        &self,
        unit_id: &str,
        metric: QualityMetric,
    ) -> Result<(&'static str, Option<f64>)> {
        let column = match metric {
            QualityMetric::LineCoverage => "current_line_cov",
            QualityMetric::IntegrationCoverage => "current_integration_cov",
            QualityMetric::MutantCoverage => "current_mutant_cov",
            QualityMetric::GateStatus => "is_hard_gated",
        };
        let sql = format!("SELECT {column} FROM logical_units WHERE id = ?1");
        let mut stmt = self.conn.prepare_cached(&sql)?;
        let mut rows = stmt.query(params![unit_id])?;
        Ok((column, rows.next()?.map(|row| row.get(0)).transpose()?))
    }

    pub fn insert_crash_event(&self, event: &CrashEvent) -> Result<bool> {
        let mut stmt = self
            .conn
            .prepare(include_str!("../../sql/storage/insert_crash_event.sql"))?;
        let existing = stmt
            .query_row(
                params![
                    event.unit_id,
                    event.commit_hash,
                    event.error_class,
                    event.provider_id,
                    event.path,
                    event.line,
                    event.function
                ],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?;
        if let Some((id, timestamp, is_verified)) = existing {
            let next_verified = if event.is_verified { 1 } else { 0 };
            if timestamp == event.timestamp && is_verified == next_verified {
                return Ok(false);
            }
            self.conn.execute(
                "UPDATE crash_events SET timestamp = ?2, is_verified = ?3 WHERE id = ?1",
                params![id, event.timestamp, next_verified],
            )?;
            return Ok(true);
        }

        self.conn.execute(
            include_str!("../../sql/storage/insert_crash_event_2.sql"),
            params![
                event.unit_id,
                event.commit_hash,
                event.timestamp,
                event.error_class,
                event.provider_id,
                if event.is_verified { 1 } else { 0 },
                event.path,
                event.line,
                event.function
            ],
        )?;
        Ok(true)
    }

    pub fn delete_crash_events_for_commit(&self, commit_hash: &str) -> Result<usize> {
        Ok(self.conn.execute(
            "DELETE FROM crash_events WHERE commit_hash = ?1",
            params![commit_hash],
        )?)
    }

    pub fn insert_test_exposure_event(&self, event: &TestExposureEvent) -> Result<bool> {
        let changed = self.conn.execute(
            include_str!("../../sql/storage/insert_test_exposure_event.sql"),
            params![
                event.unit_id,
                event.commit_hash,
                event.timestamp,
                event.path,
                event.function,
                event.line.map(i64::from),
                event.branch_id,
                event.test_id,
                event.test_type,
                event.mutation_status,
                event.mutation_kind,
                event.mutation_corpus,
                if event.is_mutation_verified { 1 } else { 0 },
                if event.is_mutation_killed { 1 } else { 0 },
                if event.is_verified { 1 } else { 0 },
                event.payload_json
            ],
        )?;
        if changed > 0 {
            self.refresh_test_exposure_summary(&event.unit_id)?;
        }
        Ok(changed > 0)
    }

    /// Self-heal the per-stage new-test timing history table (idempotent).
    fn ensure_test_stage_timings_table(&self) -> Result<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS test_stage_timings (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               commit_hash TEXT NOT NULL,
               stage TEXT NOT NULL,
               test_set TEXT NOT NULL,
               elapsed_ms REAL NOT NULL,
               stddev_ms REAL NOT NULL DEFAULT 0,
               n_samples INTEGER NOT NULL DEFAULT 1,
               timestamp INTEGER NOT NULL DEFAULT 0,
               UNIQUE(commit_hash, stage, test_set)
             );
             CREATE INDEX IF NOT EXISTS idx_test_stage_timings_lookup
               ON test_stage_timings(stage, test_set, timestamp);",
        )?;
        self.ensure_column("test_stage_timings", "stddev_ms", "REAL NOT NULL DEFAULT 0")?;
        Ok(())
    }

    /// Record the measured new-test time for a stage at a commit (upsert).
    /// `n_samples` is how many repeat runs `elapsed_ms` averages, feeding the
    /// confidence interval later.
    pub fn record_stage_timing(
        &self,
        commit_hash: &str,
        stage: &str,
        test_set: &str,
        elapsed_ms: f64,
        stddev_ms: f64,
        n_samples: i64,
        timestamp: i64,
    ) -> Result<()> {
        self.ensure_test_stage_timings_table()?;
        self.conn.execute(
            "INSERT INTO test_stage_timings \
               (commit_hash, stage, test_set, elapsed_ms, stddev_ms, n_samples, timestamp) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
             ON CONFLICT(commit_hash, stage, test_set) DO UPDATE SET \
               elapsed_ms = ?4, stddev_ms = ?5, n_samples = ?6, timestamp = ?7",
            params![commit_hash, stage, test_set, elapsed_ms, stddev_ms, n_samples, timestamp],
        )?;
        Ok(())
    }

    /// The last `window` per-commit stage times for a (stage, test_set),
    /// excluding `exclude_commit` - the baseline the current run compares against.
    pub fn stage_timing_history(
        &self,
        stage: &str,
        test_set: &str,
        window: usize,
        exclude_commit: &str,
    ) -> Result<Vec<f64>> {
        self.ensure_test_stage_timings_table()?;
        let mut stmt = self.conn.prepare(
            "SELECT elapsed_ms FROM test_stage_timings \
             WHERE stage = ?1 AND test_set = ?2 AND commit_hash <> ?3 \
             ORDER BY timestamp DESC, id DESC LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![stage, test_set, exclude_commit, window as i64],
            |row| row.get::<_, f64>(0),
        )?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// The recorded new-test time for a specific commit/stage/test_set, if any.
    /// The recorded new-test measurement `(mean_ms, stddev_ms, n_samples)` for a
    /// commit/stage/test_set, if any.
    pub fn stage_timing_for_commit(
        &self,
        commit_hash: &str,
        stage: &str,
        test_set: &str,
    ) -> Result<Option<(f64, f64, i64)>> {
        self.ensure_test_stage_timings_table()?;
        Ok(self
            .conn
            .query_row(
                "SELECT elapsed_ms, stddev_ms, n_samples FROM test_stage_timings \
                 WHERE commit_hash = ?1 AND stage = ?2 AND test_set = ?3",
                params![commit_hash, stage, test_set],
                |row| Ok((row.get::<_, f64>(0)?, row.get::<_, f64>(1)?, row.get::<_, i64>(2)?)),
            )
            .optional()?)
    }

    /// Self-heal the Big-O columns on `logical_units`. `Storage::open` only
    /// initializes brand-new files, so existing databases need this on every
    /// Big-O read/write path (idempotent). Status is complete | partial |
    /// unknown (unknown = no analysis).
    pub fn ensure_big_o_columns(&self) -> Result<()> {
        self.ensure_logical_unit_column("big_o_time", "TEXT DEFAULT ''")?;
        self.ensure_logical_unit_column("big_o_time_status", "TEXT DEFAULT 'unknown'")?;
        self.ensure_logical_unit_column("big_o_space", "TEXT DEFAULT ''")?;
        self.ensure_logical_unit_column("big_o_space_status", "TEXT DEFAULT 'unknown'")?;
        Ok(())
    }

    /// Record a function's Big-O time/space complexity (from the architecture
    /// graph) on its logical unit. `status` is complete | partial | unknown.
    pub fn update_logical_unit_big_o(
        &self,
        unit_id: &str,
        time: &str,
        time_status: &str,
        space: &str,
        space_status: &str,
    ) -> Result<()> {
        self.ensure_big_o_columns()?;
        self.conn.execute(
            "UPDATE logical_units SET big_o_time = ?2, big_o_time_status = ?3, \
             big_o_space = ?4, big_o_space_status = ?5 WHERE id = ?1",
            params![unit_id, time, time_status, space, space_status],
        )?;
        Ok(())
    }

    /// The Big-O complexity recorded for a logical unit: (time, time_status,
    /// space, space_status). `unknown` status means no analysis is available.
    pub fn logical_unit_big_o(&self, unit_id: &str) -> Result<(String, String, String, String)> {
        Ok(self
            .conn
            .query_row(
                "SELECT big_o_time, big_o_time_status, big_o_space, big_o_space_status \
                 FROM logical_units WHERE id = ?1",
                params![unit_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?
            .unwrap_or_else(|| {
                (
                    String::new(),
                    "unknown".into(),
                    String::new(),
                    "unknown".into(),
                )
            }))
    }

    /// Big-O for a function identified by its current file path and name, for
    /// the diff function box. Returns unknown when no unit matches or none has
    /// analysis. Matches on the unit's latest-event path (or original path).
    pub fn function_big_o(
        &self,
        path: &str,
        name: &str,
    ) -> Result<(String, String, String, String)> {
        self.ensure_big_o_columns()?;
        // The diff's group name and the stored unit name may differ in
        // qualification (`constant` vs `Calc.constant`/`Calc#constant`), so match
        // the leaf with a suffix LIKE as the reconciler does.
        let leaf = name.rsplit(['.', ':', '#']).next().unwrap_or(name);
        let suffix = format!("%{leaf}");
        Ok(self
            .conn
            .query_row(
                "SELECT u.big_o_time, u.big_o_time_status, u.big_o_space, u.big_o_space_status \
                 FROM logical_units u \
                 LEFT JOIN (SELECT unit_id, path, \
                              ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY timestamp DESC, id DESC) rk \
                            FROM events) e ON e.unit_id = u.id AND e.rk = 1 \
                 WHERE (u.name = ?2 OR u.name = ?4 OR u.name LIKE ?3) \
                   AND COALESCE(e.path, u.original_path) = ?1 \
                   AND (u.big_o_time_status <> 'unknown' OR u.big_o_space_status <> 'unknown') \
                 LIMIT 1",
                params![path, name, suffix, leaf],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?
            .unwrap_or_else(|| {
                (
                    String::new(),
                    "unknown".into(),
                    String::new(),
                    "unknown".into(),
                )
            }))
    }

    /// Aggregate `test_exposure_events` for one commit into a per-test inventory
    /// for the diff "Tests" section. Test-level attributes (the test's own file
    /// and definition span, pending status, and the set of mutants it killed)
    /// ride in `payload_json` — runners that don't emit them degrade gracefully
    /// (no def-span → never "changed"; no killed ids → falls back to the killed
    /// coverage lines as a coarse mutant identity for redundancy).
    pub fn test_inventory_for_commit(
        &self,
        commit_hash: &str,
    ) -> Result<Vec<crate::test_summary::TestInventoryRow>> {
        use std::collections::{BTreeMap, BTreeSet};
        let mut stmt = self.conn.prepare(
            "SELECT test_id, test_type, path, line, is_mutation_verified, \
                    mutation_status, is_mutation_killed, payload_json \
             FROM test_exposure_events WHERE commit_hash = ?1",
        )?;
        struct Agg {
            test_type: String,
            lines: BTreeSet<(String, i64)>,
            had_mutation: bool,
            killed: BTreeSet<String>,
            payload: String,
        }
        let mut map: BTreeMap<String, Agg> = BTreeMap::new();
        let rows = stmt.query_map([commit_hash], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<i64>>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, Option<String>>(5)?,
                r.get::<_, i64>(6)?,
                r.get::<_, String>(7)?,
            ))
        })?;
        for row in rows {
            let (test_id, test_type, path, line, verified, status, killed, payload) = row?;
            let agg = map.entry(test_id).or_insert_with(|| Agg {
                test_type,
                lines: BTreeSet::new(),
                had_mutation: false,
                killed: BTreeSet::new(),
                payload: "{}".to_string(),
            });
            if let Some(l) = line {
                agg.lines.insert((path.clone(), l));
            }
            if verified == 1 || status.is_some() {
                agg.had_mutation = true;
            }
            // Coarse fallback mutant identity when the runner gives no id: the
            // killed line. Overwritten below if payload carries explicit ids.
            if killed == 1 {
                if let Some(l) = line {
                    agg.killed.insert(format!("{path}:{l}"));
                }
            }
            if payload.len() > agg.payload.len() {
                agg.payload = payload;
            }
        }
        Ok(map
            .into_iter()
            .map(|(test_id, agg)| {
                let meta = crate::test_summary::TestPayloadMeta::parse(&agg.payload);
                let killed = if meta.killed_mutants.is_empty() {
                    agg.killed
                } else {
                    meta.killed_mutants
                };
                // Fall back to a covered file's language when the runner did not
                // emit the test's own path.
                let language = if meta.language == "unknown" {
                    agg.lines
                        .iter()
                        .next()
                        .map(|(p, _)| crate::test_summary::language_from_path(p))
                        .unwrap_or_else(|| "unknown".to_string())
                } else {
                    meta.language
                };
                crate::test_summary::TestInventoryRow {
                    test_id,
                    test_set: agg.test_type,
                    language,
                    test_path: meta.test_path,
                    start_line: meta.start_line,
                    end_line: meta.end_line,
                    pending: meta.pending,
                    covered_lines: agg.lines.len(),
                    had_mutation: agg.had_mutation,
                    killed_mutants: killed,
                }
            })
            .collect())
    }

    /// unit_hotness postdates many deployed databases and Storage::open only
    /// initializes brand-new files, so every hotness path self-heals the
    /// table (idempotent, matching the ensure_column migration style).
    fn ensure_unit_hotness_table(&self) -> Result<()> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS unit_hotness (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               path TEXT,
               function TEXT NOT NULL,
               line INTEGER,
               flat_share REAL NOT NULL DEFAULT 0,
               cum_share REAL NOT NULL DEFAULT 0,
               tier TEXT NOT NULL CHECK (tier IN ('critical', 'warm', 'cold')),
               source TEXT NOT NULL,
               commit_hash TEXT,
               is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
               resolution TEXT NOT NULL DEFAULT 'declared'
             );
             CREATE INDEX IF NOT EXISTS idx_unit_hotness_path ON unit_hotness(path, is_active);
             CREATE INDEX IF NOT EXISTS idx_unit_hotness_source ON unit_hotness(source, is_active);",
        )?;
        self.ensure_column(
            "unit_hotness",
            "resolution",
            "TEXT NOT NULL DEFAULT 'declared'",
        )?;
        Ok(())
    }

    /// (name, path, start_line) for every logical unit: the symbol inventory
    /// hotness resolution matches profiler frames against.
    pub fn unit_symbol_index(&self) -> Result<Vec<(String, String, i64)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT name, original_path, start_line FROM logical_units")?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn deactivate_hotness_for_source(&self, source: &str) -> Result<usize> {
        self.ensure_unit_hotness_table()?;
        Ok(self.conn.execute(
            "UPDATE unit_hotness SET is_active = 0 WHERE source = ?1 AND is_active = 1",
            params![source],
        )?)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn insert_unit_hotness(
        &self,
        path: Option<&str>,
        function: &str,
        line: Option<i64>,
        flat_share: f64,
        cum_share: f64,
        tier: &str,
        source: &str,
        commit_hash: Option<&str>,
        resolution: &str,
    ) -> Result<()> {
        self.ensure_unit_hotness_table()?;
        self.conn.execute(
            include_str!("../../sql/storage/insert_unit_hotness.sql"),
            params![
                path,
                function,
                line,
                flat_share,
                cum_share,
                tier,
                source,
                commit_hash,
                resolution
            ],
        )?;
        Ok(())
    }

    pub fn active_hotness(&self) -> Result<Vec<crate::model::HotnessRow>> {
        self.ensure_unit_hotness_table()?;
        let mut stmt = self
            .conn
            .prepare(include_str!("../../sql/core/top_hotness.sql"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(crate::model::HotnessRow {
                    path: row.get(0)?,
                    function: row.get(1)?,
                    line: row.get(2)?,
                    flat_share: row.get(3)?,
                    cum_share: row.get(4)?,
                    tier: row.get(5)?,
                    source: row.get(6)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn hotness_for_path(&self, path: &str) -> Result<Vec<crate::model::HotnessRow>> {
        self.ensure_unit_hotness_table()?;
        let mut stmt = self
            .conn
            .prepare(APPLY_HOTNESS_SQL)?;
        let path_owned = path.to_string();
        let rows = stmt
            .query_map(params![path], move |row| {
                Ok(crate::model::HotnessRow {
                    path: Some(path_owned.clone()),
                    function: row.get(0)?,
                    line: row.get(1)?,
                    flat_share: row.get(2)?,
                    cum_share: row.get(3)?,
                    tier: row.get(4)?,
                    source: row.get(5)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn deactivate_active_hazards(&self, language: &str) -> Result<usize> {
        Ok(self.conn.execute(
            "UPDATE unit_hazards SET is_active = 0 WHERE language = ?1 AND is_active = 1",
            params![language],
        )?)
    }

    pub fn insert_hazard_event(&self, event: &HazardEvent) -> Result<()> {
        self.conn.execute(
            include_str!("../../sql/storage/insert_hazard_event.sql"),
            params![
                event.unit_id,
                event.language,
                event.hazard_type,
                event.required_evidence,
                event.path,
                event.line,
                event.symbol,
                event.source,
                event.detected_at_hash,
                if event.is_active { 1 } else { 0 },
                event.payload_json
            ],
        )?;
        Ok(())
    }

    fn refresh_test_exposure_summary(&self, unit_id: &str) -> Result<()> {
        let mut latest_stmt = self.conn.prepare(include_str!(
            "../../sql/storage/refresh_test_exposure_summary.sql"
        ))?;
        let mut latest_rows = latest_stmt.query(params![unit_id])?;
        let Some(latest_row) = latest_rows.next()? else {
            return Ok(());
        };
        let latest_commit: String = latest_row.get(0)?;
        let latest_timestamp: i64 = latest_row.get(1)?;

        let distinct_tests: i64 = self.conn.query_row(
            include_str!("../../sql/storage/refresh_test_exposure_summary_2.sql"),
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mutant_verified: i64 = self.conn.query_row(
            include_str!("../../sql/storage/refresh_test_exposure_summary_3.sql"),
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mutant_killed: i64 = self.conn.query_row(
            include_str!("../../sql/storage/refresh_test_exposure_summary_4.sql"),
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mut type_stmt = self.conn.prepare(include_str!(
            "../../sql/storage/refresh_test_exposure_summary_5.sql"
        ))?;
        let type_rows = type_stmt.query_map(params![unit_id, latest_commit], |row| {
            row.get::<_, String>(0)
        })?;
        let test_types = type_rows.collect::<Result<Vec<_>, _>>()?.join(",");

        self.conn.execute(
            include_str!("../../sql/storage/refresh_test_exposure_summary_6.sql"),
            params![
                unit_id,
                distinct_tests,
                test_types,
                mutant_verified,
                mutant_killed,
                latest_timestamp
            ],
        )?;
        Ok(())
    }

    pub fn count_rows(&self, table: &str) -> Result<i64> {
        let sql = format!("SELECT COUNT(*) FROM {}", checked_table(table)?);
        Ok(self.conn.query_row(&sql, [], |row| row.get(0))?)
    }

    pub fn refresh_ui_summaries(&self) -> Result<()> {
        self.begin_transaction()?;
        let result = self
            .conn
            .execute_batch(include_str!("../../sql/storage/refresh_ui_summaries.sql"));
        if let Err(error) = result {
            let _ = self.rollback_transaction();
            return Err(error.into());
        }
        self.commit_transaction()?;
        Ok(())
    }

    pub fn top_units(&self, limit: usize, only_prefixes: &[String]) -> Result<Vec<UnitSummary>> {
        let mut sql = String::new();
        sql.push_str(
            r#"
            WITH db_clock AS (
              SELECT COALESCE(MAX(timestamp), 0) AS observed_at
              FROM (
                SELECT timestamp FROM metadata
                UNION ALL SELECT timestamp FROM events
                UNION ALL SELECT timestamp FROM quality_events
                UNION ALL SELECT timestamp FROM crash_events
                UNION ALL SELECT timestamp FROM test_exposure_events
              )
            ),
            latest_events AS (
              SELECT unit_id, path
              FROM (
                SELECT unit_id, path,
                       ROW_NUMBER() OVER (
                         PARTITION BY unit_id
                         ORDER BY timestamp DESC, id DESC
                       ) AS rank
                FROM events
              )
              WHERE rank = 1
            ),
            mutant_runs AS (
              SELECT unit_id, MAX(timestamp) AS last_mutant_run_at
              FROM test_exposure_events
              WHERE is_mutation_verified = 1 OR is_mutation_killed = 1
              GROUP BY unit_id
            ),
            reopened AS (
              SELECT c.unit_id, COUNT(DISTINCT c.id) AS reopened_count
              FROM crash_events c
              WHERE EXISTS (
                SELECT 1
                FROM events fix
                WHERE fix.unit_id = c.unit_id
                  AND fix.event_type = 'FIX'
                  AND fix.semantic_change = 1
                  AND fix.path = c.path
                  AND c.line BETWEEN fix.start_line AND fix.end_line
                  AND c.timestamp > fix.timestamp
              )
              GROUP BY c.unit_id
            )
        "#,
        );

        let raw_summaries: Vec<UnitSummary> = if only_prefixes.is_empty() {
            sql.push_str(r#"
                SELECT
                  u.id,
                  u.name,
                  u.type,
                  u.original_path,
                  COALESCE(le.path, u.original_path) AS current_path,
                  COUNT(e.id) AS total_events,
                  SUM(CASE WHEN e.event_type = 'CHANGE' THEN 1 ELSE 0 END) AS changes,
                  SUM(CASE WHEN e.event_type = 'MOVE' THEN 1 ELSE 0 END) AS moves,
                  SUM(CASE WHEN e.event_type = 'FIX' THEN 1 ELSE 0 END) AS fixes,
                  u.current_distinct_tests,
                  u.current_test_types,
                  u.current_mutant_verified_tests,
                  u.current_mutant_killed_tests,
                  u.last_test_exposure_at,
                  COALESCE(m.last_mutant_run_at, 0) AS last_mutant_run_at,
                  MAX(CASE WHEN e.event_type = 'FIX' AND e.semantic_change = 1 THEN e.timestamp ELSE 0 END) AS latest_fix_at,
                  MAX(CASE WHEN e.event_type = 'CHANGE' AND e.semantic_change = 1 THEN e.timestamp ELSE 0 END) AS latest_change_at,
                  SUM(CASE
                    WHEN u.last_test_exposure_at > 0
                     AND e.event_type = 'FIX'
                     AND e.semantic_change = 1
                     AND e.timestamp > u.last_test_exposure_at
                    THEN 1 ELSE 0
                  END) AS fixes_after_test_exposure,
                  SUM(CASE
                    WHEN u.last_test_exposure_at > 0
                     AND e.event_type = 'CHANGE'
                     AND e.semantic_change = 1
                     AND e.timestamp > u.last_test_exposure_at
                    THEN 1 ELSE 0
                  END) AS changes_after_test_exposure,
                  SUM(CASE
                    WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                     AND e.semantic_change = 1
                     AND e.event_type IN ('FIX', 'CHANGE')
                     AND e.timestamp > m.last_mutant_run_at
                    THEN 1 ELSE 0
                  END) AS semantic_changes_after_mutant_run,
                  CASE
                    WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                     AND clock.observed_at > m.last_mutant_run_at
                    THEN clock.observed_at - m.last_mutant_run_at
                    ELSE 0
                  END AS verification_stale_seconds,
                  COALESCE(r.reopened_count, 0) AS reopened_count
                FROM logical_units u
                LEFT JOIN latest_events le ON le.unit_id = u.id
                JOIN events e ON e.unit_id = u.id
                LEFT JOIN mutant_runs m ON m.unit_id = u.id
                LEFT JOIN reopened r ON r.unit_id = u.id
                CROSS JOIN db_clock clock
                GROUP BY u.id, u.name, u.type, u.original_path,
                         u.current_distinct_tests, u.current_test_types,
                         u.current_mutant_verified_tests,
                         u.current_mutant_killed_tests, u.last_test_exposure_at,
                         m.last_mutant_run_at, r.reopened_count, clock.observed_at, le.path
            "#);
            let mut stmt = self.conn.prepare(&sql)?;
            let rows = stmt.query_map([], |row| {
                let verification_stale_seconds = row.get::<_, i64>(20)?;
                Ok(UnitSummary {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    kind: row.get(2)?,
                    original_path: row.get(3)?,
                    current_path: row.get(4)?,
                    total_events: row.get(5)?,
                    changes: row.get(6)?,
                    moves: row.get(7)?,
                    fixes: row.get(8)?,
                    current_distinct_tests: row.get(9)?,
                    current_test_types: row.get(10)?,
                    current_mutant_verified_tests: row.get(11)?,
                    current_mutant_killed_tests: row.get(12)?,
                    last_test_exposure_at: row.get(13)?,
                    last_mutant_run_at: row.get(14)?,
                    latest_fix_at: row.get(15)?,
                    latest_change_at: row.get(16)?,
                    fixes_after_test_exposure: row.get(17)?,
                    changes_after_test_exposure: row.get(18)?,
                    semantic_changes_after_mutant_run: row.get(19)?,
                    verification_stale_seconds,
                    verification_staleness_score: verification_stale_seconds as f64 / 86_400.0,
                    reopened_count: row.get(21)?,
                    risk_score: 0.0,
                    big_o_time: String::new(),
                    big_o_time_status: "unknown".into(),
                    big_o_space: String::new(),
                    big_o_space_status: "unknown".into(),
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        } else {
            sql.push_str(
                r#"
                , filtered_units AS (
                  SELECT u.*,
                         COALESCE(le.path, u.original_path) AS current_path
                  FROM logical_units u
                  LEFT JOIN latest_events le ON le.unit_id = u.id
                  WHERE 
            "#,
            );
            for i in 0..only_prefixes.len() {
                if i > 0 {
                    sql.push_str(" OR ");
                }
                sql.push_str(&format!("current_path LIKE ?{}", i + 1));
            }
            sql.push_str(r#"
                )
                SELECT
                  u.id,
                  u.name,
                  u.type,
                  u.original_path,
                  u.current_path,
                  COUNT(e.id) AS total_events,
                  SUM(CASE WHEN e.event_type = 'CHANGE' THEN 1 ELSE 0 END) AS changes,
                  SUM(CASE WHEN e.event_type = 'MOVE' THEN 1 ELSE 0 END) AS moves,
                  SUM(CASE WHEN e.event_type = 'FIX' THEN 1 ELSE 0 END) AS fixes,
                  u.current_distinct_tests,
                  u.current_test_types,
                  u.current_mutant_verified_tests,
                  u.current_mutant_killed_tests,
                  u.last_test_exposure_at,
                  COALESCE(m.last_mutant_run_at, 0) AS last_mutant_run_at,
                  MAX(CASE WHEN e.event_type = 'FIX' AND e.semantic_change = 1 THEN e.timestamp ELSE 0 END) AS latest_fix_at,
                  MAX(CASE WHEN e.event_type = 'CHANGE' AND e.semantic_change = 1 THEN e.timestamp ELSE 0 END) AS latest_change_at,
                  SUM(CASE
                    WHEN u.last_test_exposure_at > 0
                     AND e.event_type = 'FIX'
                     AND e.semantic_change = 1
                     AND e.timestamp > u.last_test_exposure_at
                    THEN 1 ELSE 0
                  END) AS fixes_after_test_exposure,
                  SUM(CASE
                    WHEN u.last_test_exposure_at > 0
                     AND e.event_type = 'CHANGE'
                     AND e.semantic_change = 1
                     AND e.timestamp > u.last_test_exposure_at
                    THEN 1 ELSE 0
                  END) AS changes_after_test_exposure,
                  SUM(CASE
                    WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                     AND e.semantic_change = 1
                     AND e.event_type IN ('FIX', 'CHANGE')
                     AND e.timestamp > m.last_mutant_run_at
                    THEN 1 ELSE 0
                  END) AS semantic_changes_after_mutant_run,
                  CASE
                    WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                     AND clock.observed_at > m.last_mutant_run_at
                    THEN clock.observed_at - m.last_mutant_run_at
                    ELSE 0
                  END AS verification_stale_seconds,
                  COALESCE(r.reopened_count, 0) AS reopened_count
                FROM filtered_units u
                JOIN events e ON e.unit_id = u.id
                LEFT JOIN mutant_runs m ON m.unit_id = u.id
                LEFT JOIN reopened r ON r.unit_id = u.id
                CROSS JOIN db_clock clock
                GROUP BY u.id, u.name, u.type, u.original_path,
                         u.current_distinct_tests, u.current_test_types,
                         u.current_mutant_verified_tests,
                         u.current_mutant_killed_tests, u.last_test_exposure_at,
                         m.last_mutant_run_at, r.reopened_count, clock.observed_at, u.current_path
            "#);
            let mut stmt = self.conn.prepare(&sql)?;
            let params: Vec<String> = only_prefixes.iter().map(|p| format!("{}%", p)).collect();
            let rows = stmt.query_map(rusqlite::params_from_iter(params.iter()), |row| {
                let verification_stale_seconds = row.get::<_, i64>(20)?;
                Ok(UnitSummary {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    kind: row.get(2)?,
                    original_path: row.get(3)?,
                    current_path: row.get(4)?,
                    total_events: row.get(5)?,
                    changes: row.get(6)?,
                    moves: row.get(7)?,
                    fixes: row.get(8)?,
                    current_distinct_tests: row.get(9)?,
                    current_test_types: row.get(10)?,
                    current_mutant_verified_tests: row.get(11)?,
                    current_mutant_killed_tests: row.get(12)?,
                    last_test_exposure_at: row.get(13)?,
                    last_mutant_run_at: row.get(14)?,
                    latest_fix_at: row.get(15)?,
                    latest_change_at: row.get(16)?,
                    fixes_after_test_exposure: row.get(17)?,
                    changes_after_test_exposure: row.get(18)?,
                    semantic_changes_after_mutant_run: row.get(19)?,
                    verification_stale_seconds,
                    verification_staleness_score: verification_stale_seconds as f64 / 86_400.0,
                    reopened_count: row.get(21)?,
                    risk_score: 0.0,
                    big_o_time: String::new(),
                    big_o_time_status: "unknown".into(),
                    big_o_space: String::new(),
                    big_o_space_status: "unknown".into(),
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut summaries = raw_summaries
            .into_iter()
            .map(|summary| (summary.id.clone(), summary))
            .collect::<HashMap<_, _>>();
        apply_decayed_risk(&self.conn, &mut summaries)?;
        let mut out = summaries.into_values().collect::<Vec<_>>();
        if !only_prefixes.is_empty() {
            out.retain(|summary| {
                only_prefixes
                    .iter()
                    .any(|prefix| summary.current_path.starts_with(prefix))
            });
        }
        out.sort_by(|left, right| {
            right
                .risk_score
                .partial_cmp(&left.risk_score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| right.fixes.cmp(&left.fixes))
                .then_with(|| right.changes.cmp(&left.changes))
                .then_with(|| right.total_events.cmp(&left.total_events))
                .then_with(|| left.current_path.cmp(&right.current_path))
                .then_with(|| left.name.cmp(&right.name))
        });
        out.truncate(limit);
        // Enrich the surfaced units with their Big-O complexity (cheap: only the
        // truncated top-N). Left as unknown/empty when no analysis is recorded.
        for summary in &mut out {
            let (time, time_status, space, space_status) = self.logical_unit_big_o(&summary.id)?;
            summary.big_o_time = time;
            summary.big_o_time_status = time_status;
            summary.big_o_space = space;
            summary.big_o_space_status = space_status;
        }
        Ok(out)
    }
}

fn configure_connection(conn: &Connection) -> Result<()> {
    conn.execute_batch(include_str!("../../sql/storage/configure_connection.sql"))?;
    Ok(())
}

fn apply_decayed_risk(
    conn: &Connection,
    summaries: &mut HashMap<String, UnitSummary>,
) -> Result<()> {
    let mut stmt = conn.prepare(include_str!("../../sql/storage/apply_decayed_risk.sql"))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, f64>(3)?,
            row.get::<_, f64>(4)?,
        ))
    })?;
    let events = rows.collect::<Result<Vec<_>, _>>()?;
    if events.is_empty() {
        return Ok(());
    }

    let first = events
        .iter()
        .map(|(_, _, timestamp, _, _)| *timestamp)
        .min()
        .unwrap_or(0);
    let last = events
        .iter()
        .map(|(_, _, timestamp, _, _)| *timestamp)
        .max()
        .unwrap_or(first);
    let span = (last - first) as f64;
    for (unit_id, event_type, timestamp, target_factor, mutation_hardening_factor) in events {
        if let Some(summary) = summaries.get_mut(&unit_id) {
            let t = if span == 0.0 {
                1.0
            } else {
                (timestamp - first) as f64 / span
            };
            let weight = 1.0 / (1.0 + ((-12.0 * t) + 12.0).exp());
            let multiplier = if event_type == "FIX" {
                4.0 * target_factor * mutation_hardening_factor
            } else {
                1.0
            };
            summary.risk_score += multiplier * weight;
        }
    }
    Ok(())
}

fn checked_table(table: &str) -> Result<&str> {
    match table {
        "logical_units"
        | "events"
        | "metadata"
        | "quality_events"
        | "crash_events"
        | "test_exposure_events"
        | "test_stage_timings"
        | "unit_hazards"
        | "unit_hotness"
        | "coverage_line_events"
        | "sarif_artifacts"
        | "sarif_findings"
        | "ui_file_summaries"
        | "ui_warning_units"
        | "ui_refresh_metadata" => Ok(table),
        _ => anyhow::bail!("unsupported table {table:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{EventType, UnitKind};
    use std::fs;

    fn collected_sql_files(root: &Path) -> Vec<std::path::PathBuf> {
        let mut files = Vec::new();
        for entry in fs::read_dir(root).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                files.extend(collected_sql_files(&path));
            } else if path.extension().and_then(|value| value.to_str()) == Some("sql") {
                files.push(path);
            }
        }
        files.sort();
        files
    }

    #[test]
    fn extracted_storage_queries_prepare_against_the_real_schema() {
        let storage = Storage::open_memory().unwrap();
        let sql_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("sql");
        // UI runtime queries live in the giga-ui crate and are validated there
        // against this same schema (see giga-ui's schema test).
        let files = [sql_root.join("storage"), sql_root.join("core")]
            .into_iter()
            .flat_map(|root| collected_sql_files(&root))
            .collect::<Vec<_>>();
        assert!(files.len() >= 45);
        for path in files {
            let sql = fs::read_to_string(&path)
                .unwrap()
                .replace("{column}", "current_line_cov");
            storage
                .connection()
                .prepare(&sql)
                .unwrap_or_else(|error| panic!("{} did not prepare: {error}", path.display()));
        }
    }

    #[test]
    fn partial_line_percentage_is_not_masked_by_a_full_coverage_source() {
        let storage = Storage::open_memory().unwrap();
        storage
            .record_coverage_line_with_details(
                "old",
                10,
                "sql/query.sql",
                3,
                1,
                false,
                Some(100.0),
                "coverage:legacy",
            )
            .unwrap();
        storage
            .record_coverage_line_with_details(
                "new",
                20,
                "sql/query.sql",
                3,
                1,
                true,
                Some(200.0 / 3.0),
                "coverage:sql-cov",
            )
            .unwrap();
        storage.refresh_ui_summaries().unwrap();
        let (partial, coverage) = storage
            .connection()
            .query_row(
                "SELECT partial_lines, line_coverage FROM ui_file_summaries WHERE path = ?1",
                ["sql/query.sql"],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, f64>(1)?)),
            )
            .unwrap();
        assert_eq!(partial, 1);
        assert!((coverage - 200.0 / 3.0).abs() < 0.000_001);
    }

    #[test]
    fn migrates_partial_coverage_and_merges_partial_observations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("legacy.db");
        let legacy = Connection::open(&path).unwrap();
        legacy
            .execute_batch(
                r#"
                CREATE TABLE coverage_line_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  commit_hash TEXT NOT NULL,
                  timestamp INTEGER NOT NULL,
                  path TEXT NOT NULL,
                  line INTEGER NOT NULL,
                  hits INTEGER NOT NULL,
                  source TEXT NOT NULL DEFAULT 'coverage',
                  UNIQUE(commit_hash, path, line, source)
                );
                "#,
            )
            .unwrap();
        drop(legacy);

        let storage = Storage::open(&path).unwrap();
        assert!(storage
            .record_coverage_line_with_source("abc", 10, "src/a.rb", 3, 1, false, "unit")
            .unwrap());
        assert!(storage
            .record_coverage_line_with_source("abc", 10, "src/a.rb", 3, 1, true, "unit")
            .unwrap());

        let is_partial: i64 = storage
            .connection()
            .query_row(
                "SELECT is_partial FROM coverage_line_events WHERE path = 'src/a.rb'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(is_partial, 1);
    }

    #[test]
    fn creates_schema_and_records_events() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
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
                message: "fix thing".into(),
                timestamp: 10,
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id,
                commit_hash: "abc".into(),
                event_type: EventType::Fix,
                path: "src/a.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 0,
                timestamp: 10,
            })
            .unwrap();

        assert_eq!(storage.count_rows("logical_units").unwrap(), 1);
        assert_eq!(storage.count_rows("metadata").unwrap(), 1);
        assert_eq!(storage.count_rows("events").unwrap(), 1);
        let top = storage.top_units(10, &[]).unwrap();
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].fixes, 1);
    }

    #[test]
    fn records_quality_metric_deltas_once_per_value_change() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
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

        let event = QualityEvent {
            unit_id: unit.id.clone(),
            commit_hash: "abc".into(),
            timestamp: 10,
            metric_type: QualityMetric::LineCoverage,
            old_value: None,
            new_value: 95.0,
        };

        assert!(storage.record_quality_metric(&event).unwrap());
        assert!(!storage.record_quality_metric(&event).unwrap());
        assert_eq!(storage.count_rows("quality_events").unwrap(), 1);
    }

    #[test]
    fn records_crash_events() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        assert!(storage
            .insert_crash_event(&CrashEvent {
                unit_id: unit.id,
                commit_hash: "abc".into(),
                timestamp: 10,
                error_class: "RuntimeError".into(),
                provider_id: "evt-1".into(),
                is_verified: true,
                path: "src/a.rb".into(),
                line: 2,
                function: "run".into(),
            })
            .unwrap());

        assert_eq!(storage.count_rows("crash_events").unwrap(), 1);
    }

    #[test]
    fn crash_events_are_idempotent_per_provider_frame() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        let event = CrashEvent {
            unit_id: unit.id,
            commit_hash: "abc".into(),
            timestamp: 10,
            error_class: "RuntimeError".into(),
            provider_id: "evt-1".into(),
            is_verified: true,
            path: "src/a.rb".into(),
            line: 2,
            function: "run".into(),
        };

        assert!(storage.insert_crash_event(&event).unwrap());
        assert!(!storage.insert_crash_event(&event).unwrap());
        assert_eq!(storage.count_rows("crash_events").unwrap(), 1);
    }

    #[test]
    fn records_and_deactivates_hazard_events() {
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

        assert_eq!(storage.count_rows("unit_hazards").unwrap(), 1);
        assert_eq!(storage.deactivate_active_hazards("zig").unwrap(), 1);
    }

    #[test]
    fn records_test_exposure_events_and_current_summary() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();

        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "spec/a_spec.rb:1".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                mutation_corpus: String::new(),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "spec/a_spec.rb:1".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                mutation_corpus: "second-corpus".into(),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_test_exposure_event(&TestExposureEvent {
                unit_id: unit.id.clone(),
                commit_hash: "abc".into(),
                timestamp: 10,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: Some("b1".into()),
                test_id: "test/a_test.rb:2".into(),
                test_type: "integration".into(),
                mutation_status: None,
                mutation_kind: None,
                mutation_corpus: String::new(),
                is_mutation_verified: false,
                is_mutation_killed: false,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();

        let summary: (i64, String, i64, i64, i64) = storage
            .conn
            .query_row(
                r#"
                SELECT current_distinct_tests, current_test_types,
                       current_mutant_verified_tests,
                       current_mutant_killed_tests, last_test_exposure_at
                FROM logical_units
                WHERE id = ?1
                "#,
                rusqlite::params![unit.id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .unwrap();

        assert_eq!(storage.count_rows("test_exposure_events").unwrap(), 3);
        assert_eq!(summary, (2, "integration,unit".into(), 1, 1, 10));
    }

    #[test]
    fn stage_timings_record_history_and_current() {
        let storage = Storage::open_memory().unwrap();
        storage.record_stage_timing("c1", "precommit", "unit", 100.0, 2.0, 1, 10).unwrap();
        storage.record_stage_timing("c2", "precommit", "unit", 102.0, 2.0, 1, 20).unwrap();
        storage.record_stage_timing("c3", "precommit", "unit", 98.0, 1.5, 3, 30).unwrap();
        // Baseline is the history excluding the current commit.
        let hist = storage.stage_timing_history("precommit", "unit", 10, "c3").unwrap();
        assert_eq!(hist.len(), 2);
        assert!(hist.contains(&100.0) && hist.contains(&102.0));
        // The current commit's own measurement (mean, stddev, n) is retrievable.
        assert_eq!(
            storage.stage_timing_for_commit("c3", "precommit", "unit").unwrap(),
            Some((98.0, 1.5, 3))
        );
        // Re-recording upserts.
        storage.record_stage_timing("c3", "precommit", "unit", 95.0, 0.5, 4, 31).unwrap();
        assert_eq!(
            storage.stage_timing_for_commit("c3", "precommit", "unit").unwrap(),
            Some((95.0, 0.5, 4))
        );
        // A different test_set is isolated.
        assert!(storage
            .stage_timing_for_commit("c3", "precommit", "integration")
            .unwrap()
            .is_none());
    }

    #[test]
    fn test_inventory_aggregates_payload_and_kills_per_test() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        let event = |test_id: &str, line: u32, killed: bool, payload: &str| TestExposureEvent {
            unit_id: unit.id.clone(),
            commit_hash: "abc".into(),
            timestamp: 10,
            path: "src/a.rb".into(),
            function: Some("run".into()),
            line: Some(line),
            branch_id: Some(format!("{test_id}:{line}")),
            test_id: test_id.into(),
            test_type: "unit".into(),
            mutation_status: Some(if killed { "killed" } else { "alive" }.into()),
            mutation_kind: Some("stochastic".into()),
            mutation_corpus: String::new(),
            is_mutation_verified: true,
            is_mutation_killed: killed,
            is_verified: true,
            payload_json: payload.into(),
        };
        // One test covering two lines, with explicit payload metadata + kills.
        let meta = r#"{"test_path":"spec/a_spec.rb","test_start_line":4,"test_end_line":9,"pending":false,"killed_mutant_ids":["m1","m2"]}"#;
        storage.insert_test_exposure_event(&event("spec/a_spec.rb:killer", 2, true, meta)).unwrap();
        storage.insert_test_exposure_event(&event("spec/a_spec.rb:killer", 3, true, meta)).unwrap();
        // A pending test with no coverage lines and no payload kill ids.
        let pmeta = r#"{"test_path":"spec/a_spec.rb","test_start_line":11,"test_end_line":13,"pending":true}"#;
        let mut pending = event("spec/a_spec.rb:pending", 2, false, pmeta);
        pending.line = None; // no covered line
        storage.insert_test_exposure_event(&pending).unwrap();

        let mut inv = storage.test_inventory_for_commit("abc").unwrap();
        inv.sort_by(|a, b| a.test_id.cmp(&b.test_id));
        assert_eq!(inv.len(), 2);
        let killer = &inv[0];
        assert_eq!(killer.test_id, "spec/a_spec.rb:killer");
        assert_eq!(killer.language, "ruby");
        assert_eq!(killer.test_path, "spec/a_spec.rb");
        assert_eq!((killer.start_line, killer.end_line), (4, 9));
        assert_eq!(killer.covered_lines, 2, "two distinct covered lines");
        assert!(killer.had_mutation);
        assert_eq!(
            killer.killed_mutants,
            ["m1".to_string(), "m2".to_string()].into_iter().collect()
        );
        let pending = &inv[1];
        assert!(pending.pending);
        assert_eq!(pending.covered_lines, 0);
        assert!(pending.killed_mutants.is_empty());
    }

    #[test]
    fn top_units_include_test_exposure_hardening_fields() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "run",
            UnitKind::Function,
            "src/a.rb",
            1,
            1,
            3,
            "def run",
            "def run\n1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "fix1".into(),
                event_type: EventType::Fix,
                path: "src/a.rb".into(),
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
                commit_hash: "cov1".into(),
                timestamp: 20,
                path: "src/a.rb".into(),
                function: Some("run".into()),
                line: Some(2),
                branch_id: None,
                test_id: "spec/a_spec.rb:1".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                mutation_corpus: String::new(),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id.clone(),
                commit_hash: "fix2".into(),
                event_type: EventType::Fix,
                path: "src/a.rb".into(),
                name: "run".into(),
                start_line: 1,
                end_line: 3,
                semantic_change: true,
                lines_added: 1,
                lines_removed: 0,
                timestamp: 30,
            })
            .unwrap();
        storage
            .insert_crash_event(&CrashEvent {
                unit_id: unit.id,
                commit_hash: "crash1".into(),
                timestamp: 40,
                error_class: "RuntimeError".into(),
                provider_id: "evt-1".into(),
                is_verified: true,
                path: "src/a.rb".into(),
                line: 2,
                function: "run".into(),
            })
            .unwrap();

        let top = storage.top_units(10, &[]).unwrap();

        assert_eq!(top.len(), 1);
        assert_eq!(top[0].current_distinct_tests, 1);
        assert_eq!(top[0].current_test_types, "unit");
        assert_eq!(top[0].current_mutant_verified_tests, 1);
        assert_eq!(top[0].current_mutant_killed_tests, 1);
        assert_eq!(top[0].last_test_exposure_at, 20);
        assert_eq!(top[0].last_mutant_run_at, 20);
        assert_eq!(top[0].latest_fix_at, 30);
        assert_eq!(top[0].fixes_after_test_exposure, 1);
        assert_eq!(top[0].semantic_changes_after_mutant_run, 1);
        assert_eq!(top[0].verification_stale_seconds, 20);
        assert!(top[0].verification_staleness_score > 0.0);
        assert_eq!(top[0].reopened_count, 1);
    }

    #[test]
    fn test_find_definitions() {
        let storage = Storage::open_memory().unwrap();
        let unit = LogicalUnit::new(
            "my_test_func",
            UnitKind::Function,
            "src/a.rb",
            1,
            10,
            20,
            "def my_test_func",
            "def my_test_func\n  1\nend",
        );
        storage.upsert_logical_unit(&unit, 10).unwrap();

        // Check finding it before move/events
        let defs = storage
            .find_definitions("my_test_func", None, None)
            .unwrap();
        assert_eq!(defs.len(), 1);
        assert_eq!(defs[0].0, "src/a.rb");
        assert_eq!(defs[0].1, 10);

        // Record a move event
        storage
            .insert_metadata(&CommitMetadata {
                hash: "c2".into(),
                message: "move it".into(),
                timestamp: 20,
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id,
                commit_hash: "c2".into(),
                event_type: EventType::Move,
                path: "src/b.rb".into(),
                name: "my_test_func".into(),
                start_line: 15,
                end_line: 25,
                semantic_change: false,
                lines_added: 0,
                lines_removed: 0,
                timestamp: 20,
            })
            .unwrap();

        // Check finding it after move event
        let defs_after = storage
            .find_definitions("my_test_func", None, None)
            .unwrap();
        assert_eq!(defs_after.len(), 1);
        assert_eq!(defs_after[0].0, "src/b.rb");
        assert_eq!(defs_after[0].1, 15);
    }

    #[test]
    fn test_find_definitions_from_engine_state() {
        let storage = Storage::open_memory().unwrap();

        // Save engine state for commit "c1"
        let state_json = r#"{
            "previous": {
                "u1": {
                    "id": "u1",
                    "name": "MyClass.my_method",
                    "kind": "Function",
                    "path": "src/my_class.rb",
                    "start_line": 42,
                    "end_line": 50,
                    "normalized_hash": "abc",
                    "signature": "def my_method"
                }
            }
        }"#;
        storage.save_engine_state("c1", state_json).unwrap();

        // Query definitions with different names
        // Exact name
        let defs_exact = storage
            .find_definitions("MyClass.my_method", Some("c1"), None)
            .unwrap();
        assert_eq!(defs_exact.len(), 1);
        assert_eq!(defs_exact[0].0, "src/my_class.rb");
        assert_eq!(defs_exact[0].1, 42);

        // Short name suffix
        let defs_suffix = storage
            .find_definitions("my_method", Some("c1"), None)
            .unwrap();
        assert_eq!(defs_suffix.len(), 1);
        assert_eq!(defs_suffix[0].0, "src/my_class.rb");
        assert_eq!(defs_suffix[0].1, 42);

        // Different suffix separator or non-matching name
        let defs_non_match = storage
            .find_definitions("other_method", Some("c1"), None)
            .unwrap();
        assert!(defs_non_match.is_empty());
    }

    #[test]
    fn current_unit_spans_for_path_falls_back_to_logical_units_start_line() {
        // Same first-commit gap as file_units in ui/lsp.rs: a unit's
        // creating commit records no `events` row, so `le.*` is NULL until
        // a later commit changes/moves/fixes it. Without a fallback to
        // logical_units.start_line, every fresh unit collapses to line 1.
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
        let unit_id = unit.id.clone();
        storage.upsert_logical_unit(&unit, 10).unwrap();

        let spans = storage
            .current_unit_spans_for_path("src/worker.rb")
            .unwrap();
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].id, unit_id);
        assert_eq!(
            spans[0].start_line, 7,
            "must fall back to logical_units.start_line, not 1"
        );
        assert_eq!(
            spans[0].end_line, 7,
            "no end_line column on logical_units to recover the true extent"
        );

        assert_eq!(
            storage
                .current_unit_id_for_path_line("src/worker.rb", 7)
                .unwrap(),
            Some(unit_id)
        );
        assert_eq!(
            storage
                .current_unit_id_for_path_line("src/worker.rb", 1)
                .unwrap(),
            None
        );
    }
}
