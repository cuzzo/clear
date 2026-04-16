// Concurrent File Search — Go Benchmark  (idiomatic / optimised)
//
// One goroutine per file. Go's runtime schedules goroutines across
// GOMAXPROCS OS threads (default = num_cpu), giving true M:N parallelism.
//
// Goroutine stack: starts at ~2KB, grows on demand (unlike OS threads).
//
// Optimisations vs. naive version:
//   - bytes.Count instead of string(data) + strings.HasPrefix loop.
//     The string(data) cast copied every file from []byte → string (1.28 MB
//     total); bytes.Count works on the original []byte with zero copies.
//   - needleBytes hoisted to a package-level []byte — one alloc, not 128.
//   - File paths pre-built before t0 so fmt.Sprintf isn't in the hot path.
//
// Build: go build -o bench_go .   (from this directory)
// Run:   ./bench_go

package main

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	nFiles   = 2000
	fileSize = 10 * 1024 // 10 KB
	needle   = "the"
	dataDir  = "benchmarks/10_concurrent_search/data"
)

// Pre-computed once; no per-goroutine allocation.
var needleBytes = []byte(needle)

// ---------------------------------------------------------------------------
// Generate test data (idempotent — skips if N_FILES already exist)
// ---------------------------------------------------------------------------
var words = []string{
	"a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
	"do", "for", "from", "had", "has", "have", "he", "her", "him", "his",
	"in", "is", "it", "its", "may", "me", "my", "no", "not", "of",
	"on", "or", "our", "out", "she", "so", "than", "that", "the", "their",
	"them", "then", "there", "they", "this", "to", "up", "was", "we", "were",
	"when", "which", "who", "will", "with", "would", "you", "your", "time", "way",
}

func generateTestData() error {
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return err
	}
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return err
	}
	if len(entries) >= nFiles {
		return nil // already generated
	}

	for i := 0; i < nFiles; i++ {
		rng := rand.New(rand.NewSource(int64(i)*6364136223846793005 + 1442695040888963407))
		var sb strings.Builder
		sb.Grow(fileSize)

		for sb.Len()+6 < fileSize {
			var w string
			if rng.Intn(nFiles) < i {
				w = "the"
			} else {
				// pick from words except "the" (index 38)
				idx := rng.Intn(len(words) - 1)
				if idx >= 38 {
					idx++
				}
				w = words[idx]
			}
			sb.WriteString(w)
			if sb.Len() < fileSize {
				sb.WriteByte(' ')
			}
		}
		for sb.Len() < fileSize {
			sb.WriteByte('\n')
		}

		path := fmt.Sprintf("%s/file%04d.txt", dataDir, i)
		if err := os.WriteFile(path, []byte(sb.String()), 0644); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Result for sorting
// ---------------------------------------------------------------------------
type Result struct {
	fileIdx int
	count   int
}

func main() {
	// Generate test data (not timed)
	if err := generateTestData(); err != nil {
		fmt.Fprintf(os.Stderr, "generateTestData: %v\n", err)
		os.Exit(1)
	}

	// Pre-build all file paths — deterministic, no Sprintf in the hot path.
	paths := make([]string, nFiles)
	for i := 0; i < nFiles; i++ {
		paths[i] = fmt.Sprintf("%s/file%04d.txt", dataDir, i)
	}

	t0 := time.Now()

	// Spawn one goroutine per file.
	results := make([]Result, nFiles)
	var wg sync.WaitGroup

	for i := 0; i < nFiles; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			data, err := os.ReadFile(paths[idx])
			if err != nil {
				results[idx] = Result{fileIdx: idx, count: 0}
				return
			}
			// bytes.Count: no string copy, no manual loop, SIMD-accelerated on amd64.
			results[idx] = Result{fileIdx: idx, count: bytes.Count(data, needleBytes)}
		}(i)
	}
	wg.Wait()

	// Sort by count descending.
	sort.Slice(results, func(i, j int) bool {
		return results[i].count > results[j].count
	})

	elapsed := time.Since(t0).Seconds()

	// Print top-10.
	fmt.Printf("Top 10 files by '%s' count:\n", needle)
	top := 10
	if top > len(results) {
		top = len(results)
	}
	for _, r := range results[:top] {
		fmt.Printf("  file%04d.txt  %d\n", r.fileIdx, r.count)
	}
	fmt.Printf("BENCH_RESULT: %d ms\n", int64(elapsed*1000))
	fmt.Printf("Time: %.4f s\n", elapsed)
}
