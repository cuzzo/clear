-- query-id: storage.refresh_current_sarif_findings_view.v1
DROP VIEW IF EXISTS current_sarif_findings;
            CREATE VIEW current_sarif_findings AS
            WITH finding_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     MAX(timestamp) AS timestamp,
                     MAX(id) AS id
              FROM sarif_findings
              GROUP BY path, source, tool_name, commit_hash
            ),
            ranked_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     ROW_NUMBER() OVER (
                       PARTITION BY path, source, tool_name
                       ORDER BY timestamp DESC, id DESC
                     ) AS snapshot_rank
              FROM finding_snapshots
            ),
            latest_snapshots AS (
              SELECT path, source, tool_name, commit_hash
              FROM ranked_snapshots
              WHERE snapshot_rank = 1
            )
            SELECT findings.*
            FROM sarif_findings findings
            JOIN latest_snapshots latest
              ON latest.path = findings.path
             AND latest.source = findings.source
             AND latest.tool_name = findings.tool_name
             AND latest.commit_hash = findings.commit_hash;
