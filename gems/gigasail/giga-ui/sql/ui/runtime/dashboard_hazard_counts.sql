-- query-id: ui.runtime.dashboard_hazard_counts.v1
WITH active_hazards AS (
          SELECT *
          FROM unit_hazards
          WHERE is_active = 1
        ),
        ranked_exposure AS (
          SELECT t.unit_id,
                 t.path,
                 t.line,
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
        latest_exposure AS (
          SELECT *
          FROM ranked_exposure
          WHERE rank = 1
        ),
        latest_source_lines AS (
          SELECT path, line, source, hits
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
        evidence AS (
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
          FROM latest_exposure
          GROUP BY unit_id, path, line, lower(test_type)
        )
        SELECT h.path,
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
        LEFT JOIN evidence e
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
