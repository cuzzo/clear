// Footgun: Task Leak — Go
//
// Goroutines are cheap, so it is tempting to spawn them without
// tracking ownership. A goroutine blocked on a channel nobody writes
// to will live until process exit. In a server handling many requests
// this drains memory and eventually causes OOM.
//
// Go provides no compile-time or default-runtime protection. The goroutine
// scheduler has no concept of "this goroutine is orphaned". Detection
// requires external tooling (pprof, goleak) or manual NumGoroutine checks.

package main

import (
	"fmt"
	"runtime"
)

// fetchResult simulates an async operation that never completes.
// The result channel is unbuffered and no goroutine ever sends to it.
func fetchResult() <-chan string {
	ch := make(chan string) // nobody will ever write here
	go func() {
		result := <-ch // blocks forever
		fmt.Println("got:", result)
	}()
	return ch
}

func handleRequest(id int) {
	_ = fetchResult() // spawn goroutine, ignore the channel
	// The goroutine and channel leak here. No compiler warning.
	fmt.Printf("request %d handled (goroutine leaked)\n", id)
}

func main() {
	fmt.Printf("goroutines at start: %d\n", runtime.NumGoroutine())

	for i := 0; i < 10; i++ {
		handleRequest(i)
	}

	fmt.Printf("goroutines at end:   %d\n", runtime.NumGoroutine())
	// ~11 goroutines: 10 leaked + main. Each holds a stack (min 2KB,
	// growing on demand), the channel, and the closure.
}

// Fix: use context.Context for cancellation, or ensure every goroutine
// has a clear exit condition reachable from the caller.
//
// Detection in tests: github.com/uber-go/goleak
//   defer goleak.VerifyNone(t)
