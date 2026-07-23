-- query-id: ui.runtime.top_complexity_functions.v2
SELECT path, start_line, properties_json, message, tool_name
FROM current_sarif_findings
WHERE rule_id = 'complexity.observation'
