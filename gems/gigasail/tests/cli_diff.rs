use std::process::Command;
use tempfile::tempdir;

#[test]
fn diff_prints_revision_pinned_text_and_versioned_json_without_writing_analysis_data() {
    let directory = tempdir().unwrap();
    let repository = git2::Repository::init(directory.path()).unwrap();
    let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
    let source = directory.path().join("lib.rs");
    std::fs::write(&source, "pub fn value() -> u8 { 1 }\n").unwrap();
    let base = commit_file(&repository, &signature, None);
    std::fs::write(&source, "pub fn value() -> u8 { 2 }\n").unwrap();
    let head = commit_file(&repository, &signature, Some(base));
    let missing_db = directory.path().join("missing.db");

    let text = run_diff(directory.path(), &missing_db, base, head, ["--full"]);
    assert!(
        text.status.success(),
        "{}",
        String::from_utf8_lossy(&text.stderr)
    );
    let text = String::from_utf8(text.stdout).unwrap();
    assert!(text.contains(&format!("Gigasail diff {base}..{head}")));
    assert!(text.contains("Evidence: coverage=missing mutation=missing"));
    assert!(!missing_db.exists());

    gigasail::Storage::open(&missing_db).unwrap();
    let output = run_diff(
        directory.path(),
        &missing_db,
        base,
        head,
        [
            "--format",
            "json",
            "--coverage-source",
            "coverage:ci",
            "--sarif-source",
            "scanner",
            "--selection",
            "production",
            "--mutant-corpus",
            "mutants",
            "--test-set",
            "suite",
        ],
    );

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let document: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(document["format_version"], "gigasail-diff/v1");
    assert_eq!(document["plan"]["scope"]["base_oid"], base.to_string());
    assert_eq!(document["plan"]["scope"]["head_oid"], head.to_string());
    assert_eq!(
        document["plan"]["scope"]["evidence_scope"]["selection"],
        "production"
    );
}

fn run_diff<const N: usize>(
    repo: &std::path::Path,
    db: &std::path::Path,
    base: git2::Oid,
    head: git2::Oid,
    options: [&str; N],
) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_giga"));
    command.arg("diff").args(options).arg("--repo").arg(repo);
    command
        .arg("--db")
        .arg(db)
        .arg(base.to_string())
        .arg(head.to_string())
        .output()
        .unwrap()
}

fn commit_file(
    repository: &git2::Repository,
    signature: &git2::Signature<'_>,
    parent: Option<git2::Oid>,
) -> git2::Oid {
    let mut index = repository.index().unwrap();
    index.add_path(std::path::Path::new("lib.rs")).unwrap();
    let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
    let parent_commit = parent.map(|oid| repository.find_commit(oid).unwrap());
    let parents = parent_commit.iter().collect::<Vec<_>>();
    repository
        .commit(
            Some("HEAD"),
            signature,
            signature,
            "change source",
            &tree,
            &parents,
        )
        .unwrap()
}
