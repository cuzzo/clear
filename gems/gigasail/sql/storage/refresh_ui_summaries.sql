-- query-id: storage.refresh_ui_summaries.v1
DELETE FROM ui_file_summaries;
            DELETE FROM ui_warning_units;

            WITH latest_events AS (
              SELECT unit_id, path
              FROM (
                SELECT unit_id, path,
                       ROW_NUMBER() OVER (
                         PARTITION BY unit_id
                         ORDER BY timestamp DESC, id DESC
                       ) AS rank
                FROM events
              )
              WHERE rank = 1
            ),
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     u.current_line_cov,
                     u.current_mutant_cov,
                     u.current_distinct_tests,
                     u.current_mutant_killed_tests
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            ),
            unit_file AS (
              SELECT current_path AS path,
                     COUNT(DISTINCT id) AS units,
                     COALESCE(SUM(current_distinct_tests), 0) AS distinct_tests,
                     COALESCE(SUM(current_mutant_killed_tests), 0) AS mutant_killed_tests,
                     COALESCE(AVG(current_line_cov), 0.0) AS fallback_line_coverage,
                     COALESCE(AVG(current_mutant_cov), 0.0) AS mutant_coverage
              FROM current_units
              WHERE current_path <> ''
              GROUP BY current_path
            ),
            latest_source_lines AS (
              SELECT path, line, source, hits, is_partial, coverage_percent
              FROM (
                SELECT path, line, source, hits, is_partial, coverage_percent,
                       ROW_NUMBER() OVER (
                         PARTITION BY path, line, source
                         ORDER BY timestamp DESC, id DESC
                       ) AS rank
                FROM coverage_line_events
              )
              WHERE rank = 1
            ),
            latest_lines AS (
              SELECT path, line, MAX(hits) AS hits,
                     MAX(is_partial) AS is_partial,
                     CASE
                       WHEN MAX(is_partial) = 1 THEN MIN(CASE
                         WHEN is_partial = 1
                         THEN COALESCE(coverage_percent, CASE WHEN hits > 0 THEN 100.0 ELSE 0.0 END)
                       END)
                       ELSE MAX(COALESCE(coverage_percent, CASE WHEN hits > 0 THEN 100.0 ELSE 0.0 END))
                     END AS coverage_percent
              FROM latest_source_lines
              GROUP BY path, line
            ),
            line_file AS (
              SELECT path,
                     COUNT(*) AS tracked_lines,
                     SUM(CASE WHEN hits > 0 THEN 1 ELSE 0 END) AS covered_lines,
                     SUM(CASE WHEN hits > 0 AND is_partial = 1 THEN 1 ELSE 0 END) AS partial_lines,
                     AVG(coverage_percent) AS coverage_percent
              FROM latest_lines
              GROUP BY path
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
            ),
            line_exposure AS (
              SELECT e.path,
                     e.line,
                     l.hits,
                     COUNT(DISTINCT CASE WHEN e.is_verified = 1 THEN e.test_type END) AS verified_test_types,
                     MAX(CASE WHEN e.is_verified = 1 AND e.is_mutation_verified = 1 THEN 1 ELSE 0 END) AS mutant_verified,
                     MAX(CASE WHEN e.is_verified = 1 AND e.is_mutation_killed = 1 THEN 1 ELSE 0 END) AS mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_verified = 1
                        AND lower(COALESCE(e.mutation_kind, '')) = 'stochastic'
                       THEN 1 ELSE 0
                     END) AS stochastic_mutant_verified,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_killed = 1
                        AND lower(COALESCE(e.mutation_kind, '')) = 'stochastic'
                       THEN 1 ELSE 0
                     END) AS stochastic_mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_killed = 1
                        AND lower(COALESCE(e.mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS invariant_mutant_killed,
                     MAX(CASE
                       WHEN e.is_verified = 1
                        AND e.is_mutation_verified = 1
                        AND lower(COALESCE(e.mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS invariant_mutant_verified
              FROM latest_exposure e
              JOIN latest_lines l
                ON l.path = e.path
               AND l.line = e.line
               AND l.hits > 0
              GROUP BY e.path, e.line
            ),
            exposure_file AS (
              SELECT path,
                     SUM(mutant_verified) AS mutant_verified_covered_lines,
                     SUM(mutant_killed) AS mutant_killed_covered_lines,
                     SUM(stochastic_mutant_verified) AS stochastic_mutant_verified_covered_lines,
                     SUM(stochastic_mutant_killed) AS stochastic_mutant_killed_covered_lines,
                     SUM(invariant_mutant_verified) AS invariant_mutant_verified_covered_lines,
                     SUM(invariant_mutant_killed) AS invariant_mutant_killed_covered_lines,
                     SUM(CASE WHEN verified_test_types >= 2 OR hits > 1 THEN 1 ELSE 0 END) AS multi_type_covered_lines
              FROM line_exposure
              GROUP BY path
            ),
            active_hazards AS (
              SELECT *
              FROM unit_hazards
              WHERE is_active = 1
            ),
            hazard_ranked_exposure AS (
              SELECT t.unit_id,
                     t.path,
                     t.line,
                     t.branch_id,
                     t.test_id,
                     t.test_type,
                     t.is_verified,
                     t.is_mutation_killed,
                     t.mutation_kind,
                     ROW_NUMBER() OVER (
                       PARTITION BY t.path, t.line, COALESCE(t.branch_id, ''), t.test_id, t.test_type
                       ORDER BY t.timestamp DESC, t.id DESC
                     ) AS rank
              FROM test_exposure_events t
              JOIN active_hazards h
                ON h.unit_id = t.unit_id
               AND h.path = t.path
               AND h.line = t.line
              WHERE t.line IS NOT NULL
            ),
            hazard_latest_exposure AS (
              SELECT *
              FROM hazard_ranked_exposure
              WHERE rank = 1
            ),
            hazard_evidence AS (
              SELECT unit_id,
                     path,
                     line,
                     lower(test_type) AS test_type,
                     MAX(CASE WHEN is_verified = 1 THEN 1 ELSE 0 END) AS has_evidence,
                     MAX(CASE
                       WHEN is_verified = 1
                        AND is_mutation_killed = 1
                        AND lower(COALESCE(mutation_kind, '')) IN ('invariant', 'contract')
                       THEN 1 ELSE 0
                     END) AS has_invariant_mutation
              FROM hazard_latest_exposure
              GROUP BY unit_id, path, line, lower(test_type)
            ),
            hazard_rows AS (
              SELECT h.id,
                     h.path,
                     CASE
                       WHEN MAX(CASE
                              WHEN (e.test_type = lower(h.required_evidence)
                                 OR e.test_type LIKE '%' || lower(h.required_evidence) || '%')
                               AND e.has_evidence = 1
                              THEN 1 ELSE 0
                            END) = 1
                         OR MAX(CASE
                              WHEN ls.hits > 0
                               AND (lower(ls.source) = lower(h.required_evidence)
                                 OR lower(ls.source) LIKE '%' || lower(h.required_evidence) || '%')
                              THEN 1 ELSE 0
                            END) = 1
                       THEN 1 ELSE 0
                     END AS evidence_present,
                     CASE
                       WHEN MAX(CASE WHEN l.hits > 0 THEN 1 ELSE 0 END) = 1
                         OR MAX(CASE
                              WHEN (e.test_type = lower(h.required_evidence)
                                 OR e.test_type LIKE '%' || lower(h.required_evidence) || '%')
                               AND e.has_evidence = 1
                              THEN 1 ELSE 0
                            END) = 1
                         OR MAX(CASE
                              WHEN ls.hits > 0
                               AND (lower(ls.source) = lower(h.required_evidence)
                                 OR lower(ls.source) LIKE '%' || lower(h.required_evidence) || '%')
                              THEN 1 ELSE 0
                            END) = 1
                       THEN 1 ELSE 0
                     END AS verified
              FROM active_hazards h
              LEFT JOIN hazard_evidence e
                ON e.unit_id = h.unit_id
               AND e.path = h.path
               AND e.line = h.line
              LEFT JOIN latest_lines l
                ON l.path = h.path
               AND l.line = h.line
              LEFT JOIN latest_source_lines ls
                ON ls.path = h.path
               AND ls.line = h.line
              GROUP BY h.id, h.path
            ),
            hazard_file AS (
              SELECT path,
                     COUNT(*) AS hazards,
                     SUM(evidence_present) AS evidence_covered_hazards,
                     SUM(verified) AS covered_hazards
              FROM hazard_rows
              GROUP BY path
            ),
            paths AS (
              SELECT path FROM unit_file
              UNION
              SELECT path FROM line_file
              UNION
              SELECT path FROM exposure_file
              UNION
              SELECT path FROM hazard_file
            )
            INSERT INTO ui_file_summaries (
              path,
              units,
              hazards,
              evidence_covered_hazards,
              covered_hazards,
              distinct_tests,
              mutant_killed_tests,
              tracked_lines,
              covered_lines,
              partial_lines,
              line_coverage,
              mutant_coverage,
              mutant_verified_covered_lines,
              mutant_killed_covered_lines,
              stochastic_mutant_verified_covered_lines,
              stochastic_mutant_killed_covered_lines,
              invariant_mutant_verified_covered_lines,
              invariant_mutant_killed_covered_lines,
              multi_type_covered_lines
            )
            SELECT p.path,
                   COALESCE(uf.units, 0),
                   COALESCE(hf.hazards, 0),
                   COALESCE(hf.evidence_covered_hazards, 0),
                   COALESCE(hf.covered_hazards, 0),
                   COALESCE(uf.distinct_tests, 0),
                   COALESCE(uf.mutant_killed_tests, 0),
                   COALESCE(lf.tracked_lines, 0),
                   COALESCE(lf.covered_lines, 0),
                   COALESCE(lf.partial_lines, 0),
                   CASE
                     WHEN COALESCE(lf.tracked_lines, 0) > 0
                     THEN COALESCE(lf.coverage_percent, 0.0)
                     ELSE COALESCE(uf.fallback_line_coverage, 0.0)
                   END,
                   COALESCE(uf.mutant_coverage, 0.0),
                   COALESCE(ef.mutant_verified_covered_lines, 0),
                   COALESCE(ef.mutant_killed_covered_lines, 0),
                   COALESCE(ef.stochastic_mutant_verified_covered_lines, 0),
                   COALESCE(ef.stochastic_mutant_killed_covered_lines, 0),
                   COALESCE(ef.invariant_mutant_verified_covered_lines, 0),
                   COALESCE(ef.invariant_mutant_killed_covered_lines, 0),
                   COALESCE(ef.multi_type_covered_lines, 0)
            FROM paths p
            LEFT JOIN unit_file uf ON uf.path = p.path
            LEFT JOIN line_file lf ON lf.path = p.path
            LEFT JOIN exposure_file ef ON ef.path = p.path
            LEFT JOIN hazard_file hf ON hf.path = p.path
            WHERE p.path <> '';

            WITH latest_events AS (
              SELECT unit_id, path
              FROM (
                SELECT unit_id, path,
                       ROW_NUMBER() OVER (
                         PARTITION BY unit_id
                         ORDER BY timestamp DESC, id DESC
                       ) AS rank
                FROM events
              )
              WHERE rank = 1
            ),
            current_units AS (
              SELECT u.id,
                     COALESCE(le.path, u.original_path) AS current_path,
                     u.current_distinct_tests,
                     u.current_mutant_verified_tests,
                     u.last_test_exposure_at
              FROM logical_units u
              LEFT JOIN latest_events le ON le.unit_id = u.id
            ),
            db_clock AS (
              SELECT COALESCE(MAX(timestamp), 0) AS observed_at
              FROM (
                SELECT timestamp FROM metadata
                UNION ALL SELECT timestamp FROM events
                UNION ALL SELECT timestamp FROM quality_events
                UNION ALL SELECT timestamp FROM crash_events
                UNION ALL SELECT timestamp FROM test_exposure_events
              )
            ),
            mutant_runs AS (
              SELECT unit_id, MAX(timestamp) AS last_mutant_run_at
              FROM test_exposure_events
              WHERE is_mutation_verified = 1 OR is_mutation_killed = 1
              GROUP BY unit_id
            ),
            event_counts AS (
              SELECT cu.id,
                     SUM(CASE
                       WHEN cu.last_test_exposure_at > 0
                        AND e.semantic_change = 1
                        AND e.event_type IN ('FIX', 'CHANGE')
                        AND e.timestamp > cu.last_test_exposure_at
                       THEN 1 ELSE 0
                     END) AS changes_after_test_exposure,
                     SUM(CASE
                       WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                        AND e.semantic_change = 1
                        AND e.event_type IN ('FIX', 'CHANGE')
                        AND e.timestamp > m.last_mutant_run_at
                       THEN 1 ELSE 0
                     END) AS semantic_changes_after_mutant_run
              FROM current_units cu
              LEFT JOIN mutant_runs m ON m.unit_id = cu.id
              LEFT JOIN events e ON e.unit_id = cu.id
              GROUP BY cu.id
            ),
            reopened AS (
              SELECT c.unit_id, COUNT(DISTINCT c.id) AS reopened_count
              FROM crash_events c
              WHERE EXISTS (
                SELECT 1
                FROM events fix
                WHERE fix.unit_id = c.unit_id
                  AND fix.event_type = 'FIX'
                  AND fix.semantic_change = 1
                  AND fix.path = c.path
                  AND c.line BETWEEN fix.start_line AND fix.end_line
                  AND c.timestamp > fix.timestamp
              )
              GROUP BY c.unit_id
            )
            INSERT INTO ui_warning_units (
              unit_id,
              current_path,
              current_distinct_tests,
              current_mutant_verified_tests,
              last_test_exposure_at,
              last_mutant_run_at,
              changes_after_test_exposure,
              semantic_changes_after_mutant_run,
              verification_stale_seconds,
              reopened_count
            )
            SELECT cu.id,
                   cu.current_path,
                   cu.current_distinct_tests,
                   cu.current_mutant_verified_tests,
                   cu.last_test_exposure_at,
                   COALESCE(m.last_mutant_run_at, 0),
                   COALESCE(ec.changes_after_test_exposure, 0),
                   COALESCE(ec.semantic_changes_after_mutant_run, 0),
                   CASE
                     WHEN COALESCE(m.last_mutant_run_at, 0) > 0
                      AND clock.observed_at > m.last_mutant_run_at
                     THEN clock.observed_at - m.last_mutant_run_at
                     ELSE 0
                   END,
                   COALESCE(r.reopened_count, 0)
            FROM current_units cu
            LEFT JOIN mutant_runs m ON m.unit_id = cu.id
            LEFT JOIN event_counts ec ON ec.id = cu.id
            LEFT JOIN reopened r ON r.unit_id = cu.id
            CROSS JOIN db_clock clock
            WHERE cu.current_path <> '';

            INSERT INTO ui_refresh_metadata (key, value)
            VALUES ('refreshed_at', strftime('%s', 'now'))
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
