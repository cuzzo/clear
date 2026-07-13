-- query-id: ui.runtime.persisted_source_symbols.v1
WITH latest_events AS (
          SELECT *
          FROM (
            SELECT *,
                   ROW_NUMBER() OVER (
                     PARTITION BY unit_id
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM events
          )
          WHERE rank = 1
        )
        SELECT u.type,
               u.name,
               COALESCE(le.start_line, 1) AS start_line,
               COALESCE(le.end_line, le.start_line, 1) AS end_line
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        ORDER BY start_line, end_line, u.type, u.name
