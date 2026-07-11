-- query-id: storage.sarif_finding_counts_by_file.v1
SELECT path, COUNT(*) AS findings
            FROM current_sarif_findings
            GROUP BY path
