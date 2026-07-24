use crate::diff::{
    build_diff_plan_with_renames_and_overrides, classification_overrides, DiffPlan, RevisionFile,
};
use crate::model::{BlobFile, CommitMetadata};
use crate::vcs::{CommitChanges, VcsProvider};
use anyhow::{Context, Result};
use git2::{ObjectType, Repository, Sort, Tree};
use std::fs;
use std::path::{Path, PathBuf};

use std::collections::{BTreeMap, HashMap};

/// Synthetic revision used for the index plus working tree. It is never a
/// commit ID and consequently cannot be confused with persisted evidence.
pub const WORKTREE_REVISION: &str = "WORKTREE";

pub struct GitProvider {
    path: PathBuf,
    scope_prefix: Option<String>,
    blob_cache: std::sync::Mutex<HashMap<String, (git2::Oid, String)>>,
}

impl GitProvider {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path_buf = path.as_ref().to_path_buf();
        let repo = Repository::discover(&path_buf)
            .with_context(|| format!("open git repository {}", path_buf.display()))?;
        let workdir = repo.workdir().unwrap_or(path_buf.as_path()).to_path_buf();
        let requested = path_buf.canonicalize().unwrap_or(path_buf);
        let scope_prefix = requested
            .strip_prefix(&workdir)
            .ok()
            .filter(|path| !path.as_os_str().is_empty())
            .map(|path| path.to_string_lossy().replace('\\', "/"));
        Ok(Self {
            path: workdir,
            scope_prefix,
            blob_cache: std::sync::Mutex::new(HashMap::new()),
        })
    }

    pub fn file_contents_at_commit(&self, commit_hash: &str, path: &str) -> Result<Option<String>> {
        if commit_hash == WORKTREE_REVISION {
            return self.file_contents_in_worktree(path);
        }
        let repo = Repository::open(&self.path)?;
        let oid = git2::Oid::from_str(commit_hash)?;
        let commit = repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let repository_path = self.repository_path(path);
        let path_obj = Path::new(&repository_path);
        if let Ok(entry) = tree.get_path(path_obj) {
            let entry_id = entry.id();
            let cached_contents = {
                let cache = self.blob_cache.lock().unwrap();
                cache.get(&repository_path).and_then(|(oid, contents)| {
                    if *oid == entry_id {
                        Some(contents.clone())
                    } else {
                        None
                    }
                })
            };
            if let Some(contents) = cached_contents {
                return Ok(Some(contents));
            }
            if let Ok(blob) = repo.find_blob(entry_id) {
                if !blob.is_binary() {
                    if let Ok(contents) = std::str::from_utf8(blob.content()) {
                        let contents_str = contents.to_string();
                        self.blob_cache
                            .lock()
                            .unwrap()
                            .insert(repository_path, (entry_id, contents_str.clone()));
                        return Ok(Some(contents_str));
                    }
                }
            }
        }
        Ok(None)
    }

    fn file_contents_in_worktree(&self, path: &str) -> Result<Option<String>> {
        let candidate = self.path.join(self.repository_path(path));
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error).with_context(|| format!("stat working-tree file {path}"))
            }
        };
        if metadata.file_type().is_symlink() {
            return Ok(fs::read_link(&candidate)
                .ok()
                .and_then(|target| target.into_os_string().into_string().ok()));
        }
        if !metadata.is_file() {
            return Ok(None);
        }
        let root = self.path.canonicalize()?;
        let canonical = candidate
            .canonicalize()
            .with_context(|| format!("resolve working-tree file {path}"))?;
        if !canonical.starts_with(&root) {
            return Ok(None);
        }
        let bytes = fs::read(canonical)?;
        Ok((!bytes.contains(&0))
            .then(|| String::from_utf8(bytes).ok())
            .flatten())
    }

    /// Resolves a revision expression to the immutable commit object ID used by
    /// every diff API response.
    pub fn resolve_commit(&self, revision: &str) -> Result<String> {
        let repo = Repository::open(&self.path)?;
        let object = repo.revparse_single(revision)?;
        let commit = object.peel_to_commit()?;
        Ok(commit.id().to_string())
    }

    /// Number of commits reachable from `head` but not `base` (i.e. how many
    /// commits the diff range spans). `WORKTREE` head counts as its parent's
    /// range since it carries no commit of its own.
    pub fn commit_count(&self, base_revision: &str, head_revision: &str) -> Result<usize> {
        let head_revision = if head_revision == WORKTREE_REVISION {
            "HEAD"
        } else {
            head_revision
        };
        let base_oid = git2::Oid::from_str(&self.resolve_commit(base_revision)?)?;
        let head_oid = git2::Oid::from_str(&self.resolve_commit(head_revision)?)?;
        let repo = Repository::open(&self.path)?;
        let mut walk = repo.revwalk()?;
        walk.push(head_oid)?;
        walk.hide(base_oid)?;
        Ok(walk.count())
    }

    pub fn diff_plan(&self, base_revision: &str, head_revision: &str) -> Result<DiffPlan> {
        let base_oid = self.resolve_commit(base_revision)?;
        let repo = Repository::open(&self.path)?;
        let base_tree = repo.find_commit(git2::Oid::from_str(&base_oid)?)?.tree()?;
        let (head_oid, base, head, renames, override_contents) =
            if head_revision == WORKTREE_REVISION {
                let mut diff = repo.diff_tree_to_workdir_with_index(Some(&base_tree), None)?;
                let (base, mut head, renames) =
                    self.changed_snapshots(&repo, &base_tree, None, &mut diff)?;
                self.add_untracked_worktree_files(&repo, &mut head)?;
                (
                    WORKTREE_REVISION.to_string(),
                    base,
                    head,
                    renames,
                    self.file_contents_in_worktree(".giga/diff.toml")?,
                )
            } else {
                let head_oid = self.resolve_commit(head_revision)?;
                let head_tree = repo.find_commit(git2::Oid::from_str(&head_oid)?)?.tree()?;
                let mut diff = repo.diff_tree_to_tree(Some(&base_tree), Some(&head_tree), None)?;
                let (base, head, renames) =
                    self.changed_snapshots(&repo, &base_tree, Some(&head_tree), &mut diff)?;
                (
                    head_oid.clone(),
                    base,
                    head,
                    renames,
                    self.file_contents_at_commit(&head_oid, ".giga/diff.toml")?,
                )
            };
        let overrides = classification_overrides(override_contents.as_deref());
        Ok(build_diff_plan_with_renames_and_overrides(
            base_oid, head_oid, base, head, renames, overrides,
        ))
    }

    fn in_scope(&self, path: &str) -> bool {
        self.scope_prefix
            .as_ref()
            .is_none_or(|prefix| path == prefix || path.starts_with(&format!("{prefix}/")))
    }

    /// Converts a Git-worktree-relative path into this provider's public
    /// path identity. A provider opened on a nested project exposes paths
    /// relative to that project so Git, evidence artifacts, and the UI agree.
    fn scoped_path(&self, path: &str) -> Option<String> {
        match self.scope_prefix.as_deref() {
            None => Some(path.to_string()),
            Some(prefix) if path == prefix => Some(String::new()),
            Some(prefix) => path
                .strip_prefix(prefix)
                .and_then(|rest| rest.strip_prefix('/'))
                .map(str::to_string),
        }
    }

    /// Converts a project-relative path back to Git's enclosing-worktree path.
    fn repository_path(&self, path: &str) -> String {
        self.scope_prefix
            .as_ref()
            .map(|prefix| format!("{prefix}/{path}"))
            .unwrap_or_else(|| path.to_string())
    }

    /// Resolves a review pair to immutable object IDs. With no explicit base,
    /// the default is the merge base of the selected head and its first parent.
    /// For ordinary commits that is the first parent itself; using Git's merge
    /// base operation keeps the contract coherent for merge commits as well.
    pub fn diff_revisions(
        &self,
        base_revision: Option<&str>,
        head_revision: Option<&str>,
    ) -> Result<(String, String)> {
        let head_revision = head_revision.filter(|revision| !revision.trim().is_empty());
        let base_revision = base_revision.filter(|revision| !revision.trim().is_empty());
        if head_revision.is_some_and(|revision| revision == WORKTREE_REVISION) {
            let base = match base_revision {
                Some(base) => self.resolve_commit(base)?,
                None => self.resolve_commit("HEAD")?,
            };
            return Ok((base, WORKTREE_REVISION.into()));
        }
        // The interactive default is intentionally a working-tree review: it
        // includes staged, unstaged, and non-ignored untracked files. Passing
        // an explicit head continues to request an immutable commit review.
        if head_revision.is_none() {
            let base = match base_revision {
                Some(base) => self.resolve_commit(base)?,
                None => self.resolve_commit("HEAD")?,
            };
            return Ok((base, WORKTREE_REVISION.into()));
        }
        let head_oid = self.resolve_commit(head_revision.unwrap_or("HEAD"))?;
        let base_oid = match base_revision {
            Some(base) => self.resolve_commit(base)?,
            None => self.default_diff_base(&head_oid)?,
        };
        Ok((base_oid, head_oid))
    }

    fn default_diff_base(&self, head_oid: &str) -> Result<String> {
        let repo = Repository::open(&self.path)?;
        let head = repo.find_commit(git2::Oid::from_str(head_oid)?)?;
        let parent = head
            .parent(0)
            .with_context(|| "a diff requires a head commit with a first parent")?;
        Ok(repo.merge_base(head.id(), parent.id())?.to_string())
    }

    fn changed_snapshots(
        &self,
        repo: &Repository,
        base_tree: &Tree<'_>,
        head_tree: Option<&Tree<'_>>,
        diff: &mut git2::Diff<'_>,
    ) -> Result<(
        Vec<RevisionFile>,
        Vec<RevisionFile>,
        BTreeMap<String, String>,
    )> {
        let mut options = git2::DiffFindOptions::new();
        options.renames(true);
        diff.find_similar(Some(&mut options))?;
        let mut base = BTreeMap::new();
        let mut head = BTreeMap::new();
        let mut renames = BTreeMap::new();
        for delta in diff.deltas() {
            let old_path = delta
                .old_file()
                .path()
                .and_then(|path| path.to_str())
                .map(str::to_string);
            let new_path = delta
                .new_file()
                .path()
                .and_then(|path| path.to_str())
                .map(str::to_string);
            if let Some(path) = old_path.as_deref().filter(|path| self.in_scope(path)) {
                if let Some(mut file) = revision_file_from_tree(repo, base_tree, path)? {
                    let scoped_path = self.scoped_path(path).expect("path was in scope");
                    file.path = scoped_path.clone();
                    base.insert(scoped_path, file);
                }
            }
            if let Some(path) = new_path.as_deref().filter(|path| self.in_scope(path)) {
                let file = if let Some(tree) = head_tree {
                    revision_file_from_tree(repo, tree, path)?
                } else {
                    self.working_tree_file(path)?
                };
                if let Some(mut file) = file {
                    let scoped_path = self.scoped_path(path).expect("path was in scope");
                    file.path = scoped_path.clone();
                    head.insert(scoped_path, file);
                }
            }
            if delta.status() == git2::Delta::Renamed {
                if let (Some(old_path), Some(new_path)) = (old_path, new_path) {
                    if self.in_scope(&old_path) && self.in_scope(&new_path) {
                        renames.insert(
                            self.scoped_path(&old_path).expect("path was in scope"),
                            self.scoped_path(&new_path).expect("path was in scope"),
                        );
                    }
                }
            }
        }
        Ok((
            base.into_values().collect(),
            head.into_values().collect(),
            renames,
        ))
    }

    fn add_untracked_worktree_files(
        &self,
        repo: &Repository,
        head: &mut Vec<RevisionFile>,
    ) -> Result<()> {
        let mut options = git2::StatusOptions::new();
        options
            .include_untracked(true)
            .recurse_untracked_dirs(true)
            .include_ignored(false);
        let mut paths = head
            .iter()
            .cloned()
            .map(|file| (file.path.clone(), file))
            .collect::<BTreeMap<_, _>>();
        for entry in repo.statuses(Some(&mut options))?.iter() {
            if !entry.status().contains(git2::Status::WT_NEW) {
                continue;
            }
            let Some(path) = entry.path() else { continue };
            if !self.in_scope(path) {
                continue;
            }
            if let Some(file) = self.working_tree_file(path)? {
                paths.insert(file.path.clone(), file);
            }
        }
        *head = paths.into_values().collect();
        Ok(())
    }

    fn working_tree_file(&self, path: &str) -> Result<Option<RevisionFile>> {
        let candidate = self.path.join(path);
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error).with_context(|| format!("stat working-tree file {path}"))
            }
        };
        let contents = if metadata.file_type().is_symlink() {
            fs::read_link(&candidate)
                .ok()
                .and_then(|target| target.into_os_string().into_string().ok())
        } else if metadata.is_file() {
            let root = self.path.canonicalize()?;
            let canonical = candidate
                .canonicalize()
                .with_context(|| format!("resolve working-tree file {path}"))?;
            if !canonical.starts_with(&root) {
                return Ok(None);
            }
            let bytes = fs::read(canonical)?;
            (!bytes.contains(&0))
                .then(|| String::from_utf8(bytes).ok())
                .flatten()
        } else {
            return Ok(None);
        };
        Ok(Some(RevisionFile {
            path: self
                .scoped_path(path)
                .expect("working-tree path was in scope"),
            contents,
        }))
    }
}

fn revision_file_from_tree(
    repo: &Repository,
    tree: &Tree<'_>,
    path: &str,
) -> Result<Option<RevisionFile>> {
    let Ok(entry) = tree.get_path(Path::new(path)) else {
        return Ok(None);
    };
    if entry.kind() != Some(ObjectType::Blob) {
        return Ok(None);
    }
    let blob = repo.find_blob(entry.id())?;
    let contents = (!blob.is_binary())
        .then(|| std::str::from_utf8(blob.content()).ok().map(str::to_string))
        .flatten();
    Ok(Some(RevisionFile {
        path: path.into(),
        contents,
    }))
}

impl VcsProvider for GitProvider {
    fn list_commits(&self) -> Result<Vec<CommitMetadata>> {
        let repo = Repository::open(&self.path)?;
        let mut revwalk = repo.revwalk()?;
        revwalk.push_head()?;
        revwalk.set_sorting(Sort::TOPOLOGICAL | Sort::REVERSE)?;
        revwalk.simplify_first_parent()?;

        let mut commits = Vec::new();
        for oid in revwalk {
            let oid = oid?;
            let commit = repo.find_commit(oid)?;
            commits.push(CommitMetadata {
                hash: oid.to_string(),
                message: commit.message().unwrap_or_default().to_string(),
                timestamp: commit.time().seconds(),
            });
        }
        Ok(commits)
    }

    fn files_at_commit(
        &self,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<Vec<BlobFile>> {
        let repo = Repository::open(&self.path)?;
        let oid = git2::Oid::from_str(commit_hash)?;
        let commit = repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let mut files = Vec::new();
        if let Some(prefix) = self.scope_prefix.as_deref() {
            let entry = tree
                .get_path(Path::new(prefix))
                .with_context(|| format!("find project scope {prefix} at {commit_hash}"))?;
            if entry.kind() != Some(ObjectType::Tree) {
                anyhow::bail!("project scope {prefix} is not a tree at {commit_hash}");
            }
            let scoped_tree = repo.find_tree(entry.id())?;
            collect_tree(
                &repo,
                &scoped_tree,
                PathBuf::new(),
                path_filter,
                &self.blob_cache,
                &mut files,
            )?;
        } else {
            collect_tree(
                &repo,
                &tree,
                PathBuf::new(),
                path_filter,
                &self.blob_cache,
                &mut files,
            )?;
        }
        Ok(files)
    }

    fn changes_at_commit(
        &self,
        previous_commit_hash: Option<&str>,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<CommitChanges> {
        let repo = Repository::open(&self.path)?;
        let current_oid = git2::Oid::from_str(commit_hash)?;
        let current_commit = repo.find_commit(current_oid)?;
        let current_tree = current_commit.tree()?;

        if let Some(prev_hash) = previous_commit_hash {
            let prev_oid = git2::Oid::from_str(prev_hash)?;
            let prev_commit = repo.find_commit(prev_oid)?;
            let prev_tree = prev_commit.tree()?;

            let mut diff_options = git2::DiffOptions::new();
            let mut diff = repo.diff_tree_to_tree(
                Some(&prev_tree),
                Some(&current_tree),
                Some(&mut diff_options),
            )?;
            let mut find_options = git2::DiffFindOptions::new();
            find_options.renames(true);
            find_options.copies(true);
            diff.find_similar(Some(&mut find_options))?;

            let mut added_or_modified = Vec::new();
            let mut deleted = Vec::new();

            for delta in diff.deltas() {
                match delta.status() {
                    git2::Delta::Added
                    | git2::Delta::Modified
                    | git2::Delta::Renamed
                    | git2::Delta::Copied => {
                        if let Some(new_file) = delta.new_file().path() {
                            if let Some(path_str) = new_file.to_str() {
                                let Some(scoped_path) = self.scoped_path(path_str) else {
                                    continue;
                                };
                                if path_filter(&scoped_path) {
                                    let entry_id = delta.new_file().id();
                                    if entry_id.is_zero() {
                                        continue;
                                    }
                                    let cached_contents = {
                                        let cache = self.blob_cache.lock().unwrap();
                                        cache.get(path_str).and_then(|(oid, contents)| {
                                            if *oid == entry_id {
                                                Some(contents.clone())
                                            } else {
                                                None
                                            }
                                        })
                                    };
                                    if let Some(contents) = cached_contents {
                                        added_or_modified.push(BlobFile {
                                            path: scoped_path.clone(),
                                            contents,
                                        });
                                    } else {
                                        if let Ok(blob) = repo.find_blob(entry_id) {
                                            if !blob.is_binary() {
                                                if let Ok(contents) =
                                                    std::str::from_utf8(blob.content())
                                                {
                                                    let contents_str = contents.to_string();
                                                    self.blob_cache.lock().unwrap().insert(
                                                        path_str.to_string(),
                                                        (entry_id, contents_str.clone()),
                                                    );
                                                    added_or_modified.push(BlobFile {
                                                        path: scoped_path,
                                                        contents: contents_str,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if delta.status() == git2::Delta::Renamed {
                            if let Some(old_file) = delta.old_file().path() {
                                if let Some(path_str) = old_file.to_str() {
                                    if let Some(scoped_path) = self.scoped_path(path_str) {
                                        if path_filter(&scoped_path) {
                                            deleted.push(scoped_path);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    git2::Delta::Deleted => {
                        if let Some(old_file) = delta.old_file().path() {
                            if let Some(path_str) = old_file.to_str() {
                                if let Some(scoped_path) = self.scoped_path(path_str) {
                                    if path_filter(&scoped_path) {
                                        deleted.push(scoped_path);
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }

            Ok(CommitChanges {
                added_or_modified,
                deleted,
            })
        } else {
            let files = self.files_at_commit(commit_hash, path_filter)?;
            Ok(CommitChanges {
                added_or_modified: files,
                deleted: Vec::new(),
            })
        }
    }
}

fn collect_tree(
    repo: &Repository,
    tree: &Tree<'_>,
    prefix: PathBuf,
    path_filter: &dyn Fn(&str) -> bool,
    blob_cache: &std::sync::Mutex<HashMap<String, (git2::Oid, String)>>,
    files: &mut Vec<BlobFile>,
) -> Result<()> {
    for entry in tree.iter() {
        let name = entry.name().unwrap_or_default();
        let path = prefix.join(name);
        match entry.kind() {
            Some(ObjectType::Blob) => {
                let path_string = path.to_string_lossy().replace('\\', "/");
                if !path_filter(&path_string) {
                    continue;
                }
                let entry_id = entry.id();
                let cached_contents = {
                    let cache = blob_cache.lock().unwrap();
                    cache.get(&path_string).and_then(|(oid, contents)| {
                        if *oid == entry_id {
                            Some(contents.clone())
                        } else {
                            None
                        }
                    })
                };
                if let Some(contents) = cached_contents {
                    files.push(BlobFile {
                        path: path_string,
                        contents,
                    });
                } else {
                    let blob = repo.find_blob(entry_id)?;
                    if blob.is_binary() {
                        continue;
                    }
                    if let Ok(contents) = std::str::from_utf8(blob.content()) {
                        let contents_str = contents.to_string();
                        blob_cache
                            .lock()
                            .unwrap()
                            .insert(path_string.clone(), (entry_id, contents_str.clone()));
                        files.push(BlobFile {
                            path: path_string,
                            contents: contents_str,
                        });
                    }
                }
            }
            Some(ObjectType::Tree) => {
                let subtree = repo.find_tree(entry.id())?;
                collect_tree(repo, &subtree, path, path_filter, blob_cache, files)?;
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::Storage;
    use std::fs;
    use tempfile::tempdir;

    fn create_commit(repo: &Repository, message: &str, files: &[(&str, &str)]) -> Result<String> {
        let mut index = repo.index()?;
        let workdir = repo
            .workdir()
            .ok_or_else(|| anyhow::anyhow!("no workdir"))?;
        for (path, content) in files {
            let file_path = workdir.join(path);
            if let Some(parent_dir) = file_path.parent() {
                fs::create_dir_all(parent_dir)?;
            }
            fs::write(&file_path, content)?;
            index.add_path(Path::new(path))?;
        }
        index.write()?;
        let tree_oid = index.write_tree()?;
        let tree = repo.find_tree(tree_oid)?;

        let signature = git2::Signature::now("Test User", "test@example.com")?;

        let parent = match repo.head() {
            Ok(head_ref) => {
                let target = head_ref.target().unwrap();
                Some(repo.find_commit(target)?)
            }
            Err(_) => None,
        };

        let mut parents = Vec::new();
        if let Some(ref p) = parent {
            parents.push(p);
        }

        let oid = repo.commit(
            Some("HEAD"),
            &signature,
            &signature,
            message,
            &tree,
            &parents,
        )?;
        Ok(oid.to_string())
    }

    #[test]
    fn test_git_provider_flow() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;

        // 1. Initial commit
        let c1 = create_commit(
            &repo,
            "initial commit",
            &[("src/main.rs", "fn main() {\n    println!(\"hello\");\n}\n")],
        )?;

        // 2. Add second file, modify first
        let c2 = create_commit(
            &repo,
            "add helper",
            &[
                (
                    "src/main.rs",
                    "fn main() {\n    println!(\"hello world\");\n}\n",
                ),
                ("src/helper.rs", "fn help() {}\n"),
            ],
        )?;

        // 3. Rename/move helper, add binary file
        let workdir = repo.workdir().unwrap();
        fs::remove_file(workdir.join("src/helper.rs"))?;
        let mut index = repo.index()?;
        index.remove_path(Path::new("src/helper.rs"))?;
        index.write()?;

        let c3 = create_commit(
            &repo,
            "rename helper and add binary",
            &[
                ("src/utils.rs", "fn help() {}\n"),
                ("bin/binary.dat", "\u{0}\u{1}\u{2}\u{3}"), // binary content
            ],
        )?;

        // 4. Delete utils.rs (without adding anything similar)
        fs::remove_file(workdir.join("src/utils.rs"))?;
        let mut index = repo.index()?;
        index.remove_path(Path::new("src/utils.rs"))?;
        index.write()?;

        let c4 = create_commit(&repo, "delete utils", &[])?;

        // Open provider
        let provider = GitProvider::open(dir.path())?;

        // Test list_commits
        let commits = provider.list_commits()?;
        assert_eq!(commits.len(), 4);
        assert_eq!(commits[0].hash, c1);
        assert_eq!(commits[0].message, "initial commit");
        assert_eq!(commits[1].hash, c2);
        assert_eq!(commits[2].hash, c3);
        assert_eq!(commits[3].hash, c4);

        // Test files_at_commit
        let filter_all = |_path: &str| true;
        let files = provider.files_at_commit(&c1, &filter_all)?;
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "src/main.rs");
        assert_eq!(
            files[0].contents,
            "fn main() {\n    println!(\"hello\");\n}\n"
        );

        let files3 = provider.files_at_commit(&c3, &filter_all)?;
        assert_eq!(files3.len(), 2);
        assert!(files3.iter().any(|f| f.path == "src/main.rs"));
        assert!(files3.iter().any(|f| f.path == "src/utils.rs"));

        // Test files_at_commit with a filter that filters out some files
        let filter_main = |path: &str| path.contains("main");
        let files3_filtered = provider.files_at_commit(&c3, &filter_main)?;
        assert_eq!(files3_filtered.len(), 1);
        assert_eq!(files3_filtered[0].path, "src/main.rs");

        // Test file_contents_at_commit uncached
        let contents_init = provider.file_contents_at_commit(&c1, "src/main.rs")?;
        assert_eq!(
            contents_init,
            Some("fn main() {\n    println!(\"hello\");\n}\n".to_string())
        );

        // Test file_contents_at_commit cached
        let contents = provider.file_contents_at_commit(&c2, "src/main.rs")?;
        assert_eq!(
            contents,
            Some("fn main() {\n    println!(\"hello world\");\n}\n".to_string())
        );

        // Hit cache
        let contents_cached = provider.file_contents_at_commit(&c2, "src/main.rs")?;
        assert_eq!(
            contents_cached,
            Some("fn main() {\n    println!(\"hello world\");\n}\n".to_string())
        );

        // Non-existent file
        let no_file = provider.file_contents_at_commit(&c2, "src/nonexistent.rs")?;
        assert_eq!(no_file, None);

        // Binary file ignored or returns None
        let binary_file = provider.file_contents_at_commit(&c3, "bin/binary.dat")?;
        assert_eq!(binary_file, None);

        // Test changes_at_commit with no previous commit
        let changes_c1 = provider.changes_at_commit(None, &c1, &filter_all)?;
        assert_eq!(changes_c1.added_or_modified.len(), 1);
        assert_eq!(changes_c1.added_or_modified[0].path, "src/main.rs");
        assert!(changes_c1.deleted.is_empty());

        // Test changes_at_commit with previous commit
        let changes_c2 = provider.changes_at_commit(Some(&c1), &c2, &filter_all)?;
        assert_eq!(changes_c2.added_or_modified.len(), 2);
        assert!(changes_c2
            .added_or_modified
            .iter()
            .any(|f| f.path == "src/main.rs"));
        assert!(changes_c2
            .added_or_modified
            .iter()
            .any(|f| f.path == "src/helper.rs"));
        assert!(changes_c2.deleted.is_empty());

        // Test changes_at_commit for c3 (rename helper to utils, add binary)
        let changes_c3 = provider.changes_at_commit(Some(&c2), &c3, &filter_all)?;
        assert_eq!(changes_c3.deleted, vec!["src/helper.rs".to_string()]);
        assert_eq!(changes_c3.added_or_modified.len(), 1);
        assert_eq!(changes_c3.added_or_modified[0].path, "src/utils.rs");

        // Test changes_at_commit for c4 (delete utils.rs)
        let changes_c4 = provider.changes_at_commit(Some(&c3), &c4, &filter_all)?;
        assert_eq!(changes_c4.deleted, vec!["src/utils.rs".to_string()]);
        assert!(changes_c4.added_or_modified.is_empty());

        Ok(())
    }

    #[test]
    fn default_diff_pair_uses_head_against_the_working_tree() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(&repo, "base", &[("app.rb", "puts :base\n")])?;
        let head = create_commit(&repo, "head", &[("app.rb", "puts :head\n")])?;
        let provider = GitProvider::open(dir.path())?;

        assert_eq!(
            provider.diff_revisions(None, None)?,
            (head.clone(), WORKTREE_REVISION.into())
        );
        assert_eq!(
            provider.diff_revisions(Some(&base), Some("HEAD"))?,
            (base, head)
        );
        Ok(())
    }

    #[test]
    fn working_tree_diff_includes_staged_unstaged_untracked_and_deleted_files() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let head = create_commit(
            &repo,
            "base",
            &[
                ("changed.rs", "fn value() { 1; }\n"),
                ("deleted.rs", "fn deleted() {}\n"),
                ("staged.rs", "fn staged() { 1; }\n"),
            ],
        )?;
        fs::write(dir.path().join("changed.rs"), "fn value() { 2; }\n")?;
        fs::remove_file(dir.path().join("deleted.rs"))?;
        fs::write(dir.path().join("untracked.rs"), "fn new_file() {}\n")?;
        fs::write(dir.path().join("staged.rs"), "fn staged() { 2; }\n")?;
        let mut index = repo.index()?;
        index.add_path(Path::new("staged.rs"))?;
        index.write()?;

        let provider = GitProvider::open(dir.path())?;
        let (base, worktree) = provider.diff_revisions(None, None)?;
        assert_eq!(base, head);
        assert_eq!(worktree, WORKTREE_REVISION);
        let plan = provider.diff_plan(&base, &worktree)?;
        let paths = plan
            .files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>();
        assert!(paths.contains(&"changed.rs"));
        assert!(paths.contains(&"deleted.rs"));
        assert!(paths.contains(&"staged.rs"));
        assert!(paths.contains(&"untracked.rs"));
        assert_eq!(
            plan.files
                .iter()
                .find(|file| file.path == "deleted.rs")
                .unwrap()
                .change,
            crate::diff::FileChangeKind::Deleted
        );
        Ok(())
    }

    #[test]
    fn worktree_revision_reads_current_source_without_treating_it_as_a_commit() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        create_commit(&repo, "base", &[("app.rs", "fn value() { 1; }\n")])?;
        fs::write(dir.path().join("app.rs"), "fn value() { 2; }\n")?;
        let provider = GitProvider::open(dir.path())?;
        assert_eq!(
            provider.file_contents_at_commit(WORKTREE_REVISION, "app.rs")?,
            Some("fn value() { 2; }\n".into())
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn clean_worktree_symlinks_are_not_reported_as_deleted() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        fs::write(dir.path().join("target.txt"), "target\n")?;
        std::os::unix::fs::symlink("target.txt", dir.path().join("linked.txt"))?;
        let mut index = repo.index()?;
        index.add_path(Path::new("target.txt"))?;
        index.add_path(Path::new("linked.txt"))?;
        index.write()?;
        let tree = repo.find_tree(index.write_tree()?)?;
        let signature = git2::Signature::now("Test User", "test@example.com")?;
        let commit = repo.commit(Some("HEAD"), &signature, &signature, "symlink", &tree, &[])?;

        let plan =
            GitProvider::open(dir.path())?.diff_plan(&commit.to_string(), WORKTREE_REVISION)?;
        assert!(plan.files.is_empty());
        Ok(())
    }

    #[test]
    fn diff_plan_loads_only_changed_paths_in_a_large_repository() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let workdir = repo.workdir().context("test repository has no worktree")?;
        let mut index = repo.index()?;
        for number in 0..2_000 {
            let path = format!("src/file-{number}.rs");
            let file = workdir.join(&path);
            fs::create_dir_all(file.parent().unwrap())?;
            fs::write(
                &file,
                format!("fn value_{number}() -> u32 {{ {number} }}\n"),
            )?;
            index.add_path(Path::new(&path))?;
        }
        index.write()?;
        let tree = repo.find_tree(index.write_tree()?)?;
        let signature = git2::Signature::now("Test User", "test@example.com")?;
        let base = repo.commit(Some("HEAD"), &signature, &signature, "base", &tree, &[])?;

        fs::write(
            workdir.join("src/file-777.rs"),
            "fn value_777() -> u32 { 778 }\n",
        )?;
        let mut index = repo.index()?;
        index.add_path(Path::new("src/file-777.rs"))?;
        index.write()?;
        let tree = repo.find_tree(index.write_tree()?)?;
        let parent = repo.find_commit(base)?;
        let head = repo.commit(
            Some("HEAD"),
            &signature,
            &signature,
            "change",
            &tree,
            &[&parent],
        )?;

        let plan =
            GitProvider::open(dir.path())?.diff_plan(&base.to_string(), &head.to_string())?;
        assert_eq!(plan.files.len(), 1);
        assert_eq!(plan.files[0].path, "src/file-777.rs");
        Ok(())
    }

    #[test]
    fn repository_root_and_subdirectory_providers_have_consistent_path_identity() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(
            &repo,
            "base",
            &[
                ("gems/demo/lib/value.rb", "def value\n  1\nend\n"),
                ("other/lib/value.rb", "def value\n  1\nend\n"),
            ],
        )?;
        let head = create_commit(
            &repo,
            "change demo only",
            &[
                ("gems/demo/lib/value.rb", "def value\n  2\nend\n"),
                ("other/lib/value.rb", "def value\n  3\nend\n"),
            ],
        )?;

        let root_provider = GitProvider::open(dir.path())?;
        let root_plan = root_provider.diff_plan(&base, &head)?;
        assert_eq!(root_plan.files.len(), 2);
        assert!(root_plan
            .files
            .iter()
            .any(|file| file.path == "gems/demo/lib/value.rb"));

        let provider = GitProvider::open(dir.path().join("gems/demo"))?;
        let plan = provider.diff_plan(&base, &head)?;
        assert_eq!(plan.files.len(), 1);
        assert_eq!(plan.files[0].path, "lib/value.rb");

        let all = |_path: &str| true;
        let files = provider.files_at_commit(&head, &all)?;
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "lib/value.rb");
        assert_eq!(
            provider.file_contents_at_commit(&head, "lib/value.rb")?,
            Some("def value\n  2\nend\n".to_string())
        );

        let changes = provider.changes_at_commit(Some(&base), &head, &all)?;
        assert_eq!(changes.added_or_modified.len(), 1);
        assert_eq!(changes.added_or_modified[0].path, "lib/value.rb");
        Ok(())
    }

    #[test]
    fn commit_count_spans_the_range() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(&repo, "base", &[("a.txt", "1\n")])?;
        create_commit(&repo, "second", &[("a.txt", "2\n")])?;
        let head = create_commit(&repo, "third", &[("a.txt", "3\n")])?;
        let provider = GitProvider::open(dir.path())?;
        assert_eq!(provider.commit_count(&base, &head)?, 2);
        assert_eq!(provider.commit_count(&base, &base)?, 0);
        Ok(())
    }

    #[test]
    fn diff_plan_preserves_git_detected_renames_with_edits() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(
            &repo,
            "base",
            &[(
                "src/old.rs",
                "pub fn value() -> i32 {\n    let base = 1;\n    base + 1\n}\n",
            )],
        )?;
        let workdir = repo.workdir().unwrap();
        fs::create_dir_all(workdir.join("src"))?;
        fs::rename(workdir.join("src/old.rs"), workdir.join("src/new.rs"))?;
        let mut index = repo.index()?;
        index.remove_path(Path::new("src/old.rs"))?;
        index.write()?;
        let head = create_commit(
            &repo,
            "rename and edit",
            &[(
                "src/new.rs",
                "pub fn value() -> i32 {\n    let base = 2;\n    base + 1\n}\n",
            )],
        )?;
        let plan = GitProvider::open(dir.path())?.diff_plan(&base, &head)?;
        let file = plan
            .files
            .iter()
            .find(|file| file.path == "src/new.rs")
            .unwrap();
        assert_eq!(file.change, crate::diff::FileChangeKind::Renamed);
        assert_eq!(file.previous_path.as_deref(), Some("src/old.rs"));
        assert_eq!(
            file.base_source.as_deref(),
            Some("pub fn value() -> i32 {\n    let base = 1;\n    base + 1\n}\n")
        );
        assert_eq!(
            file.head_source.as_deref(),
            Some("pub fn value() -> i32 {\n    let base = 2;\n    base + 1\n}\n")
        );
        assert_eq!(plan.inventory.renamed_files, 1);
        assert_eq!(plan.inventory.deleted_files, 0);
        Ok(())
    }

    #[test]
    fn diff_plan_uses_head_revision_classification_overrides() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(
            &repo,
            "base",
            &[("spec/value_spec.rb", "describe :value do\nend\n")],
        )?;
        let head = create_commit(
            &repo,
            "override source role",
            &[
                ("spec/value_spec.rb", "describe :value do\n  value\nend\n"),
                (
                    ".giga/diff.toml",
                    "[[overrides]]\nprefix = \"spec/\"\nrole = \"production\"\n",
                ),
            ],
        )?;
        let plan = GitProvider::open(dir.path())?.diff_plan(&base, &head)?;
        let file = plan
            .files
            .iter()
            .find(|file| file.path == "spec/value_spec.rb")
            .unwrap();
        assert_eq!(file.role, crate::diff::SourceRole::Production);
        Ok(())
    }

    #[test]
    fn subdirectory_diff_uses_its_own_classification_overrides() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(
            &repo,
            "base",
            &[("crate/spec/value_spec.rb", "describe :value do\nend\n")],
        )?;
        let head = create_commit(
            &repo,
            "scoped override",
            &[
                (
                    "crate/spec/value_spec.rb",
                    "describe :value do\n  value\nend\n",
                ),
                (
                    "crate/.giga/diff.toml",
                    "[[overrides]]\nprefix = \"spec/\"\nrole = \"production\"\n",
                ),
            ],
        )?;
        let plan = GitProvider::open(dir.path().join("crate"))?.diff_plan(&base, &head)?;
        let file = plan
            .files
            .iter()
            .find(|file| file.path == "spec/value_spec.rb")
            .unwrap();
        assert_eq!(file.role, crate::diff::SourceRole::Production);
        Ok(())
    }

    #[test]
    fn test_gigasail_engine_with_git_provider() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;

        // Commit 1: Initial unit
        let _c1 = create_commit(
            &repo,
            "add main fn",
            &[(
                "src/main.rs",
                "fn main() {\n    foo().bar().baz().map(|x| x.to_string());\n}\n",
            )],
        )?;

        // Commit 2: Move/rename main fn to helper fn in another file
        let workdir = repo.workdir().unwrap();
        fs::remove_file(workdir.join("src/main.rs"))?;
        let mut index = repo.index()?;
        index.remove_path(Path::new("src/main.rs"))?;
        index.write()?;

        let _c2 = create_commit(
            &repo,
            "move main fn to helper",
            &[(
                "src/helper.rs",
                "fn main() {\n    foo().bar().baz().map(|x| x.to_string());\n}\n",
            )],
        )?;

        let provider = GitProvider::open(dir.path())?;
        let storage = Storage::open_memory()?;
        let mut engine =
            crate::LineageEngine::new(provider, crate::HeuristicExtractor::default(), storage);
        let stats = engine.run(None)?;

        assert_eq!(stats.commits, 2);
        assert_eq!(stats.events, 1);
        assert_eq!(stats.moves, 1);
        assert_eq!(stats.fixes, 0);
        assert_eq!(stats.changes, 0);

        Ok(())
    }
}
