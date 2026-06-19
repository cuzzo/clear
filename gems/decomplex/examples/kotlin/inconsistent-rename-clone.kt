fun original() { val src = fetch(1); check(src); store(src); finalize(src) }
fun pasted() { val dst = fetch(2); check(dst); store(src); finalize(dst) }
