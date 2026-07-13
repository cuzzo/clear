use anyhow::{bail, Context, Result};
use fact_mine_rust::parallel;
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use fact_mine_rust::syntax_oracle;
use std::fs;

use std::path::PathBuf;

fn main() -> Result<()> {
    let worker = std::thread::Builder::new()
        .name("fact-mine-rust".to_string())
        .stack_size(64 * 1024 * 1024)
        .spawn(run)
        .with_context(|| "failed to start fact-mine worker thread")?;

    match worker.join() {
        Ok(result) => result,
        Err(payload) => std::panic::resume_unwind(payload),
    }
}

fn run() -> Result<()> {
    let command = parse_args(std::env::args().skip(1).collect())?;
    match command {
        Command::SyntaxFacts { language, files } => {
            let language = Language::parse(&language)?;
            let facts = syntax_oracle::project_files(&files, language)
                .with_context(|| "failed to project syntax facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::Profile {
            profile,
            files,
            output,
            language_override,
        } => {
            let profile = match profile.as_str() {
                "espalier" => Profile::Espalier,
                "nil-kill" | "nil_kill" => Profile::NilKill,
                "trace-plan" | "trace_plan" => Profile::TracePlan,
                other => bail!(
                    "unsupported profile: {other}; use espalier, nil-kill, or trace-plan"
                ),
            };
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let all_outputs = parallel::map_ordered(&files, |file| {
                let lang = if let Some(language) = language_override {
                    language
                } else {
                    file.extension()
                        .and_then(|ext| ext.to_str())
                        .and_then(|ext| Language::for_extension(&ext.to_ascii_lowercase()))
                        .with_context(|| format!("cannot detect language for {}", file.display()))?
                };
                let document = syntax::parse_file(file.clone(), lang)?;
                Ok(profile::extract(&document, profile))
            })?;
            // Merge outputs across files (same shape as Ruby's per-file accumulation)
            let merged = profile::merge(all_outputs, profile);
            let json = serde_json::to_string_pretty(&merged)?;
            if let Some(ref output_path) = output {
                fs::write(output_path, json)?;
            } else {
                println!("{}", json);
            }
        }
    }
    Ok(())
}

enum Command {
    SyntaxFacts {
        language: String,
        files: Vec<PathBuf>,
    },
    Profile {
        profile: String,
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        language_override: Option<String>,
    },
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut iter = args.into_iter();
    let command = iter.next().unwrap_or_default();

    match command.as_str() {
        "syntax-facts" => {
            let mut language = "ruby".to_string();
            let mut files = Vec::new();
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--language" => {
                        language = iter.next().with_context(|| "--language requires a value")?;
                    }
                    other if other.starts_with("--") => bail!("unsupported option: {other}"),
                    path => files.push(PathBuf::from(path)),
                }
            }
            if files.is_empty() {
                bail!("syntax-facts requires at least one file");
            }
            Ok(Command::SyntaxFacts { language, files })
        }
        "profile" => {
            let profile = iter
                .next()
                .with_context(|| "usage: fact-mine-rust profile {espalier|nil-kill} FILE...")?;
            let mut output = None;
            let mut language_override = None;
            let mut files = Vec::new();
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--output" => {
                        output = Some(PathBuf::from(
                            iter.next().with_context(|| "--output requires a value")?,
                        ));
                    }
                    other if other.starts_with("--output=") => {
                        output = Some(PathBuf::from(other.strip_prefix("--output=").unwrap()));
                    }
                    "--language" => {
                        language_override =
                            Some(iter.next().with_context(|| "--language requires a value")?);
                    }
                    other if other.starts_with("--language=") => {
                        language_override =
                            Some(other.strip_prefix("--language=").unwrap().to_string());
                    }
                    other if other.starts_with("--") => bail!("unsupported option: {other}"),
                    path => files.push(PathBuf::from(path)),
                }
            }
            if files.is_empty() {
                bail!("profile requires at least one file");
            }
            Ok(Command::Profile {
                profile,
                files,
                output,
                language_override,
            })
        }
        other => bail!("usage: fact-mine-rust {{syntax-facts|profile}} FILE... (got: {other})"),
    }
}
