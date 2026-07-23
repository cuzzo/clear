-- query-id: storage.sarif_findings_for_path.v1
SELECT artifact_id, finding_key, source, tool_name, run_format, commit_hash,
                   timestamp, rule_id, level, message, path, start_line, start_column,
                   end_line, end_column, category, is_dark_arm, unit_id, fingerprint,
                   properties_json, raw_json
            FROM current_sarif_findings
            WHERE path = ?1
            ORDER BY start_line, source, tool_name, rule_id, message
