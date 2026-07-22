use crate::diff::{build_diff_plan, DiffPlan, RevisionFile};
use crate::model::{BlobFile, CommitMetadata};
use crate::vcs::{CommitChanges, VcsProvider};
use anyhow::{Context, Result};
use git2::{ObjectType, Repository, Sort, Tree};
use std::path::{Path, PathBuf};

use std::collections::HashMap;

pub struct GitProvider {
    path: PathBuf,
    blob_cache: std::sync::Mutex<HashMap<String, (git2::Oid, String)>>,
}

impl GitProvider {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let path_buf = path.as_ref().to_path_buf();
        let _repo = Repository::open(&path_buf)
            .with_context(|| format!("open git repository {}", path_buf.display()))?;
        Ok(Self {
            path: path_buf,
            blob_cache: std::sync::Mutex::new(HashMap::new()),
        })
    }

    pub fn file_contents_at_commit(&self, commit_hash: &str, path: &str) -> Result<Option<String>> {
        let repo = Repository::open(&self.path)?;
        let oid = git2::Oid::from_str(commit_hash)?;
        let commit = repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let path_obj = Path::new(path);
        if let Ok(entry) = tree.get_path(path_obj) {
            let entry_id = entry.id();
            let cached_contents = {
                let cache = self.blob_cache.lock().unwrap();
                cache.get(path).and_then(|(oid, contents)| {
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
                            .insert(path.to_string(), (entry_id, contents_str.clone()));
                        return Ok(Some(contents_str));
                    }
                }
            }
        }
        Ok(None)
    }

    /// Resolves a revision expression to the immutable commit object ID used by
    /// every diff API response.
    pub fn resolve_commit(&self, revision: &str) -> Result<String> {
        let repo = Repository::open(&self.path)?;
        let object = repo.revparse_single(revision)?;
        let commit = object.peel_to_commit()?;
        Ok(commit.id().to_string())
    }

    pub fn diff_plan(&self, base_revision: &str, head_revision: &str) -> Result<DiffPlan> {
        let base_oid = self.resolve_commit(base_revision)?;
        let head_oid = self.resolve_commit(head_revision)?;
        let base = self.revision_snapshot(&base_oid)?;
        let head = self.revision_snapshot(&head_oid)?;
        Ok(build_diff_plan(base_oid, head_oid, base, head))
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

    fn revision_snapshot(&self, commit_hash: &str) -> Result<Vec<RevisionFile>> {
        let repo = Repository::open(&self.path)?;
        let commit = repo.find_commit(git2::Oid::from_str(commit_hash)?)?;
        let mut files = Vec::new();
        collect_revision_tree(&repo, &commit.tree()?, PathBuf::new(), &mut files)?;
        Ok(files)
    }
}

fn collect_revision_tree(
    repo: &Repository,
    tree: &Tree<'_>,
    prefix: PathBuf,
    files: &mut Vec<RevisionFile>,
) -> Result<()> {
    for entry in tree.iter() {
        let path = prefix.join(entry.name().unwrap_or_default());
        match entry.kind() {
            Some(ObjectType::Blob) => {
                let blob = repo.find_blob(entry.id())?;
                let contents = (!blob.is_binary())
                    .then(|| std::str::from_utf8(blob.content()).ok().map(str::to_string))
                    .flatten();
                files.push(RevisionFile {
                    path: path.to_string_lossy().replace('\\', "/"),
                    contents,
                });
            }
            Some(ObjectType::Tree) => {
                let subtree = repo.find_tree(entry.id())?;
                collect_revision_tree(repo, &subtree, path, files)?;
            }
            _ => {}
        }
    }
    Ok(())
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
        collect_tree(
            &repo,
            &tree,
            PathBuf::new(),
            path_filter,
            &self.blob_cache,
            &mut files,
        )?;
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
                                if path_filter(path_str) {
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
                                            path: path_str.to_string(),
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
                                                        path: path_str.to_string(),
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
                                    if path_filter(path_str) {
                                        deleted.push(path_str.to_string());
                                    }
                                }
                            }
                        }
                    }
                    git2::Delta::Deleted => {
                        if let Some(old_file) = delta.old_file().path() {
                            if let Some(path_str) = old_file.to_str() {
                                if path_filter(path_str) {
                                    deleted.push(path_str.to_string());
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
    fn default_diff_pair_uses_resolved_head_and_first_parent_merge_base() -> Result<()> {
        let dir = tempdir()?;
        let repo = Repository::init(dir.path())?;
        let base = create_commit(&repo, "base", &[("app.rb", "puts :base\n")])?;
        let head = create_commit(&repo, "head", &[("app.rb", "puts :head\n")])?;
        let provider = GitProvider::open(dir.path())?;

        assert_eq!(
            provider.diff_revisions(None, None)?,
            (base.clone(), head.clone())
        );
        assert_eq!(
            provider.diff_revisions(Some(&base), Some("HEAD"))?,
            (base, head)
        );
        Ok(())
    }

    #[test]
    fn test_lineage_engine_with_git_provider() -> Result<()> {
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
