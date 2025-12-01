VAR list = %[10, 20, 30];
VAR view = list[0..1]; -- Creates FluxView

FN print_first %(v) ->
  -- VM receives FluxView.
  -- print() calls v.inspect.
  -- If v is a FluxView, it should print the content of the owner.
  print(v);

  -- TEST IMPLICIT DEREF:
  -- Accessing v[0] should trigger resolve_val logic if you wired it up
  print(v[0]);
END

print_first(view);
