use std::fs;
use std::process::Command;
use tempfile::tempdir;

#[test]
fn analyze_alias_uses_a_safe_builtin_profile_without_lineage_configuration() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub unsafe fn raw() { unsafe { core::ptr::read(0 as *const u8); } }\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyze", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();

    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    let run = fs::read_dir(directory.path().join(".lineage/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("analysis-")
        })
        .unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(run.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["revision"], "WORKTREE");
    assert_eq!(manifest["status"], "succeeded");
    assert_eq!(manifest["producers"].as_array().unwrap().len(), 1);
    assert_eq!(manifest["producers"][0]["name"], "fact-mine");
    assert_eq!(manifest["producers"][0]["outcome"], "succeeded");
    assert_eq!(manifest["artifacts"].as_array().unwrap().len(), 1);
    let typed_manifest: lineage::RunManifest = serde_json::from_value(manifest.clone()).unwrap();
    let sarif = String::from_utf8(
        lineage::read_manifest_artifact(&run, &typed_manifest.artifacts[0]).unwrap(),
    )
    .unwrap();
    assert!(sarif.contains("fact-mine.rust_unsafe_block"), "{sarif}");
    assert!(!directory.path().join(".lineage/lineage.db").exists());
}

#[test]
fn standalone_analysis_manifest_fingerprints_the_dirty_worktree_content() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    for source in [
        "pub fn value() -> u8 { 2 }\n",
        "pub unsafe fn value() -> u8 { unsafe { core::ptr::read(0 as *const u8) } }\n",
    ] {
        fs::write(directory.path().join("lib.rs"), source).unwrap();
        let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
            .args(["analyse", "--repo"])
            .arg(directory.path())
            .output()
            .unwrap();
        assert!(
            analyse.status.success(),
            "{}",
            String::from_utf8_lossy(&analyse.stderr)
        );
    }

    let fingerprints = fs::read_dir(directory.path().join(".lineage/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path().join("manifest.json"))
        .filter_map(|manifest| fs::read(manifest).ok())
        .filter_map(|contents| serde_json::from_slice::<serde_json::Value>(&contents).ok())
        .filter_map(|manifest| manifest["tree_fingerprint"].as_str().map(str::to_string))
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(fingerprints.len(), 2);
    assert!(fingerprints
        .iter()
        .all(|fingerprint| fingerprint.starts_with("worktree:")));
}

#[test]
fn analyse_ignores_untrusted_checkout_configuration_and_bounds_run_retention() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  analyse:\n    producers: [static]\nproducers:\n  static:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .lineage/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[]}' > .lineage/artifacts/static.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .lineage/artifacts/static.sarif\n        complete: false\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis profile");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();
    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    assert!(String::from_utf8_lossy(&analyse.stdout).contains("revision=WORKTREE"));
    assert!(!directory.path().join(".lineage/lineage.db").exists());
    assert!(directory
        .path()
        .join(".lineage/artifacts/runs")
        .read_dir()
        .unwrap()
        .any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("analysis-")));
    assert!(!directory
        .path()
        .join(".lineage/artifacts/static.sarif")
        .exists());
}

#[test]
fn interrupted_standalone_analysis_run_cannot_block_the_next_ci_publication() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();
    assert!(analyse.status.success());
    let run = fs::read_dir(directory.path().join(".lineage/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("analysis-"))
        })
        .unwrap();
    assert!(!run.join(".publication-state").exists());

    let ci = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        ci.status.success(),
        "{}",
        String::from_utf8_lossy(&ci.stderr)
    );
    assert!(directory.path().join(".lineage/artifacts/latest").exists());
}

#[test]
fn analyse_selects_a_trusted_custom_profile_and_stages_its_sarif() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  security:\n    producers: [adapter]\nproducers:\n  adapter:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .lineage/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[]}' > .lineage/artifacts/adapter.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .lineage/artifacts/adapter.sarif\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis adapter");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .args(["--profile", "security", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    let run = fs::read_dir(directory.path().join(".lineage/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .next()
        .unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(run.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["producers"][0]["outcome"], "succeeded");
    assert_eq!(manifest["artifacts"][0]["producer"], "adapter");
    assert!(!directory
        .path()
        .join(".lineage/artifacts/adapter.sarif")
        .exists());
}

#[test]
fn analyse_ingest_indexes_a_clean_revision_and_its_fact_mine_sarif() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let base = commit_all(&repository, &signature, "initial");
    fs::write(
        directory.path().join("lib.rs"),
        "pub unsafe fn value() { unsafe { core::ptr::read(0 as *const u8); } }\n",
    )
    .unwrap();
    let head = commit_all(&repository, &signature, "hazard");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .args(["--ingest", "--db", ".lineage/lineage.db"])
        .output()
        .unwrap();
    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    assert!(directory.path().join(".lineage/lineage.db").exists());

    let diff = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".lineage/lineage.db",
            "--sarif-source",
            "fact-mine",
            "--format",
            "json",
        ])
        .arg(base.to_string())
        .arg(head.to_string())
        .output()
        .unwrap();
    assert!(
        diff.status.success(),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    assert!(
        String::from_utf8_lossy(&diff.stdout).contains("fact-mine.rust_unsafe_block"),
        "{}",
        String::from_utf8_lossy(&diff.stdout)
    );
}

#[test]
fn analyse_refuses_an_untrusted_profile_that_would_modify_tracked_source() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  unsafe:\n    producers: [bad]\nproducers:\n  bad:\n    executor: command\n    argv: [sh, -c, \"printf changed > lib.rs\"]\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .args([
            "--profile",
            "unsafe",
            "--ingest",
            "--db",
            ".lineage/lineage.db",
        ])
        .output()
        .unwrap();
    assert!(!analyse.status.success());
    assert!(String::from_utf8_lossy(&analyse.stderr).contains("trust-current-config"));
    assert!(!directory.path().join(".lineage/lineage.db").exists());
    assert_eq!(
        fs::read_to_string(directory.path().join("lib.rs")).unwrap(),
        "pub fn value() {}\n"
    );
}

#[test]
fn diff_analyse_runs_builtin_fact_mine_against_the_worktree_without_a_database() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    commit_all(&repository, &signature, "initial");
    fs::write(
        directory.path().join("lib.rs"),
        "pub unsafe fn value() { unsafe { core::ptr::read(0 as *const u8); } }\n",
    )
    .unwrap();

    let diff = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args(["--analyse", "--format", "json"])
        .output()
        .unwrap();
    assert!(
        diff.status.success(),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    assert!(
        String::from_utf8_lossy(&diff.stdout).contains("fact-mine.rust_unsafe_block"),
        "{}",
        String::from_utf8_lossy(&diff.stdout)
    );
    assert!(!directory.path().join(".lineage/lineage.db").exists());
    let runs = directory.path().join(".lineage/artifacts/runs");
    assert!(
        !runs.exists() || runs.read_dir().unwrap().next().is_none(),
        "diff --analyse must remove its ephemeral run"
    );
}

#[test]
fn diff_analyse_rejects_dirty_source_for_an_explicit_commit_head() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    let base = commit_all(&repository, &signature, "base");
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 2 }\n",
    )
    .unwrap();
    let head = commit_all(&repository, &signature, "head");
    fs::write(
        directory.path().join("lib.rs"),
        "pub unsafe fn value() -> u8 { unsafe { core::ptr::read(0 as *const u8) } }\n",
    )
    .unwrap();

    let diff = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args(["--analyse", "--format", "json"])
        .arg(base.to_string())
        .arg(head.to_string())
        .output()
        .unwrap();
    assert!(!diff.status.success());
    assert!(
        String::from_utf8_lossy(&diff.stderr).contains("requires a clean worktree"),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    assert!(
        !String::from_utf8_lossy(&diff.stdout).contains("fact-mine.rust_unsafe_block"),
        "dirty findings must not be attached to an immutable diff"
    );
}

#[test]
fn analyse_rejects_a_forged_workspace_journal_without_touching_source_or_outside_files() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    let tracked_source = directory.path().join("lib.rs");
    fs::write(&tracked_source, "pub fn value() -> u8 { 1 }\n").unwrap();
    commit_all(&repository, &signature, "initial");
    let source = directory.path().join(".lineage/artifacts/fact-mine.sarif");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "declared output must survive\n").unwrap();
    let outside = tempfile::NamedTempFile::new().unwrap();
    fs::write(outside.path(), "outside must survive\n").unwrap();
    let run = directory
        .path()
        .join(".lineage/artifacts/runs/.staging-forged");
    fs::create_dir_all(&run).unwrap();
    fs::write(
        run.join("workspace-transaction.json"),
        r#"[{"source":".lineage/artifacts/fact-mine.sarif","backup":"preexisting/../../../../../../tmp/forged","original_present":true}]"#,
    )
    .unwrap();

    let analyse = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();
    assert!(!analyse.status.success());
    assert!(
        String::from_utf8_lossy(&analyse.stderr).contains("workspace transaction"),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    assert_eq!(
        fs::read_to_string(&tracked_source).unwrap(),
        "pub fn value() -> u8 { 1 }\n"
    );
    assert_eq!(
        fs::read_to_string(&source).unwrap(),
        "declared output must survive\n"
    );
    assert_eq!(
        fs::read_to_string(outside.path()).unwrap(),
        "outside must survive\n"
    );
}

#[test]
fn diff_analyse_applies_configured_sarif_as_a_worktree_overlay() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  analyse:\n    producers: [static]\nproducers:\n  static:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .lineage/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[{\\\"tool\\\":{\\\"driver\\\":{\\\"name\\\":\\\"Test Analyzer\\\"}},\\\"properties\\\":{\\\"lineage.proof_boundary\\\":[\\\"partial analyzer\\\"]},\\\"results\\\":[{\\\"ruleId\\\":\\\"T001\\\",\\\"level\\\":\\\"warning\\\",\\\"message\\\":{\\\"text\\\":\\\"overlay finding\\\"},\\\"properties\\\":{\\\"tier\\\":1,\\\"category\\\":\\\"static-hazard\\\"},\\\"locations\\\":[{\\\"physicalLocation\\\":{\\\"artifactLocation\\\":{\\\"uri\\\":\\\"lib.rs\\\"},\\\"region\\\":{\\\"startLine\\\":1}}},{\\\"physicalLocation\\\":{\\\"artifactLocation\\\":{\\\"uri\\\":\\\"lib.rs\\\"},\\\"region\\\":{\\\"startLine\\\":2}}}]}]}]}' > .lineage/artifacts/static.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .lineage/artifacts/static.sarif\n        complete: false\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis profile");
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 2 }\n",
    )
    .unwrap();

    let diff = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args(["--analyse", "--trust-current-config", "--format", "json"])
        .output()
        .unwrap();
    assert!(
        diff.status.success(),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    assert!(String::from_utf8_lossy(&diff.stdout).contains("overlay finding"));
    assert!(String::from_utf8_lossy(&diff.stdout).contains("partial analyzer"));
    assert!(String::from_utf8_lossy(&diff.stdout).contains("static-hazard"));
    assert!(!directory.path().join(".lineage/artifacts/latest").exists());
}

#[test]
fn ci_ingests_a_complete_profile_publishes_it_and_diff_requires_that_profile() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config(),
    )
    .unwrap();
    let base = commit_all(&repository, &signature, "initial");
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 2 }\n",
    )
    .unwrap();
    let head = commit_all(&repository, &signature, "change");

    let ci = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".lineage/lineage.db",
            "--profile",
            "ci",
            "--trust-current-config",
            "--require-complete",
        ])
        .output()
        .unwrap();
    assert!(
        ci.status.success(),
        "{}",
        String::from_utf8_lossy(&ci.stderr)
    );
    assert!(directory.path().join(".lineage/lineage.db").exists());
    assert!(directory
        .path()
        .join(".lineage/artifacts/latest/manifest.json")
        .exists());
    assert!(!directory
        .path()
        .join(".lineage/artifacts/coverage.json")
        .exists());

    let diff = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--full"])
        .args(["--require-profile", "ci", "--require-complete"])
        .arg(base.to_string())
        .arg(head.to_string())
        .output()
        .unwrap();
    assert!(
        diff.status.success(),
        "{}",
        String::from_utf8_lossy(&diff.stderr)
    );
    let rendered = String::from_utf8(diff.stdout).unwrap();
    assert!(rendered.contains("Evidence completeness:"));
    assert!(rendered.contains("coverage=exact"), "{rendered}");
    assert!(rendered.contains("mutation=exact"), "{rendered}");
    assert!(rendered.contains("sarif=partial"), "{rendered}");
    assert!(rendered.contains("Configured evidence (ci):"), "{rendered}");
    assert!(rendered.contains("exact     Coverage"), "{rendered}");
    assert!(rendered.contains("exact     Mutants"), "{rendered}");
}

#[test]
fn ci_failure_records_the_failing_producer_and_preserves_workspace_outputs() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  ci:\n    producers: [broken]\nproducers:\n  broken:\n    executor: command\n    argv: [sh, -c, 'exit 7']\n    timeout_seconds: 1\n    max_output_bytes: 1024\n    produces:\n      - kind: coverage\n        format: generic\n        path: .lineage/artifacts/coverage.json\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");
    fs::create_dir_all(directory.path().join(".lineage/artifacts")).unwrap();
    fs::write(
        directory.path().join(".lineage/artifacts/coverage.json"),
        "previous output",
    )
    .unwrap();

    let ci = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(!ci.status.success());
    assert_eq!(
        fs::read_to_string(directory.path().join(".lineage/artifacts/coverage.json")).unwrap(),
        "previous output"
    );
    let failed = fs::read_dir(directory.path().join(".lineage/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("failed-")
        })
        .unwrap();
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(failed.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["status"], "failed");
    assert_eq!(manifest["producers"][0]["name"], "broken");
    assert_eq!(manifest["producers"][0]["outcome"], "failed");
}

#[test]
fn next_ci_recovers_an_ingested_pending_run_before_its_own_clean_check() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let first = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );

    let artifacts = directory.path().join(".lineage/artifacts");
    let published = artifacts.join("latest").canonicalize().unwrap();
    let pending = artifacts.join("runs/pending-recovery");
    fs::rename(&published, &pending).unwrap();
    fs::write(pending.join(".publication-state"), "ingested\n").unwrap();
    fs::write(directory.path().join("dirty.txt"), "stop after recovery\n").unwrap();

    let second = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(!second.status.success());
    assert!(String::from_utf8_lossy(&second.stderr).contains("clean worktree"));
    assert!(artifacts.join("latest/manifest.json").exists());
    assert_eq!(
        fs::read_to_string(artifacts.join("latest/.publication-state")).unwrap(),
        "published\n"
    );
    assert!(!pending.exists());
}

#[test]
fn ci_uses_the_reviewed_parent_config_when_lineage_yml_changes() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "reviewed configuration");
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config().replace(
            "mkdir -p .lineage/artifacts",
            "touch untrusted-config-executed && mkdir -p .lineage/artifacts",
        ),
    )
    .unwrap();
    commit_all(&repository, &signature, "untrusted config change");

    let ci = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db"])
        .output()
        .unwrap();
    assert!(
        ci.status.success(),
        "{}",
        String::from_utf8_lossy(&ci.stderr)
    );
    assert!(!directory.path().join("untrusted-config-executed").exists());
}

#[test]
fn require_complete_rejects_a_profile_without_evidence_artifacts() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        "version: 1\nprofiles:\n  ci:\n    producers: [check]\nproducers:\n  check:\n    executor: command\n    argv: [true]\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "empty profile");

    let ci = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".lineage/lineage.db",
            "--trust-current-config",
            "--require-complete",
        ])
        .output()
        .unwrap();
    assert!(!ci.status.success());
    assert!(String::from_utf8_lossy(&ci.stderr).contains("declares no evidence artifacts"));
}

#[test]
fn next_ci_repairs_a_published_run_left_before_latest_pointer_update() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("lineage.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");
    let first = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(first.status.success());

    let artifacts = directory.path().join(".lineage/artifacts");
    let published = artifacts.join("latest").canonicalize().unwrap();
    fs::write(published.join(".publication-state"), "ready_to_publish\n").unwrap();
    fs::remove_file(artifacts.join("latest")).unwrap();
    fs::write(directory.path().join("dirty.txt"), "stop after recovery\n").unwrap();

    let second = Command::new(env!("CARGO_BIN_EXE_lineage"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".lineage/lineage.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(!second.status.success());
    assert!(String::from_utf8_lossy(&second.stderr).contains("clean worktree"));
    assert!(artifacts.join("latest/manifest.json").exists());
    assert_eq!(
        fs::read_to_string(artifacts.join("latest/.publication-state")).unwrap(),
        "published\n"
    );
}

fn complete_profile_config() -> &'static str {
    r#"version: 1
profiles:
  ci:
    producers: [evidence]
    required_evidence: [coverage, mutants, sarif]
producers:
  evidence:
    executor: command
    argv: [sh, -c, "mkdir -p .lineage/artifacts && printf '{\"files\":[{\"path\":\"lib.rs\",\"coverage\":100.0,\"line_hits\":[{\"line\":1,\"hits\":1}]}]}' > .lineage/artifacts/coverage.json && printf '{\"schema\":\"mutant-facts/v1\",\"source\":\"test\",\"language\":\"rust\",\"subjects\":[{\"file\":\"lib.rs\",\"method\":\"value\",\"mutations\":1,\"killed\":1,\"alive\":0}]}' > .lineage/artifacts/mutants.json && printf '{\"version\":\"2.1.0\",\"runs\":[]}' > .lineage/artifacts/findings.sarif"]
    timeout_seconds: 10
    max_output_bytes: 1024
    produces:
      - kind: coverage
        format: generic
        path: .lineage/artifacts/coverage.json
        complete: true
        evidence_scope: {selection: full, test_set: unit}
      - kind: mutants
        format: mutant-facts
        path: .lineage/artifacts/mutants.json
        complete: true
        evidence_scope: {selection: full, mutant_corpus: corpus, test_set: unit}
      - kind: sarif
        format: sarif
        path: .lineage/artifacts/findings.sarif
        complete: true
        evidence_scope: {selection: full, test_set: unit}
"#
}

fn commit_all(
    repository: &git2::Repository,
    signature: &git2::Signature<'_>,
    message: &str,
) -> git2::Oid {
    let mut index = repository.index().unwrap();
    for entry in fs::read_dir(repository.workdir().unwrap()).unwrap() {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file() {
            index
                .add_path(
                    entry
                        .path()
                        .strip_prefix(repository.workdir().unwrap())
                        .unwrap(),
                )
                .unwrap();
        }
    }
    index.write().unwrap();
    let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
    let parents = repository
        .head()
        .ok()
        .and_then(|head| head.peel_to_commit().ok())
        .into_iter()
        .collect::<Vec<_>>();
    let parent_refs = parents.iter().collect::<Vec<_>>();
    repository
        .commit(
            Some("HEAD"),
            signature,
            signature,
            message,
            &tree,
            &parent_refs,
        )
        .unwrap()
}
