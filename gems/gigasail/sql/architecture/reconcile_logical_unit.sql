-- query-id: architecture.reconcile_logical_unit.v1
-- result: logical_unit_id:text?
WITH latest_events AS (
  SELECT e.*
  FROM events e
  WHERE e.id = (
    SELECT x.id
    FROM events x
    WHERE x.unit_id = e.unit_id
    ORDER BY x.timestamp DESC, x.id DESC
    LIMIT 1
  )
)
SELECT u.id
FROM logical_units u
LEFT JOIN latest_events e ON e.unit_id = u.id
WHERE COALESCE(e.path, u.original_path) = ?1
  AND (u.name = ?2 OR u.name LIKE ?3)
  AND u.type IN (?4, ?5)
ORDER BY ABS(COALESCE(e.start_line, u.start_line, 1) - ?6), u.id
LIMIT 1;
