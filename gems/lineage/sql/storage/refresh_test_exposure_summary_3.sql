-- query-id: storage.refresh_test_exposure_summary_3.v1
SELECT COUNT(DISTINCT test_id)
            FROM test_exposure_events
            WHERE unit_id = ?1 AND commit_hash = ?2 AND is_mutation_verified = 1
