//! Which shards an incremental collect has to rerun.
//!
//! The question is answered by comparing two manifests: what the sources,
//! functions, tests and workload were last time against what they are now. A
//! shard reruns when a test it owns changed or a function it depended on did.
//!
//! Everything that cannot be attributed to a specific shard falls back to a
//! full collect. That is the whole safety property: it is always sound to rerun
//! everything, and never sound to skip a shard whose evidence might be stale.

use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

fn strings(value: &Value) -> Vec<String> {
    value
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, _)| key.clone())
        .collect()
}

fn table<'a>(value: &'a Value, field: &str) -> &'a Value {
    value.get(field).unwrap_or(&Value::Null)
}

fn sorted(mut values: Vec<String>) -> Vec<String> {
    values.sort();
    values.dedup();
    values
}

/// Keys present in `current` whose value differs from `previous`.
fn changed(current: &Value, previous: &Value) -> Vec<String> {
    current
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, value)| previous.get(key.as_str()) != Some(*value))
        .map(|(key, _)| key.clone())
        .collect()
}

fn missing(previous: &Value, current: &Value) -> Vec<String> {
    let present = current.as_object().map(|map| {
        map.keys().cloned().collect::<BTreeSet<_>>()
    }).unwrap_or_default();
    strings(previous).into_iter().filter(|key| !present.contains(key)).collect()
}

pub struct Increment<'a> {
    pub manifest: &'a Value,
    pub current_hashes: &'a Value,
    pub current_environment: &'a Value,
    pub functions: &'a Value,
    pub workload: &'a Value,
    pub trace_plan_digest: &'a str,
}

pub fn select(input: &Increment<'_>) -> Value {
    let manifest = input.manifest;
    let previous_hashes = table(manifest, "source_hashes");
    let changed_files = changed(input.current_hashes, previous_hashes);
    let deleted_files = missing(previous_hashes, input.current_hashes);

    let previous_functions = table(manifest, "functions");
    let previous_workload = table(manifest, "workload");
    let previous_tests = table(previous_workload, "tests");
    let current_tests = table(input.workload, "tests");
    let changed_tests = changed(current_tests, previous_tests);
    let deleted_tests = missing(previous_tests, current_tests);
    let support_changed =
        table(previous_workload, "support_files") != table(input.workload, "support_files");

    let added_functions = missing(input.functions, previous_functions);
    let deleted_functions = missing(previous_functions, input.functions);
    let changed_functions = input
        .functions
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, function)| {
            previous_functions.get(key.as_str()).is_some_and(|before| {
                before["fingerprint"] != function["fingerprint"]
            })
        })
        .map(|(key, _)| key.clone())
        .collect::<Vec<_>>();

    // A source edit that some function already accounts for is not a residual
    // change; one that no function explains means something moved that shard
    // selection cannot see.
    let path_of = |keys: &[String], table: &Value| {
        keys.iter()
            .filter_map(|key| table[key.as_str()]["path"].as_str().map(str::to_string))
            .collect::<Vec<_>>()
    };
    let mut function_changed_paths = path_of(&changed_functions, input.functions);
    function_changed_paths.extend(path_of(&added_functions, input.functions));
    function_changed_paths.extend(path_of(&deleted_functions, previous_functions));
    let residual_source_changes = sorted(
        changed_files
            .iter()
            .chain(&deleted_files)
            .filter(|path| !function_changed_paths.contains(path))
            .cloned()
            .collect(),
    );

    let environment_changed = *input.current_environment != *table(manifest, "environment");
    let command_changed =
        previous_workload["command_digest"] != input.workload["command_digest"];
    let mode_changed = previous_workload["mode"] != input.workload["mode"];
    let trace_plan_changed =
        manifest["trace_plan_digest"].as_str().unwrap_or_default() != input.trace_plan_digest;
    // A source edit necessarily changes FactMine's anchor digests, and function
    // and test selection plus evidence rebasing already cover that. A plan that
    // changed with identical sources is different: the analyzer's demand moved
    // and no source dependency says which shards it touched.
    let unexplained_trace_plan_changed =
        trace_plan_changed && changed_files.is_empty() && deleted_files.is_empty();

    let current_shards = table(input.workload, "shards");
    let deleted_shards = sorted(missing(table(previous_workload, "shards"), current_shards));

    let mut selected: Vec<String> = changed_tests
        .iter()
        .filter_map(|path| {
            current_shards.as_object().into_iter().flatten().find_map(|(id, shard)| {
                (shard["test_path"].as_str() == Some(path.as_str())).then(|| id.clone())
            })
        })
        .collect();
    let dependencies = table(manifest, "dependencies");
    for function_key in &changed_functions {
        for (shard_id, keys) in dependencies.as_object().into_iter().flatten() {
            let depends = keys
                .as_array()
                .into_iter()
                .flatten()
                .any(|key| key.as_str() == Some(function_key.as_str()));
            if depends {
                selected.push(shard_id.clone());
            }
        }
    }

    let uncertain = environment_changed
        || command_changed
        || mode_changed
        || unexplained_trace_plan_changed
        || support_changed
        || !added_functions.is_empty()
        || !deleted_functions.is_empty()
        || !residual_source_changes.is_empty();
    // An opaque workload has no test-to-shard mapping, so any change at all
    // means every shard is suspect.
    let opaque_fallback = input.workload["mode"].as_str() == Some("opaque")
        && (!changed_functions.is_empty()
            || !changed_tests.is_empty()
            || !deleted_tests.is_empty());
    let fallback_full = uncertain || opaque_fallback;
    if fallback_full {
        selected = strings(current_shards);
    }
    let selected = sorted(selected);

    let rebuild = !selected.is_empty()
        || !deleted_shards.is_empty()
        || !changed_functions.is_empty()
        || !added_functions.is_empty()
        || !deleted_functions.is_empty()
        || fallback_full;

    let mut out = Map::new();
    out.insert("selected_shards".into(), json!(selected));
    out.insert("deleted_shards".into(), json!(deleted_shards));
    out.insert("changed_tests".into(), json!(sorted(changed_tests)));
    out.insert("deleted_tests".into(), json!(sorted(deleted_tests)));
    out.insert("changed_functions".into(), json!(sorted(changed_functions)));
    out.insert("added_functions".into(), json!(sorted(added_functions)));
    out.insert("deleted_functions".into(), json!(sorted(deleted_functions)));
    out.insert("changed_files".into(), json!(sorted(changed_files)));
    out.insert("deleted_files".into(), json!(sorted(deleted_files)));
    out.insert("residual_source_changes".into(), json!(residual_source_changes));
    out.insert("support_changed".into(), json!(support_changed));
    out.insert("environment_changed".into(), json!(environment_changed));
    out.insert("command_changed".into(), json!(command_changed));
    out.insert("trace_plan_changed".into(), json!(trace_plan_changed));
    out.insert("unexplained_trace_plan_changed".into(), json!(unexplained_trace_plan_changed));
    out.insert("uncertain_closure".into(), json!(false));
    out.insert("fallback_full".into(), json!(fallback_full));
    out.insert("rebuild".into(), json!(rebuild));
    out.insert("current_hashes".into(), input.current_hashes.clone());
    out.insert("environment".into(), input.current_environment.clone());
    out.insert("functions".into(), input.functions.clone());
    out.insert("workload".into(), input.workload.clone());
    out.insert("trace_plan_digest".into(), json!(input.trace_plan_digest));
    Value::Object(out)
}


// ------------------------------------------------------------- the manifest
//
// What a collect has to remember so the next one can be incremental: the
// fingerprints it decided from, the workload it ran, and which functions and
// callsites each shard reached.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

pub const MANIFEST: &str = "runtime-snapshot.json.gz";
pub const SCHEMA: &str = "nil-kill.runtime-snapshot.v1";

fn manifest_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join(MANIFEST)
}

/// The stored manifest, or why it cannot be used. A snapshot written under a
/// different fingerprint scheme is not stale, it is unreadable: its digests
/// mean something else, and comparing them would skip shards that changed.
pub fn load(runtime_dir: &Path) -> Result<Value> {
    let path = manifest_path(runtime_dir);
    if !path.is_file() {
        bail!("no runtime snapshot at {}; run a full collect first", path.display());
    }
    let manifest: Value = serde_json::from_str(&read_gz(&path)?)
        .with_context(|| format!("{} is not readable", path.display()))?;
    if manifest["schema"] != json!(SCHEMA)
        || manifest["fingerprint_scheme"] != json!(crate::source_fingerprint::SCHEME)
    {
        bail!("runtime snapshot fingerprint contract is unsupported; run a full collect");
    }
    Ok(manifest)
}

fn read_gz(path: &Path) -> Result<String> {
    use std::io::Read;
    let bytes = std::fs::read(path)?;
    let mut text = String::new();
    if bytes.starts_with(&[0x1f, 0x8b]) {
        flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut text)?;
    } else {
        text = String::from_utf8(bytes)?;
    }
    Ok(text)
}

fn write_gz(path: &Path, text: &str) -> Result<()> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    let file = std::fs::File::create(&temporary)?;
    let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
    encoder.write_all(text.as_bytes())?;
    encoder.finish()?;
    std::fs::rename(&temporary, path)?;
    Ok(())
}

pub fn relative(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|rest| rest.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string_lossy().to_string())
}

/// What each source file says, keyed by its path relative to the root.
pub fn source_hashes(files: &[PathBuf], root: &Path) -> Value {
    let mut hashes = Map::new();
    let mut sorted_files = files.to_vec();
    sorted_files.sort();
    for path in sorted_files {
        if !path.is_file() {
            continue;
        }
        if let Some(fingerprint) = crate::source_fingerprint::of_file(&path) {
            hashes.insert(relative(&path, root), json!(fingerprint));
        }
    }
    Value::Object(hashes)
}

/// The runtime the evidence was collected against.
///
/// Ruby answered this with its own `RUBY_VERSION`, which needed a Ruby to ask.
/// The interpreter the workload actually runs is on disk, so digesting it says
/// the same thing without one -- and says it more exactly: a rebuilt patch
/// release is a different binary, and re-collecting is the conservative answer.
pub fn environment(root: &Path, commands: &[Vec<String>]) -> Value {
    use sha2::{Digest, Sha256};
    let mut claims = Map::new();
    claims.insert("runtime.language".into(), json!("ruby"));
    if let Some(interpreter) = commands.iter().find_map(|command| interpreter_of(command)) {
        if let Ok(bytes) = std::fs::read(&interpreter) {
            claims.insert(
                "runtime.interpreter.sha256".into(),
                json!(format!("sha256:{:x}", Sha256::digest(&bytes))),
            );
        }
    }
    if let Ok(bytes) = std::fs::read(root.join("Gemfile.lock")) {
        claims.insert(
            "runtime.lockfile.Gemfile.lock.sha256".into(),
            json!(format!("sha256:{:x}", Sha256::digest(&bytes))),
        );
    }
    Value::Object(claims)
}

/// The interpreter a command runs under, resolved the way the shell would.
fn interpreter_of(command: &[String]) -> Option<PathBuf> {
    let name = command.iter().find(|part| {
        let base = Path::new(part).file_name().map(|n| n.to_string_lossy().to_string());
        base.is_some_and(|base| base == "ruby" || base.starts_with("ruby"))
    })?;
    let path = Path::new(name);
    if path.is_absolute() {
        return path.is_file().then(|| path.to_path_buf());
    }
    std::env::var("PATH").ok()?.split(':').map(|dir| Path::new(dir).join(path)).find(|candidate| candidate.is_file())
}

fn identity(parts: &[&Value]) -> String {
    use sha2::{Digest, Sha256};
    let joined = parts
        .iter()
        .map(|part| serde_json::to_string(part).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\u{0}");
    format!("sha256:{:x}", Sha256::digest(joined.as_bytes()))
}

pub struct Written<'a> {
    pub runtime_dir: &'a Path,
    pub root: &'a Path,
    pub evidence: &'a Path,
    pub dependencies: Value,
    pub callsites: Value,
}

pub fn write_full(into: &Written<'_>, selection: &Value, created_at: &str) -> Result<Value> {
    let hashes = selection["current_hashes"].clone();
    let environment = selection["environment"].clone();
    let workload_digest = selection["workload"]["command_digest"].clone();
    let evidence_digest = {
        use sha2::{Digest, Sha256};
        json!(format!("{:x}", Sha256::digest(std::fs::read(into.evidence)?)))
    };
    let snapshot_id = identity(&[
        &json!("full"),
        &hashes,
        &environment,
        &workload_digest,
        &evidence_digest,
    ]);
    let mut changed_paths = hashes
        .as_object()
        .into_iter()
        .flatten()
        .map(|(key, _)| key.clone())
        .collect::<Vec<_>>();
    changed_paths.sort();
    let manifest = json!({
        "schema": SCHEMA,
        "fingerprint_scheme": crate::source_fingerprint::SCHEME,
        "snapshot_id": snapshot_id,
        "base_full_snapshot_id": snapshot_id,
        "parent_snapshot_id": Value::Null,
        "generation": 0,
        "mode": "full",
        "complete": true,
        "potentially_stale": false,
        "source_hashes": hashes,
        "environment": environment,
        "workload_digest": workload_digest,
        "trace_plan_digest": selection["trace_plan_digest"],
        "functions": selection["functions"],
        "workload": selection["workload"],
        "dependencies": into.dependencies,
        "callsites": into.callsites,
        "changed_paths": changed_paths,
        "deleted_paths": [],
        "created_at": created_at,
        "evidence": relative(into.evidence, into.root),
    });
    write_manifest(into.runtime_dir, &manifest)?;
    Ok(manifest)
}

pub fn write_incremental(
    into: &Written<'_>,
    previous: &Value,
    selection: &Value,
    created_at: &str,
) -> Result<Value> {
    let parent = previous["snapshot_id"].clone();
    let generation = previous["generation"].as_i64().unwrap_or_default() + 1;
    let snapshot_id = identity(&[
        &json!("fast"),
        &selection["current_hashes"],
        &selection["functions"],
        &selection["workload"],
        &parent,
        &json!(generation),
    ]);
    let uncertain = selection["uncertain_closure"].as_bool().unwrap_or(false);
    let manifest = json!({
        "schema": SCHEMA,
        "fingerprint_scheme": crate::source_fingerprint::SCHEME,
        "snapshot_id": snapshot_id,
        "base_full_snapshot_id": previous["base_full_snapshot_id"],
        "parent_snapshot_id": parent,
        "generation": generation,
        "mode": "fast",
        "complete": !uncertain,
        "potentially_stale": uncertain,
        "source_hashes": selection["current_hashes"],
        "environment": selection["environment"],
        "workload_digest": selection["workload"]["command_digest"],
        "trace_plan_digest": selection["trace_plan_digest"],
        "functions": selection["functions"],
        "workload": selection["workload"],
        "dependencies": into.dependencies,
        "callsites": into.callsites,
        "changed_functions": selection["changed_functions"],
        "added_functions": selection["added_functions"],
        "deleted_functions": selection["deleted_functions"],
        "changed_tests": selection["changed_tests"],
        "deleted_tests": selection["deleted_tests"],
        "changed_files": selection["changed_files"],
        "deleted_files": selection["deleted_files"],
        "residual_source_changes": selection["residual_source_changes"],
        "selected_shards": selection["selected_shards"],
        "fallback_full": selection["fallback_full"],
        "support_changed": selection["support_changed"],
        "created_at": created_at,
        "evidence": relative(into.evidence, into.root),
    });
    write_manifest(into.runtime_dir, &manifest)?;
    Ok(manifest)
}

/// A collect that could not finish leaves the previous evidence in place and
/// says so on the manifest, so the next reader knows it is looking at evidence
/// older than the source beside it.
pub fn mark_stale(
    runtime_dir: &Path,
    previous: &Value,
    reason: &str,
    selection: &Value,
    stale_at: &str,
) -> Result<()> {
    let mut manifest = previous.clone();
    let entries = manifest.as_object_mut().context("manifest is not an object")?;
    entries.insert("complete".into(), json!(false));
    entries.insert("potentially_stale".into(), json!(true));
    entries.insert("stale_reason".into(), json!(reason));
    entries.insert(
        "attempted_changed_functions".into(),
        selection["changed_functions"].clone(),
    );
    entries.insert("attempted_changed_tests".into(), selection["changed_tests"].clone());
    entries.insert("attempted_selected_shards".into(), selection["selected_shards"].clone());
    entries.insert("stale_at".into(), json!(stale_at));
    write_manifest(runtime_dir, &manifest)
}

fn write_manifest(runtime_dir: &Path, manifest: &Value) -> Result<()> {
    write_gz(
        &manifest_path(runtime_dir),
        &(serde_json::to_string_pretty(manifest)? + "\n"),
    )
}

/// What a full collect claims, in the shape `select` would have produced: every
/// shard runs, every function is new, and nothing was carried over.
pub fn full_selection(
    files: &[PathBuf],
    root: &Path,
    functions: &Value,
    workload: &Value,
    trace_plan_digest: &str,
    commands: &[Vec<String>],
) -> Value {
    json!({
        "selected_shards": strings(&workload["shards"]),
        "deleted_shards": [],
        "changed_functions": strings(functions),
        "added_functions": [],
        "deleted_functions": [],
        "changed_tests": strings(&workload["tests"]),
        "deleted_tests": [],
        "changed_files": [],
        "deleted_files": [],
        "residual_source_changes": [],
        "support_changed": false,
        "environment_changed": false,
        "command_changed": false,
        "trace_plan_changed": false,
        "unexplained_trace_plan_changed": false,
        "uncertain_closure": false,
        "fallback_full": true,
        "rebuild": true,
        "current_hashes": source_hashes(files, root),
        "environment": environment(root, commands),
        "functions": functions,
        "workload": workload,
        "trace_plan_digest": trace_plan_digest,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn function(path: &str, fingerprint: &str) -> Value {
        json!({"path": path, "fingerprint": fingerprint})
    }

    fn manifest(digest: &str) -> Value {
        json!({
            "source_hashes": {"lib/app.rb": "a"},
            "functions": {"f": function("lib/app.rb", "1")},
            "dependencies": {"shard-a": ["f"]},
            "environment": {},
            "trace_plan_digest": digest,
            "workload": {
                "mode": "test_files",
                "command_digest": "w",
                "tests": {"test/app_test.rb": "t"},
                "support_files": {},
                "shards": {"shard-a": {"test_path": "test/app_test.rb"}},
            },
        })
    }

    fn select_with(manifest: &Value, hashes: Value, functions: Value, digest: &str) -> Value {
        select(&Increment {
            manifest,
            current_hashes: &hashes,
            current_environment: &json!({}),
            functions: &functions,
            workload: &manifest["workload"],
            trace_plan_digest: digest,
        })
    }

    #[test]
    fn nothing_changed_means_nothing_to_rerun() {
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "a"}),
            json!({"f": function("lib/app.rb", "1")}),
            "plan",
        );

        assert_eq!(out["rebuild"], json!(false));
        assert_eq!(out["selected_shards"], json!([]));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_changed_function_reruns_only_the_shards_that_depended_on_it() {
        let mut stored = manifest("plan");
        stored["workload"]["shards"]["shard-b"] = json!({"test_path": "test/other_test.rb"});
        stored["dependencies"]["shard-b"] = json!(["other"]);

        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "plan",
        );

        // The source edit is explained by the function whose fingerprint moved,
        // so it is not a residual change and does not force a full collect.
        assert_eq!(out["changed_functions"], json!(["f"]));
        assert_eq!(out["residual_source_changes"], json!([]));
        assert_eq!(out["fallback_full"], json!(false));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_plan_that_moved_with_no_source_change_reruns_everything() {
        // The analyzer's demand moved and no source dependency says which
        // shards it touched, so none of them can be trusted.
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "a"}),
            json!({"f": function("lib/app.rb", "1")}),
            "different-plan",
        );

        assert_eq!(out["trace_plan_changed"], json!(true));
        assert_eq!(out["unexplained_trace_plan_changed"], json!(true));
        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_plan_change_a_source_edit_explains_is_not_a_full_retrace() {
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "source-updated-plan",
        );

        assert_eq!(out["trace_plan_changed"], json!(true));
        assert_eq!(out["unexplained_trace_plan_changed"], json!(false));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_source_edit_no_function_explains_forces_a_full_collect() {
        // Something moved that shard selection cannot attribute -- a constant,
        // a require, top-level code -- so every shard is suspect.
        let stored = manifest("plan");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "1")}),
            "plan",
        );

        assert_eq!(out["residual_source_changes"], json!(["lib/app.rb"]));
        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }

    #[test]
    fn a_changed_test_reruns_its_own_shard() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["tests"]["test/app_test.rb"] = json!("t2");
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["changed_tests"], json!(["test/app_test.rb"]));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
        assert_eq!(out["fallback_full"], json!(false));
    }

    #[test]
    fn a_changed_support_file_reruns_every_shard() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["support_files"] = json!({"test/test_helper.rb": "h"});
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["support_changed"], json!(true));
        assert_eq!(out["fallback_full"], json!(true));
    }

    #[test]
    fn a_deleted_test_drops_its_shard_without_rerunning_it() {
        let stored = manifest("plan");
        let mut workload = stored["workload"].clone();
        workload["tests"] = json!({});
        workload["shards"] = json!({});
        let out = select(&Increment {
            manifest: &stored,
            current_hashes: &json!({"lib/app.rb": "a"}),
            current_environment: &json!({}),
            functions: &json!({"f": function("lib/app.rb", "1")}),
            workload: &workload,
            trace_plan_digest: "plan",
        });

        assert_eq!(out["deleted_tests"], json!(["test/app_test.rb"]));
        assert_eq!(out["deleted_shards"], json!(["shard-a"]));
        assert_eq!(out["selected_shards"], json!([]));
        assert_eq!(out["rebuild"], json!(true));
    }

    #[test]
    fn an_opaque_workload_reruns_everything_any_change_touches() {
        // No test-to-shard mapping exists, so nothing says a change missed a
        // given command.
        let mut stored = manifest("plan");
        stored["workload"]["mode"] = json!("opaque");
        let out = select_with(
            &stored,
            json!({"lib/app.rb": "b"}),
            json!({"f": function("lib/app.rb", "2")}),
            "plan",
        );

        assert_eq!(out["fallback_full"], json!(true));
        assert_eq!(out["selected_shards"], json!(["shard-a"]));
    }
}
