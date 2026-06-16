mod decomplex;

use anyhow::{bail, Context, Result};
use decomplex::detectors::co_update;
use std::path::PathBuf;

fn main() -> Result<()> {
    let command = parse_args(std::env::args().skip(1).collect())?;
    match command {
        Command::StateWrites { language, files } => {
            if language != "ruby" {
                bail!("state-writes currently supports --language ruby only");
            }
            let facts = co_update::state_writes_for_files(&files)
                .with_context(|| "failed to extract state-write facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
    }
    Ok(())
}

enum Command {
    StateWrites { language: String, files: Vec<PathBuf> },
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut cursor = args.into_iter();
    let Some(command) = cursor.next() else {
        bail!("usage: decomplex-rust state-writes --language ruby FILE...");
    };
    match command.as_str() {
        "state-writes" => {
            let mut language = String::from("ruby");
            let mut files = Vec::new();
            while let Some(arg) = cursor.next() {
                if arg == "--language" {
                    language = cursor
                        .next()
                        .with_context(|| "--language requires a value")?;
                } else if let Some(value) = arg.strip_prefix("--language=") {
                    language = value.to_string();
                } else {
                    files.push(PathBuf::from(arg));
                }
            }
            if files.is_empty() {
                bail!("state-writes requires at least one file");
            }
            Ok(Command::StateWrites { language, files })
        }
        _ => bail!("unknown decomplex-rust command: {command}"),
    }
}
