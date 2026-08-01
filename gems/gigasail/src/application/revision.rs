use crate::{GitProvider, HeuristicExtractor, LineageEngine, Storage};
use anyhow::{Context, Result};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

pub fn repository_path(repo: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        repo.join(path)
    }
}

/// Command producers may consume sibling projects, lockfiles, or workspace
/// tooling outside a selected monorepo subdirectory. Until they execute in an
/// isolated worktree, their provenance is sound only when the entire Git
/// worktree is clean. Embedded Gigasail providers can retain narrower checks.
pub fn ensure_profile_clean_worktree(
    repo: &Path,
    config: &crate::LineageConfig,
    profile_name: &str,
    database: Option<&Path>,
) -> Result<()> {
    let profile = config
        .profiles
        .get(profile_name)
        .with_context(|| format!("unknown Gigasail profile {profile_name:?}"))?;
    let requires_full_worktree = profile.producers.iter().any(|name| {
        config
            .producers
            .get(name)
            .is_some_and(|producer| producer.executor == crate::pipeline::ProducerExecutor::Command)
    });
    ensure_clean_worktree_with_scope(
        repo,
        &config.artifacts.directory,
        database,
        requires_full_worktree,
    )
}

/// Checks only the selected subproject. This is appropriate for embedded
/// analyzers that never read sibling source trees.
pub fn ensure_clean_worktree(
    repo: &Path,
    artifact_directory: &Path,
    database: Option<&Path>,
) -> Result<()> {
    ensure_clean_worktree_with_scope(repo, artifact_directory, database, false)
}

fn ensure_clean_worktree_with_scope(
    repo: &Path,
    artifact_directory: &Path,
    database: Option<&Path>,
    require_full_worktree: bool,
) -> Result<()> {
    let repository_root = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(repo)
        .output()
        .context("resolve Git repository root for gigasail ci")?;
    if !repository_root.status.success() {
        anyhow::bail!("could not resolve Git repository root for gigasail ci");
    }
    let repository_root = PathBuf::from(String::from_utf8(repository_root.stdout)?.trim());
    let repository_prefix = repo
        .canonicalize()
        .context("canonicalize Gigasail repository path")?
        .strip_prefix(&repository_root)
        .context("Gigasail repository is outside its Git worktree")?
        .to_path_buf();
    let output = Command::new("git")
        .args(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        .current_dir(repo)
        .output()
        .context("inspect Git worktree before gigasail ci")?;
    if !output.status.success() {
        anyhow::bail!("could not inspect Git worktree before gigasail ci");
    }
    let artifact_prefix = repository_prefix
        .join(artifact_directory)
        .to_string_lossy()
        .replace('\\', "/");
    let database_path = database
        .and_then(|path| path.strip_prefix(repo).ok())
        .map(|path| repository_prefix.join(path))
        .map(|path| path.to_string_lossy().replace('\\', "/"));
    let database_sidecars = database_path.as_ref().map(|database| {
        ["-wal", "-shm", "-journal"]
            .into_iter()
            .map(|suffix| format!("{database}{suffix}"))
            .collect::<Vec<_>>()
    });
    // The whole `.giga/` state directory (database, artifacts, coordination
    // lock, and any future run state) is Gigasail's own workspace and must
    // never count as worktree dirtiness. Derive it from the database's parent
    // so a custom `--db` location is honored; skip it when the database sits at
    // the repository root (an empty relative parent would mask everything).
    let state_dir_prefix = database
        .and_then(|path| path.strip_prefix(repo).ok())
        .and_then(|relative| relative.parent())
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(|parent| {
            repository_prefix
                .join(parent)
                .to_string_lossy()
                .replace('\\', "/")
        });
    let dirty = porcelain_v1_dirty_paths(&output.stdout)?
        .into_iter()
        .find(|path| {
            let prefix = repository_prefix.to_string_lossy().replace('\\', "/");
            let inside_selected_repo = repository_prefix.as_os_str().is_empty()
                || path == &prefix
                || path.starts_with(&format!("{prefix}/"));
            let in_state_dir = state_dir_prefix
                .as_deref()
                .is_some_and(|dir| path == dir || path.starts_with(&format!("{dir}/")));
            (require_full_worktree || inside_selected_repo)
                && !in_state_dir
                && path != &artifact_prefix
                && !path.starts_with(&format!("{artifact_prefix}/"))
                && database_path.as_deref() != Some(path)
                && !database_sidecars
                    .as_deref()
                    .is_some_and(|sidecars| sidecars.iter().any(|sidecar| sidecar == path))
        });
    if let Some(path) = dirty {
        anyhow::bail!("gigasail ci requires a clean worktree (found {path})");
    }
    Ok(())
}

/// Parses `git status --porcelain=v1 -z` without Git display quoting.
pub fn porcelain_v1_dirty_paths(output: &[u8]) -> Result<Vec<String>> {
    let mut records = output
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty());
    let mut paths = Vec::new();
    while let Some(record) = records.next() {
        if record.len() < 4 || record[2] != b' ' {
            anyhow::bail!("invalid NUL-delimited git porcelain record");
        }
        let normalize = |path: &[u8]| {
            String::from_utf8_lossy(path)
                .trim_start_matches("./")
                .replace('\\', "/")
        };
        paths.push(normalize(&record[3..]));
        if matches!(record[0], b'R' | b'C') || matches!(record[1], b'R' | b'C') {
            let source = records
                .next()
                .context("truncated NUL-delimited git rename/copy record")?;
            paths.push(normalize(source));
        }
    }
    Ok(paths)
}

/// Ensures the selected immutable revision and its gigasail predecessors have
/// been indexed before evidence is associated with that revision.
pub fn ensure_revision_snapshot(db: &Path, repo: &Path, revision: &str) -> Result<()> {
    if let Some(parent) = db.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .with_context(|| format!("create Gigasail database directory {}", parent.display()))?;
    }
    if Storage::open(db)?.commit_exists(revision)? {
        return Ok(());
    }
    let provider = GitProvider::open(repo)?;
    let storage = Storage::open(db)?;
    LineageEngine::new(provider, HeuristicExtractor::default(), storage)
        .run_through_revision(revision)?;
    if !Storage::open(db)?.commit_exists(revision)? {
        anyhow::bail!("could not index selected revision {revision}");
    }
    Storage::open(db)?.refresh_ui_summaries()?;
    Ok(())
}
