-- query-id: storage.insert_test_exposure_event.v1
INSERT INTO test_exposure_events
              (unit_id, commit_hash, timestamp, path, function, line, branch_id,
               test_id, test_type, mutation_status, mutation_kind, mutation_corpus, is_mutation_verified,
               is_mutation_killed, is_verified, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, COALESCE(?11, ''), ?12, ?13, ?14, ?15, ?16)
            ON CONFLICT DO UPDATE SET
              timestamp = MAX(test_exposure_events.timestamp, excluded.timestamp),
              function = COALESCE(excluded.function, test_exposure_events.function),
              mutation_status = COALESCE(excluded.mutation_status, test_exposure_events.mutation_status),
              mutation_kind = CASE
                WHEN lower(COALESCE(test_exposure_events.mutation_kind, '')) IN ('invariant', 'contract') THEN test_exposure_events.mutation_kind
                WHEN lower(COALESCE(excluded.mutation_kind, '')) IN ('invariant', 'contract') THEN excluded.mutation_kind
                WHEN COALESCE(excluded.mutation_kind, '') <> '' THEN excluded.mutation_kind
                ELSE test_exposure_events.mutation_kind
              END,
              mutation_corpus = CASE
                WHEN COALESCE(excluded.mutation_corpus, '') <> '' THEN excluded.mutation_corpus
                ELSE test_exposure_events.mutation_corpus
              END,
              is_mutation_verified = MAX(test_exposure_events.is_mutation_verified, excluded.is_mutation_verified),
              is_mutation_killed = MAX(test_exposure_events.is_mutation_killed, excluded.is_mutation_killed),
              is_verified = MAX(test_exposure_events.is_verified, excluded.is_verified),
              payload_json = excluded.payload_json
            WHERE excluded.timestamp > test_exposure_events.timestamp
               OR excluded.is_mutation_verified > test_exposure_events.is_mutation_verified
               OR excluded.is_mutation_killed > test_exposure_events.is_mutation_killed
               OR excluded.is_verified > test_exposure_events.is_verified
               OR COALESCE(excluded.mutation_kind, '') <> COALESCE(test_exposure_events.mutation_kind, '')
               OR COALESCE(excluded.mutation_corpus, '') <> COALESCE(test_exposure_events.mutation_corpus, '')
               OR excluded.payload_json <> test_exposure_events.payload_json
