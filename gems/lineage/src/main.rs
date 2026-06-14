use anyhow::Result;
use clap::{Parser, Subcommand};
use lineage::{GitProvider, HeuristicExtractor, LineageEngine, Storage};
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
                        "{:>2}. {:<10} {:<32} {:<48} risk={:.1} fixes={} changes={} moves={} events={}",
                        index + 1,
                        unit.kind,
                        unit.name,
                        unit.current_path,
                        unit.risk_score,
                        unit.fixes,
                        unit.changes,
                        unit.moves,
                        unit.total_events
                    );
                }
            }
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
            "{{\"id\":\"{}\",\"name\":\"{}\",\"kind\":\"{}\",\"original_path\":\"{}\",\"current_path\":\"{}\",\"total_events\":{},\"changes\":{},\"moves\":{},\"fixes\":{},\"risk_score\":{:.6}}}",
            json_escape(&unit.id),
            json_escape(&unit.name),
            json_escape(&unit.kind),
            json_escape(&unit.original_path),
            json_escape(&unit.current_path),
            unit.total_events,
            unit.changes,
            unit.moves,
            unit.fixes,
            unit.risk_score
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
