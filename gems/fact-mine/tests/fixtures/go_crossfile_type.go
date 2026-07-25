package pkgx

type Builder struct {
	buf []byte
}

func (b *Builder) WriteString(s string) int {
	b.buf = append(b.buf, s...)
	return len(s)
}

func (b *Builder) Len() int {
	return len(b.buf)
}
