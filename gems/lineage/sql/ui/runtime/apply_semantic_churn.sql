-- query-id: ui.runtime.apply_semantic_churn.v1
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
        ),
        latest_events AS (
          SELECT e.*
          FROM events e
          WHERE e.id = (
            SELECT latest.id
            FROM events latest
            WHERE latest.unit_id = e.unit_id
            ORDER BY latest.timestamp DESC, latest.id DESC
            LIMIT 1
          )
        )
        SELECT COALESCE(le.start_line, 1) AS current_start,
               COALESCE(le.end_line, le.start_line, 1) AS current_end,
               e.path,
               e.start_line,
               e.end_line,
               e.event_type,
               e.commit_hash,
               e.timestamp,
               e.name,
               COALESCE(m.message, '') AS message,
               CASE
                 WHEN ?2 = 1 THEN COALESCE((
                   SELECT MIN(CASE
                     WHEN q.metric_type = 'MUTANT_COV'
                      AND q.old_value IS NOT NULL
                      AND q.new_value >= 70.0
                      AND q.new_value - q.old_value >= 25.0
                     THEN 0.15
                     WHEN q.metric_type IN ('LINE_COV', 'INTEGRATION_COV')
                      AND q.old_value IS NOT NULL
                      AND q.new_value >= 80.0
                      AND q.new_value - q.old_value >= 25.0
                     THEN 0.35
                     WHEN q.metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV')
                      AND q.old_value IS NOT NULL
                      AND q.new_value - q.old_value >= 15.0
                     THEN 0.60
                     ELSE 1.0
                   END)
                   FROM quality_events q
                   WHERE q.unit_id = e.unit_id
                     AND q.timestamp > e.timestamp
                     AND q.metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV')
                 ), 1.0)
                 ELSE 1.0
               END AS protection_factor,
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
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        JOIN events e ON e.unit_id = u.id
        LEFT JOIN metadata m ON m.commit_hash = e.commit_hash
        LEFT JOIN fix_commit_profiles fp ON fp.commit_hash = e.commit_hash
        WHERE COALESCE(le.path, u.original_path) = ?1
          AND e.semantic_change = 1
          AND e.event_type IN ('CHANGE', 'FIX')
        ORDER BY e.timestamp DESC, e.id DESC
