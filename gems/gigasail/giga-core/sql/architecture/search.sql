-- query-id: architecture.search.v1
SELECT analyzer_node_id, kind, name, owner, path, start_line, metadata_json
FROM architecture_nodes
WHERE artifact_id = ?1
  AND lower(name) LIKE ?2
  AND (?3 IS NULL OR owner_node_id = ?3)
ORDER BY CASE kind WHEN 'owner' THEN 0 WHEN 'function' THEN 1 ELSE 2 END, name
LIMIT 100;
