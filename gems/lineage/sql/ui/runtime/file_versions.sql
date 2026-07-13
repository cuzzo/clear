-- query-id: ui.runtime.file_versions.v1
WITH candidate_units AS (
  SELECT *
  FROM logical_units
  WHERE original_path = ?1
     OR id IN (SELECT DISTINCT unit_id FROM events WHERE path = ?1)
),
latest_events AS (
  SELECT unit_id, path
  FROM (
    SELECT unit_id, path,
           ROW_NUMBER() OVER (
             PARTITION BY unit_id
             ORDER BY timestamp DESC, id DESC
           ) AS rank
    FROM events
    WHERE unit_id IN (SELECT id FROM candidate_units)
  )
  WHERE rank = 1
),
current_units AS (
  SELECT u.id
  FROM candidate_units u
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
