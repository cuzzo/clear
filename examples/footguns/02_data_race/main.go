// Footgun: Data Race — Go
//
// Go detects data races, but only at runtime and only with -race.
// Without that flag the program silently produces wrong output.
// The race detector is opt-in, not guaranteed, and has ~5-20x overhead
// so it is rarely enabled in production.

package main

import (
	"fmt"
	"sync"
)

const iters = 1_000_000

func main() {
	var counter int // shared, unprotected
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		for i := 0; i < iters; i++ {
			counter++ // data race: read-modify-write is not atomic
		}
	}()

	go func() {
		defer wg.Done()
		for i := 0; i < iters; i++ {
			counter++ // data race
		}
	}()

	wg.Wait()
	fmt.Printf("counter = %d (expected %d)\n", counter, 2*iters)
}

// Compile and run:
//   go run main.go              # wrong answer, no diagnostic
//   go run -race main.go        # WARNING: DATA RACE (correct detection)
//
// Fix: use sync/atomic or protect with sync.Mutex.
//
// Note: Go's memory model defines data races as undefined behavior,
// but the toolchain does not prevent them — it only detects them
// if you ask it to.
