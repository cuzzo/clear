fn one() { alloc_mark(x); body1(); cleanup(x); }
fn two() { alloc_mark(y); body2(); cleanup(y); }
fn three() { alloc_mark(z); body3(); cleanup(z); }
fn four() { alloc_mark(w); body4(); cleanup(w); }
fn leak() { alloc_mark(q); use_value(q); }
