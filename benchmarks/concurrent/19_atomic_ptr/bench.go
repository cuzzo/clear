// AtomicPtr (M3) benchmark — Go.
//
// Same producer-consumer config swap workload as the CLEAR bench:
// 1 writer publishes a Counter via atomic.Pointer[Counter]; N readers
// each load the pointer reads_per times and verify the structural
// invariant `b == a * 2`. Compares the M3 @indirect:atomic surface
// against Go's standard `sync/atomic.Pointer[T]` (Go 1.19+).
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
	nReaders  = 16
	readsPer  = 50_000
	writes    = 5_000
)

type Counter struct {
	A int64
	B int64
}

func main() {
	var p atomic.Pointer[Counter]
	p.Store(&Counter{A: 0, B: 0})

	var wg sync.WaitGroup
	violations := int64(0)
	var vlock sync.Mutex

	t0 := time.Now()

	// Readers
	for i := 0; i < nReaders; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			localViol := int64(0)
			for j := 0; j < readsPer; j++ {
				c := p.Load()
				// Verify the structural invariant b == 2*a.
				if c.B != c.A*2 {
					localViol++
				}
			}
			if localViol > 0 {
				vlock.Lock()
				violations += localViol
				vlock.Unlock()
			}
		}()
	}

	// Writer: rcu-style. Load, clone with mutated fields, CAS.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for k := 0; k < writes; k++ {
			for {
				old := p.Load()
				next := &Counter{A: old.A + 1, B: (old.A + 1) * 2}
				if p.CompareAndSwap(old, next) {
					break
				}
			}
		}
	}()

	wg.Wait()
	elapsed := time.Since(t0).Seconds()

	final := p.Load()
	fmt.Printf("Counter: a=%d b=%d (violations: %d)\n", final.A, final.B, violations)
	fmt.Printf("BENCH_RESULT: %d ms\n", int64(elapsed*1000))
	fmt.Printf("Time: %.4f s\n", elapsed)
}
