// Footgun: TOCTOU — Go
//
// Go's sync.Mutex prevents data races but not logical TOCTOU.
// If you release the lock between check and act, another goroutine
// can modify the state in the window. The race detector won't fire
// because both accesses are individually protected; the bug is in
// the gap between two critical sections.

package main

import (
	"fmt"
	"sync"
)

type Account struct {
	mu      sync.Mutex
	balance int
}

// BROKEN: check and act in separate lock acquisitions.
// Window between Unlock() and the second Lock() allows overdraft.
func (a *Account) withdrawBroken(amount int) bool {
	a.mu.Lock()
	ok := a.balance >= amount // CHECK — lock held
	a.mu.Unlock()             // lock released: window opens here

	// Another goroutine can withdraw here, draining the balance.

	if ok {
		a.mu.Lock()
		a.balance -= amount // ACT — but check is now stale
		a.mu.Unlock()
	}
	return ok
}

// CORRECT: check and act under the same lock acquisition.
func (a *Account) withdrawCorrect(amount int) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.balance < amount {
		return false
	}
	a.balance -= amount // check and act are atomic
	return true
}

func main() {
	acct := &Account{balance: 100}

	var wg sync.WaitGroup
	results := make([]bool, 5)

	// Five goroutines each try to withdraw 80 from an account with 100.
	// With the broken version, multiple can succeed → balance goes negative.
	for i := range results {
		wg.Add(1)
		i := i
		go func() {
			defer wg.Done()
			results[i] = acct.withdrawBroken(80)
		}()
	}
	wg.Wait()

	successes := 0
	for _, ok := range results {
		if ok {
			successes++
		}
	}
	fmt.Printf("broken:  %d withdrawals succeeded, balance = %d\n",
		successes, acct.balance)
	// May print: 2 withdrawals succeeded, balance = -60

	// Reset and run the correct version.
	acct.balance = 100
	for i := range results {
		wg.Add(1)
		i := i
		go func() {
			defer wg.Done()
			results[i] = acct.withdrawCorrect(80)
		}()
	}
	wg.Wait()

	successes = 0
	for _, ok := range results {
		if ok {
			successes++
		}
	}
	fmt.Printf("correct: %d withdrawal  succeeded, balance = %d\n",
		successes, acct.balance)
	// Always: 1 withdrawal succeeded, balance = 20
}
