-- query-id: storage.resolve_current_path_2.v1
WITH current_paths AS (
              SELECT DISTINCT COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) AS current_path
              FROM logical_units u
            )
            SELECT current_path
            FROM current_paths
            WHERE current_path LIKE ?1
            ORDER BY current_path
            LIMIT 2
