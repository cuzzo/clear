-- query-id: storage.insert_sarif_finding.v1
INSERT OR IGNORE INTO sarif_findings
              (artifact_id, finding_key, source, tool_name, run_format, commit_hash,
               timestamp, rule_id, level, message, path, start_line, start_column,
               end_line, end_column, category, is_dark_arm, unit_id, fingerprint,
               properties_json, raw_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
