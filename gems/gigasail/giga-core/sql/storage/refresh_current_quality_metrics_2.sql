-- query-id: storage.refresh_current_quality_metrics_2.v1
UPDATE logical_units
                    SET {column} = COALESCE((
                      SELECT q.new_value
                      FROM quality_events q
                      WHERE q.unit_id = logical_units.id
                        AND q.metric_type = ?1
                      ORDER BY q.timestamp DESC, q.id DESC
                      LIMIT 1
                    ), 0.0)
