-- query-id: storage.init_schema.v1

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

            CREATE TABLE IF NOT EXISTS unit_hotness (
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

            CREATE TABLE IF NOT EXISTS coverage_line_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              commit_hash TEXT NOT NULL,
              timestamp INTEGER NOT NULL,
              path TEXT NOT NULL,
              line INTEGER NOT NULL,
              hits INTEGER NOT NULL,
              is_partial INTEGER NOT NULL DEFAULT 0,
              coverage_percent REAL,
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
              partial_lines INTEGER NOT NULL DEFAULT 0,
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

            CREATE TABLE IF NOT EXISTS architecture_artifacts (
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

            CREATE TABLE IF NOT EXISTS architecture_nodes (
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
              metadata_json TEXT NOT NULL,
              PRIMARY KEY (artifact_id, analyzer_node_id),
              FOREIGN KEY(artifact_id) REFERENCES architecture_artifacts(id) ON DELETE CASCADE,
              FOREIGN KEY(logical_unit_id) REFERENCES logical_units(id)
            );

            CREATE TABLE IF NOT EXISTS architecture_edges (
              artifact_id INTEGER NOT NULL,
              edge_id TEXT NOT NULL,
              source_node_id TEXT NOT NULL,
              target_node_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              conditional INTEGER NOT NULL,
              weight INTEGER NOT NULL,
              confidence TEXT NOT NULL,
              metadata_json TEXT NOT NULL,
              PRIMARY KEY (artifact_id, edge_id),
              FOREIGN KEY(artifact_id) REFERENCES architecture_artifacts(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS architecture_edge_spans (
              artifact_id INTEGER NOT NULL,
              edge_id TEXT NOT NULL,
              path TEXT NOT NULL,
              start_line INTEGER NOT NULL,
              start_column INTEGER NOT NULL,
              end_line INTEGER NOT NULL,
              end_column INTEGER NOT NULL,
              FOREIGN KEY(artifact_id) REFERENCES architecture_artifacts(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS architecture_pressure (
              artifact_id INTEGER NOT NULL,
              node_id TEXT NOT NULL,
              score REAL NOT NULL,
              band TEXT NOT NULL,
              collaboration REAL NOT NULL,
              state REAL NOT NULL,
              implementation REAL NOT NULL,
              operational REAL NOT NULL,
              explanation_json TEXT NOT NULL,
              PRIMARY KEY (artifact_id, node_id),
              FOREIGN KEY(artifact_id) REFERENCES architecture_artifacts(id) ON DELETE CASCADE
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
            CREATE INDEX IF NOT EXISTS idx_unit_hotness_path ON unit_hotness(path, is_active);
            CREATE INDEX IF NOT EXISTS idx_unit_hotness_source ON unit_hotness(source, is_active);
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
            CREATE INDEX IF NOT EXISTS idx_sarif_findings_composite_latest
              ON sarif_findings(path, source, tool_name, commit_hash, timestamp, id);
            CREATE INDEX IF NOT EXISTS idx_ui_file_summaries_path ON ui_file_summaries(path);
            CREATE INDEX IF NOT EXISTS idx_ui_warning_units_path ON ui_warning_units(current_path);
            CREATE INDEX IF NOT EXISTS idx_events_path ON events(path);
            CREATE INDEX IF NOT EXISTS idx_logical_units_original_path ON logical_units(original_path);
            CREATE INDEX IF NOT EXISTS idx_architecture_artifacts_commit ON architecture_artifacts(commit_hash, id DESC);
            CREATE INDEX IF NOT EXISTS idx_architecture_nodes_owner ON architecture_nodes(artifact_id, owner_node_id, kind);
            CREATE INDEX IF NOT EXISTS idx_architecture_nodes_logical ON architecture_nodes(logical_unit_id);
            CREATE INDEX IF NOT EXISTS idx_architecture_nodes_path ON architecture_nodes(artifact_id, path, start_line);
            CREATE INDEX IF NOT EXISTS idx_architecture_edges_source ON architecture_edges(artifact_id, source_node_id, kind);
            CREATE INDEX IF NOT EXISTS idx_architecture_edges_target ON architecture_edges(artifact_id, target_node_id, kind);
