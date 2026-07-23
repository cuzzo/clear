-- query-id: ui.runtime.has_multicommit_quality_history.v1
SELECT COUNT(DISTINCT commit_hash)
        FROM quality_events
        WHERE metric_type IN ('LINE_COV', 'INTEGRATION_COV', 'MUTANT_COV')
