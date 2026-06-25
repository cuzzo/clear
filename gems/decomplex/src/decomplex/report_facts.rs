use crate::decomplex::detectors::{
    co_update, decision_pressure, derived_state, false_simplicity, fat_union, flay_similarity,
    function_lcom, implicit_control_flow, inconsistent_rename_clone, local_flow, locality_drag,
    miner, operational_discontinuity, oversized_predicate, path_condition, predicate_alias,
    redundant_nil_guard, semantic_alias, sequence_mine, state_branch_density, state_mesh,
    superfluous_state, temporal_ordering_pressure, weighted_inlined_cognitive_complexity,
};
use crate::decomplex::parallel;
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub const FORMAT: &str = "decomplex.report-facts.v1";

const DEFAULT_MASS: usize = 32;
const DEFAULT_FUZZY: usize = 1;
const DEFAULT_EXCLUDE_DIRS: &[&str] = &[
    ".clear-cache",
    ".clear-transpile-cache",
    ".global-zig-cache",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "node_modules",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VcsFilter {
    Git,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub language: Option<Language>,
    pub excludes: Vec<String>,
    pub mass: usize,
    pub fuzzy: usize,
    pub vcs: Option<VcsFilter>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            language: None,
            excludes: Vec::new(),
            mass: DEFAULT_MASS,
            fuzzy: DEFAULT_FUZZY,
            vcs: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct SourceFile {
    pub path: PathBuf,
    pub language: Language,
}

struct SharedFacts {
    local_summaries: Vec<local_flow::MethodSummary>,
    local_complexity_scores: BTreeMap<(String, String), syntax::LocalComplexityScore>,
    semantic_aliases: semantic_alias::SemanticAliasReport,
}

impl SharedFacts {
    fn new(documents: &[Document]) -> Self {
        let profile = rust_profile_enabled();
        thread::scope(|scope| {
            let local_summaries = scope.spawn(|| {
                let started = Instant::now();
                let result = local_flow::scan_documents(documents);
                profile_phase(profile, "shared.local_summaries", started.elapsed());
                result
            });
            let local_complexity_scores = scope.spawn(|| {
                let started = Instant::now();
                let result = local_complexity_scores(documents);
                profile_phase(profile, "shared.local_complexity_scores", started.elapsed());
                result
            });
            let semantic_aliases = scope.spawn(|| {
                let started = Instant::now();
                let result = semantic_alias::scan_documents(documents);
                profile_phase(profile, "shared.semantic_aliases", started.elapsed());
                result
            });
            Self {
                local_summaries: local_summaries.join().expect("local-flow facts worker"),
                local_complexity_scores: local_complexity_scores
                    .join()
                    .expect("local-complexity facts worker"),
                semantic_aliases: semantic_aliases
                    .join()
                    .expect("semantic-alias facts worker"),
            }
        })
    }
}

pub fn collect(targets: &[PathBuf], options: &Options) -> Result<Value> {
    let files = collect_source_files(targets, options)?;
    facts_for_source_files(&files, options)
}

pub fn collect_source_files(targets: &[PathBuf], options: &Options) -> Result<Vec<SourceFile>> {
    let mut files = Vec::new();
    for target in targets {
        expand_target(target, options, &mut files)
            .with_context(|| format!("failed to collect {}", target.display()))?;
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    files.dedup_by(|left, right| left.path == right.path);
    if options.vcs == Some(VcsFilter::Git) && !files.is_empty() {
        retain_git_tracked_files(&mut files)?;
    }
    Ok(files)
}

pub fn facts_for_source_files(files: &[SourceFile], options: &Options) -> Result<Value> {
    if files.is_empty() {
        bail!("facts requires at least one supported source file");
    }

    let profile = rust_profile_enabled();
    let total_started = Instant::now();
    let parse_started = Instant::now();
    let documents = parallel::map_ordered(files, |file| {
        syntax::parse_file_for_report(file.path.clone(), file.language)
    })?;
    profile_phase(profile, "parse", parse_started.elapsed());
    let shared_started = Instant::now();
    let shared = SharedFacts::new(&documents);
    profile_phase(profile, "shared_facts", shared_started.elapsed());
    let group_started = Instant::now();
    let mut groups: BTreeMap<Language, Vec<Document>> = BTreeMap::new();
    for document in documents {
        groups.entry(document.language).or_default().push(document);
    }
    profile_phase(profile, "group_documents", group_started.elapsed());

    let detectors_started = Instant::now();
    let detectors = collect_detector_facts(&groups, &shared, options)?;
    profile_phase(profile, "detectors", detectors_started.elapsed());

    let assemble_started = Instant::now();
    let mut reported_files = files
        .iter()
        .map(|file| file.path.to_string_lossy().to_string())
        .collect::<Vec<_>>();
    reported_files.sort();
    let output = json!({
        "format": FORMAT,
        "files": reported_files,
        "detectors": detectors,
    });
    profile_phase(profile, "assemble_json", assemble_started.elapsed());
    profile_phase(profile, "facts_total", total_started.elapsed());

    Ok(output)
}

fn collect_detector_facts(
    groups: &BTreeMap<Language, Vec<Document>>,
    shared: &SharedFacts,
    options: &Options,
) -> Result<Map<String, Value>> {
    let tasks = detector_tasks(groups, shared, options);
    let jobs = parallel::job_count();
    if jobs <= 1 {
        return run_detector_tasks_sequential(tasks);
    }

    run_detector_tasks_parallel(tasks, jobs)
}

type DetectorTask<'a> = (
    &'static str,
    Box<dyn Fn() -> Result<Value> + Send + Sync + 'a>,
);

fn detector_tasks<'a>(
    groups: &'a BTreeMap<Language, Vec<Document>>,
    shared: &'a SharedFacts,
    options: &'a Options,
) -> Vec<DetectorTask<'a>> {
    let mut tasks: Vec<DetectorTask<'a>> = Vec::new();
    macro_rules! detector_task {
        ($name:expr, $body:expr) => {{
            tasks.push(($name, Box::new(move || -> Result<Value> { $body })));
        }};
    }

    detector_task!("miner", {
        merge_object_reports(
            groups,
            &["missing_abstractions", "neglected_conditions"],
            |documents| json_value(miner::scan_documents(documents)),
        )
    });
    detector_task!("co_update", {
        merge_object_reports(
            groups,
            &["co_written_pairs", "neglected_updates"],
            |documents| json_value(co_update::scan_documents(documents, 10)),
        )
    });
    detector_task!("predicate_alias", {
        merge_object_reports(groups, &["alias_clusters"], |documents| {
            json_value(predicate_alias::scan_documents(documents))
        })
    });
    detector_task!("semantic_alias", {
        json_value(shared.semantic_aliases.clone())
    });
    detector_task!("path_condition", {
        merge_object_reports(groups, &["neglected", "scattered"], |documents| {
            json_value(path_condition::scan_documents(documents))
        })
    });
    detector_task!("sequence_mine", {
        merge_object_reports(groups, &["broken"], |documents| {
            json_value(sequence_mine::scan_documents(documents, 15))
        })
        .map(rename_broken_protocol)
    });
    detector_task!("implicit_control_flow", {
        merge_object_reports(groups, &["ordered_protocols"], |documents| {
            json_value(implicit_control_flow::scan_documents(documents))
        })
    });
    detector_task!("derived_state", {
        merge_array_reports(groups, |documents| {
            let summaries = local_summaries_for_documents(&shared.local_summaries, documents);
            json_value(derived_state::scan_summaries(summaries.as_ref()))
        })
    });
    detector_task!("inconsistent_rename_clone", {
        merge_array_reports(groups, |documents| {
            let summaries = local_summaries_for_documents(&shared.local_summaries, documents);
            json_value(inconsistent_rename_clone::scan_summaries(
                summaries.as_ref(),
            ))
        })
    });
    detector_task!("flay_similarity", {
        merge_array_reports(groups, |documents| {
            json_value(flay_similarity::scan_documents(
                documents,
                options.mass,
                options.fuzzy,
            ))
        })
    });
    detector_task!("decision_pressure", {
        merge_array_reports(groups, |documents| {
            let summaries = local_summaries_for_documents(&shared.local_summaries, documents);
            json_value(decision_pressure::scan_documents_with_summaries(
                documents,
                summaries.as_ref(),
            ))
        })
    });
    detector_task!("redundant_nil_guard", {
        merge_array_reports(groups, |documents| {
            json_value(redundant_nil_guard::scan_documents(documents))
        })
    });
    detector_task!("false_simplicity", {
        merge_array_reports(groups, |documents| {
            json_value(false_simplicity::scan_documents(documents))
        })
    });
    detector_task!("oversized_predicate", {
        Ok(merge_object_reports(groups, &["findings"], |documents| {
            json_value(oversized_predicate::scan_documents(documents))
        })?
        .get("findings")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new())))
    });
    detector_task!("fat_union", {
        merge_object_reports(groups, &["fat_unions"], |documents| {
            json_value(fat_union::scan_documents(documents))
        })
    });
    detector_task!("state_heatmap", {
        state_heatmap_findings_for_groups(groups, &shared.semantic_aliases)
    });
    detector_task!("state_branch_density", {
        merge_array_reports(groups, |documents| {
            json_value(state_branch_density::scan_documents(documents))
        })
    });
    detector_task!("temporal_ordering_pressure", {
        merge_array_reports(groups, |documents| {
            json_value(temporal_ordering_pressure::scan_documents(documents))
        })
    });
    detector_task!("weighted_inlined_complexity", {
        merge_array_reports(groups, |documents| {
            let summaries = local_summaries_for_documents(&shared.local_summaries, documents);
            json_value(
                weighted_inlined_cognitive_complexity::scan_documents_with_summaries(
                    documents,
                    summaries.as_ref(),
                ),
            )
        })
    });
    detector_task!("locality_drag", {
        json_value(locality_drag::scan_summaries_with_scores(
            &shared.local_summaries,
            &shared.local_complexity_scores,
        ))
    });
    detector_task!("function_lcom", {
        json_value(function_lcom::scan_summaries(&shared.local_summaries))
    });
    detector_task!("operational_discontinuity", {
        json_value(operational_discontinuity::scan_summaries(
            &shared.local_summaries,
        ))
    });
    detector_task!("superfluous_state", {
        merge_array_reports(groups, |documents| {
            json_value(superfluous_state::scan_documents(documents))
        })
    });
    tasks
}

fn run_detector_tasks_parallel(
    tasks: Vec<DetectorTask<'_>>,
    jobs: usize,
) -> Result<Map<String, Value>> {
    let worker_count = jobs.min(tasks.len());
    let next_index = AtomicUsize::new(0);
    let (tx, rx) = mpsc::channel();
    thread::scope(|scope| {
        for _ in 0..worker_count {
            let tx = tx.clone();
            let next_index = &next_index;
            let tasks = &tasks;
            scope.spawn(move || loop {
                let index = next_index.fetch_add(1, Ordering::Relaxed);
                if index >= tasks.len() {
                    break;
                }
                let (name, task) = &tasks[index];
                let started = Instant::now();
                let result = task();
                if tx.send((index, *name, started.elapsed(), result)).is_err() {
                    break;
                }
            });
        }
        drop(tx);
    });

    let mut results = (0..tasks.len()).map(|_| None).collect::<Vec<_>>();
    for (index, name, elapsed, result) in rx {
        results[index] = Some((name, elapsed, result));
    }

    collect_detector_task_results(
        results
            .into_iter()
            .map(|row| row.expect("detector task did not return a result")),
    )
}

fn run_detector_tasks_sequential(tasks: Vec<DetectorTask<'_>>) -> Result<Map<String, Value>> {
    collect_detector_task_results(tasks.into_iter().map(|(name, task)| {
        let started = Instant::now();
        let result = task();
        (name, started.elapsed(), result)
    }))
}

fn collect_detector_task_results(
    results: impl IntoIterator<Item = (&'static str, Duration, Result<Value>)>,
) -> Result<Map<String, Value>> {
    let profile = rust_profile_enabled();
    let mut detectors = Map::new();
    let mut first_error = None;
    for (name, elapsed, result) in results {
        profile_phase(profile, &format!("detector.{name}"), elapsed);
        match result {
            Ok(value) => {
                detectors.insert(name.to_string(), value);
            }
            Err(error) => {
                if first_error.is_none() {
                    first_error = Some(error.context(format!("failed to collect {name} facts")));
                }
            }
        }
    }
    if let Some(error) = first_error {
        return Err(error);
    }
    Ok(detectors)
}

fn rust_profile_enabled() -> bool {
    std::env::var_os("DECOMPLEX_RUST_PROFILE").is_some()
}

fn profile_phase(enabled: bool, phase: &str, elapsed: Duration) {
    if enabled {
        eprintln!(
            "decomplex-rust-profile\t{}\t{:.6}",
            phase,
            elapsed.as_secs_f64()
        );
    }
}

fn local_complexity_scores(
    documents: &[Document],
) -> BTreeMap<(String, String), syntax::LocalComplexityScore> {
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

fn local_summaries_for_documents<'a>(
    summaries: &'a [local_flow::MethodSummary],
    documents: &[Document],
) -> Cow<'a, [local_flow::MethodSummary]> {
    let files = documents
        .iter()
        .map(|document| document.file.as_str())
        .collect::<BTreeSet<_>>();
    if summaries
        .iter()
        .all(|summary| files.contains(summary.file.as_str()))
    {
        return Cow::Borrowed(summaries);
    }

    Cow::Owned(
        summaries
            .iter()
            .filter(|summary| files.contains(summary.file.as_str()))
            .cloned()
            .collect(),
    )
}

fn merge_object_reports<F>(
    groups: &BTreeMap<Language, Vec<Document>>,
    fields: &[&str],
    scan: F,
) -> Result<Value>
where
    F: Fn(&[Document]) -> Result<Value>,
{
    let mut merged = Map::new();
    for field in fields {
        merged.insert((*field).to_string(), Value::Array(Vec::new()));
    }

    for (language, documents) in groups {
        let value = scan(documents)?;
        let object = value
            .as_object()
            .with_context(|| format!("{} detector did not return an object", language.as_str()))?;
        for field in fields {
            let rows = object
                .get(*field)
                .and_then(Value::as_array)
                .with_context(|| format!("detector result missing array field {field}"))?;
            merged
                .get_mut(*field)
                .and_then(Value::as_array_mut)
                .expect("merged array")
                .extend(rows.iter().cloned());
        }
    }
    Ok(Value::Object(merged))
}

fn json_value<T: Serialize>(value: T) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}

fn merge_array_reports<F>(groups: &BTreeMap<Language, Vec<Document>>, scan: F) -> Result<Value>
where
    F: Fn(&[Document]) -> Result<Value>,
{
    let mut rows = Vec::new();
    for (language, documents) in groups {
        let value = scan(documents)?;
        rows.extend(
            value
                .as_array()
                .with_context(|| format!("{} detector did not return an array", language.as_str()))?
                .iter()
                .cloned(),
        );
    }
    Ok(Value::Array(rows))
}

fn rename_broken_protocol(mut value: Value) -> Value {
    if let Some(object) = value.as_object_mut() {
        if let Some(rows) = object.remove("broken") {
            object.insert("broken_protocol".to_string(), rows);
        }
    }
    value
}

fn state_heatmap_findings_for_groups(
    groups: &BTreeMap<Language, Vec<Document>>,
    semantic_aliases: &semantic_alias::SemanticAliasReport,
) -> Result<Value> {
    let mut rows = Vec::new();
    for documents in groups.values() {
        let report = state_mesh::scan_documents_with_semantic_aliases_and_min_writes(
            documents,
            semantic_aliases,
            1,
        );
        rows.extend(state_heatmap_findings(&report));
    }
    Ok(Value::Array(rows))
}

fn state_heatmap_findings(report: &state_mesh::StateMeshReport) -> Vec<Value> {
    let mut rows = Vec::new();
    for (field, row) in &report.fields {
        let mut sites = Vec::new();
        sites.extend(row.writers.iter().map(site_location));
        sites.extend(row.readers.iter().map(site_location));
        sites.extend(row.re_derivations.iter().map(re_derivation_location));

        let mut span_map = BTreeMap::new();
        for site in row.writers.iter().chain(row.readers.iter()) {
            let loc = site_location(site);
            span_map
                .entry(loc)
                .and_modify(|span| {
                    if site.span < *span {
                        *span = site.span;
                    }
                })
                .or_insert(site.span);
        }
        let spans = span_map
            .into_iter()
            .map(|(loc, span)| (loc, json!(span)))
            .collect::<Map<_, _>>();

        rows.push(json!({
            "at": sites.first().cloned(),
            "field": field,
            "writes": row.metrics.writes,
            "reads": row.metrics.reads,
            "re_derivations": row.metrics.re_derivations,
            "scatter": row.metrics.scatter,
            "write_scatter": row.metrics.write_scatter,
            "read_scatter": row.metrics.read_scatter,
            "receiver_types": row.metrics.receiver_types,
            "messiness": row.messiness,
            "pressure": row.metrics.pressure,
            "top_writers": row.writers.iter().take(4).map(site_location).collect::<Vec<_>>(),
            "top_readers": row.readers.iter().take(4).map(site_location).collect::<Vec<_>>(),
            "sites": sites.into_iter().take(12).collect::<Vec<_>>(),
            "spans": spans,
        }));
    }
    rows
}

fn site_location(site: &state_mesh::SiteInfo) -> String {
    format!("{}:{}:{}", site.file, site.defn, site.line)
}

fn re_derivation_location(site: &state_mesh::ReDerivationInfo) -> String {
    format!("{}:{}:{}", site.file, site.defn, site.line)
}

fn retain_git_tracked_files(files: &mut Vec<SourceFile>) -> Result<()> {
    let tracked = git_tracked_paths_for_files(files)?;
    files.retain(|file| tracked.contains(&normalize_path(&file.path)));
    Ok(())
}

fn git_tracked_paths_for_files(files: &[SourceFile]) -> Result<HashSet<PathBuf>> {
    let mut tracked = HashSet::new();
    for root in git_roots_for_files(files)? {
        for path in git_ls_files(&root)? {
            tracked.insert(path);
        }
    }
    Ok(tracked)
}

fn git_roots_for_files(files: &[SourceFile]) -> Result<BTreeSet<PathBuf>> {
    let current_root = git_root_for_dir(&std::env::current_dir()?).ok();
    if let Some(root) = current_root {
        let root = normalize_path(&root);
        if files
            .iter()
            .all(|file| normalize_path(&file.path).starts_with(&root))
        {
            return Ok(BTreeSet::from([root]));
        }
    }

    let mut roots = BTreeSet::new();
    for file in files {
        let dir = file.path.parent().unwrap_or_else(|| Path::new("."));
        let root = git_root_for_dir(dir).with_context(|| {
            format!(
                "--vcs=git requires {} to be inside a Git work tree",
                file.path.display()
            )
        })?;
        roots.insert(normalize_path(&root));
    }
    Ok(roots)
}

fn git_root_for_dir(dir: &Path) -> Result<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .with_context(|| format!("failed to run git rev-parse in {}", dir.display()))?;
    if !output.status.success() {
        bail!("git rev-parse failed in {}", dir.display());
    }
    let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("git rev-parse output was not UTF-8 in {}", dir.display()))?;
    Ok(PathBuf::from(stdout.trim()))
}

fn git_ls_files(root: &Path) -> Result<Vec<PathBuf>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["ls-files", "-z"])
        .output()
        .with_context(|| format!("failed to run git ls-files in {}", root.display()))?;
    if !output.status.success() {
        bail!("git ls-files failed in {}", root.display());
    }
    let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("git ls-files output was not UTF-8 in {}", root.display()))?;
    Ok(stdout
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(|path| normalize_path(&root.join(path)))
        .collect())
}

fn normalize_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        }
    })
}

fn expand_target(target: &Path, options: &Options, out: &mut Vec<SourceFile>) -> Result<()> {
    if target.is_dir() {
        expand_directory(target, options, out)
    } else if target.is_file() {
        push_source_file(target, options, out);
        Ok(())
    } else {
        Ok(())
    }
}

fn expand_directory(dir: &Path, options: &Options, out: &mut Vec<SourceFile>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if excluded_path(&path, options) {
            continue;
        }
        if path.is_dir() {
            expand_directory(&path, options, out)?;
        } else if path.is_file() {
            push_source_file(&path, options, out);
        }
    }
    Ok(())
}

fn is_binary_file(path: &Path) -> bool {
    use std::io::Read;
    if let Ok(mut file) = std::fs::File::open(path) {
        let mut buffer = [0u8; 1024];
        if let Ok(bytes_read) = file.read(&mut buffer) {
            if bytes_read >= 4 {
                if &buffer[0..4] == b"\x7fELF" || &buffer[0..2] == b"MZ" {
                    return true;
                }
            }
            if buffer[0..bytes_read].iter().any(|&b| b == 0) {
                return true;
            }
        }
    }
    false
}

fn push_source_file(path: &Path, options: &Options, out: &mut Vec<SourceFile>) {
    if excluded_path(path, options) {
        return;
    }
    if is_binary_file(path) {
        return;
    }
    let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
        return;
    };
    if file_name.starts_with('.') || file_name == "all-tests.zig" {
        return;
    }

    let ext_lang = path.extension()
        .and_then(|value| value.to_str())
        .and_then(|extension| Language::for_extension(&extension.to_ascii_lowercase()));

    let language = match (options.language, ext_lang) {
        (Some(opt_lang), Some(e_lang)) if opt_lang == e_lang => Some(opt_lang),
        (Some(opt_lang), _) if path.extension().is_none() => Some(opt_lang),
        (None, Some(e_lang)) => Some(e_lang),
        _ => None,
    };
    let Some(language) = language else {
        return;
    };
    out.push(SourceFile {
        path: path.to_path_buf(),
        language,
    });
}

fn excluded_path(path: &Path, options: &Options) -> bool {
    let text = path.to_string_lossy().replace('\\', "/");
    if DEFAULT_EXCLUDE_DIRS.iter().any(|dir| {
        text == *dir || text.ends_with(&format!("/{dir}")) || text.contains(&format!("/{dir}/"))
    }) {
        return true;
    }

    options.excludes.iter().any(|pattern| {
        let pattern = pattern.replace('\\', "/");
        if let Some(prefix) = pattern.strip_suffix("/**") {
            let prefix = prefix.strip_prefix("**/").unwrap_or(prefix);
            text == prefix
                || text.ends_with(&format!("/{prefix}"))
                || text.contains(&format!("/{prefix}/"))
        } else {
            text == pattern || text.ends_with(&format!("/{pattern}")) || text.contains(&pattern)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn git_vcs_filter_keeps_only_tracked_source_files() {
        let dir = TempDir::new().expect("tempdir");
        run_git(dir.path(), &["init"]);

        let tracked = dir.path().join("tracked.rb");
        let untracked = dir.path().join("untracked.rb");
        fs::write(&tracked, "def tracked\nend\n").expect("write tracked");
        fs::write(&untracked, "def untracked\nend\n").expect("write untracked");
        run_git(dir.path(), &["add", "tracked.rb"]);

        let options = Options {
            vcs: Some(VcsFilter::Git),
            ..Options::default()
        };
        let files =
            collect_source_files(&[dir.path().to_path_buf()], &options).expect("source files");
        let names = files
            .iter()
            .map(|file| file.path.file_name().unwrap().to_string_lossy().to_string())
            .collect::<Vec<_>>();

        assert_eq!(names, vec!["tracked.rb"]);
    }

    fn run_git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .status()
            .expect("git command");
        assert!(status.success(), "git {:?} failed", args);
    }

    #[test]
    fn test_is_binary_file() {
        let dir = TempDir::new().expect("tempdir");
        let elf_path = dir.path().join("elf");
        fs::write(&elf_path, b"\x7fELFbody").unwrap();
        assert!(is_binary_file(&elf_path));

        let mz_path = dir.path().join("mz");
        fs::write(&mz_path, b"MZbody").unwrap();
        assert!(is_binary_file(&mz_path));

        let null_path = dir.path().join("null");
        fs::write(&null_path, b"hello\0world").unwrap();
        assert!(is_binary_file(&null_path));

        let txt_path = dir.path().join("txt.rs");
        fs::write(&txt_path, b"fn main() {}").unwrap();
        assert!(!is_binary_file(&txt_path));

        // Test non-existent file
        assert!(!is_binary_file(Path::new("nonexistent-binary-test-12345")));

        // Test small files (bytes_read < 4)
        let empty_path = dir.path().join("empty");
        fs::write(&empty_path, b"").unwrap();
        assert!(!is_binary_file(&empty_path));

        let small_path = dir.path().join("small");
        fs::write(&small_path, b"abc").unwrap();
        assert!(!is_binary_file(&small_path));
    }

    #[test]
    fn test_excluded_path() {
        let options = Options {
            excludes: vec!["**/foo/**".to_string(), "bar/baz".to_string()],
            ..Options::default()
        };

        assert!(excluded_path(Path::new("/node_modules/foo.js"), &options));
        assert!(excluded_path(Path::new("/zig-cache/bar"), &options));
        assert!(excluded_path(Path::new("/foo/abc"), &options));
        assert!(excluded_path(Path::new("dir/foo/abc"), &options));
        assert!(excluded_path(Path::new("bar/baz"), &options));
        assert!(excluded_path(Path::new("a/bar/baz"), &options));
        assert!(!excluded_path(Path::new("src/main.rs"), &options));
    }

    #[test]
    fn test_expand_target() {
        let dir = TempDir::new().expect("tempdir");
        let sub = dir.path().join("sub");
        fs::create_dir(&sub).unwrap();

        let f1 = sub.join("f1.rs");
        fs::write(&f1, "fn main() {}").unwrap();

        let f2 = sub.join("f2.rb");
        fs::write(&f2, "def foo; end").unwrap();

        let f3 = sub.join("f3.rs");
        fs::write(&f3, b"\x7fELFbinary").unwrap();

        let f4 = sub.join(".ignored.rs");
        fs::write(&f4, "fn main() {}").unwrap();

        let f5 = sub.join("all-tests.zig");
        fs::write(&f5, "test {}").unwrap();

        let f6 = sub.join("f6.rs");
        fs::write(&f6, "fn main() {}").unwrap();

        let mut files = Vec::new();
        let options = Options {
            excludes: vec!["f6.rs".to_string()],
            ..Options::default()
        };
        expand_target(&sub, &options, &mut files).unwrap();

        assert_eq!(files.len(), 2);
        files.sort_by_key(|f| f.path.clone());
        assert_eq!(files[0].path, f1);
        assert_eq!(files[0].language, Language::Rust);
        assert_eq!(files[1].path, f2);
        assert_eq!(files[1].language, Language::Ruby);

        // Test non-existent path
        let mut files_nonexistent = Vec::new();
        expand_target(Path::new("nonexistent-file-12345"), &options, &mut files_nonexistent).unwrap();
        assert!(files_nonexistent.is_empty());

        // Test excluded direct file target
        let mut files_ex = Vec::new();
        expand_target(&f6, &options, &mut files_ex).unwrap();
        assert!(files_ex.is_empty());

        // Test root directory name parsing fallback
        let mut files_root = Vec::new();
        push_source_file(Path::new("/"), &options, &mut files_root);
        assert!(files_root.is_empty());
    }

    #[test]
    fn test_run_detector_tasks() {
        let res = run_detector_tasks_sequential(vec![
            ("task_ok", Box::new(|| Ok(json!([1, 2, 3]))))
        ]).unwrap();
        assert_eq!(res.get("task_ok").unwrap(), &json!([1, 2, 3]));

        let res_err = run_detector_tasks_sequential(vec![
            ("task_err", Box::new(|| bail!("task failed")))
        ]);
        assert!(res_err.is_err());

        let res_p = run_detector_tasks_parallel(vec![
            ("task_ok", Box::new(|| Ok(json!([1, 2, 3]))))
        ], 2).unwrap();
        assert_eq!(res_p.get("task_ok").unwrap(), &json!([1, 2, 3]));

        let res_p_err = run_detector_tasks_parallel(vec![
            ("task_err", Box::new(|| bail!("task failed")))
        ], 2);
        assert!(res_p_err.is_err());
    }

    #[test]
    fn test_state_heatmap_findings() {
        let mut fields = BTreeMap::new();
        let site1 = state_mesh::SiteInfo {
            file: "file.rb".to_string(),
            defn: "m1".to_string(),
            line: 10,
            recv: "self".to_string(),
            span: [10, 1, 10, 5],
        };
        let site2 = state_mesh::SiteInfo {
            file: "file.rb".to_string(),
            defn: "m2".to_string(),
            line: 20,
            recv: "self".to_string(),
            span: [20, 1, 20, 5],
        };
        // Add duplicate location with smaller span
        let site3 = state_mesh::SiteInfo {
            file: "file.rb".to_string(),
            defn: "m1".to_string(),
            line: 10,
            recv: "self".to_string(),
            span: [5, 1, 5, 5],
        };
        // Add duplicate location with larger span
        let site4 = state_mesh::SiteInfo {
            file: "file.rb".to_string(),
            defn: "m1".to_string(),
            line: 10,
            recv: "self".to_string(),
            span: [12, 1, 12, 5],
        };
        let re_derive = state_mesh::ReDerivationInfo {
            file: "file.rb".to_string(),
            defn: "m3".to_string(),
            line: 30,
            raw: "x == y".to_string(),
            predicate: "p".to_string(),
            canon: "c".to_string(),
        };

        fields.insert(
            "@field".to_string(),
            state_mesh::StateFieldRow {
                messiness: 4.5,
                rank: 1,
                metrics: state_mesh::FieldMetricsRow {
                    writes: 1,
                    reads: 1,
                    re_derivations: 1,
                    scatter: 2,
                    write_scatter: 1,
                    read_scatter: 1,
                    receiver_types: 1,
                    pressure: 3,
                    fix_churn: 0.0,
                    percentiles: BTreeMap::new(),
                },
                writers: vec![site1, site3, site4],
                readers: vec![site2],
                re_derivations: vec![re_derive],
            },
        );

        let report = state_mesh::StateMeshReport {
            state_mesh: state_mesh::StateMeshMeta {
                total_fields: 1,
                total_writes: 1,
                total_reads: 1,
                total_re_derivations: 1,
                min_writes: 1,
                custom_fields: None,
            },
            fields,
            hierarchy: Vec::new(),
        };

        let res = state_heatmap_findings(&report);
        assert_eq!(res.len(), 1);
        let row = &res[0];
        assert_eq!(row.get("field").unwrap(), "@field");
        assert_eq!(row.get("messiness").unwrap(), 4.5);
    }

    #[test]
    fn test_git_roots_edges() {
        // Test early return (all files inside current root)
        let file_in = SourceFile {
            path: PathBuf::from("src/decomplex/report_facts.rs"),
            language: Language::Rust,
        };
        let res_in = git_roots_for_files(&[file_in]);
        assert!(res_in.is_ok());

        // Test error when not in a git repo
        let file_out = SourceFile {
            path: PathBuf::from("/non-existent-dir-12345/some-file.rb"),
            language: Language::Ruby,
        };
        let res_out = git_roots_for_files(&[file_out]);
        assert!(res_out.is_err());
    }

    #[test]
    fn test_sequential_jobs_and_profiling() {
        // Set profile env var and override jobs
        std::env::set_var("DECOMPLEX_RUST_PROFILE", "1");
        fact_mine_rust::parallel::set_jobs_for_process(Some(1)).unwrap();

        let dir = TempDir::new().expect("tempdir");
        let rb_file = dir.path().join("hello.rb");
        fs::write(&rb_file, "def hello\n  puts \"hello\"\nend\n").unwrap();

        let options = Options::default();
        let result = collect(&[rb_file], &options).expect("collect");
        assert!(result.is_object());

        // Reset
        std::env::remove_var("DECOMPLEX_RUST_PROFILE");
        fact_mine_rust::parallel::set_jobs_for_process(None).unwrap();
    }

    #[test]
    fn test_collect_and_facts_for_source_files() {
        let dir = TempDir::new().expect("tempdir");
        let rb_file = dir.path().join("hello.rb");
        fs::write(&rb_file, "def hello\n  puts \"hello\"\nend\n").unwrap();

        let rs_file = dir.path().join("hello.rs");
        fs::write(&rs_file, "fn main() {\n  println!(\"hello\");\n}\n").unwrap();

        let options = Options::default();
        let result = collect(&[rb_file.clone(), rs_file.clone()], &options).expect("collect");
        assert!(result.is_object());
        let obj = result.as_object().unwrap();
        assert_eq!(obj.get("format").unwrap(), FORMAT);
        
        let files_val = obj.get("files").unwrap().as_array().unwrap();
        assert_eq!(files_val.len(), 2);

        let options_lang = Options {
            language: Some(Language::Ruby),
            ..Options::default()
        };
        let result_lang = collect(&[dir.path().to_path_buf()], &options_lang).expect("collect with lang filter");
        let obj_lang = result_lang.as_object().unwrap();
        let files_lang = obj_lang.get("files").unwrap().as_array().unwrap();
        assert_eq!(files_lang.len(), 1);

        let empty_res = facts_for_source_files(&[], &options);
        assert!(empty_res.is_err());
    }

    #[test]
    fn test_git_errors() {
        let err_res = git_root_for_dir(Path::new("/non-existent-dir-12345"));
        assert!(err_res.is_err());

        let err_ls = git_ls_files(Path::new("/non-existent-dir-12345"));
        assert!(err_ls.is_err());
    }

    #[test]
    fn test_normalize_path() {
        let non_existent = Path::new("/non-existent-dir-12345/some-file.rb");
        let normalized = normalize_path(non_existent);
        assert_eq!(normalized, PathBuf::from("/non-existent-dir-12345/some-file.rb"));

        let non_existent_relative = Path::new("non-existent-dir-12345/some-file.rb");
        let normalized_relative = normalize_path(non_existent_relative);
        assert!(normalized_relative.is_absolute());
    }

    #[test]
    fn test_local_summaries_for_documents() {
        let summary1: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "m1",
            "owner": "ClassA",
            "name": "m1",
            "file": "a.rb",
            "line": 10,
            "span": [10, 1, 10, 5],
            "statements": [],
            "boundaries": []
        })).unwrap();

        let summary2: local_flow::MethodSummary = serde_json::from_value(json!({
            "id": "m2",
            "owner": "ClassA",
            "name": "m2",
            "file": "b.rb",
            "line": 20,
            "span": [20, 1, 20, 5],
            "statements": [],
            "boundaries": []
        })).unwrap();

        let doc_a: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "owner_defs": [],
            "call_sites": [],
            "state_declarations": [],
            "state_reads": [],
            "state_writes": [],
            "decision_sites": [],
            "branch_decisions": [],
            "branch_arms": [],
            "dispatch_sites": [],
            "semantic_effect_sites": [],
            "local_complexity_scores": {},
            "local_methods": [],
            "predicate_aliases": [],
            "comparison_uses": [],
            "path_condition_sites": [],
            "protocol_method_effects": [],
            "protocol_call_paths": [],
            "clone_candidates": [],
            "redundant_nil_guards": [],
            "immutable_struct_readers": {},
            "immutable_struct_reader_types": {},
            "type_aliases": {},
            "method_param_types": {},
            "state_param_origins": []
        })).unwrap();

        let summaries = vec![summary1, summary2];
        
        let res_owned = local_summaries_for_documents(&summaries, &[doc_a.clone()]);
        assert_eq!(res_owned.len(), 1);
        assert_eq!(res_owned[0].file, "a.rb");
        assert!(matches!(res_owned, Cow::Owned(_)));

        let doc_b: Document = serde_json::from_value(json!({
            "file": "b.rb",
            "language": "ruby",
            "owner_defs": [],
            "call_sites": [],
            "state_declarations": [],
            "state_reads": [],
            "state_writes": [],
            "decision_sites": [],
            "branch_decisions": [],
            "branch_arms": [],
            "dispatch_sites": [],
            "semantic_effect_sites": [],
            "local_complexity_scores": {},
            "local_methods": [],
            "predicate_aliases": [],
            "comparison_uses": [],
            "path_condition_sites": [],
            "protocol_method_effects": [],
            "protocol_call_paths": [],
            "clone_candidates": [],
            "redundant_nil_guards": [],
            "immutable_struct_readers": {},
            "immutable_struct_reader_types": {},
            "type_aliases": {},
            "method_param_types": {},
            "state_param_origins": []
        })).unwrap();

        let res_borrowed = local_summaries_for_documents(&summaries, &[doc_a, doc_b]);
        assert_eq!(res_borrowed.len(), 2);
        assert!(matches!(res_borrowed, Cow::Borrowed(_)));
    }

    #[test]
    fn test_merge_reports_errors() {
        let mut groups = BTreeMap::new();
        let doc: Document = serde_json::from_value(json!({
            "file": "a.rb",
            "language": "ruby",
            "owner_defs": [],
            "call_sites": [],
            "state_declarations": [],
            "state_reads": [],
            "state_writes": [],
            "decision_sites": [],
            "branch_decisions": [],
            "branch_arms": [],
            "dispatch_sites": [],
            "semantic_effect_sites": [],
            "local_complexity_scores": {},
            "local_methods": [],
            "predicate_aliases": [],
            "comparison_uses": [],
            "path_condition_sites": [],
            "protocol_method_effects": [],
            "protocol_call_paths": [],
            "clone_candidates": [],
            "redundant_nil_guards": [],
            "immutable_struct_readers": {},
            "immutable_struct_reader_types": {},
            "type_aliases": {},
            "method_param_types": {},
            "state_param_origins": []
        })).unwrap();
        groups.insert(Language::Ruby, vec![doc]);

        let res_obj = merge_object_reports(&groups, &["field"], |_docs| {
            Ok(json!([1, 2, 3]))
        });
        assert!(res_obj.is_err());

        let res_missing = merge_object_reports(&groups, &["field"], |_docs| {
            Ok(json!({}))
        });
        assert!(res_missing.is_err());

        let res_arr = merge_array_reports(&groups, |_docs| {
            Ok(json!({}))
        });
        assert!(res_arr.is_err());
    }
}
