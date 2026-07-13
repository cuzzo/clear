use super::{ControlFlowEdge, ControlFlowNode};
use serde_json::{json, Value};

pub(crate) fn project_nodes(nodes: &[ControlFlowNode]) -> Vec<Value> {
    nodes
        .iter()
        .map(|node| {
            json!({
                "id": node.id,
                "function": node.function,
                "owner": node.owner,
                "kind": node.kind,
                "role": node.role,
                "line": node.line,
                "span": node.span,
                "source": node.source,
            })
        })
        .collect()
}

pub(crate) fn project_edges(edges: &[ControlFlowEdge]) -> Vec<Value> {
    edges
        .iter()
        .map(|edge| {
            json!({
                "function": edge.function,
                "owner": edge.owner,
                "from": edge.from,
                "to": edge.to,
                "kind": edge.kind,
                "line": edge.line,
                "span": edge.span,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_node_rows_without_file_path() {
        let rows = project_nodes(&[ControlFlowNode {
            id: "test.rb:Example#run:1".to_string(),
            file: "test.rb".to_string(),
            function: "run".to_string(),
            owner: "Example".to_string(),
            kind: "statement".to_string(),
            role: "call".to_string(),
            line: 3,
            span: [3, 4, 3, 12],
            source: "work()".to_string(),
        }]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["id"], "test.rb:Example#run:1");
        assert_eq!(rows[0]["function"], "run");
        assert!(rows[0].get("file").is_none());
    }

    #[test]
    fn projects_edge_rows_without_file_path() {
        let rows = project_edges(&[ControlFlowEdge {
            file: "test.rb".to_string(),
            function: "run".to_string(),
            owner: "Example".to_string(),
            from: "entry".to_string(),
            to: "stmt1".to_string(),
            kind: "fallthrough".to_string(),
            line: 3,
            span: [3, 4, 3, 12],
        }]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["from"], "entry");
        assert_eq!(rows[0]["to"], "stmt1");
        assert_eq!(rows[0]["kind"], "fallthrough");
        assert!(rows[0].get("file").is_none());
    }
}
