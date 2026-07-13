-- query-id: architecture.delete_snapshot.v1
-- params: analyzer:text, commit_hash:text
DELETE FROM architecture_artifacts
WHERE analyzer = ?1 AND commit_hash = ?2;
