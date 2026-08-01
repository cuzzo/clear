package dispatch

type Comparer interface {
	Less(i, j int) bool
}

func countInversions(c Comparer, n int) int {
	total := 0
	for i := 0; i < n; i++ {
		if c.Less(i, i+1) {
			total++
		}
	}
	return total
}
