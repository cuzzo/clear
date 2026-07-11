-- query-id: storage.sarif_lifecycle_summary.v1
WITH commit_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     MAX(timestamp) AS timestamp, MAX(id) AS id
              FROM sarif_findings
              GROUP BY path, source, tool_name, commit_hash
            ),
            ranked_snapshots AS (
              SELECT path, source, tool_name, commit_hash,
                     ROW_NUMBER() OVER (
                       PARTITION BY path, source, tool_name
                       ORDER BY timestamp DESC, id DESC
                     ) AS snapshot_rank
              FROM commit_snapshots
            ),
            current_findings AS (
              SELECT DISTINCT finding.path, finding.source, finding.tool_name,
                              finding.rule_id, finding.fingerprint
              FROM sarif_findings finding
              JOIN ranked_snapshots snapshot
                ON snapshot.path = finding.path
               AND snapshot.source = finding.source
               AND snapshot.tool_name = finding.tool_name
               AND snapshot.commit_hash = finding.commit_hash
               AND snapshot.snapshot_rank = 1
            ),
            previous_findings AS (
              SELECT DISTINCT finding.path, finding.source, finding.tool_name,
                              finding.rule_id, finding.fingerprint
              FROM sarif_findings finding
              JOIN ranked_snapshots snapshot
                ON snapshot.path = finding.path
               AND snapshot.source = finding.source
               AND snapshot.tool_name = finding.tool_name
               AND snapshot.commit_hash = finding.commit_hash
               AND snapshot.snapshot_rank = 2
            ),
            all_keys AS (
              SELECT path, source, tool_name, rule_id, fingerprint FROM current_findings
              UNION
              SELECT path, source, tool_name, rule_id, fingerprint FROM previous_findings
            )
            SELECT
              COALESCE(SUM(CASE WHEN current.fingerprint IS NOT NULL AND previous.fingerprint IS NULL THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN current.fingerprint IS NULL AND previous.fingerprint IS NOT NULL THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN current.fingerprint IS NOT NULL AND previous.fingerprint IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM all_keys key
            LEFT JOIN current_findings current
              ON current.path = key.path
             AND current.source = key.source
             AND current.tool_name = key.tool_name
             AND current.rule_id = key.rule_id
             AND current.fingerprint = key.fingerprint
            LEFT JOIN previous_findings previous
              ON previous.path = key.path
             AND previous.source = key.source
             AND previous.tool_name = key.tool_name
             AND previous.rule_id = key.rule_id
             AND previous.fingerprint = key.fingerprint
