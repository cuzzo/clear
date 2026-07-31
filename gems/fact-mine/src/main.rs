use anyhow::{bail, Context, Result};
use fact_mine_rust::incremental;
use fact_mine_rust::parallel;
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use fact_mine_rust::syntax_oracle;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::fs;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::Instant;

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
            let facts = match language {
                Some(language) => {
                    let language = Language::parse(&language)?;
                    syntax_oracle::project_files(&files, language)
                        .with_context(|| "failed to project syntax facts")?
                }
                None => {
                    // No explicit language: infer per file extension, batch per
                    // language, and merge the document lists.
                    let mut batches: std::collections::BTreeMap<&'static str, Vec<PathBuf>> =
                        std::collections::BTreeMap::new();
                    for file in &files {
                        let extension = file.extension().and_then(|ext| ext.to_str()).unwrap_or("");
                        let language = Language::for_extension(extension).with_context(|| {
                            format!(
                                "cannot infer language for {} (pass --language to override)",
                                file.display()
                            )
                        })?;
                        batches
                            .entry(language.as_str())
                            .or_default()
                            .push(file.clone());
                    }
                    let mut merged: Option<serde_json::Value> = None;
                    for (language_name, batch) in batches {
                        let language = Language::parse(language_name)?;
                        let chunk = syntax_oracle::project_files(&batch, language)
                            .with_context(|| "failed to project syntax facts")?;
                        match merged.as_mut() {
                            None => merged = Some(chunk),
                            Some(out) => {
                                let docs =
                                    chunk["documents"].as_array().cloned().unwrap_or_default();
                                out["documents"]
                                    .as_array_mut()
                                    .expect("documents array")
                                    .extend(docs);
                            }
                        }
                    }
                    merged.unwrap_or_else(|| serde_json::json!({ "documents": [] }))
                }
            };
            println!("{}", serde_json::to_string(&facts)?);
        }
        Command::Profile {
            profile,
            files,
            output,
            language_override,
            scip_indexes,
            semantic_environments,
            complexity_summaries,
            bundled_complexity_summaries,
            portable,
            incremental_cache,
            changed_files_only,
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
            let cacheable_artifact = incremental_cache.is_some()
                && !changed_files_only
                && !portable
                && scip_indexes.is_empty()
                && semantic_environments.is_empty()
                && complexity_summaries.is_empty()
                && !output.as_ref().is_some_and(|path| {
                    path.extension().and_then(|value| value.to_str()) == Some("gz")
                });
            if cacheable_artifact {
                let root = std::env::current_dir().context("failed to determine cache root")?;
                let config =
                    incremental::CacheConfig::new(root, incremental_cache.clone().expect("cache"));
                if let Some(artifact) =
                    incremental::served_artifact_path(&files, language_override, profile, &config)?
                {
                    copy_profile_artifact(&artifact, output.as_ref())?;
                    std::eprintln!("FactMine served cached artifact: {}", artifact.display());
                    return Ok(());
                }
            }
            let mut merged = build_requested_profile(
                &files,
                language_override,
                profile,
                incremental_cache.clone(),
                changed_files_only,
            )?;
            let external_enrichment_started = Instant::now();
            for index in scip_indexes {
                fact_mine_rust::scip::apply_json_file(&mut merged, &index)?;
            }
            fact_mine_rust::external_summary::apply_environment_files(
                &mut merged,
                semantic_environments.as_slice(),
            )?;
            if bundled_complexity_summaries {
                fact_mine_rust::external_summary::apply_bundled(&mut merged)?;
            }
            fact_mine_rust::external_summary::apply_files(
                &mut merged,
                complexity_summaries.as_slice(),
            )?;
            if profile == Profile::TracePlan {
                profile::refresh_runtime_call_sites(&mut merged);
            }
            if let Some(metrics) = merged.incremental_metrics.as_mut() {
                metrics.external_enrichment_millis =
                    external_enrichment_started.elapsed().as_millis();
            }
            let serialization_started = Instant::now();
            if cacheable_artifact {
                let root = std::env::current_dir().context("failed to determine cache root")?;
                let config = incremental::CacheConfig::new(root, incremental_cache.expect("cache"));
                let artifact = incremental::served_artifact_destination(
                    &files,
                    language_override,
                    profile,
                    &config,
                )?;
                if let Some(parent) = artifact.parent() {
                    fs::create_dir_all(parent)?;
                }
                write_profile_artifact(&merged, Some(&artifact), false)?;
                copy_profile_artifact(&artifact, output.as_ref())?;
            } else {
                write_profile_artifact(&merged, output.as_ref(), portable)?;
            }
            let serialization_millis = serialization_started.elapsed().as_millis();
            std::eprintln!("FactMine artifact serialization: {serialization_millis}ms");
        }
        Command::CallResolution {
            files,
            output,
            language_override,
            format,
            scip_indexes,
            semantic_environments,
            complexity_summaries,
            bundled_complexity_summaries,
        } => {
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let mut merged = build_profile(&files, language_override, Profile::Espalier)?;
            for index in scip_indexes {
                fact_mine_rust::scip::apply_json_file(&mut merged, &index)?;
            }
            fact_mine_rust::external_summary::apply_environment_files(
                &mut merged,
                semantic_environments.as_slice(),
            )?;
            if bundled_complexity_summaries {
                fact_mine_rust::external_summary::apply_bundled(&mut merged)?;
            }
            fact_mine_rust::external_summary::apply_files(
                &mut merged,
                complexity_summaries.as_slice(),
            )?;
            let rendered = match format.as_str() {
                "json" => serde_json::to_string_pretty(&merged.call_resolution_coverage)?,
                "text" => render_call_resolution(&merged.call_resolution_coverage),
                // Corpus-resolved call edges plus the method index needed to
                // join them: the architecture layer consumes this directly.
                "edges" => {
                    let method_index: std::collections::BTreeMap<
                        &str,
                        &fact_mine_rust::profile::MethodRecord,
                    > = merged
                        .methods
                        .iter()
                        .map(|method| (method.id.as_str(), method))
                        .collect();
                    let edges = merged
                        .calls
                        .iter()
                        .filter_map(|call| {
                            let target = call.target.as_deref()?;
                            let target_method = method_index.get(target)?;
                            let source_method = method_index.get(call.source.as_str());
                            Some(serde_json::json!({
                                "source": call.source,
                                "source_owner": call.owner,
                                "source_function": call.function,
                                "source_path": call.path,
                                "line": call.line,
                                "receiver": call.receiver,
                                "message": call.message,
                                "target": target,
                                "target_owner": target_method.owner,
                                "target_name": target_method.name,
                                "target_path": target_method.path,
                                "target_line": target_method.line,
                                "target_visibility": target_method.visibility,
                                "source_resolved": source_method.is_some(),
                            }))
                        })
                        .collect::<Vec<_>>();
                    let methods = merged
                        .methods
                        .iter()
                        .map(|method| {
                            serde_json::json!({
                                "id": method.id,
                                "owner": method.owner,
                                "name": method.name,
                                "path": method.path,
                                "line": method.line,
                                "visibility": method.visibility,
                                "language": method.language,
                            })
                        })
                        .collect::<Vec<_>>();
                    serde_json::to_string(&serde_json::json!({
                        "format": "fact-mine.call-edges.v1",
                        "edges": edges,
                        "methods": methods,
                        "coverage": merged.call_resolution_coverage,
                    }))?
                }
                other => {
                    bail!("unsupported call-resolution format: {other}; use text, json, or edges")
                }
            };
            if let Some(ref output_path) = output {
                fs::write(output_path, rendered)?;
            } else {
                println!("{}", rendered);
            }
        }
        Command::NilKillTracePlan {
            static_facts,
            raw,
            runtime_plan,
            output,
            root,
            generated_at,
            target_dirs,
            exclude_dirs,
        } => {
            let facts: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&static_facts)?)
                    .with_context(|| format!("failed to parse {}", static_facts.display()))?;
            let evidence = match runtime_plan {
                Some(path) => serde_json::from_str(&std::fs::read_to_string(&path)?)
                    .with_context(|| format!("failed to parse {}", path.display()))?,
                None => serde_json::Value::Null,
            };
            let facts = if raw {
                fact_mine_rust::trace_plan::reshape_static_facts(&facts, &root)
            } else {
                facts
            };
            let plan = fact_mine_rust::trace_plan::TracePlan::build(&facts, &root);
            let document =
                plan.document(&generated_at, &target_dirs, &exclude_dirs, evidence);
            if let Some(parent) = output.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&output, serde_json::to_string_pretty(&document)?)?;
        }
        Command::NilKillScipIndex {
            runtime_dir,
            evidence,
            plan,
            output,
            attestation,
            files,
            environment,
            root,
        } => {
            let raw = fact_mine_rust::runtime_protocol::read_json(&plan)
                .with_context(|| format!("unreadable plan {}", plan.display()))?;
            let document: serde_json::Value = serde_json::from_str(&raw)?;
            let runtime_plan = document
                .get("runtime_evidence")
                .filter(|value| value.is_object())
                .cloned()
                .unwrap_or(document);
            let environment = environment
                .iter()
                .filter_map(|claim| claim.split_once('='))
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect::<std::collections::BTreeMap<_, _>>();

            let emitted = fact_mine_rust::scip_emit::emit(
                &root,
                &runtime_dir,
                &evidence,
                &runtime_plan,
                &files,
                &environment,
                |evidence_path, sources| {
                    Ok(runtime_scip_overlay(&root, sources, &plan, evidence_path)?.index)
                },
            )?;
            fs::write(&output, serde_json::to_string(&emitted.index)? + "\n")?;
            fact_mine_rust::runtime_trace::write_json(
                &attestation,
                &(serde_json::to_string_pretty(&emitted.attestation)? + "\n"),
            )?;
            println!(
                "{}",
                serde_json::to_string(&serde_json::json!({
                    "index": output,
                    "attestation": attestation,
                    "events": emitted.events,
                    "inferred_events": emitted.inferred_events,
                    "documents": emitted.documents,
                    "occurrences": emitted.occurrences,
                    "invalid_events": emitted.invalid_events,
                    "excluded_events": 0,
                    "runtime_evidence": evidence,
                    "runtime_value_observations": emitted.observations,
                }))?
            );
        }
        Command::NilKillTraceDocument { runtime_dirs, plan, root } => {
            let raw = fact_mine_rust::runtime_protocol::read_json(&plan)
                .with_context(|| format!("unreadable plan {}", plan.display()))?;
            let plan: serde_json::Value = serde_json::from_str(&raw)?;
            let digest = plan["runtime_evidence"]["plan_digest"]
                .as_str()
                .or_else(|| plan["plan_digest"].as_str())
                .unwrap_or_default()
                .to_string();
            let built = fact_mine_rust::parallel::map_ordered(&runtime_dirs, |directory| {
                // The runtime that observed, and the run it observed under,
                // both come from the shard's own document.
                let (runtime, run_id) = fact_mine_rust::trace_document::runtime_of(directory)?;
                let run_ids = if run_id.is_empty() { vec![] } else { vec![run_id] };
                fact_mine_rust::trace_document::write(
                    &root, directory, &digest, &runtime, &run_ids,
                )?;
                Ok(1usize)
            })?;
            eprintln!("Built {} trace documents", built.iter().sum::<usize>());
        }
        Command::NilKillCollectorPlan { plan, output, target_dirs, root } => {
            fact_mine_rust::collector_plan::write(&plan, &output, &target_dirs, &root)?;
        }
        Command::NilKillCollectorExport { runtime_dirs, plan, source_roles, root } => {
            let plan = plan
                .as_deref()
                .map(|path| -> Result<serde_json::Value> {
                    let raw = fact_mine_rust::runtime_protocol::read_json(path)
                        .with_context(|| format!("unreadable plan {}", path.display()))?;
                    Ok(serde_json::from_str(&raw)?)
                })
                .transpose()?;
            let anchors = fact_mine_rust::collector_export::anchors_by_key(plan.as_ref(), &root);
            let nonproduction = read_nonproduction(source_roles.as_deref(), &root);
            let project_name = std::env::var("NIL_KILL_PROJECT_NAME").unwrap_or_else(|_| {
                root.file_name().map(|name| name.to_string_lossy().to_string()).unwrap_or_default()
            });
            let project_version = std::env::var("NIL_KILL_PROJECT_VERSION")
                .unwrap_or_else(|_| "workspace".to_string());
            let shaped = fact_mine_rust::parallel::map_ordered(&runtime_dirs, |directory| {
                let mut written = 0;
                let mut documents = std::fs::read_dir(directory)
                    .with_context(|| format!("unreadable shard {}", directory.display()))?
                    .filter_map(|entry| entry.ok().map(|entry| entry.path()))
                    .filter(|path| {
                        path.file_name().is_some_and(|name| {
                            let name = name.to_string_lossy();
                            name.starts_with("collector-raw-") && name.ends_with(".json.gz")
                        })
                    })
                    .collect::<Vec<_>>();
                documents.sort();
                for path in documents {
                    let raw = fact_mine_rust::runtime_protocol::read_json(&path)
                        .with_context(|| format!("unreadable {}", path.display()))?;
                    let document: fact_mine_rust::collector_export::CollectorDocument =
                        serde_json::from_str(&raw)
                            .with_context(|| format!("invalid {}", path.display()))?;
                    fact_mine_rust::collector_export::Export::new(
                        &document,
                        &anchors,
                        nonproduction.clone(),
                        project_name.clone(),
                        project_version.clone(),
                    )
                    .write(directory)?;
                    written += 1;
                }
                Ok(written)
            })?;
            eprintln!(
                "Shaped {} collector documents across {} shards",
                shaped.iter().sum::<usize>(),
                runtime_dirs.len()
            );
        }
        Command::NilKillDeriveDomains { inputs, source_roles, root } => {
            // Which files hold non-production code is a fact about the collect,
            // not about the traced program, so it is read here rather than
            // carried through every observation.
            let nonproduction =
                read_nonproduction(source_roles.as_deref(), &root).into_iter().collect::<Vec<_>>();
            let derived = fact_mine_rust::parallel::map_ordered(&inputs, |path| {
                let raw = fact_mine_rust::runtime_protocol::read_json(path)
                    .with_context(|| format!("unreadable collector document {}", path.display()))?;
                let mut document: serde_json::Value = serde_json::from_str(&raw)
                    .with_context(|| format!("invalid collector document {}", path.display()))?;
                let count = fact_mine_rust::value_domain::derive_document(
                    &mut document,
                    nonproduction.clone(),
                );
                fact_mine_rust::runtime_trace::write_json(
                    path,
                    &serde_json::to_string(&document)?,
                )?;
                Ok(count)
            })?;
            eprintln!(
                "Derived {} value domains across {} collector documents",
                derived.iter().sum::<usize>(),
                inputs.len()
            );
        }
        Command::NilKillDecodeCalls { input, root } => {
            let text = std::fs::read_to_string(&input)?;
            let rows: Vec<serde_json::Value> = text
                .lines()
                .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .map(|event| fact_mine_rust::runtime_decode::call(&event, &root))
                .collect();
            println!("{}", serde_json::to_string(&rows)?);
        }
        Command::RuntimePlan {
            files,
            output,
            root,
            language_override,
        } => {
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let root = root
                .unwrap_or(std::env::current_dir().context("failed to determine project root")?);
            let files = canonical_runtime_sources(&files, &root)?;
            let profile = build_profile(&files, language_override, Profile::TracePlan)?;
            let plan = fact_mine_rust::runtime_protocol::build_trace_plan(&profile, &files, &root)?;
            let json = fact_mine_rust::runtime_protocol::to_json(&plan)?;
            let rendered =
                serde_json::to_string_pretty(&serde_json::from_str::<serde_json::Value>(&json)?)?
                    + "\n";
            write_text_artifact(&rendered, output.as_ref())?;
            eprintln!(
                "Runtime plan: {} documents, {} exact evidence anchors",
                plan.documents.len(),
                plan.requests.len()
            );
        }
        Command::RuntimeTrace {
            plan,
            traces,
            output,
            to_stdout,
            merged,
            root,
        } => {
            // The plan is parsed and digest-checked once however many traces are
            // joined; paying that per shard cost more than the join itself. The
            // shards themselves are independent, so they join concurrently --
            // this loop was the largest sequential stage of a collect.
            // Stage timing, off unless asked for, so this command can be
            // accounted for the same way the collector's stages are.
            let timed = std::env::var("NIL_KILL_STAGE_TIMING").as_deref() == Ok("1");
            let mark = std::time::Instant::now();
            let plan = fact_mine_rust::runtime_trace::read_plan(&plan)?;
            if timed {
                eprintln!("  rust plan-read      {:.2}s", mark.elapsed().as_secs_f64());
            }
            let root = std::fs::canonicalize(&root).unwrap_or(root);
            let mark = std::time::Instant::now();
            // Writing beside each trace is the default whatever the count.
            // Making one trace behave differently from many meant a single-shard
            // collect silently produced no evidence file at all.
            let single = to_stdout;
            let joined = fact_mine_rust::parallel::map_ordered(&traces, |path| {
                let trace = fact_mine_rust::runtime_trace::read_trace(path)?;
                let evidence =
                    fact_mine_rust::runtime_trace::build_evidence(&root, &plan, &trace)?;
                match (&output, single) {
                    (Some(target), _) => {
                        fact_mine_rust::runtime_trace::write_json(target, &evidence)?;
                        Ok(None)
                    }
                    (None, true) => Ok(Some(evidence)),
                    (None, false) if merged.is_some() => {
                        let target = path.with_file_name("runtime-evidence.v1.json.gz");
                        fact_mine_rust::runtime_trace::write_json(&target, &evidence)?;
                        Ok(Some(evidence))
                    }
                    (None, false) => {
                        let target = path.with_file_name("runtime-evidence.v1.json.gz");
                        fact_mine_rust::runtime_trace::write_json(&target, &evidence)?;
                        Ok(None)
                    }
                }
            })?;
            if timed {
                eprintln!("  rust join+write     {:.2}s", mark.elapsed().as_secs_f64());
            }
            // Merging here saves writing every shard's document only for the
            // collector to read them all back and merge them in Ruby.
            if let Some(target) = &merged {
                let mark = std::time::Instant::now();
                let documents = joined
                    .iter()
                    .flatten()
                    .map(|text| {
                        fact_mine_rust::runtime_protocol::parse_runtime_evidence_json(text)
                    })
                    .collect::<Result<Vec<_>>>()?;
                if timed {
                    eprintln!("  rust merge-parse    {:.2}s", mark.elapsed().as_secs_f64());
                }
                let mark = std::time::Instant::now();
                let document = fact_mine_rust::runtime_trace::merge_evidence(&documents)?;
                if timed {
                    eprintln!("  rust merge          {:.2}s", mark.elapsed().as_secs_f64());
                }
                let mark = std::time::Instant::now();
                fact_mine_rust::runtime_trace::write_json(
                    target,
                    &fact_mine_rust::runtime_protocol::to_json_with_defaults(&document)?,
                )?;
                if timed {
                    eprintln!("  rust canonical+write {:.2}s", mark.elapsed().as_secs_f64());
                }
            } else {
                for evidence in joined.into_iter().flatten() {
                    println!("{evidence}");
                }
            }
            eprintln!(
                "Runtime trace joined: {} anchors over {} trace(s)",
                plan.requests.len(),
                traces.len()
            );
        }
        Command::RuntimeEvidenceValidate { plan, evidence } => {
            let plan = fact_mine_rust::runtime_protocol::read_trace_plan(&plan)?;
            let evidence = fact_mine_rust::runtime_protocol::read_runtime_evidence(&evidence)?;
            fact_mine_rust::runtime_protocol::validate_runtime_evidence(&plan, &evidence)?;
            eprintln!(
                "Runtime evidence valid: {} runs, {} exact anchors",
                evidence.runs.len(),
                evidence.anchors.len()
            );
        }
        Command::LuaScip {
            files,
            output,
            root,
            server,
        } => {
            let generated =
                fact_mine_rust::lua_scip::generate(&files, root.as_deref(), server.as_deref())?;
            if let Some(output) = output {
                fs::write(&output, &generated.json)
                    .with_context(|| format!("failed to write {}", output.display()))?;
            } else {
                println!("{}", generated.json);
            }
            eprintln!(
                "Lua SCIP: {} calls, {} semantic occurrences, {} project definitions, {} external definitions, {} unresolved",
                generated.stats.calls,
                generated.stats.semantic_occurrences,
                generated.stats.project_definitions,
                generated.stats.external_definitions,
                generated.stats.unresolved_calls,
            );
        }
        Command::RuntimeScip {
            files,
            plan,
            evidence,
            output,
            root,
            language_override,
        } => {
            let language_override = language_override
                .as_deref()
                .map(Language::parse)
                .transpose()?;
            let root = root
                .unwrap_or(std::env::current_dir().context("failed to determine project root")?);
            let files = canonical_runtime_sources(&files, &root)?;
            let supplied_plan = fact_mine_rust::runtime_protocol::read_trace_plan(&plan)?;
            let plan_files = supplied_plan
                .documents
                .iter()
                .map(|document| root.join(&document.relative_path))
                .collect::<Vec<_>>();
            let (mut profile, plan_profile) =
                build_profile_pair(&files, &plan_files, language_override)?;
            // Runtime discovery may add workspace callees to the analysis
            // corpus after collection. Those files are useful declaration
            // context, but were never evidence anchors and therefore must not
            // alter the trace-plan digest. Rebuild anchor bindings from the
            // exact document set named by the validated plan.
            let rebuilt = fact_mine_rust::runtime_protocol::build_trace_plan_with_bindings(
                &plan_profile,
                &plan_files,
                &root,
            )?;
            if supplied_plan.plan_digest != rebuilt.plan.plan_digest {
                bail!("supplied runtime trace plan does not describe the current source snapshot");
            }
            let evidence = fact_mine_rust::runtime_protocol::read_runtime_evidence(&evidence)?;
            let overlay = fact_mine_rust::runtime_evidence::apply_protocol_to_profile(
                &mut profile,
                &rebuilt,
                &evidence,
            )?;
            let rendered = serde_json::to_string_pretty(&overlay.index)? + "\n";
            if let Some(output) = output {
                fs::write(&output, rendered)
                    .with_context(|| format!("failed to write {}", output.display()))?;
            } else {
                print!("{rendered}");
            }
            eprintln!(
                "Runtime SCIP: {} observed sites, {} inferred sites, {} typed receivers, {} occurrences",
                overlay.stats.observed_call_sites,
                overlay.stats.inferred_call_sites,
                overlay.stats.typed_receivers,
                overlay.stats.emitted_occurrences,
            );
        }
    }
    Ok(())
}

fn copy_profile_artifact(source: &std::path::Path, destination: Option<&PathBuf>) -> Result<()> {
    if let Some(destination) = destination {
        fs::copy(source, destination)?;
        return Ok(());
    }
    let mut source = fs::File::open(source)?;
    let stdout = std::io::stdout();
    let mut writer = BufWriter::new(stdout.lock());
    std::io::copy(&mut source, &mut writer)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

/// Stream the typed profile directly to its destination. Portable artifacts
/// intentionally retain the value projection because path rewriting is a
/// JSON-tree transformation; ordinary artifacts never allocate that second
/// representation or a complete output string.
fn write_profile_artifact(
    output: &profile::ProfileOutput,
    destination: Option<&PathBuf>,
    portable: bool,
) -> Result<()> {
    if let Some(path) = destination {
        let file = fs::File::create(path)
            .with_context(|| format!("failed to create {}", path.display()))?;
        let buffered = BufWriter::new(file);
        if path.extension().and_then(|extension| extension.to_str()) == Some("gz") {
            let mut encoder = GzEncoder::new(buffered, Compression::fast());
            write_profile_json(output, portable, &mut encoder)?;
            encoder.finish()?.flush()?;
        } else {
            let mut writer = buffered;
            write_profile_json(output, portable, &mut writer)?;
            writer.flush()?;
        }
        return Ok(());
    }
    let stdout = std::io::stdout();
    let mut writer = BufWriter::new(stdout.lock());
    write_profile_json(output, portable, &mut writer)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

fn write_text_artifact(contents: &str, destination: Option<&PathBuf>) -> Result<()> {
    if let Some(path) = destination {
        let file = fs::File::create(path)
            .with_context(|| format!("failed to create {}", path.display()))?;
        let buffered = BufWriter::new(file);
        if path.extension().and_then(|extension| extension.to_str()) == Some("gz") {
            let mut encoder = GzEncoder::new(buffered, Compression::fast());
            encoder.write_all(contents.as_bytes())?;
            encoder.finish()?.flush()?;
        } else {
            let mut writer = buffered;
            writer.write_all(contents.as_bytes())?;
            writer.flush()?;
        }
    } else {
        print!("{contents}");
    }
    Ok(())
}

fn write_profile_json(
    output: &profile::ProfileOutput,
    portable: bool,
    writer: &mut impl Write,
) -> Result<()> {
    if !portable {
        serde_json::to_writer(writer, output)?;
        return Ok(());
    }
    let mut value = serde_json::to_value(output)?;
    if let Ok(current_dir) = std::env::current_dir() {
        fact_mine_rust::profile::normalize_paths(&mut value, &current_dir);
    }
    serde_json::to_writer(writer, &value)?;
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
        Ok((
            profile::extract_local(&document, selected_profile),
            document.parse_recovered.then(|| profile::ParseRecovery {
                path: file.to_string_lossy().to_string(),
                spans: document.parse_recovery_spans,
            }),
        ))
    })?;
    let parse_recovery_files = all_outputs
        .iter()
        .filter_map(|(_, recovered)| recovered.as_ref().map(|recovery| recovery.path.clone()))
        .collect();
    let parse_recoveries = all_outputs
        .iter()
        .filter_map(|(_, recovered)| recovered.clone())
        .collect();
    let mut output = profile::ProjectFactFinalizer::new(selected_profile)
        .finalize(all_outputs.into_iter().map(|(output, _)| output).collect());
    output.input_coverage = profile::InputCoverage {
        selected_files: files.len(),
        parsed_files: files.len(),
        parse_recovery_files,
        parse_recoveries,
    };
    Ok(output)
}

/// The analysis profile and the trace-plan profile are extracted from the same
/// sources, so parse each file once and run both extractions over it. Building
/// them separately parsed the whole snapshot twice.
/// Which files this collect was told hold non-production code. A fact about the
/// collect, not about any traced program, so it is read once here.
fn read_nonproduction(
    source_roles: Option<&std::path::Path>,
    root: &std::path::Path,
) -> std::collections::BTreeSet<String> {
    source_roles
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .map(|roles| {
            roles["nonproduction"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|entry| entry.as_str())
                .map(|entry| root.join(entry).to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default()
}

/// The overlay itself: parse the sources, rebuild the plan they describe, check
/// it still names the same snapshot, and lay the observed values over it.
fn runtime_scip_overlay(
    root: &std::path::Path,
    files: &[PathBuf],
    plan: &std::path::Path,
    evidence: &std::path::Path,
) -> Result<fact_mine_rust::runtime_evidence::RuntimeScipOverlay> {
    let files = canonical_runtime_sources(files, root)?;
    let supplied = fact_mine_rust::runtime_protocol::read_trace_plan(plan)?;
    let plan_files = supplied
        .documents
        .iter()
        .map(|document| root.join(&document.relative_path))
        .collect::<Vec<_>>();
    let (mut profile, plan_profile) = build_profile_pair(&files, &plan_files, None)?;
    let rebuilt = fact_mine_rust::runtime_protocol::build_trace_plan_with_bindings(
        &plan_profile,
        &plan_files,
        root,
    )?;
    if supplied.plan_digest != rebuilt.plan.plan_digest {
        bail!("supplied runtime trace plan does not describe the current source snapshot");
    }
    let evidence = fact_mine_rust::runtime_protocol::read_runtime_evidence(evidence)?;
    fact_mine_rust::runtime_evidence::apply_protocol_to_profile(&mut profile, &rebuilt, &evidence)
}

fn build_profile_pair(
    analysis_files: &[PathBuf],
    plan_files: &[PathBuf],
    language_override: Option<Language>,
) -> Result<(profile::ProfileOutput, profile::ProfileOutput)> {
    let mut union = Vec::new();
    for file in analysis_files.iter().chain(plan_files) {
        if !union.contains(file) {
            union.push(file.clone());
        }
    }
    let wanted = |files: &[PathBuf], file: &PathBuf| files.contains(file);
    let parsed = parallel::map_ordered(&union, |file| {
        let language = if let Some(language) = language_override {
            language
        } else {
            Language::for_path(file)
                .with_context(|| format!("cannot detect language for {}", file.display()))?
        };
        let document = syntax::parse_file(file.clone(), language)?;
        let analysis = wanted(analysis_files, file)
            .then(|| profile::extract_local(&document, Profile::Espalier));
        let plan =
            wanted(plan_files, file).then(|| profile::extract_local(&document, Profile::TracePlan));
        Ok((
            analysis,
            plan,
            document.parse_recovered.then(|| profile::ParseRecovery {
                path: file.to_string_lossy().to_string(),
                spans: document.parse_recovery_spans,
            }),
        ))
    })?;

    // Each profile is finalized over its own files, in its own order, so the
    // result is exactly what building it alone would have produced.
    let position = |file: &PathBuf| union.iter().position(|entry| entry == file);
    let mut analysis_shards = Vec::with_capacity(analysis_files.len());
    let mut plan_shards = Vec::with_capacity(plan_files.len());
    for file in analysis_files {
        if let Some(shard) = position(file).and_then(|at| parsed[at].0.clone()) {
            analysis_shards.push(shard);
        }
    }
    for file in plan_files {
        if let Some(shard) = position(file).and_then(|at| parsed[at].1.clone()) {
            plan_shards.push(shard);
        }
    }
    let recoveries = |files: &[PathBuf]| {
        files
            .iter()
            .filter_map(|file| position(file).and_then(|at| parsed[at].2.clone()))
            .collect::<Vec<_>>()
    };
    let finalize = |selected: Profile, files: &[PathBuf], shards: Vec<profile::LocalFactShard>| {
        let recovered = recoveries(files);
        let mut output = profile::ProjectFactFinalizer::new(selected).finalize(shards);
        output.input_coverage = profile::InputCoverage {
            selected_files: files.len(),
            parsed_files: files.len(),
            parse_recovery_files: recovered
                .iter()
                .map(|recovery| recovery.path.clone())
                .collect(),
            parse_recoveries: recovered,
        };
        output
    };
    Ok((
        finalize(Profile::Espalier, analysis_files, analysis_shards),
        finalize(Profile::TracePlan, plan_files, plan_shards),
    ))
}

fn canonical_runtime_sources(files: &[PathBuf], root: &std::path::Path) -> Result<Vec<PathBuf>> {
    files
        .iter()
        .map(|file| {
            let source = if file.is_absolute() {
                file.clone()
            } else {
                root.join(file)
            };
            source.canonicalize().with_context(|| {
                format!("failed to canonicalize runtime source {}", file.display())
            })
        })
        .collect()
}


fn build_requested_profile(
    files: &[PathBuf],
    language_override: Option<Language>,
    profile: Profile,
    incremental_cache: Option<PathBuf>,
    changed_files_only: bool,
) -> Result<profile::ProfileOutput> {
    if let Some(cache_directory) = incremental_cache {
        let root = std::env::current_dir().context("failed to determine cache root")?;
        return Ok(incremental::build_profile(
            files,
            language_override,
            profile,
            &incremental::CacheConfig::new(root, cache_directory),
            changed_files_only,
        )?
        .output);
    }
    build_profile(files, language_override, profile)
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
    /// Assemble the collector's instrumentation plan from static facts.
    NilKillTracePlan {
        static_facts: PathBuf,
        /// True when the file is unreshaped `profile trace-plan` output.
        raw: bool,
        runtime_plan: Option<PathBuf>,
        output: PathBuf,
        root: PathBuf,
        generated_at: String,
        target_dirs: Vec<String>,
        exclude_dirs: Vec<String>,
    },
    /// Emit the runtime SCIP index for a collect, and attest what it covers.
    NilKillScipIndex {
        runtime_dir: PathBuf,
        evidence: PathBuf,
        plan: PathBuf,
        output: PathBuf,
        attestation: PathBuf,
        files: Vec<PathBuf>,
        environment: Vec<String>,
        root: PathBuf,
    },
    /// Build each shard's trace document from the rows it holds.
    NilKillTraceDocument {
        runtime_dirs: Vec<PathBuf>,
        plan: PathBuf,
        root: PathBuf,
    },
    /// Write the flat plan a traced program reads.
    NilKillCollectorPlan {
        plan: PathBuf,
        output: PathBuf,
        target_dirs: Vec<String>,
        root: PathBuf,
    },
    /// Shape the collector's documents into the rows the pipeline reads.
    NilKillCollectorExport {
        runtime_dirs: Vec<PathBuf>,
        plan: Option<PathBuf>,
        source_roles: Option<PathBuf>,
        root: PathBuf,
    },
    /// Turn the collector's raw observations into value domains.
    NilKillDeriveDomains {
        inputs: Vec<PathBuf>,
        source_roles: Option<PathBuf>,
        root: PathBuf,
    },
    NilKillDecodeCalls {
        input: PathBuf,
        root: PathBuf,
    },
    SyntaxFacts {
        language: Option<String>,
        files: Vec<PathBuf>,
    },
    Profile {
        profile: String,
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        language_override: Option<String>,
        scip_indexes: Vec<PathBuf>,
        semantic_environments: Vec<PathBuf>,
        complexity_summaries: Vec<PathBuf>,
        bundled_complexity_summaries: bool,
        portable: bool,
        incremental_cache: Option<PathBuf>,
        changed_files_only: bool,
    },
    CallResolution {
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        language_override: Option<String>,
        format: String,
        scip_indexes: Vec<PathBuf>,
        semantic_environments: Vec<PathBuf>,
        complexity_summaries: Vec<PathBuf>,
        bundled_complexity_summaries: bool,
    },
    LuaScip {
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        root: Option<PathBuf>,
        server: Option<PathBuf>,
    },
    RuntimeScip {
        files: Vec<PathBuf>,
        plan: PathBuf,
        evidence: PathBuf,
        output: Option<PathBuf>,
        root: Option<PathBuf>,
        language_override: Option<String>,
    },
    RuntimePlan {
        files: Vec<PathBuf>,
        output: Option<PathBuf>,
        root: Option<PathBuf>,
        language_override: Option<String>,
    },
    RuntimeEvidenceValidate {
        plan: PathBuf,
        evidence: PathBuf,
    },
    RuntimeTrace {
        plan: PathBuf,
        traces: Vec<PathBuf>,
        output: Option<PathBuf>,
        to_stdout: bool,
        merged: Option<PathBuf>,
        root: PathBuf,
    },
}

fn parse_args(args: Vec<String>) -> Result<Command> {
    let mut iter = args.into_iter();
    let command = iter.next().unwrap_or_default();

    match command.as_str() {
        "nil-kill-trace-plan" => {
            let mut static_facts = None;
            let mut raw = false;
            let mut runtime_plan = None;
            let mut output = None;
            let mut root = None;
            let mut generated_at = None;
            let mut target_dirs = Vec::new();
            let mut exclude_dirs = Vec::new();
            while let Some(arg) = iter.next() {
                let mut take = |name: &str| -> Result<String> {
                    iter.next().with_context(|| format!("{name} requires a value"))
                };
                match arg.as_str() {
                    "--static-facts" => static_facts = Some(PathBuf::from(take("--static-facts")?)),
                    "--raw-facts" => {
                        static_facts = Some(PathBuf::from(take("--raw-facts")?));
                        raw = true;
                    }
                    "--runtime-plan" => runtime_plan = Some(PathBuf::from(take("--runtime-plan")?)),
                    "--output" => output = Some(PathBuf::from(take("--output")?)),
                    "--root" => root = Some(PathBuf::from(take("--root")?)),
                    "--generated-at" => generated_at = Some(take("--generated-at")?),
                    "--target-dir" => target_dirs.push(take("--target-dir")?),
                    "--exclude-dir" => exclude_dirs.push(take("--exclude-dir")?),
                    other => bail!("unsupported option: {other}"),
                }
            }
            Ok(Command::NilKillTracePlan {
                static_facts: static_facts.context("--static-facts is required")?,
                raw,
                runtime_plan,
                output: output.context("--output is required")?,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
                generated_at: generated_at.unwrap_or_default(),
                target_dirs,
                exclude_dirs,
            })
        }
        "nil-kill-scip-index" => {
            let mut runtime_dir = None;
            let mut evidence = None;
            let mut plan = None;
            let mut output = None;
            let mut attestation = None;
            let mut files = Vec::new();
            let mut environment = Vec::new();
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--runtime-dir" => {
                        runtime_dir = Some(PathBuf::from(iter.next().context("--runtime-dir")?));
                    }
                    "--evidence" => {
                        evidence = Some(PathBuf::from(iter.next().context("--evidence")?));
                    }
                    "--plan" => plan = Some(PathBuf::from(iter.next().context("--plan")?)),
                    "--output" => output = Some(PathBuf::from(iter.next().context("--output")?)),
                    "--attestation" => {
                        attestation = Some(PathBuf::from(iter.next().context("--attestation")?));
                    }
                    "--file" => files.push(PathBuf::from(iter.next().context("--file")?)),
                    "--environment" => environment.push(iter.next().context("--environment")?),
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            Ok(Command::NilKillScipIndex {
                runtime_dir: runtime_dir.context("--runtime-dir is required")?,
                evidence: evidence.context("--evidence is required")?,
                plan: plan.context("--plan is required")?,
                output: output.context("--output is required")?,
                attestation: attestation.context("--attestation is required")?,
                files,
                environment,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "nil-kill-trace-document" => {
            let mut runtime_dirs = Vec::new();
            let mut plan = None;
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--runtime-dir" => {
                        runtime_dirs.push(PathBuf::from(iter.next().context("--runtime-dir")?));
                    }
                    "--plan" => plan = Some(PathBuf::from(iter.next().context("--plan")?)),
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            Ok(Command::NilKillTraceDocument {
                runtime_dirs,
                plan: plan.context("--plan is required")?,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "nil-kill-collector-plan" => {
            let mut plan = None;
            let mut output = None;
            let mut target_dirs = Vec::new();
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--plan" => plan = Some(PathBuf::from(iter.next().context("--plan")?)),
                    "--output" => output = Some(PathBuf::from(iter.next().context("--output")?)),
                    "--target-dir" => target_dirs.push(iter.next().context("--target-dir")?),
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            Ok(Command::NilKillCollectorPlan {
                plan: plan.context("--plan is required")?,
                output: output.context("--output is required")?,
                target_dirs,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "nil-kill-collector-export" => {
            let mut runtime_dirs = Vec::new();
            let mut plan = None;
            let mut source_roles = None;
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--runtime-dir" => {
                        runtime_dirs.push(PathBuf::from(iter.next().context("--runtime-dir")?));
                    }
                    "--plan" => plan = Some(PathBuf::from(iter.next().context("--plan")?)),
                    "--source-roles" => {
                        source_roles = Some(PathBuf::from(iter.next().context("--source-roles")?));
                    }
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            if runtime_dirs.is_empty() {
                bail!("nil-kill-collector-export requires at least one --runtime-dir");
            }
            Ok(Command::NilKillCollectorExport {
                runtime_dirs,
                plan,
                source_roles,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "nil-kill-derive-domains" => {
            let mut inputs = Vec::new();
            let mut source_roles = None;
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--input" => inputs.push(PathBuf::from(iter.next().context("--input")?)),
                    "--source-roles" => {
                        source_roles = Some(PathBuf::from(iter.next().context("--source-roles")?));
                    }
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            if inputs.is_empty() {
                bail!("nil-kill-derive-domains requires at least one --input");
            }
            Ok(Command::NilKillDeriveDomains {
                inputs,
                source_roles,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "nil-kill-decode-calls" => {
            let mut input = None;
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--input" => input = Some(PathBuf::from(iter.next().context("--input")?)),
                    "--root" => root = Some(PathBuf::from(iter.next().context("--root")?)),
                    other => bail!("unsupported option: {other}"),
                }
            }
            Ok(Command::NilKillDecodeCalls {
                input: input.context("--input is required")?,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "runtime-plan" => {
            let mut output = None;
            let mut root = None;
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
                    "--root" => {
                        root = Some(PathBuf::from(
                            iter.next().with_context(|| "--root requires a value")?,
                        ));
                    }
                    other if other.starts_with("--root=") => {
                        root = Some(PathBuf::from(other.strip_prefix("--root=").unwrap()));
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
                bail!("runtime-plan requires at least one source file");
            }
            Ok(Command::RuntimePlan {
                files,
                output,
                root,
                language_override,
            })
        }
        "runtime-trace" => {
            let mut plan = None;
            let mut traces: Vec<PathBuf> = Vec::new();
            let mut output = None;
            let mut to_stdout = false;
            let mut merged = None;
            let mut root = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--plan" => {
                        plan = Some(PathBuf::from(
                            iter.next().with_context(|| "--plan requires a value")?,
                        ));
                    }
                    other if other.starts_with("--plan=") => {
                        plan = Some(PathBuf::from(other.strip_prefix("--plan=").unwrap()));
                    }
                    "--runtime-trace" => {
                        traces.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--runtime-trace requires a value")?,
                        ));
                    }
                    other if other.starts_with("--runtime-trace=") => {
                        traces.push(PathBuf::from(
                            other.strip_prefix("--runtime-trace=").unwrap(),
                        ));
                    }
                    "--stdout" => {
                        to_stdout = true;
                    }
                    "--merged-output" => {
                        merged = Some(PathBuf::from(
                            iter.next().with_context(|| "--merged-output requires a value")?,
                        ));
                    }
                    other if other.starts_with("--merged-output=") => {
                        merged = Some(PathBuf::from(
                            other.strip_prefix("--merged-output=").unwrap(),
                        ));
                    }
                    "--output" => {
                        output = Some(PathBuf::from(
                            iter.next().with_context(|| "--output requires a value")?,
                        ));
                    }
                    other if other.starts_with("--output=") => {
                        output = Some(PathBuf::from(other.strip_prefix("--output=").unwrap()));
                    }
                    "--root" => {
                        root = Some(PathBuf::from(
                            iter.next().with_context(|| "--root requires a value")?,
                        ));
                    }
                    other if other.starts_with("--root=") => {
                        root = Some(PathBuf::from(other.strip_prefix("--root=").unwrap()));
                    }
                    other => bail!("unsupported runtime-trace argument: {other}"),
                }
            }
            if traces.is_empty() {
                bail!("runtime-trace requires at least one --runtime-trace FILE");
            }
            if (output.is_some() || to_stdout) && traces.len() > 1 {
                bail!("--output/--stdout name one document; joining several writes each beside its own");
            }
            Ok(Command::RuntimeTrace {
                plan: plan.with_context(|| "runtime-trace requires --plan FILE")?,
                traces,
                output,
                to_stdout,
                merged,
                root: root.unwrap_or_else(|| PathBuf::from(".")),
            })
        }
        "runtime-evidence" => {
            let operation = iter
                .next()
                .with_context(|| "runtime-evidence requires an operation; use validate")?;
            if operation != "validate" {
                bail!("unsupported runtime-evidence operation {operation:?}; use validate");
            }
            let mut plan = None;
            let mut evidence = None;
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--plan" => {
                        plan = Some(PathBuf::from(
                            iter.next().with_context(|| "--plan requires a value")?,
                        ));
                    }
                    other if other.starts_with("--plan=") => {
                        plan = Some(PathBuf::from(other.strip_prefix("--plan=").unwrap()));
                    }
                    "--evidence" => {
                        evidence = Some(PathBuf::from(
                            iter.next().with_context(|| "--evidence requires a value")?,
                        ));
                    }
                    other if other.starts_with("--evidence=") => {
                        evidence =
                            Some(PathBuf::from(other.strip_prefix("--evidence=").unwrap()));
                    }
                    other => bail!("unsupported runtime-evidence validate argument: {other}"),
                }
            }
            Ok(Command::RuntimeEvidenceValidate {
                plan: plan.with_context(|| "runtime-evidence validate requires --plan FILE")?,
                evidence: evidence
                    .with_context(|| "runtime-evidence validate requires --evidence FILE")?,
            })
        }
        "runtime-scip" => {
            let mut output = None;
            let mut plan = None;
            let mut evidence = None;
            let mut root = None;
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
                    "--runtime-evidence" => {
                        evidence = Some(PathBuf::from(
                            iter.next()
                                .with_context(|| "--runtime-evidence requires a value")?,
                        ));
                    }
                    other if other.starts_with("--runtime-evidence=") => {
                        evidence = Some(PathBuf::from(
                            other.strip_prefix("--runtime-evidence=").unwrap(),
                        ));
                    }
                    "--trace-plan" => {
                        plan = Some(PathBuf::from(
                            iter.next().with_context(|| "--trace-plan requires a value")?,
                        ));
                    }
                    other if other.starts_with("--trace-plan=") => {
                        plan = Some(PathBuf::from(
                            other.strip_prefix("--trace-plan=").unwrap(),
                        ));
                    }
                    "--root" => {
                        root = Some(PathBuf::from(
                            iter.next().with_context(|| "--root requires a value")?,
                        ));
                    }
                    other if other.starts_with("--root=") => {
                        root = Some(PathBuf::from(other.strip_prefix("--root=").unwrap()));
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
                bail!("runtime-scip requires at least one source file");
            }
            let evidence =
                evidence.with_context(|| "runtime-scip requires --runtime-evidence FILE")?;
            let plan = plan.with_context(|| "runtime-scip requires --trace-plan FILE")?;
            Ok(Command::RuntimeScip {
                files,
                plan,
                evidence,
                output,
                root,
                language_override,
            })
        }
        "scip-lua" => {
            let mut output = None;
            let mut root = None;
            let mut server = None;
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
                    "--root" => {
                        root = Some(PathBuf::from(
                            iter.next().with_context(|| "--root requires a value")?,
                        ));
                    }
                    other if other.starts_with("--root=") => {
                        root = Some(PathBuf::from(other.strip_prefix("--root=").unwrap()));
                    }
                    "--lua-language-server" => {
                        server = Some(PathBuf::from(
                            iter.next()
                                .with_context(|| "--lua-language-server requires a value")?,
                        ));
                    }
                    other if other.starts_with("--lua-language-server=") => {
                        server = Some(PathBuf::from(
                            other.strip_prefix("--lua-language-server=").unwrap(),
                        ));
                    }
                    other if other.starts_with("--") => bail!("unsupported option: {other}"),
                    path => files.push(PathBuf::from(path)),
                }
            }
            if files.is_empty() {
                bail!("scip-lua requires at least one Lua file");
            }
            Ok(Command::LuaScip {
                files,
                output,
                root,
                server,
            })
        }
        "syntax-facts" => {
            let mut language = None;
            let mut files = Vec::new();
            while let Some(arg) = iter.next() {
                match arg.as_str() {
                    "--language" => {
                        language =
                            Some(iter.next().with_context(|| "--language requires a value")?);
                    }
                    other if other.starts_with("--language=") => {
                        language = Some(other.strip_prefix("--language=").unwrap().to_string());
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
            let mut semantic_environments = Vec::new();
            let mut complexity_summaries = Vec::new();
            let mut bundled_complexity_summaries = true;
            let mut portable = false;
            let mut incremental_cache = None;
            let mut changed_files_only = false;
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
                    "--semantic-environment" => {
                        semantic_environments.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--semantic-environment requires a value")?,
                        ));
                    }
                    other if other.starts_with("--semantic-environment=") => {
                        semantic_environments.push(PathBuf::from(
                            other.strip_prefix("--semantic-environment=").unwrap(),
                        ));
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
                    "--no-bundled-complexity-summaries" => {
                        bundled_complexity_summaries = false;
                    }
                    "--portable" => {
                        portable = true;
                    }
                    "--incremental" => {
                        incremental_cache = Some(PathBuf::from(".lineage/cache/fact-mine"));
                    }
                    "--incremental-cache" => {
                        incremental_cache = Some(PathBuf::from(
                            iter.next()
                                .with_context(|| "--incremental-cache requires a value")?,
                        ));
                    }
                    other if other.starts_with("--incremental-cache=") => {
                        incremental_cache = Some(PathBuf::from(
                            other.strip_prefix("--incremental-cache=").unwrap(),
                        ));
                    }
                    "--changed-files-only" => {
                        changed_files_only = true;
                    }
                    other if other.starts_with("--") => bail!("unsupported option: {other}"),
                    path => files.push(PathBuf::from(path)),
                }
            }
            if files.is_empty() {
                bail!("profile requires at least one file");
            }
            if changed_files_only && incremental_cache.is_none() {
                bail!("--changed-files-only requires --incremental or --incremental-cache");
            }
            Ok(Command::Profile {
                profile,
                files,
                output,
                language_override,
                scip_indexes,
                semantic_environments,
                complexity_summaries,
                bundled_complexity_summaries,
                portable,
                incremental_cache,
                changed_files_only,
            })
        }
        "call-resolution" => {
            let mut output = None;
            let mut language_override = None;
            let mut format = "text".to_string();
            let mut files = Vec::new();
            let mut scip_indexes = Vec::new();
            let mut semantic_environments = Vec::new();
            let mut complexity_summaries = Vec::new();
            let mut bundled_complexity_summaries = true;
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
                    "--semantic-environment" => {
                        semantic_environments.push(PathBuf::from(
                            iter.next()
                                .with_context(|| "--semantic-environment requires a value")?,
                        ));
                    }
                    other if other.starts_with("--semantic-environment=") => {
                        semantic_environments.push(PathBuf::from(
                            other.strip_prefix("--semantic-environment=").unwrap(),
                        ));
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
                    "--no-bundled-complexity-summaries" => {
                        bundled_complexity_summaries = false;
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
                semantic_environments,
                complexity_summaries,
                bundled_complexity_summaries,
            })
        }
        other => bail!(
            "usage: fact-mine-rust {{syntax-facts|profile|call-resolution|runtime-plan|runtime-evidence|runtime-scip|scip-lua}} FILE... (got: {other})"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn profile_reports_parser_recovery_locations() {
        let mut file = tempfile::NamedTempFile::new().expect("tempfile");
        file.write_all(b"def broken(\n").expect("write source");

        let profile = build_profile(
            &[file.path().to_path_buf()],
            Some(Language::Ruby),
            Profile::Espalier,
        )
        .expect("build profile");

        assert_eq!(profile.input_coverage.selected_files, 1);
        assert_eq!(profile.input_coverage.parsed_files, 1);
        assert_eq!(profile.input_coverage.parse_recovery_files.len(), 1);
        assert_eq!(profile.input_coverage.parse_recoveries.len(), 1);
        assert!(!profile.input_coverage.parse_recoveries[0].spans.is_empty());
    }

    #[test]
    fn incremental_profile_options_select_a_complete_or_partial_cache_run() {
        let parsed = parse_args(vec![
            "profile".to_string(),
            "espalier".to_string(),
            "--incremental-cache=.cache".to_string(),
            "--changed-files-only".to_string(),
            "example.rb".to_string(),
        ])
        .expect("parse incremental profile");
        match parsed {
            Command::Profile {
                incremental_cache,
                changed_files_only,
                files,
                ..
            } => {
                assert_eq!(incremental_cache, Some(PathBuf::from(".cache")));
                assert!(changed_files_only);
                assert_eq!(files, vec![PathBuf::from("example.rb")]);
            }
            _ => panic!("expected profile command"),
        }
        assert!(parse_args(vec![
            "profile".to_string(),
            "espalier".to_string(),
            "--changed-files-only".to_string(),
            "example.rb".to_string(),
        ])
        .is_err());
    }

    #[test]
    fn stdlib_producer_can_disable_bundled_summaries() {
        let parsed = parse_args(vec![
            "profile".to_string(),
            "espalier".to_string(),
            "--no-bundled-complexity-summaries".to_string(),
            "stdlib.go".to_string(),
        ])
        .expect("parse stdlib producer profile");
        match parsed {
            Command::Profile {
                bundled_complexity_summaries,
                ..
            } => assert!(!bundled_complexity_summaries),
            _ => panic!("expected profile command"),
        }
    }

    #[test]
    fn profile_accepts_semantic_environment_sidecars() {
        let parsed = parse_args(vec![
            "profile".to_string(),
            "espalier".to_string(),
            "--semantic-environment=runtime.json".to_string(),
            "--semantic-environment".to_string(),
            "target.json".to_string(),
            "example.cpp".to_string(),
        ])
        .expect("parse semantic environment profile");
        match parsed {
            Command::Profile {
                semantic_environments,
                files,
                ..
            } => {
                assert_eq!(
                    semantic_environments,
                    vec![PathBuf::from("runtime.json"), PathBuf::from("target.json")]
                );
                assert_eq!(files, vec![PathBuf::from("example.cpp")]);
            }
            _ => panic!("expected profile command"),
        }
    }

    #[test]
    fn runtime_scip_requires_evidence_and_accepts_language_neutral_sources() {
        let parsed = parse_args(vec![
            "runtime-scip".to_string(),
            "--trace-plan=runtime-plan.json".to_string(),
            "--runtime-evidence=runtime-evidence.v1.json.gz".to_string(),
            "--output".to_string(),
            "runtime.scip.json".to_string(),
            "one.rb".to_string(),
            "two.py".to_string(),
        ])
        .expect("runtime SCIP command");
        match parsed {
            Command::RuntimeScip {
                files,
                plan,
                evidence,
                output,
                root,
                language_override,
            } => {
                assert_eq!(
                    files,
                    vec![PathBuf::from("one.rb"), PathBuf::from("two.py")]
                );
                assert_eq!(plan, PathBuf::from("runtime-plan.json"));
                assert_eq!(evidence, PathBuf::from("runtime-evidence.v1.json.gz"));
                assert_eq!(output, Some(PathBuf::from("runtime.scip.json")));
                assert_eq!(root, None);
                assert_eq!(language_override, None);
            }
            _ => panic!("expected runtime SCIP"),
        }
        assert!(parse_args(vec!["runtime-scip".to_string(), "one.rb".to_string()]).is_err());
    }

    #[test]
    fn runtime_scip_rebuilds_anchor_bindings_from_plan_documents_not_discovered_callees() {
        let directory = tempfile::tempdir().expect("tempdir");
        let planned = directory.path().join("planned.rb");
        let discovered = directory.path().join("discovered.rb");
        std::fs::write(
            &planned,
            "class Planned\n  def run(value)\n    value.size\n  end\nend\n",
        )
        .expect("planned source");
        std::fs::write(
            &discovered,
            "class Discovered\n  def helper\n    1\n  end\nend\n",
        )
        .expect("discovered source");
        let planned_profile =
            build_profile(std::slice::from_ref(&planned), None, Profile::TracePlan)
                .expect("planned profile");
        let supplied = fact_mine_rust::runtime_protocol::build_trace_plan_with_bindings(
            &planned_profile,
            std::slice::from_ref(&planned),
            directory.path(),
        )
        .expect("supplied plan");

        // `discovered` exists and participates in the full analysis corpus, but
        // only `planned` owns evidence anchors. Both profiles come out of one
        // parse of the union, so this also proves the shared parse does not let
        // the wider corpus reach the plan.
        let plan_files = supplied
            .plan
            .documents
            .iter()
            .map(|document| directory.path().join(&document.relative_path))
            .collect::<Vec<_>>();
        let (analysis, plan_profile) = build_profile_pair(
            &[planned.clone(), discovered.clone()],
            &plan_files,
            None,
        )
        .expect("profiles");
        assert_eq!(analysis.input_coverage.selected_files, 2);
        assert_eq!(plan_profile.input_coverage.selected_files, 1);
        let rebuilt = fact_mine_rust::runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            &plan_files,
            directory.path(),
        )
        .expect("rebuild");

        assert_eq!(rebuilt.plan.plan_digest, supplied.plan.plan_digest);
        assert_eq!(rebuilt.plan.documents.len(), 1);
        assert_eq!(rebuilt.plan.documents[0].relative_path, "planned.rb");
        assert!(discovered.exists());
    }

    #[test]
    fn runtime_commands_canonicalize_relative_sources_before_binding_calls() {
        let directory = tempfile::tempdir().expect("tempdir");
        let source = directory.path().join("worker.rb");
        std::fs::write(
            &source,
            "class Worker\n  def run(value)\n    value.size\n  end\nend\n",
        )
        .expect("source");
        let files = canonical_runtime_sources(&[PathBuf::from("worker.rb")], directory.path())
            .expect("canonical runtime sources");
        assert_eq!(
            files,
            vec![source.canonicalize().expect("canonical source")]
        );

        let plan_profile =
            build_profile(&files, None, Profile::TracePlan).expect("trace-plan profile");
        let built = fact_mine_rust::runtime_protocol::build_trace_plan_with_bindings(
            &plan_profile,
            &files,
            directory.path(),
        )
        .expect("plan");
        let overlay_profile =
            build_profile(&files, None, Profile::Espalier).expect("overlay profile");
        let overlay_call_ids = overlay_profile
            .calls
            .iter()
            .map(|call| call.id.as_str())
            .collect::<std::collections::BTreeSet<_>>();

        assert!(built.bindings.values().all(|binding| match binding {
            fact_mine_rust::runtime_protocol::AnchorBinding::Call { call_id } =>
                overlay_call_ids.contains(call_id.as_str()),
            _ => true,
        }));
    }

    #[test]
    fn requested_incremental_profile_emits_cache_scope() {
        let directory = tempfile::tempdir().expect("tempdir");
        let source = directory.path().join("example.rb");
        std::fs::write(&source, "class Example; def run; 1; end; end\n").expect("write source");
        let clean =
            build_profile(&[source.clone()], None, Profile::Espalier).expect("build clean profile");
        let output = build_requested_profile(
            &[source],
            None,
            Profile::Espalier,
            Some(directory.path().join("cache")),
            false,
        )
        .expect("build incremental profile");
        assert_eq!(
            output
                .artifact_scope
                .as_ref()
                .map(|scope| scope.kind.as_str()),
            Some("complete")
        );
        let mut incremental_json = serde_json::to_value(output).expect("serialize incremental");
        incremental_json
            .as_object_mut()
            .expect("object")
            .remove("artifact_scope");
        incremental_json
            .as_object_mut()
            .expect("object")
            .remove("incremental_metrics");
        assert_eq!(
            incremental_json,
            serde_json::to_value(clean).expect("serialize clean"),
        );
    }

    #[test]
    fn profile_artifacts_stream_compact_json_and_gzip() {
        let directory = tempfile::tempdir().expect("tempdir");
        let output = profile::ProfileOutput::default();
        let json = directory.path().join("profile.json");
        let gzip = directory.path().join("profile.json.gz");

        write_profile_artifact(&output, Some(&json), false).expect("write compact artifact");
        let expected = serde_json::to_string(&output).expect("expected json");
        assert_eq!(std::fs::read_to_string(&json).expect("json"), expected);

        write_profile_artifact(&output, Some(&gzip), false).expect("write gzip artifact");
        let compressed = std::fs::read(&gzip).expect("gzip");
        let mut decoder = flate2::read::GzDecoder::new(compressed.as_slice());
        let mut decoded = String::new();
        std::io::Read::read_to_string(&mut decoder, &mut decoded).expect("decode gzip");
        assert_eq!(decoded, expected);
    }
}
