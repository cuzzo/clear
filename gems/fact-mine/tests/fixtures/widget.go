package widgets

type widget struct {
	n int
}

func (w *widget) tally() int {
	return w.n
}

func use(w *widget) int {
	return w.tally()
}
