// Pub-Sub Benchmark -- Go
//
// 64 subscribers each independently generate and process 100K messages
// with CPU-bound work (2000 LCG iterations per message).
// Total work: 100K * 64 * 2000 = 12.8 billion LCG iterations.
//
// This matches the CLEAR pattern: each subscriber generates its own
// message sequence (no channels, no shared-memory broadcast).
// Measures: goroutine parallelism and scheduler efficiency.
//
// Build: go build -o bench_go .
// Run:   GOMAXPROCS=N ./bench_go

package main

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

const (
	nMessages    = 100_000
	nSubscribers = 64
	workPerMsg   = 2_000
)

func processMessage(seed uint64) uint64 {
	x := seed
	for i := 0; i < workPerMsg; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func subscriberWork(n uint64) uint64 {
	var total uint64
	for i := uint64(0); i < n; i++ {
		total += processMessage(i)
	}
	return total
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())

	var total atomic.Uint64
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < nSubscribers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result := subscriberWork(nMessages)
			total.Add(result)
		}()
	}

	wg.Wait()

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total.Load()%1_000_000_000)
	fmt.Printf("Messages: %d\n", nMessages)
	fmt.Printf("Subscribers: %d\n", nSubscribers)
	fmt.Printf("Time: %.0f ms\n", elapsed*1000)
}
