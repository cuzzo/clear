FN cur %() ->
  RETURN %(a, b) -> a + b;
END

print(cur()(1,2));

VAR x = %[ %()-> print(1) ];
x[0]();

VAR z = 5;
VAR a = %[z, z, z];
print(a);

VAR h = %{ p: z };
print(h.p);

VAR h2 = %{ fun: x[0] };
h2.fun();
