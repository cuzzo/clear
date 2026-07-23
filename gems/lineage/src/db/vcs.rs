use crate::model::{BlobFile, CommitMetadata};
use anyhow::Result;

pub struct CommitChanges {
    pub added_or_modified: Vec<BlobFile>,
    pub deleted: Vec<String>,
}

pub trait VcsProvider {
    fn list_commits(&self) -> Result<Vec<CommitMetadata>>;
    fn files_at_commit(
        &self,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<Vec<BlobFile>>;

    fn changes_at_commit(
        &self,
        previous_commit_hash: Option<&str>,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<CommitChanges> {
        let current_files = self.files_at_commit(commit_hash, path_filter)?;
        if let Some(prev_hash) = previous_commit_hash {
            let prev_files = self.files_at_commit(prev_hash, path_filter)?;
            let prev_map: std::collections::HashMap<String, String> = prev_files
                .into_iter()
                .map(|f| (f.path, f.contents))
                .collect();

            let mut added_or_modified = Vec::new();
            let mut current_paths = std::collections::HashSet::new();

            for file in current_files {
                current_paths.insert(file.path.clone());
                if let Some(prev_content) = prev_map.get(&file.path) {
                    if *prev_content != file.contents {
                        added_or_modified.push(file);
                    }
                } else {
                    added_or_modified.push(file);
                }
            }

            let mut deleted = Vec::new();
            for path in prev_map.keys() {
                if !current_paths.contains(path) {
                    deleted.push(path.clone());
                }
            }

            Ok(CommitChanges {
                added_or_modified,
                deleted,
            })
        } else {
            Ok(CommitChanges {
                added_or_modified: current_files,
                deleted: Vec::new(),
            })
        }
    }
}
