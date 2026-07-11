-- query-id: ui.runtime.top_complexity_functions.v1
WITH latest_espalier AS (
          SELECT commit_hash
          FROM current_sarif_findings
          WHERE rule_id = 'espalier.function'
             OR (LOWER(tool_name) = 'espalier' AND rule_id LIKE '%.function')
          ORDER BY timestamp DESC, id DESC
          LIMIT 1
        )
        SELECT path, start_line, properties_json, message
        FROM current_sarif_findings
        WHERE (rule_id = 'espalier.function'
           OR (LOWER(tool_name) = 'espalier' AND rule_id LIKE '%.function'))
          AND commit_hash = (SELECT commit_hash FROM latest_espalier)
