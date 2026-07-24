use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use std::io::IsTerminal;
use gigasail::application::analyse::{execute as execute_analysis, AnalyseRequest};
#[cfg(test)]
use gigasail::application::ci::{
    publication_state, run_key, write_publication_state, PublicationState,
};
#[cfg(test)]
use gigasail::application::diff::resolve_diff_run_scope;
use gigasail::application::diff::{prepare as prepare_diff, DiffCommandRequest};
#[cfg(test)]
use gigasail::application::ingest::normalize_manifest_coverage_paths;
use gigasail::application::ingest::{ingest_run_manifest, validate_run_manifest_for_ingestion};
#[cfg(test)]
use gigasail::application::revision::ensure_profile_clean_worktree;
#[cfg(test)]
use gigasail::application::revision::{ensure_clean_worktree, porcelain_v1_dirty_paths};
use gigasail::application::revision::{ensure_revision_snapshot, repository_path};
use gigasail::{
    coverage_records_to_test_exposure_json, ingest_architecture_json,
    ingest_coverage_json_with_options, ingest_hazards, ingest_hotness_json,
    ingest_mutant_facts_json_with_options, ingest_sarif_paths, ingest_stack_traces,
    ingest_test_exposure_json, latest_run_directory, load_config, parse_coverage_input,
    render_structured_diff_json, render_structured_diff_text, resolve_coverage_record_paths,
    CoverageIngestOptions, EvidenceScopeFingerprint, GitProvider, HeuristicExtractor,
    LineageEngine, MutantIngestOptions, RepoPathNormalizer, SentryProvider, Storage,
};
use std::fs;
use std::path::PathBuf;

#[cfg(test)]
use gigasail::{ArtifactKind, RunStatus};

#[derive(Debug, Parser)]
#[command(name = "giga")]
#[command(about = "Track logical code-unit history across moves and refactors")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the local static-analysis profile and stage a versioned analysis run.
    /// `sync` is an alias; pass --ingest to persist the run into the database.
    #[command(alias = "analyze", alias = "sync")]
    Analyse {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long, default_value = "analyse")]
        profile: String,
        /// Ingest a clean immutable-revision analysis run into gigasail.db.
        #[arg(long)]
        ingest: bool,
        /// Explicitly authorize commands from the checkout's giga.yml.
        /// Without this flag, analysis uses only Gigasail's embedded,
        /// allowlisted providers.
        #[arg(long)]
        trust_current_config: bool,
    },
    /// Run a configured verification profile, stage its artifacts, and ingest them.
    #[command(alias = "check")]
    Ci {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long, default_value = "ci")]
        profile: String,
        /// Read producer commands from this reviewed commit instead of the
        /// current checkout. Defaults to HEAD^; use --trust-current-config to
        /// explicitly authorize a newly introduced or changed configuration.
        #[arg(long)]
        config_revision: Option<String>,
        /// Explicitly authorize executing giga.yml from the current clean
        /// checkout. Intended only for trusted local runs and protected CI.
        #[arg(long)]
        trust_current_config: bool,
        /// Fail unless every artifact declared by the selected profile is
        /// explicitly marked complete.
        #[arg(long)]
        require_complete: bool,
    },
    /// Watch HEAD and analyse+ingest ("ci then sync") each new commit,
    /// coordinating through the .giga/ lock so an MCP server or a second
    /// watcher never indexes the database at the same time.
    Watch {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long, default_value = "analyse")]
        profile: String,
        /// Seconds between HEAD polls.
        #[arg(long, default_value_t = 2)]
        interval: u64,
        /// Explicitly authorize commands from the checkout's giga.yml.
        #[arg(long)]
        trust_current_config: bool,
        /// Process the current HEAD once and exit instead of looping.
        #[arg(long)]
        once: bool,
    },
    /// Print a revision-pinned, evidence-aware architectural diff.
    Diff {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(value_name = "BASE")]
        base: Option<String>,
        #[arg(value_name = "HEAD")]
        head: Option<String>,
        /// Output format. Defaults to the interactive TUI on a terminal and to
        /// text when stdout is piped or redirected.
        #[arg(long, value_enum)]
        format: Option<DiffFormat>,
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
        /// Refresh Gigasail's bundled source analysis before rendering.
        #[arg(long)]
        analyse: bool,
        /// Explicitly authorize checkout giga.yml commands for --analyse.
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
    /// Initialize an empty gigasail SQLite database.
    Init {
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
    },
    /// Ingest a versioned Espalier architecture graph artifact.
    IngestArchitecture {
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long)]
        input: PathBuf,
    },
    /// Build gigasail data for a Git repository.
    Build {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long)]
        max_commits: Option<usize>,
    },
    /// Print the highest-risk logical units from a gigasail database.
    Summary {
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
    },
    /// Ingest aggregate coverage or mutation quality data for one commit.
    IngestCoverage {
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
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
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: Option<PathBuf>,
        /// Ingest a gigasail-run/v1 manifest. Defaults to .giga/artifacts/latest/manifest.json.
        #[arg(long)]
        run: Option<PathBuf>,
        #[arg(long)]
        latest_run: bool,
        #[arg(long, default_value = "sentry")]
        provider: String,
        #[arg(long)]
        replace: bool,
        /// Directly ingest a coverage, mutation, or SARIF artifact. This is
        /// independent of giga.yml and complements --run manifests.
        #[arg(long, value_enum)]
        kind: Option<DirectIngestKind>,
        /// Input encoding for --kind (for example cobertura, simplecov,
        /// mutant-facts, or sarif).
        #[arg(long)]
        format: Option<String>,
        /// Immutable commit that the direct artifact describes.
        #[arg(long)]
        commit: Option<String>,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        timestamp: Option<i64>,
        #[arg(long)]
        selection: Option<String>,
        #[arg(long)]
        mutant_corpus: Option<String>,
        #[arg(long)]
        test_set: Option<String>,
        #[arg(long)]
        complete: bool,
    },
    /// Serve gigasail.db to LLM coding agents over the Model Context Protocol.
    /// Omit --db to run DB-less (live disk facts only; see docs/agents/mcp.md).
    Mcp {
        #[arg(long)]
        db: Option<PathBuf>,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
    },
    /// Run the test producers a project declares in giga.yml, selected by stage
    /// and flags, then ingest coverage/mutation evidence. Thin orchestrator over
    /// the profile machinery - not a build system (see tuning-configs.md §12).
    Test {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        /// Only unit-tagged producers (evidence_scope.test_set == unit).
        #[arg(long)]
        unit: bool,
        /// Only integration-tagged producers.
        #[arg(long)]
        integration: bool,
        /// Only fuzz-tagged producers.
        #[arg(long)]
        fuzz: bool,
        /// Include mutation producers even if the stage default is off.
        #[arg(long)]
        mutants: bool,
        /// Skip coverage-only producers (mutation still runs if selected).
        #[arg(long = "no-cov")]
        no_cov: bool,
        /// Draw from the premerge stage (default: precommit).
        #[arg(long)]
        premerge: bool,
        /// Treat these repo-relative paths as the changed set (repeatable),
        /// instead of diffing git. Preview/testing which producers a change runs.
        #[arg(long = "changed")]
        changed: Vec<String>,
        /// Run affected packages' pre-test check gates (lint/format) before
        /// tests, overriding `review.checks_enabled`. `--no-checks` forces off.
        #[arg(long, overrides_with = "no_checks")]
        checks: bool,
        #[arg(long = "no-checks")]
        no_checks: bool,
        /// Print the resolved producer plan without running anything.
        #[arg(long)]
        dry_run: bool,
        /// Authorize running commands from the current checkout's giga.yml.
        #[arg(long)]
        trust_current_config: bool,
    },
    /// Resolve the project-graph affected set for a change and print it (text or
    /// JSON), running nothing. The general "changed files + declared graph ->
    /// affected work" primitive; feed the JSON to CI to gate its job matrix.
    Affected {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        /// Treat these repo-relative paths as the changed set (repeatable),
        /// instead of diffing git.
        #[arg(long = "changed")]
        changed: Vec<String>,
        /// Resolve for the premerge stage (adds premerge-only producers).
        #[arg(long)]
        premerge: bool,
        /// Output format.
        #[arg(long, value_enum, default_value_t = AffectedFormat::Text)]
        format: AffectedFormat,
        /// Authorize reading the current checkout's giga.yml.
        #[arg(long)]
        trust_current_config: bool,
    },
    /// Measure how long a change's new tests take and record it, so the diff
    /// Tests section can show a delta vs the recent baseline. Run in the
    /// background; the diff shows `[ PENDING ]` until it lands.
    TimeTests {
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        /// The tag the measured tests belong to (unit / integration / fuzz).
        #[arg(long, default_value = "unit")]
        test_set: String,
        /// Command that runs just the new tests (the project selects them).
        #[arg(long = "run")]
        run: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum AffectedFormat {
    Text,
    Json,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum DiffFormat {
    Text,
    Json,
    /// Launch the interactive terminal review UI.
    Tui,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum DirectIngestKind {
    Coverage,
    Mutants,
    Sarif,
}

impl From<DirectIngestKind> for gigasail::ingest_service::DirectArtifactKind {
    fn from(kind: DirectIngestKind) -> Self {
        match kind {
            DirectIngestKind::Coverage => Self::Coverage,
            DirectIngestKind::Mutants => Self::Mutants,
            DirectIngestKind::Sarif => Self::Sarif,
        }
    }
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
            let result = execute_analysis(AnalyseRequest {
                repo,
                db,
                profile,
                ingest,
                trust_current_config,
            })?;
            println!(
                "gigasail analyse: profile={} revision={} artifacts={} ingested={} run={}",
                result.profile,
                result.revision,
                result.artifact_count,
                result.ingested,
                result.run_directory.display(),
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
            let result = gigasail::application::ci::execute(gigasail::application::ci::CiRequest {
                repo,
                db,
                profile,
                config_revision,
                trust_current_config,
                require_complete,
            })?;
            println!(
                "gigasail ci: profile={} revision={} artifacts={}",
                result.profile, result.revision, result.artifact_count
            );
        }
        Command::Watch {
            repo,
            db,
            profile,
            interval,
            trust_current_config,
            once,
        } => {
            let db = repository_path(&repo, &db);
            gigasail::watch::run(gigasail::watch::WatchRequest {
                repo,
                db,
                profile,
                trust_current_config,
                interval: std::time::Duration::from_secs(interval),
                once,
            })?;
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
            // Default to the interactive TUI on a terminal; fall back to text
            // when piped so scripts keep a machine-readable default.
            let format = format.unwrap_or_else(|| {
                if std::io::stdout().is_terminal() {
                    DiffFormat::Tui
                } else {
                    DiffFormat::Text
                }
            });
            // If a `giga watch` is analysing exactly this commit, wait so the
            // diff renders complete evidence; a previously analysed commit shows
            // immediately. Applies to every output format.
            gigasail::cli::wait_for_in_flight_analysis(&repo, &db, head.as_deref());
            if format == DiffFormat::Tui {
                gigasail::cli::run_diff(&repo, &db, base, head, false, analyse, false)?;
                return Ok(());
            }
            let result = prepare_diff(DiffCommandRequest {
                repo,
                db,
                base,
                head,
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
            })?;
            match format {
                DiffFormat::Text => {
                    let mut output = render_structured_diff_text(&result.plan, full);
                    if let Some(report) = result.configured_evidence_report {
                        output.push_str(&report);
                    }
                    print!("{output}");
                }
                DiffFormat::Json => println!("{}", render_structured_diff_json(&result.plan)?),
                DiffFormat::Tui => unreachable!("handled above"),
            }
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
                    let big_o = if unit.big_o_time_status == "unknown"
                        && unit.big_o_space_status == "unknown"
                    {
                        String::new()
                    } else {
                        let t = if unit.big_o_time.is_empty() {
                            "?"
                        } else {
                            unit.big_o_time.as_str()
                        };
                        let s = if unit.big_o_space.is_empty() {
                            "?"
                        } else {
                            unit.big_o_space.as_str()
                        };
                        format!(
                            " big_o=time:{}({}) space:{}({})",
                            t, unit.big_o_time_status, s, unit.big_o_space_status,
                        )
                    };
                    println!(
                        "{:>2}. {:<10} {:<32} {:<48} risk={:.1} fixes={} changes={} moves={} events={} tests={} mutant_killed={}/{} stale_mutant_days={:.1} stale_changes={} reopened={}{}",
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
                        unit.reopened_count,
                        big_o,
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
                    "gigasail ingest-coverage",
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
            let payload = read_maybe_gzip(&input)?;
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
            let payload = read_maybe_gzip(&input)?;
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
            kind,
            format,
            commit,
            source,
            timestamp,
            selection,
            mutant_corpus,
            test_set,
            complete,
        } => {
            let db = repository_path(&repo, &db);
            if let Some(kind) = kind {
                if run.is_some() || latest_run {
                    anyhow::bail!("--kind cannot be combined with --run or --latest-run");
                }
                let input = repository_path(&repo, &input.context("--kind requires --input")?);
                let format = format.context("--kind requires --format")?;
                let git = GitProvider::open(&repo)?;
                let commit = git.resolve_commit(&commit.context("--kind requires --commit")?)?;
                gigasail::application::ingest::validate_direct_artifact(
                    kind.into(),
                    &input,
                    &format,
                )?;
                ensure_revision_snapshot(&db, &repo, &commit)?;
                let result = gigasail::application::ingest::ingest_direct_artifact(
                    gigasail::application::ingest::DirectArtifactIngest {
                        kind: kind.into(),
                        db: &db,
                        repo: &repo,
                        input: &input,
                        format: &format,
                        commit: &commit,
                        source,
                        timestamp,
                        selection,
                        mutant_corpus,
                        test_set,
                        complete,
                        replace,
                    },
                )?;
                match result {
                    gigasail::application::ingest::DirectIngestResult::Coverage(stats) => println!(
                        "ingested coverage: files={} units={} events={} line_events={} skipped_files={}",
                        stats.files, stats.units, stats.events, stats.line_events, stats.skipped_files
                    ),
                    gigasail::application::ingest::DirectIngestResult::Mutants(stats) => println!(
                        "ingested mutant facts: facts={} units={} quality_events={} exposure_events={} skipped_files={} skipped_facts={}",
                        stats.facts, stats.units, stats.quality_events, stats.exposure_events,
                        stats.skipped_files, stats.skipped_facts
                    ),
                    gigasail::application::ingest::DirectIngestResult::Sarif(stats) => println!(
                        "ingested SARIF: artifacts={} findings={} skipped_files={} skipped_results={}",
                        stats.artifacts, stats.findings, stats.skipped_files, stats.skipped_results
                    ),
                }
                Storage::open(&db)?.refresh_ui_summaries()?;
                return Ok(());
            }
            if format.is_some()
                || commit.is_some()
                || source.is_some()
                || timestamp.is_some()
                || selection.is_some()
                || mutant_corpus.is_some()
                || test_set.is_some()
                || complete
            {
                anyhow::bail!(
                    "--format, --commit, --source, --timestamp, scope flags, and --complete require --kind"
                );
            }
            if run.is_some() || latest_run || input.is_none() {
                let run = match run {
                    Some(run) => repository_path(&repo, &run),
                    None => latest_run_directory(&repo, &load_config(&repo)?).join("manifest.json"),
                };
                let manifest = validate_run_manifest_for_ingestion(&repo, &run)?;
                ensure_revision_snapshot(&db, &repo, &manifest.revision)?;
                let result = ingest_run_manifest(&db, &repo, &run)?;
                Storage::open(&db)?.refresh_ui_summaries()?;
                println!(
                    "ingested run {} with {} artifacts",
                    result.revision, result.artifact_count
                );
                return Ok(());
            }
            let input = repository_path(&repo, &input.expect("input checked above"));
            let storage = Storage::open(&db)?;
            let git = GitProvider::open(&repo)?;
            let extractor = HeuristicExtractor::default();
            let normalizer = RepoPathNormalizer::new(&repo);
            let payload = read_maybe_gzip(&input)?;
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
        Command::Mcp { db, repo } => {
            // Stdio protocol adapter over giga-core; needs an async runtime.
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            runtime.block_on(gigasail::serve_mcp(db, repo))?;
        }
        Command::Test {
            repo,
            db,
            unit,
            integration,
            fuzz,
            mutants,
            no_cov,
            premerge,
            changed,
            checks,
            no_checks,
            dry_run,
            trust_current_config,
        } => {
            let mut tags = Vec::new();
            if unit {
                tags.push("unit".to_string());
            }
            if integration {
                tags.push("integration".to_string());
            }
            if fuzz {
                tags.push("fuzz".to_string());
            }
            let stage = if premerge {
                gigasail::review::ReviewMode::Premerge
            } else {
                gigasail::review::ReviewMode::Precommit
            };
            let result = gigasail::application::test::execute(gigasail::application::test::TestRequest {
                repo,
                db,
                tags,
                mutants,
                no_cov,
                stage,
                changed_override: (!changed.is_empty()).then_some(changed),
                run_checks: if checks {
                    Some(true)
                } else if no_checks {
                    Some(false)
                } else {
                    None
                },
                trust_current_config,
                dry_run,
            })?;
            let forced = if result.mutation_forced {
                " (mutation added by --mutants)"
            } else {
                ""
            };
            if !result.checks.is_empty() {
                let verb = if result.dry_run { "would gate" } else { "gated" };
                println!("giga test checks ({verb}): {}", result.checks.join(", "));
            }
            if result.dry_run {
                println!("giga test plan{forced}: {}", result.producers.join(", "));
            } else {
                println!(
                    "giga test: ran [{}]{forced} for {}; {} artifact(s) ingested",
                    result.producers.join(", "),
                    result.revision.as_deref().unwrap_or(""),
                    result.artifact_count
                );
            }
        }
        Command::Affected {
            repo,
            changed,
            premerge,
            format,
            trust_current_config,
        } => {
            let stage = if premerge {
                gigasail::review::ReviewMode::Premerge
            } else {
                gigasail::review::ReviewMode::Precommit
            };
            let affected = gigasail::application::affected::execute(
                &repo,
                stage,
                (!changed.is_empty()).then_some(changed),
                trust_current_config,
            )?;
            match format {
                AffectedFormat::Json => {
                    let doc = serde_json::json!({
                        "mode": affected.mode,
                        "changed": affected.changed,
                        "packages": affected.packages,
                        "producers": affected.producers,
                        "checks": affected.checks,
                    });
                    println!("{}", serde_json::to_string_pretty(&doc)?);
                }
                AffectedFormat::Text => {
                    println!("mode: {}", affected.mode);
                    println!("packages: {}", affected.packages.join(", "));
                    println!("producers: {}", affected.producers.join(", "));
                    if !affected.checks.is_empty() {
                        println!("checks: {}", affected.checks.join(", "));
                    }
                }
            }
        }
        Command::TimeTests {
            repo,
            db,
            test_set,
            run,
        } => {
            let result = gigasail::application::time_tests::execute(&repo, &db, &test_set, &run)?;
            println!(
                "giga time-tests: {} new-test time {:.1}ms (±{:.1}, n={}) recorded for {}",
                result.test_set,
                result.mean_ms,
                result.stddev_ms,
                result.samples,
                &result.revision[..result.revision.len().min(9)],
            );
        }
    }
    Ok(())
}

/// Read a facts file, transparently gunzipping it when it is gzip-compressed
/// (magic `1f 8b`). Mutant/coverage/exposure artifacts are stored `.gz` to keep
/// the run store and CI uploads compact; ingestion should not care.
fn read_maybe_gzip(path: &std::path::Path) -> anyhow::Result<String> {
    let bytes = std::fs::read(path)?;
    if bytes.starts_with(&[0x1f, 0x8b]) {
        use std::io::Read;
        let mut out = String::new();
        flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut out)?;
        Ok(out)
    } else {
        Ok(String::from_utf8(bytes)?)
    }
}

fn print_json_summary(units: &[gigasail::UnitSummary]) {
    print!("[");
    for (index, unit) in units.iter().enumerate() {
        if index > 0 {
            print!(",");
        }
        print!(
            "{{\"id\":\"{}\",\"name\":\"{}\",\"kind\":\"{}\",\"original_path\":\"{}\",\"current_path\":\"{}\",\"total_events\":{},\"changes\":{},\"moves\":{},\"fixes\":{},\"risk_score\":{:.6},\"current_distinct_tests\":{},\"current_test_types\":\"{}\",\"current_mutant_verified_tests\":{},\"current_mutant_killed_tests\":{},\"last_test_exposure_at\":{},\"last_mutant_run_at\":{},\"latest_fix_at\":{},\"latest_change_at\":{},\"fixes_after_test_exposure\":{},\"changes_after_test_exposure\":{},\"semantic_changes_after_mutant_run\":{},\"verification_stale_seconds\":{},\"verification_staleness_score\":{:.6},\"reopened_count\":{},\"big_o_time\":\"{}\",\"big_o_time_status\":\"{}\",\"big_o_space\":\"{}\",\"big_o_space_status\":\"{}\"}}",
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
            unit.reopened_count,
            json_escape(&unit.big_o_time),
            json_escape(&unit.big_o_time_status),
            json_escape(&unit.big_o_space),
            json_escape(&unit.big_o_space_status),
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
    use gigasail::pipeline::{DeclaredEvidenceScope, ManifestArtifact, RunManifest};
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
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        fs::write(directory.path().join("app.rb"), "puts :ok\n").unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(std::path::Path::new("app.rb")).unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        let revision = repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap()
            .to_string();
        fs::write(directory.path().join("giga.yml"), "version: 1\n").unwrap();
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
                version: gigasail::pipeline::RUN_MANIFEST_VERSION.into(),
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
                        compression: gigasail::ArtifactCompression::None,
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
                        compression: gigasail::ArtifactCompression::None,
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
                        compression: gigasail::ArtifactCompression::None,
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
            db: directory.path().join("gigasail.db"),
            base: None,
            head: Some(revision),
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
            db: directory.path().join("gigasail.db"),
            base: None,
            head: None,
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
            db: directory.path().join("gigasail.db"),
            base: None,
            head: None,
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
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        fs::write(directory.path().join("tracked.txt"), "tracked\n").unwrap();
        let mut index = repository.index().unwrap();
        index.add_path(std::path::Path::new("tracked.txt")).unwrap();
        index.write().unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap();
        fs::create_dir_all(directory.path().join(".giga/artifacts/runs")).unwrap();
        fs::write(
            directory
                .path()
                .join(".giga/artifacts/runs/manifest.json"),
            "{}",
        )
        .unwrap();
        let database = directory.path().join(".giga/gigasail.db");
        fs::write(&database, "sqlite").unwrap();

        ensure_clean_worktree(
            directory.path(),
            std::path::Path::new(".giga/artifacts"),
            Some(&database),
        )
        .unwrap();
        fs::write(directory.path().join("unexpected.txt"), "dirty\n").unwrap();
        assert!(ensure_clean_worktree(
            directory.path(),
            std::path::Path::new(".giga/artifacts"),
            None
        )
        .unwrap_err()
        .to_string()
        .contains("clean worktree"));
    }

    #[test]
    fn clean_worktree_check_for_subproject_ignores_unrelated_monorepo_changes() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        let project = directory.path().join("gems/demo");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("tracked.rb"), "puts :ok\n").unwrap();
        let mut index = repository.index().unwrap();
        index
            .add_path(std::path::Path::new("gems/demo/tracked.rb"))
            .unwrap();
        index.write().unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap();

        fs::write(directory.path().join("unrelated.md"), "outside project\n").unwrap();
        assert!(
            ensure_clean_worktree(&project, std::path::Path::new(".giga/artifacts"), None)
                .is_ok()
        );

        fs::write(project.join("dirty.rb"), "puts :dirty\n").unwrap();
        assert!(
            ensure_clean_worktree(&project, std::path::Path::new(".giga/artifacts"), None)
                .unwrap_err()
                .to_string()
                .contains("gems/demo/dirty.rb")
        );
    }

    #[test]
    fn command_profiles_require_the_entire_monorepo_to_be_clean() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        let project = directory.path().join("gems/demo");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("tracked.rb"), "puts :ok\n").unwrap();
        let mut index = repository.index().unwrap();
        index
            .add_path(std::path::Path::new("gems/demo/tracked.rb"))
            .unwrap();
        index.write().unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        repository
            .commit(Some("HEAD"), &signature, &signature, "initial", &tree, &[])
            .unwrap();

        let config = gigasail::load_config_contents(
            "version: 1\nprofiles:\n  ci:\n    producers: [command]\nproducers:\n  command:\n    executor: command\n    argv: [true]\n",
            Some("yml"),
        )
        .unwrap();
        fs::write(directory.path().join("unrelated.md"), "outside project\n").unwrap();

        assert!(ensure_profile_clean_worktree(&project, &config, "ci", None)
            .unwrap_err()
            .to_string()
            .contains("unrelated.md"));
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
