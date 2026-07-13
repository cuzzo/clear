-- query-id: storage.apply_decayed_risk.v1
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
                  )
                 THEN 0.25
                 ELSE 1.0
               END AS mutation_hardening_factor
        FROM events e
        LEFT JOIN fix_commit_profiles fp ON fp.commit_hash = e.commit_hash
        WHERE e.semantic_change = 1
          AND e.event_type IN ('FIX', 'CHANGE')
