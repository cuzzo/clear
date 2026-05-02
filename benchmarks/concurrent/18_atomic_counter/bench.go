// Atomic Counter Benchmark — Go
//
// 8 goroutines each perform 1M atomic.AddInt64 ops on a shared int64.
// Total expected: 8 * 1M = 8M.
//
// Go's sync/atomic.AddInt64 lowers to LOCK XADDQ on x86 — sequentially
// consistent (full memory barrier). The contended cache line bounces
// between L1s on every increment.
//
// Build: go build -o bench_go bench.go
// Run:   ./bench_go

package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

const (
	nWorkers   = 8
	iterations = 1_000_000
)

func main() {
	var counter int64
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < nWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				atomic.AddInt64(&counter, 1)
			}
		}()
	}
	wg.Wait()

	elapsed := time.Since(t0).Milliseconds()
	total := atomic.LoadInt64(&counter)

	fmt.Printf("Counter: %d (expected %d)\n", total, int64(nWorkers)*int64(iterations))
	fmt.Printf("BENCH_RESULT: %d ms\n", elapsed)
	fmt.Printf("Time: %d ms\n", elapsed)
}
