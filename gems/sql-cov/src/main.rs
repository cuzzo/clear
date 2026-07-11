use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use sql_cov::driver::sqlite_pool;
use sql_cov::hazard::analyze_hazards;
use sql_cov::reporter;
use sql_cov::sarif;
use sql_cov::schema::SchemaCatalog;
use sql_cov::{analyze_sql, cover_sqlite, execute_sqlite_setup, DialectName};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "sql-cov", about = "Expression-level three-valued SQL coverage")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Analyze {
        #[arg(long)]
        input: PathBuf,
        #[arg(long, default_value = "sqlite")]
        dialect: String,
        #[arg(long, default_value = "json")]
        format: String,
        #[arg(long)]
        output: Option<PathBuf>,
    },
    Run {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        setup: Option<PathBuf>,
        #[arg(long, default_value = "sqlite::memory:")]
        database: String,
        #[arg(long, default_value = "sqlite")]
        dialect: String,
        #[arg(long, default_value = "lcov")]
        format: String,
        #[arg(long)]
        output: Option<PathBuf>,
        #[arg(long = "param")]
        parameters: Vec<String>,
    },
    Hazards {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        setup: Option<PathBuf>,
        #[arg(long, default_value = "sqlite::memory:")]
        database: String,
        #[arg(long, default_value = "sqlite")]
        dialect: String,
        #[arg(long, default_value = "sarif")]
        format: String,
        #[arg(long)]
        output: Option<PathBuf>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Analyze {
            input,
            dialect,
            format,
            output,
        } => {
            let source = fs::read_to_string(&input)?;
            let analysis = analyze_sql(
                &input.to_string_lossy(),
                &source,
                DialectName::parse(&dialect)?,
            )?;
            let rendered = render(&analysis.coverage, &format)?;
            write_output(output, &rendered)?;
        }
        Command::Run {
            input,
            setup,
            database,
            dialect,
            format,
            output,
            parameters,
        } => {
            let dialect = DialectName::parse(&dialect)?;
            if dialect != DialectName::Sqlite {
                bail!("the initial execution driver supports SQLite; postgres parsing is available through analyze");
            }
            let source = fs::read_to_string(&input)?;
            let analysis = analyze_sql(&input.to_string_lossy(), &source, dialect)?;
            let pool = sqlite_pool(&database).await?;
            if let Some(setup) = setup {
                execute_sqlite_setup(&pool, &fs::read_to_string(&setup)?).await?;
            }
            let coverage = cover_sqlite(&pool, &analysis, &parameters).await?;
            let rendered = render(&coverage, &format)?;
            write_output(output, &rendered)?;
        }
        Command::Hazards {
            input,
            setup,
            database,
            dialect,
            format,
            output,
        } => {
            let dialect = DialectName::parse(&dialect)?;
            if dialect != DialectName::Sqlite {
                bail!("schema-aware hazard analysis currently supports SQLite");
            }
            let pool = sqlite_pool(&database).await?;
            if let Some(setup) = setup {
                execute_sqlite_setup(&pool, &fs::read_to_string(&setup)?).await?;
            }
            let schema = SchemaCatalog::load_sqlite(&pool).await?;
            if schema.tables.is_empty() {
                bail!("hazard analysis requires a populated SQLite schema; pass --setup or --database");
            }
            let source = fs::read_to_string(&input)?;
            let report = analyze_hazards(&input.to_string_lossy(), &source, dialect, &schema)?;
            let rendered = match format.as_str() {
                "sarif" => sarif::hazard_sarif(&report)?,
                "json" => sarif::hazard_json(&report)?,
                other => bail!("unsupported hazard format {other:?}; use sarif or json"),
            };
            write_output(output, &rendered)?;
        }
    }
    Ok(())
}

fn render(coverage: &sql_cov::SourceFileCoverage, format: &str) -> Result<String> {
    match format {
        "json" => reporter::json(coverage),
        "lcov" | "info" => Ok(reporter::lcov(coverage)),
        "html" => Ok(reporter::html(coverage)),
        other => bail!("unsupported output format {other:?}; use json, lcov, or html"),
    }
}

fn write_output(output: Option<PathBuf>, rendered: &str) -> Result<()> {
    if let Some(path) = output {
        fs::write(&path, rendered).with_context(|| format!("write {}", path.display()))?;
    } else {
        print!("{rendered}");
    }
    Ok(())
}
