-- query-id: storage.insert_sarif_artifact_2.v1
SELECT id
            FROM sarif_artifacts
            WHERE source = ?1
              AND commit_hash = ?2
              AND artifact_path = ?3
              AND artifact_sha256 = ?4
