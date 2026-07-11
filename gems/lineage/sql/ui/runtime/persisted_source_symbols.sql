-- query-id: ui.runtime.persisted_source_symbols.v1
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
        SELECT u.type,
               u.name,
               COALESCE(le.start_line, 1) AS start_line,
               COALESCE(le.end_line, le.start_line, 1) AS end_line
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        ORDER BY start_line, end_line, u.type, u.name
