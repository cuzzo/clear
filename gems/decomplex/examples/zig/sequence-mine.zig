pub fn one() void { alloc_mark(x); body1(); cleanup(x); }
pub fn two() void { alloc_mark(y); body2(); cleanup(y); }
pub fn three() void { alloc_mark(z); body3(); cleanup(z); }
pub fn four() void { alloc_mark(w); body4(); cleanup(w); }
pub fn leak() void { alloc_mark(q); use_value(q); }
