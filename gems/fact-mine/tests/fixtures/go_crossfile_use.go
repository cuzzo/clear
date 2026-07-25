package pkgx

func writeAll(b *Builder, parts []string) int {
	for _, p := range parts {
		b.WriteString(p)
	}
	return b.Len()
}
