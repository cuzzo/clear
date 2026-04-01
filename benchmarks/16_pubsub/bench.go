// Pub-Sub Benchmark — Go
//
// 1 publisher sends 100K messages to N subscribers via buffered channels.
// Each subscriber processes the message with CPU-bound work (LCG hash).
// Measures: channel broadcast latency, goroutine scheduling, fan-out overhead.
//
// This models a market-data ticker: one source, many consumers, each
// doing independent work on every message.
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
	nMessages    = 100_000
	nSubscribers = 64
	workPerMsg   = 200 // LCG iterations per message per subscriber
	chanBuf      = 256
)

// CPU-bound work: iterated LCG hash.
func processMessage(seed uint64) uint64 {
	x := seed
	for i := 0; i < workPerMsg; i++ {
		x = x*6364136223846793005 + 1442695040888963407
	}
	return x
}

func main() {
	runtime.GOMAXPROCS(runtime.NumCPU())

	// Create subscriber channels
	channels := make([]chan uint64, nSubscribers)
	for i := range channels {
		channels[i] = make(chan uint64, chanBuf)
	}

	var total atomic.Uint64
	var wg sync.WaitGroup

	t0 := time.Now()

	// Spawn subscribers
	for i := 0; i < nSubscribers; i++ {
		wg.Add(1)
		go func(ch chan uint64) {
			defer wg.Done()
			var localSum uint64
			for msg := range ch {
				localSum += processMessage(msg)
			}
			total.Add(localSum)
		}(channels[i])
	}

	// Publisher: broadcast each message to all subscribers
	for msg := uint64(0); msg < nMessages; msg++ {
		for _, ch := range channels {
			ch <- msg
		}
	}

	// Close all channels to signal completion
	for _, ch := range channels {
		close(ch)
	}

	wg.Wait()

	elapsed := time.Since(t0).Seconds()
	fmt.Printf("Checksum: %d\n", total.Load()%1_000_000_000)
	fmt.Printf("Messages: %d\n", nMessages)
	fmt.Printf("Subscribers: %d\n", nSubscribers)
	fmt.Printf("Time: %.4f s\n", elapsed)
}
