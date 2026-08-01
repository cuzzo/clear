//! `giga watch` — continuously analyse and sync each new commit.
//!
//! The watcher polls `HEAD`; when it advances to a commit it has not processed,
//! it takes the `.giga/` coordination lock, runs the analysis profile, and
//! ingests the run into the database ("ci then sync"). The lock keeps a
//! concurrent `giga watch` or MCP server from indexing the same database at the
//! same time, and lets readers (`giga diff`, MCP) see which commit is in flight.

use crate::application::analyse::{execute as execute_analysis, AnalyseRequest};
use crate::git::GitProvider;
use anyhow::{Context, Result};
use giga_core::lock::GigaLock;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct WatchRequest {
    pub repo: PathBuf,
    pub db: PathBuf,
    pub profile: String,
    pub trust_current_config: bool,
    pub interval: Duration,
    /// Process the current HEAD once and return, instead of looping (scripting
    /// and tests).
    pub once: bool,
}

/// The `.giga/` directory that holds the database, artifacts, and lock.
pub fn giga_dir(db: &Path) -> PathBuf {
    db.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn head_commit(repo: &Path) -> Result<String> {
    GitProvider::open(repo)?.resolve_commit("HEAD")
}

fn short(commit: &str) -> &str {
    &commit[..commit.len().min(12)]
}

/// Outcome of attempting to bring one commit up to date.
#[derive(Debug, PartialEq, Eq)]
pub enum Tick {
    /// The commit was analysed and ingested.
    Synced,
    /// Another process holds the lock; the commit was left for a later tick.
    Busy,
}

/// Analyse and ingest `commit` while holding the `.giga/` lock. Returns
/// [`Tick::Busy`] without doing work if a live peer already holds the lock.
pub fn process_commit(request: &WatchRequest, commit: &str) -> Result<Tick> {
    let dir = giga_dir(&request.db);
    match GigaLock::try_acquire(&dir, commit, "analyse")? {
        Some(_lock) => {
            let result = execute_analysis(AnalyseRequest {
                repo: request.repo.clone(),
                db: request.db.clone(),
                profile: request.profile.clone(),
                ingest: true,
                trust_current_config: request.trust_current_config,
            })?;
            println!(
                "giga watch: synced {} (profile={} artifacts={})",
                short(&result.revision),
                result.profile,
                result.artifact_count
            );
            Ok(Tick::Synced)
            // `_lock` drops here, releasing the .giga/ lock.
        }
        None => {
            if let Some(info) = GigaLock::current(&dir)? {
                println!(
                    "giga watch: {} busy on {} ({}); retrying",
                    request.repo.display(),
                    short(&info.commit),
                    info.operation
                );
            }
            Ok(Tick::Busy)
        }
    }
}

/// Run the watch loop. Blocks until the process is signalled (or returns after a
/// single pass when `request.once` is set).
pub fn run(request: WatchRequest) -> Result<()> {
    println!(
        "giga watch: watching {} every {}s",
        request.repo.display(),
        request.interval.as_secs()
    );
    let mut last_synced: Option<String> = None;
    loop {
        let head = head_commit(&request.repo).context("resolve HEAD")?;
        if last_synced.as_deref() != Some(head.as_str()) {
            match process_commit(&request, &head) {
                // Advance only when the commit is now synced; a Busy tick leaves
                // it for a later attempt once the peer releases the lock.
                Ok(Tick::Synced) => last_synced = Some(head),
                Ok(Tick::Busy) => {}
                Err(err) => {
                    eprintln!("giga watch: analysing {} failed: {err:#}", short(&head));
                    // Advance so a permanently failing commit does not spin; the
                    // next new commit is still attempted.
                    last_synced = Some(head);
                }
            }
        }
        if request.once {
            return Ok(());
        }
        std::thread::sleep(request.interval);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        assert!(Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap()
            .status
            .success());
    }

    fn repo_with_commit() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        git(dir.path(), &["init", "-q"]);
        git(dir.path(), &["config", "user.email", "t@t"]);
        git(dir.path(), &["config", "user.name", "t"]);
        std::fs::write(dir.path().join("a.rs"), "pub fn a() {}\n").unwrap();
        git(dir.path(), &["add", "."]);
        git(dir.path(), &["commit", "-qm", "init"]);
        dir
    }

    fn request(repo: &Path) -> WatchRequest {
        WatchRequest {
            repo: repo.to_path_buf(),
            db: repo.join(".giga/gigasail.db"),
            profile: "analyse".into(),
            trust_current_config: false,
            interval: Duration::from_secs(1),
            once: true,
        }
    }

    #[test]
    fn giga_dir_is_the_db_parent() {
        assert_eq!(giga_dir(Path::new(".giga/gigasail.db")), PathBuf::from(".giga"));
        assert_eq!(giga_dir(Path::new("gigasail.db")), PathBuf::from("."));
    }

    #[test]
    fn head_commit_resolves_the_tip() {
        let dir = repo_with_commit();
        let head = head_commit(dir.path()).unwrap();
        assert_eq!(head.len(), 40);
    }

    #[test]
    fn process_commit_defers_when_a_peer_holds_the_lock() {
        let dir = repo_with_commit();
        let request = request(dir.path());
        // A peer (this test) holds the .giga/ lock for the commit; process_commit
        // must report Busy and run no analysis.
        let held = GigaLock::try_acquire(&giga_dir(&request.db), "peercommit", "ingest")
            .unwrap()
            .expect("test holds the lock");
        assert_eq!(process_commit(&request, "peercommit").unwrap(), Tick::Busy);
        drop(held);
        // With the lock free, the DB dir was created and the lock is available.
        assert!(GigaLock::current(&giga_dir(&request.db)).unwrap().is_none());
    }
}
