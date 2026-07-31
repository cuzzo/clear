//! Replacing a collect's canonical artifacts, all of them or none.
//!
//! A collect rewrites several files that are only meaningful together -- the
//! merged evidence, the snapshot manifest, the SCIP index, the attestation, and
//! the shard store. Half of a new set beside half of an old one describes a
//! state that never existed, and nothing downstream can tell that it is looking
//! at one.
//!
//! So the previous contents are copied aside first and put back if anything
//! fails. A file that did not exist before is deleted rather than restored:
//! absent is a state too, and leaving a new artifact behind would be exactly
//! the half-written set this exists to prevent.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Deserialize)]
pub struct Saved {
    /// Where each path's previous contents were copied, or absent when the
    /// path did not exist.
    pub entries: Vec<(PathBuf, Option<PathBuf>)>,
    pub directory: PathBuf,
}

pub fn save(paths: &[PathBuf], into: &Path) -> Result<Saved> {
    std::fs::create_dir_all(into)
        .with_context(|| format!("failed to prepare {}", into.display()))?;
    let mut entries = Vec::new();
    let mut seen: Vec<&PathBuf> = Vec::new();
    for (at, path) in paths.iter().enumerate() {
        if seen.contains(&path) {
            continue;
        }
        seen.push(path);
        if !path.is_file() {
            entries.push((path.clone(), None));
            continue;
        }
        let copy = into.join(format!("{at}"));
        std::fs::copy(path, &copy)
            .with_context(|| format!("failed to preserve {}", path.display()))?;
        entries.push((path.clone(), Some(copy)));
    }
    Ok(Saved { entries, directory: into.to_path_buf() })
}

/// Put every path back the way it was. Best effort per path: one failure must
/// not abandon the rest half-restored.
pub fn restore(saved: &Saved) -> Result<()> {
    let mut failures = Vec::new();
    for (path, copy) in &saved.entries {
        let outcome = match copy {
            Some(copy) => std::fs::copy(copy, path).map(|_| ()),
            None if path.is_file() => std::fs::remove_file(path),
            None => Ok(()),
        };
        if let Err(error) = outcome {
            failures.push(format!("{}: {error}", path.display()));
        }
    }
    if failures.is_empty() {
        return Ok(());
    }
    anyhow::bail!("could not restore the canonical artifacts: {}", failures.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restores_what_was_there_and_removes_what_was_not() {
        let root = tempfile::tempdir().expect("tempdir");
        let existing = root.path().join("evidence.json");
        let fresh = root.path().join("index.json");
        std::fs::write(&existing, "before").expect("write");

        let saved = save(
            &[existing.clone(), fresh.clone()],
            &root.path().join("saved"),
        )
        .expect("save");

        // A collect then replaces one and creates the other, and fails.
        std::fs::write(&existing, "after").expect("write");
        std::fs::write(&fresh, "new").expect("write");
        restore(&saved).expect("restore");

        assert_eq!(std::fs::read_to_string(&existing).expect("read"), "before");
        assert!(!fresh.exists(), "a file that did not exist before must not survive");
    }

    #[test]
    fn a_repeated_path_is_saved_once() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("evidence.json");
        std::fs::write(&path, "before").expect("write");

        let saved = save(&[path.clone(), path.clone()], &root.path().join("saved"))
            .expect("save");

        assert_eq!(saved.entries.len(), 1);
    }
}
