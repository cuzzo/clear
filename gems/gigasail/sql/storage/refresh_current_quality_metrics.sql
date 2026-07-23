-- query-id: storage.refresh_current_quality_metrics.v1
UPDATE logical_units
            SET current_line_cov = 0.0,
                current_integration_cov = 0.0,
                current_mutant_cov = 0.0,
                is_hard_gated = 0;
