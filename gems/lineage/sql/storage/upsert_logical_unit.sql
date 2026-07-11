-- query-id: storage.upsert_logical_unit.v1
INSERT INTO logical_units (id, name, type, original_path, created_at, start_line)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO NOTHING
