// Stream Merge Benchmark — Go
//
// 8 producer goroutines each generate 10K values (LCG sequence).
// 1 consumer goroutine reads from a shared channel, sums all values.
// Total: 80K values merged from 8 streams.
//
// Tests: channel throughput, goroutine yield/resume, fan-in merge.
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"time"
)

const (
	nProducers    = 8
	itemsPerProd  = 100_000
)

func producer(ch chan<- int64, seed int64) {
	x := seed
	for i := 0; i < itemsPerProd; i++ {
		x = x*6364136223846793005 + 1442695040888963407
		ch <- x
	}
}

func main() {
	ch := make(chan int64, 64)

	t0 := time.Now()

	// Start producers
	for i := 0; i < nProducers; i++ {
		go producer(ch, int64(i+1))
	}

	// Consumer counts expected messages
	var total int64
	expected := nProducers * itemsPerProd
	for i := 0; i < expected; i++ {
		total += <-ch
	}

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total%1_000_000_000)
	fmt.Printf("Producers: %d\n", nProducers)
	fmt.Printf("Items per producer: %d\n", itemsPerProd)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
