//! Flatten the collapse tree into a navigable, searchable row list.
//!
//! Pure over the `diff::tree::Node` structure: rows respect each node's `open`
//! flag, a non-empty filter auto-expands ancestors of matches, and helpers
//! resolve/toggle nodes by index path. The TUI layer owns selection + input.

use crate::cli::diff::tree::{Node, NodeKind};

#[derive(Debug, Clone, PartialEq)]
pub struct FlatRow {
    /// Index path from the root's children to this node.
    pub path: Vec<usize>,
    pub depth: usize,
    pub label: String,
    pub kind: NodeKind,
    pub added: u32,
    pub removed: u32,
    pub risk: f64,
    pub has_children: bool,
    pub open: bool,
}

fn label_matches(node: &Node, filter_lower: &str) -> bool {
    node.label.to_lowercase().contains(filter_lower)
}

/// Whether a node's subtree (including itself) contains a filter match.
fn subtree_matches(node: &Node, filter_lower: &str) -> bool {
    if filter_lower.is_empty() {
        return true;
    }
    label_matches(node, filter_lower)
        || node
            .children
            .iter()
            .any(|c| subtree_matches(c, filter_lower))
}

/// Flatten visible rows. `filter` is matched case-insensitively against labels;
/// a non-empty filter forces open any node whose descendants match.
pub fn flatten(root: &Node, filter: &str) -> Vec<FlatRow> {
    let filter_lower = filter.to_lowercase();
    let mut rows = Vec::new();
    walk(root, &[], 0, &filter_lower, &mut rows);
    rows
}

fn walk(node: &Node, path: &[usize], depth: usize, filter_lower: &str, rows: &mut Vec<FlatRow>) {
    for (i, child) in node.children.iter().enumerate() {
        if !subtree_matches(child, filter_lower) {
            continue;
        }
        let mut child_path = path.to_vec();
        child_path.push(i);
        let has_children = !child.children.is_empty();
        let descendant_match = !filter_lower.is_empty()
            && child
                .children
                .iter()
                .any(|c| subtree_matches(c, filter_lower));
        let open = has_children && (child.open || descendant_match);
        rows.push(FlatRow {
            path: child_path.clone(),
            depth,
            label: child.label.clone(),
            kind: child.kind,
            added: child.added,
            removed: child.removed,
            risk: child.risk.0,
            has_children,
            open,
        });
        if open {
            walk(child, &child_path, depth + 1, filter_lower, rows);
        }
    }
}

/// Resolve a node by index path (into the root's children subtree).
pub fn node_at<'a>(root: &'a Node, path: &[usize]) -> Option<&'a Node> {
    let mut cursor = root;
    for &i in path {
        cursor = cursor.children.get(i)?;
    }
    Some(cursor)
}

/// Mutable resolve, for toggling `open`.
pub fn node_at_mut<'a>(root: &'a mut Node, path: &[usize]) -> Option<&'a mut Node> {
    let mut cursor = root;
    for &i in path {
        cursor = cursor.children.get_mut(i)?;
    }
    Some(cursor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::risk::RiskScore;

    fn node(kind: NodeKind, label: &str, open: bool, children: Vec<Node>) -> Node {
        Node {
            kind,
            label: label.into(),
            path: None,
            unit: None,
            children,
            added: 0,
            removed: 0,
            risk: RiskScore::ZERO,
            open,
        }
    }

    fn sample() -> Node {
        node(
            NodeKind::Root,
            "root",
            true,
            vec![node(
                NodeKind::Project,
                "proj",
                true,
                vec![
                    node(
                        NodeKind::File,
                        "open.rs",
                        true,
                        vec![node(NodeKind::Function, "verify()", false, vec![])],
                    ),
                    node(
                        NodeKind::File,
                        "closed.rs",
                        false,
                        vec![node(NodeKind::Function, "hidden()", false, vec![])],
                    ),
                ],
            )],
        )
    }

    #[test]
    fn respects_open_flags() {
        let rows = flatten(&sample(), "");
        let labels: Vec<_> = rows.iter().map(|r| r.label.as_str()).collect();
        // open.rs is open (verify shown); closed.rs is collapsed (hidden not shown).
        assert_eq!(labels, vec!["proj", "open.rs", "verify()", "closed.rs"]);
    }

    #[test]
    fn depth_tracks_nesting() {
        let rows = flatten(&sample(), "");
        let proj = rows.iter().find(|r| r.label == "proj").unwrap();
        let verify = rows.iter().find(|r| r.label == "verify()").unwrap();
        assert_eq!(proj.depth, 0);
        assert_eq!(verify.depth, 2);
    }

    #[test]
    fn filter_reveals_matches_in_collapsed_branches() {
        let rows = flatten(&sample(), "hidden");
        let labels: Vec<_> = rows.iter().map(|r| r.label.as_str()).collect();
        // Filtering to "hidden" auto-expands closed.rs and drops open.rs's subtree.
        assert!(labels.contains(&"closed.rs"));
        assert!(labels.contains(&"hidden()"));
        assert!(!labels.contains(&"verify()"));
    }

    #[test]
    fn filter_is_case_insensitive() {
        let rows = flatten(&sample(), "VERIFY");
        assert!(rows.iter().any(|r| r.label == "verify()"));
    }

    #[test]
    fn node_at_resolves_and_toggles() {
        let mut root = sample();
        // proj (0) -> closed.rs (1)
        let path = vec![0, 1];
        assert_eq!(node_at(&root, &path).unwrap().label, "closed.rs");
        node_at_mut(&mut root, &path).unwrap().open = true;
        let rows = flatten(&root, "");
        assert!(rows.iter().any(|r| r.label == "hidden()"));
    }

    #[test]
    fn node_at_bad_path_is_none() {
        let root = sample();
        assert!(node_at(&root, &[9]).is_none());
    }

    #[test]
    fn has_children_and_open_flags_are_reported() {
        let rows = flatten(&sample(), "");
        let openrs = rows.iter().find(|r| r.label == "open.rs").unwrap();
        assert!(openrs.has_children && openrs.open);
        let verify = rows.iter().find(|r| r.label == "verify()").unwrap();
        assert!(!verify.has_children);
    }
}
