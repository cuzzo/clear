use std::path::Path;
use std::process::Command;

#[test]
fn ruby_launcher_executes_the_rust_cli() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new("ruby")
        .arg(root.join("exe").join("decomplex"))
        .args([
            "syntax-facts",
            "--language=python",
            root.join("tests")
                .join("fixtures")
                .join("python_state_read_regressions.py")
                .to_str()
                .unwrap(),
        ])
        .env(
            "DECOMPLEX_RUST_BINARY",
            env!("CARGO_BIN_EXE_decomplex-rust"),
        )
        .output()
        .expect("run Ruby launcher");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let facts: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("launcher JSON output");
    assert_eq!(facts["format"], "decomplex.syntax-facts.v1");
    assert!(facts["documents"]
        .as_array()
        .is_some_and(|documents| !documents.is_empty()));
}
