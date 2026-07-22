use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use lineage::{
    build_structured_diff, coverage_records_to_test_exposure_json, execute_profile,
    ingest_architecture_json, ingest_coverage_json_with_options, ingest_hazards,
    ingest_hotness_json, ingest_mutant_facts_json_with_options, ingest_sarif_paths,
    ingest_stack_traces, ingest_test_exposure_json, latest_run_directory, load_config,
    load_run_manifest, parse_coverage_input, read_manifest_artifact, render_structured_diff_json,
    render_structured_diff_text, resolve_coverage_record_paths, serve_lsp, serve_mcp,
    serve_ui_with_overlays, ArtifactKind, CoverageIngestOptions, DiffRequest,
    EvidenceArtifactScope, EvidenceScopeFingerprint, GitProvider, HeuristicExtractor,
    LineageEngine, MutantIngestOptions, publish_run, repository_identity, RepoPathNormalizer, RunStatus,
    SentryProvider, Storage,
};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command as ProcessCommand;

#[derive(Debug, Parser)]
#[command(name = "lineage")]
#[command(about = "Track logical code-unit history across moves and refactors")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run a configured verification profile, stage its artifacts, and ingest them.
    Ci {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = "ci")]
        profile: String,
    },
    /// Print a revision-pinned, evidence-aware architectural diff.
    Diff {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(value_name = "BASE")]
        base: Option<String>,
        #[arg(value_name = "HEAD")]
        head: Option<String>,
        #[arg(long, value_enum, default_value_t = DiffFormat::Text)]
        format: DiffFormat,
        /// Include logical-unit and SARIF detail under every changed file.
        #[arg(long)]
        full: bool,
        #[arg(long)]
        coverage_source: Option<String>,
        #[arg(long)]
        sarif_source: Option<String>,
        #[arg(long)]
        selection: Option<String>,
        #[arg(long)]
        mutant_corpus: Option<String>,
        #[arg(long)]
        test_set: Option<String>,
    },
    /// Initialize an empty lineage SQLite database.
    Init {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
    },
    /// Ingest a versioned Espalier architecture graph artifact.
    IngestArchitecture {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long)]
        input: PathBuf,
    },
    /// Build lineage data for a Git repository.
    Build {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long)]
        max_commits: Option<usize>,
    },
    /// Print the highest-risk logical units from a lineage database.
    Summary {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value_t = 20)]
        top: usize,
        #[arg(long = "only")]
        only: Vec<String>,
        #[arg(long, default_value = "text")]
        format: String,
    },
    /// Refresh materialized UI summaries for fast dashboard and file index reads.
    RefreshUi {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
    },
    /// Serve the local Lineage source and verification UI.
    Ui {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        #[arg(long, default_value_t = 8080)]
        port: u16,
        #[arg(long = "overlay")]
        overlays: Vec<PathBuf>,
    },
    /// Run the Lineage language server over stdio.
    Lsp {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long = "overlay")]
        overlays: Vec<PathBuf>,
    },
    /// Serve lineage.db to LLM coding agents over the Model Context Protocol.
    /// Omit --db to run DB-less (live disk facts only; see docs/agents/mcp.md).
    Mcp {
        #[arg(long)]
        db: Option<PathBuf>,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
    },
    /// Ingest aggregate coverage or mutation quality data for one commit.
    IngestCoverage {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long, default_value = "codecov")]
        format: String,
        #[arg(long)]
        commit: String,
        #[arg(long)]
        timestamp: Option<i64>,
        #[arg(long)]
        replace: bool,
        #[arg(long)]
        test_type: Option<String>,
        #[arg(long)]
        test_id: Option<String>,
        #[arg(long)]
        mutation_status: Option<String>,
        #[arg(long)]
        mutation_kind: Option<String>,
    },
    /// Ingest named test exposure facts for one commit.
    IngestTestExposure {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        commit: String,
        #[arg(long)]
        timestamp: Option<i64>,
    },
    /// Ingest Ruby mutant-facts/v1 and convert them to mutation exposure.
    IngestMutants {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        commit: String,
        #[arg(long)]
        timestamp: Option<i64>,
        #[arg(long, default_value = "unit")]
        test_type: String,
        /// Stable mutation-corpus fingerprint. Supplying all scope fields lets
        /// the diff view use this artifact as exact positive evidence.
        #[arg(long)]
        mutation_corpus: Option<String>,
        #[arg(long)]
        selection: Option<String>,
        #[arg(long)]
        test_set: Option<String>,
        #[arg(long)]
        complete: bool,
    },
    /// Ingest profile-hotness/v1 runtime profiling shares.
    IngestHotness {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        commit: Option<String>,
    },
    /// Ingest current hazard sites for one provider and commit.
    IngestHazards {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = "zig")]
        provider: String,
        #[arg(long)]
        commit: String,
        #[arg(long)]
        timestamp: Option<i64>,
    },
    /// Ingest SARIF artifacts into the persistent finding index.
    IngestSarif {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long = "input")]
        inputs: Vec<PathBuf>,
        #[arg(long, default_value = "sarif")]
        source: String,
        #[arg(long)]
        commit: String,
        #[arg(long)]
        timestamp: Option<i64>,
        #[arg(long)]
        replace: bool,
    },
    /// Ingest provider stack traces and anchor frames to logical units.
    Ingest {
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: Option<PathBuf>,
        /// Ingest a lineage-run/v1 manifest. Defaults to .lineage/artifacts/latest/manifest.json.
        #[arg(long)]
        run: Option<PathBuf>,
        #[arg(long)]
        latest_run: bool,
        #[arg(long, default_value = "sentry")]
        provider: String,
        #[arg(long)]
        replace: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum DiffFormat {
    Text,
    Json,
}

#[derive(Debug)]
struct DiffCommandRequest {
    repo: PathBuf,
    db: PathBuf,
    base: Option<String>,
    head: Option<String>,
    format: DiffFormat,
    full: bool,
    coverage_source: Option<String>,
    sarif_source: Option<String>,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Ci { repo, db, profile } => {
            let db = repository_path(&repo, &db);
            let config = load_config(&repo)?;
            let git = GitProvider::open(&repo)?;
            ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
            let revision = git.resolve_commit("HEAD")?;
            ensure_revision_snapshot(&db, &repo, &revision)?;
            let completed = execute_profile(&repo, &config, &profile, &revision)?;
            ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
            let run = completed.directory.join("manifest.json");
            ingest_run_manifest(&db, &repo, &run)?;
            Storage::open(&db)?.refresh_ui_summaries()?;
            publish_run(&repo, &config, &completed.directory)?;
            println!(
                "lineage ci: profile={} revision={} artifacts={}",
                profile,
                completed.manifest.revision,
                completed.manifest.artifacts.len()
            );
        }
        Command::Diff {
            repo,
            db,
            base,
            head,
            format,
            full,
            coverage_source,
            sarif_source,
            selection,
            mutant_corpus,
            test_set,
        } => {
            let db = repository_path(&repo, &db);
            print!(
                "{}",
                execute_diff(DiffCommandRequest {
                    repo,
                    db,
                    base,
                    head,
                    format,
                    full,
                    coverage_source,
                    sarif_source,
                    selection,
                    mutant_corpus,
                    test_set,
                })?
            );
        }
        Command::Init { db } => {
            Storage::open(&db)?;
            println!("initialized {}", db.display());
        }
        Command::IngestArchitecture { db, input } => {
            let storage = Storage::open(&db)?;
            let payload = fs::read_to_string(&input)?;
            let stats = ingest_architecture_json(&storage, &payload)?;
            println!(
                "ingested architecture: artifacts={} nodes={} edges={} spans={} reconciled_units={}",
                stats.artifacts, stats.nodes, stats.edges, stats.spans, stats.reconciled_units
            );
        }
        Command::Build {
            repo,
            db,
            max_commits,
        } => {
            let provider = GitProvider::open(&repo)?;
            let storage = Storage::open(&db)?;
            let mut engine = LineageEngine::new(provider, HeuristicExtractor::default(), storage);
            let stats = engine.run(max_commits)?;
            println!(
                "processed {} commits, {} logical units, {} events ({} moves, {} fixes, {} changes)",
                stats.commits,
                stats.logical_units,
                stats.events,
                stats.moves,
                stats.fixes,
                stats.changes
            );
            let storage = Storage::open(&db)?;
            storage.refresh_ui_summaries()?;
        }
        Command::Summary {
            db,
            top,
            only,
            format,
        } => {
            let storage = Storage::open(&db)?;
            let units = storage.top_units(top, &only)?;
            if format == "json" {
                print_json_summary(&units);
            } else {
                for (index, unit) in units.iter().enumerate() {
                    println!(
                        "{:>2}. {:<10} {:<32} {:<48} risk={:.1} fixes={} changes={} moves={} events={} tests={} mutant_killed={}/{} stale_mutant_days={:.1} stale_changes={} reopened={}",
                        index + 1,
                        unit.kind,
                        unit.name,
                        unit.current_path,
                        unit.risk_score,
                        unit.fixes,
                        unit.changes,
                        unit.moves,
                        unit.total_events,
                        unit.current_distinct_tests,
                        unit.current_mutant_killed_tests,
                        unit.current_mutant_verified_tests,
                        unit.verification_staleness_score,
                        unit.semantic_changes_after_mutant_run,
                        unit.reopened_count
                    );
                }
            }
        }
        Command::RefreshUi { db } => {
            let storage = Storage::open(&db)?;
            storage.refresh_ui_summaries()?;
            let files = storage.count_rows("ui_file_summaries")?;
            let units = storage.count_rows("ui_warning_units")?;
            println!(
                "refreshed UI summaries for {} files and {} warning units",
                files, units
            );
        }
        Command::Ui {
            db,
            repo,
            host,
            port,
            overlays,
        } => {
            serve_ui_with_overlays(db, repo, &host, port, &overlays)?;
        }
        Command::Lsp { db, repo, overlays } => {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            runtime.block_on(serve_lsp(db, repo, &overlays))?;
        }
        Command::Mcp { db, repo } => {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            runtime.block_on(serve_mcp(db, repo))?;
        }
        Command::IngestCoverage {
            db,
            repo,
            input,
            format,
            commit,
            timestamp,
            replace,
            test_type,
            test_id,
            mutation_status,
            mutation_kind,
        } => {
            let storage = Storage::open(&db)?;
            let payload = fs::read_to_string(&input)?;
            let normalized_test_type = test_type.as_deref().map(normalize_test_type);
            let coverage_test_id = normalized_test_type.as_ref().map(|test_type| {
                test_id
                    .clone()
                    .unwrap_or_else(|| default_coverage_test_id(test_type, &input))
            });
            let line_source = normalized_test_type
                .as_ref()
                .zip(coverage_test_id.as_ref())
                .map(|(_, test_id)| format!("coverage:{test_id}"))
                .unwrap_or_else(|| "coverage".to_string());
            let stats = ingest_coverage_json_with_options(
                &storage,
                &payload,
                &format,
                &commit,
                timestamp,
                replace,
                &CoverageIngestOptions {
                    line_source,
                    evidence_scope: None,
                    complete: false,
                },
            )?;
            println!(
                "ingested coverage: files={} units={} events={} line_events={} skipped_files={}",
                stats.files, stats.units, stats.events, stats.line_events, stats.skipped_files
            );
            if let Some(test_type) = normalized_test_type {
                let test_id = coverage_test_id.expect("coverage test id exists for typed coverage");
                if replace {
                    storage.delete_test_exposure_for_commit_test(&commit, &test_type, &test_id)?;
                }
                let records = parse_coverage_input(&payload, &format)?;
                let records = resolve_coverage_record_paths(&storage, &records)?;
                let exposure_payload = coverage_records_to_test_exposure_json(
                    &records,
                    &test_type,
                    &test_id,
                    "lineage ingest-coverage",
                    mutation_status.as_deref(),
                    mutation_kind.as_deref(),
                );
                let exposure_record_count =
                    serde_json::from_str::<serde_json::Value>(&exposure_payload)?
                        .get("hits")
                        .and_then(serde_json::Value::as_array)
                        .map_or(0, Vec::len);
                if exposure_record_count == 0 {
                    println!(
                        "skipped coverage exposure: test_id={} test_type={} records=0",
                        test_id, test_type
                    );
                    return Ok(());
                }
                let git = GitProvider::open(&repo)?;
                let extractor = HeuristicExtractor::default();
                let normalizer = RepoPathNormalizer::new(&repo);
                let exposure_stats = ingest_test_exposure_json(
                    &storage,
                    &normalizer,
                    &git,
                    &extractor,
                    &exposure_payload,
                    &commit,
                    timestamp,
                )?;
                println!(
                    "ingested coverage exposure: test_id={} test_type={} records={} events={} unverified={} skipped_files={} skipped_records={}",
                    test_id,
                    test_type,
                    exposure_stats.records,
                    exposure_stats.events,
                    exposure_stats.unverified,
                    exposure_stats.skipped_files,
                    exposure_stats.skipped_records
                );
            }
        }
        Command::IngestTestExposure {
            db,
            repo,
            input,
            commit,
            timestamp,
        } => {
            let storage = Storage::open(&db)?;
            let git = GitProvider::open(&repo)?;
            let extractor = HeuristicExtractor::default();
            let normalizer = RepoPathNormalizer::new(&repo);
            let payload = fs::read_to_string(&input)?;
            let stats = ingest_test_exposure_json(
                &storage,
                &normalizer,
                &git,
                &extractor,
                &payload,
                &commit,
                timestamp,
            )?;
            println!(
                "ingested test exposure: records={} events={} mutation_records={} unverified={} skipped_files={} skipped_records={}",
                stats.records,
                stats.events,
                stats.mutation_records,
                stats.unverified,
                stats.skipped_files,
                stats.skipped_records
            );
        }
        Command::IngestMutants {
            db,
            repo,
            input,
            commit,
            timestamp,
            test_type,
            mutation_corpus,
            selection,
            test_set,
            complete,
        } => {
            let storage = Storage::open(&db)?;
            let git = GitProvider::open(&repo)?;
            let extractor = HeuristicExtractor::default();
            let normalizer = RepoPathNormalizer::new(&repo);
            let payload = fs::read_to_string(&input)?;
            let mutation_corpus = mutation_corpus.unwrap_or_default();
            let evidence_scope = match (selection, test_set) {
                (Some(selection), Some(test_set)) => Some(EvidenceScopeFingerprint {
                    revision: commit.clone(),
                    selection,
                    mutant_corpus: mutation_corpus.clone(),
                    test_set,
                }),
                (None, None) => None,
                _ => anyhow::bail!("--selection and --test-set must be supplied together"),
            };
            if complete && evidence_scope.is_none() {
                anyhow::bail!("--complete requires --selection, --test-set, and --mutation-corpus");
            }
            let stats = ingest_mutant_facts_json_with_options(
                &storage,
                &normalizer,
                &git,
                &extractor,
                &payload,
                &commit,
                timestamp,
                &test_type,
                &MutantIngestOptions {
                    mutation_corpus,
                    evidence_scope,
                    complete,
                },
            )?;
            println!(
                "ingested mutant facts: facts={} units={} quality_events={} exposure_events={} skipped_files={} skipped_facts={}",
                stats.facts,
                stats.units,
                stats.quality_events,
                stats.exposure_events,
                stats.skipped_files,
                stats.skipped_facts
            );
        }
        Command::IngestHotness {
            db,
            repo,
            input,
            source,
            commit,
        } => {
            let storage = Storage::open(&db)?;
            let normalizer = RepoPathNormalizer::new(&repo);
            let payload = fs::read_to_string(&input)?;
            let stats = ingest_hotness_json(
                &storage,
                &normalizer,
                &payload,
                source.as_deref(),
                commit.as_deref(),
            )?;
            println!(
                "ingested hotness: entries={} critical={} skipped={} resolved_exact={} resolved_symbol={} unresolved={}",
                stats.entries,
                stats.critical,
                stats.skipped,
                stats.resolved_exact,
                stats.resolved_symbol,
                stats.unresolved
            );
        }
        Command::IngestHazards {
            db,
            repo,
            provider,
            commit,
            timestamp,
        } => {
            let storage = Storage::open(&db)?;
            let stats = ingest_hazards(&storage, &repo, &provider, &commit, timestamp)?;
            println!(
                "ingested hazards: scanned_files={} hazards={} events={}",
                stats.scanned_files, stats.hazards, stats.events
            );
        }
        Command::IngestSarif {
            db,
            repo,
            inputs,
            source,
            commit,
            timestamp,
            replace,
        } => {
            if inputs.is_empty() {
                anyhow::bail!("ingest-sarif requires at least one --input path");
            }
            let storage = Storage::open(&db)?;
            let stats = ingest_sarif_paths(
                &storage, &repo, &inputs, &source, &commit, timestamp, replace,
            )?;
            println!(
                "ingested SARIF: artifacts={} findings={} skipped_files={} skipped_results={}",
                stats.artifacts, stats.findings, stats.skipped_files, stats.skipped_results
            );
        }
        Command::Ingest {
            db,
            repo,
            input,
            run,
            latest_run,
            provider,
            replace,
        } => {
            if run.is_some() || latest_run || input.is_none() {
                let run = match run {
                    Some(run) => run,
                    None => latest_run_directory(&repo, &load_config(&repo)?).join("manifest.json"),
                };
                ingest_run_manifest(&db, &repo, &run)?;
                return Ok(());
            }
            let input = input.expect("input checked above");
            let storage = Storage::open(&db)?;
            let git = GitProvider::open(&repo)?;
            let extractor = HeuristicExtractor::default();
            let normalizer = RepoPathNormalizer::new(&repo);
            let payload = fs::read_to_string(&input)?;
            let stats = match provider.as_str() {
                "sentry" => ingest_stack_traces(
                    &storage,
                    &SentryProvider,
                    &normalizer,
                    &git,
                    &extractor,
                    &payload,
                    replace,
                )?,
                other => anyhow::bail!("unsupported stack trace provider {other:?}"),
            };
            println!(
                "ingested stack traces: payloads={} frames={} events={} unverified={} skipped_frames={}",
                stats.payloads, stats.frames, stats.events, stats.unverified, stats.skipped_frames
            );
        }
    }
    Ok(())
}

fn repository_path(repo: &std::path::Path, path: &std::path::Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        repo.join(path)
    }
}

fn ensure_clean_worktree(
    repo: &std::path::Path,
    artifact_directory: &std::path::Path,
    database: Option<&std::path::Path>,
) -> Result<()> {
    let output = ProcessCommand::new("git")
        .args(["status", "--porcelain=v1", "--untracked-files=all"])
        .current_dir(repo)
        .output()
        .context("inspect Git worktree before lineage ci")?;
    if !output.status.success() {
        anyhow::bail!("could not inspect Git worktree before lineage ci");
    }
    let artifact_prefix = artifact_directory.to_string_lossy().replace('\\', "/");
    let database_path = database
        .and_then(|path| path.strip_prefix(repo).ok())
        .map(|path| path.to_string_lossy().replace('\\', "/"));
    let dirty = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.get(3..))
        .map(|path| path.trim_start_matches("./").replace('\\', "/"))
        .find(|path| {
            path != &artifact_prefix
                && !path.starts_with(&format!("{artifact_prefix}/"))
                && database_path.as_deref() != Some(path)
                && !database_path
                    .as_deref()
                    .is_some_and(|database| path.starts_with(&format!("{database}-")))
        });
    if let Some(path) = dirty {
        anyhow::bail!("lineage ci requires a clean worktree (found {path})");
    }
    Ok(())
}

fn ensure_revision_snapshot(
    db: &std::path::Path,
    repo: &std::path::Path,
    revision: &str,
) -> Result<()> {
    if let Some(parent) = db.parent().filter(|path| !path.as_os_str().is_empty()) {
        fs::create_dir_all(parent)
            .with_context(|| format!("create Lineage database directory {}", parent.display()))?;
    }
    if Storage::open(db)?.commit_exists(revision)? {
        return Ok(());
    }
    let provider = GitProvider::open(repo)?;
    let storage = Storage::open(db)?;
    LineageEngine::new(provider, HeuristicExtractor::default(), storage).run(Some(1))?;
    if !Storage::open(db)?.commit_exists(revision)? {
        anyhow::bail!("could not index selected revision {revision}");
    }
    Storage::open(db)?.refresh_ui_summaries()?;
    Ok(())
}

fn execute_diff(mut request: DiffCommandRequest) -> Result<String> {
    let provider = GitProvider::open(&request.repo)?;
    resolve_diff_run_scope(&provider, &mut request)?;
    let storage = request
        .db
        .exists()
        .then(|| Storage::open_existing(&request.db))
        .transpose()?;
    let plan = build_structured_diff(
        &provider,
        storage.as_ref(),
        &DiffRequest {
            base_revision: request.base,
            head_revision: request.head,
            coverage_source: request.coverage_source,
            sarif_source: request.sarif_source,
            selection: request.selection,
            mutant_corpus: request.mutant_corpus,
            test_set: request.test_set,
        },
    )?;
    match request.format {
        DiffFormat::Text => Ok(render_structured_diff_text(&plan, request.full)),
        DiffFormat::Json => Ok(format!("{}\n", render_structured_diff_json(&plan)?)),
    }
}

fn resolve_diff_run_scope(provider: &GitProvider, request: &mut DiffCommandRequest) -> Result<()> {
    let supplied = [
        request.selection.is_some(),
        request.mutant_corpus.is_some(),
        request.test_set.is_some(),
    ];
    if supplied.iter().any(|present| *present) && !supplied.iter().all(|present| *present) {
        anyhow::bail!("--selection, --mutant-corpus, and --test-set must be supplied together");
    }
    let explicit_scope = supplied.iter().all(|present| *present);
    let config_path = request.repo.join(lineage::pipeline::CONFIG_FILE_NAME);
    let json_config_path = request.repo.join(lineage::pipeline::CONFIG_JSON_FILE_NAME);
    if !config_path.exists() && !json_config_path.exists() {
        return Ok(());
    }
    let config = load_config(&request.repo)?;
    let manifest_path = latest_run_directory(&request.repo, &config).join("manifest.json");
    if !manifest_path.exists() {
        return Ok(());
    }
    let manifest = load_run_manifest(&manifest_path)?;
    let head = provider.resolve_commit(request.head.as_deref().unwrap_or("HEAD"))?;
    if manifest.status != RunStatus::Succeeded
        || manifest.revision != head
        || (!manifest.tree_fingerprint.is_empty() && manifest.tree_fingerprint != head)
    {
        return Ok(());
    }
    let scopes = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.complete)
        .filter_map(|artifact| artifact.evidence_scope.as_ref())
        .collect::<Vec<_>>();
    let Some(scope) = scopes.first() else {
        return Ok(());
    };
    if scopes.iter().any(|candidate| *candidate != *scope) {
        anyhow::bail!("latest successful run contains incompatible complete evidence scopes");
    }
    if !explicit_scope {
        request.selection = Some(scope.selection.clone());
        request.mutant_corpus = Some(scope.mutant_corpus.clone());
        request.test_set = Some(scope.test_set.clone());
    }
    let coverage_sources = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Coverage)
        .map(|artifact| artifact.producer.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if request.coverage_source.is_none() && coverage_sources.len() > 1 {
        anyhow::bail!("latest successful run has multiple coverage producers; specify --coverage-source");
    }
    if request.coverage_source.is_none() {
        request.coverage_source = coverage_sources.into_iter().next().map(str::to_string);
    }
    let sarif_sources = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Sarif)
        .map(|artifact| artifact.producer.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if request.sarif_source.is_none() && sarif_sources.len() > 1 {
        anyhow::bail!("latest successful run has multiple SARIF producers; specify --sarif-source");
    }
    if request.sarif_source.is_none() {
        request.sarif_source = sarif_sources.into_iter().next().map(str::to_string);
    }
    Ok(())
}

fn ingest_run_manifest(
    db: &std::path::Path,
    repo: &std::path::Path,
    manifest_path: &std::path::Path,
) -> Result<()> {
    let manifest = load_run_manifest(manifest_path)?;
    let git = GitProvider::open(repo)?;
    validate_manifest_provenance(repo, &git, &manifest)?;
    validate_manifest_artifact_batches(&manifest)?;
    let run_directory = manifest_path
        .parent()
        .context("run manifest has no parent directory")?;
    let storage = Storage::open(db)?;
    let extractor = HeuristicExtractor::default();
    let normalizer = RepoPathNormalizer::new(repo);
    let sarif_directory = std::env::temp_dir().join(format!(
        "lineage-sarif-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .context("system time precedes Unix epoch")?
            .as_nanos()
    ));
    fs::create_dir_all(&sarif_directory)?;
    let mut sarif_inputs = BTreeMap::<String, Vec<PathBuf>>::new();
    let mut sarif_scopes = BTreeMap::<String, Vec<(EvidenceScopeFingerprint, bool)>>::new();
    storage.begin_transaction()?;
    let result = (|| -> Result<()> {
        for (index, artifact) in manifest.artifacts.iter().enumerate() {
            let payload = read_manifest_artifact(run_directory, artifact)?;
            let evidence_scope = artifact_evidence_scope(artifact, &manifest.revision)?;
            match artifact.kind {
                ArtifactKind::Coverage => {
                    ingest_coverage_json_with_options(
                        &storage,
                        std::str::from_utf8(&payload)?,
                        &artifact.format,
                        &manifest.revision,
                        None,
                        true,
                        &CoverageIngestOptions {
                            line_source: artifact.producer.clone(),
                            evidence_scope: evidence_scope.clone(),
                            complete: artifact.complete,
                        },
                    )?;
                }
                ArtifactKind::Mutants => {
                    ingest_mutant_facts_json_with_options(
                        &storage,
                        &normalizer,
                        &git,
                        &extractor,
                        std::str::from_utf8(&payload)?,
                        &manifest.revision,
                        None,
                        evidence_scope
                            .clone()
                            .as_ref()
                            .map(|scope| scope.test_set.as_str())
                            .unwrap_or("unit"),
                        &MutantIngestOptions {
                            mutation_corpus: evidence_scope
                                .as_ref()
                                .map(|scope| scope.mutant_corpus.clone())
                                .unwrap_or_default(),
                            evidence_scope,
                            complete: artifact.complete,
                        },
                    )?;
            }
            ArtifactKind::Sarif => {
                let document: serde_json::Value = serde_json::from_slice(&payload).with_context(|| {
                    format!("parse SARIF artifact from producer {:?}", artifact.producer)
                })?;
                if document.get("version").and_then(serde_json::Value::as_str).is_none()
                    || document.get("runs").and_then(serde_json::Value::as_array).is_none()
                {
                    anyhow::bail!("producer {:?} emitted an invalid SARIF document", artifact.producer);
                }
                let unpacked = sarif_directory
                        .join(format!("{index}-{}", artifact.producer))
                        .with_extension("json");
                    fs::create_dir_all(
                        unpacked.parent().expect("unpacked artifact parent exists"),
                    )?;
                    fs::write(&unpacked, payload)?;
                    sarif_inputs
                        .entry(artifact.producer.clone())
                        .or_default()
                        .push(unpacked);
                    if let Some(scope) = evidence_scope {
                        sarif_scopes
                            .entry(artifact.producer.clone())
                            .or_default()
                            .push((scope, artifact.complete));
                    }
                }
            }
        }
        for (source, inputs) in sarif_inputs {
            ingest_sarif_paths(
                &storage,
                repo,
                &inputs,
                &source,
                &manifest.revision,
                None,
                true,
            )?;
            if let Some((scope, complete)) = sarif_scopes
                .remove(&source)
                .unwrap_or_default()
                .into_iter()
                .next()
            {
                storage.record_evidence_artifact_scope(&EvidenceArtifactScope {
                    family: "sarif".into(),
                    source: source.clone(),
                    scope,
                    complete,
                    expected_lines: Default::default(),
                })?;
            }
        }
        Ok(())
    })();
    let cleanup_result = fs::remove_dir_all(&sarif_directory);
    match result {
        Ok(()) => storage.commit_transaction()?,
        Err(error) => {
            let _ = storage.rollback_transaction();
            return Err(error);
        }
    }
    cleanup_result.with_context(|| format!("remove temporary SARIF directory {}", sarif_directory.display()))?;
    println!(
        "ingested run {} with {} artifacts",
        manifest.revision,
        manifest.artifacts.len()
    );
    Ok(())
}

fn validate_manifest_provenance(
    repo: &std::path::Path,
    git: &GitProvider,
    manifest: &lineage::pipeline::RunManifest,
) -> Result<()> {
    if manifest.status != RunStatus::Succeeded {
        anyhow::bail!("only successful run manifests can be ingested");
    }
    if manifest.repository_identity.is_empty() || manifest.repository_identity != repository_identity(repo) {
        anyhow::bail!("run manifest was produced for a different repository");
    }
    let resolved = git.resolve_commit(&manifest.revision)?;
    if resolved != manifest.revision {
        anyhow::bail!("run manifest revision must be an immutable resolved commit hash");
    }
    if manifest.tree_fingerprint.is_empty() || manifest.tree_fingerprint != resolved {
        anyhow::bail!("run manifest tree fingerprint does not match its revision");
    }
    Ok(())
}

fn validate_manifest_artifact_batches(manifest: &lineage::pipeline::RunManifest) -> Result<()> {
    let mut batches =
        BTreeMap::<(String, ArtifactKind), Vec<&lineage::pipeline::ManifestArtifact>>::new();
    for artifact in &manifest.artifacts {
        batches
            .entry((artifact.producer.clone(), artifact.kind))
            .or_default()
            .push(artifact);
    }
    for ((producer, kind), artifacts) in batches {
        let first = artifacts[0];
        if artifacts.iter().any(|artifact| {
            artifact.complete != first.complete || artifact.evidence_scope != first.evidence_scope
        }) {
            anyhow::bail!(
                "producer {producer:?} has incompatible scope or completeness declarations for {kind:?} artifacts"
            );
        }
        if matches!(kind, ArtifactKind::Coverage | ArtifactKind::Mutants) && artifacts.len() != 1 {
            anyhow::bail!(
                "producer {producer:?} emits {} {kind:?} artifacts; shard merging is not yet supported, configure one merged artifact",
                artifacts.len()
            );
        }
    }
    Ok(())
}

fn artifact_evidence_scope(
    artifact: &lineage::pipeline::ManifestArtifact,
    revision: &str,
) -> Result<Option<EvidenceScopeFingerprint>> {
    let scope = artifact.evidence_scope.as_ref();
    if artifact.complete && scope.is_none() {
        anyhow::bail!(
            "complete artifact from producer {:?} lacks evidence_scope",
            artifact.producer
        );
    }
    Ok(scope.map(|scope| EvidenceScopeFingerprint {
        revision: revision.into(),
        selection: scope.selection.clone(),
        mutant_corpus: scope.mutant_corpus.clone(),
        test_set: scope.test_set.clone(),
    }))
}

fn print_json_summary(units: &[lineage::UnitSummary]) {
    print!("[");
    for (index, unit) in units.iter().enumerate() {
        if index > 0 {
            print!(",");
        }
        print!(
            "{{\"id\":\"{}\",\"name\":\"{}\",\"kind\":\"{}\",\"original_path\":\"{}\",\"current_path\":\"{}\",\"total_events\":{},\"changes\":{},\"moves\":{},\"fixes\":{},\"risk_score\":{:.6},\"current_distinct_tests\":{},\"current_test_types\":\"{}\",\"current_mutant_verified_tests\":{},\"current_mutant_killed_tests\":{},\"last_test_exposure_at\":{},\"last_mutant_run_at\":{},\"latest_fix_at\":{},\"latest_change_at\":{},\"fixes_after_test_exposure\":{},\"changes_after_test_exposure\":{},\"semantic_changes_after_mutant_run\":{},\"verification_stale_seconds\":{},\"verification_staleness_score\":{:.6},\"reopened_count\":{}}}",
            json_escape(&unit.id),
            json_escape(&unit.name),
            json_escape(&unit.kind),
            json_escape(&unit.original_path),
            json_escape(&unit.current_path),
            unit.total_events,
            unit.changes,
            unit.moves,
            unit.fixes,
            unit.risk_score,
            unit.current_distinct_tests,
            json_escape(&unit.current_test_types),
            unit.current_mutant_verified_tests,
            unit.current_mutant_killed_tests,
            unit.last_test_exposure_at,
            unit.last_mutant_run_at,
            unit.latest_fix_at,
            unit.latest_change_at,
            unit.fixes_after_test_exposure,
            unit.changes_after_test_exposure,
            unit.semantic_changes_after_mutant_run,
            unit.verification_stale_seconds,
            unit.verification_staleness_score,
            unit.reopened_count
        );
    }
    println!("]");
}

fn normalize_test_type(value: &str) -> String {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect::<String>();
    let normalized = normalized
        .split('-')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if normalized.is_empty() {
        "unknown".to_string()
    } else {
        normalized
    }
}

fn default_coverage_test_id(test_type: &str, input: &std::path::Path) -> String {
    let path = input
        .to_string_lossy()
        .trim_start_matches("./")
        .replace('\\', "/");
    format!("{test_type}:{path}")
}

fn json_escape(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use lineage::pipeline::{DeclaredEvidenceScope, ManifestArtifact, RunManifest};
    use tempfile::tempdir;

    #[test]
    fn latest_successful_run_supplies_complete_diff_scope() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
        fs::write(directory.path().join("app.rb"), "puts :ok\n").unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(std::path::Path::new("app.rb")).unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        let revision = repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap()
            .to_string();
        fs::write(directory.path().join("lineage.yml"), "version: 1\n").unwrap();
        let config = load_config(directory.path()).unwrap();
        let latest = latest_run_directory(directory.path(), &config);
        fs::create_dir_all(&latest).unwrap();
        fs::write(
            latest.join("manifest.json"),
            serde_json::to_vec(&RunManifest {
                version: lineage::pipeline::RUN_MANIFEST_VERSION.into(),
                revision: revision.clone(),
                profile: "ci".into(),
                repository_identity: "example".into(),
                tree_fingerprint: revision.clone(),
                started_at_unix_ms: 1,
                duration_ms: 1,
                status: RunStatus::Succeeded,
                configuration_hash: "config".into(),
                producers: Vec::new(),
                artifacts: vec![ManifestArtifact {
                    producer: "coverage-ci".into(),
                    kind: ArtifactKind::Coverage,
                    format: "generic".into(),
                    path: "coverage.json".into(),
                    content_hash: "unused".into(),
                    compression: lineage::ArtifactCompression::None,
                    scope: None,
                    complete: true,
                    evidence_scope: Some(DeclaredEvidenceScope {
                        selection: "full".into(),
                        mutant_corpus: "corpus-v1".into(),
                        test_set: "unit".into(),
                    }),
                }],
            })
            .unwrap(),
        )
        .unwrap();
        let provider = GitProvider::open(directory.path()).unwrap();
        let mut request = DiffCommandRequest {
            repo: directory.path().to_path_buf(),
            db: directory.path().join("lineage.db"),
            base: None,
            head: Some(revision),
            format: DiffFormat::Text,
            full: true,
            coverage_source: None,
            sarif_source: None,
            selection: None,
            mutant_corpus: None,
            test_set: None,
        };

        resolve_diff_run_scope(&provider, &mut request).unwrap();

        assert_eq!(request.coverage_source.as_deref(), Some("coverage-ci"));
        assert_eq!(request.selection.as_deref(), Some("full"));
        assert_eq!(request.mutant_corpus.as_deref(), Some("corpus-v1"));
        assert_eq!(request.test_set.as_deref(), Some("unit"));
    }

    #[test]
    fn partial_diff_scope_override_is_rejected() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let provider = GitProvider::open(repository.path().parent().unwrap()).unwrap();
        let mut request = DiffCommandRequest {
            repo: directory.path().to_path_buf(),
            db: directory.path().join("lineage.db"),
            base: None,
            head: None,
            format: DiffFormat::Text,
            full: true,
            coverage_source: None,
            sarif_source: None,
            selection: Some("full".into()),
            mutant_corpus: None,
            test_set: None,
        };
        assert!(resolve_diff_run_scope(&provider, &mut request)
            .unwrap_err()
            .to_string()
            .contains("must be supplied together"));
    }

    #[test]
    fn diff_scope_resolution_does_not_require_configuration() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let provider = GitProvider::open(repository.path().parent().unwrap()).unwrap();
        let mut request = DiffCommandRequest {
            repo: directory.path().to_path_buf(),
            db: directory.path().join("lineage.db"),
            base: None,
            head: None,
            format: DiffFormat::Text,
            full: true,
            coverage_source: None,
            sarif_source: None,
            selection: None,
            mutant_corpus: None,
            test_set: None,
        };

        resolve_diff_run_scope(&provider, &mut request).unwrap();
        assert!(request.selection.is_none());
    }

    #[test]
    fn clean_worktree_check_ignores_only_configured_artifacts() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
        fs::write(directory.path().join("tracked.txt"), "tracked\n").unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(std::path::Path::new("tracked.txt")).unwrap();
        index.write().unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap();
        fs::create_dir_all(directory.path().join(".lineage/artifacts/runs")).unwrap();
        fs::write(
            directory.path().join(".lineage/artifacts/runs/manifest.json"),
            "{}",
        )
        .unwrap();
        let database = directory.path().join(".lineage/lineage.db");
        fs::write(&database, "sqlite").unwrap();

        ensure_clean_worktree(
            directory.path(),
            std::path::Path::new(".lineage/artifacts"),
            Some(&database),
        )
        .unwrap();
        fs::write(directory.path().join("unexpected.txt"), "dirty\n").unwrap();
        assert!(ensure_clean_worktree(directory.path(), std::path::Path::new(".lineage/artifacts"), None)
            .unwrap_err()
            .to_string()
            .contains("clean worktree"));
    }
}
