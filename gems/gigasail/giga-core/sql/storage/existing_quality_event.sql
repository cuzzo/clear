-- query-id: storage.existing_quality_event.v1
SELECT id, new_value
            FROM quality_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND metric_type = ?3
            ORDER BY id DESC
            LIMIT 1
