-- query-id: architecture.latest_artifact.v1
SELECT id
FROM architecture_artifacts
ORDER BY id DESC
LIMIT 1;
