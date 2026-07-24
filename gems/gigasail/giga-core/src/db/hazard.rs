use crate::extract::{BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, HazardEvent, LogicalUnit, UnitKind};
use crate::storage::Storage;
use anyhow::{Context, Result};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use streaming_iterator::StreamingIterator;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HazardIngestStats {
    pub scanned_files: usize,
    pub hazards: usize,
    pub events: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HazardSite {
    pub path: String,
    pub line: u32,
    pub source: String,
    pub hazard_type: String,
    pub required_evidence: String,
}

pub fn ingest_hazards(
    storage: &Storage,
    repo: impl AsRef<Path>,
    provider: &str,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    match provider {
        "zig" => ingest_zig_hazards(storage, repo.as_ref(), commit, timestamp),
        "go" => ingest_go_hazards(storage, repo.as_ref(), commit, timestamp),
        "rust" => ingest_rust_hazards(storage, repo.as_ref(), commit, timestamp),
        "c" => ingest_c_hazards(storage, repo.as_ref(), commit, timestamp),
        "cpp" => ingest_cpp_hazards(storage, repo.as_ref(), commit, timestamp),
        "csharp" => ingest_csharp_hazards(storage, repo.as_ref(), commit, timestamp),
        "ruby" | "python" | "javascript" | "typescript" | "java" | "kotlin" | "swift" | "lua"
        | "php" => {
            storage.deactivate_active_hazards(provider)?;
            Ok(HazardIngestStats {
                scanned_files: 0,
                hazards: 0,
                events: 0,
            })
        }
        other => anyhow::bail!("unsupported hazard provider {other:?}"),
    }
}

fn ingest_zig_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "zig",
        zig_source_files,
        scan_zig_sites,
    )
}

fn ingest_go_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "go",
        go_source_files,
        scan_go_sites,
    )
}

fn ingest_rust_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "rust",
        rust_source_files,
        scan_rust_sites,
    )
}

fn ingest_c_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "c",
        c_source_files,
        scan_c_sites,
    )
}

fn ingest_cpp_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "cpp",
        cpp_source_files,
        scan_cpp_sites,
    )
}

fn ingest_csharp_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(
        storage,
        repo,
        commit,
        timestamp,
        "csharp",
        csharp_source_files,
        scan_csharp_sites,
    )
}

fn ingest_language_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
    language: &str,
    source_files: fn(&Path) -> Result<Vec<String>>,
    scan_sites: fn(&str, &str) -> Vec<HazardSite>,
) -> Result<HazardIngestStats> {
    let repo = repo
        .canonicalize()
        .with_context(|| format!("failed to resolve repo {}", repo.display()))?;
    let timestamp = timestamp
        .or_else(|| storage.commit_timestamp(commit).ok().flatten())
        .unwrap_or_else(now_timestamp);
    let files = source_files(&repo)?;
    let extractor = HeuristicExtractor::default();
    let mut stats = HazardIngestStats {
        scanned_files: files.len(),
        hazards: 0,
        events: 0,
    };

    storage.begin_transaction()?;
    storage.deactivate_active_hazards(language)?;
    for path in files {
        let abs = repo.join(&path);
        let contents = fs::read_to_string(&abs)
            .with_context(|| format!("failed to read {}", abs.display()))?;
        let blob = BlobFile {
            path: path.clone(),
            contents: contents.clone(),
        };
        let units = extractor.extract_units(&blob);
        for site in scan_sites(&path, &contents) {
            stats.hazards += 1;
            let unit = unit_for_site(&blob, &units, site.line);
            let resolved_id = storage
                .resolve_unit_id(&unit.id, &unit.path, &unit.name)?
                .unwrap_or_else(|| unit.id.clone());
            if resolved_id == unit.id {
                storage.upsert_logical_unit(&unit, timestamp)?;
            }
            storage.insert_hazard_event(&HazardEvent {
                unit_id: resolved_id,
                language: language.into(),
                hazard_type: site.hazard_type.clone(),
                required_evidence: site.required_evidence.clone(),
                path: site.path.clone(),
                line: site.line,
                symbol: Some(unit.name.clone()),
                source: site.source.clone(),
                detected_at_hash: commit.to_string(),
                is_active: true,
                payload_json: json!({
                    "provider": language,
                    "source": site.source,
                    "timestamp": timestamp
                })
                .to_string(),
            })?;
            stats.events += 1;
        }
    }
    storage.commit_transaction()?;
    Ok(stats)
}

fn zig_source_files(repo: &Path) -> Result<Vec<String>> {
    let mut files = Vec::new();
    for prefix in ["zig/runtime", "zig/lib"] {
        collect_zig_files(repo, Path::new(prefix), &mut files)?;
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn go_source_files(repo: &Path) -> Result<Vec<String>> {
    let mut files = Vec::new();
    collect_go_files(repo, Path::new(""), &mut files)?;
    files.sort();
    files.dedup();
    Ok(files)
}

fn rust_source_files(repo: &Path) -> Result<Vec<String>> {
    collect_language_files(repo, rust_source_path)
}

fn c_source_files(repo: &Path) -> Result<Vec<String>> {
    collect_language_files(repo, c_source_path)
}

fn cpp_source_files(repo: &Path) -> Result<Vec<String>> {
    collect_language_files(repo, cpp_source_path)
}

fn csharp_source_files(repo: &Path) -> Result<Vec<String>> {
    collect_language_files(repo, csharp_source_path)
}

fn collect_language_files(repo: &Path, source_path: fn(&str) -> bool) -> Result<Vec<String>> {
    let mut files = Vec::new();
    collect_matching_files(repo, Path::new(""), &mut files, source_path)?;
    files.sort();
    files.dedup();
    Ok(files)
}

fn collect_matching_files(
    repo: &Path,
    rel_dir: &Path,
    out: &mut Vec<String>,
    source_path: fn(&str) -> bool,
) -> Result<()> {
    let abs = repo.join(rel_dir);
    if !abs.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(&abs)? {
        let entry = entry?;
        let path = entry.path();
        let rel = rel_path(repo, &path)?;
        if path.is_dir() {
            if !excluded_common_dir(&rel) {
                collect_matching_files(repo, Path::new(&rel), out, source_path)?;
            }
        } else if source_path(&rel) {
            out.push(rel);
        }
    }
    Ok(())
}

fn collect_go_files(repo: &Path, rel_dir: &Path, out: &mut Vec<String>) -> Result<()> {
    let abs = repo.join(rel_dir);
    if !abs.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(&abs)? {
        let entry = entry?;
        let path = entry.path();
        let rel = rel_path(repo, &path)?;
        if path.is_dir() {
            if !excluded_go_dir(&rel) {
                collect_go_files(repo, Path::new(&rel), out)?;
            }
        } else if rel.ends_with(".go") && !excluded_go_file(&rel) {
            out.push(rel);
        }
    }
    Ok(())
}

fn collect_zig_files(repo: &Path, rel_dir: &Path, out: &mut Vec<String>) -> Result<()> {
    let abs = repo.join(rel_dir);
    if !abs.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(&abs)? {
        let entry = entry?;
        let path = entry.path();
        let rel = rel_path(repo, &path)?;
        if path.is_dir() {
            collect_zig_files(repo, Path::new(&rel), out)?;
        } else if rel.ends_with(".zig") && !excluded_zig_file(&rel) {
            out.push(rel);
        }
    }
    Ok(())
}

fn excluded_go_dir(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    matches!(
        name,
        ".git" | "vendor" | "testdata" | "node_modules" | "tmp" | "dist"
    ) || name.starts_with('.')
}

fn excluded_common_dir(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    matches!(
        name,
        ".git"
            | "vendor"
            | "third_party"
            | "node_modules"
            | "tmp"
            | "dist"
            | "build"
            | "target"
            | "bin"
            | "obj"
            | "packages"
            | "cmake-build-debug"
            | "cmake-build-release"
            | "tests"
            | "test"
            | "benches"
            | "examples"
    ) || name.starts_with('.')
}

fn excluded_go_file(path: &str) -> bool {
    let Some(name) = path.rsplit('/').next() else {
        return true;
    };
    name.ends_with("_test.go")
}

fn rust_source_path(path: &str) -> bool {
    path.ends_with(".rs")
}

fn c_source_path(path: &str) -> bool {
    path.ends_with(".c") || path.ends_with(".h")
}

fn cpp_source_path(path: &str) -> bool {
    [".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"]
        .iter()
        .any(|suffix| path.ends_with(suffix))
}

fn csharp_source_path(path: &str) -> bool {
    path.ends_with(".cs")
}

fn excluded_zig_file(path: &str) -> bool {
    let Some(name) = path.rsplit('/').next() else {
        return true;
    };
    name.ends_with("-test.zig")
        || name.ends_with("-vopr.zig")
        || name.ends_with("-loom.zig")
        || name.ends_with("-bench.zig")
        || name.starts_with("vopr-")
        || name.starts_with("loom-")
        || matches!(
            name,
            "all-tests.zig" | "all-fuzz.zig" | "size_check.zig" | "runtime-header.zig"
        )
}

// Both scanners consume the same contract resolver. The old Gigasail copy
// classified hazard names independently and could turn `unsafe_block` into a
// race because it contains the substring "lock".
const GO_HAZARDS: &str = hazard_contract::GO_HAZARDS;
const RUST_HAZARDS: &str = hazard_contract::RUST_HAZARDS;
const ZIG_HAZARDS: &str = hazard_contract::ZIG_HAZARDS;
const C_HAZARDS: &str = hazard_contract::C_HAZARDS;
const CPP_HAZARDS: &str = hazard_contract::CPP_HAZARDS;

fn hazard_policy(hazard_type: &str) -> Option<&'static hazard_contract::HazardPolicy> {
    hazard_contract::resolve_hazard_policy(hazard_type)
}

fn go_reflect_import_aliases(
    root: tree_sitter::Node,
    source: &[u8],
) -> std::collections::HashSet<String> {
    fn visit(
        node: tree_sitter::Node,
        source: &[u8],
        aliases: &mut std::collections::HashSet<String>,
    ) {
        if node.kind() == "import_spec"
            && node
                .child_by_field_name("path")
                .and_then(|path| path.utf8_text(source).ok())
                .is_some_and(|path| path.trim_matches('"') == "reflect")
        {
            let alias = node
                .child_by_field_name("name")
                .and_then(|name| name.utf8_text(source).ok())
                .unwrap_or("reflect");
            if alias != "_" && alias != "." {
                aliases.insert(alias.to_string());
            }
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            visit(child, source, aliases);
        }
    }

    let mut aliases = std::collections::HashSet::new();
    visit(root, source, &mut aliases);
    aliases
}

fn go_identifier_is_binding(node: tree_sitter::Node, source: &[u8], name: &str) -> bool {
    let text = node.utf8_text(source).unwrap_or("");
    let left_side = match node.kind() {
        "short_var_declaration" | "range_clause" => text.split(":=").next().unwrap_or(text),
        "var_declaration" | "const_declaration" => text
            .strip_prefix("var")
            .or_else(|| text.strip_prefix("const"))
            .unwrap_or(text)
            .split('=')
            .next()
            .unwrap_or(text),
        "type_declaration" => text.strip_prefix("type").unwrap_or(text),
        _ => return false,
    };
    left_side
        .split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
        .any(|word| word == name)
}

fn go_block_shadows_reflect(
    block: tree_sitter::Node,
    call: tree_sitter::Node,
    source: &[u8],
    alias: &str,
) -> bool {
    fn visit(
        node: tree_sitter::Node,
        call: tree_sitter::Node,
        source: &[u8],
        alias: &str,
        block: tree_sitter::Node,
    ) -> bool {
        if node.id() != block.id() && node.kind() == "block" {
            return false;
        }
        if node.id() != call.id()
            && node.start_byte() <= call.start_byte()
            && go_identifier_is_binding(node, source, alias)
        {
            return true;
        }
        let mut cursor = node.walk();
        let found = node
            .children(&mut cursor)
            .any(|child| visit(child, call, source, alias, block));
        found
    }

    visit(block, call, source, alias, block)
}

fn go_reflection_call_is_imported_and_unshadowed(
    call: tree_sitter::Node,
    source: &[u8],
    aliases: &std::collections::HashSet<String>,
) -> bool {
    let Some(function) = call.child_by_field_name("function") else {
        return false;
    };
    if function.kind() != "selector_expression" {
        return false;
    }
    let Some(package) = function.child_by_field_name("operand") else {
        return false;
    };
    let Ok(package_name) = package.utf8_text(source) else {
        return false;
    };
    if !aliases.contains(package_name) {
        return false;
    }

    let mut current = Some(call);
    while let Some(node) = current {
        if node.kind() == "block" && go_block_shadows_reflect(node, call, source, package_name) {
            return false;
        }
        if matches!(node.kind(), "function_declaration" | "method_declaration")
            && node
                .child_by_field_name("parameters")
                .and_then(|parameters| parameters.utf8_text(source).ok())
                .is_some_and(|text| {
                    text.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                        .any(|word| word == package_name)
                })
        {
            return false;
        }
        current = node.parent();
    }
    true
}

fn c_arithmetic_hazard_is_relevant(node: tree_sitter::Node, source: &[u8]) -> bool {
    let operator = node
        .child_by_field_name("operator")
        .and_then(|operator| operator.utf8_text(source).ok())
        .unwrap_or("");
    let rhs = node
        .child_by_field_name("right")
        .and_then(|right| right.utf8_text(source).ok())
        .unwrap_or("");
    hazard_contract::c_arithmetic_literal_is_relevant(operator, rhs)
}

fn query_hazards(
    path: &str,
    contents: &str,
    language: tree_sitter::Language,
    query_str: &str,
) -> Vec<HazardSite> {
    let mut parser = tree_sitter::Parser::new();
    if parser.set_language(&language).is_err() {
        return Vec::new();
    }
    let Some(tree) = parser.parse(contents, None) else {
        return Vec::new();
    };
    let query = match tree_sitter::Query::new(&language, query_str) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("QUERY ERROR for {}: {:?}", path, e);
            return Vec::new();
        }
    };

    let mut cursor = tree_sitter::QueryCursor::new();
    let mut sites = Vec::new();
    let mut matches = cursor.matches(&query, tree.root_node(), contents.as_bytes());

    while let Some(m) = matches.next() {
        for capture in m.captures {
            let capture_name = query.capture_names()[capture.index as usize];
            if let Some(hazard_type) = capture_name.strip_prefix("hazard.") {
                let start_line = (capture.node.start_position().row + 1) as u32;
                let line_text = contents
                    .lines()
                    .nth((start_line as usize).saturating_sub(1))
                    .unwrap_or("")
                    .trim()
                    .to_string();

                let policy = hazard_policy(hazard_type).unwrap_or_else(|| {
                    panic!("hazard query capture {hazard_type:?} has no contract policy")
                });

                if hazard_type == "go_reflection"
                    && !go_reflection_call_is_imported_and_unshadowed(
                        capture.node,
                        contents.as_bytes(),
                        &go_reflect_import_aliases(tree.root_node(), contents.as_bytes()),
                    )
                {
                    continue;
                }
                if matches!(hazard_type, "c_ubsan_arithmetic" | "cpp_ubsan_arithmetic")
                    && !c_arithmetic_hazard_is_relevant(capture.node, contents.as_bytes())
                {
                    continue;
                }
                sites.push(HazardSite {
                    path: path.to_string(),
                    line: start_line,
                    source: line_text,
                    hazard_type: hazard_type.to_string(),
                    required_evidence: policy.evidence_provider.clone(),
                });
            }
        }
    }
    let mut unique_sites = Vec::new();
    for site in sites {
        if !unique_sites
            .iter()
            .any(|s: &HazardSite| s.line == site.line && s.hazard_type == site.hazard_type)
        {
            unique_sites.push(site);
        }
    }
    unique_sites
}

pub fn scan_zig_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let sites = query_hazards(
        path,
        contents,
        tree_sitter_zig::LANGUAGE.into(),
        ZIG_HAZARDS,
    );

    let mut final_sites = Vec::new();
    let mut in_loom_exclude = false;
    let mut in_vopr_exclude = false;
    let mut retry_depth = 0usize;

    let mut line_states = Vec::new();
    for line in contents.lines() {
        if line.contains("LOOM-EXCLUDE-BEGIN") {
            in_loom_exclude = true;
        }
        if line.contains("LOOM-EXCLUDE-END") {
            in_loom_exclude = false;
        }
        if line.contains("VOPR-EXCLUDE-BEGIN") {
            in_vopr_exclude = true;
        }
        if line.contains("VOPR-EXCLUDE-END") {
            in_vopr_exclude = false;
        }

        let mut retry_triggered = false;
        let mut retry_ended = false;
        let mut vopr_retry_direct = false;
        if line.contains("VOPR-START-RETRY") {
            retry_depth += 1;
            retry_triggered = true;
        }
        if line.contains("VOPR-END-RETRY") {
            retry_depth = retry_depth.saturating_sub(1);
            retry_ended = true;
        }
        if line.contains("VOPR-RETRY") {
            vopr_retry_direct = true;
        }

        line_states.push((
            in_loom_exclude,
            in_vopr_exclude,
            retry_depth > 0,
            retry_triggered,
            retry_ended,
            vopr_retry_direct,
            line,
        ));
    }

    for site in sites {
        let idx = (site.line as usize).saturating_sub(1);
        if let Some(&(loom_ex, vopr_ex, _, _, _, _, _)) = line_states.get(idx) {
            if site.hazard_type == "zig_loom_atomic" && loom_ex {
                continue;
            }
            if site.hazard_type.starts_with("zig_vopr_") && vopr_ex {
                continue;
            }
            final_sites.push(site);
        }
    }

    for (idx, &(_loom_ex, vopr_ex, retry, start_retry, _, retry_direct, line)) in
        line_states.iter().enumerate()
    {
        let line_no = (idx + 1) as u32;
        if line.contains("HAMMER-WAIT-LOOP-BEGIN") {
            final_sites.push(site(path, line_no, line, "zig_wait_loop"));
        }
        if vopr_ex {
            continue;
        }
        if start_retry || retry_direct {
            final_sites.push(site(path, line_no, line, "zig_vopr_retry"));
        } else if retry && executable_zig_retry_line(line) && !line.contains("VOPR-") {
            let has_structural_vopr = final_sites
                .iter()
                .any(|s| s.line == line_no && s.hazard_type.starts_with("zig_vopr_"));
            if !has_structural_vopr {
                final_sites.push(site(path, line_no, line, "zig_vopr_retry_body"));
            }
        }
    }

    final_sites
}

fn executable_zig_retry_line(line: &str) -> bool {
    let code = line.split("//").next().unwrap_or("").trim();
    !code.is_empty()
        && !code.chars().all(|ch| matches!(ch, '{' | '}' | ';' | ','))
        && code != "} else {"
}

pub fn scan_go_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    query_hazards(path, contents, tree_sitter_go::LANGUAGE.into(), GO_HAZARDS)
}

pub fn scan_rust_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    query_hazards(
        path,
        contents,
        tree_sitter_rust::LANGUAGE.into(),
        RUST_HAZARDS,
    )
}

pub fn scan_c_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    query_hazards(path, contents, tree_sitter_c::LANGUAGE.into(), C_HAZARDS)
}

pub fn scan_cpp_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    query_hazards(
        path,
        contents,
        tree_sitter_cpp::LANGUAGE.into(),
        CPP_HAZARDS,
    )
}

// C# reflection flow is owned by FactMine. Gigasail keeps the same narrow site
// shape for storage/UI consumers, but does not replay a second type/alias
// analysis here.
pub fn scan_csharp_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    fact_mine_rust::syntax::hazards::extract_file_hazards(
        path,
        contents,
        fact_mine_rust::syntax::Language::CSharp,
    )
    .into_iter()
    .map(|fact| HazardSite {
        path: fact.path,
        line: fact.line,
        source: fact.snippet,
        hazard_type: fact.hazard_type,
        required_evidence: fact.required_evidence,
    })
    .collect()
}

fn site(path: &str, line: u32, source: &str, hazard_type: &str) -> HazardSite {
    let policy = hazard_policy(hazard_type)
        .unwrap_or_else(|| panic!("synthetic hazard {hazard_type:?} has no contract policy"));
    HazardSite {
        path: path.to_string(),
        line,
        source: source.trim().to_string(),
        hazard_type: hazard_type.to_string(),
        required_evidence: policy.evidence_provider.clone(),
    }
}

pub fn unit_for_site(blob: &BlobFile, units: &[LogicalUnit], line: u32) -> LogicalUnit {
    units
        .iter()
        .find(|unit| unit.start_line <= line && line <= unit.end_line)
        .cloned()
        .unwrap_or_else(|| {
            let end = blob.contents.lines().count().max(1) as u32;
            LogicalUnit::new(
                blob.path.clone(),
                UnitKind::Module,
                blob.path.clone(),
                1,
                1,
                end,
                blob.path.clone(),
                &blob.contents,
            )
        })
}

fn rel_path(repo: &Path, path: &Path) -> Result<String> {
    let rel: PathBuf = path.strip_prefix(repo)?.into();
    Ok(rel.to_string_lossy().replace('\\', "/"))
}

pub fn now_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::Storage;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn ingests_zig_hazards_for_current_snapshot() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("zig/runtime")).unwrap();
        fs::write(
            dir.path().join("zig/runtime/a.zig"),
            "fn run() void {\n    value.store(1, .release);\n    _ = std.time.milliTimestamp();\n}\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();

        let stats = ingest_hazards(&storage, dir.path(), "zig", "abc", Some(10)).unwrap();

        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 2);
        assert_eq!(storage.count_rows("unit_hazards").unwrap(), 2);
    }

    #[test]
    fn ingests_go_concurrency_hazards_for_current_snapshot() {
        let dir = tempdir().unwrap();
        fs::write(
            dir.path().join("worker.go"),
            "package demo\n\nimport \"sync/atomic\"\n\nfunc run(ch chan int) {\n    go func() { ch <- 1 }()\n    value := atomic.LoadInt64(&counter)\n    _ = value\n}\n",
        )
        .unwrap();
        fs::write(
            dir.path().join("worker_test.go"),
            "package demo\n\nfunc TestRun() { go run(nil) }\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();

        let stats = ingest_hazards(&storage, dir.path(), "go", "abc", Some(10)).unwrap();

        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 3);
        assert_eq!(storage.count_rows("unit_hazards").unwrap(), 3);
    }

    #[test]
    fn go_reflection_requires_the_reflect_import_alias_and_not_a_local_shadow() {
        let aliased = scan_go_sites(
            "worker.go",
            "package demo\nimport r \"reflect\"\nfunc run(value interface{}, name string) {\n  r.ValueOf(value).MethodByName(name).Call(nil)\n}",
        );
        assert!(aliased
            .iter()
            .any(|site| site.hazard_type == "go_reflection"));

        let shadowed = scan_go_sites(
            "worker.go",
            "package demo\nimport \"reflect\"\nfunc run(value interface{}, name string) {\n  reflect := fakeReflect{}\n  reflect.ValueOf(value).MethodByName(name).Call(nil)\n}",
        );
        assert!(!shadowed
            .iter()
            .any(|site| site.hazard_type == "go_reflection"));
    }

    #[test]
    fn ingests_rust_loom_and_unsafe_hazards_for_current_snapshot() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(
            dir.path().join("src/lib.rs"),
            "use std::sync::atomic::{AtomicUsize, Ordering};\n\npub fn run(ptr: *const u8) -> usize {\n    let value = AtomicUsize::new(0);\n    value.fetch_add(1, Ordering::SeqCst);\n    unsafe {\n        ptr.add(1).read()\n    }\n}\n",
        )
        .unwrap();
        let storage = Storage::open_memory().unwrap();

        let stats = ingest_hazards(&storage, dir.path(), "rust", "abc", Some(10)).unwrap();

        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 5);
        assert_eq!(storage.count_rows("unit_hazards").unwrap(), 5);
    }

    #[test]
    fn system_hazard_scans_cover_c_cpp_and_csharp_categories() {
        let c_types = hazard_types(scan_c_sites(
            "runtime.c",
            "void run(char *dst, char *src, int n) {\n    pthread_mutex_lock(&lock);\n    char *buf = malloc(32);\n    memcpy(dst, src, n);\n    int shifted = n << src[0];\n    free(buf);\n}\n",
        ));
        assert!(c_types.contains(&"c_tsan_concurrency".to_string()));
        assert!(c_types.contains(&"c_asan_raw_memory_api".to_string()));
        assert!(c_types.contains(&"c_lsan_lifetime".to_string()));
        assert!(c_types.contains(&"c_ubsan_arithmetic".to_string()));

        let cpp_types = hazard_types(scan_cpp_sites(
            "runtime.cpp",
            "void run(char *dst, char *src, int n) {\n    std::atomic<int> ready;\n    auto *buf = new char[32];\n    std::memcpy(dst, src, n);\n    auto raw = reinterpret_cast<int *>(dst);\n    auto shifted = n << raw[0];\n    delete[] buf;\n}\n",
        ));
        assert!(cpp_types.contains(&"cpp_tsan_concurrency".to_string()));
        assert!(cpp_types.contains(&"cpp_asan_raw_memory_api".to_string()));
        assert!(cpp_types.contains(&"cpp_asan_pointer_or_cast".to_string()));
        assert!(cpp_types.contains(&"cpp_lsan_lifetime".to_string()));
        assert!(cpp_types.contains(&"cpp_ubsan_cast".to_string()));
        assert!(cpp_types.contains(&"cpp_ubsan_arithmetic".to_string()));

        let csharp_types = hazard_types(scan_csharp_sites(
            "Worker.cs",
            "public unsafe class Worker {\n    public void Run(byte* ptr) {\n        Task.Run(() => {});\n        fixed (byte* p = buffer) {\n            *p = 1;\n        }\n    }\n}\n",
        ));
        assert!(csharp_types.contains(&"csharp_concurrency".to_string()));
        assert!(csharp_types.contains(&"csharp_unsafe_memory".to_string()));
    }

    #[test]
    fn gigasail_csharp_reflection_scan_uses_canonical_factmine_facts() {
        let source = r#"
            class Demo {
                void Run() {
                    Type target = typeof(Demo);
                    MethodInfo method = target.GetMethod("Run");
                    method.Invoke(null, null);
                    Assembly.Load("demo");
                }
            }
        "#;
        let gigasail_sites = scan_csharp_sites("Demo.cs", source);
        let reflection: Vec<_> = gigasail_sites
            .iter()
            .filter(|site| site.hazard_type == "csharp_metaprogramming")
            .collect();
        assert_eq!(reflection.len(), 3, "{reflection:?}");
        assert!(reflection
            .iter()
            .any(|site| site.source.contains("target.GetMethod")));
        assert!(reflection
            .iter()
            .any(|site| site.source.contains("method.Invoke")));
        assert!(reflection
            .iter()
            .any(|site| site.source.contains("Assembly.Load")));

        let shadowed = r#"
            class Type { public object GetMethod(string name) { return null; } }
            class Demo {
                void Run() {
                    Type target = new Type();
                    target.GetMethod("Run");
                }
            }
        "#;
        assert!(!scan_csharp_sites("Shadow.cs", shadowed)
            .iter()
            .any(|site| site.hazard_type == "csharp_metaprogramming"));
    }

    #[test]
    fn go_hazard_scan_ignores_comments() {
        let sites = scan_go_sites(
            "demo.go",
            "package demo\n\nfunc run() {\n    // go func() {}()\n    /* atomic.AddInt64(&x, 1) */\n    ch <- 1\n}\n",
        );

        assert_eq!(sites.len(), 1);
        assert_eq!(sites[0].hazard_type, "go_concurrency_channel");
    }

    #[test]
    fn systems_hazard_scans_ignore_comments_and_strings() {
        let sites = scan_c_sites(
            "runtime.c",
            "void run(void) {\n    // pthread_mutex_lock(&lock);\n    const char *s = \"memcpy(dst, src, n)\";\n}\n",
        );

        assert!(sites.is_empty());
    }

    #[test]
    fn test_unsupported_language_bail() {
        let dir = tempdir().unwrap();
        let storage = Storage::open_memory().unwrap();
        let stats = ingest_hazards(&storage, dir.path(), "unsupported_lang", "abc", Some(10));
        assert!(stats.is_err());
        assert!(stats
            .unwrap_err()
            .to_string()
            .contains("unsupported hazard provider"));
    }

    #[test]
    fn test_zig_scanners_loom_and_vopr_exclusions() {
        let zig_code = r#"
            // LOOM-EXCLUDE-BEGIN
            value.store(1, .release);
            // LOOM-EXCLUDE-END
            value.store(2, .release); // should be captured

            // VOPR-EXCLUDE-BEGIN
            _ = std.time.milliTimestamp();
            // VOPR-EXCLUDE-END
            _ = std.time.milliTimestamp(); // should be captured
            
            // VOPR-START-RETRY
            some_retry_call();
            // VOPR-END-RETRY
            
            // VOPR-RETRY
        "#;

        let sites = scan_zig_sites("test.zig", zig_code);
        let types = hazard_types(sites);

        assert_eq!(types.iter().filter(|t| *t == "zig_loom_atomic").count(), 1);
        assert_eq!(types.iter().filter(|t| *t == "zig_vopr_time").count(), 1);
        assert_eq!(types.iter().filter(|t| *t == "zig_vopr_retry").count(), 2);
        assert_eq!(
            types.iter().filter(|t| *t == "zig_vopr_retry_body").count(),
            1
        );
    }

    #[test]
    fn test_zig_nested_retry_and_hammer_hazards() {
        let zig_code = r#"
            // VOPR-START-RETRY
            outer_before();
            // VOPR-START-RETRY
            inner();
            // VOPR-END-RETRY
            outer_after();
            // VOPR-END-RETRY
            // HAMMER-WAIT-LOOP-BEGIN: tag=queue.wait
            while (blocked()) yield();
            // HAMMER-WAIT-LOOP-END: tag=queue.wait
            value.cmpxchgWeak(1, 2, .acq_rel, .acquire);
        "#;

        let sites = scan_zig_sites("test.zig", zig_code);
        assert!(sites
            .iter()
            .any(|s| s.hazard_type == "zig_vopr_retry_body" && s.source.contains("outer_after")));
        assert!(sites
            .iter()
            .any(|s| s.hazard_type == "zig_wait_loop" && s.required_evidence == "hammer"));
        assert!(sites
            .iter()
            .any(|s| s.hazard_type == "zig_loom_atomic" && s.source.contains("cmpxchgWeak")));
    }

    #[test]
    fn test_zig_vopr_categories() {
        let codes_and_cats = vec![
            ("std.time.milliTimestamp()", "zig_vopr_time"),
            ("std.time.nanoTimestamp()", "zig_vopr_time"),
            ("std.time.microTimestamp()", "zig_vopr_time"),
            ("std.time.Instant.now()", "zig_vopr_time"),
            ("std.time.Timer", "zig_vopr_time"),
            ("clock_gettime()", "zig_vopr_time"),
            ("milliTimestamp()", "zig_vopr_time"),
            ("nanoTimestamp()", "zig_vopr_time"),
            ("std.crypto.random", "zig_vopr_random"),
            ("std.Random", "zig_vopr_random"),
            ("std.rand", "zig_vopr_random"),
            ("getrandom()", "zig_vopr_random"),
            ("Random.DefaultPrng", "zig_vopr_random"),
            ("posix.recv()", "zig_vopr_net_io"),
            ("posix.send()", "zig_vopr_net_io"),
            ("posix.connect()", "zig_vopr_net_io"),
            ("posix.accept()", "zig_vopr_net_io"),
            ("posix.bind()", "zig_vopr_net_io"),
            ("posix.listen()", "zig_vopr_net_io"),
            ("posix.socket()", "zig_vopr_net_io"),
            ("std.posix.recv()", "zig_vopr_net_io"),
            ("std.posix.send()", "zig_vopr_net_io"),
            ("std.posix.connect()", "zig_vopr_net_io"),
            ("std.posix.accept()", "zig_vopr_net_io"),
            ("std.net.Stream", "zig_vopr_net_io"),
            ("linux.IoUring.recv()", "zig_vopr_net_io"),
            ("linux.IoUring.send()", "zig_vopr_net_io"),
            ("linux.IoUring.accept()", "zig_vopr_net_io"),
            ("linux.IoUring.connect()", "zig_vopr_net_io"),
            ("posix.open()", "zig_vopr_fs_io"),
            ("posix.openat()", "zig_vopr_fs_io"),
            ("posix.read()", "zig_vopr_fs_io"),
            ("posix.write()", "zig_vopr_fs_io"),
            ("posix.close()", "zig_vopr_fs_io"),
            ("posix.fsync()", "zig_vopr_fs_io"),
            ("std.posix.open()", "zig_vopr_fs_io"),
            ("std.posix.openat()", "zig_vopr_fs_io"),
            ("std.posix.read()", "zig_vopr_fs_io"),
            ("std.posix.write()", "zig_vopr_fs_io"),
            ("std.posix.close()", "zig_vopr_fs_io"),
            ("std.fs.File", "zig_vopr_fs_io"),
            ("linux.IoUring.read()", "zig_vopr_fs_io"),
            ("linux.IoUring.write()", "zig_vopr_fs_io"),
            ("linux.IoUring.fsync()", "zig_vopr_fs_io"),
            ("linux.IoUring.openat()", "zig_vopr_fs_io"),
            ("linux.IoUring.close()", "zig_vopr_fs_io"),
            ("self.ring.read()", "zig_vopr_ring_io"),
            ("self.ring.write()", "zig_vopr_ring_io"),
            ("self.ring.recv()", "zig_vopr_ring_io"),
            ("self.ring.send()", "zig_vopr_ring_io"),
            ("self.ring.accept()", "zig_vopr_ring_io"),
            ("self.ring.connect()", "zig_vopr_ring_io"),
            ("self.ring.fsync()", "zig_vopr_ring_io"),
            ("self.ring.poll_add()", "zig_vopr_ring_io"),
            ("self.ring.poll_remove()", "zig_vopr_ring_io"),
            ("self.ring.cancel()", "zig_vopr_ring_io"),
            ("ring.read()", "zig_vopr_ring_io"),
            ("ring.write()", "zig_vopr_ring_io"),
            ("ring.recv()", "zig_vopr_ring_io"),
            ("ring.send()", "zig_vopr_ring_io"),
            ("ring.accept()", "zig_vopr_ring_io"),
            ("ring.connect()", "zig_vopr_ring_io"),
        ];

        for (code, expected_type) in codes_and_cats {
            let sites = scan_zig_sites("test.zig", code);
            assert!(
                !sites.is_empty(),
                "Expected sites for: {}, found none",
                code
            );
            assert_eq!(
                sites[0].hazard_type, expected_type,
                "Expected {} for {}, got {}",
                expected_type, code, sites[0].hazard_type
            );
        }
    }

    #[test]
    fn test_rust_unsafe_block_tracking() {
        let rust_code = r#"
            // unsafe implementation check
            unsafe impl Send for MyStruct {}
            
            // unsafe fn check
            unsafe fn raw_call() {}
            
            fn normal_fn() {
                unsafe {
                    let val = raw_ptr.read(); // unsafe operation inside unsafe block
                    if val > 0 {
                        let nested = 42;
                    }
                }
                // outside unsafe block, no unsafe operation
            }
        "#;

        let sites = scan_rust_sites("src/lib.rs", rust_code);
        let types = hazard_types(sites);

        assert!(types.contains(&"rust_unsafe_impl".to_string()));
        assert!(types.contains(&"rust_unsafe_fn".to_string()));
        assert!(types.contains(&"rust_unsafe_block".to_string()));
        assert!(types.contains(&"rust_unsafe_operation".to_string()));
    }

    #[test]
    fn test_excluded_common_directories_and_files() {
        let dir = tempdir().unwrap();

        // Excluded folders: vendor, third_party,cmake-build-debug, etc.
        let excluded_dirs = vec![
            "vendor",
            "third_party",
            "node_modules",
            "tmp",
            "dist",
            "build",
            "target",
            "bin",
            "obj",
            "packages",
            "cmake-build-debug",
            "cmake-build-release",
            "tests",
            "test",
            "benches",
            "examples",
            ".hidden_dir",
        ];

        for d in excluded_dirs {
            let path = dir.path().join(d);
            fs::create_dir_all(&path).unwrap();
            fs::write(path.join("lib.rs"), "unsafe fn foo() {}").unwrap();
        }

        // Included folders
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/lib.rs"), "unsafe fn foo() {}").unwrap();

        let storage = Storage::open_memory().unwrap();
        let stats = ingest_hazards(&storage, dir.path(), "rust", "abc", Some(10)).unwrap();

        // Only src/lib.rs should be scanned
        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 1);
    }

    #[test]
    fn test_excluded_go_directories_and_files() {
        let dir = tempdir().unwrap();

        let excluded_go_dirs = vec![
            "vendor",
            "testdata",
            "node_modules",
            "tmp",
            "dist",
            ".hidden_dir",
        ];

        for d in excluded_go_dirs {
            let path = dir.path().join(d);
            fs::create_dir_all(&path).unwrap();
            fs::write(path.join("file.go"), "package foo\nfunc run() { go bar() }").unwrap();
        }

        // Excluded file pattern: _test.go
        fs::create_dir_all(dir.path().join("pkg")).unwrap();
        fs::write(
            dir.path().join("pkg/helper_test.go"),
            "package pkg\nfunc run() { go bar() }",
        )
        .unwrap();

        // Valid go files
        fs::write(
            dir.path().join("pkg/helper.go"),
            "package pkg\nfunc run() {\n    go bar()\n}",
        )
        .unwrap();

        let storage = Storage::open_memory().unwrap();
        let stats = ingest_hazards(&storage, dir.path(), "go", "abc", Some(10)).unwrap();

        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 1);
    }

    #[test]
    fn test_excluded_zig_files() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("zig/runtime")).unwrap();

        let excluded_names = vec![
            "foo-test.zig",
            "foo-vopr.zig",
            "foo-loom.zig",
            "foo-bench.zig",
            "vopr-foo.zig",
            "loom-foo.zig",
            "all-tests.zig",
            "all-fuzz.zig",
            "size_check.zig",
            "runtime-header.zig",
        ];

        for name in excluded_names {
            fs::write(
                dir.path().join("zig/runtime").join(name),
                "fn run() void { @cmpxchgStrong(i32, &x, 0, 1, .seq_cst, .seq_cst); }",
            )
            .unwrap();
        }

        // Valid zig file
        fs::write(
            dir.path().join("zig/runtime/valid.zig"),
            "fn run() void { @cmpxchgStrong(i32, &x, 0, 1, .seq_cst, .seq_cst); }",
        )
        .unwrap();

        let storage = Storage::open_memory().unwrap();
        let stats = ingest_hazards(&storage, dir.path(), "zig", "abc", Some(10)).unwrap();

        assert_eq!(stats.scanned_files, 1);
        assert_eq!(stats.hazards, 1);
    }

    fn hazard_types(sites: Vec<HazardSite>) -> Vec<String> {
        sites.into_iter().map(|site| site.hazard_type).collect()
    }

    #[test]
    fn test_ingest_c_cpp_csharp_and_timestamp_fallback() {
        let dir = tempdir().unwrap();
        fs::write(
            dir.path().join("test.c"),
            "void foo() { char *p = malloc(10); free(p); }",
        )
        .unwrap();
        fs::write(
            dir.path().join("test.cpp"),
            "void foo() { auto p = new int; delete p; }",
        )
        .unwrap();
        fs::write(
            dir.path().join("test.cs"),
            "public unsafe class Bar { void Baz() { fixed (int* p = &x) {} } }",
        )
        .unwrap();

        let storage = Storage::open_memory().unwrap();

        let stats_c = ingest_hazards(&storage, dir.path(), "c", "commit_c", None).unwrap();
        assert_eq!(stats_c.scanned_files, 1);

        let stats_cpp = ingest_hazards(&storage, dir.path(), "cpp", "commit_cpp", None).unwrap();
        assert_eq!(stats_cpp.scanned_files, 1);

        let stats_csharp =
            ingest_hazards(&storage, dir.path(), "csharp", "commit_cs", None).unwrap();
        assert_eq!(stats_csharp.scanned_files, 1);
    }

    #[test]
    fn test_query_hazards_invalid_query_error() {
        let sites = query_hazards(
            "test.rs",
            "pub fn foo() {}",
            tree_sitter_rust::LANGUAGE.into(),
            "(invalid_pattern",
        );
        assert!(sites.is_empty());
    }

    #[test]
    fn hazard_policy_comes_from_shared_contract() {
        assert_eq!(
            hazard_policy("zig_allocator").unwrap().evidence_provider,
            "allocator"
        );
        assert_eq!(
            hazard_policy("zig_vopr_time").unwrap().evidence_provider,
            "vopr"
        );
        assert!(hazard_policy("unknown_hazard").is_none());
    }

    #[test]
    fn unsafe_hazards_are_not_classified_by_substrings() {
        assert_eq!(
            hazard_policy("rust_unsafe_block")
                .unwrap()
                .evidence_provider,
            "miri"
        );
        assert_eq!(
            hazard_policy("rust_unsafe_fn").unwrap().evidence_provider,
            "miri"
        );
        assert_eq!(
            hazard_policy("go_race_lock").unwrap().evidence_provider,
            "race"
        );
        assert_eq!(
            hazard_policy("go_race_atomic").unwrap().evidence_provider,
            "race"
        );
    }

    #[test]
    fn test_non_directory_file_collection_no_files() {
        let dir = tempdir().unwrap();
        let file_path = dir.path().join("not_a_dir");
        fs::write(&file_path, "code").unwrap();
        let storage = Storage::open_memory().unwrap();
        let stats = ingest_hazards(&storage, &file_path, "zig", "abc", Some(10)).unwrap();
        assert_eq!(stats.scanned_files, 0);
    }

    // The runtime query text comes from hazard-contract. These copies remain
    // as generated/package-local resources; this test checks both generated
    // copies, so a local edit cannot quietly create a second policy owner.
    #[test]
    fn vendored_hazard_queries_match_fact_mines_originals() {
        let originals_dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fact-mine/src/syntax");
        if !originals_dir.is_dir() {
            eprintln!("skipping: fact-mine sibling tree not present (not a monorepo checkout)");
            return;
        }
        let vendored = [
            ("go_hazards.scm", GO_HAZARDS),
            ("rust_hazards.scm", RUST_HAZARDS),
            ("zig_hazards.scm", ZIG_HAZARDS),
            ("c_hazards.scm", C_HAZARDS),
            ("cpp_hazards.scm", CPP_HAZARDS),
            ("csharp_hazards.scm", hazard_contract::CSHARP_HAZARDS),
        ];
        for (name, vendored_text) in vendored {
            let generated_copy = fs::read_to_string(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("src/db/hazards")
                    .join(name),
            )
            .unwrap_or_else(|_| panic!("gigasail generated query {name} is missing"));
            assert_eq!(
                vendored_text, generated_copy,
                "gigasail generated {name} drifted from hazard-contract"
            );
            let original = fs::read_to_string(originals_dir.join(name))
                .unwrap_or_else(|_| panic!("fact-mine original {name} is missing"));
            assert_eq!(
                vendored_text, original,
                "{name} has drifted from fact-mine's original - re-copy it from \
                 gems/fact-mine/src/syntax/{name} into gems/gigasail/src/db/hazards/{name}"
            );
        }
    }
}
