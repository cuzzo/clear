-- query-id: storage.ensure_natural_key_indexes.v1
DELETE FROM coverage_line_events
            WHERE id NOT IN (
              SELECT (
                SELECT c2.id
                FROM coverage_line_events c2
                WHERE c2.commit_hash = c1.commit_hash
                  AND c2.path = c1.path
                  AND c2.line = c1.line
                  AND c2.source = c1.source
                ORDER BY c2.hits DESC, c2.timestamp DESC, c2.id DESC
                LIMIT 1
              )
              FROM coverage_line_events c1
              GROUP BY c1.commit_hash, c1.path, c1.line, c1.source
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_coverage_line_events_natural_key
              ON coverage_line_events(commit_hash, path, line, source);

            DELETE FROM quality_events
            WHERE id NOT IN (
              SELECT (
                SELECT q2.id
                FROM quality_events q2
                WHERE q2.unit_id = q1.unit_id
                  AND q2.commit_hash = q1.commit_hash
                  AND q2.metric_type = q1.metric_type
                ORDER BY q2.new_value DESC, q2.timestamp DESC, q2.id DESC
                LIMIT 1
              )
              FROM quality_events q1
              GROUP BY q1.unit_id, q1.commit_hash, q1.metric_type
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_quality_events_natural_key
              ON quality_events(unit_id, commit_hash, metric_type);

            DELETE FROM crash_events
            WHERE id NOT IN (
              SELECT (
                SELECT e2.id
                FROM crash_events e2
                WHERE e2.unit_id = e1.unit_id
                  AND e2.commit_hash = e1.commit_hash
                  AND e2.error_class = e1.error_class
                  AND e2.provider_id = e1.provider_id
                  AND e2.path = e1.path
                  AND e2.line = e1.line
                  AND e2.function = e1.function
                ORDER BY e2.is_verified DESC, e2.timestamp DESC, e2.id DESC
                LIMIT 1
              )
              FROM crash_events e1
              GROUP BY e1.unit_id, e1.commit_hash, e1.error_class, e1.provider_id,
                       e1.path, e1.line, e1.function
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_crash_events_natural_key
              ON crash_events(unit_id, commit_hash, error_class, provider_id, path, line, function);

            DELETE FROM test_exposure_events
            WHERE id NOT IN (
              SELECT (
                SELECT t2.id
                FROM test_exposure_events t2
                WHERE t2.unit_id = t1.unit_id
                  AND t2.commit_hash = t1.commit_hash
                  AND t2.path = t1.path
                  AND COALESCE(t2.line, -1) = COALESCE(t1.line, -1)
                  AND COALESCE(t2.branch_id, '') = COALESCE(t1.branch_id, '')
                  AND t2.test_id = t1.test_id
                  AND t2.test_type = t1.test_type
                ORDER BY t2.is_verified DESC,
                         t2.is_mutation_killed DESC,
                         t2.is_mutation_verified DESC,
                         CASE
                           WHEN lower(COALESCE(t2.mutation_kind, '')) IN ('invariant', 'contract') THEN 2
                           WHEN COALESCE(t2.mutation_kind, '') <> '' THEN 1
                           ELSE 0
                         END DESC,
                         t2.timestamp DESC,
                         t2.id DESC
                LIMIT 1
              )
              FROM test_exposure_events t1
              GROUP BY t1.unit_id, t1.commit_hash, t1.path, COALESCE(t1.line, -1),
                       COALESCE(t1.branch_id, ''), t1.test_id, t1.test_type
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_test_exposure_events_natural_key
              ON test_exposure_events(
                unit_id,
                commit_hash,
                path,
                COALESCE(line, -1),
                COALESCE(branch_id, ''),
                test_id,
                test_type
              );
