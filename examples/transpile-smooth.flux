STRUCT User { id: Int64 }

FN double(n: Int64) RETURNS Int64 ->
  RETURN n * 2;
END

FN cheatMain() RETURNS User ->
  VAR start = 10;

  -- 1. Simple Pipe: double(10)
  VAR res1 = start s> double;

  -- 2. Chained Pipe: double(double(10))
  VAR res2 = start s> double s> double;

  -- 3. Pipe into Print (Builtin)
  res2 s> print;

  VAR u = %User{ id: 777 };
  RETURN u;
END

