function one() { alloc_mark(x); body1(); cleanup(x); }
function two() { alloc_mark(y); body2(); cleanup(y); }
function three() { alloc_mark(z); body3(); cleanup(z); }
function four() { alloc_mark(w); body4(); cleanup(w); }
function leak() { alloc_mark(q); use_value(q); }
