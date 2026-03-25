// Concurrent File Search — Rust Benchmark
//
// One OS thread per file via std::thread::spawn.
// Unlike CLEAR fibers (~2KB) or Go goroutines (~8KB starting), OS threads
// have an 8MB stack reservation — higher per-task memory overhead but
// full OS-level parallelism without a userspace scheduler.
//
// For closer comparison to CLEAR/Go's M:N model, use Rayon or Tokio.
// This version uses only std (no external dependencies) for simplicity.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust
// Run:   ./bench_rust

use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Instant;

const N_FILES: usize = 128;
const FILE_SIZE: usize = 10 * 1024;
const NEEDLE: &str = "the";
const DATA_DIR: &str = "benchmarks/10_concurrent_search/data";

// ---------------------------------------------------------------------------
// Deterministic pseudo-random u64 (LCG, same seed as Go/Zig versions)
// ---------------------------------------------------------------------------
struct Lcg(u64);

impl Lcg {
    fn new(seed: u64) -> Self {
        Lcg(seed)
    }
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0
    }
    fn next_usize(&mut self, n: usize) -> usize {
        (self.next_u64() >> 33) as usize % n
    }
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
    fs::create_dir_all(DATA_DIR)?;
    let existing = fs::read_dir(DATA_DIR)?.count();
    if existing >= N_FILES {
        return Ok(());
    }

    for i in 0..N_FILES {
        let mut rng = Lcg::new((i as u64).wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407));
        let mut buf = String::with_capacity(FILE_SIZE + 8);

        while buf.len() + 6 < FILE_SIZE {
            let w = if rng.next_usize(N_FILES) < i {
                "the"
            } else {
                // pick from words except "the" (index 38)
                let mut idx = rng.next_usize(WORDS.len() - 1);
                if idx >= 38 { idx += 1; }
                WORDS[idx]
            };
            buf.push_str(w);
            if buf.len() < FILE_SIZE {
                buf.push(' ');
            }
        }
        while buf.len() < FILE_SIZE {
            buf.push('\n');
        }

        let path = PathBuf::from(DATA_DIR).join(format!("file{:03}.txt", i));
        fs::write(&path, buf.as_bytes())?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Count non-overlapping occurrences of needle in haystack
// ---------------------------------------------------------------------------
fn count_occurrences(haystack: &str, needle: &str) -> i64 {
    if needle.is_empty() { return 0; }
    let nb = needle.as_bytes();
    let hb = haystack.as_bytes();
    let mut count = 0i64;
    let mut pos = 0usize;
    while pos + nb.len() <= hb.len() {
        if hb[pos..].starts_with(nb) {
            count += 1;
            pos += nb.len();
        } else {
            pos += 1;
        }
    }
    count
}

// ---------------------------------------------------------------------------
// Result for sorting
// ---------------------------------------------------------------------------
#[derive(Clone)]
struct Result {
    file_idx: usize,
    count: i64,
}

fn main() {
    // Generate test data (not timed)
    generate_test_data().expect("generateTestData failed");

    let t0 = Instant::now();

    // Spawn one thread per file
    let handles: Vec<_> = (0..N_FILES)
        .map(|i| {
            thread::spawn(move || {
                let path = PathBuf::from(DATA_DIR).join(format!("file{:03}.txt", i));
                let data = fs::read_to_string(&path).unwrap_or_default();
                Result {
                    file_idx: i,
                    count: count_occurrences(&data, NEEDLE),
                }
            })
        })
        .collect();

    let mut results: Vec<Result> = handles
        .into_iter()
        .map(|h| h.join().expect("thread panicked"))
        .collect();

    // Sort by count descending
    results.sort_by(|a, b| b.count.cmp(&a.count));

    let elapsed = t0.elapsed().as_secs_f64();

    // Print top-10
    println!("Top 10 files by '{}' count:", NEEDLE);
    for r in results.iter().take(10) {
        println!("  file{:03}.txt  {}", r.file_idx, r.count);
    }
    println!("Time: {:.4} s", elapsed);
}
