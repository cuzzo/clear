-- query-id: architecture.load_node.v1
SELECT analyzer_node_id, logical_unit_id, owner_node_id, kind, name, owner, language, path,
       start_line, start_column, end_line, end_column, confidence, metadata_json
FROM architecture_nodes
WHERE artifact_id = ?1 AND analyzer_node_id = ?2;
