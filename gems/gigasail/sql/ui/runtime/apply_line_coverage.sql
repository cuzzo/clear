-- query-id: ui.runtime.apply_line_coverage.v1
WITH latest_source AS (
          SELECT line, source, hits, is_partial,
                 ROW_NUMBER() OVER (
                   PARTITION BY line, source
                   ORDER BY timestamp DESC, id DESC
                 ) AS rank
          FROM coverage_line_events
          WHERE path = ?1
        ),
        latest AS (
          SELECT line, MAX(hits) AS hits, MAX(is_partial) AS is_partial
          FROM latest_source
          WHERE rank = 1
          GROUP BY line
        )
        SELECT line, hits, COALESCE(is_partial, 0)
        FROM latest
        ORDER BY line
