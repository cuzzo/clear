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
    EvidenceScopeFingerprint, GitProvider, HeuristicExtractor, LineageEngine, MutantIngestOptions,
    RepoPathNormalizer, SentryProvider, Storage,
};
use std::fs;
use std::path::PathBuf;

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
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = "ci")]
        profile: String,
    },
    /// Print a revision-pinned, evidence-aware architectural diff.
    Diff {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
    },
    /// Ingest a versioned Espalier architecture graph artifact.
    IngestArchitecture {
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
        #[arg(long)]
        input: PathBuf,
    },
    /// Build lineage data for a Git repository.
    Build {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
        #[arg(long)]
        max_commits: Option<usize>,
    },
    /// Print the highest-risk logical units from a lineage database.
    Summary {
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
    },
    /// Serve the local Lineage source and verification UI.
    Ui {
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
        #[arg(long, default_value = "lineage.db")]
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
            let config = load_config(&repo)?;
            let git = GitProvider::open(&repo)?;
            let revision = git.resolve_commit("HEAD")?;
            let manifest = execute_profile(&repo, &config, &profile, &revision)?;
            let run = latest_run_directory(&repo, &config).join("manifest.json");
            ingest_run_manifest(&db, &repo, &run)?;
            println!(
                "lineage ci: profile={} revision={} artifacts={}",
                profile,
                manifest.revision,
                manifest.artifacts.len()
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

fn execute_diff(request: DiffCommandRequest) -> Result<String> {
    let provider = GitProvider::open(&request.repo)?;
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

fn ingest_run_manifest(
    db: &std::path::Path,
    repo: &std::path::Path,
    manifest_path: &std::path::Path,
) -> Result<()> {
    let manifest = load_run_manifest(manifest_path)?;
    let run_directory = manifest_path
        .parent()
        .context("run manifest has no parent directory")?;
    let storage = Storage::open(db)?;
    let git = GitProvider::open(repo)?;
    let extractor = HeuristicExtractor::default();
    let normalizer = RepoPathNormalizer::new(repo);
    for artifact in &manifest.artifacts {
        let payload = read_manifest_artifact(run_directory, artifact)?;
        match artifact.kind {
            ArtifactKind::Coverage => {
                ingest_coverage_json_with_options(
                    &storage,
                    std::str::from_utf8(&payload)?,
                    &artifact.format,
                    &manifest.revision,
                    None,
                    true,
                    &CoverageIngestOptions::default(),
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
                    "unit",
                    &MutantIngestOptions::default(),
                )?;
            }
            ArtifactKind::Sarif => {
                let unpacked = run_directory
                    .join("unpacked")
                    .join(&artifact.path)
                    .with_extension("json");
                fs::create_dir_all(unpacked.parent().expect("unpacked artifact parent exists"))?;
                fs::write(&unpacked, payload)?;
                ingest_sarif_paths(
                    &storage,
                    repo,
                    &[unpacked],
                    &artifact.producer,
                    &manifest.revision,
                    None,
                    true,
                )?;
            }
        }
    }
    println!(
        "ingested run {} with {} artifacts",
        manifest.revision,
        manifest.artifacts.len()
    );
    Ok(())
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
