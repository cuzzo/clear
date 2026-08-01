-- query-id: storage.delete_test_exposure_for_commit_test.v1
SELECT DISTINCT unit_id
            FROM test_exposure_events
            WHERE commit_hash = ?1 AND test_type = ?2 AND test_id = ?3
