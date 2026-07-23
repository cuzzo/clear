-- query-id: storage.refresh_test_exposure_summary.v1
SELECT commit_hash, timestamp
            FROM test_exposure_events
            WHERE unit_id = ?1
            ORDER BY timestamp DESC, id DESC
            LIMIT 1
