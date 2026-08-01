-- query-id: ui.architecture_symbols_for_path.v1
SELECT n.analyzer_node_id, n.owner_node_id, n.kind, n.name, n.start_line, n.end_line,
       COALESCE(p.score, 0), COALESCE(p.band, 'ordinary'),
       COALESCE((
         SELECT group_concat(DISTINCT s.name)
         FROM architecture_edges e
         JOIN architecture_nodes s ON s.artifact_id = e.artifact_id AND s.analyzer_node_id = e.source_node_id
         WHERE e.artifact_id = n.artifact_id AND e.target_node_id = n.analyzer_node_id AND e.kind = 'reads'
       ), ''),
       COALESCE((
         SELECT group_concat(DISTINCT s.name)
         FROM architecture_edges e
         JOIN architecture_nodes s ON s.artifact_id = e.artifact_id AND s.analyzer_node_id = e.target_node_id
         WHERE e.artifact_id = n.artifact_id AND e.source_node_id = n.analyzer_node_id AND e.kind = 'writes'
       ), '')
FROM architecture_nodes n
LEFT JOIN architecture_pressure p ON p.artifact_id = n.artifact_id AND p.node_id = n.analyzer_node_id
WHERE n.artifact_id = (SELECT id FROM architecture_artifacts ORDER BY id DESC LIMIT 1)
  AND n.path = ?1;
