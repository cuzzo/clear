// Footgun: Memory Ordering — Go
//
// Go deliberately does NOT expose memory ordering knobs.
// sync/atomic operations are always sequentially consistent under
// Go's memory model: every atomic operation synchronizes with every
// other atomic operation on the same variable in program order.
//
// This means Go cannot express the "relaxed publish flag" bug from C/Rust.
// The tradeoff: you can't accidentally use Relaxed where you need Acquire,
// but you also can't use Relaxed for performance-sensitive counters where
// SC ordering is unnecessary overhead.
//
// Go's memory model has one subtle footgun of its own: using plain reads
// and writes (non-atomic) as a "fast path" before an atomic. This is a
// data race and undefined behavior in Go, even on x86.

package main

import (
	"fmt"
	"sync"
	"sync/atomic"
)

// SAFE: Go's atomic.Store/Load are always sequentially consistent.
// There is no way to get memory ordering wrong with sync/atomic.
func publishFlag() {
	var message [64]byte
	var ready int32

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		copy(message[:], "hello from producer")
		atomic.StoreInt32(&ready, 1) // SC: all prior writes visible
	}()

	go func() {
		defer wg.Done()
		for atomic.LoadInt32(&ready) == 0 { // SC: sees the store
			// spin
		}
		// Guaranteed to see "hello from producer" on all architectures.
		fmt.Printf("saw: %s\n", message[:19])
	}()

	wg.Wait()
}

// FOOTGUN: non-atomic read used as "fast path" — this IS a data race.
// The compiler and CPU may both reorder or cache the read of `flag`.
// On real hardware this can cause an infinite loop or stale reads.
func nonAtomicFastPath() {
	var flag int32 // NOT atomic
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		flag = 1 // plain write: data race
	}()

	go func() {
		defer wg.Done()
		for flag == 0 { // plain read: data race — may never see update
			// spin — compiler may hoist this out of the loop
		}
		fmt.Println("saw flag (lucky — this is a data race)")
	}()

	wg.Wait()
}

func main() {
	fmt.Println("--- safe: sync/atomic (always SC in Go) ---")
	publishFlag()

	fmt.Println("--- footgun: plain read/write instead of atomic ---")
	nonAtomicFastPath()
	// Run with: go run -race main.go
	// The nonAtomicFastPath will be flagged: WARNING: DATA RACE
}
