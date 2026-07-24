-- query-id: storage.refresh_current_sarif_findings_view.v1
CREATE TABLE IF NOT EXISTS current_sarif_findings (
  id INTEGER PRIMARY KEY,
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
  raw_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_current_sarif_findings_path_line
  ON current_sarif_findings(path, start_line);
CREATE INDEX IF NOT EXISTS idx_current_sarif_findings_source_commit
  ON current_sarif_findings(source, commit_hash);
CREATE INDEX IF NOT EXISTS idx_current_sarif_findings_unit_id
  ON current_sarif_findings(unit_id);
CREATE INDEX IF NOT EXISTS idx_current_sarif_findings_rule_id
  ON current_sarif_findings(rule_id);

DELETE FROM current_sarif_findings;

INSERT INTO current_sarif_findings
WITH finding_snapshots AS (
  SELECT path, source, tool_name, commit_hash,
         MAX(timestamp) AS timestamp,
         MAX(id) AS id
  FROM sarif_findings
  GROUP BY path, source, tool_name, commit_hash
),
ranked_snapshots AS (
  SELECT path, source, tool_name, commit_hash,
         ROW_NUMBER() OVER (
           PARTITION BY path, source, tool_name
           ORDER BY timestamp DESC, id DESC
         ) AS snapshot_rank
  FROM finding_snapshots
),
latest_snapshots AS (
  SELECT path, source, tool_name, commit_hash
  FROM ranked_snapshots
  WHERE snapshot_rank = 1
)
SELECT findings.id, findings.artifact_id, findings.finding_key, findings.source,
       findings.tool_name, findings.run_format, findings.commit_hash, findings.timestamp,
       findings.rule_id, findings.level, findings.message, findings.path,
       findings.start_line, findings.start_column, findings.end_line, findings.end_column,
       findings.category, findings.is_dark_arm, findings.unit_id, findings.fingerprint,
       findings.properties_json, findings.raw_json
FROM sarif_findings findings
JOIN latest_snapshots latest
  ON latest.path = findings.path
 AND latest.source = findings.source
 AND latest.tool_name = findings.tool_name
 AND latest.commit_hash = findings.commit_hash;
