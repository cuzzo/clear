-- query-id: ui.runtime.dashboard_coverage_line_counts.v1
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
        )
        SELECT path, hits
        FROM latest_lines
