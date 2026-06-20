use anyhow::{bail, Context, Result};
use decomplex_rust::decomplex::detectors::{
    co_update, decision_pressure, derived_state, false_simplicity, fat_union, flay_similarity,
    function_lcom, implicit_control_flow, inconsistent_rename_clone, local_flow, locality_drag,
    miner, operational_discontinuity, oversized_predicate, path_condition, predicate_alias,
    redundant_nil_guard, semantic_alias, sequence_mine, state_branch_density, state_mesh,
    structural_topology, temporal_ordering_pressure, weighted_inlined_cognitive_complexity,
};
use decomplex_rust::decomplex::parallel;
use decomplex_rust::decomplex::report::Report;
use decomplex_rust::decomplex::report_facts::{self, Options as ReportFactsOptions, VcsFilter};
use decomplex_rust::decomplex::syntax::{Document, Language, LocalComplexityScore};
use decomplex_rust::decomplex::syntax_oracle;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;

fn main() -> Result<()> {
    let worker = std::thread::Builder::new()
        .name("decomplex-rust".to_string())
        .stack_size(64 * 1024 * 1024)
        .spawn(run)
        .with_context(|| "failed to start decomplex worker thread")?;

    match worker.join() {
        Ok(result) => result,
        Err(payload) => std::panic::resume_unwind(payload),
    }
}

fn run() -> Result<()> {
    let command = parse_args(std::env::args().skip(1).collect())?;
    parallel::set_jobs_for_process(command.jobs())?;
    match command {
        Command::StateWrites {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let facts = co_update::state_writes_for_files(&files, language)
                .with_context(|| "failed to extract state-write facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::CoUpdate {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = co_update::scan_files(&files, language)
                .with_context(|| "failed to scan co-update facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::PredicateAliases {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = predicate_alias::scan_files(&files, language)
                .with_context(|| "failed to scan predicate-alias facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::Miner {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = miner::scan_files(&files, language)
                .with_context(|| "failed to scan decision-site miner facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::SemanticAliases {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = semantic_alias::scan_files(&files, language)
                .with_context(|| "failed to scan semantic-alias facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::DecisionPressure {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = decision_pressure::scan_files(&files, language)
                .with_context(|| "failed to scan decision-pressure facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StateBranchDensity {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = state_branch_density::scan_files(&files, language)
                .with_context(|| "failed to scan state-branch-density facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::TemporalOrderingPressure {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = temporal_ordering_pressure::scan_files(&files, language)
                .with_context(|| "failed to scan temporal-ordering-pressure facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::RedundantNilGuard {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = redundant_nil_guard::scan_files(&files, language)
                .with_context(|| "failed to scan redundant-nil-guard facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StateMesh {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = state_mesh::scan_files(&files, language)
                .with_context(|| "failed to scan state-mesh facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::InconsistentRenameClone {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = inconsistent_rename_clone::scan_files(&files, language)
                .with_context(|| "failed to scan inconsistent-rename-clone facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::DerivedState {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = derived_state::scan_files(&files, language)
                .with_context(|| "failed to scan derived-state facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::ImplicitControlFlow {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = implicit_control_flow::scan_files(&files, language)
                .with_context(|| "failed to scan implicit-control-flow facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::WeightedInlinedComplexity {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = weighted_inlined_cognitive_complexity::scan_files(&files, language)
                .with_context(|| "failed to scan weighted-inlined-complexity facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::LocalityDrag {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = locality_drag::scan_files(&files, language)
                .with_context(|| "failed to scan locality-drag facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::OperationalDiscontinuity {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = operational_discontinuity::scan_files(&files, language)
                .with_context(|| "failed to scan operational-discontinuity facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::StructuralTopology {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let report = structural_topology::scan_files(&files, language)
                .with_context(|| "failed to scan structural-topology facts")?;
            println!("{}", serde_json::to_string(&report)?);
        }
        Command::LocalFlow {
            language, files, ..
        } => {
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
        Command::OversizedPredicate {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = oversized_predicate::scan_files(&files, language)
                .with_context(|| "failed to scan oversized-predicate facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::PathCondition {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = path_condition::scan_files(&files, language)
                .with_context(|| "failed to scan path-condition facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::SequenceMine {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = sequence_mine::scan_files(&files, language)
                .with_context(|| "failed to scan sequence-mine facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::FunctionLcom {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = function_lcom::scan_files(&files, language)
                .with_context(|| "failed to scan function-lcom facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::FalseSimplicity {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = false_simplicity::scan_files(&files, language)
                .with_context(|| "failed to scan false-simplicity facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::FatUnion {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let findings = fat_union::scan_files(&files, language)
                .with_context(|| "failed to scan fat-union facts")?;
            println!("{}", serde_json::to_string(&findings)?);
        }
        Command::Facts {
            options,
            targets,
            output,
            ..
        } => {
            let facts = report_facts::collect(&targets, &options)
                .with_context(|| "failed to collect report facts")?;
            write_json(&facts, output.as_ref())?;
        }
        Command::Report {
            options,
            targets,
            format,
            output,
            ..
        } => {
            let facts = report_facts::collect(&targets, &options)
                .with_context(|| "failed to collect report facts")?;
            render_report(&facts, &format, output.as_ref())?;
        }
        Command::RenderReport {
            input,
            from_stdin,
            format,
            output,
        } => {
            let facts = read_facts(input.as_ref(), from_stdin)?;
            render_report(&facts, &format, output.as_ref())?;
        }
        Command::SyntaxFacts {
            language, files, ..
        } => {
            let language = Language::parse(&language)?;
            let facts = syntax_oracle::project_files(&files, language)
                .with_context(|| "failed to collect syntax facts")?;
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::DetectorFacts { input } => {
            let fixture = read_facts(Some(&input), false)?;
            let detector = fixture
                .get("detector")
                .and_then(Value::as_str)
                .with_context(|| format!("{} missing detector", input.display()))?;
            let input = detector_fact_input(&fixture).with_context(|| {
                format!("failed to read detector facts from {}", input.display())
            })?;
            let output = run_detector_on_fact_input(detector, &input, &fixture)?;
            println!("{}", serde_json::to_string(&output)?);
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
    OversizedPredicate {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    PathCondition {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    SequenceMine {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    FunctionLcom {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    FalseSimplicity {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    FatUnion {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    Facts {
        options: ReportFactsOptions,
        targets: Vec<PathBuf>,
        output: Option<PathBuf>,
        jobs: Option<usize>,
    },
    Report {
        options: ReportFactsOptions,
        targets: Vec<PathBuf>,
        format: String,
        output: Option<PathBuf>,
        jobs: Option<usize>,
    },
    RenderReport {
        input: Option<PathBuf>,
        from_stdin: bool,
        format: String,
        output: Option<PathBuf>,
    },
    SyntaxFacts {
        language: String,
        files: Vec<PathBuf>,
        jobs: Option<usize>,
    },
    DetectorFacts {
        input: PathBuf,
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
            | Self::FlaySimilarity { jobs, .. }
            | Self::OversizedPredicate { jobs, .. }
            | Self::PathCondition { jobs, .. }
            | Self::SequenceMine { jobs, .. }
            | Self::FunctionLcom { jobs, .. }
            | Self::FalseSimplicity { jobs, .. }
            | Self::FatUnion { jobs, .. }
            | Self::Facts { jobs, .. }
            | Self::Report { jobs, .. }
            | Self::SyntaxFacts { jobs, .. } => *jobs,
            Self::RenderReport { .. } | Self::DetectorFacts { .. } => None,
        }
    }
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut cursor = args.into_iter();
    let Some(command) = cursor.next() else {
        bail!("usage: decomplex-rust COMMAND [--language ruby] [--jobs N] FILE...");
    };
    match command.as_str() {
        "facts" => {
            let args = parse_report_facts_args(cursor.collect(), false)?;
            if args.targets.is_empty() {
                bail!("facts requires at least one file or directory");
            }
            Ok(Command::Facts {
                options: args.options,
                targets: args.targets,
                output: args.output,
                jobs: args.jobs,
            })
        }
        "report" => {
            let args = parse_report_facts_args(cursor.collect(), true)?;
            if args.targets.is_empty() {
                bail!("report requires at least one file or directory");
            }
            Ok(Command::Report {
                options: args.options,
                targets: args.targets,
                format: args.format,
                output: args.output,
                jobs: args.jobs,
            })
        }
        "render-report" => {
            let args = parse_render_report_args(cursor.collect())?;
            Ok(Command::RenderReport {
                input: args.input,
                from_stdin: args.from_stdin,
                format: args.format,
                output: args.output,
            })
        }
        "detector-facts" => {
            let input = parse_input_only_args(cursor.collect(), "detector-facts")?;
            Ok(Command::DetectorFacts { input })
        }
        "syntax-facts" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("syntax-facts requires at least one file");
            }
            Ok(Command::SyntaxFacts {
                language,
                files,
                jobs,
            })
        }
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
        "oversized-predicate" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("oversized-predicate requires at least one file");
            }
            Ok(Command::OversizedPredicate {
                language,
                files,
                jobs,
            })
        }
        "path-condition" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("path-condition requires at least one file");
            }
            Ok(Command::PathCondition {
                language,
                files,
                jobs,
            })
        }
        "sequence-mine" | "broken-protocol" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("sequence-mine requires at least one file");
            }
            Ok(Command::SequenceMine {
                language,
                files,
                jobs,
            })
        }
        "function-lcom" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("function-lcom requires at least one file");
            }
            Ok(Command::FunctionLcom {
                language,
                files,
                jobs,
            })
        }
        "false-simplicity" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("false-simplicity requires at least one file");
            }
            Ok(Command::FalseSimplicity {
                language,
                files,
                jobs,
            })
        }
        "fat-union" => {
            let (language, files, jobs) = parse_language_files_and_jobs(cursor.collect())?;
            if files.is_empty() {
                bail!("fat-union requires at least one file");
            }
            Ok(Command::FatUnion {
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
                    language = rest.next().with_context(|| "--language requires a value")?;
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
                    fuzzy = value
                        .parse()
                        .with_context(|| "--fuzzy must be an integer")?;
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

fn parse_input_only_args(args: Vec<String>, command: &str) -> Result<PathBuf> {
    let mut input = None;
    let mut cursor = args.into_iter();
    while let Some(arg) = cursor.next() {
        if arg == "--input" {
            input = Some(PathBuf::from(
                cursor.next().with_context(|| "--input requires a value")?,
            ));
        } else if let Some(value) = arg.strip_prefix("--input=") {
            input = Some(PathBuf::from(value));
        } else {
            bail!("unknown {command} argument: {arg}");
        }
    }
    input.with_context(|| format!("{command} requires --input=FILE"))
}

#[derive(Deserialize)]
struct DetectorFactDocuments {
    documents: Vec<Document>,
}

struct DetectorFactInput {
    documents: Vec<Document>,
    local_methods: Vec<local_flow::MethodSummary>,
}

fn detector_fact_input(fixture: &Value) -> Result<DetectorFactInput> {
    let input = fixture
        .get("input")
        .cloned()
        .with_context(|| "detector fact fixture missing input")?;
    let documents: DetectorFactDocuments = serde_json::from_value(input.clone())?;
    let mut local_methods = Vec::new();

    if let Some(methods) = input.get("local_methods") {
        local_methods.extend(serde_json::from_value::<Vec<local_flow::MethodSummary>>(
            methods.clone(),
        )?);
    }
    for document in input
        .get("documents")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(methods) = document.get("local_methods") {
            local_methods.extend(serde_json::from_value::<Vec<local_flow::MethodSummary>>(
                methods.clone(),
            )?);
        }
    }

    Ok(DetectorFactInput {
        documents: documents.documents,
        local_methods,
    })
}

fn run_detector_on_fact_input(
    detector: &str,
    input: &DetectorFactInput,
    fixture: &Value,
) -> Result<Value> {
    let documents = input.documents.as_slice();
    match detector {
        "co-update" => Ok(json!(co_update::scan_documents(documents))),
        "decision-pressure" => {
            if input.local_methods.is_empty() {
                Ok(json!(decision_pressure::scan_documents(documents)))
            } else {
                Ok(json!(decision_pressure::scan_documents_with_summaries(
                    documents,
                    &input.local_methods
                )))
            }
        }
        "predicate-alias" | "predicate-aliases" => {
            Ok(json!(predicate_alias::scan_documents(documents)))
        }
        "miner" | "decision-miner" => Ok(json!(miner::scan_documents(documents))),
        "semantic-alias" | "semantic-aliases" => {
            Ok(json!(semantic_alias::scan_documents(documents)))
        }
        "flay-similarity" | "structural-similarity" => {
            let options = fixture.get("options").unwrap_or(&Value::Null);
            let mass = value_usize(options, "mass", 32)?;
            let fuzzy = value_usize(options, "fuzzy", 1)?;
            Ok(json!({
                "findings": flay_similarity::scan_documents(documents, mass, fuzzy),
            }))
        }
        "temporal-ordering-pressure" => {
            Ok(json!(temporal_ordering_pressure::scan_documents(documents)))
        }
        "state-branch-density" => Ok(json!(state_branch_density::scan_documents(documents))),
        "redundant-nil-guard" => Ok(json!(redundant_nil_guard::scan_documents(documents))),
        "state-mesh" | "state-heatmap" => Ok(json!(state_mesh::scan_documents(documents))),
        "inconsistent-rename-clone" => {
            Ok(json!(inconsistent_rename_clone::scan_documents(documents)))
        }
        "derived-state" => {
            if input.local_methods.is_empty() {
                Ok(json!(derived_state::scan_documents(documents)))
            } else {
                Ok(json!(derived_state::scan_summaries(&input.local_methods)))
            }
        }
        "implicit-control-flow" | "ordered-protocol-mine" => {
            Ok(json!(implicit_control_flow::scan_documents(documents)))
        }
        "weighted-inlined-complexity" => {
            if input.local_methods.is_empty() {
                Ok(json!(
                    weighted_inlined_cognitive_complexity::scan_documents(documents)
                ))
            } else {
                Ok(json!(
                    weighted_inlined_cognitive_complexity::scan_documents_with_summaries(
                        documents,
                        &input.local_methods
                    )
                ))
            }
        }
        "locality-drag" => {
            if input.local_methods.is_empty() {
                Ok(json!(locality_drag::scan_documents(documents)))
            } else {
                let scores = complexity_scores(documents);
                Ok(json!(locality_drag::scan_summaries_with_scores(
                    &input.local_methods,
                    &scores
                )))
            }
        }
        "operational-discontinuity" => {
            if input.local_methods.is_empty() {
                Ok(json!(operational_discontinuity::scan_documents(documents)))
            } else {
                Ok(json!(operational_discontinuity::scan_summaries(
                    &input.local_methods
                )))
            }
        }
        "oversized-predicate" => Ok(json!(oversized_predicate::scan_documents(documents))),
        "path-condition" => Ok(json!({
            "neglected": path_condition::scan_documents(documents).neglected,
        })),
        "sequence-mine" | "broken-protocol" => Ok(json!(sequence_mine::scan_documents(documents))),
        "function-lcom" => {
            if input.local_methods.is_empty() {
                Ok(json!(function_lcom::scan_documents(documents)))
            } else {
                Ok(json!(function_lcom::scan_summaries(&input.local_methods)))
            }
        }
        "false-simplicity" => Ok(json!(false_simplicity::scan_documents(documents))),
        "fat-union" => Ok(json!(fat_union::scan_documents(documents))),
        "local-flow" => Ok(json!(local_flow::scan_documents(documents))),
        "structural-topology" => Ok(json!(structural_topology::scan_documents(documents))),
        _ => bail!("unsupported detector fact fixture: {detector}"),
    }
}

fn complexity_scores(
    documents: &[Document],
) -> std::collections::BTreeMap<(String, String), LocalComplexityScore> {
    documents
        .iter()
        .flat_map(|document| {
            document
                .local_complexity_scores
                .iter()
                .map(|(id, score)| ((document.file.clone(), id.clone()), score.clone()))
        })
        .collect()
}

fn value_usize(options: &Value, key: &str, default: usize) -> Result<usize> {
    match options.get(key) {
        Some(value) => value
            .as_u64()
            .map(|value| value as usize)
            .with_context(|| format!("option {key} must be an integer")),
        None => Ok(default),
    }
}

struct ReportFactsArgs {
    options: ReportFactsOptions,
    targets: Vec<PathBuf>,
    output: Option<PathBuf>,
    jobs: Option<usize>,
    format: String,
}

struct RenderReportArgs {
    input: Option<PathBuf>,
    from_stdin: bool,
    output: Option<PathBuf>,
    format: String,
}

fn parse_render_report_args(args: Vec<String>) -> Result<RenderReportArgs> {
    let mut input = None;
    let mut from_stdin = false;
    let mut output = None;
    let mut format = "markdown".to_string();
    let mut cursor = args.into_iter();
    while let Some(arg) = cursor.next() {
        if arg == "--from-stdin" {
            from_stdin = true;
        } else if arg == "--input" {
            input = Some(PathBuf::from(
                cursor.next().with_context(|| "--input requires a value")?,
            ));
        } else if let Some(value) = arg.strip_prefix("--input=") {
            input = Some(PathBuf::from(value));
        } else if arg == "--output" {
            output = Some(PathBuf::from(
                cursor.next().with_context(|| "--output requires a value")?,
            ));
        } else if let Some(value) = arg.strip_prefix("--output=") {
            output = Some(PathBuf::from(value));
        } else if arg == "--format" {
            format = cursor.next().with_context(|| "--format requires a value")?;
        } else if let Some(value) = arg.strip_prefix("--format=") {
            format = value.to_string();
        } else {
            bail!("unknown render-report argument: {arg}");
        }
    }
    if input.is_none() && !from_stdin {
        bail!("render-report requires facts JSON on stdin or --input=FILE");
    }
    Ok(RenderReportArgs {
        input,
        from_stdin,
        output,
        format,
    })
}

fn parse_report_facts_args(args: Vec<String>, allow_format: bool) -> Result<ReportFactsArgs> {
    let mut options = ReportFactsOptions::default();
    let mut targets = Vec::new();
    let mut output = None;
    let mut jobs = None;
    let mut format = "markdown".to_string();
    let mut cursor = args.into_iter();
    while let Some(arg) = cursor.next() {
        if arg == "--language" {
            let value = cursor
                .next()
                .with_context(|| "--language requires a value")?;
            options.language = Some(Language::parse(&value)?);
        } else if let Some(value) = arg.strip_prefix("--language=") {
            options.language = Some(Language::parse(value)?);
        } else if arg == "--jobs" {
            jobs = Some(parse_jobs(
                cursor.next().with_context(|| "--jobs requires a value")?,
            )?);
        } else if let Some(value) = arg.strip_prefix("--jobs=") {
            jobs = Some(parse_jobs(value.to_string())?);
        } else if arg == "--exclude" {
            options.excludes.push(
                cursor
                    .next()
                    .with_context(|| "--exclude requires a value")?,
            );
        } else if let Some(value) = arg.strip_prefix("--exclude=") {
            options.excludes.push(value.to_string());
        } else if arg == "--output" {
            output = Some(PathBuf::from(
                cursor.next().with_context(|| "--output requires a value")?,
            ));
        } else if let Some(value) = arg.strip_prefix("--output=") {
            output = Some(PathBuf::from(value));
        } else if arg == "--format" {
            if !allow_format {
                bail!("facts does not support --format");
            }
            format = cursor.next().with_context(|| "--format requires a value")?;
        } else if let Some(value) = arg.strip_prefix("--format=") {
            if !allow_format {
                bail!("facts does not support --format");
            }
            format = value.to_string();
        } else if arg == "--mass" {
            options.mass = cursor
                .next()
                .with_context(|| "--mass requires a value")?
                .parse()
                .with_context(|| "--mass must be an integer")?;
        } else if let Some(value) = arg.strip_prefix("--mass=") {
            options.mass = value.parse().with_context(|| "--mass must be an integer")?;
        } else if arg == "--fuzzy" {
            options.fuzzy = cursor
                .next()
                .with_context(|| "--fuzzy requires a value")?
                .parse()
                .with_context(|| "--fuzzy must be an integer")?;
        } else if let Some(value) = arg.strip_prefix("--fuzzy=") {
            options.fuzzy = value
                .parse()
                .with_context(|| "--fuzzy must be an integer")?;
        } else if arg == "--vcs" {
            options.vcs = Some(parse_vcs_filter(
                cursor.next().with_context(|| "--vcs requires a value")?,
            )?);
        } else if let Some(value) = arg.strip_prefix("--vcs=") {
            options.vcs = Some(parse_vcs_filter(value.to_string())?);
        } else {
            targets.push(PathBuf::from(arg));
        }
    }
    Ok(ReportFactsArgs {
        options,
        targets,
        output,
        jobs,
        format,
    })
}

fn write_json(value: &serde_json::Value, output: Option<&PathBuf>) -> Result<()> {
    let text = serde_json::to_string_pretty(value)?;
    if let Some(path) = output {
        std::fs::write(path, text)?;
    } else {
        println!("{text}");
    }
    Ok(())
}

fn read_facts(input: Option<&PathBuf>, from_stdin: bool) -> Result<serde_json::Value> {
    let payload = if let Some(path) = input {
        std::fs::read_to_string(path)
            .with_context(|| format!("failed to read {}", path.display()))?
    } else if from_stdin {
        let mut payload = String::new();
        std::io::stdin()
            .read_to_string(&mut payload)
            .with_context(|| "failed to read facts JSON from stdin")?;
        payload
    } else {
        bail!("render-report requires facts JSON on stdin or --input=FILE");
    };
    if payload.trim().is_empty() {
        bail!("render-report requires facts JSON on stdin or --input=FILE");
    }
    serde_json::from_str(&payload).with_context(|| "failed to parse report facts JSON")
}

fn render_report(facts: &serde_json::Value, format: &str, output: Option<&PathBuf>) -> Result<()> {
    let report = Report::from_facts(facts)?;
    let text = match format {
        "markdown" | "md" => report.to_markdown(),
        "sarif" | "json" => report.to_sarif(),
        _ => bail!("unsupported report format: {format}"),
    };
    if let Some(path) = output {
        std::fs::write(path, text)?;
    } else {
        println!("{text}");
    }
    Ok(())
}

fn parse_language_files_and_jobs(
    args: Vec<String>,
) -> Result<(String, Vec<PathBuf>, Option<usize>)> {
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

fn parse_vcs_filter(value: String) -> Result<VcsFilter> {
    match value.as_str() {
        "git" => Ok(VcsFilter::Git),
        _ => bail!("unsupported --vcs value: {value}"),
    }
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

    #[test]
    fn parses_git_vcs_filter_for_facts() {
        let command = parse_args(vec![
            "facts".to_string(),
            "--vcs=git".to_string(),
            "src".to_string(),
        ])
        .expect("command");

        match command {
            Command::Facts { options, .. } => assert_eq!(options.vcs, Some(VcsFilter::Git)),
            _ => panic!("expected facts command"),
        }
    }
}
