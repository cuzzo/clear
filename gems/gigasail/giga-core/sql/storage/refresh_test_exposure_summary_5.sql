-- query-id: storage.refresh_test_exposure_summary_5.v1
SELECT DISTINCT test_type
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND test_type <> ''
            ORDER BY test_type
