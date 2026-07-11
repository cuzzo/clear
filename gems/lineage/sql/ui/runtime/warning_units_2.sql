-- query-id: ui.runtime.warning_units_2.v1
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
        SELECT cu.current_path,
               cu.current_distinct_tests,
               cu.current_mutant_verified_tests,
               cu.last_test_exposure_at,
               COALESCE(m.last_mutant_run_at, 0) AS last_mutant_run_at,
               COALESCE(ec.changes_after_test_exposure, 0) AS changes_after_test_exposure,
               COALESCE(ec.semantic_changes_after_mutant_run, 0) AS semantic_changes_after_mutant_run,
               CASE
                 WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                  AND clock.observed_at > m.last_mutant_run_at
                 THEN clock.observed_at - m.last_mutant_run_at
                 ELSE 0
               END AS verification_stale_seconds,
               COALESCE(r.reopened_count, 0) AS reopened_count
        FROM current_units cu
        LEFT JOIN mutant_runs m ON m.unit_id = cu.id
        LEFT JOIN event_counts ec ON ec.id = cu.id
        LEFT JOIN reopened r ON r.unit_id = cu.id
        CROSS JOIN db_clock clock
