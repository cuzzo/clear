//! Classify a change's newly-added imports into third-party packages, grouped
//! by language, for the diff summary's `NEW PACKAGES` section.
//!
//! The pivot is the repository's own module identity (Go's `module` line, a
//! Rust crate name, ...): an import under that identity is *first-party* (it is
//! a sibling package, surfaced elsewhere as a class collaboration, not a new
//! external package); an import with no external namespace is *stdlib*; only a
//! genuinely external module is a *third-party package* worth flagging here.

/// Where an import's target lives relative to the repository under review.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportOrigin {
    /// Language standard library / builtins (`fmt`, `std::fmt`, `os`).
    Stdlib,
    /// A sibling package in this same repository (module root match).
    Internal,
    /// An external dependency - the only kind `NEW PACKAGES` lists.
    ThirdParty,
}

/// Go standard-library imports have no dot in their first path segment (no
/// domain); third-party import paths start with a host like `github.com`.
fn go_origin(label: &str) -> ImportOrigin {
    let first = label.split('/').next().unwrap_or(label);
    if first.contains('.') {
        ImportOrigin::ThirdParty
    } else {
        ImportOrigin::Stdlib
    }
}

const RUST_STDLIB: [&str; 5] = ["std", "core", "alloc", "proc_macro", "test"];

fn rust_origin(label: &str) -> ImportOrigin {
    let head = label.split("::").next().unwrap_or(label);
    match head {
        "crate" | "self" | "super" => ImportOrigin::Internal,
        h if RUST_STDLIB.contains(&h) => ImportOrigin::Stdlib,
        _ => ImportOrigin::ThirdParty,
    }
}

const NODE_BUILTINS: [&str; 22] = [
    "assert", "buffer", "child_process", "crypto", "dns", "events", "fs", "http",
    "https", "net", "os", "path", "process", "querystring", "stream", "string_decoder",
    "tls", "url", "util", "v8", "vm", "zlib",
];

fn js_origin(label: &str) -> ImportOrigin {
    if label.starts_with('.') || label.starts_with('/') {
        return ImportOrigin::Internal;
    }
    let bare = label.strip_prefix("node:").unwrap_or(label);
    let root = bare.split('/').next().unwrap_or(bare);
    if NODE_BUILTINS.contains(&root) {
        ImportOrigin::Stdlib
    } else {
        ImportOrigin::ThirdParty
    }
}

/// Classify one import label for a language, given the repository's first-party
/// module roots (e.g. `github.com/yahn/unslop`, a crate name). A first-party
/// match always wins - it is a sibling package, never a new external one.
pub fn classify_import(language: &str, raw: &str, first_party: &[String]) -> ImportOrigin {
    let label = raw.trim().trim_matches('"');
    if first_party.iter().any(|root| {
        !root.is_empty()
            && (label == root
                || label.starts_with(&format!("{root}/"))
                || label.starts_with(&format!("{root}::")))
    }) {
        return ImportOrigin::Internal;
    }
    match language {
        "go" => go_origin(label),
        "rust" => rust_origin(label),
        "javascript" | "typescript" => js_origin(label),
        // Languages without a namespace convention we model: anything that is
        // not first-party is treated as an external package. Better to list a
        // genuine dependency than to silently drop it.
        _ => ImportOrigin::ThirdParty,
    }
}

/// The package identity to display for a third-party import: the import path is
/// the package in Go; the crate is the first `::` segment in Rust; the package
/// is the (optionally scoped) first path segment in JS/TS.
pub fn package_name(language: &str, raw: &str) -> String {
    let label = raw.trim().trim_matches('"');
    match language {
        "rust" => label.split("::").next().unwrap_or(label).to_string(),
        "javascript" | "typescript" => {
            let bare = label.strip_prefix("node:").unwrap_or(label);
            if let Some(scoped) = bare.strip_prefix('@') {
                // `@scope/pkg/sub` -> `@scope/pkg`.
                let mut parts = scoped.splitn(3, '/');
                match (parts.next(), parts.next()) {
                    (Some(scope), Some(pkg)) => format!("@{scope}/{pkg}"),
                    _ => bare.to_string(),
                }
            } else {
                bare.split('/').next().unwrap_or(bare).to_string()
            }
        }
        // Go import paths and unknown languages: the label is the package.
        _ => label.to_string(),
    }
}

/// Group a change's per-file added imports into the third-party packages it
/// introduces, keyed by language, sorted and de-duplicated. `files` yields one
/// `(language, imports)` entry per changed file; stdlib and first-party imports
/// are dropped. This is the whole of the NEW PACKAGES computation minus the
/// manifest reads that supply `first_party`.
pub fn group_third_party<'a, I>(
    files: I,
    first_party: &[String],
) -> std::collections::BTreeMap<String, Vec<String>>
where
    I: IntoIterator<Item = (&'a str, &'a [String])>,
{
    let mut by_lang: std::collections::BTreeMap<String, std::collections::BTreeSet<String>> =
        std::collections::BTreeMap::new();
    for (language, imports) in files {
        for import in imports {
            if classify_import(language, import, first_party) == ImportOrigin::ThirdParty {
                by_lang
                    .entry(language.to_string())
                    .or_default()
                    .insert(package_name(language, import));
            }
        }
    }
    by_lang
        .into_iter()
        .map(|(lang, pkgs)| (lang, pkgs.into_iter().collect()))
        .collect()
}

/// The repository's own module roots, parsed from manifests at the head
/// revision. Imports under these are first-party (excluded from NEW PACKAGES).
pub fn first_party_roots(go_mod: Option<&str>, cargo_toml: Option<&str>) -> Vec<String> {
    let mut roots = Vec::new();
    if let Some(text) = go_mod {
        for line in text.lines() {
            if let Some(rest) = line.trim().strip_prefix("module ") {
                roots.push(rest.trim().to_string());
                break;
            }
        }
    }
    if let Some(text) = cargo_toml {
        // The [package] name; the crate's own `use <name>::` paths are first-party.
        let mut in_package = false;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('[') {
                in_package = trimmed == "[package]";
                continue;
            }
            if in_package {
                if let Some(rest) = trimmed.strip_prefix("name") {
                    if let Some(eq) = rest.trim_start().strip_prefix('=') {
                        let name = eq.trim().trim_matches('"');
                        // Cargo normalises `-` to `_` in import paths.
                        roots.push(name.replace('-', "_"));
                        break;
                    }
                }
            }
        }
    }
    roots
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_splits_stdlib_internal_and_third_party() {
        let fp = vec!["github.com/yahn/unslop".to_string()];
        assert_eq!(classify_import("go", "fmt", &fp), ImportOrigin::Stdlib);
        assert_eq!(classify_import("go", "path/filepath", &fp), ImportOrigin::Stdlib);
        assert_eq!(
            classify_import("go", "github.com/yahn/unslop/internal/format", &fp),
            ImportOrigin::Internal
        );
        assert_eq!(
            classify_import("go", "github.com/spf13/cobra", &fp),
            ImportOrigin::ThirdParty
        );
    }

    #[test]
    fn rust_splits_by_crate_head() {
        let fp = vec!["myapp".to_string()];
        assert_eq!(classify_import("rust", "std::fmt", &fp), ImportOrigin::Stdlib);
        assert_eq!(classify_import("rust", "crate::foo", &fp), ImportOrigin::Internal);
        assert_eq!(classify_import("rust", "myapp::bar", &fp), ImportOrigin::Internal);
        assert_eq!(classify_import("rust", "serde::Deserialize", &fp), ImportOrigin::ThirdParty);
        assert_eq!(package_name("rust", "serde::Deserialize"), "serde");
    }

    #[test]
    fn js_relative_is_internal_builtin_is_stdlib_scoped_package_kept() {
        assert_eq!(classify_import("typescript", "./util", &[]), ImportOrigin::Internal);
        assert_eq!(classify_import("javascript", "node:fs", &[]), ImportOrigin::Stdlib);
        assert_eq!(classify_import("javascript", "fs", &[]), ImportOrigin::Stdlib);
        assert_eq!(classify_import("typescript", "@scope/pkg/sub", &[]), ImportOrigin::ThirdParty);
        assert_eq!(package_name("typescript", "@scope/pkg/sub"), "@scope/pkg");
        assert_eq!(package_name("javascript", "lodash/fp"), "lodash");
    }

    #[test]
    fn group_keeps_third_party_by_language_and_drops_the_rest() {
        let roots = vec!["github.com/yahn/unslop".to_string()];
        let go_writer: Vec<String> = ["fmt", "os", "github.com/yahn/unslop/internal/format"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let go_cmd: Vec<String> = ["github.com/spf13/cobra", "github.com/yahn/unslop/internal/ui"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let rs: Vec<String> = ["std::fmt", "serde::Deserialize", "tokio::spawn"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let files: Vec<(&str, &[String])> = vec![
            ("go", go_writer.as_slice()),
            ("go", go_cmd.as_slice()),
            ("rust", rs.as_slice()),
        ];
        let out = group_third_party(files, &roots);
        assert_eq!(out.get("go").unwrap(), &vec!["github.com/spf13/cobra".to_string()]);
        assert_eq!(
            out.get("rust").unwrap(),
            &vec!["serde".to_string(), "tokio".to_string()]
        );
    }

    #[test]
    fn first_party_roots_parse_go_module_and_cargo_name() {
        let go = "module github.com/yahn/unslop\n\ngo 1.22\n";
        let cargo = "[package]\nname = \"my-app\"\nversion = \"0.1.0\"\n\n[dependencies]\nserde = \"1\"\n";
        let roots = first_party_roots(Some(go), Some(cargo));
        assert!(roots.contains(&"github.com/yahn/unslop".to_string()));
        assert!(roots.contains(&"my_app".to_string()));
    }
}
