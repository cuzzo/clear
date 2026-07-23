-- query-id: architecture.load_edges.v1
SELECT e.edge_id, e.source_node_id, e.target_node_id, e.kind, e.conditional, e.weight, e.confidence, e.metadata_json,
       COALESCE((
         SELECT json_group_array(json_object(
           'path', s.path,
           'start_line', s.start_line,
           'start_column', s.start_column,
           'end_line', s.end_line,
           'end_column', s.end_column
         ))
         FROM architecture_edge_spans s
         WHERE s.artifact_id = e.artifact_id AND s.edge_id = e.edge_id
       ), '[]')
FROM architecture_edges e
WHERE e.artifact_id = ?1
  AND (e.source_node_id = ?2 OR e.target_node_id = ?2)
ORDER BY e.kind, e.source_node_id, e.target_node_id;
