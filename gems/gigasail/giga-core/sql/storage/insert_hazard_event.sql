-- query-id: storage.insert_hazard_event.v1
INSERT INTO unit_hazards
              (unit_id, language, hazard_type, required_evidence, path, line,
               symbol, source, detected_at_hash, is_active, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
