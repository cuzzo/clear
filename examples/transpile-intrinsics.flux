STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  MUTABLE str = %"start";
  VAR add_str = %", a";

  MUTABLE i = 0;
  WHILE i < 10 DO
    SET str = str + add_str;
    SET i = i + 1;
  END

  print(str);
  print(i);
  VAR u = %User{ id: 707 };
  RETURN u;
END

