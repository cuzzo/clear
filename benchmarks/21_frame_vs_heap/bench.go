// Benchmark 21: Frame vs Heap Escape — Go Baseline
//
// Go strings are immutable heap objects. fmt.Sprintf always allocates.
// There is no "stack string" equivalent in Go — the GC handles all
// short-lived string allocations. This benchmark measures Go's GC
// overhead for the same workload that CLEAR handles with zero-cost
// frame allocation (bump pointer + rewind).
//
// Build: go build -o bench_go bench.go
// Run:   ./bench_go

package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"
)

const N = 1000000

func readMemory() (hwmKB, rssKB int64) {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmHWM:") {
			fmt.Sscanf(line, "VmHWM: %d kB", &hwmKB)
		} else if strings.HasPrefix(line, "VmRSS:") {
			fmt.Sscanf(line, "VmRSS: %d kB", &rssKB)
		}
	}
	return
}

func benchGC(n int) int64 {
	var total int64
	for i := 0; i < n; i++ {
		s := fmt.Sprintf("item-%d-value", i)
		total += int64(len(s))
	}
	return total
}

func main() {
	// Warm up
	benchGC(1000)

	t0 := time.Now()
	total := benchGC(N)
	elapsed := time.Since(t0)

	hwmKB, rssKB := readMemory()

	fmt.Printf("Frame vs Heap Escape (%d iterations) — Go baseline\n", N)
	fmt.Printf("  GC-managed strings: %.0f ms  RSS %d KB\n",
		float64(elapsed.Milliseconds()), rssKB)
	fmt.Printf("  Total length:       %d\n", total)
	fmt.Printf("  Peak RSS (VmHWM):   %d KB\n", hwmKB)
}
