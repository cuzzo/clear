package pkgb

import "example/pkga"

type encoder struct {
	pkga.Buffer
	depth int
}

func (e *encoder) emit(s string) int {
	e.WriteString(s)
	return e.Len()
}
