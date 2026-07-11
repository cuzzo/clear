-- query-id: storage.insert_metadata.v1
INSERT OR IGNORE INTO metadata (commit_hash, message, timestamp)
            VALUES (?1, ?2, ?3)
