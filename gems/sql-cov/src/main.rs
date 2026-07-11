use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use sql_cov::driver::{mysql_pool, postgres_pool, sqlite_pool};
use sql_cov::hazard::analyze_hazards;
use sql_cov::reporter;
use sql_cov::sarif;
use sql_cov::schema::SchemaCatalog;
use sql_cov::{
    analyze_sql, cover_mysql, cover_postgres, cover_sqlite, execute_mysql_setup,
    execute_postgres_setup, execute_sqlite_setup, DialectName,
};
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
        #[arg(long)]
        sqlfluff: bool,
        #[arg(long)]
        sqlfluff_sarif: Option<PathBuf>,
    },
    GenerateCheck {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        setup: Option<PathBuf>,
        #[arg(long, default_value = "sqlite::memory:")]
        database: String,
        #[arg(long, default_value = "sqlite")]
        dialect: String,
        #[arg(long)]
        id: String,
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
                None,
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
            let source = fs::read_to_string(&input)?;
            let setup = setup.map(fs::read_to_string).transpose()?;
            let (_analysis, coverage) = match dialect {
                DialectName::Sqlite => {
                    let pool = sqlite_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_sqlite_setup(&pool, setup).await?;
                    }
                    let schema = SchemaCatalog::load_sqlite(&pool).await.ok();
                    let analysis = analyze_sql(&input.to_string_lossy(), &source, dialect, schema.as_ref())?;
                    let coverage = cover_sqlite(&pool, &analysis, &parameters).await?;
                    (analysis, coverage)
                }
                DialectName::Postgres => {
                    let pool = postgres_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_postgres_setup(&pool, setup).await?;
                    }
                    let schema = SchemaCatalog::load_postgres(&pool).await.ok();
                    let analysis = analyze_sql(&input.to_string_lossy(), &source, dialect, schema.as_ref())?;
                    let coverage = cover_postgres(&pool, &analysis, &parameters).await?;
                    (analysis, coverage)
                }
                DialectName::Mysql => {
                    let pool = mysql_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_mysql_setup(&pool, setup).await?;
                    }
                    let schema = SchemaCatalog::load_mysql(&pool).await.ok();
                    let analysis = analyze_sql(&input.to_string_lossy(), &source, dialect, schema.as_ref())?;
                    let coverage = cover_mysql(&pool, &analysis, &parameters).await?;
                    (analysis, coverage)
                }
            };
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
            sqlfluff,
            sqlfluff_sarif,
        } => {
            let dialect_name = DialectName::parse(&dialect)?;
            let setup = setup.map(fs::read_to_string).transpose()?;
            let schema = match dialect_name {
                DialectName::Sqlite => {
                    let pool = sqlite_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_sqlite_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_sqlite(&pool).await?
                }
                DialectName::Postgres => {
                    let pool = postgres_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_postgres_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_postgres(&pool).await?
                }
                DialectName::Mysql => {
                    let pool = mysql_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_mysql_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_mysql(&pool).await?
                }
            };
            if schema.tables.is_empty() {
                bail!("hazard analysis requires a populated SQLite schema; pass --setup or --database");
            }
            let source = fs::read_to_string(&input)?;
            let report = analyze_hazards(&input.to_string_lossy(), &source, dialect_name, &schema)?;

            let mut sqlfluff_sarif_content = None;
            if let Some(path) = sqlfluff_sarif {
                sqlfluff_sarif_content = Some(fs::read_to_string(path)?);
            } else if sqlfluff {
                let sqlfluff_paths = vec![
                    "sqlfluff",
                    "/home/yahn/.sqlfluff-venv/bin/sqlfluff"
                ];
                let mut found_bin = None;
                for p in sqlfluff_paths {
                    if std::process::Command::new(p)
                        .arg("--version")
                        .output()
                        .is_ok()
                    {
                        found_bin = Some(p);
                        break;
                    }
                }

                if let Some(bin) = found_bin {
                    let output = std::process::Command::new(bin)
                        .args([
                            "lint",
                            "--dialect",
                            match dialect_name {
                                DialectName::Sqlite => "sqlite",
                                DialectName::Postgres => "postgres",
                                DialectName::Mysql => "mysql",
                            },
                            "--format",
                            "sarif",
                            &input.to_string_lossy()
                        ])
                        .output();
                    match output {
                        Ok(out) => {
                            let stdout = String::from_utf8_lossy(&out.stdout);
                            sqlfluff_sarif_content = Some(stdout.into_owned());
                        }
                        Err(e) => {
                            eprintln!("Warning: failed to execute sqlfluff lint: {}", e);
                        }
                    }
                } else {
                    eprintln!("Warning: sqlfluff binary not found in PATH or ~/.sqlfluff-venv/bin/");
                }
            }

            let rendered = match format.as_str() {
                "sarif" => sarif::hazard_sarif(&report, sqlfluff_sarif_content.as_deref())?,
                "json" => sarif::hazard_json(&report)?,
                other => bail!("unsupported hazard format {other:?}; use sarif or json"),
            };
            write_output(output, &rendered)?;
        }
        Command::GenerateCheck {
            input,
            setup,
            database,
            dialect,
            id,
        } => {
            let dialect_name = DialectName::parse(&dialect)?;
            let setup = setup.map(fs::read_to_string).transpose()?;
            let schema = match dialect_name {
                DialectName::Sqlite => {
                    let pool = sqlite_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_sqlite_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_sqlite(&pool).await?
                }
                DialectName::Postgres => {
                    let pool = postgres_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_postgres_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_postgres(&pool).await?
                }
                DialectName::Mysql => {
                    let pool = mysql_pool(&database).await?;
                    if let Some(setup) = &setup {
                        execute_mysql_setup(&pool, setup).await?;
                    }
                    SchemaCatalog::load_mysql(&pool).await?
                }
            };
            let source = fs::read_to_string(&input)?;
            let report = analyze_hazards(&input.to_string_lossy(), &source, dialect_name, &schema)?;
            
            let Some(finding) = report.findings.iter().find(|f| f.id == id) else {
                bail!("no hazard finding found in {} with id {}", input.to_string_lossy(), id);
            };

            let mut matched_targets = Vec::new();
            for ev in &finding.evidence {
                if ev.starts_with("schema declares ") && ev.ends_with(" nullable") {
                    let inner = &ev["schema declares ".len()..(ev.len() - " nullable".len())];
                    if let Some(dot_idx) = inner.find('.') {
                        let table = &inner[..dot_idx];
                        let col = &inner[dot_idx + 1..];
                        matched_targets.push((table.to_string(), col.to_string()));
                    }
                } else if ev.starts_with("outer join can synthesize NULL for ") {
                    let inner = &ev["outer join can synthesize NULL for ".len()..];
                    if let Some(dot_idx) = inner.find('.') {
                        let table = &inner[..dot_idx];
                        let col = &inner[dot_idx + 1..];
                        matched_targets.push((table.to_string(), col.to_string()));
                    }
                }
            }

            if matched_targets.is_empty() {
                println!("-- Finding ID: {}", finding.id);
                println!("-- Kind: {:?}", finding.kind);
                println!("-- Message: {}", finding.message);
                println!("-- Recommendation: {}", finding.recommendation);
                println!("-- No specific nullable table columns could be extracted from evidence: {:?}", finding.evidence);
                return Ok(());
            }

            println!("-- Finding ID: {}", finding.id);
            println!("-- Kind: {:?}", finding.kind);
            println!("-- Message: {}", finding.message);
            println!("-- Recommendation: {}", finding.recommendation);
            println!();

            for (table, col) in matched_targets {
                println!("-- Checking nullable column {}.{}", table, col);
                println!("SELECT COUNT(*) AS null_count FROM {} WHERE {} IS NULL;", table, col);
                println!();
                println!("-- If the check returns 0, you can safely make the column NOT NULL:");
                println!("-- PostgreSQL:");
                println!("--   ALTER TABLE {} ALTER COLUMN {} SET NOT NULL;", table, col);
                println!("-- MySQL / MariaDB:");
                println!("--   ALTER TABLE {} MODIFY {} <datatype> NOT NULL;", table, col);
                println!("-- SQLite:");
                println!("--   SQLite does not support altering column nullability directly.");
                println!("--   To apply the constraint, recreate the table with `NOT NULL` on `{}`.", col);
                println!();
            }
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
