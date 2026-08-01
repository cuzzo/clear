-- query-id: storage.insert_crash_event.v1
SELECT id, timestamp, is_verified
            FROM crash_events
            WHERE unit_id = ?1
              AND commit_hash = ?2
              AND error_class = ?3
              AND provider_id = ?4
              AND path = ?5
              AND line = ?6
              AND function = ?7
            ORDER BY id DESC
            LIMIT 1
