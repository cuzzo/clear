-- query-id: storage.resolve_current_path_2.v2
SELECT e.path AS current_path
FROM events e
WHERE e.path LIKE ?1
  AND e.id = (
    SELECT latest.id
    FROM events latest
    WHERE latest.unit_id = e.unit_id
    ORDER BY latest.timestamp DESC, latest.id DESC
    LIMIT 1
  )
UNION ALL
SELECT u.original_path AS current_path
FROM logical_units u
WHERE u.original_path LIKE ?1
  AND NOT EXISTS (
    SELECT 1 FROM events e WHERE e.unit_id = u.id
  )
ORDER BY current_path
LIMIT 2;
