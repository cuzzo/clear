// Footgun: Iterator Invalidation — Go
//
// Go's `range` over a slice takes a snapshot of the slice header (pointer,
// length) at the start of the loop. Adding elements via append during the
// loop is safe for the loop variable but the new elements are NOT visited —
// the loop iterates over the original length. This is spec-defined behavior,
// not a bug, but it surprises programmers coming from mutable-iterator
// languages.
//
// Deleting from a slice during range by index is the classic skip bug: after
// removing index i, element i+1 shifts down to i, but the loop increments
// i on the next iteration, skipping the shifted element.
//
// Map range in Go: adding keys during range may or may not be visited
// (undefined by the spec). Deleting the current key is safe. Deleting
// other keys: the deleted key may or may not appear (also undefined).

package main

import "fmt"

// SURPRISING: appending during range does not grow the loop's iteration set.
func appendDuringRange() {
	s := []int{1, 2, 3}
	for _, v := range s {
		s = append(s, v*10) // appends, but loop still iterates 3 times
	}
	fmt.Printf("after append-during-range: %v\n", s) // [1 2 3 10 20 30]
}

// BROKEN: naive delete-during-range skips elements.
func deleteSkip() {
	s := []int{1, 2, 3, 4, 5}
	for i := 0; i < len(s); i++ {
		if s[i]%2 == 0 {
			s = append(s[:i], s[i+1:]...) // remove s[i]
			// BUG: i is incremented next iteration; s[i] (now the shifted
			// element) is skipped. Fix: i-- after the removal.
		}
	}
	fmt.Printf("broken delete (evens removed): %v\n", s) // may miss elements
}

// CORRECT: delete-during-iteration with i-- after removal.
func deleteCorrect() {
	s := []int{1, 2, 3, 4, 5}
	for i := 0; i < len(s); i++ {
		if s[i]%2 == 0 {
			s = append(s[:i], s[i+1:]...)
			i-- // re-examine index i (shifted element)
		}
	}
	fmt.Printf("correct delete (evens removed): %v\n", s)
}

// CORRECT: idiomatic Go — build a new slice without the elements to remove.
func deleteIdiomatic() {
	s := []int{1, 2, 3, 4, 5}
	result := s[:0] // share backing array, zero length
	for _, v := range s {
		if v%2 != 0 {
			result = append(result, v)
		}
	}
	fmt.Printf("idiomatic delete (odds kept): %v\n", result)
}

// SURPRISING: map iteration order + concurrent modification.
func mapDuringRange() {
	m := map[string]int{"a": 1, "b": 2, "c": 3}
	// Adding a key during range: may or may not be visited (spec says
	// "map iteration order is not specified and is not guaranteed to be
	// the same from one iteration to the next").
	for k, v := range m {
		m["new_"+k] = v * 10 // new keys: visited or not — undefined
		_ = k
	}
	fmt.Printf("map after in-loop add: len=%d\n", len(m))
}

func main() {
	fmt.Println("--- append during range ---")
	appendDuringRange()

	fmt.Println("--- broken delete during iteration ---")
	deleteSkip()

	fmt.Println("--- correct delete during iteration ---")
	deleteCorrect()

	fmt.Println("--- idiomatic filter (no in-place mutation) ---")
	deleteIdiomatic()

	fmt.Println("--- map modification during range ---")
	mapDuringRange()
}

// Key insight: Go does not prevent iterator invalidation — it just makes
// the spec-defined behavior less dangerous than C's UB. The delete-skip
// bug still exists; range-over-slice takes a snapshot of len so append
// doesn't crash but silently misses new elements. The idiomatic fix is
// to build a new collection instead of mutating in place.
