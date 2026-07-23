-- query-id: ui.runtime.decay_bounds.v1
SELECT COALESCE(MIN(timestamp), 0), COALESCE(MAX(timestamp), 0)
        FROM (
          SELECT timestamp
          FROM events
          WHERE semantic_change = 1
            AND event_type IN ('CHANGE', 'FIX')
          UNION ALL
          SELECT timestamp
          FROM crash_events
        )
