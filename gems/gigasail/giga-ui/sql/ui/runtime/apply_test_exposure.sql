-- query-id: ui.runtime.apply_test_exposure.v1
WITH ranked_exposure AS (
          SELECT path, line, branch_id, test_id, test_type, is_verified,
                 is_mutation_verified, is_mutation_killed, mutation_kind,
                 ROW_NUMBER() OVER (
                   PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM test_exposure_events
          WHERE path = ?1 AND line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        )
        SELECT line, test_type, COUNT(DISTINCT test_id),
               COUNT(DISTINCT CASE WHEN is_mutation_verified = 1 THEN test_id END),
               COUNT(DISTINCT CASE WHEN is_mutation_killed = 1 THEN test_id END),
               COUNT(DISTINCT CASE
                 WHEN is_mutation_verified = 1
                  AND lower(COALESCE(mutation_kind, '')) = 'stochastic'
                 THEN test_id
               END),
               COUNT(DISTINCT CASE
                 WHEN is_mutation_verified = 1
                  AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                 THEN test_id
               END)
        FROM latest_exposure
        WHERE is_verified = 1
        GROUP BY line, test_type
