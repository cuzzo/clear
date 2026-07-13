CREATE TABLE logical_units (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  original_path TEXT NOT NULL,
  start_line INTEGER NOT NULL,
  current_distinct_tests INTEGER DEFAULT 0,
  current_line_cov REAL DEFAULT 0,
  current_mutant_cov REAL DEFAULT 0
);
CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  unit_id TEXT,
  timestamp INTEGER,
  path TEXT,
  start_line INTEGER,
  event_type TEXT
);
CREATE TABLE architecture_artifacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  analyzer TEXT NOT NULL,
  analyzer_version TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  commit_hash TEXT NOT NULL,
  root TEXT NOT NULL,
  complete INTEGER NOT NULL,
  generated_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE architecture_nodes (
  artifact_id INTEGER NOT NULL,
  analyzer_node_id TEXT NOT NULL,
  logical_unit_id TEXT,
  owner_node_id TEXT,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  owner TEXT,
  language TEXT,
  path TEXT,
  start_line INTEGER NOT NULL,
  start_column INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  end_column INTEGER NOT NULL,
  confidence TEXT NOT NULL,
  metadata_json TEXT NOT NULL
);
CREATE TABLE architecture_pressure (
  artifact_id INTEGER NOT NULL,
  node_id TEXT NOT NULL,
  score REAL,
  band TEXT,
  collaboration REAL,
  state REAL,
  implementation REAL,
  operational REAL,
  explanation_json TEXT
);
CREATE TABLE architecture_edges (
  artifact_id INTEGER NOT NULL,
  edge_id TEXT NOT NULL,
  source_node_id TEXT NOT NULL,
  target_node_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  conditional INTEGER NOT NULL,
  weight INTEGER NOT NULL,
  confidence TEXT NOT NULL,
  metadata_json TEXT NOT NULL
);
CREATE TABLE architecture_edge_spans (
  artifact_id INTEGER NOT NULL,
  edge_id TEXT NOT NULL,
  path TEXT NOT NULL,
  start_line INTEGER NOT NULL,
  start_column INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  end_column INTEGER NOT NULL
);
CREATE TABLE unit_hazards (unit_id TEXT, is_active INTEGER);

INSERT INTO logical_units VALUES
  ('unit:1', 'match', 'function', 'demo.rb', 2, 2, 80.0, 60.0),
  ('unit:2', 'other', 'function', 'other.rb', 2, 0, 0.0, 0.0);
INSERT INTO events VALUES (1, 'unit:1', 1, 'demo.rb', 2, 'CHANGE');
INSERT INTO architecture_artifacts
  (id, analyzer, analyzer_version, schema_version, commit_hash, root, complete, generated_at, payload_json)
VALUES (1, 'espalier', 'test', 1, 'abc', '.', 1, 'now', '{}');
INSERT INTO architecture_nodes VALUES
  (1, 'owner:1', NULL, NULL, 'owner', 'Demo', 'Demo', 'ruby', 'demo.rb', 1, 0, 10, 3, 'high', '{}'),
  (1, 'fn:match', 'unit:1', 'owner:1', 'function', 'match', 'Demo', 'ruby', 'demo.rb', 2, 0, 4, 3, 'high', '{}'),
  (1, 'fn:other', NULL, 'owner:2', 'function', 'other', 'Other', 'ruby', 'other.rb', 2, 0, 4, 3, 'high', '{}'),
  (2, 'fn:old', NULL, 'owner:1', 'function', 'old', 'Demo', 'ruby', 'demo.rb', 5, 0, 7, 3, 'partial', '{}'),
  (1, 'fn:unknown', NULL, NULL, 'function', 'unknown', 'Demo', 'ruby', 'demo.rb', 8, 0, 9, 3, 'partial', '{}');
INSERT INTO architecture_pressure VALUES (1, 'fn:match', 70.0, 'orange', 0, 0, 0, 0, '{}');
INSERT INTO architecture_edges VALUES
  (1, 'edge:1', 'fn:match', 'fn:other', 'calls', 0, 1, 'high', '{}');
INSERT INTO architecture_edge_spans VALUES (1, 'edge:1', 'demo.rb', 2, 0, 2, 5);
