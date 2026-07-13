-- query-id: architecture.artifact_health.v1
SELECT analyzer, analyzer_version, schema_version, commit_hash, complete, generated_at
FROM architecture_artifacts
WHERE id = ?1;
