use crate::model::{CommitMetadata, Event, LogicalUnit};
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
    pub total_events: i64,
    pub changes: i64,
    pub moves: i64,
    pub fixes: i64,
    pub risk_score: f64,
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
              created_at INTEGER NOT NULL
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

            CREATE INDEX IF NOT EXISTS idx_events_unit_id ON events(unit_id);
            CREATE INDEX IF NOT EXISTS idx_events_commit_hash ON events(commit_hash);
            CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
            "#,
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
              COUNT(e.id) AS total_events,
              SUM(CASE WHEN e.event_type = 'CHANGE' THEN 1 ELSE 0 END) AS changes,
              SUM(CASE WHEN e.event_type = 'MOVE' THEN 1 ELSE 0 END) AS moves,
              SUM(CASE WHEN e.event_type = 'FIX' THEN 1 ELSE 0 END) AS fixes
            FROM logical_units u
            JOIN events e ON e.unit_id = u.id
            GROUP BY u.id, u.name, u.type, u.original_path
            "#,
        )?;

        let rows = stmt.query_map([], |row| {
            Ok(UnitSummary {
                id: row.get(0)?,
                name: row.get(1)?,
                kind: row.get(2)?,
                original_path: row.get(3)?,
                total_events: row.get(4)?,
                changes: row.get(5)?,
                moves: row.get(6)?,
                fixes: row.get(7)?,
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
                    .any(|prefix| summary.original_path.starts_with(prefix))
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
                .then_with(|| left.original_path.cmp(&right.original_path))
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
        "logical_units" | "events" | "metadata" => Ok(table),
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
}
