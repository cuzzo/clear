// Concurrent File Search — Go Benchmark
//
// One goroutine per file. Go's runtime schedules goroutines across
// GOMAXPROCS OS threads (default = num_cpu), giving true parallelism.
//
// Goroutine stack: starts at ~2KB, grows on demand (unlike OS threads).
// M:N scheduler: many goroutines multiplexed over N OS threads.
//
// Build: go build -o bench_go .   (from this directory)
// Run:   ./bench_go

package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	nFiles   = 128
	fileSize = 10 * 1024 // 10 KB
	needle   = "the"
	dataDir  = "benchmarks/10_concurrent_search/data"
)

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

		path := filepath.Join(dataDir, fmt.Sprintf("file%03d.txt", i))
		if err := os.WriteFile(path, []byte(sb.String()), 0644); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Count non-overlapping occurrences of needle in s
// ---------------------------------------------------------------------------
func countOccurrences(s, needle string) int {
	if len(needle) == 0 {
		return 0
	}
	count := 0
	pos := 0
	for pos+len(needle) <= len(s) {
		if strings.HasPrefix(s[pos:], needle) {
			count++
			pos += len(needle)
		} else {
			pos++
		}
	}
	return count
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

	t0 := time.Now()

	// Spawn one goroutine per file
	results := make([]Result, nFiles)
	var wg sync.WaitGroup

	for i := 0; i < nFiles; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			path := filepath.Join(dataDir, fmt.Sprintf("file%03d.txt", idx))
			data, err := os.ReadFile(path)
			if err != nil {
				results[idx] = Result{fileIdx: idx, count: 0}
				return
			}
			results[idx] = Result{fileIdx: idx, count: countOccurrences(string(data), needle)}
		}(i)
	}
	wg.Wait()

	// Sort by count descending
	sort.Slice(results, func(i, j int) bool {
		return results[i].count > results[j].count
	})

	elapsed := time.Since(t0).Seconds()

	// Print top-10
	fmt.Printf("Top 10 files by '%s' count:\n", needle)
	top := 10
	if top > len(results) {
		top = len(results)
	}
	for _, r := range results[:top] {
		fmt.Printf("  file%03d.txt  %d\n", r.fileIdx, r.count)
	}
	fmt.Printf("Time: %.4f s\n", elapsed)
}
