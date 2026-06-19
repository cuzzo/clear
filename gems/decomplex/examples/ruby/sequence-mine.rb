# frozen_string_literal: true

def one; alloc_mark(x); body1; cleanup(x); end
def two; alloc_mark(y); body2; cleanup(y); end
def three; alloc_mark(z); body3; cleanup(z); end
def four; alloc_mark(w); body4; cleanup(w); end
def leak; alloc_mark(q); use(q); end
