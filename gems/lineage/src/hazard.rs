use crate::extract::{BoundaryExtractor, HeuristicExtractor};
use crate::model::{BlobFile, HazardEvent, LogicalUnit, UnitKind};
use crate::storage::Storage;
use anyhow::{Context, Result};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HazardIngestStats {
    pub scanned_files: usize,
    pub hazards: usize,
    pub events: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HazardSite {
    path: String,
    line: u32,
    source: String,
    hazard_type: String,
    required_evidence: String,
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
        other => anyhow::bail!("unsupported hazard provider {other:?}"),
    }
}

fn ingest_zig_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(storage, repo, commit, timestamp, "zig", zig_source_files, scan_zig_sites)
}

fn ingest_go_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(storage, repo, commit, timestamp, "go", go_source_files, scan_go_sites)
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
    matches!(name, ".git" | "vendor" | "testdata" | "node_modules" | "tmp" | "dist")
        || name.starts_with('.')
}

fn excluded_go_file(path: &str) -> bool {
    let Some(name) = path.rsplit('/').next() else {
        return true;
    };
    name.ends_with("_test.go")
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
        || matches!(name, "all-tests.zig" | "all-fuzz.zig" | "size_check.zig" | "runtime-header.zig")
}

fn scan_zig_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_loom_exclude = false;
    let mut in_vopr_exclude = false;
    let mut in_retry = false;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        if line.contains("LOOM-EXCLUDE-BEGIN") {
            in_loom_exclude = true;
            continue;
        }
        if line.contains("LOOM-EXCLUDE-END") {
            in_loom_exclude = false;
            continue;
        }
        if line.contains("VOPR-EXCLUDE-BEGIN") {
            in_vopr_exclude = true;
            continue;
        }
        if line.contains("VOPR-EXCLUDE-END") {
            in_vopr_exclude = false;
            continue;
        }

        let code = strip_zig_comment(line);
        if !in_loom_exclude && is_atomic_site(code) {
            sites.push(site(path, line_no, line, "zig_loom_atomic", "loom"));
        }

        if !in_vopr_exclude {
            if line.contains("VOPR-START-RETRY") {
                sites.push(site(path, line_no, line, "zig_vopr_retry", "vopr"));
                in_retry = true;
                continue;
            }
            if line.contains("VOPR-END-RETRY") {
                in_retry = false;
                continue;
            }
            if line.contains("VOPR-RETRY") {
                sites.push(site(path, line_no, line, "zig_vopr_retry", "vopr"));
                continue;
            }
            if let Some(category) = vopr_category(code) {
                sites.push(site(
                    path,
                    line_no,
                    line,
                    &format!("zig_vopr_{category}"),
                    "vopr",
                ));
            } else if in_retry && !code.trim().is_empty() {
                sites.push(site(path, line_no, line, "zig_vopr_retry_body", "vopr"));
            }
        }
    }
    sites
}

fn scan_go_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_block_comment = false;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        let code = strip_go_comment(line, &mut in_block_comment);
        if code.trim().is_empty() {
            continue;
        }
        if is_go_goroutine_site(&code) {
            sites.push(site(path, line_no, line, "go_race_goroutine", "race"));
        }
        if is_go_atomic_site(&code) {
            sites.push(site(path, line_no, line, "go_race_atomic", "race"));
        }
        if is_go_lock_site(&code) {
            sites.push(site(path, line_no, line, "go_race_lock", "race"));
        }
        if is_go_waitgroup_site(&code) {
            sites.push(site(path, line_no, line, "go_concurrency_waitgroup", "concurrency"));
        }
        if is_go_channel_site(&code) {
            sites.push(site(path, line_no, line, "go_concurrency_channel", "concurrency"));
        }
    }
    sites
}

fn site(
    path: &str,
    line: u32,
    source: &str,
    hazard_type: &str,
    required_evidence: &str,
) -> HazardSite {
    HazardSite {
        path: path.to_string(),
        line,
        source: source.trim().to_string(),
        hazard_type: hazard_type.to_string(),
        required_evidence: required_evidence.to_string(),
    }
}

fn is_go_goroutine_site(code: &str) -> bool {
    code.trim_start().starts_with("go ") || code.contains("; go ")
}

fn is_go_atomic_site(code: &str) -> bool {
    code.contains("atomic.")
}

fn is_go_lock_site(code: &str) -> bool {
    [
        "sync.Mutex",
        "sync.RWMutex",
        "sync.Map",
        "sync.Once",
        "sync.Cond",
        ".Lock(",
        ".Unlock(",
        ".RLock(",
        ".RUnlock(",
    ]
    .iter()
    .any(|needle| code.contains(needle))
}

fn is_go_waitgroup_site(code: &str) -> bool {
    ["sync.WaitGroup", ".Add(", ".Done(", ".Wait("]
        .iter()
        .any(|needle| code.contains(needle))
}

fn is_go_channel_site(code: &str) -> bool {
    code.contains("make(chan")
        || code.contains("select {")
        || code.contains("<-")
}

fn is_atomic_site(code: &str) -> bool {
    code.contains("@atomic")
        || code.contains("@cmpxchg")
        || code.contains("@fence(")
        || [
            ".load(",
            ".store(",
            ".swap(",
            ".fetchAdd(",
            ".fetchSub(",
            ".fetchOr(",
            ".fetchAnd(",
            ".fetchXor(",
            ".fetchMin(",
            ".fetchMax(",
            ".cmpxchgStrong(",
            ".cmpxchgWeak(",
            ".compareExchange(",
            ".compareExchangeStrong(",
            ".compareExchangeWeak(",
            ".rmw(",
        ]
        .iter()
        .any(|needle| code.contains(needle))
}

fn vopr_category(code: &str) -> Option<&'static str> {
    if [
        "std.time.milliTimestamp(",
        "std.time.nanoTimestamp(",
        "std.time.microTimestamp(",
        "std.time.Instant.now(",
        "std.time.Timer",
        "clock_gettime(",
        "milliTimestamp(",
        "nanoTimestamp(",
    ]
    .iter()
    .any(|needle| code.contains(needle))
    {
        return Some("time");
    }
    if ["std.crypto.random", "std.Random", "std.rand", "getrandom(", "Random.DefaultPrng"]
        .iter()
        .any(|needle| code.contains(needle))
    {
        return Some("random");
    }
    if [
        "posix.recv(",
        "posix.send(",
        "posix.connect(",
        "posix.accept(",
        "posix.bind(",
        "posix.listen(",
        "posix.socket(",
        "std.posix.recv(",
        "std.posix.send(",
        "std.posix.connect(",
        "std.posix.accept(",
        "std.net.",
        "linux.IoUring.recv(",
        "linux.IoUring.send(",
        "linux.IoUring.accept(",
        "linux.IoUring.connect(",
    ]
    .iter()
    .any(|needle| code.contains(needle))
    {
        return Some("net_io");
    }
    if [
        "posix.open(",
        "posix.openat(",
        "posix.read(",
        "posix.write(",
        "posix.close(",
        "posix.fsync(",
        "std.posix.open(",
        "std.posix.openat(",
        "std.posix.read(",
        "std.posix.write(",
        "std.posix.close(",
        "std.fs.",
        "linux.IoUring.read(",
        "linux.IoUring.write(",
        "linux.IoUring.fsync(",
        "linux.IoUring.openat(",
        "linux.IoUring.close(",
    ]
    .iter()
    .any(|needle| code.contains(needle))
    {
        return Some("fs_io");
    }
    if [
        "self.ring.read(",
        "self.ring.write(",
        "self.ring.recv(",
        "self.ring.send(",
        "self.ring.accept(",
        "self.ring.connect(",
        "self.ring.fsync(",
        "self.ring.poll_add(",
        "self.ring.poll_remove(",
        "self.ring.cancel(",
        "ring.read(",
        "ring.write(",
        "ring.recv(",
        "ring.send(",
        "ring.accept(",
        "ring.connect(",
    ]
    .iter()
    .any(|needle| code.contains(needle))
    {
        return Some("ring_io");
    }
    None
}

fn strip_zig_comment(line: &str) -> &str {
    line.split_once("//").map(|(code, _)| code).unwrap_or(line)
}

fn strip_go_comment(line: &str, in_block_comment: &mut bool) -> String {
    let mut out = String::new();
    let mut rest = line;
    loop {
        if *in_block_comment {
            let Some((_, after)) = rest.split_once("*/") else {
                return out;
            };
            *in_block_comment = false;
            rest = after;
            continue;
        }
        let block = rest.find("/*");
        let line_comment = rest.find("//");
        match (block, line_comment) {
            (Some(block), Some(comment)) if comment < block => {
                out.push_str(&rest[..comment]);
                return out;
            }
            (Some(block), _) => {
                out.push_str(&rest[..block]);
                rest = &rest[block + 2..];
                *in_block_comment = true;
            }
            (_, Some(comment)) => {
                out.push_str(&rest[..comment]);
                return out;
            }
            (None, None) => {
                out.push_str(rest);
                return out;
            }
        }
    }
}

fn unit_for_site(blob: &BlobFile, units: &[LogicalUnit], line: u32) -> LogicalUnit {
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

fn now_timestamp() -> i64 {
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
    fn go_hazard_scan_ignores_comments() {
        let sites = scan_go_sites(
            "demo.go",
            "package demo\n\nfunc run() {\n    // go func() {}()\n    /* atomic.AddInt64(&x, 1) */\n    ch <- 1\n}\n",
        );

        assert_eq!(sites.len(), 1);
        assert_eq!(sites[0].hazard_type, "go_concurrency_channel");
    }
}
