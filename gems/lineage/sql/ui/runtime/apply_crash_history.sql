-- query-id: ui.runtime.apply_crash_history.v1
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
        SELECT COALESCE(le.start_line, 1) AS current_start,
               COALESCE(le.end_line, le.start_line, 1) AS current_end,
               c.path,
               c.line,
               c.commit_hash,
               c.timestamp,
               c.error_class,
               c.provider_id,
               c.function
        FROM logical_units u
        LEFT JOIN latest_events le ON le.unit_id = u.id
        JOIN crash_events c ON c.unit_id = u.id
        WHERE COALESCE(le.path, u.original_path) = ?1
        ORDER BY c.timestamp DESC, c.id DESC
