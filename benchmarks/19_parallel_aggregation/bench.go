// Parallel Aggregation Benchmark — Go
//
// Same LCG, same seed, same N and bucket count as CLEAR.
//
// Phase 1: Thread-local histograms (one per goroutine) + merge.
//   No locks, no shared state during counting.
//   This is the Go equivalent of CLEAR's SHARD pipeline — zero contention —
//   but requires explicit split/merge boilerplate (~30 lines vs 1 line).
//
// Phase 2: Parallel reduce over histogram values for sum/max/min/avg.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"math"
	"runtime"
	"sync"
	"time"
)

const (
	n       = 1_000_000
	buckets = 1_000
)

func lcg(state int64) int64 {
	return state*6364136223846793005 + 1442695040888963407
}

func main() {
	numWorkers := runtime.GOMAXPROCS(0)

	// Pre-compute seeds (LCG is sequential)
	seeds := make([]int64, n)
	seed := int64(42)
	for i := range seeds {
		seed = lcg(seed)
		seeds[i] = seed
	}

	// Phase 1: Thread-local histograms + merge
	t0 := time.Now()
	locals := make([]map[int64]int64, numWorkers)
	per := (n + numWorkers - 1) / numWorkers
	var wg sync.WaitGroup
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			start, end := w*per, (w+1)*per
			if end > n {
				end = n
			}
			local := make(map[int64]int64, buckets/numWorkers+1)
			for _, s := range seeds[start:end] {
				if s < 0 {
					s = -s
				}
				local[s%buckets]++
			}
			locals[w] = local
		}(w)
	}
	wg.Wait()
	counts := make(map[int64]int64, buckets)
	for _, local := range locals {
		for k, v := range local {
			counts[k] += v
		}
	}
	histTime := time.Since(t0)

	// Phase 2: Parallel stats over histogram values
	t1 := time.Now()
	vals := make([]float64, 0, len(counts))
	for _, v := range counts {
		vals = append(vals, float64(v))
	}
	type partial struct{ total, max, min float64 }
	parts := make([]partial, numWorkers)
	per2 := (len(vals) + numWorkers - 1) / numWorkers
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			start, end := w*per2, (w+1)*per2
			if end > len(vals) {
				end = len(vals)
			}
			if start >= len(vals) {
				return
			}
			p := partial{0, math.Inf(-1), math.Inf(1)}
			for _, v := range vals[start:end] {
				p.total += v
				if v > p.max {
					p.max = v
				}
				if v < p.min {
					p.min = v
				}
			}
			parts[w] = p
		}(w)
	}
	wg.Wait()
	var total, highest, lowest float64
	highest, lowest = math.Inf(-1), math.Inf(1)
	for _, p := range parts {
		total += p.total
		if p.max > highest {
			highest = p.max
		}
		if p.min < lowest {
			lowest = p.min
		}
	}
	average := total / float64(len(counts))
	statsTime := time.Since(t1)

	if int64(total) != n {
		panic("total mismatch")
	}

	fmt.Printf("Events: %d\n", n)
	fmt.Printf("Buckets: %d\n", buckets)
	fmt.Printf("Shard histogram: %.0f ms\n", histTime.Seconds()*1000)
	fmt.Printf("Aggregation: %.0f ms\n", statsTime.Seconds()*1000)
	fmt.Printf("Total: %.0f\n", total)
	fmt.Printf("Max: %.0f\n", highest)
	fmt.Printf("Min: %.0f\n", lowest)
	fmt.Printf("Avg: %.2f\n", average)
	fmt.Println("Verified: yes")
	fmt.Printf("BENCH_RESULT: %d ms\n", histTime.Milliseconds()+statsTime.Milliseconds())
}
