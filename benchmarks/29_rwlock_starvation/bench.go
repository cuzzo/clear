// RwLock Writer Starvation Benchmark -- Go
//
// Demonstrates Go's sync.RWMutex writer starvation under heavy read load.
// Go's RWMutex is reader-preferring: new readers can acquire the lock
// even while a writer is waiting, so a steady stream of overlapping
// readers can starve writers indefinitely.
//
// Setup:
//   - N reader goroutines each hold RLock for ~1us (simulated work), loop M times
//   - 1 writer goroutine attempts to acquire Lock, loop W times
//   - Measure: writer completion time, reader completion time, max writer wait
//
// Build: go build -o bench_go bench.go

package main

import (
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

const (
	readIters  = 2_000_000
	writeIters = 1_000
	workPerOp  = 100 // iterations of busywork per lock hold
)

func busyWork(n int) int64 {
	var acc int64
	for i := 0; i < n; i++ {
		acc += int64(i)
	}
	return acc
}

func main() {
	nCPU := runtime.NumCPU()
	runtime.GOMAXPROCS(nCPU)
	nReaders := nCPU - 1
	if nReaders < 1 {
		nReaders = 1
	}

	var rw sync.RWMutex
	var sharedData int64
	var sink atomic.Int64 // prevent dead-code elimination

	var wg sync.WaitGroup

	t0 := time.Now()

	// Spawn readers
	for r := 0; r < nReaders; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < readIters; i++ {
				rw.RLock()
				v := sharedData
				sink.Add(busyWork(workPerOp))
				_ = v
				rw.RUnlock()
			}
		}()
	}

	// Spawn writer -- measure per-write latency
	var writerDone time.Duration
	var maxWriteWait time.Duration
	var totalWriteWait time.Duration
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < writeIters; i++ {
			wt0 := time.Now()
			rw.Lock()
			waited := time.Since(wt0)
			if waited > maxWriteWait {
				maxWriteWait = waited
			}
			totalWriteWait += waited
			sharedData++
			sink.Add(busyWork(workPerOp))
			rw.Unlock()
		}
		writerDone = time.Since(t0)
	}()

	wg.Wait()
	elapsed := time.Since(t0)

	avgWriteWait := totalWriteWait / time.Duration(writeIters)

	fmt.Printf("Readers:        %d\n", nReaders)
	fmt.Printf("Read iters:     %d per reader\n", readIters)
	fmt.Printf("Write iters:    %d\n", writeIters)
	fmt.Printf("Total time:     %d ms\n", elapsed.Milliseconds())
	fmt.Printf("Writer done:    %d ms\n", writerDone.Milliseconds())
	fmt.Printf("Avg write wait: %d us\n", avgWriteWait.Microseconds())
	fmt.Printf("Max write wait: %d us\n", maxWriteWait.Microseconds())
	fmt.Printf("Final value:    %d\n", sharedData)
	fmt.Printf("Sink:           %d\n", sink.Load())
}
