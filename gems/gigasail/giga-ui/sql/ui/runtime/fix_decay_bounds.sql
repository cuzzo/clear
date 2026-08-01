-- query-id: ui.runtime.fix_decay_bounds.v1
SELECT MIN(timestamp), MAX(timestamp)
        FROM events
        WHERE semantic_change = 1
          AND event_type = 'FIX'
