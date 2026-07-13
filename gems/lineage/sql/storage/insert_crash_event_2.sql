-- query-id: storage.insert_crash_event_2.v1
INSERT INTO crash_events
              (unit_id, commit_hash, timestamp, error_class, provider_id,
               is_verified, path, line, function)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
