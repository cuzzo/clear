//! Revision-pinned, render-independent change inventory for the diff UI.

use crate::extract::{BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, UnitKind};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

pub const DIFF_API_VERSION: &str = "v1";
pub const DIFF_POLICY_VERSION: &str = "diff-risk/v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionFile {
    pub path: String,
    pub contents: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffScope {
    pub base_oid: String,
    pub head_oid: String,
    pub policy_version: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffPlan {
    pub scope: DiffScope,
    pub inventory: ChangeInventory,
    pub dependency_changes: Vec<DependencyChange>,
    pub language_summaries: Vec<LanguageSummary>,
    pub files: Vec<DiffFile>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ChangeInventory {
    pub changed_directories: usize,
    pub changed_files: usize,
    pub added_files: usize,
    pub modified_files: usize,
    pub deleted_files: usize,
    pub renamed_files: usize,
    pub by_role: BTreeMap<String, usize>,
    pub configuration_paths: Vec<ConfigFile>,
    pub documentation_paths: Vec<String>,
    pub generated_paths: Vec<String>,
    pub lockfile_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConfigFile {
    pub path: String,
    pub kind: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceRole {
    Production,
    Test,
    Documentation,
    Configuration,
    Generated,
    Lockfile,
    Other,
}

impl SourceRole {
    fn key(self) -> String {
        match self {
            Self::Production => "production",
            Self::Test => "test",
            Self::Documentation => "documentation",
            Self::Configuration => "configuration",
            Self::Generated => "generated",
            Self::Lockfile => "lockfile",
            Self::Other => "other",
        }
        .to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffFile {
    pub path: String,
    pub previous_path: Option<String>,
    pub change: FileChangeKind,
    pub role: SourceRole,
    pub language: Option<String>,
    pub base_source: Option<String>,
    pub head_source: Option<String>,
    pub added_lines: AddedLines,
    pub groups: Vec<DiffGroup>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct AddedLines {
    pub code: usize,
    pub comments: usize,
    pub other: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LanguageSummary {
    pub language: String,
    pub production: AddedLines,
    pub test: AddedLines,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffGroup {
    pub name: String,
    pub kind: String,
    pub start_line: u32,
    pub end_line: u32,
    pub visibility: Visibility,
    pub added_lines: AddedLines,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Visibility {
    Public,
    Private,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DependencyChange {
    pub manifest_path: String,
    pub status: DependencyStatus,
    pub entries: Vec<DependencyEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyStatus {
    Exact,
    UnknownPackageFile,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DependencyEntry {
    pub name: String,
    pub scope: String,
    pub before: Option<String>,
    pub after: Option<String>,
}

/// Builds a stable plan from immutable revision snapshots. Callers must resolve
/// symbolic revisions before invoking this function.
pub fn build_diff_plan(
    base_oid: impl Into<String>,
    head_oid: impl Into<String>,
    base_files: Vec<RevisionFile>,
    head_files: Vec<RevisionFile>,
) -> DiffPlan {
    let base = file_map(base_files);
    let head = file_map(head_files);
    let renamed = renamed_paths(&base, &head);
    let mut files = Vec::new();

    let paths = base
        .keys()
        .chain(head.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    for path in paths {
        let base_file = base.get(&path);
        let head_file = head.get(&path);
        if base_file == head_file {
            continue;
        }

        let previous_path = renamed
            .iter()
            .find_map(|(old, new)| (new == &path).then(|| old.clone()));
        if head_file.is_none() && renamed.contains_key(&path) {
            continue;
        }
        let change = match (base_file, head_file, previous_path.as_ref()) {
            (None, Some(_), Some(_)) => FileChangeKind::Renamed,
            (None, Some(_), None) => FileChangeKind::Added,
            (Some(_), None, _) => FileChangeKind::Deleted,
            (Some(_), Some(_), _) => FileChangeKind::Modified,
            (None, None, _) => unreachable!("paths come from one snapshot"),
        };
        let display_path = path.as_str();
        let role = source_role(display_path);
        let base_source = base_file.and_then(|file| file.contents.clone());
        let head_source = head_file.and_then(|file| file.contents.clone());
        let added_line_numbers = added_line_numbers(base_source.as_deref(), head_source.as_deref());
        let added_lines = summarize_added_lines(head_source.as_deref(), &added_line_numbers, display_path);
        let groups = semantic_groups(display_path, head_source.as_deref(), &added_line_numbers);
        files.push(DiffFile {
            path: display_path.to_string(),
            previous_path,
            change,
            role,
            language: language_for_path(display_path),
            base_source,
            head_source,
            added_lines,
            groups,
        });
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    let inventory = build_inventory(&files);
    let dependency_changes = dependency_changes(&files);
    let language_summaries = language_summaries(&files);

    DiffPlan {
        scope: DiffScope {
            base_oid: base_oid.into(),
            head_oid: head_oid.into(),
            policy_version: DIFF_POLICY_VERSION,
        },
        inventory,
        dependency_changes,
        language_summaries,
        files,
    }
}

fn language_summaries(files: &[DiffFile]) -> Vec<LanguageSummary> {
    let mut summaries = BTreeMap::<String, LanguageSummary>::new();
    for file in files {
        let Some(language) = &file.language else { continue };
        let summary = summaries.entry(language.clone()).or_insert_with(|| LanguageSummary {
            language: language.clone(),
            production: AddedLines::default(),
            test: AddedLines::default(),
        });
        match file.role {
            SourceRole::Production => add_lines(&mut summary.production, &file.added_lines),
            SourceRole::Test => add_lines(&mut summary.test, &file.added_lines),
            _ => {}
        }
    }
    summaries.into_values().collect()
}

fn add_lines(target: &mut AddedLines, source: &AddedLines) {
    target.code += source.code;
    target.comments += source.comments;
    target.other += source.other;
}

fn added_line_numbers(base: Option<&str>, head: Option<&str>) -> BTreeSet<u32> {
    let mut remaining = BTreeMap::<&str, usize>::new();
    for line in base.unwrap_or_default().lines() {
        *remaining.entry(line).or_default() += 1;
    }
    head.unwrap_or_default()
        .lines()
        .enumerate()
        .filter_map(|(index, line)| match remaining.get_mut(line) {
            Some(count) if *count > 0 => { *count -= 1; None }
            _ => Some(index as u32 + 1),
        })
        .collect()
}

fn summarize_added_lines(source: Option<&str>, added: &BTreeSet<u32>, path: &str) -> AddedLines {
    let mut summary = AddedLines::default();
    for (index, line) in source.unwrap_or_default().lines().enumerate() {
        if !added.contains(&(index as u32 + 1)) { continue; }
        match line_kind(line, path) {
            LineKind::Code => summary.code += 1,
            LineKind::Comment => summary.comments += 1,
            LineKind::Other => summary.other += 1,
        }
    }
    summary
}

fn semantic_groups(path: &str, source: Option<&str>, added: &BTreeSet<u32>) -> Vec<DiffGroup> {
    let Some(source) = source else { return Vec::new() };
    let extractor = HeuristicExtractor::default();
    let file = BlobFile { path: path.to_string(), contents: source.to_string() };
    extractor.extract_units(&file).into_iter().map(|unit| DiffGroup {
        name: unit.name,
        kind: unit.kind.as_str().to_string(),
        start_line: unit.start_line,
        end_line: unit.end_line,
        visibility: visibility_for(&unit.signature, unit.kind),
        added_lines: summarize_group_lines(source, added, path, unit.start_line, unit.end_line),
    }).collect()
}

fn summarize_group_lines(source: &str, added: &BTreeSet<u32>, path: &str, start: u32, end: u32) -> AddedLines {
    let lines = added.iter().copied().filter(|line| *line >= start && *line <= end).collect();
    summarize_added_lines(Some(source), &lines, path)
}

fn visibility_for(signature: &str, kind: UnitKind) -> Visibility {
    if kind != UnitKind::Function { return Visibility::Unknown; }
    if signature.contains("private") { Visibility::Private }
    else if signature.contains("public") || signature.contains("pub ") || signature.starts_with("def ") { Visibility::Public }
    else { Visibility::Unknown }
}

enum LineKind { Code, Comment, Other }

fn line_kind(line: &str, path: &str) -> LineKind {
    let line = line.trim();
    if line.is_empty() || line == "end" || matches!(line, "{" | "}" | "};" | "{}") { return LineKind::Other; }
    if line.starts_with('#') || line.starts_with("//") || line.starts_with("/*") || line.starts_with('*') || line.starts_with("<!--") { return LineKind::Comment; }
    if path.ends_with(".rb") && line == "=begin" { return LineKind::Comment; }
    LineKind::Code
}

fn file_map(files: Vec<RevisionFile>) -> BTreeMap<String, RevisionFile> {
    files
        .into_iter()
        .map(|file| (file.path.clone(), file))
        .collect()
}

fn renamed_paths(
    base: &BTreeMap<String, RevisionFile>,
    head: &BTreeMap<String, RevisionFile>,
) -> BTreeMap<String, String> {
    let mut renamed = BTreeMap::new();
    for (old_path, old_file) in base {
        if head.contains_key(old_path) {
            continue;
        }
        if let Some((new_path, _)) = head.iter().find(|(new_path, new_file)| {
            !base.contains_key(*new_path) && new_file.contents == old_file.contents
        }) {
            renamed.insert(old_path.clone(), (*new_path).clone());
        }
    }
    renamed
}

fn build_inventory(files: &[DiffFile]) -> ChangeInventory {
    let mut inventory = ChangeInventory::default();
    let mut directories = BTreeSet::new();
    for file in files {
        inventory.changed_files += 1;
        *inventory.by_role.entry(file.role.key()).or_default() += 1;
        if let Some(directory) = file.path.rsplit_once('/').map(|(directory, _)| directory) {
            directories.insert(directory.to_string());
        }
        match file.change {
            FileChangeKind::Added => inventory.added_files += 1,
            FileChangeKind::Modified => inventory.modified_files += 1,
            FileChangeKind::Deleted => inventory.deleted_files += 1,
            FileChangeKind::Renamed => inventory.renamed_files += 1,
        }
        match file.role {
            SourceRole::Configuration => inventory.configuration_paths.push(ConfigFile {
                path: file.path.clone(),
                kind: config_kind(&file.path)
                    .unwrap_or("configuration")
                    .to_string(),
            }),
            SourceRole::Documentation => inventory.documentation_paths.push(file.path.clone()),
            SourceRole::Generated => inventory.generated_paths.push(file.path.clone()),
            SourceRole::Lockfile => inventory.lockfile_paths.push(file.path.clone()),
            _ => {}
        }
    }
    inventory.changed_directories = directories.len();
    inventory
}

fn dependency_changes(files: &[DiffFile]) -> Vec<DependencyChange> {
    files
        .iter()
        .filter_map(|file| dependency_change(file))
        .collect()
}

fn dependency_change(file: &DiffFile) -> Option<DependencyChange> {
    match file.path.as_str() {
        "package.json" | _ if file.path.ends_with("/package.json") => {
            Some(package_json_dependencies(file))
        }
        path if is_manifest_path(path) => Some(DependencyChange {
            manifest_path: file.path.clone(),
            status: DependencyStatus::UnknownPackageFile,
            entries: Vec::new(),
        }),
        _ => None,
    }
}

fn package_json_dependencies(file: &DiffFile) -> DependencyChange {
    let before = file
        .base_source
        .as_deref()
        .map(parse_package_json)
        .transpose();
    let after = file
        .head_source
        .as_deref()
        .map(parse_package_json)
        .transpose();
    let (Ok(before), Ok(after)) = (before, after) else {
        return DependencyChange {
            manifest_path: file.path.clone(),
            status: DependencyStatus::UnknownPackageFile,
            entries: Vec::new(),
        };
    };
    let before = before.unwrap_or_default();
    let after = after.unwrap_or_default();
    let names = before
        .keys()
        .chain(after.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    let entries = names
        .into_iter()
        .filter_map(|key| {
            let before_entry = before.get(&key);
            let after_entry = after.get(&key);
            (before_entry != after_entry).then(|| DependencyEntry {
                name: key.1,
                scope: key.0,
                before: before_entry.cloned(),
                after: after_entry.cloned(),
            })
        })
        .collect();
    DependencyChange {
        manifest_path: file.path.clone(),
        status: DependencyStatus::Exact,
        entries,
    }
}

fn parse_package_json(contents: &str) -> Result<BTreeMap<(String, String), String>, ()> {
    let value: serde_json::Value = serde_json::from_str(contents).map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    let mut dependencies = BTreeMap::new();
    for scope in [
        "dependencies",
        "devDependencies",
        "optionalDependencies",
        "peerDependencies",
    ] {
        if let Some(values) = object.get(scope).and_then(serde_json::Value::as_object) {
            for (name, version) in values {
                let version = version.as_str().ok_or(())?;
                dependencies.insert((scope.to_string(), name.clone()), version.to_string());
            }
        }
    }
    Ok(dependencies)
}

fn source_role(path: &str) -> SourceRole {
    if is_lockfile(path) {
        SourceRole::Lockfile
    } else if is_generated(path) {
        SourceRole::Generated
    } else if path.ends_with(".md") {
        SourceRole::Documentation
    } else if config_kind(path).is_some() {
        SourceRole::Configuration
    } else if is_test_path(path) {
        SourceRole::Test
    } else if language_for_path(path).is_some() {
        SourceRole::Production
    } else {
        SourceRole::Other
    }
}

fn is_test_path(path: &str) -> bool {
    path.contains("/test/")
        || path.contains("/spec/")
        || path.starts_with("test/")
        || path.starts_with("spec/")
        || path.ends_with("_test.rb")
        || path.ends_with("_spec.rb")
        || path.ends_with("_test.go")
        || path.ends_with(".test.ts")
        || path.ends_with(".test.tsx")
        || path.ends_with(".spec.ts")
        || path.ends_with(".spec.tsx")
}

fn is_generated(path: &str) -> bool {
    path.contains("/generated/")
        || path.starts_with("generated/")
        || path.contains("/target/")
        || path.starts_with("target/")
        || path.ends_with(".min.js")
        || path.ends_with(".generated.ts")
}

fn is_lockfile(path: &str) -> bool {
    matches!(
        path.rsplit('/').next().unwrap_or(path),
        "Gemfile.lock"
            | "Cargo.lock"
            | "package-lock.json"
            | "pnpm-lock.yaml"
            | "yarn.lock"
            | "bun.lockb"
            | "poetry.lock"
            | "uv.lock"
            | "Pipfile.lock"
            | "go.sum"
            | "composer.lock"
            | "Package.resolved"
    )
}

fn config_kind(path: &str) -> Option<&'static str> {
    let file = path.rsplit('/').next().unwrap_or(path);
    if path.starts_with(".github/workflows/") && (file.ends_with(".yml") || file.ends_with(".yaml"))
    {
        return Some("github_workflow");
    }
    match file {
        ".gitignore" | ".gitattributes" | ".editorconfig" | ".rspec" | ".ruby-version" => {
            Some("repository")
        }
        "Gemfile" | "Rakefile" | "*.gemspec" => Some("ruby_manifest"),
        "Cargo.toml" | "rust-toolchain" | "rust-toolchain.toml" => Some("rust_manifest"),
        "package.json" | "tsconfig.json" | "vite.config.ts" | "eslint.config.js" => {
            Some("javascript_manifest")
        }
        "pyproject.toml" | "requirements.txt" | "setup.py" | "setup.cfg" | "Pipfile"
        | "tox.ini" | "noxfile.py" => Some("python_manifest"),
        "go.mod" | ".golangci.yml" | "Makefile" => Some("go_manifest"),
        "build.zig" | "build.zig.zon" => Some("zig_manifest"),
        "CMakeLists.txt" | "meson.build" | "vcpkg.json" | "conanfile.txt" | "conanfile.py" => {
            Some("native_build")
        }
        "pom.xml"
        | "build.gradle"
        | "build.gradle.kts"
        | "settings.gradle"
        | "settings.gradle.kts"
        | "libs.versions.toml" => Some("jvm_manifest"),
        "Package.swift" => Some("swift_manifest"),
        "composer.json" => Some("php_manifest"),
        _ if file.ends_with(".gemspec") => Some("ruby_manifest"),
        _ if file.ends_with(".csproj") || file.ends_with(".fsproj") || file.ends_with(".sln") => {
            Some("dotnet_manifest")
        }
        _ if file.ends_with(".rockspec") => Some("lua_manifest"),
        _ => None,
    }
}

fn is_manifest_path(path: &str) -> bool {
    config_kind(path).is_some()
        && !matches!(
            config_kind(path),
            Some("repository") | Some("github_workflow")
        )
}

fn language_for_path(path: &str) -> Option<String> {
    let extension = path.rsplit('.').next()?.to_ascii_lowercase();
    let language = match extension.as_str() {
        "c" | "h" => "c",
        "cc" | "cpp" | "cxx" | "hpp" => "cpp",
        "cs" => "csharp",
        "go" => "go",
        "java" => "java",
        "js" | "jsx" => "javascript",
        "kt" | "kts" => "kotlin",
        "lua" => "lua",
        "php" => "php",
        "py" => "python",
        "rb" => "ruby",
        "rs" => "rust",
        "swift" => "swift",
        "ts" | "tsx" => "typescript",
        "zig" => "zig",
        _ => return None,
    };
    Some(language.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, contents: &str) -> RevisionFile {
        RevisionFile {
            path: path.to_string(),
            contents: Some(contents.to_string()),
        }
    }

    fn binary(path: &str) -> RevisionFile {
        RevisionFile {
            path: path.to_string(),
            contents: None,
        }
    }

    #[test]
    fn builds_a_revision_pinned_inventory_with_source_roles() {
        let plan = build_diff_plan(
            "a".repeat(40),
            "b".repeat(40),
            vec![
                file("lib/old.rb", "def old; end\n"),
                file("Gemfile", "source\n"),
            ],
            vec![
                file("lib/new.rb", "def old; end\n"),
                file("generated/client.generated.ts", "export {}\n"),
                file("test/new_test.rb", "assert true\n"),
                file("docs/readme.md", "# docs\n"),
                file(".github/workflows/ci.yml", "name: CI\n"),
                file("Cargo.lock", "lock\n"),
                binary("assets/chart.png"),
            ],
        );

        assert_eq!(plan.scope.base_oid, "a".repeat(40));
        assert_eq!(plan.scope.head_oid, "b".repeat(40));
        assert_eq!(plan.scope.policy_version, DIFF_POLICY_VERSION);
        assert_eq!(plan.inventory.changed_files, 8);
        assert_eq!(plan.inventory.renamed_files, 1);
        assert_eq!(plan.inventory.deleted_files, 1);
        assert_eq!(plan.inventory.documentation_paths, vec!["docs/readme.md"]);
        assert_eq!(plan.inventory.lockfile_paths, vec!["Cargo.lock"]);
        assert_eq!(
            plan.inventory.generated_paths,
            vec!["generated/client.generated.ts"]
        );
        assert!(plan
            .inventory
            .configuration_paths
            .iter()
            .any(|config| config.kind == "ruby_manifest"));
        assert!(plan
            .inventory
            .configuration_paths
            .iter()
            .any(|config| config.kind == "github_workflow"));
        assert_eq!(
            plan.files
                .iter()
                .find(|file| file.path == "lib/new.rb")
                .unwrap()
                .previous_path
                .as_deref(),
            Some("lib/old.rb")
        );
        assert_eq!(
            plan.files
                .iter()
                .find(|file| file.path == "assets/chart.png")
                .unwrap()
                .role,
            SourceRole::Other
        );
    }

    #[test]
    fn reports_package_json_dependency_changes_exactly() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file(
                "web/package.json",
                r#"{"dependencies":{"react":"18"},"devDependencies":{"vite":"5"}}"#,
            )],
            vec![file(
                "web/package.json",
                r#"{"dependencies":{"react":"19","zod":"4"},"devDependencies":{}}"#,
            )],
        );

        assert_eq!(plan.dependency_changes.len(), 1);
        let change = &plan.dependency_changes[0];
        assert_eq!(change.status, DependencyStatus::Exact);
        assert_eq!(change.entries.len(), 3);
        assert!(change.entries.iter().any(|entry| entry.name == "react"
            && entry.before.as_deref() == Some("18")
            && entry.after.as_deref() == Some("19")));
        assert!(change
            .entries
            .iter()
            .any(|entry| entry.name == "vite" && entry.after.is_none()));
        assert!(change
            .entries
            .iter()
            .any(|entry| entry.name == "zod" && entry.before.is_none()));
    }

    #[test]
    fn reports_dynamic_or_invalid_manifests_as_unknown_package_file_changes() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("Gemfile", "gem 'old'\n"),
                file("package.json", "not json"),
            ],
            vec![
                file("Gemfile", "gem name_from_env\n"),
                file("package.json", "still not json"),
            ],
        );

        assert_eq!(plan.dependency_changes.len(), 2);
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.status == DependencyStatus::UnknownPackageFile));
        assert!(plan
            .dependency_changes
            .iter()
            .all(|change| change.entries.is_empty()));
    }

    #[test]
    fn excludes_unchanged_files_and_invalid_exact_dependency_values() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![
                file("same.rb", "unchanged\n"),
                file("package.json", r#"{"dependencies":{"bad":3}}"#),
            ],
            vec![
                file("same.rb", "unchanged\n"),
                file("package.json", r#"{"dependencies":{"bad":"3"}}"#),
            ],
        );

        assert_eq!(plan.files.len(), 1);
        assert_eq!(
            plan.dependency_changes[0].status,
            DependencyStatus::UnknownPackageFile
        );
    }

    #[test]
    fn summarizes_meaningful_added_lines_and_symbol_groups() {
        let plan = build_diff_plan(
            "base",
            "head",
            vec![file("lib/app.rb", "def run\nend\n")],
            vec![file(
                "lib/app.rb",
                "# prepares output\ndef run\n  work\nend\n",
            )],
        );

        let changed = &plan.files[0];
        assert_eq!(
            changed.added_lines,
            AddedLines {
                code: 1,
                comments: 1,
                other: 0
            }
        );
        assert_eq!(changed.groups.len(), 1);
        assert_eq!(changed.groups[0].kind, "function");
        assert_eq!(changed.groups[0].visibility, Visibility::Public);
        assert_eq!(changed.groups[0].added_lines.code, 1);
        assert_eq!(plan.language_summaries[0].language, "ruby");
        assert_eq!(plan.language_summaries[0].production.comments, 1);
    }

    #[test]
    fn excludes_closure_only_lines_across_brace_languages() {
        for (path, line) in [("main.zig", "}"), ("main.go", "}"), ("main.rs", "};")] {
            assert!(matches!(line_kind(line, path), LineKind::Other));
        }
        assert!(matches!(line_kind("// intent", "main.go"), LineKind::Comment));
        assert!(matches!(line_kind("return value", "main.go"), LineKind::Code));
    }

    #[test]
    fn recognizes_catalog_entries_and_raw_file_fallbacks() {
        assert_eq!(source_role("src/main.zig"), SourceRole::Production);
        assert_eq!(source_role("spec/model_spec.rb"), SourceRole::Test);
        assert_eq!(source_role("generated/api.ts"), SourceRole::Generated);
        assert_eq!(source_role("README.md"), SourceRole::Documentation);
        assert_eq!(source_role(".gitignore"), SourceRole::Configuration);
        assert_eq!(source_role("go.sum"), SourceRole::Lockfile);
        assert_eq!(source_role("image.avif"), SourceRole::Other);
        assert_eq!(config_kind("Library.gemspec"), Some("ruby_manifest"));
        assert_eq!(config_kind("src/app.rs"), None);
    }
}
