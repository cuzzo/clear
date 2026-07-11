-- query-id: architecture.insert_pressure.v1
INSERT INTO architecture_pressure
  (artifact_id, node_id, score, band, collaboration, state, implementation, operational, explanation_json)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
