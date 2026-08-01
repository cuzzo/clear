-- query-id: storage.insert_sarif_artifact.v1
INSERT INTO sarif_artifacts
              (source, tool_name, run_format, artifact_path, artifact_sha256,
               commit_hash, timestamp, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(source, commit_hash, artifact_path, artifact_sha256) DO UPDATE SET
              tool_name = excluded.tool_name,
              run_format = excluded.run_format,
              timestamp = excluded.timestamp,
              payload_json = excluded.payload_json,
              ingested_at = strftime('%s', 'now')
