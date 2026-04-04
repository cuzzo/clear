// Dynamic Spawn Benchmark — Go
//
// Spawns 100K goroutines, each does CPU-bound work (10K LCG iterations).
// Measures goroutine spawn overhead + parallel execution.
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
	nTasks     = 100_000
	iterations = 10_000
)

func doWork(seed int64) int64 {
	x := seed
	for i := 0; i < iterations; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func main() {
	results := make([]int64, nTasks)
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < nTasks; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = doWork(int64(idx))
		}(i)
	}
	wg.Wait()

	var total int64
	for _, r := range results {
		total += r
	}

	elapsed := time.Since(t0).Seconds()
	checksum := total % 1_000_000_000
	if checksum < 0 { checksum += 1_000_000_000 }
	fmt.Printf("Checksum: %d\n", checksum)
	fmt.Printf("Tasks: %d\n", nTasks)
	fmt.Printf("Iterations: %d\n", iterations)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
