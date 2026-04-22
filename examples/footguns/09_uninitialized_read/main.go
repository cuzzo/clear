// Footgun: Uninitialized Read — Go
//
// Go zero-initializes every variable at declaration. There is no such
// thing as an uninitialized variable in Go: `var x int` is always 0,
// `var s string` is always "", `var p *T` is always nil. This is a
// language-level guarantee, not a runtime convention.
//
// The entire category of "uninitialized read" bugs does not exist in Go.
// You cannot declare a variable without a value; the zero value is always
// well-defined for every type.

package main

import "fmt"

// Always safe: x is 0 by language guarantee.
func zeroInitLocal() {
	var x int // always 0 — guaranteed by the spec
	fmt.Printf("x = %d\n", x)
}

// Always safe: sum is 0 before the loop (or stays 0 if n <= 0).
func conditionalInit(n int) int {
	var sum int // zero — no conditional uninitialized path
	for i := 0; i < n; i++ {
		sum += i
	}
	return sum // always valid
}

// Always safe: all struct fields are zero-initialized.
type Triple struct{ A, B, C int }

func zeroInitStruct() Triple {
	var t Triple // {A:0, B:0, C:0} — guaranteed
	t.A = 1
	t.B = 2
	// t.C is 0, not garbage
	return t
}

func main() {
	fmt.Println("--- zero-initialized local ---")
	zeroInitLocal()

	fmt.Println("--- conditional init (n=0) ---")
	fmt.Printf("sum = %d\n", conditionalInit(0)) // 0, not garbage

	fmt.Println("--- zero-initialized struct field ---")
	t := zeroInitStruct()
	fmt.Printf("t = {%d, %d, %d}\n", t.A, t.B, t.C) // t.C == 0
}

// Key insight: Go's zero-value guarantee is not just a convention —
// it is part of the language specification. The runtime enforces it for
// all allocations (stack frames, heap, global variables, channel receives).
// New fields added to a struct are automatically zero-initialized; the C
// "forgot to initialize the new field" bug cannot happen.
//
// The tradeoff: you must be careful that the zero value is meaningful for
// your type (e.g., a mutex's zero value is an unlocked mutex — intentional).
