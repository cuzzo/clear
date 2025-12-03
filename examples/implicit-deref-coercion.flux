STRUCT Point { x: Number, y: Number }

FN get_x(p) ->
  -- 'p' arrives as a FluxPtr (View)
  -- accessing .x triggers the implicit deref in the VM
  RETURN p.x;
END

FN mut_x!(MUTABLE p) ->
  -- 'p' arrives as a FluxPtr (View)
  -- accessing .x triggers the implicit deref in the VM
  SET p.x = 0;
END

FN mut_a!(MUTABLE a) ->
  -- 'p' arrives as a FluxPtr (View)
  -- accessing .x triggers the implicit deref in the VM
  SET a[1] = 100;
END



MUTABLE pt = %Point{ x: 42, y: 100 };
MUTABLE arr = %[ 1, 2, 3];

-- This call triggers 'implicit_deref_coerce_arg' in the compiler
print(get_x(pt));
mut_x!(pt);
print(get_x(pt));

mut_a!(arr);
print(arr);
