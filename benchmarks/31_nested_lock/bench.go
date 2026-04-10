// Nested Lock Benchmark -- Go
//
// Bank transfer workload: N accounts, M workers doing random transfers.
// Each transfer:
//   1. Read-locks a shared bank (RWMutex) to access the accounts array
//   2. Locks two accounts (ordered by index to prevent deadlock)
//   3. Transfers $1
// Measures throughput and contention overhead of nested lock acquisition.
//
// Build: go build -o bench_go bench.go

package main

import (
	"fmt"
	"math/rand"
	"runtime"
	"sync"
	"time"
)

const (
	numAccounts  = 64
	opsPerWorker = 500_000
)

type Account struct {
	mu      sync.Mutex
	balance int64
}

type Bank struct {
	mu       sync.RWMutex
	accounts []*Account
}

func main() {
	nCPU := runtime.NumCPU()
	runtime.GOMAXPROCS(nCPU)
	nWorkers := nCPU
	if nWorkers < 2 {
		nWorkers = 2
	}

	bank := &Bank{}
	bank.accounts = make([]*Account, numAccounts)
	for i := range bank.accounts {
		bank.accounts[i] = &Account{balance: 1000}
	}

	var wg sync.WaitGroup
	t0 := time.Now()

	for w := 0; w < nWorkers; w++ {
		wg.Add(1)
		go func(seed int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(int64(seed)*7 + 13))
			for i := 0; i < opsPerWorker; i++ {
				a := rng.Intn(numAccounts)
				b := rng.Intn(numAccounts)
				if a == b {
					b = (a + 1) % numAccounts
				}

				// Read-lock bank to access accounts array
				bank.mu.RLock()

				// Lock in index order to prevent deadlock
				lo, hi := a, b
				if lo > hi {
					lo, hi = hi, lo
				}
				bank.accounts[lo].mu.Lock()
				bank.accounts[hi].mu.Lock()

				if bank.accounts[lo].balance > 0 {
					bank.accounts[lo].balance--
					bank.accounts[hi].balance++
				}

				bank.accounts[hi].mu.Unlock()
				bank.accounts[lo].mu.Unlock()
				bank.mu.RUnlock()
			}
		}(w)
	}

	wg.Wait()
	elapsed := time.Since(t0)

	var total int64
	for _, a := range bank.accounts {
		total += a.balance
	}
	expected := int64(numAccounts) * 1000
	totalOps := int64(nWorkers) * opsPerWorker

	fmt.Printf("Workers:        %d\n", nWorkers)
	fmt.Printf("Accounts:       %d\n", numAccounts)
	fmt.Printf("Ops per worker: %d\n", opsPerWorker)
	fmt.Printf("Total ops:      %d\n", totalOps)
	fmt.Printf("Total time:     %d ms\n", elapsed.Milliseconds())
	fmt.Printf("Ops/sec:        %d\n", totalOps*1000/elapsed.Milliseconds())
	fmt.Printf("Balance:        %d (expected %d)\n", total, expected)
}
