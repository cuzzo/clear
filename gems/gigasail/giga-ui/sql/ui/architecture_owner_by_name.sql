-- query-id: ui.architecture_owner_by_name.v1
SELECT analyzer_node_id
FROM architecture_nodes
WHERE artifact_id = (SELECT id FROM architecture_artifacts ORDER BY id DESC LIMIT 1)
  AND kind = 'owner'
  AND path = ?1
  AND (name = ?2 OR name LIKE ?3)
ORDER BY CASE WHEN name = ?2 THEN 0 ELSE 1 END, start_line
LIMIT 1;
