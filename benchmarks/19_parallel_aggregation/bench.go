// Parallel Aggregation Benchmark — Distributed Histogram + Stats (Go)
//
// Same LCG, same seed, same N as CLEAR.
// go build -o bench_go bench.go && ./bench_go

package main

import (
	"fmt"
	"math"
	"time"
)

func lcg(state int64) int64 {
	return state*6364136223846793005 + 1442695040888963407
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

func main() {
	n := int64(100_000)
	buckets := int64(10_000)
	seed := int64(42)

	start := time.Now()

	// Phase 1: Build histogram
	counts := make(map[string]int64)
	for i := int64(0); i < n; i++ {
		seed = lcg(seed)
		bucket := abs64(seed) % buckets
		key := fmt.Sprintf("b:%d", bucket)
		counts[key]++
	}

	// Phase 2: Stats over histogram values
	total := 0.0
	highest := math.Inf(-1)
	lowest := math.Inf(1)
	for _, v := range counts {
		fv := float64(v)
		total += fv
		if fv > highest {
			highest = fv
		}
		if fv < lowest {
			lowest = fv
		}
	}
	average := total / float64(len(counts))

	elapsed := time.Since(start)

	if int64(total) != n {
		panic("total mismatch")
	}

	fmt.Printf("Events: %d\n", n)
	fmt.Printf("Buckets: %d\n", buckets)
	fmt.Printf("Total: %.0f\n", total)
	fmt.Printf("Max: %.0f\n", highest)
	fmt.Printf("Min: %.0f\n", lowest)
	fmt.Printf("Avg: %.0f\n", average)
	fmt.Println("Verified: yes")
	fmt.Printf("BENCH_RESULT: %d ms\n", elapsed.Milliseconds())
	fmt.Printf("Time: %.4f s\n", elapsed.Seconds())
}
