// Footgun: Use-After-Free — Go
//
// Go's garbage collector makes heap UAF structurally impossible:
// an object is only collected once all references to it are gone.
// Holding a pointer IS proof of liveness. You cannot obtain a
// pointer to a collected object; the concepts are contradictory.
//
// There is no free() in Go. The closest analog — returning a pointer
// to a local variable — is safe because the compiler detects the
// escape and promotes the variable to the heap automatically.

package main

import "fmt"

type Player struct {
	Name  string
	Score int
}

// In C, returning &local is a dangling pointer (stack UAF).
// In Go, the compiler sees that p escapes and allocates it on the heap.
func newPlayer(name string, score int) *Player {
	p := Player{Name: name, Score: score} // escapes to heap
	return &p                             // safe: GC owns it now
}

func main() {
	p := newPlayer("Alice", 100)
	fmt.Printf("player: %s scored %d\n", p.Name, p.Score)

	// There is no way to "free" p in Go.
	// p will be collected only after main returns and p goes out of scope.
	// UAF is not a category of bug that exists in safe Go.

	p = nil // drop the reference — GC may now collect the old Player
	// Dereferencing p here would be a nil-pointer panic, not a UAF.
	_ = p
}

// Result: always correct output.
// The GC, not the programmer, decides when memory is reclaimed.
