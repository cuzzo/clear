// Concurrent-readers benchmark — Go.
// Mirrors bench_clear.zig: 1 writer + K readers, observe by view().
package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

const NWrites = 5_000_000

var readerCounts = []int{1, 4, 8}

// ---------------- atomic.Int64 (Go's "@observable" equivalent) ----------------

func runAtomic(nReaders int) {
	var counter atomic.Int64
	var stop atomic.Uint32

	readerN := make([]int, nReaders)

	var wg sync.WaitGroup
	totalSink := make([]int64, nReaders)
	for i := range readerN {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			n := 0
			var sink int64 = 0
			for stop.Load() == 0 {
				sink ^= counter.Load() // data-dependent so compiler can't elide
				n++
			}
			readerN[i] = n
			totalSink[i] = sink
		}()
	}

	t0 := time.Now()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < NWrites; i++ {
			counter.Add(1)
		}
		stop.Store(1)
	}()
	wg.Wait()
	elapsed := time.Since(t0)

	totalReads := 0
	for _, n := range readerN {
		totalReads += n
	}
	nsPerInc := elapsed.Nanoseconds() / NWrites
	readsPerSec := int64(0)
	if elapsed.Nanoseconds() > 0 {
		readsPerSec = int64(totalReads) * 1_000_000_000 / elapsed.Nanoseconds()
	}
	fmt.Printf("[Go atomic.Int64]    writer=%3d ns/inc  readers=%d  total_reads=%d  reads/sec=%d\n",
		nsPerInc, nReaders, totalReads, readsPerSec)
	if counter.Load() != int64(NWrites) {
		fmt.Printf("  !! counter view %d != expected %d\n", counter.Load(), NWrites)
	}
	// keep totalSink alive so the compiler can't elide the data-dependent reads
	var sinkSum int64 = 0
	for _, s := range totalSink {
		sinkSum ^= s
	}
	if sinkSum == 0xdeadbeef {
		fmt.Println("  (sink check)")
	}
}

// ---------------- sync.Mutex<int64> (Go's "@locked Int64" equivalent) ----------------

type LockedI64 struct {
	mu  sync.Mutex
	val int64
}

func (l *LockedI64) Add(n int64) {
	l.mu.Lock()
	l.val += n
	l.mu.Unlock()
}

func (l *LockedI64) View() int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.val
}

func runLocked(nReaders int) {
	var counter LockedI64
	var stop atomic.Uint32

	readerN := make([]int, nReaders)
	totalSink := make([]int64, nReaders)

	var wg sync.WaitGroup
	for i := range readerN {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			n := 0
			var sink int64 = 0
			for stop.Load() == 0 {
				sink ^= counter.View()
				n++
			}
			readerN[i] = n
			totalSink[i] = sink
		}()
	}

	t0 := time.Now()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < NWrites; i++ {
			counter.Add(1)
		}
		stop.Store(1)
	}()
	wg.Wait()
	elapsed := time.Since(t0)

	totalReads := 0
	for _, n := range readerN {
		totalReads += n
	}
	nsPerInc := elapsed.Nanoseconds() / NWrites
	readsPerSec := int64(0)
	if elapsed.Nanoseconds() > 0 {
		readsPerSec = int64(totalReads) * 1_000_000_000 / elapsed.Nanoseconds()
	}
	fmt.Printf("[Go sync.Mutex]      writer=%3d ns/inc  readers=%d  total_reads=%d  reads/sec=%d\n",
		nsPerInc, nReaders, totalReads, readsPerSec)
	if counter.View() != int64(NWrites) {
		fmt.Printf("  !! counter view %d != expected %d\n", counter.View(), NWrites)
	}
	var sinkSum int64 = 0
	for _, s := range totalSink {
		sinkSum ^= s
	}
	if sinkSum == 0xdeadbeef {
		fmt.Println("  (sink check)")
	}
}

func main() {
	fmt.Printf("Concurrent observable benchmark — Go — N=%d writes, readers=%v\n", NWrites, readerCounts)
	for _, k := range readerCounts {
		runAtomic(k)
	}
	fmt.Println()
	for _, k := range readerCounts {
		runLocked(k)
	}
}
