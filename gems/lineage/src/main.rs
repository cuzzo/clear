use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use lineage::{
    build_structured_diff, coverage_records_to_test_exposure_json, ingest_architecture_json,
    ingest_coverage_json_with_options, ingest_hazards, ingest_hotness_json,
    ingest_mutant_facts_json_with_options, ingest_sarif_paths, ingest_stack_traces,
    ingest_test_exposure_json, latest_run_directory, load_config, load_config_contents,
    load_run_manifest, parse_coverage_input, publish_run, read_manifest_artifact,
    render_structured_diff_json, render_structured_diff_text, repository_identity,
    resolve_coverage_record_paths, seal_published_run, serve_lsp, serve_mcp,
    serve_ui_with_overlays, validate_run_artifacts, ArtifactKind, CoverageIngestOptions,
    DiffRequest, EvidenceArtifactScope, EvidenceScopeFingerprint, GitProvider, HeuristicExtractor,
    LanguageNormalizer, LineageEngine, MutantIngestOptions, ProfileExecutionSession,
    ProfileRunKind, RepoPathNormalizer, RunStatus, SentryProvider, Storage,
};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
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
    /// Run the local static-analysis profile and stage a versioned analysis run.
    #[command(alias = "analyze")]
    Analyse {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = "analyse")]
        profile: String,
        /// Ingest a clean immutable-revision analysis run into lineage.db.
        #[arg(long)]
        ingest: bool,
        /// Explicitly authorize commands from the checkout's lineage.yml.
        /// Without this flag, analysis uses only Lineage's embedded,
        /// allowlisted providers.
        #[arg(long)]
        trust_current_config: bool,
    },
    /// Run a configured verification profile, stage its artifacts, and ingest them.
    Ci {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".lineage/lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = "ci")]
        profile: String,
        /// Read producer commands from this reviewed commit instead of the
        /// current checkout. Defaults to HEAD^; use --trust-current-config to
        /// explicitly authorize a newly introduced or changed configuration.
        #[arg(long)]
        config_revision: Option<String>,
        /// Explicitly authorize executing lineage.yml from the current clean
        /// checkout. Intended only for trusted local runs and protected CI.
        #[arg(long)]
        trust_current_config: bool,
        /// Fail unless every artifact declared by the selected profile is
        /// explicitly marked complete.
        #[arg(long)]
        require_complete: bool,
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
        /// Refresh Lineage's bundled source analysis before rendering.
        #[arg(long)]
        analyse: bool,
        /// Explicitly authorize checkout lineage.yml commands for --analyse.
        /// The default runs only embedded, allowlisted analysis.
        #[arg(long)]
        trust_current_config: bool,
        /// Require the latest successful evidence run for this profile to
        /// match the selected immutable revision and current configuration.
        #[arg(long)]
        require_profile: Option<String>,
        /// Require every declared artifact in --require-profile to be complete.
        #[arg(long)]
        require_complete: bool,
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
    analyse: bool,
    trust_current_config: bool,
    require_profile: Option<String>,
    require_complete: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Analyse {
            repo,
            db,
            profile,
            ingest,
            trust_current_config,
        } => {
            let db = repository_path(&repo, &db);
            let config = analysis_config(&repo, &profile, trust_current_config)?;
            let git = GitProvider::open(&repo)?;
            let revision = if ingest {
                ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
                git.resolve_commit("HEAD")?
            } else {
                lineage::git::WORKTREE_REVISION.into()
            };
            let execution = ProfileExecutionSession::begin(&repo, &config)?;
            let completed =
                execution.execute(&profile, &revision, ProfileRunKind::StandaloneAnalysis)?;
            if ingest {
                ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
                ensure_revision_snapshot(&db, &repo, &revision)?;
                ingest_run_manifest(&db, &repo, &completed.directory.join("manifest.json"))?;
                Storage::open(&db)?.refresh_ui_summaries()?;
                seal_published_run(&completed.directory)?;
            }
            println!(
                "lineage analyse: profile={} revision={} artifacts={} ingested={} run={}",
                profile,
                revision,
                completed.manifest.artifacts.len(),
                ingest,
                completed.directory.display(),
            );
        }
        Command::Ci {
            repo,
            db,
            profile,
            config_revision,
            trust_current_config,
            require_complete,
        } => {
            let db = repository_path(&repo, &db);
            let git = GitProvider::open(&repo)?;
            let config = load_ci_config(
                &repo,
                &git,
                config_revision.as_deref(),
                trust_current_config,
            )?;
            if require_complete {
                ensure_profile_declares_complete_artifacts(&config, &profile)?;
            }
            ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
            let execution = ProfileExecutionSession::begin(&repo, &config)?;
            reconcile_pending_publications(&repo, &config, &db)?;
            ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
            let revision = git.resolve_commit("HEAD")?;
            ensure_revision_snapshot(&db, &repo, &revision)?;
            let completed =
                execution.execute(&profile, &revision, ProfileRunKind::CiPublication)?;
            ensure_clean_worktree(&repo, &config.artifacts.directory, Some(&db))?;
            let run = completed.directory.join("manifest.json");
            write_publication_state(&completed.directory, PublicationState::Ingesting)?;
            record_run_state(&db, &run, "ingesting")?;
            ingest_run_manifest(&db, &repo, &run)?;
            write_publication_state(&completed.directory, PublicationState::Ingested)?;
            Storage::open(&db)?.refresh_ui_summaries()?;
            write_publication_state(&completed.directory, PublicationState::ReadyToPublish)?;
            publish_run(&repo, &config, &completed.directory)?;
            let published = latest_run_directory(&repo, &config);
            write_publication_state(&published, PublicationState::Published)?;
            seal_published_run(&published)?;
            record_run_state(&db, &published.join("manifest.json"), "published")?;
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
            analyse,
            trust_current_config,
            require_profile,
            require_complete,
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
                    analyse,
                    trust_current_config,
                    require_profile,
                    require_complete,
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

fn load_ci_config(
    repo: &Path,
    git: &GitProvider,
    requested_revision: Option<&str>,
    trust_current_config: bool,
) -> Result<lineage::LineageConfig> {
    if trust_current_config {
        if requested_revision.is_some() {
            anyhow::bail!("--trust-current-config and --config-revision cannot be used together");
        }
        return load_config(repo);
    }
    let revision = match requested_revision {
        Some(revision) => git.resolve_commit(revision)?,
        None => git.resolve_commit("HEAD^").with_context(|| {
            "lineage ci requires --config-revision or --trust-current-config when HEAD has no reviewed parent"
        })?,
    };
    let yaml = git.file_contents_at_commit(&revision, lineage::pipeline::CONFIG_FILE_NAME)?;
    let json = git.file_contents_at_commit(&revision, lineage::pipeline::CONFIG_JSON_FILE_NAME)?;
    match (yaml, json) {
        (Some(_), Some(_)) => anyhow::bail!(
            "trusted configuration revision {revision} contains both lineage.yml and lineage.json"
        ),
        (Some(contents), None) => load_config_contents(&contents, Some("yml")).with_context(|| {
            format!("parse trusted lineage.yml from configuration revision {revision}")
        }),
        (None, Some(contents)) => load_config_contents(&contents, Some("json")).with_context(|| {
            format!("parse trusted lineage.json from configuration revision {revision}")
        }),
        (None, None) => anyhow::bail!(
            "trusted configuration revision {revision} contains no lineage.yml; use --trust-current-config only after review"
        ),
    }
}

const PUBLICATION_STATE_FILE: &str = ".publication-state";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PublicationState {
    Ingesting,
    Ingested,
    ReadyToPublish,
    Published,
}

impl PublicationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ingesting => "ingesting",
            Self::Ingested => "ingested",
            Self::ReadyToPublish => "ready_to_publish",
            Self::Published => "published",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value.trim() {
            "ingesting" => Ok(Self::Ingesting),
            "ingested" => Ok(Self::Ingested),
            "ready_to_publish" => Ok(Self::ReadyToPublish),
            "published" => Ok(Self::Published),
            other => anyhow::bail!("invalid Lineage publication state {other:?}"),
        }
    }
}

fn write_publication_state(run_directory: &Path, state: PublicationState) -> Result<()> {
    use std::io::Write;

    let state_path = run_directory.join(PUBLICATION_STATE_FILE);
    let temporary = run_directory.join(format!(
        ".{PUBLICATION_STATE_FILE}.{}-{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .context("system time precedes Unix epoch")?
            .as_nanos()
    ));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(format!("{}\n", state.as_str()).as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, &state_path)?;
        #[cfg(unix)]
        fs::File::open(run_directory)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.with_context(|| {
        format!(
            "write Lineage publication state in {}",
            run_directory.display()
        )
    })
}

fn run_key(manifest_path: &Path) -> Result<String> {
    let directory = manifest_path
        .parent()
        .context("run manifest has no directory")?;
    directory
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| {
            name.trim_start_matches(".staging-")
                .trim_start_matches("pending-")
                .trim_start_matches("analysis-")
                .trim_start_matches("published-")
                .trim_start_matches("failed-")
                .to_string()
        })
        .context("run directory has no valid name")
}

fn unix_time_ms() -> Result<u128> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_millis())
}

fn record_run_state(db: &Path, manifest_path: &Path, state: &str) -> Result<()> {
    let manifest = load_run_manifest(manifest_path)?;
    Storage::open(db)?.record_ci_run(&run_key(manifest_path)?, &manifest, state, unix_time_ms()?)
}

fn publication_state(run_directory: &Path) -> Result<PublicationState> {
    let path = run_directory.join(PUBLICATION_STATE_FILE);
    let contents = fs::read_to_string(&path)
        .with_context(|| format!("read Lineage publication state {}", path.display()))?;
    PublicationState::parse(&contents)
}

/// Recovers unfinished publication after a crash. A `ready_to_publish` state
/// may be in either `pending-*` or `published-*`: the latter means the crash
/// occurred after the durable directory rename but before `latest` changed.
fn reconcile_pending_publications(
    repo: &Path,
    config: &lineage::LineageConfig,
    db: &Path,
) -> Result<()> {
    let runs = repo.join(&config.artifacts.directory).join("runs");
    if !runs.exists() {
        return Ok(());
    }
    let mut recoverable = fs::read_dir(&runs)?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("pending-") || name.starts_with("published-"))
        })
        .collect::<Vec<_>>();
    recoverable.sort();
    for run in recoverable {
        let is_published = run
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("published-"));
        let state = match publication_state(&run) {
            Ok(state) => state,
            Err(error)
                if !is_published
                    && error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound) =>
            {
                // A producer can finish and finalize its immutable staged
                // payload before the post-run clean-tree validation fails.
                // No publication state means ingestion was never authorized;
                // retain the forensic payload as a failed run instead of
                // making every later CI invocation unrecoverable.
                let name = run
                    .file_name()
                    .and_then(|name| name.to_str())
                    .context("pending Lineage run has no name")?;
                let failed = runs.join(format!("failed-{}", name.trim_start_matches("pending-")));
                fs::rename(&run, &failed).with_context(|| {
                    format!("quarantine incomplete Lineage run {}", run.display())
                })?;
                continue;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "recoverable Lineage run {} has no publication state",
                        run.display()
                    )
                })
            }
        };
        match state {
            PublicationState::Ingesting => {
                if is_published {
                    anyhow::bail!("published Lineage run {} is still ingesting", run.display());
                }
                ingest_run_manifest(db, repo, &run.join("manifest.json"))?;
                write_publication_state(&run, PublicationState::Ingested)?;
                Storage::open(db)?.refresh_ui_summaries()?;
                write_publication_state(&run, PublicationState::ReadyToPublish)?;
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::Ingested => {
                if is_published {
                    anyhow::bail!("published Lineage run {} is only ingested", run.display());
                }
                Storage::open(db)?.refresh_ui_summaries()?;
                write_publication_state(&run, PublicationState::ReadyToPublish)?;
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::ReadyToPublish => {
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::Published => {
                if !is_published {
                    anyhow::bail!(
                        "pending Lineage run {} is incorrectly marked published",
                        run.display()
                    );
                }
                let manifest = load_run_manifest(&run.join("manifest.json"))?;
                validate_run_artifacts(&run, &manifest)?;
                publish_run(repo, config, &run)?;
                record_run_state(db, &run.join("manifest.json"), "published")?;
            }
        }
    }
    Ok(())
}

fn ensure_clean_worktree(
    repo: &std::path::Path,
    artifact_directory: &std::path::Path,
    database: Option<&std::path::Path>,
) -> Result<()> {
    let repository_root = ProcessCommand::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(repo)
        .output()
        .context("resolve Git repository root for lineage ci")?;
    if !repository_root.status.success() {
        anyhow::bail!("could not resolve Git repository root for lineage ci");
    }
    let repository_root = PathBuf::from(String::from_utf8(repository_root.stdout)?.trim());
    let repository_prefix = repo
        .canonicalize()
        .context("canonicalize Lineage repository path")?
        .strip_prefix(&repository_root)
        .context("Lineage repository is outside its Git worktree")?
        .to_path_buf();
    let output = ProcessCommand::new("git")
        .args(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        .current_dir(repo)
        .output()
        .context("inspect Git worktree before lineage ci")?;
    if !output.status.success() {
        anyhow::bail!("could not inspect Git worktree before lineage ci");
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
    let dirty = porcelain_v1_dirty_paths(&output.stdout)?
        .into_iter()
        .find(|path| {
            path != &artifact_prefix
                && !path.starts_with(&format!("{artifact_prefix}/"))
                && database_path.as_deref() != Some(path)
                && !database_sidecars
                    .as_deref()
                    .is_some_and(|sidecars| sidecars.iter().any(|sidecar| sidecar == path))
        });
    if let Some(path) = dirty {
        anyhow::bail!("lineage ci requires a clean worktree (found {path})");
    }
    Ok(())
}

/// Parses `git status --porcelain=v1 -z` without relying on Git's quoted
/// display format. Rename and copy records contain a second NUL-delimited
/// source path, which must be inspected as well as the destination.
fn porcelain_v1_dirty_paths(output: &[u8]) -> Result<Vec<String>> {
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
    let analysis_overlay = if request.analyse {
        build_analysis_overlay(
            &request.repo,
            &provider,
            request.head.as_deref(),
            request.trust_current_config,
        )?
    } else {
        Vec::new()
    };
    if let Some(profile) = request.require_profile.as_deref() {
        ensure_required_profile(
            &request.repo,
            &request.db,
            &provider,
            request.head.as_deref(),
            profile,
            request.require_complete,
        )?;
    } else if request.require_complete {
        anyhow::bail!("--require-complete requires --require-profile");
    }
    resolve_diff_run_scope(&provider, &mut request)?;
    let full_report = request
        .full
        .then(|| configured_evidence_report(&request.repo, &provider, &request))
        .transpose()?;
    let storage = request
        .db
        .exists()
        .then(|| Storage::open_existing(&request.db))
        .transpose()?;
    let mut plan = build_structured_diff(
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
    if !analysis_overlay.is_empty() {
        lineage::diff::apply_head_only_sarif_findings(&mut plan, &analysis_overlay);
    }
    match request.format {
        DiffFormat::Text => {
            let mut rendered = render_structured_diff_text(&plan, request.full);
            if let Some(report) = full_report {
                rendered.push_str(&report);
            }
            Ok(rendered)
        }
        DiffFormat::Json => Ok(format!("{}\n", render_structured_diff_json(&plan)?)),
    }
}

fn build_analysis_overlay(
    repo: &Path,
    provider: &GitProvider,
    requested_head: Option<&str>,
    trust_current_config: bool,
) -> Result<Vec<lineage::diff::SarifObservation>> {
    let config = analysis_config(repo, "analyse", trust_current_config)?;
    let revision = if let Some(head) =
        requested_head.filter(|head| *head != lineage::git::WORKTREE_REVISION)
    {
        let resolved = provider.resolve_commit(head)?;
        if resolved != provider.resolve_commit("HEAD")? {
            anyhow::bail!(
                "diff --analyse can only execute the current checkout; checkout {resolved} before analysing a historical revision"
            );
        }
        ensure_clean_worktree(repo, &config.artifacts.directory, None)?;
        resolved
    } else {
        lineage::git::WORKTREE_REVISION.into()
    };
    let execution = ProfileExecutionSession::begin(repo, &config)?;
    let run = execution.execute("analyse", &revision, ProfileRunKind::StandaloneAnalysis)?;
    let observations = sarif_observations_from_run(repo, &run.directory, &run.manifest);
    let cleanup = fs::remove_dir_all(&run.directory)
        .with_context(|| format!("remove ephemeral analysis run {}", run.directory.display()));
    match (observations, cleanup) {
        (Ok(observations), Ok(())) => Ok(observations),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(cleanup_error)) => Err(error.context(format!(
            "also failed to clean analysis run: {cleanup_error:#}"
        ))),
    }
}

/// Returns only embedded, allowlisted analysis unless the caller explicitly
/// authorizes execution of checkout configuration. This distinction matters:
/// a repository's `lineage.yml` is arbitrary code when it contains command
/// producers, while the built-in provider is linked into this binary.
fn analysis_config(
    repo: &Path,
    profile: &str,
    trust_current_config: bool,
) -> Result<lineage::LineageConfig> {
    let yaml = repo.join(lineage::pipeline::CONFIG_FILE_NAME);
    let json = repo.join(lineage::pipeline::CONFIG_JSON_FILE_NAME);
    if trust_current_config {
        if !yaml.exists() && !json.exists() {
            if profile == "analyse" {
                return builtin_analysis_config();
            }
            anyhow::bail!(
                "analysis profile {profile:?} is not built in and no lineage.yml was found"
            );
        }
        let config = load_config(repo)?;
        if !config.profiles.contains_key(profile) {
            anyhow::bail!("unknown Lineage analysis profile {profile:?}");
        }
        return Ok(config);
    }
    if profile != "analyse" {
        anyhow::bail!(
            "analysis profile {profile:?} is repository configuration; pass --trust-current-config after review"
        );
    }
    builtin_analysis_config()
}

fn builtin_analysis_config() -> Result<lineage::LineageConfig> {
    use lineage::pipeline::{
        validate_config, EvidenceProducer, ProducerExecutor, VerificationProfile,
    };
    let producer_names = vec!["fact-mine".to_string()];
    let producers = BTreeMap::from([(
        "fact-mine".to_string(),
        EvidenceProducer {
            executor: ProducerExecutor::Lineage,
            argv: vec!["fact-mine-native".to_string()],
            working_directory: None,
            timeout_seconds: 60,
            max_output_bytes: 8 * 1024 * 1024,
            environment: BTreeMap::new(),
            produces: vec![lineage::pipeline::ProducedArtifact {
                kind: ArtifactKind::Sarif,
                format: "sarif".to_string(),
                path: PathBuf::from(".lineage/artifacts/fact-mine.sarif"),
                scope: Some("static".to_string()),
                complete: false,
                evidence_scope: None,
            }],
        },
    )]);
    validate_config(lineage::LineageConfig {
        version: 1,
        artifacts: Default::default(),
        profiles: BTreeMap::from([(
            "analyse".to_string(),
            VerificationProfile {
                producers: producer_names,
                required_evidence: Default::default(),
            },
        )]),
        producers,
    })
}

fn sarif_observations_from_run(
    repo: &Path,
    run_directory: &Path,
    manifest: &lineage::RunManifest,
) -> Result<Vec<lineage::diff::SarifObservation>> {
    let mut observations = Vec::new();
    for artifact in manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Sarif)
    {
        let document: serde_json::Value =
            serde_json::from_slice(&read_manifest_artifact(run_directory, artifact)?)?;
        for finding in lineage::normalize_sarif_document(repo, &document)? {
            let tier = finding
                .provenance
                .get("tier")
                .or_else(|| finding.provenance.get("risk_tier"))
                .and_then(|value| value.parse::<u8>().ok());
            observations.push(lineage::diff::SarifObservation {
                path: finding.path,
                finding: lineage::diff::SarifFindingSummary {
                    source: artifact.producer.clone(),
                    tool: finding.tool_name,
                    rule_id: finding.rule_id,
                    level: finding.level,
                    category: finding.category,
                    message: finding.message,
                    fingerprint: finding.fingerprint,
                    tier,
                    tier_one: tier == Some(1),
                    status: finding.status,
                    provenance: finding.provenance,
                    proof_boundary: finding.proof_boundary,
                    start_line: finding.start_line,
                    end_line: finding.end_line.unwrap_or(finding.start_line),
                },
            });
        }
    }
    Ok(observations)
}

/// `DiffPlan` is intentionally limited to the evidence it can join to changed
/// source lines. `--full` additionally reports every artifact family promised
/// by the selected profile so absent, partial, and stale configured evidence
/// is never silently omitted from the text view.
fn configured_evidence_report(
    repo: &Path,
    provider: &GitProvider,
    request: &DiffCommandRequest,
) -> Result<String> {
    let config_path = repo.join(lineage::pipeline::CONFIG_FILE_NAME);
    let json_path = repo.join(lineage::pipeline::CONFIG_JSON_FILE_NAME);
    if !config_path.exists() && !json_path.exists() {
        return Ok("Configured evidence: unconfigured (no lineage.yml)\n".into());
    }
    let config = load_config(repo)?;
    let profile_name = request
        .require_profile
        .as_deref()
        .or_else(|| config.profiles.contains_key("ci").then_some("ci"));
    let Some(profile_name) = profile_name else {
        return Ok("Configured evidence: unconfigured (no selected profile)\n".into());
    };
    let profile = config
        .profiles
        .get(profile_name)
        .context("selected Lineage profile is missing")?;
    let manifest_path = latest_run_directory(repo, &config).join("manifest.json");
    let manifest = manifest_path
        .exists()
        .then(|| load_run_manifest(&manifest_path))
        .transpose()?;
    let requested_head = request
        .head
        .as_deref()
        .filter(|head| *head != lineage::git::WORKTREE_REVISION)
        .map(|head| provider.resolve_commit(head))
        .transpose()?;
    let working_tree =
        request.head.is_none() || request.head.as_deref() == Some(lineage::git::WORKTREE_REVISION);
    let mut output = format!("Configured evidence ({profile_name}):\n");
    for required in &profile.required_evidence {
        let state = match manifest.as_ref() {
            None => "missing",
            Some(manifest) if manifest.status != RunStatus::Succeeded => "failed",
            Some(_) if working_tree => "stale",
            Some(manifest)
                if requested_head
                    .as_ref()
                    .is_some_and(|head| manifest.revision != *head) =>
            {
                "stale"
            }
            Some(manifest) => match manifest
                .artifacts
                .iter()
                .filter(|artifact| artifact.kind == *required)
                .map(|artifact| artifact.complete)
                .reduce(|left, right| left && right)
            {
                Some(true) => "exact",
                Some(false) => "partial",
                None => "missing",
            },
        };
        use std::fmt::Write;
        let _ = writeln!(output, "  {state:<9} {required:?}");
    }
    Ok(output)
}

fn ensure_profile_declares_complete_artifacts(
    config: &lineage::pipeline::LineageConfig,
    profile_name: &str,
) -> Result<()> {
    let profile = config
        .profiles
        .get(profile_name)
        .with_context(|| format!("unknown Lineage profile {profile_name:?}"))?;
    let declared = profile
        .producers
        .iter()
        .flat_map(|name| {
            config.producers[name]
                .produces
                .iter()
                .map(move |artifact| (name, artifact))
        })
        .filter(|(_, artifact)| artifact.kind != ArtifactKind::Auxiliary)
        .collect::<Vec<_>>();
    if declared.is_empty() {
        anyhow::bail!(
            "profile {profile_name:?} cannot satisfy --require-complete because it declares no evidence artifacts"
        );
    }
    let incomplete = declared.iter().find(|(_, artifact)| !artifact.complete);
    if let Some((producer, artifact)) = incomplete {
        anyhow::bail!(
            "profile {profile_name:?} cannot satisfy --require-complete: producer {producer:?} artifact {} is declared partial",
            artifact.path.display()
        );
    }
    for required in &profile.required_evidence {
        if !declared
            .iter()
            .any(|(_, artifact)| artifact.kind == *required)
        {
            anyhow::bail!(
                "profile {profile_name:?} cannot satisfy --require-complete: missing required {required:?} evidence"
            );
        }
    }
    Ok(())
}

fn ensure_required_profile(
    repo: &std::path::Path,
    db: &std::path::Path,
    provider: &GitProvider,
    requested_head: Option<&str>,
    profile_name: &str,
    require_complete: bool,
) -> Result<()> {
    if requested_head == Some(lineage::git::WORKTREE_REVISION) || requested_head.is_none() {
        anyhow::bail!(
            "--require-profile requires an explicit immutable head revision; working-tree evidence is not exact"
        );
    }
    let config = load_config(repo)?;
    if require_complete {
        ensure_profile_declares_complete_artifacts(&config, profile_name)?;
    }
    let manifest_path = latest_run_directory(repo, &config).join("manifest.json");
    let manifest = load_run_manifest(&manifest_path).with_context(|| {
        format!("--require-profile {profile_name:?} needs a successful latest Lineage run")
    })?;
    validate_run_artifacts(
        manifest_path
            .parent()
            .context("latest run has no directory")?,
        &manifest,
    )
    .context("--require-profile found a modified or corrupt published artifact")?;
    let record = Storage::open_existing(db)?
        .ci_run_record(&run_key(&manifest_path)?)?
        .context("--require-profile has no durable database run record")?;
    if record.state != "published"
        || record.manifest_hash != lineage::run_manifest_hash(&manifest)?
        || record.revision != manifest.revision
        || record.profile != manifest.profile
        || record.repository_identity != manifest.repository_identity
        || record.configuration_hash != manifest.configuration_hash
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} has a stale or modified durable database run record"
        );
    }
    let head = provider.resolve_commit(requested_head.expect("checked above"))?;
    if manifest.status != RunStatus::Succeeded
        || manifest.profile != profile_name
        || manifest.revision != head
        || manifest.tree_fingerprint != head
        || manifest.configuration_hash != lineage::pipeline::configuration_fingerprint(&config)?
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} was not satisfied by an exact successful run for {head}"
        );
    }
    if require_complete
        && manifest
            .artifacts
            .iter()
            .any(|artifact| artifact.kind != ArtifactKind::Auxiliary && !artifact.complete)
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} has a successful run, but it contains partial artifacts"
        );
    }
    Ok(())
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
    validate_run_artifacts(
        manifest_path
            .parent()
            .context("latest run has no directory")?,
        &manifest,
    )
    .context("latest Lineage run contains a modified or corrupt artifact")?;
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
        .filter_map(|artifact| {
            artifact
                .evidence_scope
                .as_ref()
                .map(|scope| (artifact.kind, scope))
        })
        .collect::<Vec<_>>();
    let Some((_, common_scope)) = scopes.first() else {
        return Ok(());
    };
    if scopes.iter().any(|(_, candidate)| {
        candidate.selection != common_scope.selection || candidate.test_set != common_scope.test_set
    }) {
        anyhow::bail!(
            "latest successful run contains incompatible complete evidence selection or test-set scopes"
        );
    }
    let mutant_corpora = scopes
        .iter()
        .filter(|(kind, _)| *kind == ArtifactKind::Mutants)
        .map(|(_, scope)| scope.mutant_corpus.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if mutant_corpora.len() > 1 {
        anyhow::bail!("latest successful run contains multiple complete mutation corpora; specify an explicit scope");
    }
    let inferred_mutant_corpus = mutant_corpora
        .into_iter()
        .next()
        .unwrap_or("not-applicable");
    if !explicit_scope {
        request.selection = Some(common_scope.selection.clone());
        request.mutant_corpus = Some(inferred_mutant_corpus.into());
        request.test_set = Some(common_scope.test_set.clone());
    }
    let coverage_sources = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Coverage)
        .map(|artifact| artifact.producer.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if request.coverage_source.is_none() && coverage_sources.len() > 1 {
        anyhow::bail!(
            "latest successful run has multiple coverage producers; specify --coverage-source"
        );
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
    // A profile normally has many independent SARIF producers. Leaving the
    // source unset deliberately asks DiffService to aggregate them, retaining
    // their honest partial/exact state instead of silently choosing one or
    // forcing users to repeat internal producer names.
    if request.sarif_source.is_none() && sarif_sources.len() == 1 {
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
                ArtifactKind::Auxiliary => {
                    // Auxiliary artifacts are immutable run provenance and
                    // producer hand-off inputs, not database evidence.
                }
                ArtifactKind::Coverage => {
                    let payload =
                        normalize_manifest_coverage_paths(&payload, &artifact.format, &normalizer)?;
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
                    let document: serde_json::Value = serde_json::from_slice(&payload)
                        .with_context(|| {
                            format!("parse SARIF artifact from producer {:?}", artifact.producer)
                        })?;
                    if document
                        .get("version")
                        .and_then(serde_json::Value::as_str)
                        .is_none()
                        || document
                            .get("runs")
                            .and_then(serde_json::Value::as_array)
                            .is_none()
                    {
                        anyhow::bail!(
                            "producer {:?} emitted an invalid SARIF document",
                            artifact.producer
                        );
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
        storage.record_ci_run(
            &run_key(manifest_path)?,
            &manifest,
            "ingested",
            unix_time_ms()?,
        )?;
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
    cleanup_result.with_context(|| {
        format!(
            "remove temporary SARIF directory {}",
            sarif_directory.display()
        )
    })?;
    println!(
        "ingested run {} with {} artifacts",
        manifest.revision,
        manifest.artifacts.len()
    );
    Ok(())
}

/// SimpleCov records absolute filenames. Convert those filenames at the
/// manifest boundary, where the selected project root is known, before the
/// generic coverage parser applies its intentionally repository-agnostic
/// normalization. This keeps nested projects (`--repo gems/test-miser`) from
/// being recorded under their enclosing monorepo prefix.
fn normalize_manifest_coverage_paths(
    payload: &[u8],
    format: &str,
    normalizer: &dyn LanguageNormalizer,
) -> Result<Vec<u8>> {
    if format != "simplecov" {
        return Ok(payload.to_vec());
    }
    let mut document: serde_json::Value = serde_json::from_slice(payload)
        .context("parse SimpleCov artifact while normalizing project-relative paths")?;
    let Some(resultsets) = document.as_object_mut() else {
        anyhow::bail!("SimpleCov artifact must be a JSON object");
    };
    for resultset in resultsets.values_mut() {
        let Some(coverage) = resultset
            .get_mut("coverage")
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        let mut normalized = serde_json::Map::new();
        for (path, value) in std::mem::take(coverage) {
            let path = normalizer.normalize_path(&path);
            if normalized.insert(path.clone(), value).is_some() {
                anyhow::bail!(
                    "SimpleCov artifact contains multiple paths that normalize to {path:?}"
                );
            }
        }
        *coverage = normalized;
    }
    serde_json::to_vec(&document).context("serialize normalized SimpleCov artifact")
}

fn validate_manifest_provenance(
    repo: &std::path::Path,
    git: &GitProvider,
    manifest: &lineage::pipeline::RunManifest,
) -> Result<()> {
    if manifest.status != RunStatus::Succeeded {
        anyhow::bail!("only successful run manifests can be ingested");
    }
    if manifest.repository_identity.is_empty()
        || manifest.repository_identity != repository_identity(repo)
    {
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
    use sha2::{Digest, Sha256};
    use tempfile::tempdir;

    #[test]
    fn normalizes_simplecov_paths_to_the_selected_subproject() {
        let payload = br#"{
          "Minitest": {
            "coverage": {
              "/tmp/checkout/gems/test-miser/lib/test_miser/report.rb": {"lines": [null, 1]},
              "/tmp/checkout/gems/test-miser/test/report_test.rb": {"lines": [null, 2]}
            }
          }
        }"#;
        let normalized = normalize_manifest_coverage_paths(
            payload,
            "simplecov",
            &RepoPathNormalizer::new("/tmp/checkout/gems/test-miser"),
        )
        .unwrap();
        let document: serde_json::Value = serde_json::from_slice(&normalized).unwrap();
        let coverage = document
            .pointer("/Minitest/coverage")
            .and_then(serde_json::Value::as_object)
            .unwrap();
        assert!(coverage.contains_key("lib/test_miser/report.rb"));
        assert!(coverage.contains_key("test/report_test.rb"));
        assert!(!coverage.keys().any(|path| path.contains("gems/test-miser")));
    }

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
        let coverage = b"{}";
        let sarif = b"{\"version\":\"2.1.0\",\"runs\":[]}";
        fs::write(latest.join("coverage.json"), coverage).unwrap();
        fs::write(latest.join("first.sarif"), sarif).unwrap();
        fs::write(latest.join("second.sarif"), sarif).unwrap();
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
                artifacts: vec![
                    ManifestArtifact {
                        producer: "coverage-ci".into(),
                        kind: ArtifactKind::Coverage,
                        format: "generic".into(),
                        path: "coverage.json".into(),
                        content_hash: hex::encode(Sha256::digest(coverage)),
                        compression: lineage::ArtifactCompression::None,
                        scope: None,
                        complete: true,
                        evidence_scope: Some(DeclaredEvidenceScope {
                            selection: "full".into(),
                            mutant_corpus: "corpus-v1".into(),
                            test_set: "unit".into(),
                        }),
                    },
                    ManifestArtifact {
                        producer: "first".into(),
                        kind: ArtifactKind::Sarif,
                        format: "sarif".into(),
                        path: "first.sarif".into(),
                        content_hash: hex::encode(Sha256::digest(sarif)),
                        compression: lineage::ArtifactCompression::None,
                        scope: None,
                        complete: true,
                        evidence_scope: Some(DeclaredEvidenceScope {
                            selection: "full".into(),
                            mutant_corpus: "not-applicable".into(),
                            test_set: "unit".into(),
                        }),
                    },
                    ManifestArtifact {
                        producer: "second".into(),
                        kind: ArtifactKind::Sarif,
                        format: "sarif".into(),
                        path: "second.sarif".into(),
                        content_hash: hex::encode(Sha256::digest(sarif)),
                        compression: lineage::ArtifactCompression::None,
                        scope: None,
                        complete: false,
                        evidence_scope: None,
                    },
                ],
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
            analyse: false,
            trust_current_config: false,
            require_profile: None,
            require_complete: false,
        };

        resolve_diff_run_scope(&provider, &mut request).unwrap();

        assert_eq!(request.coverage_source.as_deref(), Some("coverage-ci"));
        assert_eq!(request.selection.as_deref(), Some("full"));
        assert_eq!(request.mutant_corpus.as_deref(), Some("not-applicable"));
        assert_eq!(request.test_set.as_deref(), Some("unit"));
        assert!(request.sarif_source.is_none());
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
            analyse: false,
            trust_current_config: false,
            require_profile: None,
            require_complete: false,
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
            analyse: false,
            trust_current_config: false,
            require_profile: None,
            require_complete: false,
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
            directory
                .path()
                .join(".lineage/artifacts/runs/manifest.json"),
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
        assert!(ensure_clean_worktree(
            directory.path(),
            std::path::Path::new(".lineage/artifacts"),
            None
        )
        .unwrap_err()
        .to_string()
        .contains("clean worktree"));
    }

    #[test]
    fn parses_nul_porcelain_renames_and_unusual_names_without_display_quoting() {
        let output = b" M spaced name.rb\0R  renamed name.rb\0old name.rb\0?? quote\"and\tunicode-\xE2\x98\x83.rb\0";
        assert_eq!(
            porcelain_v1_dirty_paths(output).unwrap(),
            vec![
                "spaced name.rb",
                "renamed name.rb",
                "old name.rb",
                "quote\"and\tunicode-☃.rb",
            ]
        );
        assert!(porcelain_v1_dirty_paths(b"R  only-new\0").is_err());
    }

    #[test]
    fn publication_state_round_trips() {
        let directory = tempdir().unwrap();
        let run = directory.path().join("pending-run");
        fs::create_dir_all(&run).unwrap();
        write_publication_state(&run, PublicationState::Ingesting).unwrap();
        assert_eq!(
            publication_state(&run).unwrap(),
            PublicationState::Ingesting
        );
        write_publication_state(&run, PublicationState::ReadyToPublish).unwrap();
        assert_eq!(
            publication_state(&run).unwrap(),
            PublicationState::ReadyToPublish
        );
    }

    #[test]
    fn run_key_normalizes_each_durable_run_prefix() {
        let directory = tempfile::tempdir().unwrap();
        for prefix in ["pending-", "analysis-", "published-", "failed-"] {
            let manifest = directory
                .path()
                .join(format!("{prefix}stable-run/manifest.json"));
            std::fs::create_dir_all(manifest.parent().unwrap()).unwrap();
            assert_eq!(run_key(&manifest).unwrap(), "stable-run");
        }
    }
}
