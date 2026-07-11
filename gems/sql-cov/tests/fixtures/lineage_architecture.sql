CREATE TABLE logical_units (
  id TEXT PRIMARY KEY,
  current_distinct_tests INTEGER DEFAULT 0,
  current_line_cov REAL DEFAULT 0,
  current_mutant_cov REAL DEFAULT 0
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
  explanation_json TEXT
);
CREATE TABLE architecture_edges (
  artifact_id INTEGER NOT NULL,
  source_node_id TEXT NOT NULL,
  target_node_id TEXT NOT NULL
);
CREATE TABLE unit_hazards (unit_id TEXT, is_active INTEGER);
CREATE TABLE events (unit_id TEXT, event_type TEXT);

INSERT INTO logical_units VALUES ('unit:1', 2, 80.0, 60.0);
INSERT INTO architecture_nodes VALUES
  (1, 'fn:match', 'unit:1', 'owner:1', 'function', 'match', 'Demo', 'ruby', 'demo.rb', 2, 0, 4, 3, 'high', '{}'),
  (1, 'fn:other', NULL, 'owner:2', 'function', 'other', 'Other', 'ruby', 'other.rb', 2, 0, 4, 3, 'high', '{}'),
  (2, 'fn:old', NULL, 'owner:1', 'function', 'old', 'Demo', 'ruby', 'demo.rb', 5, 0, 7, 3, 'high', '{}'),
  (1, 'fn:unknown', NULL, NULL, 'function', 'unknown', 'Demo', 'ruby', 'demo.rb', 8, 0, 9, 3, 'partial', '{}');
INSERT INTO architecture_pressure VALUES (1, 'fn:match', 70.0, 'orange', '{}');
