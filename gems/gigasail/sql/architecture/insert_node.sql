-- query-id: architecture.insert_node.v1
INSERT INTO architecture_nodes
  (artifact_id, analyzer_node_id, logical_unit_id, owner_node_id, kind, name, owner,
   language, path, start_line, start_column, end_line, end_column, confidence, metadata_json)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
