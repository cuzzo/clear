-- query-id: ui.runtime.unit_signal_counts.v1
SELECT unit_id,
                   SUM(CASE WHEN NOT (
                     lower(category) = 'lint'
                     OR lower(source) LIKE '%lint%'
                     OR lower(tool_name) IN ('rubocop', 'clippy', 'zig ast check')
                     OR lower(rule_id) LIKE 'lint/%'
                     OR lower(rule_id) LIKE 'security/%'
                     OR lower(rule_id) LIKE 'clippy::%'
                     OR lower(rule_id) LIKE 'zig.ast-check%'
                   ) THEN 1 ELSE 0 END) AS sarif_findings,
                   SUM(CASE WHEN (
                     lower(category) = 'lint'
                     OR lower(source) LIKE '%lint%'
                     OR lower(tool_name) IN ('rubocop', 'clippy', 'zig ast check')
                     OR lower(rule_id) LIKE 'lint/%'
                     OR lower(rule_id) LIKE 'security/%'
                     OR lower(rule_id) LIKE 'clippy::%'
                     OR lower(rule_id) LIKE 'zig.ast-check%'
                   ) THEN 1 ELSE 0 END) AS lint_findings,
                   SUM(CASE WHEN is_dark_arm = 1 THEN 1 ELSE 0 END) AS dark_arms
            FROM current_sarif_findings
            WHERE unit_id IS NOT NULL
            GROUP BY unit_id
