-- query-id: ui.runtime.warning_units.v1
SELECT current_path,
                   current_distinct_tests,
                   current_mutant_verified_tests,
                   last_test_exposure_at,
                   last_mutant_run_at,
                   changes_after_test_exposure,
                   semantic_changes_after_mutant_run,
                   verification_stale_seconds,
                   reopened_count
            FROM ui_warning_units
