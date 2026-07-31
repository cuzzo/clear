//! `nil-kill collect`, without a Ruby process to drive it.
//!
//! Every stage below is already a FactMine function; what was left in Ruby was
//! the order they run in, the environment the traced programs are given, and
//! the transaction that keeps the canonical artifacts consistent. That is what
//! this is.
//!
//! The traced program still has whatever runtime it has -- collecting Ruby
//! means running Ruby -- but nothing between the command line and the evidence
//! needs one.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub struct Config {
    pub root: PathBuf,
    pub tmp_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub trace_plan: PathBuf,
    pub targets: Vec<String>,
    pub collector_extension: PathBuf,
    pub commands: Vec<Vec<String>>,
    pub fast: bool,
    pub continue_on_error: bool,
    pub shard_jobs: usize,
}

impl Config {
    pub fn from_env(root: PathBuf, commands: Vec<Vec<String>>) -> Self {
        let tmp_dir = std::env::var("NIL_KILL_TMP_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| root.join("tmp").join("nil-kill"));
        let targets = std::env::var("NIL_KILL_TARGETS")
            .unwrap_or_else(|_| "src".to_string())
            .split(':')
            .map(str::to_string)
            .collect();
        Self {
            runtime_dir: tmp_dir.join("runtime"),
            trace_plan: tmp_dir.join("trace-plan.json"),
            collector_extension: collector_extension(),
            tmp_dir,
            root,
            targets,
            commands,
            fast: false,
            continue_on_error: false,
            shard_jobs: std::thread::available_parallelism().map_or(4, |n| n.get()),
        }
    }

    /// Every analyzed source file under the targets.
    pub fn target_files(&self) -> Vec<PathBuf> {
        let mut found = Vec::new();
        for target in &self.targets {
            let path = self.root.join(target);
            collect_ruby(&path, &mut found);
        }
        found.sort();
        found.dedup();
        found
    }
}

/// The collector object the traced program loads.
///
/// It ships beside this binary, not inside the project being collected, so it
/// is found from where nil-kill is installed rather than from the analyzed
/// root -- a collect of any repository but nil-kill's own would otherwise look
/// for it under that repository.
fn collector_extension() -> PathBuf {
    const RELATIVE: &str = "gems/nil-kill/ext/nil_kill_trace/nil_kill_trace.so";
    if let Ok(path) = std::env::var("NIL_KILL_COLLECTOR_EXTENSION") {
        return PathBuf::from(path);
    }
    // target/<profile>/fact-mine-rust -> the workspace holding both gems.
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.ancestors().nth(5).map(|root| root.join(RELATIVE)))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from(RELATIVE))
}

fn collect_ruby(path: &Path, into: &mut Vec<PathBuf>) {
    if path.is_file() {
        if path.extension().is_some_and(|e| e == "rb") {
            into.push(path.to_path_buf());
        }
        return;
    }
    for entry in std::fs::read_dir(path).into_iter().flatten().flatten() {
        collect_ruby(&entry.path(), into);
    }
}

fn stage<T>(name: &str, body: impl FnOnce() -> Result<T>) -> Result<T> {
    if std::env::var("NIL_KILL_STAGE_TIMING").as_deref() != Ok("1") {
        return body();
    }
    let started = std::time::Instant::now();
    let out = body();
    eprintln!("stage {name:<26} {:6.2}s", started.elapsed().as_secs_f64());
    out
}

/// The one shard per command a workload gets when no test runner is
/// recognizable. Nothing about such a command says which part of it a source
/// change affects, so every one of them reruns.
fn opaque_shards(commands: &[Vec<String>]) -> Vec<Value> {
    use sha2::{Digest, Sha256};
    commands
        .iter()
        .enumerate()
        .map(|(at, command)| {
            let digest = format!("{:x}", Sha256::digest(serde_json::to_string(command).unwrap_or_default().as_bytes()));
            json!({
                "id": format!("command-{at}-{}", &digest[..12]),
                "command": command,
                "test_path": "",
            })
        })
        .collect()
}

pub fn run(config: &Config) -> Result<()> {
    // Incremental collect is still the Ruby CLI's: it needs the snapshot
    // manifest, the stored per-shard evidence and the rebase onto the current
    // plan, none of which this drives yet. Saying so is the point -- a `--fast`
    // that quietly ran a full collect would report a generation it never made,
    // and one that ran no shards would publish empty evidence as current.
    if config.fast {
        bail!(
            "nil-kill collect --fast is not implemented here yet; \
             run a full collect, or use the Ruby CLI for an incremental one"
        );
    }
    if config.commands.is_empty() {
        bail!("nil-kill collect requires a command: collect -- <command...>");
    }
    std::fs::create_dir_all(&config.runtime_dir)?;

    // ---- the plan --------------------------------------------------------
    stage("trace-plan", || {
        if std::env::var("NIL_KILL_TRACE_PLAN").as_deref() == Ok("0") {
            return Ok(());
        }
        write_trace_plan(config)
    })?;
    let plan: Value = std::fs::read_to_string(&config.trace_plan)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_else(|| json!({}));
    let plan_digest = plan["runtime_evidence"]["plan_digest"].as_str().unwrap_or("").to_string();

    let files = config.target_files();
    let inventory = config.tmp_dir.join("function-inventory.json");
    stage("function-inventory", || {
        let mut args = vec![
            "nil-kill-function-inventory".to_string(),
            "--output".into(), inventory.to_string_lossy().to_string(),
            "--root".into(), config.root.to_string_lossy().to_string(),
        ];
        if config.trace_plan.is_file() {
            args.push("--plan".into());
            args.push(config.trace_plan.to_string_lossy().to_string());
        }
        for file in &files {
            args.push("--file".into());
            args.push(file.to_string_lossy().to_string());
        }
        self_call(&args)
    })?;

    // ---- the workload ----------------------------------------------------
    // One shard per test file where the command names a runner, one opaque
    // shard per command where it does not.
    let planned = config
        .commands
        .iter()
        .find_map(|command| crate::workload_plan::build(&files, command, &config.root));
    let shards = match &planned {
        Some(plan) => plan
            .shards
            .iter()
            .map(|shard| json!({
                "id": shard.id,
                "command": shard.command,
                "test_path": shard.test_path,
            }))
            .collect(),
        None => opaque_shards(&config.commands),
    };
    let generation = 0;
    let working = config.runtime_dir.join("runs").join(format!("{generation:06}"));
    let _ = std::fs::remove_dir_all(&working);
    std::fs::create_dir_all(&working)?;

    // Tests and their support files are what a collect must not report as
    // production code. Getting this wrong does not fail a collect -- it
    // publishes the test suite's own methods as observed production evidence.
    let roles = working.join("source-roles.json");
    let mut nonproduction = planned
        .as_ref()
        .map(|plan| {
            plan.test_paths.iter().chain(&plan.support_paths).cloned().collect::<Vec<_>>()
        })
        .unwrap_or_default();
    nonproduction.sort();
    nonproduction.dedup();
    std::fs::write(&roles, serde_json::to_string(&json!({"nonproduction": nonproduction}))?)?;

    // ---- run them --------------------------------------------------------
    // No more workers than there is work for them to do; what is left over is
    // the parallelism each shard's own workload may use.
    let shard_jobs = config.shard_jobs.max(1).min(shards.len().max(1));
    let mut run_ids = BTreeMap::new();
    let runs = shards
        .iter()
        .map(|shard| {
            let id = shard["id"].as_str().unwrap_or_default().to_string();
            let dir = working.join(&id);
            std::fs::create_dir_all(&dir).ok();
            let run_id = format!("{generation}:{id}:{}", uuid());
            run_ids.insert(id.clone(), run_id.clone());
            let mut env: BTreeMap<String, Option<String>> = BTreeMap::new();
            for (key, value) in std::env::vars() {
                env.insert(key, Some(value));
            }
            env.insert("NIL_KILL_TRACE".into(), Some("1".into()));
            env.insert("NIL_KILL_RUNTIME_SCIP".into(), Some("1".into()));
            env.insert("NIL_KILL_ROOT".into(), Some(config.root.to_string_lossy().to_string()));
            env.insert("NIL_KILL_SOURCE_ROLES".into(), Some(roles.to_string_lossy().to_string()));
            env.insert("NIL_KILL_RUNTIME_DIR".into(), Some(dir.to_string_lossy().to_string()));
            env.insert("NIL_KILL_RUN_ID".into(), Some(run_id));
            env.insert("NIL_KILL_SHARD_ID".into(), Some(id.clone()));
            // A workload that picks a different test order each time observes
            // different state and records different values.
            env.insert(
                "SEED".into(),
                Some(std::env::var("NIL_KILL_WORKLOAD_SEED").unwrap_or_else(|_| "0".into())),
            );
            // The workload's own parallelism, divided by how many shards run at
            // once. A workload that picks its own thread count observes
            // different interleavings and records different values.
            let inner = (config.shard_jobs.max(1) / shard_jobs.max(1)).max(1).to_string();
            for key in ["WORKERS", "NK_JOBS", "NIL_KILL_JOBS"] {
                if std::env::var(key).is_err() {
                    env.insert(key.into(), Some(inner.clone()));
                }
            }
            let project = config
                .root
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_default();
            env.entry("NIL_KILL_PROJECT_NAME".into()).or_insert(Some(project));
            env.entry("NIL_KILL_PROJECT_VERSION".into())
                .or_insert(Some(head_revision(&config.root)));
            let rubyopt = format!(
                "{} -r{}",
                std::env::var("RUBYOPT").unwrap_or_default(),
                config.collector_extension.display()
            );
            env.insert("RUBYOPT".into(), Some(rubyopt.trim().to_string()));
            crate::shard_runner::Shard {
                id,
                command: shard["command"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|part| part.as_str().map(str::to_string))
                    .collect(),
                env,
            }
        })
        .collect::<Vec<_>>();

    let failed = crate::shard_runner::run(&crate::shard_runner::Plan {
        shards: runs,
        jobs: shard_jobs,
        continue_on_error: config.continue_on_error,
        banner: String::new(),
    })?;
    if !failed.is_empty() {
        bail!(
            "required trace shard(s) failed; canonical evidence was not replaced: {}",
            failed.join(", ")
        );
    }

    let shard_dirs = shards
        .iter()
        .map(|shard| working.join(shard["id"].as_str().unwrap_or_default()))
        .collect::<Vec<_>>();

    // ---- what the collector saw becomes what it means --------------------
    let root = config.root.to_string_lossy().to_string();
    let plan_path = config.trace_plan.to_string_lossy().to_string();
    stage("derive-domains", || {
        let mut args = vec!["nil-kill-derive-domains".to_string(),
            "--root".into(), root.clone(),
            "--source-roles".into(), roles.to_string_lossy().to_string()];
        for dir in &shard_dirs {
            for path in raw_documents(dir) {
                args.push("--input".into());
                args.push(path.to_string_lossy().to_string());
            }
        }
        self_call(&args)
    })?;
    stage("collector-export", || {
        let mut args = vec!["nil-kill-collector-export".to_string(),
            "--root".into(), root.clone(), "--plan".into(), plan_path.clone(),
            "--source-roles".into(), roles.to_string_lossy().to_string()];
        for dir in &shard_dirs {
            args.push("--runtime-dir".into());
            args.push(dir.to_string_lossy().to_string());
        }
        self_call(&args)
    })?;
    stage("trace-documents", || {
        let mut args = vec!["nil-kill-trace-document".to_string(),
            "--root".into(), root.clone(), "--plan".into(), plan_path.clone()];
        for dir in &shard_dirs {
            args.push("--runtime-dir".into());
            args.push(dir.to_string_lossy().to_string());
        }
        self_call(&args)
    })?;

    // ---- join, merge, index ---------------------------------------------
    let traces = shard_dirs
        .iter()
        .map(|dir| dir.join("runtime-trace.json.gz"))
        .collect::<Vec<_>>();
    let merged = working.join("merged-evidence.v1.json.gz");
    stage("join", || {
        let mut args = vec!["runtime-trace".to_string(),
            "--root".into(), root.clone(), "--plan".into(), plan_path.clone(),
            "--merged-output".into(), merged.to_string_lossy().to_string()];
        for trace in &traces {
            args.push("--runtime-trace".into());
            args.push(trace.to_string_lossy().to_string());
        }
        self_call(&args)
    })?;

    let canonical = config.runtime_dir.join("runtime-evidence.v1.json.gz");
    let index = config.runtime_dir.join("runtime.scip.json");
    let attestation = config.runtime_dir.join("runtime-attestation.json.gz");
    let state = config.tmp_dir.join("canonical-transaction.json");
    let saved = crate::canonical_transaction::save(
        &[canonical.clone(), index.clone(), attestation.clone()],
        &state.with_extension("d"),
    )?;

    let finish = || -> Result<()> {
        std::fs::copy(&merged, &canonical)?;
        // The overlay re-derives the plan from source to check the snapshot
        // still matches, and reads the runtime-evidence contract rather than
        // the private instrumentation controls beside it.
        let evidence_plan = config.tmp_dir.join("runtime-evidence-contract.json");
        std::fs::write(&evidence_plan, serde_json::to_string(&plan["runtime_evidence"])?)?;
        stage("scip-index", || {
            self_call(&["nil-kill-scip-index".to_string(),
                "--runtime-dir".into(), working.to_string_lossy().to_string(),
                "--evidence".into(), canonical.to_string_lossy().to_string(),
                "--plan".into(), evidence_plan.to_string_lossy().to_string(),
                "--output".into(), index.to_string_lossy().to_string(),
                "--attestation".into(), attestation.to_string_lossy().to_string(),
                "--root".into(), root.clone()])
        })
    };
    if let Err(error) = finish() {
        crate::canonical_transaction::restore(&saved).ok();
        return Err(error);
    }
    let _ = inventory;
    Ok(())
}

fn raw_documents(dir: &Path) -> Vec<PathBuf> {
    let mut found = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name().is_some_and(|name| {
                let name = name.to_string_lossy();
                name.starts_with("collector-raw-") && name.ends_with(".json.gz")
            })
        })
        .collect::<Vec<_>>();
    found.sort();
    found
}

/// The commit a collect ran against, which is the workspace package's version.
fn head_revision(root: &Path) -> String {
    std::process::Command::new("git")
        .args(["-C", &root.to_string_lossy(), "rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| "workspace".to_string())
}

/// A run identity that is unique per shard per collect.
fn uuid() -> String {
    use sha2::{Digest, Sha256};
    let seed = format!(
        "{:?}{}",
        std::time::SystemTime::now(),
        std::process::id()
    );
    format!("{:x}", Sha256::digest(seed.as_bytes()))[..32].to_string()
}

/// A stage, run as its own invocation of this binary. Each is already a
/// verified subcommand; collect decides the order and the environment.
fn self_call(args: &[String]) -> Result<()> {
    let binary = std::env::current_exe().context("cannot locate the fact-mine binary")?;
    let name = args.first().cloned().unwrap_or_default();
    let status = std::process::Command::new(&binary)
        .args(args)
        .status()
        .with_context(|| format!("failed to run {name}"))?;
    if !status.success() {
        bail!("fact-mine {name} failed");
    }
    Ok(())
}

fn write_trace_plan(config: &Config) -> Result<()> {
    let files = config.target_files();
    if files.is_empty() {
        return Ok(());
    }
    let text = |path: &Path| path.to_string_lossy().to_string();
    let facts = config.tmp_dir.join("static-facts.json");
    let evidence = config.tmp_dir.join("runtime-evidence-plan.json");
    let mut profile = vec!["profile".to_string(), "trace-plan".into(),
                           "--output".into(), text(&facts)];
    let mut runtime = vec!["runtime-plan".to_string(), "--output".into(), text(&evidence),
                           "--root".into(), text(&config.root)];
    for file in &files {
        profile.push(text(file));
        runtime.push(text(file));
    }
    self_call(&profile)?;
    self_call(&runtime)?;

    let mut args = vec!["nil-kill-trace-plan".to_string(),
        "--raw-facts".into(), text(&facts),
        "--runtime-plan".into(), text(&evidence),
        "--output".into(), text(&config.trace_plan),
        "--root".into(), text(&config.root)];
    let mut sidecar = vec!["nil-kill-collector-plan".to_string(),
        "--plan".into(), text(&config.trace_plan),
        "--output".into(), text(&config.tmp_dir.join("collector-plan.tsv")),
        "--root".into(), text(&config.root)];
    for target in &config.targets {
        for list in [&mut args, &mut sidecar] {
            list.push("--target-dir".into());
            list.push(text(&config.root.join(target)));
        }
    }
    self_call(&args)?;
    self_call(&sidecar)
}
