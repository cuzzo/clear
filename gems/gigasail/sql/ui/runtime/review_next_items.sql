-- query-id: ui.runtime.review_next_items.v1
WITH grouped AS (
          SELECT finding.path,
                 MIN(finding.start_line) AS start_line,
                 COALESCE(unit.name, MIN(finding.rule_id)) AS title,
                 GROUP_CONCAT(DISTINCT finding.tool_name) AS tools,
                 COUNT(*) AS findings,
                 SUM(CASE WHEN lower(finding.level) IN ('error', 'warning') THEN 1 ELSE 0 END) AS warnings,
                 SUM(finding.is_dark_arm) AS dark_arms,
                 MIN(finding.rule_id || ': ' || finding.message) AS example,
                 COUNT(DISTINCT finding.tool_name) AS tool_count
          FROM current_sarif_findings finding
          LEFT JOIN logical_units unit ON unit.id = finding.unit_id
          WHERE finding.path <> ''
            AND (?1 = '' OR finding.path = ?1 OR finding.path LIKE ?2)
          GROUP BY finding.path,
                   COALESCE(finding.unit_id, 'line:' || finding.start_line)
        )
        SELECT path, start_line, title, tools, findings, warnings, dark_arms, example, tool_count,
               warnings * 3.0 + dark_arms * 5.0 + findings + tool_count * 2.0 AS score
        FROM grouped
        ORDER BY score DESC, path, start_line
        LIMIT 500
