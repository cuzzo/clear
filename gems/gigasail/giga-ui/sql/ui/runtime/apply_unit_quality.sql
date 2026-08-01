-- query-id: ui.runtime.apply_unit_quality.v1
WITH candidate_units AS (
  SELECT *
  FROM logical_units
  WHERE original_path = ?1
     OR id IN (SELECT DISTINCT unit_id FROM events WHERE path = ?1)
),
latest_events AS (
  SELECT *
  FROM (
    SELECT *,
           ROW_NUMBER() OVER (
             PARTITION BY unit_id
             ORDER BY timestamp DESC, id DESC
           ) AS rank
    FROM events
    WHERE unit_id IN (SELECT id FROM candidate_units)
  )
  WHERE rank = 1
)
SELECT COALESCE(le.start_line, 1),
       COALESCE(le.end_line, le.start_line, 1),
       u.current_line_cov,
       u.current_mutant_cov,
       u.current_test_types
FROM candidate_units u
LEFT JOIN latest_events le ON le.unit_id = u.id
WHERE COALESCE(le.path, u.original_path) = ?1
