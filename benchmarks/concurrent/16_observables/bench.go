// Concurrent observable stream-sum benchmark — Go.
// Mirrors bench.cht: producer stream -> consumer sum -> join.
package main

import (
	"fmt"
	"time"
)

const NWrites = 2_000_000

func expectedSum() int64 {
	n := int64(NWrites)
	return (n * (n - 1)) / 2
}

func main() {
	ch := make(chan int64, 64)
	done := make(chan int64, 1)

	t0 := time.Now()
	go func() {
		var sum int64 = 0
		for v := range ch {
			sum += v
		}
		done <- sum
	}()
	go func() {
		for i := int64(0); i < int64(NWrites); i++ {
			ch <- i
		}
		close(ch)
	}()

	final := <-done
	elapsed := time.Since(t0)
	expected := expectedSum()
	checksum := final + int64(NWrites)*131
	expectedChecksum := expected + int64(NWrites)*131
	if final != expected {
		panic(fmt.Sprintf("final %d != expected %d", final, expected))
	}
	if checksum != expectedChecksum {
		panic(fmt.Sprintf("checksum %d != expected %d", checksum, expectedChecksum))
	}

	fmt.Printf("Go observable stream sum: %d (sum 0..N-1) in %.6f ms\n", final, float64(elapsed.Nanoseconds())/1_000_000.0)
	fmt.Printf("BENCH_INFO: Go stream_sum final=%d checksum=%d n=%d\n", final, checksum, NWrites)
	fmt.Printf("BENCH_RESULT: %.6f ms\n", float64(elapsed.Nanoseconds())/1_000_000.0)
}
