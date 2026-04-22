// Footgun: Memory Leak — Go
//
// The GC eliminates heap memory leaks: objects are collected once
// unreachable. However, Go still has a common and dangerous leak
// category: goroutines that block forever on a channel nobody writes to.
// Goroutines hold memory (stack, channel, closures) for their lifetime.
// The runtime has no timeout or cancellation by default; blocked
// goroutines accumulate silently until the process runs out of memory.

package main

import (
	"fmt"
	"runtime"
	"time"
)

// leak spawns a goroutine that waits on a channel that will never be
// written to. The goroutine (and its stack) live until process exit.
func leak() {
	ch := make(chan int) // unbuffered, no sender
	go func() {
		v := <-ch // blocks forever
		fmt.Println("received", v)
	}()
	// ch and the goroutine are now unreachable from the caller,
	// but the goroutine itself is alive (blocked), so the GC
	// cannot collect it.
}

func main() {
	fmt.Printf("goroutines before: %d\n", runtime.NumGoroutine())

	for i := 0; i < 1000; i++ {
		leak()
	}

	fmt.Printf("goroutines after:  %d\n", runtime.NumGoroutine())
	// Prints ~1001: 1000 leaked goroutines + main.
	// They will never be collected. In a long-running server this
	// exhausts memory.

	time.Sleep(10 * time.Millisecond) // let scheduler run
	fmt.Printf("goroutines still:  %d\n", runtime.NumGoroutine())
}

// Fix: pass a context.Context and select on ctx.Done() alongside the
// channel read, so callers can cancel blocked goroutines.
//
// Detection: runtime.NumGoroutine() growing without bound; pprof goroutine
// profile; goleak in tests (github.com/uber-go/goleak).
