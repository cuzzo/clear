use crate::model::{BlobFile, CommitMetadata};
use crate::vcs::{CommitChanges, VcsProvider};
use anyhow::{Context, Result};
use git2::{ObjectType, Repository, Sort, Tree};
use std::path::{Path, PathBuf};

use std::cell::RefCell;
use std::collections::HashMap;

pub struct GitProvider {
    repo: Repository,
    blob_cache: RefCell<HashMap<String, (git2::Oid, String)>>,
}

impl GitProvider {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let repo = Repository::open(path.as_ref())
            .with_context(|| format!("open git repository {}", path.as_ref().display()))?;
        Ok(Self {
            repo,
            blob_cache: RefCell::new(HashMap::new()),
        })
    }

    pub fn file_contents_at_commit(&self, commit_hash: &str, path: &str) -> Result<Option<String>> {
        let oid = git2::Oid::from_str(commit_hash)?;
        let commit = self.repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let path_obj = Path::new(path);
        if let Ok(entry) = tree.get_path(path_obj) {
            let entry_id = entry.id();
            let cached_contents = {
                let cache = self.blob_cache.borrow();
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
            if let Ok(blob) = self.repo.find_blob(entry_id) {
                if !blob.is_binary() {
                    if let Ok(contents) = std::str::from_utf8(blob.content()) {
                        let contents_str = contents.to_string();
                        self.blob_cache.borrow_mut().insert(
                            path.to_string(),
                            (entry_id, contents_str.clone()),
                        );
                        return Ok(Some(contents_str));
                    }
                }
            }
        }
        Ok(None)
    }
}

impl VcsProvider for GitProvider {
    fn list_commits(&self) -> Result<Vec<CommitMetadata>> {
        let mut revwalk = self.repo.revwalk()?;
        revwalk.push_head()?;
        revwalk.set_sorting(Sort::TOPOLOGICAL | Sort::REVERSE)?;
        revwalk.simplify_first_parent()?;

        let mut commits = Vec::new();
        for oid in revwalk {
            let oid = oid?;
            let commit = self.repo.find_commit(oid)?;
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
        let oid = git2::Oid::from_str(commit_hash)?;
        let commit = self.repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let mut files = Vec::new();
        collect_tree(&self.repo, &tree, PathBuf::new(), path_filter, &self.blob_cache, &mut files)?;
        Ok(files)
    }

    fn changes_at_commit(
        &self,
        previous_commit_hash: Option<&str>,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<CommitChanges> {
        let current_oid = git2::Oid::from_str(commit_hash)?;
        let current_commit = self.repo.find_commit(current_oid)?;
        let current_tree = current_commit.tree()?;

        if let Some(prev_hash) = previous_commit_hash {
            let prev_oid = git2::Oid::from_str(prev_hash)?;
            let prev_commit = self.repo.find_commit(prev_oid)?;
            let prev_tree = prev_commit.tree()?;

            let mut diff_options = git2::DiffOptions::new();
            let diff = self.repo.diff_tree_to_tree(
                Some(&prev_tree),
                Some(&current_tree),
                Some(&mut diff_options),
            )?;

            let mut added_or_modified = Vec::new();
            let mut deleted = Vec::new();

            for delta in diff.deltas() {
                match delta.status() {
                    git2::Delta::Added | git2::Delta::Modified | git2::Delta::Renamed | git2::Delta::Copied => {
                        if let Some(new_file) = delta.new_file().path() {
                            if let Some(path_str) = new_file.to_str() {
                                if path_filter(path_str) {
                                    let entry_id = delta.new_file().id();
                                    if entry_id.is_zero() {
                                        continue;
                                    }
                                    let cached_contents = {
                                        let cache = self.blob_cache.borrow();
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
                                        if let Ok(blob) = self.repo.find_blob(entry_id) {
                                            if !blob.is_binary() {
                                                if let Ok(contents) = std::str::from_utf8(blob.content()) {
                                                    let contents_str = contents.to_string();
                                                    self.blob_cache.borrow_mut().insert(
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
    blob_cache: &RefCell<HashMap<String, (git2::Oid, String)>>,
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
                    let cache = blob_cache.borrow();
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
                        blob_cache.borrow_mut().insert(path_string.clone(), (entry_id, contents_str.clone()));
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
