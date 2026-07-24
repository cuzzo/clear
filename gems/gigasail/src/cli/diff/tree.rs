//! Collapse changed units into a project -> dir -> file -> class -> function
//! tree, ranked by risk, with test code and private functions separated.

use crate::cli::diff::risk::RiskScore;
use crate::cli::diff::units::{ChangedUnit, FileChange};
use crate::model::UnitKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    /// The synthetic top row: the whole-change funnel summary.
    Summary,
    Root,
    Project,
    Directory,
    File,
    Class,
    Function,
    /// The single per-file `(PRIVATE FUNCTIONS)` blob.
    PrivateGroup,
    /// The per-project `(TESTS)` subtree that isolates test-code risk.
    TestGroup,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub kind: NodeKind,
    pub label: String,
    pub path: Option<String>,
    pub unit: Option<ChangedUnit>,
    pub children: Vec<Node>,
    pub added: u32,
    pub removed: u32,
    pub risk: RiskScore,
    pub open: bool,
}

impl Node {
    fn container(kind: NodeKind, label: impl Into<String>) -> Node {
        Node {
            kind,
            label: label.into(),
            path: None,
            unit: None,
            children: Vec::new(),
            added: 0,
            removed: 0,
            risk: RiskScore::ZERO,
            open: false,
        }
    }

    fn leaf(kind: NodeKind, unit: ChangedUnit) -> Node {
        let label = leaf_label(&unit);
        Node {
            kind,
            label,
            path: Some(unit.path.clone()),
            added: unit.added,
            removed: unit.removed,
            risk: unit.risk(),
            unit: Some(unit),
            children: Vec::new(),
            open: false,
        }
    }

    pub fn changed_loc(&self) -> u32 {
        self.added + self.removed
    }
}

fn leaf_label(unit: &ChangedUnit) -> String {
    match unit.kind {
        UnitKind::Function => format!("{}()", unit.leaf()),
        _ => unit.leaf().to_string(),
    }
}

/// Find-or-create a directory/container child by label under `children`.
fn child_mut<'a>(children: &'a mut Vec<Node>, kind: NodeKind, label: &str) -> &'a mut Node {
    if let Some(pos) = children
        .iter()
        .position(|c| c.kind == kind && c.label == label)
    {
        return &mut children[pos];
    }
    children.push(Node::container(kind, label));
    children.last_mut().unwrap()
}

/// Build the file node with its class/function/private structure.
fn file_node(fc: &FileChange) -> Node {
    let mut node = Node::container(NodeKind::File, file_basename(&fc.path));
    node.path = Some(fc.path.clone());

    // Seed class/module nodes from changed structural units.
    for unit in fc.units.iter().filter(|u| u.kind != UnitKind::Function) {
        let label = unit.leaf().to_string();
        let class = child_mut(&mut node.children, NodeKind::Class, &label);
        class.unit = Some(unit.clone());
    }

    for unit in fc.units.iter().filter(|u| u.kind == UnitKind::Function) {
        if unit.visibility.is_private() {
            let group = child_mut(
                &mut node.children,
                NodeKind::PrivateGroup,
                "(PRIVATE FUNCTIONS)",
            );
            group
                .children
                .push(Node::leaf(NodeKind::Function, unit.clone()));
            continue;
        }
        match unit.owner() {
            Some(owner) => {
                let owner = owner.rsplit([':', '.']).next().unwrap_or(owner).to_string();
                let class = child_mut(&mut node.children, NodeKind::Class, &owner);
                class
                    .children
                    .push(Node::leaf(NodeKind::Function, unit.clone()));
            }
            None => node
                .children
                .push(Node::leaf(NodeKind::Function, unit.clone())),
        }
    }

    // Files with only unattributed changes still carry their line counts.
    node.added = fc.file_added;
    node.removed = fc.file_removed;
    node
}

fn file_basename(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

/// Insert a file's node into the directory trie under `parent`, creating
/// `Directory` nodes for each path segment between the project root and file.
fn insert_file(parent: &mut Node, rel_dirs: &[&str], file: Node) {
    let mut cursor = parent;
    for dir in rel_dirs {
        cursor = child_mut(&mut cursor.children, NodeKind::Directory, dir);
    }
    cursor.children.push(file);
}

/// Build the full collapse tree. `project_for` maps a repo-relative file path to
/// its owning project label (e.g. by walking up to the nearest manifest).
pub fn build_tree(changes: &[FileChange], project_for: impl Fn(&str) -> String) -> Node {
    let mut root = Node::container(NodeKind::Root, "changes");

    for fc in changes {
        let project = project_for(&fc.path);
        let project_node = child_mut(&mut root.children, NodeKind::Project, &project);

        // Path relative to the project root, split into directory segments.
        let rel = fc
            .path
            .strip_prefix(&project)
            .map(|r| r.trim_start_matches('/'))
            .unwrap_or(&fc.path);
        let mut segments: Vec<&str> = rel.split('/').collect();
        segments.pop(); // drop the filename

        let file = file_node(fc);
        if fc.is_test {
            let tests = child_mut(&mut project_node.children, NodeKind::TestGroup, "(TESTS)");
            insert_file(tests, &segments, file);
        } else {
            insert_file(project_node, &segments, file);
        }
    }

    aggregate(&mut root);
    sort_by_risk(&mut root);
    open_max_path(&mut root);
    root
}

/// Bottom-up: a container's lines/risk are the sum of its children plus its own
/// unit (class nodes can carry a changed unit).
fn aggregate(node: &mut Node) -> (u32, u32, f64) {
    let mut added = node.unit.as_ref().map_or(0, |u| u.added);
    let mut removed = node.unit.as_ref().map_or(0, |u| u.removed);
    let mut risk = node.unit.as_ref().map_or(0.0, |u| u.risk().0);

    for child in &mut node.children {
        let (ca, cr, crisk) = aggregate(child);
        added += ca;
        removed += cr;
        risk += crisk;
    }

    // Leaf function/file line counts are already set; only overwrite containers.
    if !matches!(node.kind, NodeKind::Function) {
        if node.kind != NodeKind::File || !node.children.is_empty() {
            node.added = added;
            node.removed = removed;
        }
        node.risk = RiskScore(risk);
    }
    (node.added, node.removed, node.risk.0)
}

fn sort_by_risk(node: &mut Node) {
    for child in &mut node.children {
        sort_by_risk(child);
    }
    node.children.sort_by(|a, b| {
        b.risk
            .partial_cmp(&a.risk)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.changed_loc().cmp(&a.changed_loc()))
            .then(a.label.cmp(&b.label))
    });
}

/// Open every node on the single highest-risk path from the root.
fn open_max_path(node: &mut Node) {
    node.open = true;
    if let Some(first) = node.children.first_mut() {
        open_max_path(first);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::gitdiff::ChangeStatus;
    use crate::cli::diff::risk::Evidence;
    use crate::cli::diff::visibility::Visibility;

    fn unit(name: &str, kind: UnitKind, vis: Visibility, added: u32, path: &str) -> ChangedUnit {
        ChangedUnit {
            name: name.to_string(),
            kind,
            path: path.to_string(),
            start_line: 1,
            end_line: 5,
            signature: String::new(),
            visibility: vis,
            is_test: crate::extract::is_test_source_path(path),
            added,
            removed: 0,
            added_lines: vec![],
            added_dependencies: Vec::new(),
            added_state: Vec::new(),
            evidence: Evidence {
                t1_findings: added, // more churn -> more findings, for deterministic risk
                ..Default::default()
            },
        }
    }

    fn file(path: &str, units: Vec<ChangedUnit>) -> FileChange {
        let is_test = crate::extract::is_test_source_path(path);
        let file_added = units.iter().map(|u| u.added).sum();
        FileChange {
            path: path.to_string(),
            old_path: None,
            status: ChangeStatus::Modified,
            is_test,
            units,
            file_added,
            file_removed: 0,
            unattributed_added: 0,
            unattributed_removed: 0,
            added_imports: Vec::new(),
        }
    }

    fn flat(project: &str) -> impl Fn(&str) -> String + '_ {
        move |_| project.to_string()
    }

    fn find<'a>(node: &'a Node, kind: NodeKind, label: &str) -> Option<&'a Node> {
        if node.kind == kind && node.label == label {
            return Some(node);
        }
        node.children.iter().find_map(|c| find(c, kind, label))
    }

    #[test]
    fn nests_directories_between_project_and_file() {
        let changes = vec![file(
            "proj/src/auth/token.rs",
            vec![unit(
                "verify",
                UnitKind::Function,
                Visibility::Public,
                3,
                "proj/src/auth/token.rs",
            )],
        )];
        let root = build_tree(&changes, flat("proj"));
        let project = &root.children[0];
        assert_eq!(project.kind, NodeKind::Project);
        assert_eq!(project.label, "proj");
        // proj -> src -> auth -> token.rs
        let src = &project.children[0];
        assert_eq!((src.kind, src.label.as_str()), (NodeKind::Directory, "src"));
        let auth = &src.children[0];
        assert_eq!(auth.label, "auth");
        let f = &auth.children[0];
        assert_eq!((f.kind, f.label.as_str()), (NodeKind::File, "token.rs"));
    }

    #[test]
    fn public_functions_nest_under_class_private_go_to_blob() {
        let changes = vec![file(
            "proj/store.rb",
            vec![
                unit(
                    "Store.open",
                    UnitKind::Function,
                    Visibility::Public,
                    2,
                    "proj/store.rb",
                ),
                unit(
                    "Store.secret",
                    UnitKind::Function,
                    Visibility::Private,
                    1,
                    "proj/store.rb",
                ),
                unit(
                    "top_level",
                    UnitKind::Function,
                    Visibility::Public,
                    1,
                    "proj/store.rb",
                ),
            ],
        )];
        let root = build_tree(&changes, flat("proj"));
        let store_class = find(&root, NodeKind::Class, "Store").unwrap();
        assert_eq!(store_class.children.len(), 1);
        assert_eq!(store_class.children[0].label, "open()");

        let private = find(&root, NodeKind::PrivateGroup, "(PRIVATE FUNCTIONS)").unwrap();
        assert_eq!(private.children.len(), 1);
        assert_eq!(private.children[0].label, "secret()");

        let top = find(&root, NodeKind::Function, "top_level()");
        assert!(top.is_some());
    }

    #[test]
    fn test_files_go_under_tests_group() {
        let changes = vec![
            file(
                "proj/src/a.rs",
                vec![unit(
                    "a",
                    UnitKind::Function,
                    Visibility::Public,
                    1,
                    "proj/src/a.rs",
                )],
            ),
            file(
                "proj/spec/a_spec.rb",
                vec![unit(
                    "test_a",
                    UnitKind::Function,
                    Visibility::Public,
                    1,
                    "proj/spec/a_spec.rb",
                )],
            ),
        ];
        let root = build_tree(&changes, flat("proj"));
        let tests = find(&root, NodeKind::TestGroup, "(TESTS)").unwrap();
        assert!(find(tests, NodeKind::File, "a_spec.rb").is_some());
        // Production file is NOT under the tests group.
        assert!(find(tests, NodeKind::File, "a.rs").is_none());
    }

    #[test]
    fn risk_aggregates_and_sorts_riskiest_first() {
        let changes = vec![
            file(
                "proj/low.rs",
                vec![unit(
                    "low",
                    UnitKind::Function,
                    Visibility::Public,
                    1,
                    "proj/low.rs",
                )],
            ),
            file(
                "proj/high.rs",
                vec![unit(
                    "high",
                    UnitKind::Function,
                    Visibility::Public,
                    50,
                    "proj/high.rs",
                )],
            ),
        ];
        let root = build_tree(&changes, flat("proj"));
        // Riskiest file (high.rs) sorts first and is opened by default.
        let project = &root.children[0];
        assert_eq!(project.children[0].label, "high.rs");
        assert!(project.children[0].open);
        assert!(!project.children[1].open);
        assert!(project.risk.0 > 0.0);
    }

    #[test]
    fn synthetic_class_created_when_only_methods_change() {
        let changes = vec![file(
            "proj/a.rs",
            vec![unit(
                "Widget.draw",
                UnitKind::Function,
                Visibility::Public,
                3,
                "proj/a.rs",
            )],
        )];
        let root = build_tree(&changes, flat("proj"));
        let class = find(&root, NodeKind::Class, "Widget").unwrap();
        assert_eq!(class.unit, None); // synthetic: no changed class unit
        assert_eq!(class.children[0].label, "draw()");
    }

    #[test]
    fn changed_class_unit_carries_its_own_lines() {
        let changes = vec![file(
            "proj/a.rs",
            vec![
                unit(
                    "Config",
                    UnitKind::Class,
                    Visibility::Public,
                    4,
                    "proj/a.rs",
                ),
                unit(
                    "Config.load",
                    UnitKind::Function,
                    Visibility::Public,
                    2,
                    "proj/a.rs",
                ),
            ],
        )];
        let root = build_tree(&changes, flat("proj"));
        let class = find(&root, NodeKind::Class, "Config").unwrap();
        assert!(class.unit.is_some());
        // 4 (class body) + 2 (method) aggregated.
        assert_eq!(class.added, 6);
    }
}
