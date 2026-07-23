-- query-id: ui.runtime.top_hotness.v1
SELECT path, function, line, flat_share, cum_share, tier, source
FROM unit_hotness
WHERE is_active = 1
ORDER BY cum_share DESC
