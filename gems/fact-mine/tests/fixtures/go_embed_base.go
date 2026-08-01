package pkga

type Buffer struct {
	data []byte
}

func (b *Buffer) WriteString(s string) int {
	b.data = append(b.data, s...)
	return len(s)
}

func (b *Buffer) Len() int {
	return len(b.data)
}
