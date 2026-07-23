use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

use crate::stack_trace::{LanguageNormalizer, RepoPathNormalizer};
use crate::storage::Storage;

/// One profile-hotness/v1 entry: a function's share of a runtime profile.
#[derive(Clone, Debug, Deserialize)]
pub struct HotnessEntry {
    pub function: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub flat_share: f64,
    #[serde(default)]
    pub cum_share: f64,
    pub tier: String,
}

#[derive(Clone, Debug, Deserialize)]
struct HotnessDocument {
    schema: String,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    commit: Option<String>,
    entries: Vec<HotnessEntry>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HotnessIngestStats {
    pub entries: usize,
    pub critical: usize,
    pub skipped: usize,
    pub resolved_exact: usize,
    pub resolved_symbol: usize,
    pub unresolved: usize,
}

/// Method-name tails too generic for symbol matching: a unique project
/// definition proves nothing about a profiler frame with one of these names.
const GENERIC_TAILS: &[&str] = &[
    "new", "init", "main", "run", "call", "get", "set", "next", "len", "size", "insert", "remove",
    "push", "pop", "clear", "clone", "drop", "free", "alloc", "read", "write", "open", "close",
    "parse", "format", "hash", "eq", "cmp", "index", "iter", "lock", "unlock", "update", "build",
];

/// Reduce a profiler symbol to (owner_tail, method_tail).
///
/// Handles the mangling conventions of the supported profilers without any
/// language analysis: template/generic arguments, Rust hash suffixes and
/// closures, Zig anonymous instantiations, Go receiver spellings, and
/// JVM/C#-style dotted names.
fn symbol_tails(symbol: &str) -> (Option<String>, Option<String>) {
    // Go spells method receivers as pkg.(*Type).Method: keep the type.
    let symbol = if symbol.contains(".(*") {
        symbol.replace(".(*", ".").replacen(").", ".", 1)
    } else {
        symbol.to_string()
    };
    let symbol = symbol.as_str();
    let mut cleaned = String::with_capacity(symbol.len());
    let mut depth = 0usize;
    for c in symbol.chars() {
        match c {
            '<' | '(' | '[' => depth += 1,
            '>' | ')' | ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 => cleaned.push(c),
            _ => {}
        }
    }
    let cleaned = cleaned
        .replace("{{closure}}", "")
        .replace("::habcdef", "::");
    let segments: Vec<String> = cleaned
        .split(|c| c == ':' || c == '.' || c == '#' || c == '$')
        .map(|segment| {
            segment
                .trim()
                .trim_start_matches('*')
                .trim_start_matches('&')
                .split("__anon_")
                .next()
                .unwrap_or("")
                .to_string()
        })
        .filter(|segment| {
            !segment.is_empty()
                && segment.chars().next().is_some_and(|c| c.is_alphabetic() || c == '_')
                // Rust symbol hashes: h + 16 hex digits.
                && !(segment.len() == 17
                    && segment.starts_with('h')
                    && segment[1..].chars().all(|c| c.is_ascii_hexdigit()))
        })
        .collect();
    let method = segments.last().cloned();
    let owner = segments
        .len()
        .checked_sub(2)
        .and_then(|index| segments.get(index))
        .cloned();
    (owner, method)
}

struct UnitIndex {
    /// method tail -> (unit path, unit name, start_line)
    by_tail: HashMap<String, Vec<(String, String, i64)>>,
    paths: HashSet<String>,
    by_basename: HashMap<String, Vec<String>>,
}

impl UnitIndex {
    fn load(storage: &Storage) -> Result<Self> {
        let units = storage.unit_symbol_index()?;
        let mut by_tail: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();
        let mut paths = HashSet::new();
        let mut by_basename: HashMap<String, Vec<String>> = HashMap::new();
        for (name, path, start_line) in units {
            let (_, tail) = symbol_tails(&name);
            if let Some(tail) = tail {
                by_tail
                    .entry(tail)
                    .or_default()
                    .push((path.clone(), name.clone(), start_line));
            }
            if let Some(basename) = path.rsplit('/').next() {
                by_basename
                    .entry(basename.to_string())
                    .or_default()
                    .push(path.clone());
            }
            paths.insert(path);
        }
        Ok(Self {
            by_tail,
            paths,
            by_basename,
        })
    }

    /// Resolve one entry to (path, line, resolution tier).
    fn resolve(
        &self,
        entry: &HotnessEntry,
        normalized_path: Option<&str>,
    ) -> (Option<String>, Option<i64>, &'static str) {
        // Tier 1: the profile's own path is a known project path. A
        // repo-relative path (contains a separator, not absolute) is kept
        // even without a matching unit - stackprof/pprof/cpuprofile paths
        // are authoritative; bare DWARF basenames and absolute system paths
        // fall through to symbol matching.
        if let Some(path) = normalized_path {
            if self.paths.contains(path) {
                return (Some(path.to_string()), entry.line, "exact");
            }
            if path.contains('/') && !path.starts_with('/') {
                return (Some(path.to_string()), entry.line, "declared");
            }
        }

        let (owner_tail, method_tail) = symbol_tails(&entry.function);
        let Some(method_tail) = method_tail else {
            return (None, None, "unresolved");
        };
        let candidates = match self.by_tail.get(&method_tail) {
            Some(candidates) => candidates,
            None => return (None, None, "unresolved"),
        };

        // Tier 2: DWARF often records basenames or build-relative paths;
        // corroborate them against project paths sharing the basename.
        if let Some(profile_path) = normalized_path {
            if let Some(basename) = profile_path.rsplit('/').next() {
                if let Some(project_paths) = self.by_basename.get(basename) {
                    let matching: Vec<_> = candidates
                        .iter()
                        .filter(|(path, _, _)| project_paths.contains(path))
                        .collect();
                    if let [only] = matching.as_slice() {
                        return (
                            Some(only.0.clone()),
                            entry.line.or(Some(only.2)),
                            "basename",
                        );
                    }
                }
            }
        }

        if GENERIC_TAILS.contains(&method_tail.as_str()) && owner_tail.is_none() {
            return (None, None, "unresolved");
        }

        // Module-path corroboration: for qualified symbols (crate::mod::fn,
        // a.b.C.method) require some qualifying segment to appear in the
        // candidate's path or name, so external-crate frames with project-
        // coincident tails (tree_sitter::Node::next_sibling vs a local
        // next_sibling helper) do not mis-resolve.
        let qualifiers: Vec<String> = {
            let cleaned = entry.function.replace("(*", "").replace(')', "");
            let mut segments: Vec<String> = cleaned
                .split(|c| c == ':' || c == '.' || c == '#' || c == '$')
                .filter(|segment| {
                    segment.len() > 2 && segment.chars().all(|c| c.is_alphanumeric() || c == '_')
                })
                .map(|segment| segment.to_lowercase())
                .collect();
            segments.pop();
            segments
        };
        // Only ::-qualified symbols carry module paths; dotted symbols
        // qualify by type names, which the owner tier already checks.
        let module_qualified = entry.function.contains("::");
        let corroborated = |path: &str, name: &str| -> bool {
            if !module_qualified || qualifiers.len() < 2 {
                return true;
            }
            let haystack =
                format!("{} {}", path.to_lowercase(), name.to_lowercase()).replace('-', "_");
            qualifiers.iter().any(|segment| haystack.contains(segment))
        };

        // Tier 3: owner tail appears in the unit name or its path.
        if let Some(owner) = &owner_tail {
            let owner_lower = owner.to_lowercase();
            let matching: Vec<_> = candidates
                .iter()
                .filter(|(path, name, _)| {
                    (name.to_lowercase().contains(&owner_lower)
                        || path.to_lowercase().contains(&owner_lower))
                        && corroborated(path, name)
                })
                .collect();
            if let [only] = matching.as_slice() {
                return (Some(only.0.clone()), Some(only.2), "owner-tail");
            }
        }

        // Tier 4: the tail is defined exactly once in the project.
        if !GENERIC_TAILS.contains(&method_tail.as_str()) {
            if let [only] = candidates.as_slice() {
                if corroborated(&only.0, &only.1) {
                    return (Some(only.0.clone()), Some(only.2), "tail-unique");
                }
            }
        }

        (None, None, "unresolved")
    }
}

const TIERS: &[&str] = &["critical", "warm", "cold"];

/// Ingest a profile-hotness/v1 document.
///
/// Rows are replaced per profile `source` so re-ingesting a fresh profile of
/// the same workload never double-counts, while profiles of different
/// workloads coexist; consumers take the maximum tier across sources - hot in
/// any real workload means hot.
pub fn ingest_hotness_json(
    storage: &Storage,
    normalizer: &RepoPathNormalizer,
    payload: &str,
    source_override: Option<&str>,
    commit_override: Option<&str>,
) -> Result<HotnessIngestStats> {
    let document: HotnessDocument =
        serde_json::from_str(payload).with_context(|| "invalid profile-hotness JSON")?;
    if document.schema != "profile-hotness/v1" {
        bail!("unsupported hotness schema: {}", document.schema);
    }
    let source = source_override
        .map(str::to_string)
        .or(document.source.clone())
        .unwrap_or_else(|| "profile".to_string());
    let commit = commit_override
        .map(str::to_string)
        .or(document.commit.clone());

    storage.deactivate_hotness_for_source(&source)?;
    let index = UnitIndex::load(storage)?;

    let mut stats = HotnessIngestStats::default();
    for entry in &document.entries {
        if entry.function.trim().is_empty() || !TIERS.contains(&entry.tier.as_str()) {
            stats.skipped += 1;
            continue;
        }
        let normalized = entry
            .path
            .as_deref()
            .map(|raw| normalizer.normalize_path(raw))
            .filter(|normalized| !normalized.is_empty());
        let (path, line, resolution) = index.resolve(entry, normalized.as_deref());
        match resolution {
            "exact" | "declared" => stats.resolved_exact += 1,
            "unresolved" => stats.unresolved += 1,
            _ => stats.resolved_symbol += 1,
        }
        storage.insert_unit_hotness(
            path.as_deref(),
            &entry.function,
            line.or(entry.line),
            entry.flat_share,
            entry.cum_share,
            &entry.tier,
            &source,
            commit.as_deref(),
            resolution,
        )?;
        stats.entries += 1;
        if entry.tier == "critical" {
            stats.critical += 1;
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn open_storage(dir: &std::path::Path) -> Storage {
        Storage::open(&dir.join("lineage.db")).unwrap()
    }

    fn payload(entries: &str) -> String {
        format!(
            r#"{{"schema":"profile-hotness/v1","source":"pprof:cpu","commit":"abc","entries":[{entries}]}}"#
        )
    }

    #[test]
    fn ingests_entries_and_replaces_same_source() {
        let dir = tempdir().unwrap();
        let storage = open_storage(dir.path());
        let normalizer = RepoPathNormalizer::new(dir.path());

        let stats = ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Server#handle","path":"src/server.rb","line":42,"flat_share":0.4,"cum_share":0.6,"tier":"critical"},
                   {"function":"Parser#parse","path":"src/parse.rb","line":10,"flat_share":0.01,"cum_share":0.02,"tier":"warm"},
                   {"function":"","tier":"critical"},
                   {"function":"Bad#tier","tier":"scorching"}"#,
            ),
            None,
            None,
        )
        .unwrap();
        assert_eq!(stats.entries, 2);
        assert_eq!(stats.critical, 1);
        assert_eq!(stats.skipped, 2);

        // Re-ingest the same source: previous rows deactivate, no double count.
        let stats = ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Server#handle","path":"src/server.rb","line":42,"flat_share":0.5,"cum_share":0.7,"tier":"critical"}"#,
            ),
            None,
            None,
        )
        .unwrap();
        assert_eq!(stats.entries, 1);

        let rows = storage.active_hotness().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].function, "Server#handle");
        assert!((rows[0].cum_share - 0.7).abs() < 1e-9);

        // A different source coexists.
        ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"Worker#drain","path":"src/worker.rb","flat_share":0.2,"cum_share":0.3,"tier":"critical"}"#,
            ),
            Some("pprof:io"),
            None,
        )
        .unwrap();
        assert_eq!(storage.active_hotness().unwrap().len(), 2);
    }

    #[test]
    fn symbol_tails_normalize_supported_profiler_spellings() {
        let cases = [
            (
                "fact_mine_rust::syntax::hazards::extract_hazards::h1a2b3c4d5e6f7a8b",
                Some("hazards"),
                Some("extract_hazards"),
            ),
            (
                "Thread.PosixThreadImpl.spawn__anon_54996.Instance.entryFn",
                Some("Instance"),
                Some("entryFn"),
            ),
            ("main.(*Server).handle", Some("Server"), Some("handle")),
            ("com.example.Widget.render", Some("Widget"), Some("render")),
            ("Namespace.Type::Method", Some("Type"), Some("Method")),
            (
                "<alloc::vec::Vec<T> as Extend<T>>::extend",
                None,
                Some("extend"),
            ),
            ("parse", None, Some("parse")),
        ];
        for (symbol, owner, method) in cases {
            let (got_owner, got_method) = symbol_tails(symbol);
            assert_eq!(got_owner.as_deref(), owner, "owner of {symbol}");
            assert_eq!(got_method.as_deref(), method, "method of {symbol}");
        }
    }

    #[test]
    fn resolves_symbols_against_the_unit_inventory() {
        use crate::model::{LogicalUnit, UnitKind};
        let dir = tempdir().unwrap();
        let storage = open_storage(dir.path());
        let normalizer = RepoPathNormalizer::new(dir.path());
        for (name, path, line) in [
            ("extract_hazards", "src/syntax/hazards.rs", 60_u32),
            ("entryFn", "zig/lib/parking-lot.zig", 12),
            ("handle", "src/server.go", 40),
            ("handle", "src/client.go", 9),
            ("parse", "src/parse.rs", 5),
        ] {
            let unit = LogicalUnit::new(
                name,
                UnitKind::Function,
                path,
                1,
                line,
                line + 5,
                "sig",
                "body",
            );
            storage.upsert_logical_unit(&unit, 10).unwrap();
        }

        let stats = ingest_hotness_json(
            &storage,
            &normalizer,
            &payload(
                r#"{"function":"fact_mine_rust::syntax::hazards::extract_hazards::hdeadbeefdeadbeef","path":"hazards.rs","line":77,"cum_share":0.2,"tier":"critical"},
                   {"function":"Thread.Pool__anon_1.entryFn","cum_share":0.1,"tier":"critical"},
                   {"function":"main.(*Server).handle","cum_share":0.09,"tier":"critical"},
                   {"function":"parse","cum_share":0.08,"tier":"critical"},
                   {"function":"clone3","cum_share":0.9,"tier":"critical"},
                   {"function":"Compiler#annotate","path":"compiler/ruby/annotator.rb","line":3,"cum_share":0.4,"tier":"critical"}"#,
            ),
            None,
            None,
        )
        .unwrap();

        // hazards.rs basename corroboration, entryFn tail-unique, Server owner
        // disambiguation, and the declared repo-relative ruby path resolve;
        // `parse` is a generic tail without owner and clone3 is out-of-project.
        assert_eq!(stats.resolved_symbol, 3);
        assert_eq!(stats.resolved_exact + stats.resolved_symbol, 4);
        assert_eq!(stats.unresolved, 2);

        let rows = storage.active_hotness().unwrap();
        let by_function: std::collections::HashMap<_, _> =
            rows.iter().map(|row| (row.function.clone(), row)).collect();
        assert_eq!(
            by_function["fact_mine_rust::syntax::hazards::extract_hazards::hdeadbeefdeadbeef"]
                .path
                .as_deref(),
            Some("src/syntax/hazards.rs")
        );
        assert_eq!(
            by_function["Thread.Pool__anon_1.entryFn"].path.as_deref(),
            Some("zig/lib/parking-lot.zig")
        );
        assert_eq!(
            by_function["main.(*Server).handle"].path.as_deref(),
            Some("src/server.go")
        );
        assert_eq!(by_function["parse"].path, None);
        assert_eq!(by_function["clone3"].path, None);
        assert_eq!(
            by_function["Compiler#annotate"].path.as_deref(),
            Some("compiler/ruby/annotator.rb")
        );
    }

    #[test]
    fn rejects_unknown_schema() {
        let dir = tempdir().unwrap();
        let storage = open_storage(dir.path());
        let normalizer = RepoPathNormalizer::new(dir.path());
        let error = ingest_hotness_json(
            &storage,
            &normalizer,
            r#"{"schema":"profile-hotness/v2","entries":[]}"#,
            None,
            None,
        )
        .unwrap_err();
        assert!(error.to_string().contains("unsupported hotness schema"));
    }
}
