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
        "rust" => ingest_rust_hazards(storage, repo.as_ref(), commit, timestamp),
        "c" => ingest_c_hazards(storage, repo.as_ref(), commit, timestamp),
        "cpp" => ingest_cpp_hazards(storage, repo.as_ref(), commit, timestamp),
        "csharp" => ingest_csharp_hazards(storage, repo.as_ref(), commit, timestamp),
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

fn ingest_rust_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(storage, repo, commit, timestamp, "rust", rust_source_files, scan_rust_sites)
}

fn ingest_c_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(storage, repo, commit, timestamp, "c", c_source_files, scan_c_sites)
}

fn ingest_cpp_hazards(
    storage: &Storage,
    repo: &Path,
    commit: &str,
    timestamp: Option<i64>,
) -> Result<HazardIngestStats> {
    ingest_language_hazards(storage, repo, commit, timestamp, "cpp", cpp_source_files, scan_cpp_sites)
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
    matches!(name, ".git" | "vendor" | "testdata" | "node_modules" | "tmp" | "dist")
        || name.starts_with('.')
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

fn scan_rust_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_block_comment = false;
    let mut unsafe_depth = 0_i32;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        let code = strip_quoted_literals(&strip_go_comment(line, &mut in_block_comment));
        if code.trim().is_empty() {
            continue;
        }
        if is_rust_atomic_site(&code) {
            sites.push(site(path, line_no, line, "rust_loom_atomic", "loom"));
        }
        if is_rust_concurrency_site(&code) {
            sites.push(site(path, line_no, line, "rust_loom_concurrency", "loom"));
        }
        if code.contains("unsafe fn ") || code.contains("unsafe fn(") {
            sites.push(site(path, line_no, line, "rust_unsafe_fn", "miri"));
        }
        if code.contains("unsafe impl ") {
            sites.push(site(path, line_no, line, "rust_unsafe_impl", "miri"));
        }
        let starts_unsafe = code.contains("unsafe {");
        if starts_unsafe {
            sites.push(site(path, line_no, line, "rust_unsafe_block", "miri"));
        }
        if (unsafe_depth > 0 || starts_unsafe) && is_rust_unsafe_operation(&code) {
            sites.push(site(path, line_no, line, "rust_unsafe_operation", "miri"));
        }
        unsafe_depth = update_unsafe_depth(&code, unsafe_depth);
    }
    sites
}

fn scan_c_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_block_comment = false;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        let code = strip_quoted_literals(&strip_go_comment(line, &mut in_block_comment));
        if code.trim().is_empty() {
            continue;
        }
        if is_c_tsan_site(&code) {
            sites.push(site(path, line_no, line, "c_tsan_concurrency", "tsan"));
        }
        if is_c_asan_api_site(&code) {
            sites.push(site(path, line_no, line, "c_asan_raw_memory_api", "asan"));
        }
        if is_c_pointer_hazard(&code) {
            sites.push(site(path, line_no, line, "c_asan_pointer", "asan"));
        }
        if is_c_lsan_site(&code) {
            sites.push(site(path, line_no, line, "c_lsan_lifetime", "lsan"));
        }
        if is_arithmetic_ub_site(&code) {
            sites.push(site(path, line_no, line, "c_ubsan_arithmetic", "ubsan"));
        }
        if is_c_cast_ub_site(&code) {
            sites.push(site(path, line_no, line, "c_ubsan_cast", "ubsan"));
        }
    }
    sites
}

fn scan_cpp_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_block_comment = false;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        let code = strip_quoted_literals(&strip_go_comment(line, &mut in_block_comment));
        if code.trim().is_empty() {
            continue;
        }
        if is_cpp_tsan_site(&code) {
            sites.push(site(path, line_no, line, "cpp_tsan_concurrency", "tsan"));
        }
        if is_cpp_asan_api_site(&code) {
            sites.push(site(path, line_no, line, "cpp_asan_raw_memory_api", "asan"));
        }
        if is_cpp_pointer_or_cast_hazard(&code) {
            sites.push(site(path, line_no, line, "cpp_asan_pointer_or_cast", "asan"));
        }
        if is_cpp_lsan_site(&code) {
            sites.push(site(path, line_no, line, "cpp_lsan_lifetime", "lsan"));
        }
        if is_arithmetic_ub_site(&code) {
            sites.push(site(path, line_no, line, "cpp_ubsan_arithmetic", "ubsan"));
        }
        if contains_any(&code, &["reinterpret_cast<", "const_cast<", "static_cast<"]) {
            sites.push(site(path, line_no, line, "cpp_ubsan_cast", "ubsan"));
        }
    }
    sites
}

fn scan_csharp_sites(path: &str, contents: &str) -> Vec<HazardSite> {
    let mut sites = Vec::new();
    let mut in_block_comment = false;
    let mut unsafe_depth = 0_i32;
    for (index, line) in contents.lines().enumerate() {
        let line_no = (index + 1) as u32;
        let code = strip_quoted_literals(&strip_go_comment(line, &mut in_block_comment));
        if code.trim().is_empty() {
            continue;
        }
        if is_csharp_concurrency_site(&code) {
            sites.push(site(path, line_no, line, "csharp_concurrency", "concurrency"));
        }
        if is_csharp_unsafe_site(&code, unsafe_depth) {
            sites.push(site(path, line_no, line, "csharp_unsafe_memory", "unsafe"));
        }
        unsafe_depth = update_csharp_unsafe_depth(&code, unsafe_depth);
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

fn contains_any(code: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| code.contains(needle))
}

fn is_rust_atomic_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "std::sync::atomic",
            "core::sync::atomic",
            "Ordering::",
            ".load(",
            ".store(",
            ".swap(",
            ".compare_exchange(",
            ".compare_exchange_weak(",
            ".fetch_add(",
            ".fetch_sub(",
            ".fetch_or(",
            ".fetch_and(",
            ".fetch_xor(",
            ".fetch_update(",
            "fence(",
            "AtomicBool",
            "AtomicI",
            "AtomicU",
            "AtomicPtr",
        ],
    )
}

fn is_rust_concurrency_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "thread::spawn",
            "std::thread::spawn",
            "std::sync::Mutex",
            "std::sync::RwLock",
            "std::sync::Condvar",
            "std::sync::Arc",
            "Arc<",
            "Mutex<",
            "RwLock<",
            "Condvar",
            "mpsc::",
            "crossbeam::channel",
            ".lock(",
            ".try_lock(",
        ],
    )
}

fn is_rust_unsafe_operation(code: &str) -> bool {
    contains_any(
        code,
        &[
            "std::ptr::",
            "core::ptr::",
            "ptr::read",
            "ptr::write",
            "ptr::copy",
            "copy_nonoverlapping",
            "from_raw",
            "into_raw",
            "get_unchecked",
            "get_unchecked_mut",
            "unwrap_unchecked",
            "transmute",
            "assume_init",
            "MaybeUninit",
            "addr_of!",
            "asm!",
            ".add(",
            ".offset(",
            ".read(",
            ".write(",
            ".copy_to(",
            ".copy_from(",
        ],
    ) || pointer_deref_site(code)
}

fn update_unsafe_depth(code: &str, unsafe_depth: i32) -> i32 {
    let relevant = if unsafe_depth > 0 {
        code
    } else if let Some(index) = code.find("unsafe {") {
        &code[index..]
    } else {
        ""
    };
    if relevant.is_empty() {
        return unsafe_depth;
    }
    (unsafe_depth + brace_delta(relevant)).max(0)
}

fn is_c_tsan_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "_Atomic",
            "atomic_",
            "__atomic_",
            "__sync_",
            "pthread_create",
            "pthread_mutex_",
            "pthread_rwlock_",
            "pthread_cond_",
            "pthread_spin_",
            "pthread_barrier_",
            "mtx_",
            "cnd_",
            "thrd_create",
        ],
    )
}

fn is_c_asan_api_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "memcpy(",
            "memmove(",
            "memset(",
            "strcpy(",
            "strncpy(",
            "strcat(",
            "strncat(",
            "sprintf(",
            "snprintf(",
            "vsprintf(",
            "vsnprintf(",
            "gets(",
            "scanf(",
            "sscanf(",
            "fscanf(",
            "alloca(",
        ],
    )
}

fn is_c_lsan_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "malloc(",
            "calloc(",
            "realloc(",
            "aligned_alloc(",
            "posix_memalign(",
            "strdup(",
            "strndup(",
            "free(",
        ],
    )
}

fn is_c_pointer_hazard(code: &str) -> bool {
    code.contains("->") || pointer_deref_site(code)
}

fn is_c_cast_ub_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "(intptr_t)",
            "(uintptr_t)",
            "(size_t)",
            "(ssize_t)",
            "(int)",
            "(long)",
            "(short)",
            "(char)",
            "(void *)",
            "(char *)",
            "(int *)",
            "(long *)",
        ],
    )
}

fn is_cpp_tsan_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "std::thread",
            "std::jthread",
            "std::async",
            "std::atomic",
            "std::mutex",
            "std::shared_mutex",
            "std::recursive_mutex",
            "std::condition_variable",
            "std::lock_guard",
            "std::unique_lock",
            "std::scoped_lock",
            "std::call_once",
            ".lock(",
            ".try_lock(",
            ".unlock(",
        ],
    )
}

fn is_cpp_asan_api_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "std::memcpy(",
            "std::memmove(",
            "std::memset(",
            "memcpy(",
            "memmove(",
            "memset(",
            "strcpy(",
            "strncpy(",
            "strcat(",
            "strncat(",
            "sprintf(",
            "snprintf(",
            "std::span<",
            "std::string_view",
        ],
    )
}

fn is_cpp_lsan_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "malloc(",
            "calloc(",
            "realloc(",
            "free(",
            "std::malloc(",
            "std::calloc(",
            "std::realloc(",
            "std::free(",
            "new ",
            "new[]",
            "delete ",
            "delete[]",
        ],
    )
}

fn is_cpp_pointer_or_cast_hazard(code: &str) -> bool {
    code.contains("->")
        || pointer_deref_site(code)
        || contains_any(code, &["reinterpret_cast<", "const_cast<"])
}

fn is_arithmetic_ub_site(code: &str) -> bool {
    contains_any(code, &[" / ", " % ", "<<", ">>"])
}

fn is_csharp_concurrency_site(code: &str) -> bool {
    contains_any(
        code,
        &[
            "Task.Run",
            "Task.Factory.StartNew",
            "new Thread",
            "ThreadPool.",
            "Parallel.",
            "lock (",
            "lock(",
            "Monitor.",
            "Interlocked.",
            "Volatile.",
            "ConcurrentDictionary",
            "ConcurrentQueue",
            "ConcurrentBag",
            "BlockingCollection",
            "SemaphoreSlim",
            "Mutex",
            "ReaderWriterLockSlim",
            "SpinLock",
        ],
    )
}

fn is_csharp_unsafe_site(code: &str, unsafe_depth: i32) -> bool {
    (unsafe_depth > 0 && (code.contains("->") || pointer_deref_site(code)))
        || contains_any(
            code,
            &[
                "unsafe",
                "fixed (",
                "fixed(",
                "stackalloc",
                "Marshal.",
                "IntPtr",
                "UIntPtr",
                "GCHandle",
                "Unsafe.",
                "MemoryMarshal.",
                "byte*",
                "char*",
                "int*",
                "long*",
                "void*",
            ],
        )
}

fn update_csharp_unsafe_depth(code: &str, unsafe_depth: i32) -> i32 {
    let relevant = if unsafe_depth > 0 {
        code
    } else if let Some(index) = code.find("unsafe {") {
        &code[index..]
    } else {
        ""
    };
    if relevant.is_empty() {
        return unsafe_depth;
    }
    (unsafe_depth + brace_delta(relevant)).max(0)
}

fn pointer_deref_site(code: &str) -> bool {
    let trimmed = code.trim_start();
    trimmed.starts_with('*')
        || contains_any(code, &["= *", "=*", "return *", "(*", ", *", "[*"])
}

fn brace_delta(code: &str) -> i32 {
    code.chars().fold(0_i32, |total, ch| match ch {
        '{' => total + 1,
        '}' => total - 1,
        _ => total,
    })
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

fn strip_quoted_literals(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '"' || ch == '\'' {
            let quote = ch;
            out.push_str("\"\"");
            let mut escaped = false;
            for inner in chars.by_ref() {
                if escaped {
                    escaped = false;
                    continue;
                }
                if inner == '\\' {
                    escaped = true;
                    continue;
                }
                if inner == quote {
                    break;
                }
            }
        } else {
            out.push(ch);
        }
    }
    out
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

    fn hazard_types(sites: Vec<HazardSite>) -> Vec<String> {
        sites.into_iter().map(|site| site.hazard_type).collect()
    }
}
