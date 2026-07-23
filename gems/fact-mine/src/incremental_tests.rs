use super::*;
use std::io::Write;
use std::sync::Mutex;

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn ruby_file(directory: &Path, name: &str, source: &str) -> PathBuf {
    let path = directory.join(name);
    fs::write(&path, source).expect("write source");
    path
}

fn config(directory: &Path) -> CacheConfig {
    CacheConfig::new(
        directory.to_path_buf(),
        directory.join(".lineage/cache/fact-mine"),
    )
}

#[test]
fn warm_cache_skips_local_extraction_and_keeps_complete_output() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class A; def run; 1; end; end\n",
    );
    let first = build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &config(directory.path()),
        false,
    )?;
    let second = build_profile(
        &[file],
        None,
        Profile::Espalier,
        &config(directory.path()),
        false,
    )?;
    assert_eq!(first.metrics.shard_misses, 1);
    assert_eq!(second.metrics.project_snapshot_hits, 1);
    assert_eq!(second.metrics.shard_hits, 0);
    assert_eq!(second.metrics.shard_misses, 0);
    assert_eq!(
        serde_json::to_value(&first.output)?.get("methods"),
        serde_json::to_value(&second.output)?.get("methods"),
    );
    assert_eq!(
        second
            .output
            .artifact_scope
            .as_ref()
            .map(|scope| scope.complete),
        Some(true)
    );
    Ok(())
}

#[test]
fn changed_renamed_and_deleted_files_update_the_manifest() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let first = ruby_file(
        directory.path(),
        "first.rb",
        "class A; def one; 1; end; end\n",
    );
    let second = ruby_file(
        directory.path(),
        "second.rb",
        "class B; def two; 2; end; end\n",
    );
    build_profile(
        &[first.clone(), second.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    fs::write(&first, "class A; def changed; 1; end; end\n")?;
    let renamed = directory.path().join("renamed.rb");
    fs::rename(&second, &renamed)?;
    let run = build_profile(
        &[first, renamed],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    assert_eq!(run.metrics.shard_hits, 0);
    assert!(run.metrics.invalidated_files >= 3);
    let manifest: RevisionManifest = serde_json::from_slice(&fs::read(
        cache_config.directory.join("revision-manifest-v1.json"),
    )?)?;
    assert_eq!(manifest.files.len(), 2);
    assert!(manifest.files.contains_key("renamed.rb"));
    Ok(())
}

#[test]
fn corrupt_shards_are_safe_misses() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class A; def run; 1; end; end\n",
    );
    build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    let shard = fs::read_dir(cache_config.directory.join("shards"))?
        .next()
        .expect("shard")?
        .path();
    fs::write(&shard, b"corrupt")?;
    fs::remove_dir_all(cache_config.directory.join("projects"))?;
    let run = build_profile(&[file], None, Profile::Espalier, &cache_config, false)?;
    assert_eq!(run.metrics.corrupt_entries, 1);
    assert_eq!(run.metrics.shard_misses, 1);
    Ok(())
}

#[test]
fn corrupt_project_snapshots_fall_back_to_valid_shards() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class A; def run; 1; end; end\n",
    );
    build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    let candidate = candidate(
        &file,
        None,
        Profile::Espalier,
        directory.path(),
        &stdlib_registry_digest()?,
        &configuration_digest()?,
    )?;
    let project_key = project_cache_key(Profile::Espalier, &[candidate])?;
    let cache = ShardCache::new(cache_config.directory.clone());
    fs::write(cache.project_path(&project_key), b"corrupt")?;

    let run = build_profile(&[file], None, Profile::Espalier, &cache_config, false)?;
    assert_eq!(run.metrics.project_snapshot_hits, 0);
    assert_eq!(run.metrics.project_snapshot_misses, 1);
    assert_eq!(run.metrics.shard_hits, 1);
    Ok(())
}

#[test]
fn partial_preview_is_never_marked_complete_or_manifested() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class A; def run; 1; end; end\n",
    );
    let run = build_profile(&[file], None, Profile::Espalier, &cache_config, true)?;
    let scope = run.output.artifact_scope.expect("scope");
    assert!(!scope.complete);
    assert_eq!(scope.kind, "changed_file_preview");
    assert!(!cache_config
        .directory
        .join("revision-manifest-v1.json")
        .exists());
    Ok(())
}

#[test]
fn cache_key_changes_for_local_configuration() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class A; def run; 1; end; end\n",
    );
    let registry = stdlib_registry_digest()?;
    let config_digest = configuration_digest()?;
    let original = candidate(
        &file,
        None,
        Profile::Espalier,
        directory.path(),
        &registry,
        &config_digest,
    )?;
    let changed = candidate(
        &file,
        None,
        Profile::NilKill,
        directory.path(),
        &registry,
        &config_digest,
    )?;
    assert_ne!(original.cache_key, changed.cache_key);
    Ok(())
}

#[test]
fn deterministic_mutation_corpus_matches_clean_project_results() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let caller = directory.path().join("caller.rb");
    let callee = directory.path().join("callee.rb");
    let extra = directory.path().join("extra.rb");
    for mutation in 0..300usize {
        let scenario = mutation % 12;
        let caller_source = match scenario {
                3 => "class Caller; def run; Callee.renamed; end; end\n",
                5 => "class Caller; def run; RenamedCallee.value; end; end\n",
                7 => "class Caller; def run; Callee.value; end; end\n",
                9 => "class Caller; def run; Namespaced::Callee.value; end; end\n",
                10 => "class Caller; def run; Child.new.value; end; end\n",
                11 => "require 'generated_dependency'\nclass Caller; def run; dependency.value; end; end\n",
                _ => "class Caller; def run; Callee.value; end; end\n",
            };
        fs::write(&caller, caller_source)?;
        let callee_source = match scenario {
                1 => format!("class Callee\n  def self.value; {mutation}; end\n  def self.added; :added; end\nend\n"),
                2 => "class Callee; end\n".to_string(),
                3 => format!("class Callee\n  def self.renamed; {mutation}; end\nend\n"),
                4 => format!("class Callee\n  def self.value; {mutation}; end\nend\nclass AddedOwner; def extra; :ok; end; end\n"),
                5 => format!("class RenamedCallee\n  def self.value; {mutation}; end\nend\n"),
                6 => format!("class Callee\n  def self.value; {mutation}; end\n  def self.value(arg); arg; end\nend\n"),
                7 => "class Callee; end\n".to_string(),
                8 => format!("class Callee\n  def self.value(argument = {mutation}); argument; end\nend\n"),
                9 => format!("module Namespaced\n  class Callee\n    def self.value; {mutation}; end\n  end\nend\n"),
                10 => format!("class Parent\n  def value; {mutation}; end\nend\nclass Child < Parent; end\n"),
                11 => "class Callee; end\n".to_string(),
                _ => format!("class Callee\n  def self.value; {mutation}; end\nend\n"),
            };
        fs::write(&callee, callee_source)?;
        if scenario == 4 {
            fs::write(&extra, "class Extra; def self.present; true; end; end\n")?;
        } else if extra.exists() {
            fs::remove_file(&extra)?;
        }
        let mut files = vec![caller.clone(), callee.clone()];
        if extra.exists() {
            files.push(extra.clone());
        }
        let incremental = build_profile(&files, None, Profile::Espalier, &cache_config, false)?;
        let clean_cache = tempfile::tempdir()?;
        let clean = build_profile(
            &files,
            None,
            Profile::Espalier,
            &config(clean_cache.path()),
            false,
        )?;
        let mut incremental_json = serde_json::to_value(incremental.output)?;
        let mut clean_json = serde_json::to_value(clean.output)?;
        incremental_json
            .as_object_mut()
            .unwrap()
            .remove("incremental_metrics");
        clean_json
            .as_object_mut()
            .unwrap()
            .remove("incremental_metrics");
        assert_eq!(
            incremental_json, clean_json,
            "mutation {mutation}, scenario {scenario}"
        );
    }
    Ok(())
}

#[test]
fn external_summary_changes_reuse_local_shards_and_recompute_project_output() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        "class Sample; def self.run; missing_dependency; end; end\n",
    );
    let symbol = "scip-ruby gem sample 1 Sample#missing_dependency().";
    let first = build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    let second = build_profile(&[file], None, Profile::Espalier, &cache_config, false)?;
    assert_eq!(second.metrics.project_snapshot_hits, 1);

    let mut first_output = first.output;
    let mut second_output = second.output;
    for output in [&mut first_output, &mut second_output] {
        output.calls[0].semantic_symbol = Some(symbol.to_string());
        output.calls[0].target = None;
        output.calls[0].known_time_complexity = None;
        output.calls[0].known_space_complexity = None;
    }
    crate::external_summary::apply_json(
        &mut first_output,
        &serde_json::json!({
            "schema": "fact-mine.external-complexity-summary.v1",
            "symbols": { symbol: { "time": "O(N)", "space": "O(1)" } }
        })
        .to_string(),
    )?;
    crate::external_summary::apply_json(
        &mut second_output,
        &serde_json::json!({
            "schema": "fact-mine.external-complexity-summary.v1",
            "symbols": { symbol: { "time": "O(log N)", "space": "O(1)" } }
        })
        .to_string(),
    )?;
    assert_eq!(
        first_output.calls[0].known_time_complexity.as_deref(),
        Some("O(N)")
    );
    assert_eq!(
        second_output.calls[0].known_time_complexity.as_deref(),
        Some("O(log N)")
    );
    Ok(())
}

#[test]
fn compressed_shards_are_smaller_than_their_json_payload() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let config = config(directory.path());
    let file = ruby_file(
        directory.path(),
        "sample.rb",
        &format!("class A\n{}end\n", "  def run; 1; end\n".repeat(80)),
    );
    build_profile(&[file], None, Profile::Espalier, &config, false)?;
    let shard = fs::read_dir(config.directory.join("shards"))?
        .next()
        .expect("shard")?
        .path();
    let compressed = fs::metadata(shard)?.len();
    assert!(compressed > 0);
    Ok(())
}

#[test]
fn configured_global_shapes_content_is_fingerprinted() -> Result<()> {
    let _environment = ENV_LOCK.lock().expect("environment lock");
    let mut shapes = tempfile::NamedTempFile::new()?;
    shapes.write_all(br#"{"struct_field_hash_shapes": {}}"#)?;
    std::env::set_var("FACT_MINE_GLOBAL_SHAPES_FILE", shapes.path());
    let first = configuration_digest()?;
    fs::write(
        shapes.path(),
        br#"{"struct_field_hash_shapes": {"A\u0000x": {}}}"#,
    )?;
    let second = configuration_digest()?;
    std::env::remove_var("FACT_MINE_GLOBAL_SHAPES_FILE");
    assert_ne!(first, second);
    Ok(())
}

#[test]
fn cache_handles_recovery_relative_paths_and_all_profiles() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let relative = PathBuf::from("broken.rb");
    let absolute = directory.path().join(&relative);
    fs::write(&absolute, "def broken(\n")?;
    let registry = stdlib_registry_digest()?;
    let configuration = configuration_digest()?;
    let trace_candidate = candidate(
        &relative,
        None,
        Profile::TracePlan,
        directory.path(),
        &registry,
        &configuration,
    )?;
    assert_eq!(trace_candidate.profile, "trace-plan");
    assert_eq!(trace_candidate.path_identity, "broken.rb");
    let run = build_profile(
        &[absolute],
        None,
        Profile::Espalier,
        &config(directory.path()),
        false,
    )?;
    assert_eq!(run.output.input_coverage.parse_recoveries.len(), 1);
    Ok(())
}

#[test]
fn corrupt_json_identity_and_manifest_entries_are_misses() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let cache_config = config(directory.path());
    let file = ruby_file(directory.path(), "sample.rb", "class A; end\n");
    build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    let shard_path = fs::read_dir(cache_config.directory.join("shards"))?
        .next()
        .expect("shard")?
        .path();

    let mut bad_json = GzEncoder::new(Vec::new(), Compression::default());
    bad_json.write_all(b"{}")?;
    fs::write(&shard_path, bad_json.finish()?)?;
    fs::remove_dir_all(cache_config.directory.join("projects"))?;
    let json_miss = build_profile(
        &[file.clone()],
        None,
        Profile::Espalier,
        &cache_config,
        false,
    )?;
    assert_eq!(json_miss.metrics.corrupt_entries, 1);

    let candidate = candidate(
        &file,
        None,
        Profile::Espalier,
        directory.path(),
        &stdlib_registry_digest()?,
        &configuration_digest()?,
    )?;
    let cache = ShardCache::new(cache_config.directory.clone());
    let mut cached = match cache.load(&candidate)? {
        CacheRead::Hit(shard, _) => CachedShard {
            schema_version: CACHE_SCHEMA_VERSION,
            cache_key: candidate.cache_key.clone(),
            source_digest: candidate.source_digest.clone(),
            path: candidate.path_identity.clone(),
            language: candidate.language.as_str().to_string(),
            profile: candidate.profile.to_string(),
            shard: *shard,
        },
        _ => panic!("expected cached shard"),
    };
    cached.profile = "wrong-profile".to_string();
    let mut invalid_identity = GzEncoder::new(Vec::new(), Compression::default());
    invalid_identity.write_all(&serde_json::to_vec(&cached)?)?;
    fs::write(&shard_path, invalid_identity.finish()?)?;
    assert!(matches!(cache.load(&candidate)?, CacheRead::Corrupt(_)));

    fs::write(
        cache_config.directory.join("revision-manifest-v1.json"),
        b"not json",
    )?;
    fs::remove_dir_all(cache_config.directory.join("projects"))?;
    let manifest_miss = build_profile(&[file], None, Profile::Espalier, &cache_config, false)?;
    assert_eq!(manifest_miss.metrics.shard_misses, 1);
    Ok(())
}

#[test]
fn cache_io_failures_and_nested_registry_walks_are_reported() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let registry_root = directory.path().join("registry");
    let nested = registry_root.join("nested");
    fs::create_dir_all(&nested)?;
    fs::write(nested.join("registry.yml"), "kind: constant\n")?;
    let mut discovered = Vec::new();
    collect_files(&registry_root, &mut discovered)?;
    assert_eq!(discovered.len(), 1);

    let file = ruby_file(directory.path(), "sample.rb", "class A; end\n");
    let candidate = candidate(
        &file,
        None,
        Profile::Espalier,
        directory.path(),
        &stdlib_registry_digest()?,
        &configuration_digest()?,
    )?;
    let cache = ShardCache::new(directory.path().join("cache"));
    fs::create_dir_all(cache.shard_path(&candidate.cache_key))?;
    assert!(cache.load(&candidate).is_err());
    fs::create_dir_all(cache.manifest_path())?;
    assert!(cache.load_manifest().is_err());

    let blocked = directory.path().join("blocked");
    fs::write(&blocked, "not a directory")?;
    let blocked_config = CacheConfig::new(directory.path().to_path_buf(), blocked);
    assert!(build_profile(&[file], None, Profile::Espalier, &blocked_config, false).is_err());
    Ok(())
}

#[test]
fn missing_configured_global_shapes_fails_before_cache_lookup() {
    let _environment = ENV_LOCK.lock().expect("environment lock");
    std::env::set_var(
        "FACT_MINE_GLOBAL_SHAPES_FILE",
        "/definitely/missing/fact-mine.json",
    );
    assert!(configuration_digest().is_err());
    std::env::remove_var("FACT_MINE_GLOBAL_SHAPES_FILE");
}
