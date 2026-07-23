//! Line-level git diff extraction for `gigasail diff`.
//!
//! The core crate only tracks file-level tree-to-tree changes. The review UI
//! needs hunks and per-line add/remove/context data, so this module reads a
//! `git2::Diff` via `git2::Patch` (which sidesteps the borrow-checker friction
//! of `Diff::foreach` closures sharing an accumulator).

use anyhow::{Context, Result};
use git2::{Repository, Tree};
use std::path::Path;

/// What set of changes to diff. Resolved from CLI args.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffTarget {
    /// Staged changes: the index versus HEAD. Default.
    Staged,
    /// Working tree (staged + unstaged) versus HEAD. `--all`.
    Workdir,
    /// A single commit reviewed as `parent..commit`.
    Commit(String),
    /// An explicit `a..b` range.
    Range(String, String),
}

impl DiffTarget {
    /// A short human label for the diff header.
    pub fn label(&self) -> String {
        match self {
            DiffTarget::Staged => "staged vs HEAD".to_string(),
            DiffTarget::Workdir => "working tree vs HEAD".to_string(),
            DiffTarget::Commit(rev) => format!("commit {rev}"),
            DiffTarget::Range(a, b) => format!("{a}..{b}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeStatus {
    Added,
    Modified,
    Renamed,
    Deleted,
    Other,
}

impl ChangeStatus {
    fn from_delta(status: git2::Delta) -> Self {
        match status {
            git2::Delta::Added => ChangeStatus::Added,
            git2::Delta::Modified => ChangeStatus::Modified,
            git2::Delta::Renamed | git2::Delta::Copied => ChangeStatus::Renamed,
            git2::Delta::Deleted => ChangeStatus::Deleted,
            _ => ChangeStatus::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineOrigin {
    Add,
    Del,
    Context,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub origin: LineOrigin,
    pub old_lineno: Option<u32>,
    pub new_lineno: Option<u32>,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiff {
    pub path: String,
    pub old_path: Option<String>,
    pub status: ChangeStatus,
    pub hunks: Vec<Hunk>,
}

impl FileDiff {
    pub fn added_lines(&self) -> u32 {
        self.hunks
            .iter()
            .flat_map(|h| &h.lines)
            .filter(|l| l.origin == LineOrigin::Add)
            .count() as u32
    }

    pub fn removed_lines(&self) -> u32 {
        self.hunks
            .iter()
            .flat_map(|h| &h.lines)
            .filter(|l| l.origin == LineOrigin::Del)
            .count() as u32
    }
}

fn head_tree(repo: &Repository) -> Result<Option<Tree<'_>>> {
    match repo.head() {
        Ok(head) => Ok(Some(head.peel_to_commit()?.tree()?)),
        // Unborn branch (no commits yet): diff against the empty tree.
        Err(_) => Ok(None),
    }
}

fn revspec_tree<'a>(repo: &'a Repository, rev: &str) -> Result<Tree<'a>> {
    let object = repo
        .revparse_single(rev)
        .with_context(|| format!("resolve revision {rev:?}"))?;
    Ok(object.peel_to_commit()?.tree()?)
}

/// Compute the line-level diff for `target` in the repository at `repo_path`.
pub fn compute_diff(repo_path: &Path, target: &DiffTarget) -> Result<Vec<FileDiff>> {
    let repo = Repository::open(repo_path)
        .with_context(|| format!("open git repository {}", repo_path.display()))?;
    let mut opts = git2::DiffOptions::new();
    opts.context_lines(3);

    let mut diff = match target {
        DiffTarget::Staged => {
            let tree = head_tree(&repo)?;
            repo.diff_tree_to_index(tree.as_ref(), None, Some(&mut opts))?
        }
        DiffTarget::Workdir => {
            let tree = head_tree(&repo)?;
            repo.diff_tree_to_workdir_with_index(tree.as_ref(), Some(&mut opts))?
        }
        DiffTarget::Commit(rev) => {
            let commit = repo.revparse_single(rev)?.peel_to_commit()?;
            let new_tree = commit.tree()?;
            let old_tree = match commit.parent(0) {
                Ok(parent) => Some(parent.tree()?),
                Err(_) => None,
            };
            repo.diff_tree_to_tree(old_tree.as_ref(), Some(&new_tree), Some(&mut opts))?
        }
        DiffTarget::Range(a, b) => {
            let old_tree = revspec_tree(&repo, a)?;
            let new_tree = revspec_tree(&repo, b)?;
            repo.diff_tree_to_tree(Some(&old_tree), Some(&new_tree), Some(&mut opts))?
        }
    };

    let mut find = git2::DiffFindOptions::new();
    find.renames(true);
    find.copies(true);
    diff.find_similar(Some(&mut find))?;

    collect_file_diffs(&diff)
}

/// Build the structured `FileDiff` list from a resolved `git2::Diff`.
pub fn collect_file_diffs(diff: &git2::Diff) -> Result<Vec<FileDiff>> {
    let mut files = Vec::new();
    let delta_count = diff.deltas().len();
    for idx in 0..delta_count {
        let delta = match diff.get_delta(idx) {
            Some(delta) => delta,
            None => continue,
        };
        let status = ChangeStatus::from_delta(delta.status());
        let new_path = delta
            .new_file()
            .path()
            .and_then(|p| p.to_str())
            .map(str::to_string);
        let old_path = delta
            .old_file()
            .path()
            .and_then(|p| p.to_str())
            .map(str::to_string);
        // A deleted file has no new path; fall back to the old path so the row
        // still names something.
        let path = match new_path.clone().or_else(|| old_path.clone()) {
            Some(path) => path,
            None => continue,
        };
        let renamed_from = if old_path != new_path { old_path } else { None };

        let hunks = match git2::Patch::from_diff(diff, idx)? {
            Some(patch) => collect_hunks(&patch)?,
            // Binary blobs and pure renames produce no textual patch.
            None => Vec::new(),
        };

        files.push(FileDiff {
            path,
            old_path: renamed_from,
            status,
            hunks,
        });
    }
    Ok(files)
}

fn collect_hunks(patch: &git2::Patch) -> Result<Vec<Hunk>> {
    let mut hunks = Vec::new();
    let hunk_count = patch.num_hunks();
    for h in 0..hunk_count {
        let (hunk, line_count) = patch.hunk(h)?;
        let mut lines = Vec::with_capacity(line_count);
        for l in 0..line_count {
            let line = patch.line_in_hunk(h, l)?;
            let origin = match line.origin() {
                '+' => LineOrigin::Add,
                '-' => LineOrigin::Del,
                _ => LineOrigin::Context,
            };
            let content = String::from_utf8_lossy(line.content())
                .trim_end_matches(['\n', '\r'])
                .to_string();
            lines.push(DiffLine {
                origin,
                old_lineno: line.old_lineno(),
                new_lineno: line.new_lineno(),
                content,
            });
        }
        hunks.push(Hunk {
            old_start: hunk.old_start(),
            old_lines: hunk.old_lines(),
            new_start: hunk.new_start(),
            new_lines: hunk.new_lines(),
            lines,
        });
    }
    Ok(hunks)
}

/// Resolve the new-side source of a changed file, for unit extraction.
///
/// The new side must match the diff: `Staged` reads the **index** blob (not the
/// working tree, which may have later unstaged edits), `Workdir` reads the file
/// from disk, and commit/range targets read the blob from the new-side tree.
/// Returns `None` for deleted or unreadable files.
pub fn new_side_source(repo_path: &Path, target: &DiffTarget, path: &str) -> Option<String> {
    match target {
        DiffTarget::Workdir => std::fs::read_to_string(repo_path.join(path)).ok(),
        DiffTarget::Staged => {
            let repo = Repository::open(repo_path).ok()?;
            let index = repo.index().ok()?;
            let entry = index.get_path(Path::new(path), 0)?;
            blob_text(&repo, entry.id)
        }
        DiffTarget::Commit(rev) | DiffTarget::Range(_, rev) => {
            let repo = Repository::open(repo_path).ok()?;
            let tree = repo
                .revparse_single(rev)
                .ok()?
                .peel_to_commit()
                .ok()?
                .tree()
                .ok()?;
            let entry = tree.get_path(Path::new(path)).ok()?;
            blob_text(&repo, entry.id())
        }
    }
}

fn blob_text(repo: &Repository, oid: git2::Oid) -> Option<String> {
    let blob = repo.find_blob(oid).ok()?;
    if blob.is_binary() {
        return None;
    }
    std::str::from_utf8(blob.content()).ok().map(str::to_string)
}

/// Pure line-level diff of two source snapshots via an LCS walk. No git2: the
/// plan-driven review path already carries base/head source, so this needs only
/// the two strings. Emits a single hunk that spans the whole file, with context
/// lines carrying both line numbers, additions carrying the new number, and
/// deletions the old — the same shape the renderer consumes from git2 hunks.
pub fn diff_lines(base: &str, head: &str) -> Vec<Hunk> {
    let base_lines: Vec<&str> = base.lines().collect();
    let head_lines: Vec<&str> = head.lines().collect();
    let lines = lcs_diff(&base_lines, &head_lines);
    if lines.iter().all(|l| l.origin == LineOrigin::Context) {
        return Vec::new();
    }
    vec![Hunk {
        old_start: 1,
        old_lines: base_lines.len() as u32,
        new_start: 1,
        new_lines: head_lines.len() as u32,
        lines,
    }]
}

fn lcs_diff(base: &[&str], head: &[&str]) -> Vec<DiffLine> {
    let n = base.len();
    let m = head.len();
    // dp[i][j] = LCS length of base[i..] and head[j..].
    let mut dp = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if base[i] == head[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let context = |old: usize, new: usize, content: &str| DiffLine {
        origin: LineOrigin::Context,
        old_lineno: Some(old as u32 + 1),
        new_lineno: Some(new as u32 + 1),
        content: content.to_string(),
    };
    let deletion = |old: usize, content: &str| DiffLine {
        origin: LineOrigin::Del,
        old_lineno: Some(old as u32 + 1),
        new_lineno: None,
        content: content.to_string(),
    };
    let addition = |new: usize, content: &str| DiffLine {
        origin: LineOrigin::Add,
        old_lineno: None,
        new_lineno: Some(new as u32 + 1),
        content: content.to_string(),
    };
    let mut out = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if base[i] == head[j] {
            out.push(context(i, j, base[i]));
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            out.push(deletion(i, base[i]));
            i += 1;
        } else {
            out.push(addition(j, head[j]));
            j += 1;
        }
    }
    while i < n {
        out.push(deletion(i, base[i]));
        i += 1;
    }
    while j < m {
        out.push(addition(j, head[j]));
        j += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("run git");
        assert!(status.status.success(), "git {:?} failed", args);
    }

    fn init_repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]);
        git(dir.path(), &["config", "user.email", "t@t"]);
        git(dir.path(), &["config", "user.name", "t"]);
        dir
    }

    #[test]
    fn target_labels_are_human_readable() {
        assert_eq!(DiffTarget::Staged.label(), "staged vs HEAD");
        assert_eq!(DiffTarget::Workdir.label(), "working tree vs HEAD");
        assert_eq!(DiffTarget::Commit("abc".into()).label(), "commit abc");
        assert_eq!(DiffTarget::Range("a".into(), "b".into()).label(), "a..b");
    }

    #[test]
    fn staged_diff_reports_added_lines_and_hunks() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "fn a() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);

        fs::write(dir.path().join("a.rs"), "fn a() {}\nfn b() {}\nfn c() {}\n").unwrap();
        git(dir.path(), &["add", "a.rs"]);

        let files = compute_diff(dir.path(), &DiffTarget::Staged).unwrap();
        assert_eq!(files.len(), 1);
        let file = &files[0];
        assert_eq!(file.path, "a.rs");
        assert_eq!(file.status, ChangeStatus::Modified);
        assert_eq!(file.added_lines(), 2);
        assert_eq!(file.removed_lines(), 0);
        assert!(!file.hunks.is_empty());
        let added: Vec<_> = file
            .hunks
            .iter()
            .flat_map(|h| &h.lines)
            .filter(|l| l.origin == LineOrigin::Add)
            .map(|l| l.new_lineno.unwrap())
            .collect();
        assert_eq!(added, vec![2, 3]);
    }

    #[test]
    fn workdir_diff_sees_unstaged_changes() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "one\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        fs::write(dir.path().join("a.rs"), "one\ntwo\n").unwrap();

        // Nothing staged: the staged diff is empty, the workdir diff is not.
        assert!(compute_diff(dir.path(), &DiffTarget::Staged)
            .unwrap()
            .is_empty());
        let workdir = compute_diff(dir.path(), &DiffTarget::Workdir).unwrap();
        assert_eq!(workdir.len(), 1);
        assert_eq!(workdir[0].added_lines(), 1);
    }

    #[test]
    fn commit_target_diffs_against_parent() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "one\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        fs::write(dir.path().join("a.rs"), "one\ntwo\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "second"]);

        let files = compute_diff(dir.path(), &DiffTarget::Commit("HEAD".into())).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].added_lines(), 1);
    }

    #[test]
    fn range_target_diffs_two_trees() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "one\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        fs::write(dir.path().join("a.rs"), "one\ntwo\nthree\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "second"]);

        let files = compute_diff(
            dir.path(),
            &DiffTarget::Range("HEAD~1".into(), "HEAD".into()),
        )
        .unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].added_lines(), 2);
    }

    #[test]
    fn first_commit_diffs_against_empty_tree() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "one\ntwo\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);

        let files = compute_diff(dir.path(), &DiffTarget::Commit("HEAD".into())).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].status, ChangeStatus::Added);
        assert_eq!(files[0].added_lines(), 2);
    }

    #[test]
    fn new_side_source_reads_workdir_and_commit() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "fn a() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        fs::write(dir.path().join("a.rs"), "fn a() {}\n// edit\n").unwrap();

        // Workdir target reads from disk (sees the uncommitted edit).
        let workdir = new_side_source(dir.path(), &DiffTarget::Workdir, "a.rs").unwrap();
        assert!(workdir.contains("// edit"));

        // Commit target reads the committed blob (no edit).
        let committed =
            new_side_source(dir.path(), &DiffTarget::Commit("HEAD".into()), "a.rs").unwrap();
        assert!(!committed.contains("// edit"));

        // Missing path -> None.
        assert!(new_side_source(dir.path(), &DiffTarget::Workdir, "nope.rs").is_none());
        assert!(
            new_side_source(dir.path(), &DiffTarget::Commit("HEAD".into()), "nope.rs").is_none()
        );
    }

    #[test]
    fn staged_source_reads_index_not_working_tree() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "fn a() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        // Stage one version, then make a DIFFERENT unstaged edit on top.
        fs::write(dir.path().join("a.rs"), "fn a() {}\n// staged\n").unwrap();
        git(dir.path(), &["add", "a.rs"]);
        fs::write(
            dir.path().join("a.rs"),
            "fn a() {}\n// staged\n// unstaged\n",
        )
        .unwrap();

        // Staged source must reflect the index (the staged version), NOT the
        // later working-tree edit.
        let staged = new_side_source(dir.path(), &DiffTarget::Staged, "a.rs").unwrap();
        assert!(staged.contains("// staged"));
        assert!(!staged.contains("// unstaged"));
        // Workdir sees the latest edit.
        let workdir = new_side_source(dir.path(), &DiffTarget::Workdir, "a.rs").unwrap();
        assert!(workdir.contains("// unstaged"));
    }

    #[test]
    fn deleted_file_keeps_old_path() {
        let dir = init_repo();
        fs::write(dir.path().join("a.rs"), "one\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        fs::remove_file(dir.path().join("a.rs")).unwrap();
        git(dir.path(), &["add", "a.rs"]);

        let files = compute_diff(dir.path(), &DiffTarget::Staged).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "a.rs");
        assert_eq!(files[0].status, ChangeStatus::Deleted);
        assert_eq!(files[0].removed_lines(), 1);
    }

    #[test]
    fn diff_lines_marks_added_lines_with_new_numbers() {
        let hunks = diff_lines("fn a() {}\n", "fn a() {}\nfn b() {}\nfn c() {}\n");
        assert_eq!(hunks.len(), 1);
        let added: Vec<u32> = hunks[0]
            .lines
            .iter()
            .filter(|l| l.origin == LineOrigin::Add)
            .map(|l| l.new_lineno.unwrap())
            .collect();
        assert_eq!(added, vec![2, 3]);
        // The surviving line is context, carrying both line numbers.
        assert!(hunks[0]
            .lines
            .iter()
            .any(|l| l.origin == LineOrigin::Context && l.new_lineno == Some(1)));
    }

    #[test]
    fn diff_lines_interleaves_deletions() {
        let hunks = diff_lines("keep1\nremoved\nkeep2\n", "keep1\nkeep2\n");
        let seq: Vec<(LineOrigin, &str)> = hunks[0]
            .lines
            .iter()
            .map(|l| (l.origin, l.content.as_str()))
            .collect();
        assert_eq!(
            seq,
            vec![
                (LineOrigin::Context, "keep1"),
                (LineOrigin::Del, "removed"),
                (LineOrigin::Context, "keep2"),
            ]
        );
        assert_eq!(
            hunks[0]
                .lines
                .iter()
                .find(|l| l.origin == LineOrigin::Del)
                .unwrap()
                .old_lineno,
            Some(2)
        );
    }

    #[test]
    fn diff_lines_identical_sources_have_no_hunks() {
        assert!(diff_lines("same\ntext\n", "same\ntext\n").is_empty());
        assert!(diff_lines("", "").is_empty());
    }

    #[test]
    fn diff_lines_added_file_is_all_additions() {
        let hunks = diff_lines("", "one\ntwo\n");
        assert_eq!(hunks.len(), 1);
        assert!(hunks[0]
            .lines
            .iter()
            .all(|l| l.origin == LineOrigin::Add));
        assert_eq!(hunks[0].lines.len(), 2);
    }
}
