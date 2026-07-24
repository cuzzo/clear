-- query-id: storage.find_definitions.v1
SELECT u.id,
              COALESCE((
                SELECT latest.path
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.original_path) AS path,
              COALESCE((
                SELECT latest.start_line
                FROM events latest
                WHERE latest.unit_id = u.id
                ORDER BY latest.timestamp DESC, latest.id DESC
                LIMIT 1
              ), u.start_line) AS start_line
            FROM logical_units u
            WHERE u.name = ?1
               OR u.name LIKE '%.' || ?1
               OR u.name LIKE '%::' || ?1
               OR u.name LIKE '%#' || ?1
            ORDER BY u.id
            LIMIT 100
