-- query-id: ui.runtime.file_index_with_scope.v1
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
              SELECT
                u.id,
                COALESCE(le.path, u.original_path) AS current_path,
                u.current_line_cov,
                u.current_mutant_cov,
                u.current_distinct_tests,
                u.current_mutant_killed_tests
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            ),
            hazard_counts AS (
              SELECT unit_id, COUNT(*) AS hazards
              FROM unit_hazards
              WHERE is_active = 1
              GROUP BY unit_id
            )
            SELECT
              cu.current_path,
              COUNT(DISTINCT cu.id) AS units,
              COALESCE(SUM(hc.hazards), 0) AS hazards,
              COALESCE(SUM(cu.current_distinct_tests), 0) AS distinct_tests,
              COALESCE(SUM(cu.current_mutant_killed_tests), 0) AS mutant_killed_tests,
              COALESCE(AVG(cu.current_line_cov), 0.0) AS line_coverage,
              COALESCE(AVG(cu.current_mutant_cov), 0.0) AS mutant_coverage
            FROM current_units cu
            LEFT JOIN hazard_counts hc ON hc.unit_id = cu.id
            WHERE cu.current_path <> ''
            GROUP BY cu.current_path
            ORDER BY hazards DESC, mutant_killed_tests DESC, distinct_tests DESC, cu.current_path
