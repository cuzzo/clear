mod decomplex;

use anyhow::{bail, Context, Result};
use decomplex::detectors::{co_update, flay_similarity, predicate_alias};
use decomplex::parallel;
use decomplex::syntax::Language;
use std::path::PathBuf;

fn main() -> Result<()> {
    let command = parse_args(std::env::args().skip(1).collect())?;
    parallel::set_jobs_for_process(command.jobs())?;
    match command {
        Command::StateWrites { language, files, .. } => {
            let language = Language::parse(&language)?;
            let facts = co_update::state_writes_for_files(&files, language)
                .with_context(|| "failed to extract state-write facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::CoUpdate { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = co_update::scan_files(&files, language)
                .with_context(|| "failed to scan co-update facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::PredicateAliases { language, files, .. } => {
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
            ..
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
    StateWrites {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    CoUpdate {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    PredicateAliases {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    FlaySimilarity {
        language: String,
        mass: usize,
        fuzzy: usize,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
}

impl Command {
    fn jobs(&self) -> Option<usize> {
        match self {
            Self::StateWrites { jobs, .. }
            | Self::CoUpdate { jobs, .. }
            | Self::PredicateAliases { jobs, .. }
            | Self::FlaySimilarity { jobs, .. } => *jobs,
        }
    }
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut cursor = args.into_iter();
    let Some(command) = cursor.next() else {
        bail!("usage: decomplex-rust COMMAND [--language ruby] [--jobs N] FILE...");
    };
    match command.as_str() {
        "state-writes" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("state-writes requires at least one file");
            }
            Ok(Command::StateWrites {
                language,
                files,
                jobs,
            })
        }
        "co-update" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("co-update requires at least one file");
            }
            Ok(Command::CoUpdate {
                language,
                files,
                jobs,
            })
        }
        "predicate-aliases" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("predicate-aliases requires at least one file");
            }
            Ok(Command::PredicateAliases {
                language,
                files,
                jobs,
            })
        }
        "flay-similarity" => {
            let mut language = String::from("ruby");
            let mut mass = 32usize;
            let mut fuzzy = 1usize;
            let mut jobs = None;
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
                } else if arg == "--jobs" {
                    jobs = Some(parse_jobs(
                        rest.next().with_context(|| "--jobs requires a value")?,
                    )?);
                } else if let Some(value) = arg.strip_prefix("--jobs=") {
                    jobs = Some(parse_jobs(value.to_string())?);
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
                jobs,
            })
        }
        _ => bail!("unknown decomplex-rust command: {command}"),
    }
}

fn parse_language_files_and_jobs(args: Vec<String>) -> Result<(String, Vec<PathBuf>, Option<usize>)> {
    let mut language = String::from("ruby");
    let mut jobs = None;
    let mut files = Vec::new();
    let mut cursor = args.into_iter();
    while let Some(arg) = cursor.next() {
        if arg == "--language" {
            language = cursor
                .next()
                .with_context(|| "--language requires a value")?;
        } else if let Some(value) = arg.strip_prefix("--language=") {
            language = value.to_string();
        } else if arg == "--jobs" {
            jobs = Some(parse_jobs(
                cursor.next().with_context(|| "--jobs requires a value")?,
            )?);
        } else if let Some(value) = arg.strip_prefix("--jobs=") {
            jobs = Some(parse_jobs(value.to_string())?);
        } else {
            files.push(PathBuf::from(arg));
        }
    }
    Ok((language, files, jobs))
}

fn parse_jobs(value: String) -> Result<usize> {
    let jobs = value
        .parse::<usize>()
        .with_context(|| "--jobs must be an integer")?;
    if jobs == 0 {
        bail!("--jobs must be greater than zero");
    }
    Ok(jobs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_jobs_option() {
        let command = parse_args(vec![
            "co-update".to_string(),
            "--jobs=4".to_string(),
            "a.rb".to_string(),
        ])
        .expect("command");

        assert_eq!(command.jobs(), Some(4));
    }

    #[test]
    fn rejects_zero_jobs_option() {
        assert!(parse_args(vec![
            "co-update".to_string(),
            "--jobs=0".to_string(),
            "a.rb".to_string(),
        ])
        .is_err());
    }
}
