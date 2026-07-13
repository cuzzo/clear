-- query-id: ui.runtime.line_coverage_by_file.v1
WITH latest_source_lines AS (
          SELECT path, line, hits, is_partial, coverage_percent
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
        )
        SELECT path, hits, is_partial, coverage_percent
        FROM latest_lines
        ORDER BY path
