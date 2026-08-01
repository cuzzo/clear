//! Running the traced programs.
//!
//! One process per shard, several at a time, each told through its environment
//! where to write and which run it is. Their output is the workload's own --
//! test results a person is watching -- so it goes straight to the terminal
//! rather than being captured and replayed.
//!
//! The first failure stops the rest unless the caller asked to continue: a
//! shard that did not run leaves no evidence, and evidence that is silently
//! missing is worse than a collect that stops and says so.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

#[derive(Debug, Deserialize)]
pub struct Shard {
    pub id: String,
    pub command: Vec<String>,
    /// A null value means "unset this variable", which is what a nil in the
    /// caller's environment hash has always meant.
    #[serde(default)]
    pub env: std::collections::BTreeMap<String, Option<String>>,
}

#[derive(Debug, Deserialize)]
pub struct Plan {
    pub shards: Vec<Shard>,
    #[serde(default = "one")]
    pub jobs: usize,
    #[serde(default)]
    pub continue_on_error: bool,
    /// Echoed with each shard so the terminal shows what a person could rerun.
    #[serde(default)]
    pub banner: String,
}

fn one() -> usize {
    1
}

/// The shards that failed, in the order they were scheduled.
pub fn run(plan: &Plan) -> Result<Vec<String>> {
    let next = AtomicUsize::new(0);
    let stop = AtomicBool::new(false);
    let failed: Mutex<Vec<(usize, String)>> = Mutex::new(Vec::new());
    let total = plan.shards.len();
    let jobs = plan.jobs.max(1).min(total.max(1));

    std::thread::scope(|scope| {
        for _ in 0..jobs {
            scope.spawn(|| {
                loop {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    let at = next.fetch_add(1, Ordering::SeqCst);
                    let Some(shard) = plan.shards.get(at) else { return };
                    let Some((program, arguments)) = shard.command.split_first() else {
                        continue;
                    };
                    println!("[{}/{total}] {}{}", at + 1, plan.banner, shard.command.join(" "));
                    let mut process = Command::new(program);
                    process.args(arguments);
                    for (key, value) in &shard.env {
                        match value {
                            Some(value) => process.env(key, value),
                            None => process.env_remove(key),
                        };
                    }
                    let status = process
                        .stdout(Stdio::inherit())
                        .stderr(Stdio::inherit())
                        .status();
                    let ok = matches!(status, Ok(status) if status.success());
                    if !ok {
                        failed.lock().expect("failures").push((at, shard.id.clone()));
                        if !plan.continue_on_error {
                            stop.store(true, Ordering::SeqCst);
                        }
                    }
                }
            });
        }
    });

    let mut failures = failed.into_inner().expect("failures");
    failures.sort_by_key(|(at, _)| *at);
    Ok(failures.into_iter().map(|(_, id)| id).collect())
}

pub fn run_file(path: &std::path::Path) -> Result<Vec<String>> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("unreadable shard plan {}", path.display()))?;
    run(&serde_json::from_str(&raw)?)
}
