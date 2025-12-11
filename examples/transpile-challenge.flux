STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  MUTABLE counts = %{"dummy": 0_i64}; -- Init Map

  VAR word_str = %"apple banana apple";
  MUTABLE words = word_str.split(" ");

  -- Manual Loop (For loop next!)
  MUTABLE i = 0_i64;
  WHILE i < words.count() DO
    VAR w = words[i];
    VAR current = counts[w]; -- mapGet (defaults to 0)
    SET counts[w] = current + 1_i64; -- mapPut
    SET i = i + 1_i64;
  END

  print(%"Apple Count:", counts["apple"]);

  VAR u = %User{ id: counts["banana"] };
  RETURN u;
END
