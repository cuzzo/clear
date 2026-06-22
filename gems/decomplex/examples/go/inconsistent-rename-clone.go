package main
func original() { src := fetch(1); check(src); store(src); finalize(src) }
func pasted() { dst := fetch(2); check(dst); store(src); finalize(dst) }
