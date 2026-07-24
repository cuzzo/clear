-- query-id: ui.runtime.sarif_dark_arm_counts_by_file.v1
SELECT path, COUNT(*) AS findings
        FROM current_sarif_findings
        WHERE is_dark_arm = 1
        GROUP BY path
