// Dynamic Spawn Benchmark — Go
//
// Spawns 100K goroutines, each does trivial work (return its index).
// Measures pure spawn + collect overhead with minimal CPU work.
// This is the worst case for per-spawn allocation overhead.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"sync"
	"time"
)

const nTasks = 10_000

func main() {
	results := make([]int64, nTasks)
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < nTasks; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = int64(idx) * 3
		}(i)
	}
	wg.Wait()

	var total int64
	for _, r := range results {
		total += r
	}

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Total: %d\n", total)
	fmt.Printf("Tasks: %d\n", nTasks)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
