function one() alloc_mark(x); body1(); cleanup(x) end
function two() alloc_mark(y); body2(); cleanup(y) end
function three() alloc_mark(z); body3(); cleanup(z) end
function four() alloc_mark(w); body4(); cleanup(w) end
function leak() alloc_mark(q); use_value(q) end
