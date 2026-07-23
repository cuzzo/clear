use anyhow::{bail, Context, Result};
use crate::ast;
use crate::syntax::Language;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn normalizer_examples_match_oracles() -> Result<()> {
    let fixtures_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("normalizer");
    if !fixtures_root.exists() {
        return Ok(());
    }
    let oracle_dir = fixtures_root.join("oracles");
    let mut failures = Vec::new();

    for fixture in fixture_paths(&fixtures_root)? {
        let language = language_for_fixture(&fixture)?;
        let name = fixture.file_stem().unwrap().to_str().unwrap();
        let oracle_path = oracle_dir.join(format!("{}-{name}.json", language.as_str()));

        let (ast, _) = ast::parse_with_language(&fixture, language)
            .with_context(|| format!("parse {}", fixture.display()))?;

        let actual = serde_json::to_value(&ast)?;

        let is_update = std::env::var("UPDATE_ORACLES").is_ok();
        let expected: Value = if is_update && !oracle_path.exists() {
            if let Some(parent) = oracle_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            serde_json::json!({})
        } else {
            serde_json::from_str(
                &fs::read_to_string(&oracle_path).unwrap_or_else(|_| "{}".to_string()),
            )
            .with_context(|| format!("read {}", oracle_path.display()))?
        };

        if is_update {
            fs::write(&oracle_path, serde_json::to_string_pretty(&actual)?)?;
        } else if actual != expected {
            failures.push(format!(
                "{}\nexpected: {}\nactual:   {}",
                fixture.display(),
                expected,
                actual
            ));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!("normalizer oracle failures:\n{}", failures.join("\n\n"))
    }
}

fn fixture_paths(root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file() && language_for_fixture(&path).is_ok() {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn language_for_fixture(path: &Path) -> Result<Language> {
    let extension = path.extension().and_then(|ext| ext.to_str()).unwrap_or("");
    Language::for_extension(extension)
        .with_context(|| format!("unsupported extension {}", extension))
}
