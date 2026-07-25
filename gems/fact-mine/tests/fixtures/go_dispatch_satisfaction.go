package sat

type Sorter interface {
	Len() int
	Less(i, j int) bool
}

type Ints []int

func (x Ints) Len() int           { return len(x) }
func (x Ints) Less(i, j int) bool { return x[i] < x[j] }

type Partial struct{ n int }

func (Partial) Len() int { return 0 }
