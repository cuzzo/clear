//! Attribute diff hunks to the logical units (functions/classes) they touch.
//!
//! Units come from the existing tree-sitter `HeuristicExtractor` run over the
//! new-side source. Each added/context line is charged to the innermost
//! enclosing unit; deleted lines follow the nearest surviving new-side line.

use crate::cli::diff::gitdiff::{ChangeStatus, FileDiff, LineOrigin};
use crate::cli::diff::risk::{leaf_risk, Evidence, RiskScore};
use crate::cli::diff::visibility::{classify, Visibility};
use crate::extract::{is_test_source_path, BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, LogicalUnit, UnitKind};

#[derive(Debug, Clone, PartialEq)]
pub struct ChangedUnit {
    pub name: String,
    pub kind: UnitKind,
    pub path: String,
    pub start_line: u32,
    pub end_line: u32,
    pub signature: String,
    pub visibility: Visibility,
    pub is_test: bool,
    pub added: u32,
    pub removed: u32,
    /// New-side line numbers added within this unit (for accurate
    /// uncovered-changed-LoC; pre-existing uncovered lines are excluded).
    pub added_lines: Vec<u32>,
    pub evidence: Evidence,
}

impl ChangedUnit {
    pub fn changed_loc(&self) -> u32 {
        self.added + self.removed
    }

    pub fn risk(&self) -> RiskScore {
        leaf_risk(self.added, self.removed, &self.evidence)
    }

    /// The unqualified class/module owner encoded in a qualified name, if any
    /// (`Store.open` -> `Some("Store")`, `run` -> `None`).
    pub fn owner(&self) -> Option<&str> {
        let idx = self.name.rfind(['.', ':'])?;
        let owner = &self.name[..idx];
        // Strip a trailing `:` left by a `::` separator.
        Some(owner.trim_end_matches(':')).filter(|s| !s.is_empty())
    }

    /// The unqualified leaf of the name (`Store.open` -> `open`).
    pub fn leaf(&self) -> &str {
        self.name.rsplit(['.', ':']).next().unwrap_or(&self.name)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FileChange {
    pub path: String,
    pub old_path: Option<String>,
    pub status: ChangeStatus,
    pub is_test: bool,
    pub units: Vec<ChangedUnit>,
    pub file_added: u32,
    pub file_removed: u32,
    pub unattributed_added: u32,
    pub unattributed_removed: u32,
}

/// Find the innermost (smallest-span) unit enclosing a 1-based new-side line.
fn enclosing(units: &[LogicalUnit], line: u32) -> Option<usize> {
    units
        .iter()
        .enumerate()
        .filter(|(_, u)| u.start_line <= line && line <= u.end_line)
        .min_by(|(_, a), (_, b)| {
            let span = |u: &LogicalUnit| u.end_line.saturating_sub(u.start_line);
            span(a).cmp(&span(b)).then(b.start_line.cmp(&a.start_line))
        })
        .map(|(idx, _)| idx)
}

/// Build the per-file change record: which units changed and by how much.
///
/// `new_source` is the new-side file contents (working tree or blob). It is
/// `None` for deleted files, in which case every removed line is unattributed.
pub fn assign_units(file: &FileDiff, new_source: Option<&str>) -> FileChange {
    let is_test = is_test_source_path(&file.path);
    let extractor = HeuristicExtractor::default();

    let (logical_units, lines): (Vec<LogicalUnit>, Vec<&str>) = match new_source {
        Some(source) if extractor.supports_path(&file.path) => {
            let blob = BlobFile {
                path: file.path.clone(),
                contents: source.to_string(),
            };
            (extractor.extract_units(&blob), source.lines().collect())
        }
        Some(source) => (Vec::new(), source.lines().collect()),
        None => (Vec::new(), Vec::new()),
    };

    let mut added = vec![0u32; logical_units.len()];
    let mut added_lines: Vec<Vec<u32>> = vec![Vec::new(); logical_units.len()];
    let mut removed = vec![0u32; logical_units.len()];
    let mut unattributed_added = 0u32;
    let mut unattributed_removed = 0u32;
    let mut file_added = 0u32;
    let mut file_removed = 0u32;

    for hunk in &file.hunks {
        let mut last_new = hunk.new_start;
        for line in &hunk.lines {
            match line.origin {
                LineOrigin::Add => {
                    file_added += 1;
                    let lineno = line.new_lineno.unwrap_or(last_new);
                    last_new = lineno;
                    match enclosing(&logical_units, lineno) {
                        Some(idx) => {
                            added[idx] += 1;
                            added_lines[idx].push(lineno);
                        }
                        None => unattributed_added += 1,
                    }
                }
                LineOrigin::Del => {
                    file_removed += 1;
                    match enclosing(&logical_units, last_new) {
                        Some(idx) => removed[idx] += 1,
                        None => unattributed_removed += 1,
                    }
                }
                LineOrigin::Context => {
                    if let Some(lineno) = line.new_lineno {
                        last_new = lineno;
                    }
                }
            }
        }
    }

    let mut units = Vec::new();
    for (idx, unit) in logical_units.into_iter().enumerate() {
        if added[idx] == 0 && removed[idx] == 0 {
            continue;
        }
        let visibility = classify(
            &file.path,
            &unit.name,
            &unit.signature,
            unit.start_line,
            &lines,
        );
        units.push(ChangedUnit {
            name: unit.name,
            kind: unit.kind,
            path: file.path.clone(),
            start_line: unit.start_line,
            end_line: unit.end_line,
            signature: unit.signature,
            visibility,
            is_test,
            added: added[idx],
            removed: removed[idx],
            added_lines: std::mem::take(&mut added_lines[idx]),
            evidence: Evidence::default(),
        });
    }
    // Riskiest first within the file.
    units.sort_by(|a, b| {
        b.risk()
            .partial_cmp(&a.risk())
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.start_line.cmp(&b.start_line))
    });

    FileChange {
        path: file.path.clone(),
        old_path: file.old_path.clone(),
        status: file.status,
        is_test,
        units,
        file_added,
        file_removed,
        unattributed_added,
        unattributed_removed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::diff::gitdiff::{DiffLine, Hunk};

    fn add(new_lineno: u32, content: &str) -> DiffLine {
        DiffLine {
            origin: LineOrigin::Add,
            old_lineno: None,
            new_lineno: Some(new_lineno),
            content: content.to_string(),
        }
    }

    fn ctx(old: u32, new: u32, content: &str) -> DiffLine {
        DiffLine {
            origin: LineOrigin::Context,
            old_lineno: Some(old),
            new_lineno: Some(new),
            content: content.to_string(),
        }
    }

    fn del(old: u32, content: &str) -> DiffLine {
        DiffLine {
            origin: LineOrigin::Del,
            old_lineno: Some(old),
            new_lineno: None,
            content: content.to_string(),
        }
    }

    const RUST_SRC: &str =
        "pub fn alpha() {\n    let a = 1;\n    let b = 2;\n}\n\nfn beta() {\n    let c = 3;\n}\n";

    #[test]
    fn assigns_added_lines_to_enclosing_function() {
        // Two lines added inside alpha (lines 2,3).
        let file = FileDiff {
            path: "src/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 1,
                new_start: 1,
                new_lines: 4,
                lines: vec![
                    ctx(1, 1, "pub fn alpha() {"),
                    add(2, "    let a = 1;"),
                    add(3, "    let b = 2;"),
                    ctx(2, 4, "}"),
                ],
            }],
        };
        let change = assign_units(&file, Some(RUST_SRC));
        assert_eq!(change.file_added, 2);
        assert_eq!(change.units.len(), 1);
        let alpha = &change.units[0];
        assert_eq!(alpha.name, "alpha");
        assert_eq!(alpha.added, 2);
        assert_eq!(alpha.visibility, Visibility::Public);
        assert_eq!(change.unattributed_added, 0);
    }

    #[test]
    fn attributes_private_function_and_deletions() {
        // Delete a line inside beta (private).
        let file = FileDiff {
            path: "src/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 6,
                old_lines: 3,
                new_start: 6,
                new_lines: 2,
                lines: vec![
                    ctx(6, 6, "fn beta() {"),
                    del(7, "    let c = 3;"),
                    ctx(8, 7, "}"),
                ],
            }],
        };
        let change = assign_units(&file, Some(RUST_SRC));
        assert_eq!(change.file_removed, 1);
        assert_eq!(change.units.len(), 1);
        let beta = &change.units[0];
        assert_eq!(beta.name, "beta");
        assert_eq!(beta.removed, 1);
        assert_eq!(beta.visibility, Visibility::Private);
    }

    #[test]
    fn lines_outside_any_unit_are_unattributed() {
        let file = FileDiff {
            path: "src/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 5,
                old_lines: 0,
                new_start: 5,
                new_lines: 1,
                lines: vec![add(5, "// a top-level comment between fns")],
            }],
        };
        let change = assign_units(&file, Some(RUST_SRC));
        assert_eq!(change.unattributed_added, 1);
        assert!(change.units.is_empty());
    }

    #[test]
    fn unsupported_extension_yields_no_units() {
        let file = FileDiff {
            path: "notes.txt".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 0,
                new_start: 1,
                new_lines: 1,
                lines: vec![add(1, "hello")],
            }],
        };
        let change = assign_units(&file, Some("hello\n"));
        assert!(change.units.is_empty());
        assert_eq!(change.unattributed_added, 1);
    }

    #[test]
    fn deleted_file_has_no_new_source() {
        let file = FileDiff {
            path: "src/a.rs".into(),
            old_path: None,
            status: ChangeStatus::Deleted,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 2,
                new_start: 0,
                new_lines: 0,
                lines: vec![del(1, "pub fn alpha() {}"), del(2, "// tail")],
            }],
        };
        let change = assign_units(&file, None);
        assert_eq!(change.file_removed, 2);
        assert_eq!(change.unattributed_removed, 2);
        assert!(change.units.is_empty());
    }

    #[test]
    fn test_path_marks_units_as_test() {
        let src = "fn it_works() {\n    assert!(true);\n}\n";
        let file = FileDiff {
            path: "src/foo_test.rs".into(),
            old_path: None,
            status: ChangeStatus::Modified,
            hunks: vec![Hunk {
                old_start: 1,
                old_lines: 0,
                new_start: 2,
                new_lines: 1,
                lines: vec![ctx(1, 1, "fn it_works() {"), add(2, "    assert!(true);")],
            }],
        };
        let change = assign_units(&file, Some(src));
        assert!(change.is_test);
        assert!(change.units.iter().all(|u| u.is_test));
    }

    #[test]
    fn owner_and_leaf_split_qualified_names() {
        let unit = ChangedUnit {
            name: "Store.open".into(),
            kind: UnitKind::Function,
            path: "a.rb".into(),
            start_line: 1,
            end_line: 2,
            signature: "def open".into(),
            visibility: Visibility::Public,
            is_test: false,
            added: 1,
            removed: 0,
            added_lines: vec![],
            evidence: Evidence::default(),
        };
        assert_eq!(unit.owner(), Some("Store"));
        assert_eq!(unit.leaf(), "open");

        let top = ChangedUnit {
            name: "run".into(),
            ..unit.clone()
        };
        assert_eq!(top.owner(), None);
        assert_eq!(top.leaf(), "run");
    }
}
