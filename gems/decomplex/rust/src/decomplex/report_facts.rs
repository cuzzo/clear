use crate::decomplex::detectors::{
    co_update, decision_pressure, derived_state, false_simplicity, fat_union, flay_similarity,
    function_lcom, implicit_control_flow, inconsistent_rename_clone, local_flow, locality_drag,
    miner, operational_discontinuity, oversized_predicate, path_condition, predicate_alias,
    redundant_nil_guard, semantic_alias, sequence_mine, state_branch_density, state_mesh,
    temporal_ordering_pressure, weighted_inlined_cognitive_complexity,
};
use crate::decomplex::parallel;
use crate::decomplex::syntax::{self, Document, Language};
use anyhow::{bail, Context, Result};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::thread;

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
        thread::scope(|scope| {
            let local_summaries = scope.spawn(|| local_flow::scan_documents(documents));
            let local_complexity_scores = scope.spawn(|| local_complexity_scores(documents));
            let semantic_aliases = scope.spawn(|| semantic_alias::scan_documents(documents));
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

    let documents = parallel::map_ordered(files, |file| {
        syntax::parse_file(file.path.clone(), file.language)
    })?;
    let shared = SharedFacts::new(&documents);
    let mut groups: BTreeMap<Language, Vec<Document>> = BTreeMap::new();
    for document in documents {
        groups.entry(document.language).or_default().push(document);
    }

    let detectors = collect_detector_facts(&groups, &shared, options)?;

    let mut reported_files = files
        .iter()
        .map(|file| file.path.to_string_lossy().to_string())
        .collect::<Vec<_>>();
    reported_files.sort();

    Ok(json!({
        "format": FORMAT,
        "files": reported_files,
        "detectors": detectors,
    }))
}

fn collect_detector_facts(
    groups: &BTreeMap<Language, Vec<Document>>,
    shared: &SharedFacts,
    options: &Options,
) -> Result<Map<String, Value>> {
    if parallel::job_count() <= 1 {
        return collect_detector_facts_sequential(groups, shared, options);
    }

    let (tx, rx) = mpsc::channel();
    thread::scope(|scope| {
        macro_rules! spawn_detector {
            ($name:expr, $body:expr) => {{
                let tx = tx.clone();
                scope.spawn(move || {
                    let result: Result<Value> = (|| $body)();
                    let _ = tx.send(($name.to_string(), result));
                });
            }};
        }

        spawn_detector!("miner", {
            merge_object_reports(
                groups,
                &["missing_abstractions", "neglected_conditions"],
                |documents| json_value(miner::scan_documents(documents)),
            )
        });
        spawn_detector!("co_update", {
            merge_object_reports(
                groups,
                &["co_written_pairs", "neglected_updates"],
                |documents| json_value(co_update::scan_documents(documents)),
            )
        });
        spawn_detector!("predicate_alias", {
            merge_object_reports(groups, &["alias_clusters"], |documents| {
                json_value(predicate_alias::scan_documents(documents))
            })
        });
        spawn_detector!("semantic_alias", {
            json_value(shared.semantic_aliases.clone())
        });
        spawn_detector!("path_condition", {
            merge_object_reports(groups, &["neglected", "scattered"], |documents| {
                json_value(path_condition::scan_documents(documents))
            })
        });
        spawn_detector!("sequence_mine", {
            merge_object_reports(groups, &["broken"], |documents| {
                json_value(sequence_mine::scan_documents(documents))
            })
            .map(rename_broken_protocol)
        });
        spawn_detector!("implicit_control_flow", {
            merge_object_reports(groups, &["ordered_protocols"], |documents| {
                json_value(implicit_control_flow::scan_documents(documents))
            })
        });
        spawn_detector!("derived_state", {
            merge_array_reports(groups, |documents| {
                json_value(derived_state::scan_documents(documents))
            })
        });
        spawn_detector!("inconsistent_rename_clone", {
            merge_array_reports(groups, |documents| {
                json_value(inconsistent_rename_clone::scan_documents(documents))
            })
        });
        spawn_detector!("flay_similarity", {
            merge_array_reports(groups, |documents| {
                json_value(flay_similarity::scan_documents(
                    documents,
                    options.mass,
                    options.fuzzy,
                ))
            })
        });
        spawn_detector!("decision_pressure", {
            merge_array_reports(groups, |documents| {
                json_value(decision_pressure::scan_documents(documents))
            })
        });
        spawn_detector!("redundant_nil_guard", {
            merge_array_reports(groups, |documents| {
                json_value(redundant_nil_guard::scan_documents(documents))
            })
        });
        spawn_detector!("false_simplicity", {
            merge_array_reports(groups, |documents| {
                json_value(false_simplicity::scan_documents(documents))
            })
        });
        spawn_detector!("oversized_predicate", {
            Ok(merge_object_reports(groups, &["findings"], |documents| {
                json_value(oversized_predicate::scan_documents(documents))
            })?
            .get("findings")
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new())))
        });
        spawn_detector!("fat_union", {
            merge_object_reports(groups, &["fat_unions"], |documents| {
                json_value(fat_union::scan_documents(documents))
            })
        });
        spawn_detector!("state_heatmap", {
            state_heatmap_findings_for_groups(groups, &shared.semantic_aliases)
        });
        spawn_detector!("state_branch_density", {
            merge_array_reports(groups, |documents| {
                json_value(state_branch_density::scan_documents(documents))
            })
        });
        spawn_detector!("temporal_ordering_pressure", {
            merge_array_reports(groups, |documents| {
                json_value(temporal_ordering_pressure::scan_documents(documents))
            })
        });
        spawn_detector!("weighted_inlined_complexity", {
            merge_array_reports(groups, |documents| {
                json_value(weighted_inlined_cognitive_complexity::scan_documents(
                    documents,
                ))
            })
        });
        spawn_detector!("locality_drag", {
            json_value(locality_drag::scan_summaries_with_scores(
                shared.local_summaries.clone(),
                shared.local_complexity_scores.clone(),
            ))
        });
        spawn_detector!("function_lcom", {
            json_value(function_lcom::scan_summaries(
                shared.local_summaries.clone(),
            ))
        });
        spawn_detector!("operational_discontinuity", {
            json_value(operational_discontinuity::scan_summaries(
                shared.local_summaries.clone(),
            ))
        });
        drop(tx);
    });

    let mut detectors = Map::new();
    let mut first_error = None;
    for (name, result) in rx {
        match result {
            Ok(value) => {
                detectors.insert(name, value);
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

fn collect_detector_facts_sequential(
    groups: &BTreeMap<Language, Vec<Document>>,
    shared: &SharedFacts,
    options: &Options,
) -> Result<Map<String, Value>> {
    let mut detectors = Map::new();
    detectors.insert(
        "miner".to_string(),
        merge_object_reports(
            groups,
            &["missing_abstractions", "neglected_conditions"],
            |documents| json_value(miner::scan_documents(documents)),
        )?,
    );
    detectors.insert(
        "co_update".to_string(),
        merge_object_reports(
            groups,
            &["co_written_pairs", "neglected_updates"],
            |documents| json_value(co_update::scan_documents(documents)),
        )?,
    );
    detectors.insert(
        "predicate_alias".to_string(),
        merge_object_reports(groups, &["alias_clusters"], |documents| {
            json_value(predicate_alias::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "semantic_alias".to_string(),
        json_value(shared.semantic_aliases.clone())?,
    );
    detectors.insert(
        "path_condition".to_string(),
        merge_object_reports(groups, &["neglected", "scattered"], |documents| {
            json_value(path_condition::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "sequence_mine".to_string(),
        merge_object_reports(groups, &["broken"], |documents| {
            json_value(sequence_mine::scan_documents(documents))
        })
        .map(rename_broken_protocol)?,
    );
    detectors.insert(
        "implicit_control_flow".to_string(),
        merge_object_reports(groups, &["ordered_protocols"], |documents| {
            json_value(implicit_control_flow::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "derived_state".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(derived_state::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "inconsistent_rename_clone".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(inconsistent_rename_clone::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "flay_similarity".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(flay_similarity::scan_documents(
                documents,
                options.mass,
                options.fuzzy,
            ))
        })?,
    );
    detectors.insert(
        "decision_pressure".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(decision_pressure::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "redundant_nil_guard".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(redundant_nil_guard::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "false_simplicity".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(false_simplicity::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "oversized_predicate".to_string(),
        merge_object_reports(groups, &["findings"], |documents| {
            json_value(oversized_predicate::scan_documents(documents))
        })?
        .get("findings")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new())),
    );
    detectors.insert(
        "fat_union".to_string(),
        merge_object_reports(groups, &["fat_unions"], |documents| {
            json_value(fat_union::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "state_heatmap".to_string(),
        state_heatmap_findings_for_groups(groups, &shared.semantic_aliases)?,
    );
    detectors.insert(
        "state_branch_density".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(state_branch_density::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "temporal_ordering_pressure".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(temporal_ordering_pressure::scan_documents(documents))
        })?,
    );
    detectors.insert(
        "weighted_inlined_complexity".to_string(),
        merge_array_reports(groups, |documents| {
            json_value(weighted_inlined_cognitive_complexity::scan_documents(
                documents,
            ))
        })?,
    );
    detectors.insert(
        "locality_drag".to_string(),
        json_value(locality_drag::scan_summaries_with_scores(
            shared.local_summaries.clone(),
            shared.local_complexity_scores.clone(),
        ))?,
    );
    detectors.insert(
        "function_lcom".to_string(),
        json_value(function_lcom::scan_summaries(
            shared.local_summaries.clone(),
        ))?,
    );
    detectors.insert(
        "operational_discontinuity".to_string(),
        json_value(operational_discontinuity::scan_summaries(
            shared.local_summaries.clone(),
        ))?,
    );
    Ok(detectors)
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

        let spans = row
            .writers
            .iter()
            .chain(row.readers.iter())
            .map(|site| (site_location(site), json!(site.span)))
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

fn push_source_file(path: &Path, options: &Options, out: &mut Vec<SourceFile>) {
    if excluded_path(path, options) {
        return;
    }
    let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
        return;
    };
    if file_name.starts_with('.') || file_name == "all-tests.zig" {
        return;
    }

    let language = options.language.or_else(|| {
        path.extension()
            .and_then(|value| value.to_str())
            .and_then(|extension| Language::for_extension(&extension.to_ascii_lowercase()))
    });
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
}
