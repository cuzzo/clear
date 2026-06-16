mod decomplex;

use anyhow::{bail, Context, Result};
use decomplex::detectors::{co_update, flay_similarity, predicate_alias};
use decomplex::syntax::Language;
use std::path::PathBuf;

fn main() -> Result<()> {
    let command = parse_args(std::env::args().skip(1).collect())?;
    match command {
        Command::StateWrites { language, files } => {
            let language = Language::parse(&language)?;
            let facts = co_update::state_writes_for_files(&files, language)
                .with_context(|| "failed to extract state-write facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::CoUpdate { language, files } => {
            let language = Language::parse(&language)?;
            let report = co_update::scan_files(&files, language)
                .with_context(|| "failed to scan co-update facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::PredicateAliases { language, files } => {
            let language = Language::parse(&language)?;
            let report = predicate_alias::scan_files(&files, language)
                .with_context(|| "failed to scan predicate-alias facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::FlaySimilarity {
            language,
            mass,
            fuzzy,
            files,
        } => {
            let language = Language::parse(&language)?;
            let findings = flay_similarity::scan_files(&files, language, mass, fuzzy)
                .with_context(|| "failed to scan structural similarity")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
    }
    Ok(())
}

enum Command {
    StateWrites { language: String, files: Vec<PathBuf> },
    CoUpdate { language: String, files: Vec<PathBuf> },
    PredicateAliases { language: String, files: Vec<PathBuf> },
    FlaySimilarity {
        language: String,
        mass: usize,
        fuzzy: usize,
        files: Vec<PathBuf>,
    },
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut cursor = args.into_iter();
    let Some(command) = cursor.next() else {
        bail!("usage: decomplex-rust state-writes --language ruby FILE...");
    };
    match command.as_str() {
        "state-writes" => {
            let (language, files) = parse_language_and_files(cursor.collect())?;
            if files.is_empty() {
                bail!("state-writes requires at least one file");
            }
            Ok(Command::StateWrites { language, files })
        }
        "co-update" => {
            let (language, files) = parse_language_and_files(cursor.collect())?;
            if files.is_empty() {
                bail!("co-update requires at least one file");
            }
            Ok(Command::CoUpdate { language, files })
        }
        "predicate-aliases" => {
            let (language, files) = parse_language_and_files(cursor.collect())?;
            if files.is_empty() {
                bail!("predicate-aliases requires at least one file");
            }
            Ok(Command::PredicateAliases { language, files })
        }
        "flay-similarity" => {
            let mut language = String::from("ruby");
            let mut mass = 32usize;
            let mut fuzzy = 1usize;
            let mut files = Vec::new();
            let mut rest = cursor.collect::<Vec<_>>().into_iter();
            while let Some(arg) = rest.next() {
                if arg == "--language" {
                    language = rest
                        .next()
                        .with_context(|| "--language requires a value")?;
                } else if let Some(value) = arg.strip_prefix("--language=") {
                    language = value.to_string();
                } else if arg == "--mass" {
                    mass = rest
                        .next()
                        .with_context(|| "--mass requires a value")?
                        .parse()
                        .with_context(|| "--mass must be an integer")?;
                } else if let Some(value) = arg.strip_prefix("--mass=") {
                    mass = value.parse().with_context(|| "--mass must be an integer")?;
                } else if arg == "--fuzzy" {
                    fuzzy = rest
                        .next()
                        .with_context(|| "--fuzzy requires a value")?
                        .parse()
                        .with_context(|| "--fuzzy must be an integer")?;
                } else if let Some(value) = arg.strip_prefix("--fuzzy=") {
                    fuzzy = value.parse().with_context(|| "--fuzzy must be an integer")?;
                } else {
                    files.push(PathBuf::from(arg));
                }
            }
            if files.is_empty() {
                bail!("flay-similarity requires at least one file");
            }
            Ok(Command::FlaySimilarity {
                language,
                mass,
                fuzzy,
                files,
            })
        }
        _ => bail!("unknown decomplex-rust command: {command}"),
    }
}

fn parse_language_and_files(args: Vec<String>) -> Result<(String, Vec<PathBuf>)> {
    let mut language = String::from("ruby");
    let mut files = Vec::new();
    let mut cursor = args.into_iter();
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
    Ok((language, files))
}
