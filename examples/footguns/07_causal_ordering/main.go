// Footgun: Causal Message Ordering — Go
//
// Go channels are FIFO per sender, but there is no causal ordering across
// independent channels. If A sends on ch1 and independently B sends on ch2,
// a receiver reading from both channels cannot determine which send
// happened first without out-of-band coordination.
//
// The practical consequence: a relay pattern where B forwards A's signal
// to C does NOT automatically carry A's writes to C. C may read shared
// state that A wrote before the relay, but see it as stale.
//
// Go's memory model (revised 2022) is explicit: a channel send
// happens-before the corresponding receive, but only for the same channel.
// Crossing channel boundaries breaks the happens-before chain unless you
// synchronize explicitly (e.g. via a mutex or a single channel for both
// the data and the signal).

package main

import (
	"fmt"
	"sync"
)

// BROKEN: relay pattern with split channels. The happens-before chain
// from writer → relay → reader is not preserved for sharedData.
func brokenRelay() {
	var sharedData string
	var mu sync.Mutex

	ch1 := make(chan struct{}, 1) // writer → relay
	ch2 := make(chan struct{}, 1) // relay  → reader

	var wg sync.WaitGroup
	wg.Add(3)

	// Writer: sets data, then signals relay.
	go func() {
		defer wg.Done()
		mu.Lock()
		sharedData = "important result"
		mu.Unlock()
		ch1 <- struct{}{} // signals relay
	}()

	// Relay: receives from ch1, forwards to ch2.
	// The happens-before from ch1 receive covers the writer's signal,
	// but the relay does NOT re-establish happens-before for sharedData
	// when it sends on ch2. ch2 receive only happens-before ch2 send.
	go func() {
		defer wg.Done()
		<-ch1
		ch2 <- struct{}{} // forward — does NOT carry sharedData h-b
	}()

	// Reader: receives "go" from relay, reads sharedData.
	go func() {
		defer wg.Done()
		<-ch2
		// Go memory model: ch2 receive h-b ch2 send (relay's side).
		// But sharedData's write h-b ch1 send, not ch2 send.
		// There is no direct happens-before between sharedData write
		// and ch2 receive. On real hardware this is usually fine due
		// to OS scheduler ordering, but it is not guaranteed by the
		// memory model.
		mu.Lock()
		fmt.Printf("reader saw: '%s'\n", sharedData)
		mu.Unlock()
	}()

	wg.Wait()
}

// CORRECT: send the data itself through the channel, not a separate signal.
// The channel carry the happens-before; no split between data and signal.
func correctRelay() {
	ch := make(chan string, 1) // carries both data and h-b guarantee

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		ch <- "important result" // data and signal in one send
	}()

	go func() {
		defer wg.Done()
		data := <-ch // h-b guaranteed: write happens-before this receive
		fmt.Printf("reader saw: '%s'\n", data)
	}()

	wg.Wait()
}

func main() {
	fmt.Println("--- broken relay (split channel + shared memory) ---")
	brokenRelay()

	fmt.Println("--- correct relay (data through channel) ---")
	correctRelay()
}
