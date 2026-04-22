// Footgun: Buffer Overflow — Go
//
// Go performs bounds checking on every slice and array index operation at
// runtime. An out-of-bounds access panics immediately with a descriptive
// message — it cannot silently corrupt memory. There is no pointer
// arithmetic on slices; you cannot form a pointer to "one past the end".
//
// The tradeoff: runtime bounds checks add a small overhead (~1-3% for
// typical workloads). The benefit: an entire class of memory corruption
// bugs is impossible to express in pure Go.

package main

import "fmt"

// Safe by construction: panic on out-of-bounds, never silent corruption.
func boundsChecked() {
	buf := make([]byte, 4)

	// This would panic at runtime: "index out of range [4] with length 4"
	// buf[4] = 'x'

	// Correct: stay within bounds
	for i := 0; i < len(buf); i++ {
		buf[i] = byte('0' + i)
	}
	fmt.Printf("buf: %s\n", buf)
}

// Off-by-one: Go catches it.
func offByOne() {
	arr := [8]int{}

	// Correct loop — the broken C version used i <= 8
	for i := 0; i < len(arr); i++ {
		arr[i] = i
	}
	fmt.Printf("arr[7]=%d\n", arr[7])
}

// Demonstrate the panic explicitly with recover so the program continues.
func showPanic() {
	defer func() {
		if r := recover(); r != nil {
			fmt.Printf("caught panic: %v\n", r)
		}
	}()

	buf := make([]byte, 4)
	_ = buf[10] // panics: index out of range [10] with length 4
}

func main() {
	fmt.Println("--- bounds-checked access ---")
	boundsChecked()

	fmt.Println("--- off-by-one (safe) ---")
	offByOne()

	fmt.Println("--- explicit out-of-bounds (caught panic) ---")
	showPanic()
}

// Key insight: Go's slice header (pointer + length + capacity) means the
// runtime always knows the valid range. There is no way to suppress the check
// in pure Go — unsafe.Pointer can bypass it, but that opts you back into C
// territory and is obvious in the code.
