-- query-id: ui.runtime.analyzer_health_2.v1
SELECT source, tool_name, COUNT(*)
                FROM current_sarif_findings
                WHERE path = ?1 OR path LIKE ?2
                GROUP BY source, tool_name
