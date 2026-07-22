-- query-id: storage.insert_unit_hotness.v2
INSERT INTO unit_hotness
              (path, function, line, flat_share, cum_share, tier, source, commit_hash, is_active, resolution)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9)
