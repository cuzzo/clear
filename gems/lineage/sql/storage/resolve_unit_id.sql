-- query-id: storage.resolve_unit_id.v1
SELECT u.id
            FROM logical_units u
            WHERE u.name = ?2
              AND COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) = ?1
            ORDER BY u.created_at DESC
            LIMIT 1
