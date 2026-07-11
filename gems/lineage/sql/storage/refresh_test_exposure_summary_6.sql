-- query-id: storage.refresh_test_exposure_summary_6.v1
UPDATE logical_units
            SET current_distinct_tests = ?2,
                current_test_types = ?3,
                current_mutant_verified_tests = ?4,
                current_mutant_killed_tests = ?5,
                last_test_exposure_at = ?6
            WHERE id = ?1
