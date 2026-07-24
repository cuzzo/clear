//! Cross-process coordination lock for `.giga/` analysis runs.
//!
//! A single PID-bearing lock file (`.giga/lock.json`) serializes the
//! analyse/ingest ("ci then sync") work so `giga watch` and an MCP server never
//! index the same database concurrently. Readers (`giga diff`, MCP queries)
//! consult [`GigaLock::current`] to decide whether to wait for an in-progress
//! run on their target commit or render what is already stored.
//!
//! Acquisition is race-free across processes: the payload is written to a
//! per-PID temp file first, then atomically `hard_link`ed into place. `link(2)`
//! fails with `EEXIST` when the lock is already held, so the visible lock file
//! always contains a fully written record — there is no window where a peer can
//! observe a half-written lock and wrongly reclaim it. A lock left behind by a
//! dead process is reclaimed automatically via a `kill(pid, 0)` liveness check.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const LOCK_FILE: &str = "lock.json";

/// Distinguishes concurrent temp files within one process (threads share a PID).
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// The recorded holder of the `.giga/` lock.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LockInfo {
    pub pid: u32,
    /// The commit whose evidence the holder is producing.
    pub commit: String,
    /// What the holder is doing, e.g. `"analyse"` or `"ingest"`.
    pub operation: String,
    /// Unix seconds when the lock was taken.
    pub started_at: u64,
}

/// An acquired lock. Dropping it releases the lock file (if this process is
/// still the recorded owner).
#[derive(Debug)]
pub struct GigaLock {
    path: PathBuf,
    info: LockInfo,
}

impl GigaLock {
    /// The record this process wrote when it acquired the lock.
    pub fn info(&self) -> &LockInfo {
        &self.info
    }

    /// Try to acquire the `.giga/` lock for `commit`/`operation`.
    ///
    /// Returns `Ok(None)` when a live process already holds it. A stale lock
    /// left by a dead process is reclaimed and acquired.
    pub fn try_acquire(giga_dir: &Path, commit: &str, operation: &str) -> Result<Option<GigaLock>> {
        fs::create_dir_all(giga_dir)
            .with_context(|| format!("create {}", giga_dir.display()))?;
        let path = giga_dir.join(LOCK_FILE);
        let info = LockInfo {
            pid: std::process::id(),
            commit: commit.to_string(),
            operation: operation.to_string(),
            started_at: now_unix(),
        };
        let bytes = serde_json::to_vec(&info)?;
        let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let tmp = giga_dir.join(format!(".{LOCK_FILE}.{}.{}.tmp", info.pid, seq));
        fs::write(&tmp, &bytes).with_context(|| format!("write {}", tmp.display()))?;

        // Bounded retry to resolve the reclaim race with a peer process.
        let outcome = (|| {
            for _ in 0..8 {
                match fs::hard_link(&tmp, &path) {
                    Ok(()) => {
                        return Ok(Some(GigaLock {
                            path: path.clone(),
                            info: info.clone(),
                        }))
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                        match read_lock(&path)? {
                            // A live peer owns it.
                            Some(existing) if pid_alive(existing.pid) => return Ok(None),
                            // A dead peer left it behind: reclaim and retry.
                            Some(_) => {
                                let _ = fs::remove_file(&path);
                                continue;
                            }
                            // File exists but is unreadable/corrupt, or a peer is
                            // mid-reclaim. Assume held rather than risk stealing.
                            None => return Ok(None),
                        }
                    }
                    Err(err) => {
                        return Err(err).with_context(|| format!("link {}", path.display()))
                    }
                }
            }
            // A peer kept winning the reclaim race; treat as held.
            Ok(None)
        })();

        let _ = fs::remove_file(&tmp);
        outcome
    }

    /// Read the current holder if a live process holds the lock. A stale lock
    /// (dead PID) is removed and `None` is returned.
    pub fn current(giga_dir: &Path) -> Result<Option<LockInfo>> {
        let path = giga_dir.join(LOCK_FILE);
        match read_lock(&path)? {
            Some(info) if pid_alive(info.pid) => Ok(Some(info)),
            Some(_) => {
                let _ = fs::remove_file(&path);
                Ok(None)
            }
            None => Ok(None),
        }
    }
}

impl Drop for GigaLock {
    fn drop(&mut self) {
        // Only remove the lock if we are still the recorded owner, so a
        // reclaimed-and-retaken lock held by another process is left intact.
        if let Ok(Some(info)) = read_lock(&self.path) {
            if info.pid == self.info.pid && info.started_at == self.info.started_at {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

/// Parse the lock file. `Ok(None)` means the file is absent OR present but
/// unparseable; callers treat "present but unparseable" as held (they only ever
/// see a fully written record once it is linked, so unparseable implies genuine
/// corruption, which must not be silently stolen).
fn read_lock(path: &Path) -> Result<Option<LockInfo>> {
    match fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).ok()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err).with_context(|| format!("read {}", path.display())),
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Whether a process with `pid` is alive. `kill(pid, 0)` returns `0` (we may
/// signal it) or fails with `EPERM` (alive, not ours) for live processes, and
/// `ESRCH` for dead ones.
#[cfg(unix)]
fn pid_alive(pid: u32) -> bool {
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if result == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_alive(_pid: u32) -> bool {
    // Without a portable liveness probe, never steal a lock.
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn dead_pid() -> u32 {
        // A child that has exited and been reaped: its PID is dead (barring an
        // immediate, unlikely reuse within the test window).
        let child = Command::new("true").spawn().expect("spawn true");
        let pid = child.id();
        let mut child = child;
        child.wait().expect("reap true");
        pid
    }

    #[test]
    fn acquire_then_release_on_drop() {
        let dir = tempfile::tempdir().unwrap();
        {
            let lock = GigaLock::try_acquire(dir.path(), "abc123", "analyse")
                .unwrap()
                .expect("first acquire succeeds");
            assert_eq!(lock.info().commit, "abc123");
            assert_eq!(lock.info().operation, "analyse");
            // Held: a second acquire from this same (live) process is refused.
            assert!(GigaLock::try_acquire(dir.path(), "abc123", "analyse")
                .unwrap()
                .is_none());
            assert!(GigaLock::current(dir.path()).unwrap().is_some());
        }
        // Dropped: the lock is released and re-acquirable.
        assert!(GigaLock::current(dir.path()).unwrap().is_none());
        assert!(GigaLock::try_acquire(dir.path(), "def456", "ingest")
            .unwrap()
            .is_some());
    }

    #[test]
    fn stale_lock_from_dead_pid_is_reclaimed() {
        let dir = tempfile::tempdir().unwrap();
        let stale = LockInfo {
            pid: dead_pid(),
            commit: "old".into(),
            operation: "analyse".into(),
            started_at: 1,
        };
        fs::write(dir.path().join(LOCK_FILE), serde_json::to_vec(&stale).unwrap()).unwrap();
        // current() reports no live holder and clears the stale file.
        assert!(GigaLock::current(dir.path()).unwrap().is_none());
        // A fresh acquire reclaims it.
        let lock = GigaLock::try_acquire(dir.path(), "new", "analyse")
            .unwrap()
            .expect("reclaim stale lock");
        assert_eq!(lock.info().commit, "new");
    }

    #[test]
    fn live_lock_is_never_reclaimed() {
        let dir = tempfile::tempdir().unwrap();
        // Our own PID is alive, so this record must be treated as held.
        let live = LockInfo {
            pid: std::process::id(),
            commit: "busy".into(),
            operation: "ingest".into(),
            started_at: 1,
        };
        fs::write(dir.path().join(LOCK_FILE), serde_json::to_vec(&live).unwrap()).unwrap();
        assert!(GigaLock::current(dir.path()).unwrap().is_some());
        assert!(GigaLock::try_acquire(dir.path(), "busy", "ingest")
            .unwrap()
            .is_none());
    }

    #[test]
    fn hammer_exactly_one_winner_per_round() {
        // Oversubscribed threads race for the lock. Because acquisition is an
        // atomic hard_link and every winner HOLDS its lock until the whole round
        // has attempted, exactly one thread can win; the rest observe a live
        // holder (this process) and back off. After the round, the retained lock
        // is dropped and the file is free again.
        let dir = Arc::new(tempfile::tempdir().unwrap());
        for _ in 0..64 {
            let attempts = Arc::new(AtomicUsize::new(0));
            let held: Arc<std::sync::Mutex<Vec<GigaLock>>> =
                Arc::new(std::sync::Mutex::new(Vec::new()));
            let barrier = Arc::new(std::sync::Barrier::new(16));
            let mut handles = Vec::new();
            for _ in 0..16 {
                let dir = Arc::clone(&dir);
                let attempts = Arc::clone(&attempts);
                let held = Arc::clone(&held);
                let barrier = Arc::clone(&barrier);
                handles.push(std::thread::spawn(move || {
                    barrier.wait();
                    attempts.fetch_add(1, Ordering::SeqCst);
                    if let Some(lock) =
                        GigaLock::try_acquire(dir.path(), "race", "analyse").unwrap()
                    {
                        // Retain the lock (do not drop) so peers see it held.
                        held.lock().unwrap().push(lock);
                    }
                }));
            }
            for handle in handles {
                handle.join().unwrap();
            }
            assert_eq!(attempts.load(Ordering::SeqCst), 16);
            let mut held = held.lock().unwrap();
            assert_eq!(held.len(), 1, "exactly one thread must win the lock");
            held.clear(); // drop the retained lock -> release
            assert!(
                GigaLock::current(dir.path()).unwrap().is_none(),
                "lock must be free after the winner releases"
            );
        }
    }
}
