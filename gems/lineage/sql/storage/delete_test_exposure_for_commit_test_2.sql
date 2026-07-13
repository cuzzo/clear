-- query-id: storage.delete_test_exposure_for_commit_test_2.v1
DELETE FROM test_exposure_events
            WHERE commit_hash = ?1 AND test_type = ?2 AND test_id = ?3
