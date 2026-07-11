-- query-id: ui.runtime.file_versions.v1
WITH latest_events AS (
          SELECT e.unit_id, e.path
          FROM events e
          WHERE e.id = (
            SELECT latest.id
            FROM events latest
            WHERE latest.unit_id = e.unit_id
            ORDER BY latest.timestamp DESC, latest.id DESC
            LIMIT 1
          )
        ),
        current_units AS (
          SELECT u.id
          FROM logical_units u
          LEFT JOIN latest_events le ON le.unit_id = u.id
          WHERE COALESCE(le.path, u.original_path) = ?1
        ),
        union_query AS (
          SELECT e.commit_hash, e.timestamp, e.event_type, e.path, e.name,
                 e.start_line, e.end_line, e.semantic_change, e.id
          FROM current_units cu
          JOIN events e ON e.unit_id = cu.id
          UNION
          SELECT e.commit_hash, e.timestamp, e.event_type, e.path, e.name,
                 e.start_line, e.end_line, e.semantic_change, e.id
          FROM events e
          WHERE e.path = ?1
        )
        SELECT commit_hash, timestamp, event_type, path, name,
               start_line, end_line, semantic_change
        FROM union_query
        ORDER BY timestamp DESC, id DESC
        LIMIT 200
