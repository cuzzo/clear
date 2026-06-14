use anyhow::Result;
use clap::{Parser, Subcommand};
use lineage::{
    ingest_coverage_json, ingest_hazards, ingest_stack_traces, ingest_test_exposure_json,
    serve_lsp, serve_ui_with_overlays, GitProvider, HeuristicExtractor, LineageEngine,
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
    /// Initialize an empty lineage SQLite database.
    Init {
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
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
    /// Ingest aggregate coverage or mutation quality data for one commit.
    IngestCoverage {
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
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
    /// Ingest provider stack traces and anchor frames to logical units.
    Ingest {
        #[arg(long, default_value = "lineage.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long, default_value = "sentry")]
        provider: String,
        #[arg(long)]
        replace: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Init { db } => {
            Storage::open(&db)?;
            println!("initialized {}", db.display());
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
                        "{:>2}. {:<10} {:<32} {:<48} risk={:.1} fixes={} changes={} moves={} events={} tests={} mutant_killed={}/{}",
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
                        unit.current_mutant_verified_tests
                    );
                }
            }
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
        Command::IngestCoverage {
            db,
            input,
            format,
            commit,
            timestamp,
            replace,
        } => {
            let storage = Storage::open(&db)?;
            let payload = fs::read_to_string(&input)?;
            let stats =
                ingest_coverage_json(&storage, &payload, &format, &commit, timestamp, replace)?;
            println!(
                "ingested coverage: files={} units={} events={} line_events={} skipped_files={}",
                stats.files, stats.units, stats.events, stats.line_events, stats.skipped_files
            );
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
        Command::Ingest {
            db,
            repo,
            input,
            provider,
            replace,
        } => {
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

fn print_json_summary(units: &[lineage::UnitSummary]) {
    print!("[");
    for (index, unit) in units.iter().enumerate() {
        if index > 0 {
            print!(",");
        }
        print!(
            "{{\"id\":\"{}\",\"name\":\"{}\",\"kind\":\"{}\",\"original_path\":\"{}\",\"current_path\":\"{}\",\"total_events\":{},\"changes\":{},\"moves\":{},\"fixes\":{},\"risk_score\":{:.6},\"current_distinct_tests\":{},\"current_test_types\":\"{}\",\"current_mutant_verified_tests\":{},\"current_mutant_killed_tests\":{},\"last_test_exposure_at\":{},\"latest_fix_at\":{},\"latest_change_at\":{},\"fixes_after_test_exposure\":{},\"changes_after_test_exposure\":{}}}",
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
            unit.latest_fix_at,
            unit.latest_change_at,
            unit.fixes_after_test_exposure,
            unit.changes_after_test_exposure
        );
    }
    println!("]");
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
