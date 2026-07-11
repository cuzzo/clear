use crate::model::{
    CommitMetadata, CrashEvent, Event, HazardEvent, LogicalUnit, QualityEvent, QualityMetric,
    SarifArtifact, SarifFinding, TestExposureEvent,
};
use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::Path;

pub struct Storage {
    conn: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentUnitSpan {
    pub id: String,
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
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
}

impl Storage {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        configure_connection(&conn)?;
        let storage = Self { conn };
        storage.init_schema()?;
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
        self.conn.execute_batch(
            r#"
            PRAGMA foreign_keys = ON;
            PRAGMA synchronous = NORMAL;

            CREATE TABLE IF NOT EXISTS logical_units (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              type TEXT NOT NULL,
              original_path TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              start_line INTEGER DEFAULT 1,
              current_line_cov REAL DEFAULT 0.0,
              current_integration_cov REAL DEFAULT 0.0,
              current_mutant_cov REAL DEFAULT 0.0,
              is_hard_gated INTEGER DEFAULT 0,
              current_distinct_tests INTEGER DEFAULT 0,
              current_test_types TEXT DEFAULT '',
              current_mutant_verified_tests INTEGER DEFAULT 0,
              current_mutant_killed_tests INTEGER DEFAULT 0,
              last_test_exposure_at INTEGER DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              event_type TEXT NOT NULL CHECK (event_type IN ('CHANGE', 'MOVE', 'FIX')),
              path TEXT NOT NULL,
              name TEXT NOT NULL,
              start_line INTEGER NOT NULL,
              end_line INTEGER NOT NULL,
              semantic_change INTEGER NOT NULL CHECK (semantic_change IN (0, 1)),
              lines_added INTEGER NOT NULL DEFAULT 0,
              lines_removed INTEGER NOT NULL DEFAULT 0,
              timestamp INTEGER NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS metadata (
              commit_hash TEXT PRIMARY KEY,
              message TEXT NOT NULL,
              sentry_id TEXT,
              coverage_delta REAL,
              timestamp INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS quality_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              metric_type TEXT NOT NULL CHECK (
                metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV', 'GATE_STATUS')
              ),
              old_value REAL,
              new_value REAL NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS crash_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              error_class TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              is_verified INTEGER NOT NULL CHECK (is_verified IN (0, 1)),
              path TEXT NOT NULL,
              line INTEGER NOT NULL,
              function TEXT NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS test_exposure_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              path TEXT NOT NULL,
              function TEXT,
              line INTEGER,
              branch_id TEXT,
              test_id TEXT NOT NULL,
              test_type TEXT NOT NULL,
              mutation_status TEXT,
              mutation_kind TEXT NOT NULL DEFAULT '',
              is_mutation_verified INTEGER NOT NULL CHECK (is_mutation_verified IN (0, 1)),
              is_mutation_killed INTEGER NOT NULL CHECK (is_mutation_killed IN (0, 1)),
              is_verified INTEGER NOT NULL CHECK (is_verified IN (0, 1)),
              payload_json TEXT NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS unit_hazards (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              unit_id TEXT NOT NULL,
              language TEXT NOT NULL,
              hazard_type TEXT NOT NULL,
              required_evidence TEXT NOT NULL,
              path TEXT NOT NULL,
              line INTEGER NOT NULL,
              symbol TEXT,
              source TEXT NOT NULL,
              detected_at_hash TEXT NOT NULL,
              is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
              payload_json TEXT NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS coverage_line_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              path TEXT NOT NULL,
              line INTEGER NOT NULL,
              hits INTEGER NOT NULL,
              is_partial INTEGER NOT NULL DEFAULT 0,
              source TEXT NOT NULL DEFAULT 'coverage',
              UNIQUE(commit_hash, path, line, source)
            );

            CREATE TABLE IF NOT EXISTS sarif_artifacts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL,
              tool_name TEXT NOT NULL,
              run_format TEXT NOT NULL,
              artifact_path TEXT NOT NULL,
              artifact_sha256 TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              payload_json TEXT NOT NULL,
              ingested_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
              UNIQUE(source, commit_hash, artifact_path, artifact_sha256)
            );

            CREATE TABLE IF NOT EXISTS sarif_findings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              artifact_id INTEGER NOT NULL,
              finding_key TEXT NOT NULL,
              source TEXT NOT NULL,
              tool_name TEXT NOT NULL,
              run_format TEXT NOT NULL,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              rule_id TEXT NOT NULL,
              level TEXT NOT NULL,
              message TEXT NOT NULL,
              path TEXT NOT NULL,
              start_line INTEGER NOT NULL,
              start_column INTEGER,
              end_line INTEGER,
              end_column INTEGER,
              category TEXT NOT NULL,
              is_dark_arm INTEGER NOT NULL CHECK (is_dark_arm IN (0, 1)),
              unit_id TEXT,
              fingerprint TEXT NOT NULL,
              properties_json TEXT NOT NULL,
              raw_json TEXT NOT NULL,
              FOREIGN KEY(artifact_id) REFERENCES sarif_artifacts(id) ON DELETE CASCADE,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id),
              UNIQUE(source, commit_hash, finding_key)
            );

            CREATE TABLE IF NOT EXISTS ui_file_summaries (
              path TEXT PRIMARY KEY,
              units INTEGER NOT NULL,
              hazards INTEGER NOT NULL,
              evidence_covered_hazards INTEGER NOT NULL,
              covered_hazards INTEGER NOT NULL,
              distinct_tests INTEGER NOT NULL,
              mutant_killed_tests INTEGER NOT NULL,
              tracked_lines INTEGER NOT NULL,
              covered_lines INTEGER NOT NULL,
              line_coverage REAL NOT NULL,
              mutant_coverage REAL NOT NULL,
              mutant_verified_covered_lines INTEGER NOT NULL,
              mutant_killed_covered_lines INTEGER NOT NULL,
              stochastic_mutant_verified_covered_lines INTEGER NOT NULL,
              stochastic_mutant_killed_covered_lines INTEGER NOT NULL,
              invariant_mutant_verified_covered_lines INTEGER NOT NULL,
              invariant_mutant_killed_covered_lines INTEGER NOT NULL,
              multi_type_covered_lines INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS ui_warning_units (
              unit_id TEXT PRIMARY KEY,
              current_path TEXT NOT NULL,
              current_distinct_tests INTEGER NOT NULL,
              current_mutant_verified_tests INTEGER NOT NULL,
              last_test_exposure_at INTEGER NOT NULL,
              last_mutant_run_at INTEGER NOT NULL,
              changes_after_test_exposure INTEGER NOT NULL,
              semantic_changes_after_mutant_run INTEGER NOT NULL,
              verification_stale_seconds INTEGER NOT NULL,
              reopened_count INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS ui_refresh_metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS engine_state (
              commit_hash TEXT PRIMARY KEY,
              state_json TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_events_unit_id ON events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_events_unit_latest
              ON events(unit_id, timestamp DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_events_unit_type_semantic_time
              ON events(unit_id, event_type, semantic_change, timestamp);
            CREATE INDEX IF NOT EXISTS idx_events_commit_hash ON events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
            CREATE INDEX IF NOT EXISTS idx_quality_events_unit_id ON quality_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_quality_events_commit_hash ON quality_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_crash_events_unit_id ON crash_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_crash_events_unit_path_line_time
              ON crash_events(unit_id, path, line, timestamp);
            CREATE INDEX IF NOT EXISTS idx_crash_events_commit_hash ON crash_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_unit_id ON test_exposure_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_unit_mutant_time
              ON test_exposure_events(unit_id, is_mutation_verified, is_mutation_killed, timestamp);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_path_line_latest
              ON test_exposure_events(path, line, branch_id, test_id, test_type, timestamp DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_commit_hash ON test_exposure_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_test_id ON test_exposure_events(test_id);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_type ON test_exposure_events(test_type);
            CREATE INDEX IF NOT EXISTS idx_unit_hazards_unit_id ON unit_hazards(unit_id);
            CREATE INDEX IF NOT EXISTS idx_unit_hazards_path_line ON unit_hazards(path, line);
            CREATE INDEX IF NOT EXISTS idx_unit_hazards_type ON unit_hazards(hazard_type);
            CREATE INDEX IF NOT EXISTS idx_unit_hazards_detected_at ON unit_hazards(detected_at_hash);
            CREATE INDEX IF NOT EXISTS idx_coverage_line_events_path_line ON coverage_line_events(path, line);
            CREATE INDEX IF NOT EXISTS idx_coverage_line_events_path_line_source_latest
              ON coverage_line_events(path, line, source, timestamp DESC, id DESC);
            CREATE INDEX IF NOT EXISTS idx_coverage_line_events_commit_hash ON coverage_line_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_sarif_artifacts_source_commit
              ON sarif_artifacts(source, commit_hash);
            CREATE INDEX IF NOT EXISTS idx_sarif_findings_path_line
              ON sarif_findings(path, start_line);
            CREATE INDEX IF NOT EXISTS idx_sarif_findings_source_commit
              ON sarif_findings(source, commit_hash);
            CREATE INDEX IF NOT EXISTS idx_sarif_findings_unit_id
              ON sarif_findings(unit_id);
            CREATE INDEX IF NOT EXISTS idx_sarif_findings_rule_id
              ON sarif_findings(rule_id);
            CREATE INDEX IF NOT EXISTS idx_ui_file_summaries_path ON ui_file_summaries(path);
            CREATE INDEX IF NOT EXISTS idx_ui_warning_units_path ON ui_warning_units(current_path);
            CREATE INDEX IF NOT EXISTS idx_events_path ON events(path);
            CREATE INDEX IF NOT EXISTS idx_logical_units_original_path ON logical_units(original_path);
            "#,
        )?;
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
        self.ensure_column("test_exposure_events", "mutation_kind", "TEXT NOT NULL DEFAULT ''")?;
        self.ensure_column(
            "coverage_line_events",
            "is_partial",
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
        self.backfill_mutation_kind()?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_test_exposure_events_mutation_kind ON test_exposure_events(mutation_kind)",
            [],
        )?;
        self.ensure_natural_key_indexes()?;
        Ok(())
    }

    pub(crate) fn connection(&self) -> &Connection {
        &self.conn
    }

    fn ensure_logical_unit_column(&self, name: &str, definition: &str) -> Result<()> {
        self.ensure_column("logical_units", name, definition)
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
        self.conn.execute_batch(
            r#"
            DELETE FROM coverage_line_events
            WHERE id NOT IN (
              SELECT (
                SELECT c2.id
                FROM coverage_line_events c2
                WHERE c2.commit_hash = c1.commit_hash
                  AND c2.path = c1.path
                  AND c2.line = c1.line
                  AND c2.source = c1.source
                ORDER BY c2.hits DESC, c2.timestamp DESC, c2.id DESC
                LIMIT 1
              )
              FROM coverage_line_events c1
              GROUP BY c1.commit_hash, c1.path, c1.line, c1.source
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_coverage_line_events_natural_key
              ON coverage_line_events(commit_hash, path, line, source);

            DELETE FROM quality_events
            WHERE id NOT IN (
              SELECT (
                SELECT q2.id
                FROM quality_events q2
                WHERE q2.unit_id = q1.unit_id
                  AND q2.commit_hash = q1.commit_hash
                  AND q2.metric_type = q1.metric_type
                ORDER BY q2.new_value DESC, q2.timestamp DESC, q2.id DESC
                LIMIT 1
              )
              FROM quality_events q1
              GROUP BY q1.unit_id, q1.commit_hash, q1.metric_type
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_quality_events_natural_key
              ON quality_events(unit_id, commit_hash, metric_type);

            DELETE FROM crash_events
            WHERE id NOT IN (
              SELECT (
                SELECT e2.id
                FROM crash_events e2
                WHERE e2.unit_id = e1.unit_id
                  AND e2.commit_hash = e1.commit_hash
                  AND e2.error_class = e1.error_class
                  AND e2.provider_id = e1.provider_id
                  AND e2.path = e1.path
                  AND e2.line = e1.line
                  AND e2.function = e1.function
                ORDER BY e2.is_verified DESC, e2.timestamp DESC, e2.id DESC
                LIMIT 1
              )
              FROM crash_events e1
              GROUP BY e1.unit_id, e1.commit_hash, e1.error_class, e1.provider_id,
                       e1.path, e1.line, e1.function
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_crash_events_natural_key
              ON crash_events(unit_id, commit_hash, error_class, provider_id, path, line, function);

            DELETE FROM test_exposure_events
            WHERE id NOT IN (
              SELECT (
                SELECT t2.id
                FROM test_exposure_events t2
                WHERE t2.unit_id = t1.unit_id
                  AND t2.commit_hash = t1.commit_hash
                  AND t2.path = t1.path
                  AND COALESCE(t2.line, -1) = COALESCE(t1.line, -1)
                  AND COALESCE(t2.branch_id, '') = COALESCE(t1.branch_id, '')
                  AND t2.test_id = t1.test_id
                  AND t2.test_type = t1.test_type
                ORDER BY t2.is_verified DESC,
                         t2.is_mutation_killed DESC,
                         t2.is_mutation_verified DESC,
                         CASE
                           WHEN lower(COALESCE(t2.mutation_kind, '')) IN ('invariant', 'contract') THEN 2
                           WHEN COALESCE(t2.mutation_kind, '') <> '' THEN 1
                           ELSE 0
                         END DESC,
                         t2.timestamp DESC,
                         t2.id DESC
                LIMIT 1
              )
              FROM test_exposure_events t1
              GROUP BY t1.unit_id, t1.commit_hash, t1.path, COALESCE(t1.line, -1),
                       COALESCE(t1.branch_id, ''), t1.test_id, t1.test_type
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_test_exposure_events_natural_key
              ON test_exposure_events(
                unit_id,
                commit_hash,
                path,
                COALESCE(line, -1),
                COALESCE(branch_id, ''),
                test_id,
                test_type
              );
            "#,
        )?;
        Ok(())
    }

    fn backfill_mutation_kind(&self) -> Result<()> {
        self.conn.execute(
            r#"
            UPDATE test_exposure_events
            SET mutation_kind = CASE
              WHEN lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%invariant%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%contract%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%property%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%fuzz%'
              THEN 'invariant'
              ELSE 'stochastic'
            END
            WHERE is_mutation_verified = 1
              AND COALESCE(mutation_kind, '') = ''
            "#,
            [],
        )?;
        Ok(())
    }

    pub fn begin_transaction(&self) -> Result<()> {
        self.conn.execute_batch("BEGIN IMMEDIATE TRANSACTION;")?;
        Ok(())
    }

    pub fn commit_transaction(&self) -> Result<()> {
        self.conn.execute_batch("COMMIT;")?;
        Ok(())
    }

    pub fn rollback_transaction(&self) -> Result<()> {
        self.conn.execute_batch("ROLLBACK;")?;
        Ok(())
    }

    pub fn insert_metadata(&self, metadata: &CommitMetadata) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT OR IGNORE INTO metadata (commit_hash, message, timestamp)
            VALUES (?1, ?2, ?3)
            "#,
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
            r#"
            INSERT INTO logical_units (id, name, type, original_path, created_at, start_line)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO NOTHING
            "#,
            params![unit.id, unit.name, unit.kind.as_str(), unit.path, created_at, unit.start_line],
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
                let mut stmt = self.conn.prepare(
                    "SELECT commit_hash FROM metadata ORDER BY timestamp DESC LIMIT 1"
                )?;
                let mut rows = stmt.query([])?;
                rows.next()?.map(|row| row.get::<_, String>(0)).transpose()?
            }
        };

        // Try to load engine state first for exact current paths and lines
        if let Some(ref hash) = target_commit {
            if let Ok(Some(state_json)) = self.load_engine_state(hash) {
                if let Ok(state) = serde_json::from_str::<serde_json::Value>(&state_json) {
                    if let Some(previous) = state.get("previous").and_then(|p| p.as_object()) {
                        let mut results = Vec::new();
                        for (_id, val) in previous {
                            let Some(uname) = val.get("name").and_then(|n| n.as_str()) else { continue; };
                            
                            // Check if name matches (exactly or qualified suffix)
                            let name_matches = uname == name
                                || uname.ends_with(&format!(".{name}"))
                                || uname.ends_with(&format!("::{name}"))
                                || uname.ends_with(&format!("#{name}"));
                                
                            if name_matches {
                                let Some(upath) = val.get("path").and_then(|p| p.as_str()) else { continue; };
                                let Some(ustart) = val.get("start_line").and_then(|l| l.as_u64()) else { continue; };
                                results.push((upath.to_string(), ustart as u32));
                            }
                        }
                        
                        if !results.is_empty() {
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
                                        return b_exact.cmp(&a_exact);
                                    }
                                    
                                    let a_in_dir = !cur_dir.is_empty() && a_norm.starts_with(&format!("{}/", cur_dir));
                                    let b_in_dir = !cur_dir.is_empty() && b_norm.starts_with(&format!("{}/", cur_dir));
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

        let mut stmt = self.conn.prepare(
            r#"
            SELECT u.id,
              COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) AS path,
              COALESCE((
                SELECT latest.start_line
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.start_line) AS start_line
            FROM logical_units u
            WHERE u.name = ?1
               OR u.name LIKE '%.' || ?1
               OR u.name LIKE '%::' || ?1
               OR u.name LIKE '%#' || ?1
            LIMIT 100
            "#,
        )?;
        let rows = stmt.query_map(params![name], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, u32>(2)?))
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
            r#"
            INSERT INTO events
              (unit_id, commit_hash, event_type, path, name, start_line, end_line,
               semantic_change, lines_added, lines_removed, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
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
        let mut stmt = self.conn.prepare(
            r#"
            SELECT u.id
            FROM logical_units u
            WHERE COALESCE((
              SELECT latest.path
              FROM events latest
              WHERE latest.unit_id = u.id
              ORDER BY latest.timestamp DESC, latest.id DESC
              LIMIT 1
            ), u.original_path) = ?1
            ORDER BY u.name, u.id
            "#,
        )?;
        let rows = stmt.query_map(params![path], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn resolve_current_path(&self, path: &str) -> Result<Option<String>> {
        let normalized = path.trim_start_matches("./");
        let mut stmt = self.conn.prepare(
            r#"
            WITH current_paths AS (
              SELECT DISTINCT COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) AS current_path
              FROM logical_units u
            )
            SELECT current_path
            FROM current_paths
            WHERE current_path = ?1
            ORDER BY current_path
            "#,
        )?;
        let exact = stmt
            .query_map(params![normalized], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        if let Some(path) = exact.into_iter().next() {
            return Ok(Some(path));
        }

        let suffix = format!("%/{normalized}");
        let mut stmt = self.conn.prepare(
            r#"
            WITH current_paths AS (
              SELECT DISTINCT COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) AS current_path
              FROM logical_units u
            )
            SELECT current_path
            FROM current_paths
            WHERE current_path LIKE ?1
            ORDER BY current_path
            LIMIT 2
            "#,
        )?;
        let candidates = stmt
            .query_map(params![suffix], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(if candidates.len() == 1 {
            candidates.into_iter().next()
        } else {
            None
        })
    }

    pub fn resolve_unit_id(&self, observed_id: &str, path: &str, name: &str) -> Result<Option<String>> {
        if self.logical_unit_exists(observed_id)? {
            return Ok(Some(observed_id.to_string()));
        }

        let mut stmt = self.conn.prepare(
            r#"
            SELECT u.id
            FROM logical_units u
            WHERE u.name = ?2
              AND COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) = ?1
            ORDER BY u.created_at DESC
            LIMIT 1
            "#,
        )?;
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
            self.conn.execute(
                &format!("UPDATE logical_units SET {column} = ?2 WHERE id = ?1"),
                params![event.unit_id, merged_value],
            )?;
            if (previous_new_value - merged_value).abs() < 0.0001 {
                return Ok(false);
            }

            self.conn.execute(
                r#"
                UPDATE quality_events
                SET timestamp = ?2, new_value = ?3
                WHERE id = ?1
                "#,
                params![id, event.timestamp, merged_value],
            )?;
            return Ok(true);
        }

        if old_value
            .map(|value| (value - event.new_value).abs() < 0.0001)
            .unwrap_or(false)
        {
            return Ok(false);
        }

        self.conn.execute(
            r#"
            INSERT INTO quality_events
              (unit_id, commit_hash, timestamp, metric_type, old_value, new_value)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                event.unit_id,
                event.commit_hash,
                event.timestamp,
                event.metric_type.as_str(),
                old_value,
                event.new_value
            ],
        )?;
        self.conn.execute(
            &format!("UPDATE logical_units SET {column} = ?2 WHERE id = ?1"),
            params![event.unit_id, event.new_value],
        )?;
        Ok(true)
    }

    fn existing_quality_event(
        &self,
        unit_id: &str,
        commit_hash: &str,
        metric: QualityMetric,
    ) -> Result<Option<(i64, f64)>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, new_value
            FROM quality_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND metric_type = ?3
            ORDER BY id DESC
            LIMIT 1
            "#,
        )?;
        Ok(stmt
            .query_row(params![unit_id, commit_hash, metric.as_str()], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .optional()?)
    }

    pub fn delete_coverage_for_commit(&self, commit_hash: &str) -> Result<usize> {
        let quality = self.conn.execute(
            r#"
            DELETE FROM quality_events
            WHERE commit_hash = ?1
              AND metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV', 'GATE_STATUS')
            "#,
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
        let mut stmt = self.conn.prepare(
            r#"
            SELECT DISTINCT unit_id
            FROM test_exposure_events
            WHERE commit_hash = ?1 AND test_type = ?2 AND test_id = ?3
            "#,
        )?;
        let unit_ids = stmt
            .query_map(params![commit_hash, test_type, test_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let deleted = self.conn.execute(
            r#"
            DELETE FROM test_exposure_events
            WHERE commit_hash = ?1 AND test_type = ?2 AND test_id = ?3
            "#,
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

    pub fn insert_sarif_artifact(&self, artifact: &SarifArtifact) -> Result<i64> {
        self.conn.execute(
            r#"
            INSERT INTO sarif_artifacts
              (source, tool_name, run_format, artifact_path, artifact_sha256,
               commit_hash, timestamp, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(source, commit_hash, artifact_path, artifact_sha256) DO UPDATE SET
              tool_name = excluded.tool_name,
              run_format = excluded.run_format,
              timestamp = excluded.timestamp,
              payload_json = excluded.payload_json,
              ingested_at = strftime('%s', 'now')
            "#,
            params![
                artifact.source,
                artifact.tool_name,
                artifact.run_format,
                artifact.artifact_path,
                artifact.artifact_sha256,
                artifact.commit_hash,
                artifact.timestamp,
                artifact.payload_json
            ],
        )?;
        let id = self.conn.query_row(
            r#"
            SELECT id
            FROM sarif_artifacts
            WHERE source = ?1
              AND commit_hash = ?2
              AND artifact_path = ?3
              AND artifact_sha256 = ?4
            "#,
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
            r#"
            INSERT OR IGNORE INTO sarif_findings
              (artifact_id, finding_key, source, tool_name, run_format, commit_hash,
               timestamp, rule_id, level, message, path, start_line, start_column,
               end_line, end_column, category, is_dark_arm, unit_id, fingerprint,
               properties_json, raw_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
            "#,
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
            .min_by_key(|span| (span.end_line.saturating_sub(span.start_line), span.id.clone()))
            .map(|span| span.id))
    }

    pub fn current_unit_spans_for_path(&self, path: &str) -> Result<Vec<CurrentUnitSpan>> {
        let mut stmt = self.conn.prepare(
            r#"
            WITH filtered_units AS (
              SELECT id FROM logical_units WHERE original_path = ?1
              UNION
              SELECT unit_id AS id FROM events WHERE path = ?1
            ),
            latest_events AS (
              SELECT *
              FROM (
                SELECT e.*,
                       ROW_NUMBER() OVER (
                         PARTITION BY e.unit_id
                         ORDER BY e.timestamp DESC, e.id DESC
                       ) AS rank
                FROM events e
                WHERE e.unit_id IN (SELECT id FROM filtered_units)
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
              WHERE u.id IN (SELECT id FROM filtered_units)
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path = ?1
            "#,
        )?;
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
        let mut stmt = self.conn.prepare(
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
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path <> ''
            "#,
        )?;
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
        sql.push_str(r#"
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
        "#);
        for i in 0..ids.len() {
            if i > 0 {
                sql.push_str(", ");
            }
            sql.push_str(&format!("?{}", i + 1));
        }
        sql.push_str(r#"
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
        "#);
        for i in 0..ids.len() {
            if i > 0 {
                sql.push_str(", ");
            }
            sql.push_str(&format!("?{}", i + 1));
        }
        sql.push_str(r#"
              )
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path <> ''
        "#);

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
        let mut stmt = self.conn.prepare(
            r#"
            SELECT artifact_id, finding_key, source, tool_name, run_format, commit_hash,
                   timestamp, rule_id, level, message, path, start_line, start_column,
                   end_line, end_column, category, is_dark_arm, unit_id, fingerprint,
                   properties_json, raw_json
            FROM sarif_findings
            WHERE path = ?1
            ORDER BY start_line, source, tool_name, rule_id, message
            "#,
        )?;
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
        let mut stmt = self.conn.prepare(
            r#"
            SELECT path, COUNT(*) AS findings
            FROM sarif_findings
            GROUP BY path
            "#,
        )?;
        let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?;
        Ok(rows.collect::<std::result::Result<HashMap<_, _>, _>>()?)
    }

    fn refresh_current_quality_metrics(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            UPDATE logical_units
            SET current_line_cov = 0.0,
                current_integration_cov = 0.0,
                current_mutant_cov = 0.0,
                is_hard_gated = 0;
            "#,
        )?;
        for (metric, column) in [
            (QualityMetric::LineCoverage, "current_line_cov"),
            (QualityMetric::IntegrationCoverage, "current_integration_cov"),
            (QualityMetric::MutantCoverage, "current_mutant_cov"),
            (QualityMetric::GateStatus, "is_hard_gated"),
        ] {
            self.conn.execute(
                &format!(
                    r#"
                    UPDATE logical_units
                    SET {column} = COALESCE((
                      SELECT q.new_value
                      FROM quality_events q
                      WHERE q.unit_id = logical_units.id
                        AND q.metric_type = ?1
                      ORDER BY q.timestamp DESC, q.id DESC
                      LIMIT 1
                    ), 0.0)
                    "#
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
        self.record_coverage_line_with_source(commit_hash, timestamp, path, line, hits, false, "coverage")
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
        let changed = self.conn.execute(
            r#"
            INSERT INTO coverage_line_events
              (commit_hash, timestamp, path, line, hits, is_partial, source)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(commit_hash, path, line, source) DO UPDATE SET
              timestamp = MAX(coverage_line_events.timestamp, excluded.timestamp),
              hits = MAX(coverage_line_events.hits, excluded.hits),
              is_partial = MAX(coverage_line_events.is_partial, excluded.is_partial)
            WHERE excluded.timestamp > coverage_line_events.timestamp
               OR excluded.hits > coverage_line_events.hits
               OR excluded.is_partial > coverage_line_events.is_partial
            "#,
            params![
                commit_hash,
                timestamp,
                path,
                line,
                hits,
                if is_partial { 1 } else { 0 },
                source
            ],
        )?;
        Ok(changed > 0)
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
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query(params![unit_id])?;
        Ok((column, rows.next()?.map(|row| row.get(0)).transpose()?))
    }

    pub fn insert_crash_event(&self, event: &CrashEvent) -> Result<bool> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT id, timestamp, is_verified
            FROM crash_events
            WHERE unit_id = ?1
              AND commit_hash = ?2
              AND error_class = ?3
              AND provider_id = ?4
              AND path = ?5
              AND line = ?6
              AND function = ?7
            ORDER BY id DESC
            LIMIT 1
            "#,
        )?;
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
            r#"
            INSERT INTO crash_events
              (unit_id, commit_hash, timestamp, error_class, provider_id,
               is_verified, path, line, function)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
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
            r#"
            INSERT INTO test_exposure_events
              (unit_id, commit_hash, timestamp, path, function, line, branch_id,
               test_id, test_type, mutation_status, mutation_kind, is_mutation_verified,
               is_mutation_killed, is_verified, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, COALESCE(?11, ''), ?12, ?13, ?14, ?15)
            ON CONFLICT DO UPDATE SET
              timestamp = MAX(test_exposure_events.timestamp, excluded.timestamp),
              function = COALESCE(excluded.function, test_exposure_events.function),
              mutation_status = COALESCE(excluded.mutation_status, test_exposure_events.mutation_status),
              mutation_kind = CASE
                WHEN lower(COALESCE(test_exposure_events.mutation_kind, '')) IN ('invariant', 'contract') THEN test_exposure_events.mutation_kind
                WHEN lower(COALESCE(excluded.mutation_kind, '')) IN ('invariant', 'contract') THEN excluded.mutation_kind
                WHEN COALESCE(excluded.mutation_kind, '') <> '' THEN excluded.mutation_kind
                ELSE test_exposure_events.mutation_kind
              END,
              is_mutation_verified = MAX(test_exposure_events.is_mutation_verified, excluded.is_mutation_verified),
              is_mutation_killed = MAX(test_exposure_events.is_mutation_killed, excluded.is_mutation_killed),
              is_verified = MAX(test_exposure_events.is_verified, excluded.is_verified),
              payload_json = excluded.payload_json
            WHERE excluded.timestamp > test_exposure_events.timestamp
               OR excluded.is_mutation_verified > test_exposure_events.is_mutation_verified
               OR excluded.is_mutation_killed > test_exposure_events.is_mutation_killed
               OR excluded.is_verified > test_exposure_events.is_verified
               OR COALESCE(excluded.mutation_kind, '') <> COALESCE(test_exposure_events.mutation_kind, '')
               OR excluded.payload_json <> test_exposure_events.payload_json
            "#,
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

    pub fn deactivate_active_hazards(&self, language: &str) -> Result<usize> {
        Ok(self.conn.execute(
            "UPDATE unit_hazards SET is_active = 0 WHERE language = ?1 AND is_active = 1",
            params![language],
        )?)
    }

    pub fn insert_hazard_event(&self, event: &HazardEvent) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO unit_hazards
              (unit_id, language, hazard_type, required_evidence, path, line,
               symbol, source, detected_at_hash, is_active, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
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
        let mut latest_stmt = self.conn.prepare(
            r#"
            SELECT commit_hash, timestamp
            FROM test_exposure_events
            WHERE unit_id = ?1
            ORDER BY timestamp DESC, id DESC
            LIMIT 1
            "#,
        )?;
        let mut latest_rows = latest_stmt.query(params![unit_id])?;
        let Some(latest_row) = latest_rows.next()? else {
            return Ok(());
        };
        let latest_commit: String = latest_row.get(0)?;
        let latest_timestamp: i64 = latest_row.get(1)?;

        let distinct_tests: i64 = self.conn.query_row(
            r#"
            SELECT COUNT(DISTINCT test_id)
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2
            "#,
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mutant_verified: i64 = self.conn.query_row(
            r#"
            SELECT COUNT(DISTINCT test_id)
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND is_mutation_verified = 1
            "#,
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mutant_killed: i64 = self.conn.query_row(
            r#"
            SELECT COUNT(DISTINCT test_id)
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND is_mutation_killed = 1
            "#,
            params![unit_id, latest_commit],
            |row| row.get(0),
        )?;
        let mut type_stmt = self.conn.prepare(
            r#"
            SELECT DISTINCT test_type
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND test_type <> ''
            ORDER BY test_type
            "#,
        )?;
        let type_rows = type_stmt.query_map(params![unit_id, latest_commit], |row| {
            row.get::<_, String>(0)
        })?;
        let test_types = type_rows
            .collect::<Result<Vec<_>, _>>()?
            .join(",");

        self.conn.execute(
            r#"
            UPDATE logical_units
            SET current_distinct_tests = ?2,
                current_test_types = ?3,
                current_mutant_verified_tests = ?4,
                current_mutant_killed_tests = ?5,
                last_test_exposure_at = ?6
            WHERE id = ?1
            "#,
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
        let result = self.conn.execute_batch(
            r#"
            DELETE FROM ui_file_summaries;
            DELETE FROM ui_warning_units;

            WITH latest_events AS (
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
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     u.current_line_cov,
                     u.current_mutant_cov,
                     u.current_distinct_tests,
                     u.current_mutant_killed_tests
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            ),
            unit_file AS (
              SELECT current_path AS path,
                     COUNT(DISTINCT id) AS units,
                     COALESCE(SUM(current_distinct_tests), 0) AS distinct_tests,
                     COALESCE(SUM(current_mutant_killed_tests), 0) AS mutant_killed_tests,
                     COALESCE(AVG(current_line_cov), 0.0) AS fallback_line_coverage,
                     COALESCE(AVG(current_mutant_cov), 0.0) AS mutant_coverage
              FROM current_units
              WHERE current_path <> ''
              GROUP BY current_path
            ),
            latest_source_lines AS (
              SELECT path, line, source, hits
              FROM (
                SELECT path, line, source, hits,
                       ROW_NUMBER() OVER (
                         PARTITION BY path, line, source
                         ORDER BY timestamp DESC, id DESC
                       ) AS rank
                FROM coverage_line_events
              )
              WHERE rank = 1
            ),
            latest_lines AS (
              SELECT path, line, MAX(hits) AS hits
              FROM latest_source_lines
              GROUP BY path, line
            ),
            line_file AS (
              SELECT path,
                     COUNT(*) AS tracked_lines,
                     SUM(CASE WHEN hits > 0 THEN 1 ELSE 0 END) AS covered_lines
              FROM latest_lines
              GROUP BY path
            ),
            ranked_exposure AS (
              SELECT path, line, branch_id, test_id, test_type, is_verified,
                     is_mutation_verified, is_mutation_killed, mutation_kind,
                     ROW_NUMBER() OVER (
                       PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                       ORDER BY timestamp DESC, id DESC
                     ) AS rank
              FROM test_exposure_events
              WHERE line IS NOT NULL
            ),
            latest_exposure AS (
              SELECT *
              FROM ranked_exposure
              WHERE rank = 1
            ),
            line_exposure AS (
              SELECT e.path,
                     e.line,
                     l.hits,
                     COUNT(DISTINCT CASE WHEN e.is_verified = 1 THEN e.test_type END) AS verified_test_types,
                     MAX(CASE WHEN e.is_verified = 1 AND e.is_mutation_verified = 1 THEN 1 ELSE 0 END) AS mutant_verified,
                     MAX(CASE WHEN e.is_verified = 1 AND e.is_mutation_killed = 1 THEN 1 ELSE 0 END) AS mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_verified = 1
                        AND lower(COALESCE(e.mutation_kind, '')) = 'stochastic'
                       THEN 1 ELSE 0
                     END) AS stochastic_mutant_verified,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_killed = 1
                        AND lower(COALESCE(e.mutation_kind, '')) = 'stochastic'
                       THEN 1 ELSE 0
                     END) AS stochastic_mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_killed = 1
                        AND lower(COALESCE(e.mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS invariant_mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_verified = 1
                        AND lower(COALESCE(e.mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS invariant_mutant_verified
              FROM latest_exposure e
              JOIN latest_lines l
                ON l.path = e.path
               AND l.line = e.line
               AND l.hits > 0
              GROUP BY e.path, e.line
            ),
            exposure_file AS (
              SELECT path,
                     SUM(mutant_verified) AS mutant_verified_covered_lines,
                     SUM(mutant_killed) AS mutant_killed_covered_lines,
                     SUM(stochastic_mutant_verified) AS stochastic_mutant_verified_covered_lines,
                     SUM(stochastic_mutant_killed) AS stochastic_mutant_killed_covered_lines,
                     SUM(invariant_mutant_verified) AS invariant_mutant_verified_covered_lines,
                     SUM(invariant_mutant_killed) AS invariant_mutant_killed_covered_lines,
                     SUM(CASE WHEN verified_test_types >= 2 OR hits > 1 THEN 1 ELSE 0 END) AS multi_type_covered_lines
              FROM line_exposure
              GROUP BY path
            ),
            active_hazards AS (
              SELECT *
              FROM unit_hazards
              WHERE is_active = 1
            ),
            hazard_ranked_exposure AS (
              SELECT t.unit_id,
                     t.path,
                     t.line,
                     t.branch_id,
                     t.test_id,
                     t.test_type,
                     t.is_verified,
                     t.is_mutation_killed,
                     t.mutation_kind,
                     ROW_NUMBER() OVER (
                       PARTITION BY t.path, t.line, COALESCE(t.branch_id, ''), t.test_id, t.test_type
                       ORDER BY t.timestamp DESC, t.id DESC
                     ) AS rank
              FROM test_exposure_events t
              JOIN active_hazards h
                ON h.unit_id = t.unit_id
               AND h.path = t.path
               AND h.line = t.line
              WHERE t.line IS NOT NULL
            ),
            hazard_latest_exposure AS (
              SELECT *
              FROM hazard_ranked_exposure
              WHERE rank = 1
            ),
            hazard_evidence AS (
              SELECT unit_id,
                     path,
                     line,
                     lower(test_type) AS test_type,
                     MAX(CASE WHEN is_verified = 1 THEN 1 ELSE 0 END) AS has_evidence,
                     MAX(CASE
                       WHEN is_verified = 1
                        AND is_mutation_killed = 1
                        AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS has_invariant_mutation
              FROM hazard_latest_exposure
              GROUP BY unit_id, path, line, lower(test_type)
            ),
            hazard_rows AS (
              SELECT h.id,
                     h.path,
                     CASE
                       WHEN MAX(CASE
                              WHEN (e.test_type = lower(h.required_evidence)
                                 OR e.test_type LIKE '%' || lower(h.required_evidence) || '%')
                               AND e.has_evidence = 1
                              THEN 1 ELSE 0
                            END) = 1
                         OR MAX(CASE
                              WHEN ls.hits > 0
                               AND (lower(ls.source) = lower(h.required_evidence)
                                 OR lower(ls.source) LIKE '%' || lower(h.required_evidence) || '%')
                              THEN 1 ELSE 0
                            END) = 1
                       THEN 1 ELSE 0
                     END AS evidence_present,
                     CASE
                       WHEN MAX(CASE WHEN l.hits > 0 THEN 1 ELSE 0 END) = 1
                         OR MAX(CASE
                              WHEN (e.test_type = lower(h.required_evidence)
                                 OR e.test_type LIKE '%' || lower(h.required_evidence) || '%')
                               AND e.has_evidence = 1
                              THEN 1 ELSE 0
                            END) = 1
                         OR MAX(CASE
                              WHEN ls.hits > 0
                               AND (lower(ls.source) = lower(h.required_evidence)
                                 OR lower(ls.source) LIKE '%' || lower(h.required_evidence) || '%')
                              THEN 1 ELSE 0
                            END) = 1
                       THEN 1 ELSE 0
                     END AS verified
              FROM active_hazards h
              LEFT JOIN hazard_evidence e
                ON e.unit_id = h.unit_id
               AND e.path = h.path
               AND e.line = h.line
              LEFT JOIN latest_lines l
                ON l.path = h.path
               AND l.line = h.line
              LEFT JOIN latest_source_lines ls
                ON ls.path = h.path
               AND ls.line = h.line
              GROUP BY h.id, h.path
            ),
            hazard_file AS (
              SELECT path,
                     COUNT(*) AS hazards,
                     SUM(evidence_present) AS evidence_covered_hazards,
                     SUM(verified) AS covered_hazards
              FROM hazard_rows
              GROUP BY path
            ),
            paths AS (
              SELECT path FROM unit_file
              UNION
              SELECT path FROM line_file
              UNION
              SELECT path FROM exposure_file
              UNION
              SELECT path FROM hazard_file
            )
            INSERT INTO ui_file_summaries (
              path,
              units,
              hazards,
              evidence_covered_hazards,
              covered_hazards,
              distinct_tests,
              mutant_killed_tests,
              tracked_lines,
              covered_lines,
              line_coverage,
              mutant_coverage,
              mutant_verified_covered_lines,
              mutant_killed_covered_lines,
              stochastic_mutant_verified_covered_lines,
              stochastic_mutant_killed_covered_lines,
              invariant_mutant_verified_covered_lines,
              invariant_mutant_killed_covered_lines,
              multi_type_covered_lines
            )
            SELECT p.path,
                   COALESCE(uf.units, 0),
                   COALESCE(hf.hazards, 0),
                   COALESCE(hf.evidence_covered_hazards, 0),
                   COALESCE(hf.covered_hazards, 0),
                   COALESCE(uf.distinct_tests, 0),
                   COALESCE(uf.mutant_killed_tests, 0),
                   COALESCE(lf.tracked_lines, 0),
                   COALESCE(lf.covered_lines, 0),
                   CASE
                     WHEN COALESCE(lf.tracked_lines, 0) > 0
                     THEN 100.0 * COALESCE(lf.covered_lines, 0) / lf.tracked_lines
                     ELSE COALESCE(uf.fallback_line_coverage, 0.0)
                   END,
                   COALESCE(uf.mutant_coverage, 0.0),
                   COALESCE(ef.mutant_verified_covered_lines, 0),
                   COALESCE(ef.mutant_killed_covered_lines, 0),
                   COALESCE(ef.stochastic_mutant_verified_covered_lines, 0),
                   COALESCE(ef.stochastic_mutant_killed_covered_lines, 0),
                   COALESCE(ef.invariant_mutant_verified_covered_lines, 0),
                   COALESCE(ef.invariant_mutant_killed_covered_lines, 0),
                   COALESCE(ef.multi_type_covered_lines, 0)
            FROM paths p
            LEFT JOIN unit_file uf ON uf.path = p.path
            LEFT JOIN line_file lf ON lf.path = p.path
            LEFT JOIN exposure_file ef ON ef.path = p.path
            LEFT JOIN hazard_file hf ON hf.path = p.path
            WHERE p.path <> '';

            WITH latest_events AS (
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
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     u.current_distinct_tests,
                     u.current_mutant_verified_tests,
                     u.last_test_exposure_at
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            ),
            db_clock AS (
              SELECT COALESCE(MAX(timestamp), 0) AS observed_at
              FROM (
                SELECT timestamp FROM metadata
                UNION ALL SELECT timestamp FROM events
                UNION ALL SELECT timestamp FROM quality_events
                UNION ALL SELECT timestamp FROM crash_events
                UNION ALL SELECT timestamp FROM test_exposure_events
              )
            ),
            mutant_runs AS (
              SELECT unit_id, MAX(timestamp) AS last_mutant_run_at
              FROM test_exposure_events
              WHERE is_mutation_verified = 1 OR is_mutation_killed = 1
              GROUP BY unit_id
            ),
            event_counts AS (
              SELECT cu.id,
                     SUM(CASE
                       WHEN cu.last_test_exposure_at > 0
                        AND e.semantic_change = 1
                        AND e.event_type IN ('FIX', 'CHANGE')
                        AND e.timestamp > cu.last_test_exposure_at
                       THEN 1 ELSE 0
                     END) AS changes_after_test_exposure,
                     SUM(CASE
                       WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                        AND e.semantic_change = 1
                        AND e.event_type IN ('FIX', 'CHANGE')
                        AND e.timestamp > m.last_mutant_run_at
                       THEN 1 ELSE 0
                     END) AS semantic_changes_after_mutant_run
              FROM current_units cu
              LEFT JOIN mutant_runs m ON m.unit_id = cu.id
              LEFT JOIN events e ON e.unit_id = cu.id
              GROUP BY cu.id
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
            INSERT INTO ui_warning_units (
              unit_id,
              current_path,
              current_distinct_tests,
              current_mutant_verified_tests,
              last_test_exposure_at,
              last_mutant_run_at,
              changes_after_test_exposure,
              semantic_changes_after_mutant_run,
              verification_stale_seconds,
              reopened_count
            )
            SELECT cu.id,
                   cu.current_path,
                   cu.current_distinct_tests,
                   cu.current_mutant_verified_tests,
                   cu.last_test_exposure_at,
                   COALESCE(m.last_mutant_run_at, 0),
                   COALESCE(ec.changes_after_test_exposure, 0),
                   COALESCE(ec.semantic_changes_after_mutant_run, 0),
                   CASE
                     WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                      AND clock.observed_at > m.last_mutant_run_at
                     THEN clock.observed_at - m.last_mutant_run_at
                     ELSE 0
                   END,
                   COALESCE(r.reopened_count, 0)
            FROM current_units cu
            LEFT JOIN mutant_runs m ON m.unit_id = cu.id
            LEFT JOIN event_counts ec ON ec.id = cu.id
            LEFT JOIN reopened r ON r.unit_id = cu.id
            CROSS JOIN db_clock clock
            WHERE cu.current_path <> '';

            INSERT INTO ui_refresh_metadata (key, value)
            VALUES ('refreshed_at', strftime('%s', 'now'))
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            "#,
        );
        if let Err(error) = result {
            let _ = self.rollback_transaction();
            return Err(error.into());
        }
        self.commit_transaction()?;
        Ok(())
    }

    pub fn top_units(&self, limit: usize, only_prefixes: &[String]) -> Result<Vec<UnitSummary>> {
        let mut sql = String::new();
        sql.push_str(r#"
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
        "#);

        let raw_summaries: Vec<UnitSummary> = if only_prefixes.is_empty() {
            sql.push_str(r#"
                SELECT
                  u.id,
                  u.name,
                  u.type,
                  u.original_path,
                  COALESCE((
                    SELECT latest.path
                    FROM events latest
                    WHERE latest.unit_id = u.id
                    ORDER BY latest.timestamp DESC, latest.id DESC
                    LIMIT 1
                  ), u.original_path) AS current_path,
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
                JOIN events e ON e.unit_id = u.id
                LEFT JOIN mutant_runs m ON m.unit_id = u.id
                LEFT JOIN reopened r ON r.unit_id = u.id
                CROSS JOIN db_clock clock
                GROUP BY u.id, u.name, u.type, u.original_path,
                         u.current_distinct_tests, u.current_test_types,
                         u.current_mutant_verified_tests,
                         u.current_mutant_killed_tests, u.last_test_exposure_at,
                         m.last_mutant_run_at, r.reopened_count, clock.observed_at
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
                })
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        } else {
            sql.push_str(r#"
                , filtered_units AS (
                  SELECT * FROM (
                    SELECT u.*,
                           COALESCE((
                             SELECT latest.path
                             FROM events latest
                             WHERE latest.unit_id = u.id
                             ORDER BY latest.timestamp DESC, latest.id DESC
                             LIMIT 1
                           ), u.original_path) AS current_path
                    FROM logical_units u
                  )
                  WHERE 
            "#);
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
                         m.last_mutant_run_at, r.reopened_count, clock.observed_at
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
        Ok(out)
    }
}

fn configure_connection(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        PRAGMA foreign_keys = ON;
        PRAGMA synchronous = NORMAL;
        "#,
    )?;
    Ok(())
}

fn apply_decayed_risk(conn: &Connection, summaries: &mut HashMap<String, UnitSummary>) -> Result<()> {
    let mut stmt = conn.prepare(
        r#"
        WITH fix_commit_raw AS (
          SELECT commit_hash,
                 COUNT(DISTINCT CASE
                   WHEN NOT (
                     path LIKE 'spec/%'
                     OR path LIKE 'test/%'
                     OR path LIKE 'tests/%'
                     OR path LIKE 'transpile-tests/%'
                     OR path LIKE 'tools/fuzz/%'
                     OR path LIKE '%/spec/%'
                     OR path LIKE '%/test/%'
                     OR path LIKE '%_spec.%'
                     OR path LIKE '%_test.%'
                   )
                   THEN unit_id END) AS code_units,
                 COUNT(DISTINCT CASE
                   WHEN NOT (
                     path LIKE 'spec/%'
                     OR path LIKE 'test/%'
                     OR path LIKE 'tests/%'
                     OR path LIKE 'transpile-tests/%'
                     OR path LIKE 'tools/fuzz/%'
                     OR path LIKE '%/spec/%'
                     OR path LIKE '%/test/%'
                     OR path LIKE '%_spec.%'
                     OR path LIKE '%_test.%'
                   )
                   THEN path END) AS code_files,
                 COALESCE(SUM(CASE
                   WHEN NOT (
                     path LIKE 'spec/%'
                     OR path LIKE 'test/%'
                     OR path LIKE 'tests/%'
                     OR path LIKE 'transpile-tests/%'
                     OR path LIKE 'tools/fuzz/%'
                     OR path LIKE '%/spec/%'
                     OR path LIKE '%/test/%'
                     OR path LIKE '%_spec.%'
                     OR path LIKE '%_test.%'
                   )
                   THEN ABS(lines_added) + ABS(lines_removed) ELSE 0 END), 0) AS code_lines
          FROM events
          WHERE event_type = 'FIX'
            AND semantic_change = 1
          GROUP BY commit_hash
        ),
        fix_commit_profiles AS (
          SELECT commit_hash,
                 CASE
                   WHEN code_units BETWEEN 1 AND 3
                    AND code_files BETWEEN 1 AND 3
                    AND code_lines <= 80
                   THEN 1.0
                   WHEN code_units BETWEEN 1 AND 8
                    AND code_files BETWEEN 1 AND 5
                    AND code_lines <= 200
                   THEN 0.65
                   WHEN code_units BETWEEN 1 AND 20
                    AND code_files BETWEEN 1 AND 10
                    AND code_lines <= 500
                   THEN 0.30
                   ELSE 0.10
                 END AS target_factor
          FROM fix_commit_raw
        )
        SELECT e.unit_id,
               e.event_type,
               e.timestamp,
               CASE WHEN e.event_type = 'FIX'
                    THEN COALESCE(fp.target_factor, 0.10)
                    ELSE 1.0
               END AS target_factor,
               CASE
                 WHEN e.event_type = 'FIX'
                  AND COALESCE(fp.target_factor, 0.10) >= 0.65
                  AND EXISTS (
                    SELECT 1
                    FROM test_exposure_events t
                    WHERE t.unit_id = e.unit_id
                      AND t.timestamp > e.timestamp
                      AND t.is_mutation_killed = 1
                    LIMIT 1
                  )
                 THEN 0.25
                 ELSE 1.0
               END AS mutation_hardening_factor
        FROM events e
        LEFT JOIN fix_commit_profiles fp ON fp.commit_hash = e.commit_hash
        WHERE e.semantic_change = 1
          AND e.event_type IN ('FIX', 'CHANGE')
        "#,
    )?;
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
        | "unit_hazards"
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
        assert!(storage.insert_crash_event(&CrashEvent {
            unit_id: unit.id,
            commit_hash: "abc".into(),
            timestamp: 10,
            error_class: "RuntimeError".into(),
            provider_id: "evt-1".into(),
            is_verified: true,
            path: "src/a.rb".into(),
            line: 2,
            function: "run".into(),
        }).unwrap());

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
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .unwrap();

        assert_eq!(storage.count_rows("test_exposure_events").unwrap(), 2);
        assert_eq!(summary, (2, "integration,unit".into(), 1, 1, 10));
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
        let defs = storage.find_definitions("my_test_func", None, None).unwrap();
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
        let defs_after = storage.find_definitions("my_test_func", None, None).unwrap();
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
        let defs_exact = storage.find_definitions("MyClass.my_method", Some("c1"), None).unwrap();
        assert_eq!(defs_exact.len(), 1);
        assert_eq!(defs_exact[0].0, "src/my_class.rb");
        assert_eq!(defs_exact[0].1, 42);
        
        // Short name suffix
        let defs_suffix = storage.find_definitions("my_method", Some("c1"), None).unwrap();
        assert_eq!(defs_suffix.len(), 1);
        assert_eq!(defs_suffix[0].0, "src/my_class.rb");
        assert_eq!(defs_suffix[0].1, 42);
        
        // Different suffix separator or non-matching name
        let defs_non_match = storage.find_definitions("other_method", Some("c1"), None).unwrap();
        assert!(defs_non_match.is_empty());
    }
}
