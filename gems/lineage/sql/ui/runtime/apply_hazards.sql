-- query-id: ui.runtime.apply_hazards.v1
WITH ranked_exposure AS (
          SELECT unit_id, path, line, test_type, is_verified, is_mutation_killed, mutation_kind,
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
            WHERE path = ?1
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
        SELECT h.line, h.hazard_type, h.required_evidence, h.source,
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
        FROM unit_hazards h
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
        WHERE h.path = ?1 AND h.is_active = 1
        GROUP BY h.id, h.line, h.hazard_type, h.required_evidence, h.source
        ORDER BY h.line, h.hazard_type
