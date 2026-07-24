-- query-id: storage.record_quality_metric_2.v1
INSERT INTO quality_events
              (unit_id, commit_hash, timestamp, metric_type, old_value, new_value)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
