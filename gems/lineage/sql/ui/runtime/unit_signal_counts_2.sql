-- query-id: ui.runtime.unit_signal_counts_2.v1
SELECT unit_id, COUNT(*) AS hazards
            FROM unit_hazards
            WHERE is_active = 1
            GROUP BY unit_id
