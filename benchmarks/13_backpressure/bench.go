// Backpressure Benchmark — Go
//
// Producer sends 100,000 items through a bounded channel (capacity 64).
// 8 consumer goroutines process each item (CPU work: 500 LCG iterations).
// Producer blocks when the channel is full — real backpressure.
//
// Tests: bounded channel throughput, producer blocking latency,
// goroutine scheduling under sustained load.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

const (
	totalItems  = 100_000
	chanCap     = 64
	workPerItem = 5_000
)

func processItem(val uint64) uint64 {
	x := val
	for i := 0; i < workPerItem; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func main() {
	ch := make(chan uint64, chanCap)
	var total atomic.Uint64
	var wg sync.WaitGroup

	t0 := time.Now()

	// Start consumers — scale with available cores
	nConsumers := runtime.GOMAXPROCS(0)
	for c := 0; c < nConsumers; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for val := range ch {
				result := processItem(val)
				total.Add(result)
			}
		}()
	}

	// Producer: send items (blocks when channel full)
	for i := uint64(0); i < totalItems; i++ {
		ch <- i // Blocks if consumers are slower than producer
	}
	close(ch)

	wg.Wait()

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total.Load()%1_000_000_000)
	fmt.Printf("Items: %d\n", totalItems)
	fmt.Printf("Workers: %d\n", nConsumers)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
