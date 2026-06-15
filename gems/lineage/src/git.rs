use crate::model::{BlobFile, CommitMetadata};
use crate::vcs::VcsProvider;
use anyhow::{Context, Result};
use git2::{ObjectType, Repository, Sort, Tree};
use std::path::{Path, PathBuf};

pub struct GitProvider {
    repo: Repository,
}

impl GitProvider {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let repo = Repository::open(path.as_ref())
            .with_context(|| format!("open git repository {}", path.as_ref().display()))?;
        Ok(Self { repo })
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
        collect_tree(&self.repo, &tree, PathBuf::new(), path_filter, &mut files)?;
        Ok(files)
    }
}

fn collect_tree(
    repo: &Repository,
    tree: &Tree<'_>,
    prefix: PathBuf,
    path_filter: &dyn Fn(&str) -> bool,
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
                let blob = repo.find_blob(entry.id())?;
                if blob.is_binary() {
                    continue;
                }
                if let Ok(contents) = std::str::from_utf8(blob.content()) {
                    files.push(BlobFile {
                        path: path_string,
                        contents: contents.to_string(),
                    });
                }
            }
            Some(ObjectType::Tree) => {
                let subtree = repo.find_tree(entry.id())?;
                collect_tree(repo, &subtree, path, path_filter, files)?;
            }
            _ => {}
        }
    }
    Ok(())
}
