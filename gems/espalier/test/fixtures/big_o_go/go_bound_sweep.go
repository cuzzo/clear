package gologcosts

import (
	"regexp"
	"sort"
	"strings"
)

var sweepRe = regexp.MustCompile(`x`)

// O(N^2)
func NestedSameInput(xs []int) int {
	total := 0
	for _, a := range xs {
		for _, b := range xs {
			total += a * b
		}
	}
	return total
}

// O(N*M)
func NestedIndependentInputs(xs []int, ys []int) int {
	total := 0
	for _, a := range xs {
		for _, b := range ys {
			total += a * b
		}
	}
	return total
}

// O(N^3)
func TripleNested(xs []int) int {
	total := 0
	for _, a := range xs {
		for _, b := range xs {
			for _, c := range xs {
				total += a * b * c
			}
		}
	}
	return total
}

// O(N^2): every iteration rebuilds the accumulated string.
func ConcatEveryIteration(parts []string) string {
	out := ""
	for _, part := range parts {
		out = out + part
	}
	return out
}

// O(N log N): the rows partition the input, so the sorts sum to it.
func SortInsideLoop(rows [][]int) int {
	total := 0
	for _, row := range rows {
		sort.Ints(row)
		total += len(row)
	}
	return total
}

// O(N log N)
func SortOnce(xs []int) {
	sort.Ints(xs)
}

// O(N): the inner scan is over the element, not the collection.
func InnerOverElement(rows [][]int) int {
	total := 0
	for _, row := range rows {
		for _, value := range row {
			total += value
		}
	}
	return total
}

// O(N^2) worst case: the break does not bound the scan below N.
func NestedWithBreak(xs []int, target int) int {
	found := 0
	for range xs {
		for _, b := range xs {
			if b == target {
				found++
				break
			}
		}
	}
	return found
}

// O(N)
func MapLookupPerElement(keys []string, index map[string]int) int {
	total := 0
	for _, key := range keys {
		total += index[key]
	}
	return total
}

// O(N)
func RegexpPerElement(lines []string) int {
	count := 0
	for _, line := range lines {
		if sweepRe.MatchString(line) {
			count++
		}
	}
	return count
}

// O(N*C): the callback's cost is the caller's to carry.
func CallbackPerElement(xs []int, apply func(int) int) int {
	total := 0
	for _, x := range xs {
		total += apply(x)
	}
	return total
}

// O(N): linear recursion down the slice.
func SumRecursive(xs []int) int {
	if len(xs) == 0 {
		return 0
	}
	return xs[0] + SumRecursive(xs[1:])
}

// O(N^2): the prefix joined grows with the index.
func JoinGrowingPrefix(parts []string) int {
	total := 0
	for i := range parts {
		total += len(strings.Join(parts[:i+1], "/"))
	}
	return total
}

// O(N^2): each Contains scans the whole accumulated buffer.
func ScanAccumulated(parts []string) int {
	seen := ""
	hits := 0
	for _, part := range parts {
		if strings.Contains(seen, part) {
			hits++
		}
		seen += part
	}
	return hits
}

// O(log N): the control variable is divided each iteration.
func DivideDescent(b int64) int {
	exp := 0
	for n := b / 1024; n >= 1024; n /= 1024 {
		exp++
	}
	return exp
}

// O(N): a decrement reaches the bound one step at a time.
func DecrementDescent(b int64) int {
	steps := 0
	for n := b; n > 1; n-- {
		steps++
	}
	return steps
}

// O(N log M): a descent over one input nested inside a scan over another.
func DescentPerElement(rows []int64, limit int64) int {
	total := 0
	for range rows {
		for n := limit; n > 1; n /= 2 {
			total++
		}
	}
	return total
}

// O(N log M): the descent runs over the element's value, which is not a
// partition of the collection being scanned.
func DescentOverElementValue(rows []int64) int {
	total := 0
	for _, row := range rows {
		for n := row; n > 1; n /= 2 {
			total++
		}
	}
	return total
}
