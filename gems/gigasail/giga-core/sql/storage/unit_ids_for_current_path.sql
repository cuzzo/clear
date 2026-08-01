-- query-id: storage.unit_ids_for_current_path.v1
SELECT u.id
            FROM logical_units u
            WHERE COALESCE((
              SELECT latest.path
              FROM events latest
              WHERE latest.unit_id = u.id
              ORDER BY latest.timestamp DESC, latest.id DESC
              LIMIT 1
            ), u.original_path) = ?1
            ORDER BY u.name, u.id
