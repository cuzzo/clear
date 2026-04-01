// Fan-Out / Fan-In Benchmark — Go
//
// Spawns N workers (goroutines), each computes a CPU-bound result
// (iterated hash), then collects all results into a single sum.
//
// Tests: goroutine spawn overhead, channel throughput, fan-in latency.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"sync"
	"time"
)

const (
	nWorkers   = 10_000
	iterations = 100_000
)

// CPU-bound work: iterated LCG hash to prevent optimization.
func doWork(seed uint64) uint64 {
	x := seed
	for i := 0; i < iterations; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func main() {
	results := make([]uint64, nWorkers)
	var wg sync.WaitGroup

	t0 := time.Now()

	// Fan-out: spawn N workers
	for i := 0; i < nWorkers; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = doWork(uint64(idx))
		}(i)
	}

	// Fan-in: wait for all, sum results
	wg.Wait()

	var total uint64
	for _, r := range results {
		total += r
	}

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total%1_000_000_000)
	fmt.Printf("Workers: %d\n", nWorkers)
	fmt.Printf("Iterations: %d\n", iterations)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
