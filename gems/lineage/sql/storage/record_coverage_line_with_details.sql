-- query-id: storage.record_coverage_line_with_details.v1
INSERT INTO coverage_line_events
              (commit_hash, timestamp, path, line, hits, is_partial, coverage_percent, source)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(commit_hash, path, line, source) DO UPDATE SET
              timestamp = MAX(coverage_line_events.timestamp, excluded.timestamp),
              hits = MAX(coverage_line_events.hits, excluded.hits),
              is_partial = MAX(coverage_line_events.is_partial, excluded.is_partial),
              coverage_percent = COALESCE(excluded.coverage_percent, coverage_line_events.coverage_percent)
            WHERE excluded.timestamp > coverage_line_events.timestamp
               OR excluded.hits > coverage_line_events.hits
               OR excluded.is_partial > coverage_line_events.is_partial
               OR COALESCE(excluded.coverage_percent, -1) <> COALESCE(coverage_line_events.coverage_percent, -1)
