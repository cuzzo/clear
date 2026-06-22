use anyhow::{bail, Context, Result};
use fact_mine_rust::syntax::Language;
use fact_mine_rust::syntax_oracle;
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
    let Command::SyntaxFacts { language, files } = parse_args(std::env::args().skip(1).collect())?;
    let language = Language::parse(&language)?;
    let facts = syntax_oracle::project_files(&files, language)
        .with_context(|| "failed to project syntax facts")?;
    println!("{}", serde_json::to_string(&facts)?);
    Ok(())
}

enum Command {
    SyntaxFacts {
        language: String,
        files: Vec<PathBuf>,
    },
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut language = "ruby".to_string();
    let mut files = Vec::new();
    let mut iter = args.into_iter();
    let command = iter.next().unwrap_or_default();
    if command != "syntax-facts" {
        bail!("usage: fact-mine-rust syntax-facts [--language ruby] FILE...");
    }

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
