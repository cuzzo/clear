-- query-id: storage.record_quality_metric.v1
UPDATE quality_events
                SET timestamp = ?2, new_value = ?3
                WHERE id = ?1
