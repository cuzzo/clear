// Footgun: Deadlock — Go
//
// Go's sync.Mutex blocks the goroutine forever on deadlock. The runtime
// detects when ALL goroutines are blocked (a "global" deadlock) and panics
// with "all goroutines are asleep — deadlock!". But it does NOT detect
// partial deadlocks (a subset of goroutines deadlocked while others run).
//
// In practice, server programs always have goroutines running (the HTTP
// listener, timers, etc.), so a partial deadlock hangs silently — the server
// stops serving some requests but keeps running. The only evidence is in
// `go tool pprof` goroutine dumps or runtime/pprof block profiling.
//
// Go's race detector (-race) does not detect deadlocks, only data races.

package main

import (
	"fmt"
	"sync"
	"time"
)

// BROKEN: AB / BA lock order — deadlock.
// Not run in main(); shown for illustration.
func broken() {
	var muA, muB sync.Mutex

	go func() {
		muA.Lock()
		fmt.Println("g1: acquired A")
		time.Sleep(1 * time.Millisecond)
		fmt.Println("g1: waiting for B...")
		muB.Lock() // blocks: g2 holds B
		fmt.Println("g1: acquired B (never reached)")
		muB.Unlock()
		muA.Unlock()
	}()

	go func() {
		muB.Lock()
		fmt.Println("g2: acquired B")
		time.Sleep(1 * time.Millisecond)
		fmt.Println("g2: waiting for A...")
		muA.Lock() // blocks: g1 holds A — DEADLOCK
		fmt.Println("g2: acquired A (never reached)")
		muA.Unlock()
		muB.Unlock()
	}()

	// These joins would hang:
	// wg.Wait()
}

// CORRECT: consistent lock order — always A before B.
func correct() {
	var muA, muB sync.Mutex
	var wg sync.WaitGroup

	transfer := func(name string) {
		defer wg.Done()
		muA.Lock()   // always A first
		muB.Lock()   // then B
		fmt.Printf("%s: holds both locks\n", name)
		muB.Unlock()
		muA.Unlock()
	}

	wg.Add(2)
	go transfer("g1")
	go transfer("g2")
	wg.Wait()
}

// CORRECT: avoid multi-lock patterns via channels.
// Channels carry both the value and the synchronization — no explicit locks.
func withChannels() {
	type transfer struct{ from, to int; amount int }

	ch := make(chan transfer, 1)
	balances := map[int]int{1: 100, 2: 200}

	// Single goroutine owns the balances map — no lock needed.
	go func() {
		for t := range ch {
			balances[t.to] += t.amount
			balances[t.from] -= t.amount
		}
	}()

	ch <- transfer{from: 1, to: 2, amount: 50}
	ch <- transfer{from: 2, to: 1, amount: 30}
	close(ch)

	// Give the goroutine time to process (in real code: sync via done channel).
	time.Sleep(time.Millisecond)
	fmt.Printf("balances: %v\n", balances)
}

func main() {
	fmt.Println("--- consistent lock order (safe) ---")
	correct()

	fmt.Println("--- channel-based (no locks needed) ---")
	withChannels()

	fmt.Println("--- broken (not run — would deadlock) ---")
	// broken() // do not call
}

// Key insight: Go detects GLOBAL deadlock (all goroutines blocked) but not
// PARTIAL deadlock (subset blocked). Production services almost always have
// other goroutines running, so partial deadlocks silently hang.
// The idiomatic Go fix: avoid multi-lock patterns by using channels and
// having a single goroutine own each shared resource.
