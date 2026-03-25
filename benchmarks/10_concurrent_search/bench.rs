// Concurrent File Search — Rust / Tokio Benchmark
//
// One Tokio task per file.  Tokio uses an M:N thread pool (num_cpu threads
// by default) and async file I/O, giving true parallelism comparable to Go's
// goroutine scheduler.
//
// Tokio task overhead: ~a few hundred bytes per task (vs ~8MB OS thread stack
// in the old std::thread version, vs ~2KB CLEAR fiber).
//
// Search: memchr::memmem::find_iter — SIMD-accelerated (AVX2/SSE2),
// matching Go's bytes.Count throughput.
//
// Build: cargo build --release   (from this directory; runner.rb does this)
// Run:   ./bench_rust

use std::path::PathBuf;
use std::time::Instant;
use memchr::memmem;

const N_FILES: usize = 128;
const FILE_SIZE: usize = 10 * 1024;
const NEEDLE: &str = "the";
const DATA_DIR: &str = "benchmarks/10_concurrent_search/data";

// ---------------------------------------------------------------------------
// Deterministic pseudo-random u64 (LCG, same seed as Go/Zig versions)
// ---------------------------------------------------------------------------
struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self { Lcg(seed) }
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0
    }
    fn next_usize(&mut self, n: usize) -> usize { (self.next_u64() >> 33) as usize % n }
}

// ---------------------------------------------------------------------------
// Generate test data (idempotent)
// ---------------------------------------------------------------------------
static WORDS: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
    "do", "for", "from", "had", "has", "have", "he", "her", "him", "his",
    "in", "is", "it", "its", "may", "me", "my", "no", "not", "of",
    "on", "or", "our", "out", "she", "so", "than", "that", "the", "their",
    "them", "then", "there", "they", "this", "to", "up", "was", "we", "were",
    "when", "which", "who", "will", "with", "would", "you", "your", "time", "way",
];

fn generate_test_data() -> std::io::Result<()> {
    std::fs::create_dir_all(DATA_DIR)?;
    let existing = std::fs::read_dir(DATA_DIR)?.count();
    if existing >= N_FILES { return Ok(()); }

    for i in 0..N_FILES {
        let mut rng = Lcg::new((i as u64).wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407));
        let mut buf = String::with_capacity(FILE_SIZE + 8);

        while buf.len() + 6 < FILE_SIZE {
            let w = if rng.next_usize(N_FILES) < i {
                "the"
            } else {
                let mut idx = rng.next_usize(WORDS.len() - 1);
                if idx >= 38 { idx += 1; }
                WORDS[idx]
            };
            buf.push_str(w);
            if buf.len() < FILE_SIZE { buf.push(' '); }
        }
        while buf.len() < FILE_SIZE { buf.push('\n'); }

        let path = PathBuf::from(DATA_DIR).join(format!("file{:03}.txt", i));
        std::fs::write(&path, buf.as_bytes())?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Count non-overlapping occurrences — SIMD via memchr::memmem
// ---------------------------------------------------------------------------
fn count_occurrences(data: &[u8], needle: &[u8]) -> i64 {
    memmem::find_iter(data, needle).count() as i64
}

// ---------------------------------------------------------------------------
// Result for sorting
// ---------------------------------------------------------------------------
#[derive(Clone)]
struct SearchResult {
    file_idx: usize,
    count: i64,
}

// ---------------------------------------------------------------------------
// main — Tokio async entry point
// ---------------------------------------------------------------------------
#[tokio::main]
async fn main() {
    generate_test_data().expect("generateTestData failed");

    // Pre-build paths (deterministic, not timed).
    let paths: Vec<PathBuf> = (0..N_FILES)
        .map(|i| PathBuf::from(DATA_DIR).join(format!("file{:03}.txt", i)))
        .collect();

    let t0 = Instant::now();

    // Spawn one Tokio task per file.  tokio::fs::read uses the blocking thread
    // pool internally so file reads run in parallel across CPU cores.
    let mut set = tokio::task::JoinSet::new();
    for (i, path) in paths.into_iter().enumerate() {
        set.spawn(async move {
            let data = tokio::fs::read(&path).await.unwrap_or_default();
            SearchResult { file_idx: i, count: count_occurrences(&data, NEEDLE.as_bytes()) }
        });
    }

    let mut results = Vec::with_capacity(N_FILES);
    while let Some(r) = set.join_next().await {
        results.push(r.expect("task panicked"));
    }

    // Sort by count descending.
    results.sort_by(|a, b| b.count.cmp(&a.count));

    let elapsed = t0.elapsed().as_secs_f64();

    println!("Top 10 files by '{}' count:", NEEDLE);
    for r in results.iter().take(10) {
        println!("  file{:03}.txt  {}", r.file_idx, r.count);
    }
    println!("Time: {:.4} s", elapsed);
}
