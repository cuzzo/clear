-- query-id: ui.runtime.analyzer_health.v1
SELECT source, tool_name, COUNT(*)
        FROM current_sarif_findings
        GROUP BY source, tool_name
