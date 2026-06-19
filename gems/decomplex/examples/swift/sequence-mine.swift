func one() { alloc_mark(x); body1(); cleanup(x) }
func two() { alloc_mark(y); body2(); cleanup(y) }
func three() { alloc_mark(z); body3(); cleanup(z) }
func four() { alloc_mark(w); body4(); cleanup(w) }
func leak() { alloc_mark(q); use_value(q) }
