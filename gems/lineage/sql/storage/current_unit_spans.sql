-- query-id: storage.current_unit_spans.v1
WITH latest_events AS (
              SELECT *
              FROM (
                SELECT e.*,
                       ROW_NUMBER() OVER (
                         PARTITION BY e.unit_id
                         ORDER BY e.timestamp DESC, e.id DESC
                       ) AS rank
                FROM events e
              )
              WHERE rank = 1
            ),
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     COALESCE(le.start_line, 1) AS start_line,
                     COALESCE(le.end_line, le.start_line, 1) AS end_line
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path <> ''
