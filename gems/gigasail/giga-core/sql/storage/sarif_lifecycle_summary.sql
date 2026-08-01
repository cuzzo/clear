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
              COALESCE(SUM(CASE WHEN current_finding.fingerprint IS NOT NULL AND previous_finding.fingerprint IS NULL THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN current_finding.fingerprint IS NULL AND previous_finding.fingerprint IS NOT NULL THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN current_finding.fingerprint IS NOT NULL AND previous_finding.fingerprint IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM all_keys finding_key
            LEFT JOIN current_findings current_finding
              ON current_finding.path = finding_key.path
             AND current_finding.source = finding_key.source
             AND current_finding.tool_name = finding_key.tool_name
             AND current_finding.rule_id = finding_key.rule_id
             AND current_finding.fingerprint = finding_key.fingerprint
            LEFT JOIN previous_findings previous_finding
              ON previous_finding.path = finding_key.path
             AND previous_finding.source = finding_key.source
             AND previous_finding.tool_name = finding_key.tool_name
             AND previous_finding.rule_id = finding_key.rule_id
             AND previous_finding.fingerprint = finding_key.fingerprint
