-- query-id: storage.current_unit_spans_for_path.v1
WITH filtered_units AS (
              SELECT id FROM logical_units WHERE original_path = ?1
              UNION
              SELECT unit_id AS id FROM events WHERE path = ?1
            ),
            latest_events AS (
              SELECT *
              FROM (
                SELECT e.*,
                       ROW_NUMBER() OVER (
                         PARTITION BY e.unit_id
                         ORDER BY e.timestamp DESC, e.id DESC
                       ) AS rank
                FROM events e
                WHERE e.unit_id IN (SELECT id FROM filtered_units)
              )
              WHERE rank = 1
            ),
            -- A unit's creating commit records no `events` row (only later
            -- changes/moves/fixes do), so `le.*` is NULL until then. Fall
            -- back to logical_units.start_line, which the engine always
            -- sets at creation, before the line-1 default.
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     COALESCE(le.start_line, u.start_line, 1) AS start_line,
                     COALESCE(le.end_line, le.start_line, u.start_line, 1) AS end_line
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
              WHERE u.id IN (SELECT id FROM filtered_units)
            )
            SELECT id, current_path, start_line, end_line
            FROM current_units
            WHERE current_path = ?1
