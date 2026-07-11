-- query-id: architecture.insert_artifact.v1
INSERT INTO architecture_artifacts
  (analyzer, analyzer_version, schema_version, commit_hash, root, complete, generated_at, payload_json)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
