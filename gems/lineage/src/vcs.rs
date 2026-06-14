use crate::model::{BlobFile, CommitMetadata};
use anyhow::Result;

pub trait VcsProvider {
    fn list_commits(&self) -> Result<Vec<CommitMetadata>>;
    fn files_at_commit(
        &self,
        commit_hash: &str,
        path_filter: &dyn Fn(&str) -> bool,
    ) -> Result<Vec<BlobFile>>;
}
