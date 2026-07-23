-- query-id: ui.runtime.apply_hotness.v1
SELECT function, line, flat_share, cum_share, tier, source
FROM unit_hotness
WHERE path = ?1 AND is_active = 1
ORDER BY cum_share DESC
