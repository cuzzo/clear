package pkg

type State struct {
	n int
}

func helper(x int) int {
	return x + 1
}

func (s *State) compute() int {
	return helper(s.n)
}
