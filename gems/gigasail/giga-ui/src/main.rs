use anyhow::Result;
use clap::{Parser, Subcommand};
use giga_ui::{serve_lsp, serve_ui_with_overlays};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "giga-ui")]
#[command(about = "Gigasail web UI and language server (MCP moved to `giga mcp`)")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Serve the local Gigasail source and verification UI.
    Serve {
        #[arg(long, default_value = ".giga/gigasail.db")]
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
    /// Run the Gigasail language server over stdio.
    Lsp {
        #[arg(long, default_value = ".giga/gigasail.db")]
        db: PathBuf,
        #[arg(long, default_value = ".")]
        repo: PathBuf,
        #[arg(long = "overlay")]
        overlays: Vec<PathBuf>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve {
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
    }
    Ok(())
}
