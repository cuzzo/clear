// Pub-Sub Benchmark — Go
//
// 1 publisher goroutine fans out 100K messages to 64 subscribers.
// Each subscriber has its own buffered channel (cap 64).
// Publisher sends to all 64 channels sequentially per message.
// Each subscriber processes every message (2000 LCG iterations).
// Total work: 100K * 64 * 2000 = 12.8 billion LCG iterations.
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
	nMessages    = 10_000
	nSubscribers = 64
	workPerMsg   = 2_000
	chanCap      = 64
)

func processMessage(seed int64) int64 {
	x := seed
	for i := 0; i < workPerMsg; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func main() {
	channels := make([]chan int64, nSubscribers)
	for i := range channels {
		channels[i] = make(chan int64, chanCap)
	}

	var total atomic.Int64
	var wg sync.WaitGroup

	t0 := time.Now()

	// Start subscribers
	for i := 0; i < nSubscribers; i++ {
		wg.Add(1)
		ch := channels[i]
		go func() {
			defer wg.Done()
			var sum int64
			for seed := range ch {
				sum += processMessage(seed)
			}
			total.Add(sum)
		}()
	}

	// Publisher: fan-out each message to all subscribers
	for i := int64(0); i < nMessages; i++ {
		for _, ch := range channels {
			ch <- i
		}
	}
	for _, ch := range channels {
		close(ch)
	}

	wg.Wait()

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total.Load()%1_000_000_000)
	fmt.Printf("Messages: %d\n", int64(nMessages))
	fmt.Printf("Subscribers: %d\n", nSubscribers)
	fmt.Printf("BENCH_RESULT: %d ms\n", int64(elapsed*1000))
	fmt.Printf("Time: %.0f ms\n", elapsed*1000)
}
