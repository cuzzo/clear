void one() { alloc_mark(x); body1(); cleanup(x); }
void two() { alloc_mark(y); body2(); cleanup(y); }
void three() { alloc_mark(z); body3(); cleanup(z); }
void four() { alloc_mark(w); body4(); cleanup(w); }
void leak() { alloc_mark(q); use_value(q); }
