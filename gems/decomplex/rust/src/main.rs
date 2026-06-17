mod decomplex;

use anyhow::{bail, Context, Result};
use decomplex::detectors::{
    co_update, decision_pressure, derived_state, flay_similarity, implicit_control_flow,
    inconsistent_rename_clone, local_flow, locality_drag, miner, operational_discontinuity,
    predicate_alias, redundant_nil_guard, semantic_alias, state_branch_density, state_mesh,
    structural_topology, temporal_ordering_pressure, weighted_inlined_cognitive_complexity,
};
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
        Command::Miner { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = miner::scan_files(&files, language)
                .with_context(|| "failed to scan decision-site miner facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::SemanticAliases { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = semantic_alias::scan_files(&files, language)
                .with_context(|| "failed to scan semantic-alias facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::DecisionPressure { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = decision_pressure::scan_files(&files, language)
                .with_context(|| "failed to scan decision-pressure facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StateBranchDensity { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = state_branch_density::scan_files(&files, language)
                .with_context(|| "failed to scan state-branch-density facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::TemporalOrderingPressure { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = temporal_ordering_pressure::scan_files(&files, language)
                .with_context(|| "failed to scan temporal-ordering-pressure facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::RedundantNilGuard { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = redundant_nil_guard::scan_files(&files, language)
                .with_context(|| "failed to scan redundant-nil-guard facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StateMesh { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = state_mesh::scan_files(&files, language)
                .with_context(|| "failed to scan state-mesh facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::InconsistentRenameClone { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = inconsistent_rename_clone::scan_files(&files, language)
                .with_context(|| "failed to scan inconsistent-rename-clone facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::DerivedState { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = derived_state::scan_files(&files, language)
                .with_context(|| "failed to scan derived-state facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::ImplicitControlFlow { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = implicit_control_flow::scan_files(&files, language)
                .with_context(|| "failed to scan implicit-control-flow facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::WeightedInlinedComplexity { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = weighted_inlined_cognitive_complexity::scan_files(&files, language)
                .with_context(|| "failed to scan weighted-inlined-complexity facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::LocalityDrag { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = locality_drag::scan_files(&files, language)
                .with_context(|| "failed to scan locality-drag facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::OperationalDiscontinuity { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = operational_discontinuity::scan_files(&files, language)
                .with_context(|| "failed to scan operational-discontinuity facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StructuralTopology { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = structural_topology::scan_files(&files, language)
                .with_context(|| "failed to scan structural-topology facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::LocalFlow { language, files, .. } => {
            let language = Language::parse(&language)?;
            let report = local_flow::scan_files(&files, language)
                .with_context(|| "failed to scan local-flow facts")?;
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
    Miner {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    SemanticAliases {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    DecisionPressure {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    StateBranchDensity {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    TemporalOrderingPressure {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    RedundantNilGuard {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    StateMesh {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    InconsistentRenameClone {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    DerivedState {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    ImplicitControlFlow {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    WeightedInlinedComplexity {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    LocalityDrag {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    OperationalDiscontinuity {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    StructuralTopology {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    LocalFlow {
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
            | Self::Miner { jobs, .. }
            | Self::SemanticAliases { jobs, .. }
            | Self::DecisionPressure { jobs, .. }
            | Self::StateBranchDensity { jobs, .. }
            | Self::TemporalOrderingPressure { jobs, .. }
            | Self::RedundantNilGuard { jobs, .. }
            | Self::StateMesh { jobs, .. }
            | Self::InconsistentRenameClone { jobs, .. }
            | Self::DerivedState { jobs, .. }
            | Self::ImplicitControlFlow { jobs, .. }
            | Self::WeightedInlinedComplexity { jobs, .. }
            | Self::LocalityDrag { jobs, .. }
            | Self::OperationalDiscontinuity { jobs, .. }
            | Self::StructuralTopology { jobs, .. }
            | Self::LocalFlow { jobs, .. }
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
        "miner" | "decision-miner" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("miner requires at least one file");
            }
            Ok(Command::Miner {
                language,
                files,
                jobs,
            })
        }
        "semantic-aliases" | "semantic-alias" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("semantic-aliases requires at least one file");
            }
            Ok(Command::SemanticAliases {
                language,
                files,
                jobs,
            })
        }
        "decision-pressure" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("decision-pressure requires at least one file");
            }
            Ok(Command::DecisionPressure {
                language,
                files,
                jobs,
            })
        }
        "state-branch-density" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("state-branch-density requires at least one file");
            }
            Ok(Command::StateBranchDensity {
                language,
                files,
                jobs,
            })
        }
        "temporal-ordering-pressure" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("temporal-ordering-pressure requires at least one file");
            }
            Ok(Command::TemporalOrderingPressure {
                language,
                files,
                jobs,
            })
        }
        "redundant-nil-guard" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("redundant-nil-guard requires at least one file");
            }
            Ok(Command::RedundantNilGuard {
                language,
                files,
                jobs,
            })
        }
        "state-mesh" | "state-heatmap" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("state-mesh requires at least one file");
            }
            Ok(Command::StateMesh {
                language,
                files,
                jobs,
            })
        }
        "inconsistent-rename-clone" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("inconsistent-rename-clone requires at least one file");
            }
            Ok(Command::InconsistentRenameClone {
                language,
                files,
                jobs,
            })
        }
        "derived-state" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("derived-state requires at least one file");
            }
            Ok(Command::DerivedState {
                language,
                files,
                jobs,
            })
        }
        "implicit-control-flow" | "ordered-protocol-mine" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("implicit-control-flow requires at least one file");
            }
            Ok(Command::ImplicitControlFlow {
                language,
                files,
                jobs,
            })
        }
        "weighted-inlined-complexity" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("weighted-inlined-complexity requires at least one file");
            }
            Ok(Command::WeightedInlinedComplexity {
                language,
                files,
                jobs,
            })
        }
        "locality-drag" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("locality-drag requires at least one file");
            }
            Ok(Command::LocalityDrag {
                language,
                files,
                jobs,
            })
        }
        "operational-discontinuity" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("operational-discontinuity requires at least one file");
            }
            Ok(Command::OperationalDiscontinuity {
                language,
                files,
                jobs,
            })
        }
        "structural-topology" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("structural-topology requires at least one file");
            }
            Ok(Command::StructuralTopology {
                language,
                files,
                jobs,
            })
        }
        "local-flow" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("local-flow requires at least one file");
            }
            Ok(Command::LocalFlow {
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
