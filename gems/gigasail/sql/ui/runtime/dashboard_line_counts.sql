-- query-id: ui.runtime.dashboard_line_counts.v1
WITH latest_source_lines AS (
          SELECT path, line, hits
          FROM (
            SELECT path, line, source, hits,
                   ROW_NUMBER() OVER (
                     PARTITION BY path, line, source
                     ORDER BY timestamp DESC, id DESC
                   ) AS rank
            FROM coverage_line_events
          )
          WHERE rank = 1
        ),
        latest_lines AS (
          SELECT path, line, MAX(hits) AS hits
          FROM latest_source_lines
          GROUP BY path, line
        ),
        ranked_exposure AS (
          SELECT path, line, branch_id, test_id, test_type, is_verified,
                 is_mutation_verified, is_mutation_killed, mutation_kind,
                 ROW_NUMBER() OVER (
                   PARTITION BY path, line, COALESCE(branch_id, ''), test_id, test_type
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM test_exposure_events
          WHERE line IS NOT NULL
        ),
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        )
        SELECT path,
               line,
               latest_lines.hits,
               COUNT(DISTINCT CASE WHEN is_verified = 1 THEN test_type END) AS verified_test_types,
               MAX(CASE WHEN is_verified = 1 AND is_mutation_verified = 1 THEN 1 ELSE 0 END) AS mutant_verified,
               MAX(CASE WHEN is_verified = 1 AND is_mutation_killed = 1 THEN 1 ELSE 0 END) AS mutant_killed,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_verified = 1
                  AND lower(COALESCE(mutation_kind, '')) = 'stochastic'
                 THEN 1 ELSE 0
               END) AS stochastic_mutant_verified,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_killed = 1
                  AND lower(COALESCE(mutation_kind, '')) = 'stochastic'
                 THEN 1 ELSE 0
               END) AS stochastic_mutant_killed,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_killed = 1
                  AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                 THEN 1 ELSE 0
               END) AS invariant_mutant_killed,
               MAX(CASE
                 WHEN is_verified = 1
                  AND is_mutation_verified = 1
                  AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                 THEN 1 ELSE 0
               END) AS invariant_mutant_verified
        FROM latest_exposure
        JOIN latest_lines USING (path, line)
        WHERE latest_lines.hits > 0
        GROUP BY path, line
