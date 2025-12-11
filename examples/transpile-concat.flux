STRUCT User { id: Number }

FN cheatMain() RETURNS User ->
  VAR s1 = %"Hello ";
  VAR s2 = %" ";
  VAR s3 = "World!";

  print(s1 + s2 + s3);

  VAR u = %User{ id: 89 };
  RETURN u;
END
