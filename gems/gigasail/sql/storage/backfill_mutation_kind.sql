-- query-id: storage.backfill_mutation_kind.v1
UPDATE test_exposure_events
            SET mutation_kind = CASE
              WHEN lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%invariant%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%contract%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%property%'
                OR lower(COALESCE(test_type, '') || ' ' || COALESCE(test_id, '')) LIKE '%fuzz%'
              THEN 'invariant'
              ELSE 'stochastic'
            END
            WHERE is_mutation_verified = 1
              AND COALESCE(mutation_kind, '') = ''
