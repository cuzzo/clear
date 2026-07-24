//! `giga time-tests`: measure how long a change's new tests take and record it,
//! so the diff "Tests" section can show a delta vs the recent baseline. Meant to
//! run in the background - the diff shows `[ PENDING ]` until this lands.
//!
//! v1 measures the wall-clock of the caller-supplied "run the new tests" command
//! (the project knows how to select its new tests): run once; if that is under
//! 250ms the launch/noise dominates, so take three more for a usable sample and
//! confidence interval; if it is already over a second, one run is enough.
//! Framework built-in per-test timing (to avoid relaunch) is a later refinement.

use crate::git::GitProvider;
use crate::storage::Storage;
use crate::test_timing::{mean_stddev, TIMING_STAGE};
use anyhow::{Context, Result};
use std::path::Path;
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub struct TimeTestsResult {
    pub revision: String,
    pub test_set: String,
    pub mean_ms: f64,
    pub stddev_ms: f64,
    pub samples: usize,
}

pub fn execute(
    repo: &Path,
    db: &Path,
    test_set: &str,
    run_command: &str,
) -> Result<TimeTestsResult> {
    let git = GitProvider::open(repo)?;
    let revision = git.resolve_commit("HEAD")?;

    let mut samples = vec![run_and_time(repo, run_command)?];
    // Fast suite: the single measurement is dominated by process launch and
    // scheduling noise, so gather a small sample for a meaningful CI. Slow
    // suite (>1s): one run is representative and repeats are expensive.
    if samples[0] < 250.0 {
        for _ in 0..3 {
            samples.push(run_and_time(repo, run_command)?);
        }
    }
    let (mean_ms, stddev_ms) = mean_stddev(&samples);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let storage = Storage::open(db)?;
    storage.record_stage_timing(
        &revision,
        TIMING_STAGE,
        test_set,
        mean_ms,
        stddev_ms,
        samples.len() as i64,
        timestamp,
    )?;

    Ok(TimeTestsResult {
        revision,
        test_set: test_set.to_string(),
        mean_ms,
        stddev_ms,
        samples: samples.len(),
    })
}

/// Run the command through `sh -c` in the repo and return its wall-clock in ms.
/// The command's exit status is not consulted - a failing test still took time,
/// and the timing measurement should not itself fail the run.
fn run_and_time(repo: &Path, command: &str) -> Result<f64> {
    let start = Instant::now();
    Command::new("sh")
        .arg("-c")
        .arg(command)
        .current_dir(repo)
        .status()
        .with_context(|| format!("failed to run timing command: {command}"))?;
    Ok(start.elapsed().as_secs_f64() * 1000.0)
}
