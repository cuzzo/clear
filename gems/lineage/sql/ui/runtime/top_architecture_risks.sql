-- query-id: ui.runtime.top_architecture_risks.v1
SELECT path, start_line, rule_id, level, message, properties_json
        FROM current_sarif_findings
        WHERE lower(tool_name) = 'espalier'
           OR lower(run_format) = 'espalier.manifest.sarif.v1'
           OR lower(source) LIKE '%espalier%'
