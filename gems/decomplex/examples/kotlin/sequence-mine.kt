fun one() { alloc_mark(x); body1(); cleanup(x) }
fun two() { alloc_mark(y); body2(); cleanup(y) }
fun three() { alloc_mark(z); body3(); cleanup(z) }
fun four() { alloc_mark(w); body4(); cleanup(w) }
fun leak() { alloc_mark(q); use_value(q) }
