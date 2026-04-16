// False Sharing Benchmark -- Go
//
// N goroutines each increment their own counter M times.
// Three configurations:
//   1. PACKED:     adjacent int64s in a slice (false sharing)
//   2. PADDED:     each counter in a 64-byte struct (no false sharing)
//   3. HEAP-ALLOC: each counter is a separate *int64 (like Arc -- no false sharing)
//
// Build: go build -o bench_go .

package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

const totalWork = 40_000_000

type PaddedCounter struct {
	value int64
	_     [56]byte // pad to 64 bytes
}

func runPacked(nThreads int, increments int) time.Duration {
	counters := make([]int64, nThreads)
	var wg sync.WaitGroup

	t0 := time.Now()
	for t := 0; t < nThreads; t++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < increments; i++ {
				counters[id]++
			}
		}(t)
	}
	wg.Wait()
	elapsed := time.Since(t0)

	var total int64
	for _, v := range counters {
		total += v
	}
	if total != int64(nThreads)*int64(increments) {
		panic("packed total mismatch")
	}
	return elapsed
}

func runPadded(nThreads int, increments int) time.Duration {
	counters := make([]PaddedCounter, nThreads)
	var wg sync.WaitGroup

	t0 := time.Now()
	for t := 0; t < nThreads; t++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < increments; i++ {
				counters[id].value++
			}
		}(t)
	}
	wg.Wait()
	elapsed := time.Since(t0)

	var total int64
	for _, c := range counters {
		total += c.value
	}
	if total != int64(nThreads)*int64(increments) {
		panic("padded total mismatch")
	}
	return elapsed
}

func runHeapAlloc(nThreads int, increments int) time.Duration {
	// Each counter is a separate heap allocation (like Arc/shared)
	counters := make([]*int64, nThreads)
	for i := range counters {
		counters[i] = new(int64)
	}
	var wg sync.WaitGroup

	t0 := time.Now()
	for t := 0; t < nThreads; t++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			ptr := counters[id]
			for i := 0; i < increments; i++ {
				*ptr++
			}
		}(t)
	}
	wg.Wait()
	elapsed := time.Since(t0)

	var total int64
	for _, ptr := range counters {
		total += *ptr
	}
	if total != int64(nThreads)*int64(increments) {
		panic("heap-alloc total mismatch")
	}
	return elapsed
}

func main() {
	nThreads := runtime.NumCPU()
	runtime.GOMAXPROCS(nThreads)
	increments := totalWork / nThreads

	// Warm up
	runPacked(nThreads, increments)
	runPadded(nThreads, increments)
	runHeapAlloc(nThreads, increments)

	packedMs := float64(runPacked(nThreads, increments).Milliseconds())
	paddedMs := float64(runPadded(nThreads, increments).Milliseconds())
	heapMs := float64(runHeapAlloc(nThreads, increments).Milliseconds())

	// BENCH_RESULT = heap-alloc (separate allocs, closest to CLEAR @shared)
	fmt.Printf("BENCH_RESULT: %.0f ms\n", heapMs)
	fmt.Printf("False-sharing (%d threads x %d iters)\n", nThreads, increments)
	fmt.Printf("  Packed (false sharing):  %.1f ms\n", packedMs)
	fmt.Printf("  Padded (no false share): %.1f ms\n", paddedMs)
	fmt.Printf("  Heap-alloc (like @shared): %.1f ms\n", heapMs)
	fmt.Printf("  Slowdown:                %.1fx  (packed / padded)\n", packedMs/paddedMs)
}
