-- query-id: ui.runtime.analyzer_health_3.v1
SELECT source, tool_name, commit_hash, timestamp
        FROM (
          SELECT source, tool_name, commit_hash, timestamp,
                 ROW_NUMBER() OVER (
                   PARTITION BY source, tool_name
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM sarif_artifacts
        )
        WHERE rank = 1
        ORDER BY lower(tool_name), lower(source)
