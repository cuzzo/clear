use sha2::{Digest, Sha256};
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

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["analyze", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();

    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    let run = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
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
    let typed_manifest: gigasail::RunManifest = serde_json::from_value(manifest.clone()).unwrap();
    let sarif = String::from_utf8(
        gigasail::read_manifest_artifact(&run, &typed_manifest.artifacts[0]).unwrap(),
    )
    .unwrap();
    assert!(sarif.contains("fact-mine.rust_unsafe_block"), "{sarif}");
    assert!(!directory.path().join(".giga/gigasail.db").exists());
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
        let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
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

    let fingerprints = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
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
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  analyse:\n    producers: [static]\nproducers:\n  static:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .giga/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[]}' > .giga/artifacts/static.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .giga/artifacts/static.sarif\n        complete: false\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis profile");

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
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
    assert!(!directory.path().join(".giga/gigasail.db").exists());
    assert!(directory
        .path()
        .join(".giga/artifacts/runs")
        .read_dir()
        .unwrap()
        .any(|entry| entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("analysis-")));
    assert!(!directory
        .path()
        .join(".giga/artifacts/static.sarif")
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
        directory.path().join("gigasail.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .output()
        .unwrap();
    assert!(analyse.status.success());
    let run = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("analysis-"))
        })
        .unwrap();
    assert!(!run.join(".publication-state").exists());

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        ci.status.success(),
        "{}",
        String::from_utf8_lossy(&ci.stderr)
    );
    assert!(directory.path().join(".giga/artifacts/latest").exists());
}

#[test]
fn analyse_selects_a_trusted_custom_profile_and_stages_its_sarif() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    fs::write(
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  security:\n    producers: [adapter]\nproducers:\n  adapter:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .giga/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[]}' > .giga/artifacts/adapter.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .giga/artifacts/adapter.sarif\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis adapter");

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
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
    let run = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
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
        .join(".giga/artifacts/adapter.sarif")
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

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .args(["--ingest", "--db", ".giga/gigasail.db"])
        .output()
        .unwrap();
    assert!(
        analyse.status.success(),
        "{}",
        String::from_utf8_lossy(&analyse.stderr)
    );
    assert!(directory.path().join(".giga/gigasail.db").exists());

    let diff = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
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
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  unsafe:\n    producers: [bad]\nproducers:\n  bad:\n    executor: command\n    argv: [sh, -c, \"printf changed > lib.rs\"]\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["analyse", "--repo"])
        .arg(directory.path())
        .args([
            "--profile",
            "unsafe",
            "--ingest",
            "--db",
            ".giga/gigasail.db",
        ])
        .output()
        .unwrap();
    assert!(!analyse.status.success());
    assert!(String::from_utf8_lossy(&analyse.stderr).contains("trust-current-config"));
    assert!(!directory.path().join(".giga/gigasail.db").exists());
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

    let diff = Command::new(env!("CARGO_BIN_EXE_giga"))
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
    assert!(!directory.path().join(".giga/gigasail.db").exists());
    let runs = directory.path().join(".giga/artifacts/runs");
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

    let diff = Command::new(env!("CARGO_BIN_EXE_giga"))
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
    let source = directory.path().join(".giga/artifacts/fact-mine.sarif");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "declared output must survive\n").unwrap();
    let outside = tempfile::NamedTempFile::new().unwrap();
    fs::write(outside.path(), "outside must survive\n").unwrap();
    let run = directory
        .path()
        .join(".giga/artifacts/runs/.staging-forged");
    fs::create_dir_all(&run).unwrap();
    fs::write(
        run.join("workspace-transaction.json"),
        r#"[{"source":".giga/artifacts/fact-mine.sarif","backup":"preexisting/../../../../../../tmp/forged","original_present":true}]"#,
    )
    .unwrap();

    let analyse = Command::new(env!("CARGO_BIN_EXE_giga"))
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
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  analyse:\n    producers: [static]\nproducers:\n  static:\n    executor: command\n    argv: [sh, -c, \"mkdir -p .giga/artifacts && printf '{\\\"version\\\":\\\"2.1.0\\\",\\\"runs\\\":[{\\\"tool\\\":{\\\"driver\\\":{\\\"name\\\":\\\"Test Analyzer\\\"}},\\\"properties\\\":{\\\"gigasail.proof_boundary\\\":[\\\"partial analyzer\\\"]},\\\"results\\\":[{\\\"ruleId\\\":\\\"T001\\\",\\\"level\\\":\\\"warning\\\",\\\"message\\\":{\\\"text\\\":\\\"overlay finding\\\"},\\\"properties\\\":{\\\"tier\\\":1,\\\"category\\\":\\\"static-hazard\\\"},\\\"locations\\\":[{\\\"physicalLocation\\\":{\\\"artifactLocation\\\":{\\\"uri\\\":\\\"lib.rs\\\"},\\\"region\\\":{\\\"startLine\\\":1}}},{\\\"physicalLocation\\\":{\\\"artifactLocation\\\":{\\\"uri\\\":\\\"lib.rs\\\"},\\\"region\\\":{\\\"startLine\\\":2}}}]}]}]}' > .giga/artifacts/static.sarif\"]\n    produces:\n      - kind: sarif\n        format: sarif\n        path: .giga/artifacts/static.sarif\n        complete: false\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "analysis profile");
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 2 }\n",
    )
    .unwrap();

    let diff = Command::new(env!("CARGO_BIN_EXE_giga"))
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
    assert!(!directory.path().join(".giga/artifacts/latest").exists());
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
        directory.path().join("gigasail.yml"),
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

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
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
    assert!(directory.path().join(".giga/gigasail.db").exists());
    assert!(directory
        .path()
        .join(".giga/artifacts/latest/manifest.json")
        .exists());
    assert!(!directory
        .path()
        .join(".giga/artifacts/coverage.json")
        .exists());

    let diff = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["diff", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--full"])
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
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  ci:\n    producers: [broken]\nproducers:\n  broken:\n    executor: command\n    argv: [sh, -c, 'exit 7']\n    timeout_seconds: 1\n    max_output_bytes: 1024\n    produces:\n      - kind: coverage\n        format: generic\n        path: .giga/artifacts/coverage.json\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");
    fs::create_dir_all(directory.path().join(".giga/artifacts")).unwrap();
    fs::write(
        directory.path().join(".giga/artifacts/coverage.json"),
        "previous output",
    )
    .unwrap();

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(!ci.status.success());
    assert_eq!(
        fs::read_to_string(directory.path().join(".giga/artifacts/coverage.json")).unwrap(),
        "previous output"
    );
    let failed = fs::read_dir(directory.path().join(".giga/artifacts/runs"))
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
        directory.path().join("gigasail.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");

    let first = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );

    let artifacts = directory.path().join(".giga/artifacts");
    let published = artifacts.join("latest").canonicalize().unwrap();
    let pending = artifacts.join("runs/pending-recovery");
    fs::rename(&published, &pending).unwrap();
    fs::write(pending.join(".publication-state"), "ingested\n").unwrap();
    fs::write(directory.path().join("dirty.txt"), "stop after recovery\n").unwrap();

    let second = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
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
        directory.path().join("gigasail.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "reviewed configuration");
    fs::write(
        directory.path().join("gigasail.yml"),
        complete_profile_config().replace(
            "mkdir -p .giga/artifacts",
            "touch untrusted-config-executed && mkdir -p .giga/artifacts",
        ),
    )
    .unwrap();
    commit_all(&repository, &signature, "untrusted config change");

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db"])
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
        directory.path().join("gigasail.yml"),
        "version: 1\nprofiles:\n  ci:\n    producers: [check]\nproducers:\n  check:\n    executor: command\n    argv: [true]\n",
    )
    .unwrap();
    commit_all(&repository, &signature, "empty profile");

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
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
        directory.path().join("gigasail.yml"),
        complete_profile_config(),
    )
    .unwrap();
    commit_all(&repository, &signature, "initial");
    let first = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(first.status.success());

    let artifacts = directory.path().join(".giga/artifacts");
    let published = artifacts.join("latest").canonicalize().unwrap();
    fs::write(published.join(".publication-state"), "ready_to_publish\n").unwrap();
    fs::remove_file(artifacts.join("latest")).unwrap();
    fs::write(directory.path().join("dirty.txt"), "stop after recovery\n").unwrap();

    let second = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/gigasail.db", "--trust-current-config"])
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

#[test]
fn ingest_run_rejects_a_path_traversal_producer_before_creating_temp_files() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    let run = directory.path().join("incoming");
    fs::create_dir_all(run.join("artifacts")).unwrap();
    let sarif = br#"{"version":"2.1.0","runs":[]}"#;
    fs::write(run.join("artifacts/findings.sarif"), sarif).unwrap();
    let escaped = std::env::temp_dir().join(format!(
        "gigasail-manifest-producer-escape-{}-{}.json",
        std::process::id(),
        revision
    ));
    let _ = fs::remove_file(&escaped);
    write_external_sarif_manifest(
        &run,
        &revision,
        "x/../../gigasail-manifest-producer-escape",
        "sarif",
        sarif,
        directory.path(),
    );

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!ingest.status.success());
    assert!(
        String::from_utf8_lossy(&ingest.stderr).contains("unsafe producer identifier"),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    assert!(
        !escaped.exists(),
        "untrusted producer escaped the temp directory"
    );
}

#[test]
fn ingest_run_rejects_malformed_sarif_before_recording_complete_evidence() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    let run = directory.path().join("incoming");
    fs::create_dir_all(run.join("artifacts")).unwrap();
    let sarif = br#"{"version":"2.0.0","runs":[]}"#;
    fs::write(run.join("artifacts/findings.sarif"), sarif).unwrap();
    write_external_sarif_manifest(&run, &revision, "scanner", "sarif", sarif, directory.path());

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!ingest.status.success());
    assert!(
        String::from_utf8_lossy(&ingest.stderr).contains("SARIF version must be"),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    assert!(
        !directory.path().join(".giga/fresh.db").exists(),
        "invalid SARIF must be rejected before snapshot creation mutates a fresh database"
    );
}

#[test]
fn ingest_run_rejects_invalid_complete_scope_before_indexing_a_fresh_database() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    let run = directory.path().join("incoming");
    fs::create_dir_all(run.join("artifacts")).unwrap();
    let sarif = br#"{"version":"2.1.0","runs":[]}"#;
    fs::write(run.join("artifacts/findings.sarif"), sarif).unwrap();
    write_external_sarif_manifest(&run, &revision, "scanner", "sarif", sarif, directory.path());
    let manifest_path = run.join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    manifest["artifacts"][0]["evidence_scope"]["selection"] = serde_json::json!("");
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!ingest.status.success());
    assert!(
        String::from_utf8_lossy(&ingest.stderr).contains("evidence_scope"),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    assert!(
        !directory.path().join(".giga/fresh.db").exists(),
        "manifest validation must happen before a fresh database is indexed"
    );
}

#[test]
fn ingest_run_rolls_back_complete_sarif_when_results_cannot_be_represented() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    let run = directory.path().join("incoming");
    fs::create_dir_all(run.join("artifacts")).unwrap();
    let sarif = br#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scanner"}},"results":[{"ruleId":"unanchored","message":{"text":"cannot represent this result"}}]}]}"#;
    fs::write(run.join("artifacts/findings.sarif"), sarif).unwrap();
    write_external_sarif_manifest(&run, &revision, "scanner", "sarif", sarif, directory.path());

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!ingest.status.success());
    assert!(String::from_utf8_lossy(&ingest.stderr).contains("complete SARIF"));
    let connection =
        rusqlite::Connection::open(directory.path().join(".giga/fresh.db")).unwrap();
    let scopes: i64 = connection
        .query_row("SELECT COUNT(*) FROM evidence_artifact_scopes", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(scopes, 0);
}

#[test]
fn ingest_run_requires_successful_declared_producers_for_every_artifact() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    let run = directory.path().join("incoming");
    fs::create_dir_all(run.join("artifacts")).unwrap();
    let sarif = br#"{"version":"2.1.0","runs":[]}"#;
    fs::write(run.join("artifacts/findings.sarif"), sarif).unwrap();
    write_external_sarif_manifest(&run, &revision, "scanner", "sarif", sarif, directory.path());

    let manifest_path = run.join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();
    manifest["producers"][0]["outcome"] = serde_json::json!("failed");
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let failed = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!failed.status.success());
    assert!(String::from_utf8_lossy(&failed.stderr).contains("non-successful producer"));

    manifest["producers"][0]["outcome"] = serde_json::json!("succeeded");
    manifest["artifacts"][0]["producer"] = serde_json::json!("undeclared");
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    let undeclared = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh.db",
            "--run",
            "incoming/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(!undeclared.status.success());
    assert!(String::from_utf8_lossy(&undeclared.stderr).contains("not declared"));
}

#[test]
fn ingest_run_indexes_a_fresh_database_and_refreshes_the_manifest_revision() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    fs::write(
        directory.path().join("gigasail.yml"),
        complete_profile_config(),
    )
    .unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();

    let ci = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ci", "--repo"])
        .arg(directory.path())
        .args(["--db", ".giga/producer.db", "--trust-current-config"])
        .output()
        .unwrap();
    assert!(
        ci.status.success(),
        "{}",
        String::from_utf8_lossy(&ci.stderr)
    );
    fs::remove_file(directory.path().join(".giga/producer.db")).unwrap();

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/fresh/gigasail.db",
            "--run",
            ".giga/artifacts/latest/manifest.json",
        ])
        .output()
        .unwrap();
    assert!(
        ingest.status.success(),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    let storage =
        gigasail::Storage::open(directory.path().join(".giga/fresh/gigasail.db")).unwrap();
    assert!(storage.commit_exists(&revision).unwrap());
    assert_eq!(
        storage.ci_run_state("latest").unwrap().as_deref(),
        Some("ingested")
    );
}

#[test]
fn direct_ingest_coverage_matches_the_documented_kind_format_commit_workflow() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    fs::write(
        directory.path().join("coverage.json"),
        r#"{"files":[{"path":"lib.rs","coverage":100.0,"line_hits":[{"line":1,"hits":1}]}]}"#,
    )
    .unwrap();

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
            "--kind",
            "coverage",
            "--format",
            "generic",
            "--input",
            "coverage.json",
            "--commit",
            &revision,
            "--source",
            "direct-coverage",
            "--selection",
            "full",
            "--test-set",
            "unit",
            "--complete",
        ])
        .output()
        .unwrap();
    assert!(
        ingest.status.success(),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    let storage = gigasail::Storage::open(directory.path().join(".giga/gigasail.db")).unwrap();
    let scope = gigasail::EvidenceScopeFingerprint {
        revision,
        selection: "full".into(),
        mutant_corpus: "not-applicable".into(),
        test_set: "unit".into(),
    };
    assert!(storage
        .scoped_coverage_artifact("direct-coverage", &scope, &["lib.rs".into()])
        .unwrap()
        .is_some());
}

#[test]
fn direct_ingest_indexes_the_requested_historical_revision_in_a_fresh_database() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    let historical = commit_all(&repository, &signature, "historical").to_string();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 2 }\n",
    )
    .unwrap();
    let head = commit_all(&repository, &signature, "head").to_string();
    fs::write(
        directory.path().join("coverage.json"),
        r#"{"files":[{"path":"lib.rs","coverage":100.0,"line_hits":[{"line":1,"hits":1}]}]}"#,
    )
    .unwrap();

    let ingest = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
            "--kind",
            "coverage",
            "--format",
            "generic",
            "--input",
            "coverage.json",
            "--commit",
            &historical,
        ])
        .output()
        .unwrap();
    assert!(
        ingest.status.success(),
        "{}",
        String::from_utf8_lossy(&ingest.stderr)
    );
    let storage = gigasail::Storage::open(directory.path().join(".giga/gigasail.db")).unwrap();
    assert!(storage.commit_exists(&historical).unwrap());
    assert!(
        !storage.commit_exists(&head).unwrap(),
        "targeted snapshot indexing must not silently substitute the current HEAD"
    );
}

#[test]
fn direct_mutant_and_sarif_ingestion_record_complete_family_scopes() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(
        directory.path().join("lib.rs"),
        "pub fn value() -> u8 { 1 }\n",
    )
    .unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    fs::write(
        directory.path().join("mutants.json"),
        r#"{"schema":"mutant-facts/v1","source":"test","language":"rust","subjects":[{"file":"lib.rs","method":"value","mutations":1,"killed":1,"alive":0}]}"#,
    )
    .unwrap();
    fs::write(
        directory.path().join("findings.sarif"),
        r#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scanner"}},"results":[{"ruleId":"R001","level":"warning","message":{"text":"finding"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"lib.rs"},"region":{"startLine":1}}}]}]}]}"#,
    )
    .unwrap();

    let mutant = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
            "--kind",
            "mutants",
            "--format",
            "mutant-facts",
            "--input",
            "mutants.json",
            "--commit",
            &revision,
            "--source",
            "direct-mutants",
            "--selection",
            "full",
            "--mutant-corpus",
            "corpus",
            "--test-set",
            "unit",
            "--complete",
        ])
        .output()
        .unwrap();
    assert!(
        mutant.status.success(),
        "{}",
        String::from_utf8_lossy(&mutant.stderr)
    );

    let sarif = Command::new(env!("CARGO_BIN_EXE_giga"))
        .args(["ingest", "--repo"])
        .arg(directory.path())
        .args([
            "--db",
            ".giga/gigasail.db",
            "--kind",
            "sarif",
            "--format",
            "sarif",
            "--input",
            "findings.sarif",
            "--commit",
            &revision,
            "--source",
            "direct-sarif",
            "--selection",
            "full",
            "--test-set",
            "unit",
            "--complete",
        ])
        .output()
        .unwrap();
    assert!(
        sarif.status.success(),
        "{}",
        String::from_utf8_lossy(&sarif.stderr)
    );

    let connection =
        rusqlite::Connection::open(directory.path().join(".giga/gigasail.db")).unwrap();
    let scopes: Vec<(String, String, i64)> = connection
        .prepare("SELECT family, source, complete FROM evidence_artifact_scopes ORDER BY family")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(
        scopes,
        vec![
            ("mutation".into(), "corpus".into(), 1),
            ("sarif".into(), "direct-sarif".into(), 1),
        ]
    );
}

#[test]
fn complete_direct_imports_rollback_when_coverage_mutants_or_sarif_skip_evidence() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    fs::write(directory.path().join("lib.rs"), "pub fn value() {}\n").unwrap();
    let revision = commit_all(&repository, &signature, "initial").to_string();
    fs::write(
        directory.path().join("coverage.json"),
        r#"{"files":[{"path":"missing.rs","coverage":100.0,"line_hits":[{"line":1,"hits":1}]}]}"#,
    )
    .unwrap();
    fs::write(
        directory.path().join("mutants.json"),
        r#"{"schema":"mutant-facts/v1","source":"test","language":"rust","subjects":[{"file":"missing.rs","method":"value","mutations":1,"killed":1,"alive":0}]}"#,
    )
    .unwrap();
    fs::write(
        directory.path().join("findings.sarif"),
        r#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"scanner"}},"results":[{"ruleId":"missing-location","message":{"text":"cannot anchor"}}]}]}"#,
    )
    .unwrap();
    for (kind, format, input, extra) in [
        ("coverage", "generic", "coverage.json", Vec::<&str>::new()),
        (
            "mutants",
            "mutant-facts",
            "mutants.json",
            vec!["--mutant-corpus", "corpus"],
        ),
        ("sarif", "sarif", "findings.sarif", Vec::new()),
    ] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_giga"));
        command.args(["ingest", "--repo"]);
        command.arg(directory.path());
        command.args([
            "--db",
            ".giga/gigasail.db",
            "--kind",
            kind,
            "--format",
            format,
            "--input",
            input,
            "--commit",
            &revision,
            "--selection",
            "full",
            "--test-set",
            "unit",
            "--complete",
        ]);
        command.args(extra);
        let output = command.output().unwrap();
        assert!(
            !output.status.success(),
            "{kind} unexpectedly accepted skipped complete evidence"
        );
        assert!(String::from_utf8_lossy(&output.stderr).contains("complete"));
    }
    let connection =
        rusqlite::Connection::open(directory.path().join(".giga/gigasail.db")).unwrap();
    let scopes: i64 = connection
        .query_row("SELECT COUNT(*) FROM evidence_artifact_scopes", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        scopes, 0,
        "rolled-back complete imports must leave no exact scope"
    );
}

fn write_external_sarif_manifest(
    run: &std::path::Path,
    revision: &str,
    producer: &str,
    format: &str,
    sarif: &[u8],
    repository: &std::path::Path,
) {
    let artifact_hash = hex::encode(Sha256::digest(sarif));
    let manifest = serde_json::json!({
        "version": "gigasail-run/v1",
        "revision": revision,
        "profile": "external",
        "repository_identity": gigasail::repository_identity(repository),
        "tree_fingerprint": revision,
        "started_at_unix_ms": 1,
        "duration_ms": 1,
        "status": "succeeded",
        "configuration_hash": "external",
        "producers": [{
            "name": producer,
            "argv": ["external"],
            "tool_version": "1",
            "working_directory": ".",
            "settings_hash": "settings",
            "started_at_unix_ms": 1,
            "duration_ms": 1,
            "exit_status": 0,
            "outcome": "succeeded",
            "failure": null,
            "stdout_log": "logs/stdout.log",
            "stderr_log": "logs/stderr.log"
        }],
        "artifacts": [{
            "producer": producer,
            "kind": "sarif",
            "format": format,
            "path": "artifacts/findings.sarif",
            "content_hash": artifact_hash,
            "compression": "none",
            "scope": null,
            "complete": true,
            "evidence_scope": {"selection":"full","test_set":"unit"}
        }]
    });
    fs::write(
        run.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).unwrap(),
    )
    .unwrap();
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
    argv: [sh, -c, "mkdir -p .giga/artifacts && printf '{\"files\":[{\"path\":\"lib.rs\",\"coverage\":100.0,\"line_hits\":[{\"line\":1,\"hits\":1}]}]}' > .giga/artifacts/coverage.json && printf '{\"schema\":\"mutant-facts/v1\",\"source\":\"test\",\"language\":\"rust\",\"subjects\":[{\"file\":\"lib.rs\",\"method\":\"value\",\"mutations\":1,\"killed\":1,\"alive\":0}]}' > .giga/artifacts/mutants.json && printf '{\"version\":\"2.1.0\",\"runs\":[]}' > .giga/artifacts/findings.sarif"]
    timeout_seconds: 10
    max_output_bytes: 1024
    produces:
      - kind: coverage
        format: generic
        path: .giga/artifacts/coverage.json
        complete: true
        evidence_scope: {selection: full, test_set: unit}
      - kind: mutants
        format: mutant-facts
        path: .giga/artifacts/mutants.json
        complete: true
        evidence_scope: {selection: full, mutant_corpus: corpus, test_set: unit}
      - kind: sarif
        format: sarif
        path: .giga/artifacts/findings.sarif
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
