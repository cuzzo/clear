-- query-id: architecture.insert_edge_span.v1
INSERT INTO architecture_edge_spans
  (artifact_id, edge_id, path, start_line, start_column, end_line, end_column)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);
