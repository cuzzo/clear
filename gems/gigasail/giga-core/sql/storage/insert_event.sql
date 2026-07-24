-- query-id: storage.insert_event.v1
INSERT INTO events
              (unit_id, commit_hash, event_type, path, name, start_line, end_line,
               semantic_change, lines_added, lines_removed, timestamp)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
