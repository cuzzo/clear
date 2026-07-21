-- query-id: storage.insert_unit_hotness.v1
INSERT INTO unit_hotness
              (path, function, line, flat_share, cum_share, tier, source, commit_hash, is_active)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)
