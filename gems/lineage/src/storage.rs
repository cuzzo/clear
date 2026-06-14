use crate::model::{
    CommitMetadata, CrashEvent, Event, LogicalUnit, QualityEvent, QualityMetric,
    TestExposureEvent,
};
use anyhow::Result;
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::path::Path;

pub struct Storage {
    conn: Connection,
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
    pub latest_fix_at: i64,
    pub latest_change_at: i64,
    pub fixes_after_test_exposure: i64,
    pub changes_after_test_exposure: i64,
}

impl Storage {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        let storage = Self { conn };
        storage.init_schema()?;
        Ok(storage)
    }

    pub fn open_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
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
              is_mutation_verified INTEGER NOT NULL CHECK (is_mutation_verified IN (0, 1)),
              is_mutation_killed INTEGER NOT NULL CHECK (is_mutation_killed IN (0, 1)),
              is_verified INTEGER NOT NULL CHECK (is_verified IN (0, 1)),
              payload_json TEXT NOT NULL,
              FOREIGN KEY(unit_id) REFERENCES logical_units(id)
            );

            CREATE INDEX IF NOT EXISTS idx_events_unit_id ON events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_events_commit_hash ON events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
            CREATE INDEX IF NOT EXISTS idx_quality_events_unit_id ON quality_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_quality_events_commit_hash ON quality_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_crash_events_unit_id ON crash_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_crash_events_commit_hash ON crash_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_unit_id ON test_exposure_events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_commit_hash ON test_exposure_events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_test_id ON test_exposure_events(test_id);
            CREATE INDEX IF NOT EXISTS idx_test_exposure_events_type ON test_exposure_events(test_type);
            "#,
        )?;
        self.ensure_logical_unit_column("current_line_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("current_integration_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("current_mutant_cov", "REAL DEFAULT 0.0")?;
        self.ensure_logical_unit_column("is_hard_gated", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_distinct_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_test_types", "TEXT DEFAULT ''")?;
        self.ensure_logical_unit_column("current_mutant_verified_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("current_mutant_killed_tests", "INTEGER DEFAULT 0")?;
        self.ensure_logical_unit_column("last_test_exposure_at", "INTEGER DEFAULT 0")?;
        Ok(())
    }

    fn ensure_logical_unit_column(&self, name: &str, definition: &str) -> Result<()> {
        let mut stmt = self.conn.prepare("PRAGMA table_info(logical_units)")?;
        let columns = stmt.query_map([], |row| row.get::<_, String>(1))?;
        for column in columns {
            if column? == name {
                return Ok(());
            }
        }
        self.conn.execute(
            &format!("ALTER TABLE logical_units ADD COLUMN {name} {definition}"),
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

    pub fn upsert_logical_unit(&self, unit: &LogicalUnit, created_at: i64) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO logical_units (id, name, type, original_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(id) DO NOTHING
            "#,
            params![unit.id, unit.name, unit.kind.as_str(), unit.path, created_at],
        )?;
        Ok(())
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

    pub fn insert_crash_event(&self, event: &CrashEvent) -> Result<()> {
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
        Ok(())
    }

    pub fn insert_test_exposure_event(&self, event: &TestExposureEvent) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO test_exposure_events
              (unit_id, commit_hash, timestamp, path, function, line, branch_id,
               test_id, test_type, mutation_status, is_mutation_verified,
               is_mutation_killed, is_verified, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
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
                if event.is_mutation_verified { 1 } else { 0 },
                if event.is_mutation_killed { 1 } else { 0 },
                if event.is_verified { 1 } else { 0 },
                event.payload_json
            ],
        )?;
        self.refresh_test_exposure_summary(&event.unit_id)?;
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

    pub fn top_units(&self, limit: usize, only_prefixes: &[String]) -> Result<Vec<UnitSummary>> {
        let mut stmt = self.conn.prepare(
            r#"
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
              END) AS changes_after_test_exposure
            FROM logical_units u
            JOIN events e ON e.unit_id = u.id
            GROUP BY u.id, u.name, u.type, u.original_path,
                     u.current_distinct_tests, u.current_test_types,
                     u.current_mutant_verified_tests,
                     u.current_mutant_killed_tests, u.last_test_exposure_at
            "#,
        )?;

        let rows = stmt.query_map([], |row| {
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
                latest_fix_at: row.get(14)?,
                latest_change_at: row.get(15)?,
                fixes_after_test_exposure: row.get(16)?,
                changes_after_test_exposure: row.get(17)?,
                risk_score: 0.0,
            })
        })?;

        let mut summaries = rows
            .collect::<Result<Vec<_>, _>>()?
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

fn apply_decayed_risk(conn: &Connection, summaries: &mut HashMap<String, UnitSummary>) -> Result<()> {
    let mut stmt = conn.prepare(
        r#"
        SELECT unit_id, event_type, timestamp
        FROM events
        WHERE semantic_change = 1
          AND event_type IN ('FIX', 'CHANGE')
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    let events = rows.collect::<Result<Vec<_>, _>>()?;
    if events.is_empty() {
        return Ok(());
    }

    let first = events.iter().map(|(_, _, timestamp)| *timestamp).min().unwrap_or(0);
    let last = events.iter().map(|(_, _, timestamp)| *timestamp).max().unwrap_or(first);
    let span = (last - first) as f64;
    for (unit_id, event_type, timestamp) in events {
        if let Some(summary) = summaries.get_mut(&unit_id) {
            let t = if span == 0.0 {
                1.0
            } else {
                (timestamp - first) as f64 / span
            };
            let weight = 1.0 / (1.0 + ((-12.0 * t) + 12.0).exp());
            let multiplier = if event_type == "FIX" { 4.0 } else { 1.0 };
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
        | "test_exposure_events" => Ok(table),
        _ => anyhow::bail!("unsupported table {table:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{EventType, UnitKind};

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
        storage.insert_crash_event(&CrashEvent {
            unit_id: unit.id,
            commit_hash: "abc".into(),
            timestamp: 10,
            error_class: "RuntimeError".into(),
            provider_id: "evt-1".into(),
            is_verified: true,
            path: "src/a.rb".into(),
            line: 2,
            function: "run".into(),
        }).unwrap();

        assert_eq!(storage.count_rows("crash_events").unwrap(), 1);
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
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_event(&Event {
                unit_id: unit.id,
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

        let top = storage.top_units(10, &[]).unwrap();

        assert_eq!(top.len(), 1);
        assert_eq!(top[0].current_distinct_tests, 1);
        assert_eq!(top[0].current_test_types, "unit");
        assert_eq!(top[0].current_mutant_verified_tests, 1);
        assert_eq!(top[0].current_mutant_killed_tests, 1);
        assert_eq!(top[0].last_test_exposure_at, 20);
        assert_eq!(top[0].latest_fix_at, 30);
        assert_eq!(top[0].fixes_after_test_exposure, 1);
    }
}
