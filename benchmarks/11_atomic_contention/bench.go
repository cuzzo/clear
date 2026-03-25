// Atomic Contention Benchmark — Go
//
// 1024 goroutines each increment a shared atomic counter 10 000 times.
// Total expected: 10 240 000.
//
// Go's M:N scheduler spreads goroutines across GOMAXPROCS cores.  The
// atomic counter's cache line bounces between L1 caches on every
// increment — the "parallelism tax" for shared mutable state.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

const (
	nFibers    = 1024
	increments = 10_000
)

func main() {
	var counter int64
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < nFibers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < increments; j++ {
				atomic.AddInt64(&counter, 1)
			}
		}()
	}
	wg.Wait()

	elapsed := time.Since(t0).Seconds()
	total := atomic.LoadInt64(&counter)

	fmt.Printf("Counter: %d (expected %d)\n", total, int64(nFibers)*int64(increments))
	fmt.Printf("Time: %.4f s\n", elapsed)
}
