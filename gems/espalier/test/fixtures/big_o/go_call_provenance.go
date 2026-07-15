package fixtures

func helper(items []int) {
	for _, item := range items {
		consume(item)
	}
}

func unrelated(left []int, right []int) {
	for _, x := range left {
		for _, y := range right {
			consume(x, y)
		}
	}
}

func caller(items []int) {
	helper(items)
}
