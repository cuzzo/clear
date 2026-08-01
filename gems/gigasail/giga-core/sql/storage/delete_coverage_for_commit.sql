-- query-id: storage.delete_coverage_for_commit.v1
DELETE FROM quality_events
            WHERE commit_hash = ?1
              AND metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV', 'GATE_STATUS')
