-- query-id: architecture.insert_edge.v1
INSERT INTO architecture_edges
  (artifact_id, edge_id, source_node_id, target_node_id, kind, conditional, weight, confidence, metadata_json)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
