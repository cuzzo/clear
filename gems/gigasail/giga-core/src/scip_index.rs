//! Resolves the SCIP indexer a repository needs. The table is code, not
//! configuration: `executor: gigasail` must never let a giga.yml name an
//! executable to run.

use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

/// Indexer invocation per language. `{index}` is the declared output artifact.
/// Versions are the ones espalier's big-o.md pins for its acceptance corpora.
const INDEXERS: &[(&str, &[&str])] = &[
    ("go", &["scip-go", "index", "./...", "--quiet", "--output", "{index}"]),
    ("rust", &["rust-analyzer", "scip", ".", "--output", "{index}"]),
    ("java", &["scip-java", "index", "--output", "{index}"]),
    ("kotlin", &["scip-java", "index", "--output", "{index}"]),
    ("csharp", &["scip-dotnet", "index", "--output", "{index}"]),
    ("python", &["scip-python", "index", ".", "--output={index}"]),
    ("typescript", &["scip-typescript", "index", "--output", "{index}"]),
    ("javascript", &["scip-typescript", "index", "--output", "{index}"]),
    (
        "cpp",
        &[
            "scip-clang",
            "--compdb-path=compile_commands.json",
            "--index-output-path={index}",
        ],
    ),
    ("php", &["scip-php", "--output", "{index}"]),
    ("ruby", &["scip-ruby", "--index-file", "{index}"]),
];

/// Marker that identifies a language's build, most specific first: a TypeScript
/// project also has a package.json, and a Gradle project may ship a go.mod for
/// a tool directory.
const MARKERS: &[(&str, &str)] = &[
    ("go.mod", "go"),
    ("Cargo.toml", "rust"),
    ("pom.xml", "java"),
    ("build.gradle", "java"),
    ("build.gradle.kts", "kotlin"),
    ("tsconfig.json", "typescript"),
    ("package.json", "javascript"),
    ("pyproject.toml", "python"),
    ("setup.py", "python"),
    ("composer.json", "php"),
    ("Gemfile", "ruby"),
    ("compile_commands.json", "cpp"),
];

pub fn detect_language(repo: &Path) -> Result<&'static str> {
    let found = MARKERS
        .iter()
        .filter(|(marker, _)| repo.join(marker).exists())
        .map(|(_, language)| *language)
        .collect::<Vec<_>>();
    let mut distinct = found.clone();
    distinct.sort_unstable();
    distinct.dedup();
    match distinct.as_slice() {
        [language] => Ok(language),
        [] => bail!(
            "no supported build marker in the repository root; name the language explicitly, as argv: [scip-index, go]"
        ),
        languages => bail!(
            "repository root matches {}; name the language explicitly, as argv: [scip-index, {}]",
            languages.join(" and "),
            languages[0]
        ),
    }
}

/// Indexers install into per-ecosystem bin directories that are routinely
/// absent from a non-login shell's PATH, which is the environment producers run
/// under.
fn resolve_tool(tool: &str) -> Result<String> {
    if let Some(path) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&path) {
            if directory.join(tool).is_file() {
                return Ok(tool.to_string());
            }
        }
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let candidates = [
        std::env::var_os("GOBIN").map(PathBuf::from),
        std::env::var_os("GOPATH").map(|gopath| PathBuf::from(gopath).join("bin")),
        home.as_ref().map(|home| home.join("go/bin")),
        home.as_ref().map(|home| home.join(".cargo/bin")),
        home.as_ref().map(|home| home.join(".local/bin")),
        Some(PathBuf::from("/usr/local/bin")),
    ];
    for candidate in candidates.into_iter().flatten() {
        let resolved = candidate.join(tool);
        if resolved.is_file() {
            return Ok(resolved.to_string_lossy().into_owned());
        }
    }
    bail!("{tool} is not installed or not on PATH; install it to index this repository")
}

pub fn indexer_argv(language: &str, output: &Path) -> Result<Vec<String>> {
    let Some((_, template)) = INDEXERS.iter().find(|(name, _)| *name == language) else {
        bail!(
            "no SCIP indexer is wired for {language:?}; supported: {}",
            INDEXERS
                .iter()
                .map(|(name, _)| *name)
                .collect::<Vec<_>>()
                .join(", ")
        );
    };
    let output = output.to_string_lossy();
    let mut argv = template
        .iter()
        .map(|argument| argument.replace("{index}", &output))
        .collect::<Vec<_>>();
    argv[0] = resolve_tool(&argv[0])?;
    Ok(argv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_a_single_build_marker() {
        let repo = tempfile::tempdir().unwrap();
        std::fs::write(repo.path().join("go.mod"), "module x\n").unwrap();
        assert_eq!(detect_language(repo.path()).unwrap(), "go");
    }

    #[test]
    fn refuses_to_guess_between_two_builds() {
        let repo = tempfile::tempdir().unwrap();
        std::fs::write(repo.path().join("go.mod"), "module x\n").unwrap();
        std::fs::write(repo.path().join("Cargo.toml"), "[package]\n").unwrap();
        let error = detect_language(repo.path()).unwrap_err().to_string();
        assert!(error.contains("go and rust"), "{error}");
        assert!(error.contains("scip-index"), "{error}");
    }

    #[test]
    fn refuses_a_repository_with_no_marker() {
        let repo = tempfile::tempdir().unwrap();
        assert!(detect_language(repo.path()).is_err());
    }

    #[test]
    fn a_typescript_project_is_not_mistaken_for_javascript() {
        let repo = tempfile::tempdir().unwrap();
        std::fs::write(repo.path().join("package.json"), "{}").unwrap();
        std::fs::write(repo.path().join("tsconfig.json"), "{}").unwrap();
        let error = detect_language(repo.path()).unwrap_err().to_string();
        assert!(error.contains("javascript and typescript"), "{error}");
    }

    #[test]
    fn substitutes_the_declared_output_path() {
        let argv = indexer_argv("go", Path::new(".giga/artifacts/index.scip")).unwrap();
        assert!(argv[0].ends_with("scip-go"), "{argv:?}");
        assert!(argv.contains(&".giga/artifacts/index.scip".to_string()), "{argv:?}");
    }

    #[test]
    fn an_unwired_language_names_what_is_supported() {
        let error = indexer_argv("cobol", Path::new("index.scip"))
            .unwrap_err()
            .to_string();
        assert!(error.contains("go, rust"), "{error}");
    }
}
