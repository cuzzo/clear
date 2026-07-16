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
            scip_indexes,
            complexity_summaries,
        } => {
            let profile = match profile.as_str() {
                "espalier" => Profile::Espalier,
                "nil-kill" | "nil_kill" => Profile::NilKill,
                "trace-plan" | "trace_plan" => Profile::TracePlan,
                other => {
                    bail!("unsupported profile: {other}; use espalier, nil-kill, or trace-plan")
                }
            };
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let mut merged = build_profile(&files, language_override, profile)?;
            for index in scip_indexes {
                fact_mine_rust::scip::apply_json_file(&mut merged, &index)?;
            }
            for summary in complexity_summaries {
                fact_mine_rust::external_summary::apply_file(&mut merged, &summary)?;
            }
            let json = serde_json::to_string_pretty(&merged)?;
            if let Some(ref output_path) = output {
                fs::write(output_path, json)?;
            } else {
                println!("{}", json);
            }
        }
        Command::CallResolution {
            files,
            output,
            language_override,
            format,
            scip_indexes,
            complexity_summaries,
        } => {
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let mut merged = build_profile(&files, language_override, Profile::Espalier)?;
            for index in scip_indexes {
                fact_mine_rust::scip::apply_json_file(&mut merged, &index)?;
            }
            for summary in complexity_summaries {
                fact_mine_rust::external_summary::apply_file(&mut merged, &summary)?;
            }
            let rendered = match format.as_str() {
                "json" => serde_json::to_string_pretty(&merged.call_resolution_coverage)?,
                "text" => render_call_resolution(&merged.call_resolution_coverage),
                other => bail!("unsupported call-resolution format: {other}; use text or json"),
            };
            if let Some(ref output_path) = output {
                fs::write(output_path, rendered)?;
            } else {
                println!("{}", rendered);
            }
        }
    }
    Ok(())
}

fn build_profile(
    files: &[PathBuf],
    language_override: Option<Language>,
    selected_profile: Profile,
) -> Result<profile::ProfileOutput> {
    let all_outputs = parallel::map_ordered(files, |file| {
        let language = if let Some(language) = language_override {
            language
        } else {
            Language::for_path(file)
                .with_context(|| format!("cannot detect language for {}", file.display()))?
        };
        let document = syntax::parse_file(file.clone(), language)?;
        Ok(profile::extract(&document, selected_profile))
    })?;
    Ok(profile::merge(all_outputs, selected_profile))
}

fn render_call_resolution(coverage: &profile::CallResolutionCoverage) -> String {
    let mut lines = vec![
        "Call resolution coverage".to_string(),
        "Denominator: call sites inside emitted executable methods".to_string(),
        format!(
            "Parser call nodes: {}; not normalized: {}; normalized without identical parser span: {}",
            coverage.raw_parser_call_sites,
            coverage.raw_calls_not_normalized,
            coverage.normalized_calls_without_raw_span
        ),
        format!("Total observed call sites: {}", coverage.total_call_sites),
        format!("Eligible call sites: {}", coverage.eligible_call_sites),
        format!(
            "Outside executable functions: {}",
            coverage.outside_executable_function
        ),
        format!(
            "Exact project targets: {} ({:.2}%)",
            coverage.exact_project_targets, coverage.exact_project_target_percent
        ),
        format!(
            "Modeled without project target: {}",
            coverage.modeled_without_project_target
        ),
        format!("Accounted calls: {:.2}%", coverage.accounted_call_percent),
        format!(
            "Semantically accounted calls (including closed candidate domains): {} ({:.2}%)",
            coverage.semantically_accounted_call_sites,
            coverage.semantically_accounted_call_percent
        ),
        format!(
            "Unresolved call sites: {} ({:.2}%)",
            coverage.unresolved_call_sites, coverage.unresolved_call_percent
        ),
        format!(
            "Unresolved with project candidate sets: {}",
            coverage.calls_with_project_candidate_set
        ),
        format!(
            "Functions with unresolved calls: {}",
            coverage.functions_with_unresolved_calls
        ),
    ];
    if !coverage.by_language.is_empty() {
        lines.push(String::new());
        lines.push("By language:".to_string());
        for (language, counts) in &coverage.by_language {
            lines.push(format!(
                "- {language}: eligible {}, exact {} ({:.2}%), modeled {}, closed candidate identities {}, semantically accounted {}, multi-target candidate sets {}, unresolved {} ({:.2}%)",
                counts.eligible_call_sites,
                counts.exact_project_targets,
                percent(counts.exact_project_targets, counts.eligible_call_sites),
                counts.modeled_without_project_target,
                counts.closed_candidate_identity_sites,
                counts.semantically_accounted_call_sites,
                counts.calls_with_project_candidate_set,
                counts.unresolved_call_sites,
                percent(counts.unresolved_call_sites, counts.eligible_call_sites),
            ));
        }
    }
    if !coverage.unresolved_by_reason.is_empty() {
        lines.push(String::new());
        lines.push("Unresolved by reason:".to_string());
        for (reason, count) in &coverage.unresolved_by_reason {
            lines.push(format!("- {reason}: {count}"));
        }
    }
    if !coverage.unresolved_by_missing_proof.is_empty() {
        lines.push(String::new());
        lines.push("Unresolved by first missing proof:".to_string());
        for (proof, count) in &coverage.unresolved_by_missing_proof {
            lines.push(format!("- {proof}: {count}"));
        }
    }
    if !coverage.empty_domain_by_cause.is_empty() {
        lines.push(String::new());
        lines.push("Empty candidate domains by cause:".to_string());
        for (cause, count) in &coverage.empty_domain_by_cause {
            lines.push(format!("- {cause}: {count}"));
        }
    }
    lines.join("\n")
}

fn percent(numerator: usize, denominator: usize) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        numerator as f64 * 100.0 / denominator as f64
    }
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
        scip_indexes: Vec<PathBuf>,
        complexity_summaries: Vec<PathBuf>,
    },
    CallResolution {
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        language_override: Option<String>,
        format: String,
        scip_indexes: Vec<PathBuf>,
        complexity_summaries: Vec<PathBuf>,
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
            let mut scip_indexes = Vec::new();
            let mut complexity_summaries = Vec::new();
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
                    "--scip-index" => {
                        scip_indexes.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--scip-index requires a value")?,
                        ));
                    }
                    other if other.starts_with("--scip-index=") => {
                        scip_indexes
                            .push(PathBuf::from(other.strip_prefix("--scip-index=").unwrap()));
                    }
                    "--complexity-summary" => {
                        complexity_summaries.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--complexity-summary requires a value")?,
                        ));
                    }
                    other if other.starts_with("--complexity-summary=") => {
                        complexity_summaries.push(PathBuf::from(
                            other.strip_prefix("--complexity-summary=").unwrap(),
                        ));
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
                scip_indexes,
                complexity_summaries,
            })
        }
        "call-resolution" => {
            let mut output = None;
            let mut language_override = None;
            let mut format = "text".to_string();
            let mut files = Vec::new();
            let mut scip_indexes = Vec::new();
            let mut complexity_summaries = Vec::new();
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
                    "--scip-index" => {
                        scip_indexes.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--scip-index requires a value")?,
                        ));
                    }
                    other if other.starts_with("--scip-index=") => {
                        scip_indexes
                            .push(PathBuf::from(other.strip_prefix("--scip-index=").unwrap()));
                    }
                    "--complexity-summary" => {
                        complexity_summaries.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--complexity-summary requires a value")?,
                        ));
                    }
                    other if other.starts_with("--complexity-summary=") => {
                        complexity_summaries.push(PathBuf::from(
                            other.strip_prefix("--complexity-summary=").unwrap(),
                        ));
                    }
                    "--format" => {
                        format = iter.next().with_context(|| "--format requires a value")?;
                    }
                    other if other.starts_with("--format=") => {
                        format = other.strip_prefix("--format=").unwrap().to_string();
                    }
                    other if other.starts_with("--") => bail!("unsupported option: {other}"),
                    path => files.push(PathBuf::from(path)),
                }
            }
            if files.is_empty() {
                bail!("call-resolution requires at least one file");
            }
            Ok(Command::CallResolution {
                files,
                output,
                language_override,
                format,
                scip_indexes,
                complexity_summaries,
            })
        }
        other => bail!(
            "usage: fact-mine-rust {{syntax-facts|profile|call-resolution}} FILE... (got: {other})"
        ),
    }
}
