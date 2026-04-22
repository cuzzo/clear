// Footgun: Alias Mutation — Go
//
// Go slices are reference types: a slice header (pointer, length, capacity)
// is copied by value, but the underlying array is shared. Appending to one
// slice may or may not affect another slice that shares the backing array,
// depending on capacity. This is a common source of subtle bugs.
//
// Go structs are value types: assigning a struct copies it. Modifying the
// copy does not affect the original — the opposite surprise from slices.
//
// Go has no `restrict` keyword and no strict-aliasing rule. The compiler
// does not assume pointers are non-aliasing. This is safer than C's
// strict-aliasing UB but means some optimizations are foregone.

package main

import "fmt"

// SUBTLE: s1 and s2 share a backing array until s2 grows past cap(s1).
// Writes via s2[i] (within s1's capacity) are visible through s1.
func sliceAliasing() {
	s1 := make([]int, 4, 8) // len=4, cap=8
	s2 := s1[:4]             // shares backing array

	s2[0] = 99
	fmt.Printf("s1[0] after s2[0]=99: %d\n", s1[0]) // 99, not 0

	// append within capacity: still shares
	s2 = append(s2, 10) // len becomes 5, still within cap=8
	s2[0] = 42
	fmt.Printf("s1[0] after append+modify: %d\n", s1[0]) // 42

	// append past capacity: new backing array — no longer aliased
	s3 := make([]int, 4, 4) // cap=4
	s4 := append(s3, 0, 0, 0, 0, 0) // forces reallocation
	s4[0] = 999
	fmt.Printf("s3[0] after s4[0]=999 (reallocated): %d\n", s3[0]) // 0, not 999
}

// SURPRISING: struct assignment copies the value. Modify the copy,
// original is unchanged. This is the opposite of the slice aliasing trap.
type Point struct{ X, Y int }

func structCopy() {
	p1 := Point{1, 2}
	p2 := p1 // copy
	p2.X = 99
	fmt.Printf("p1.X after p2.X=99: %d\n", p1.X) // 1, not 99
}

// CORRECT: use pointers explicitly when you want shared mutation.
func sharedMutation() {
	p1 := Point{1, 2}
	p2 := &p1 // pointer — same memory
	p2.X = 99
	fmt.Printf("p1.X after p2.X=99 (pointer): %d\n", p1.X) // 99
}

func main() {
	fmt.Println("--- slice aliasing ---")
	sliceAliasing()

	fmt.Println("--- struct copy (value semantics) ---")
	structCopy()

	fmt.Println("--- shared mutation via pointer ---")
	sharedMutation()
}

// Key insight: Go's aliasing model has two separate surprises:
// - Slices: reference semantics by default (shared backing array)
// - Structs: value semantics by default (copied on assignment)
// The rule of thumb: if you want to share, use a pointer. If you
// append past capacity, you get a new backing array and lose sharing.
// Go's race detector (-race) catches concurrent aliased mutations.
