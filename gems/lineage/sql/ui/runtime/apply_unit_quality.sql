-- query-id: ui.runtime.apply_unit_quality.v1
WITH latest_events AS (
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
        SELECT COALESCE(le.start_line, 1),
               COALESCE(le.end_line, le.start_line, 1),
               u.current_line_cov,
               u.current_mutant_cov,
               u.current_test_types
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
