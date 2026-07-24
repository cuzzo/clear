-- query-id: architecture.owner_inventory.v1
SELECT n.analyzer_node_id, n.logical_unit_id, n.owner_node_id, n.kind, n.name, n.owner, n.language, n.path,
       n.start_line, n.start_column, n.end_line, n.end_column, n.confidence, n.metadata_json,
       p.score, p.band, p.explanation_json,
       (SELECT COUNT(*) FROM architecture_edges e WHERE e.artifact_id = n.artifact_id AND e.target_node_id = n.analyzer_node_id) AS incoming,
       (SELECT COUNT(*) FROM architecture_edges e WHERE e.artifact_id = n.artifact_id AND e.source_node_id = n.analyzer_node_id) AS outgoing,
       (SELECT COUNT(*) FROM unit_hazards h WHERE h.unit_id = n.logical_unit_id AND h.is_active = 1) AS hazards,
       (SELECT COUNT(*) FROM events e WHERE e.unit_id = n.logical_unit_id AND e.event_type = 'CHANGE') AS changes,
       (SELECT COUNT(*) FROM events e WHERE e.unit_id = n.logical_unit_id AND e.event_type = 'FIX') AS fixes,
       COALESCE(u.current_distinct_tests, 0), COALESCE(u.current_line_cov, 0), COALESCE(u.current_mutant_cov, 0)
FROM architecture_nodes n
LEFT JOIN architecture_pressure p ON p.artifact_id = n.artifact_id AND p.node_id = n.analyzer_node_id
LEFT JOIN logical_units u ON u.id = n.logical_unit_id
WHERE n.artifact_id = ?1 AND n.owner_node_id = ?2
ORDER BY COALESCE(p.score, 0) DESC, n.kind, n.name;
