STRUCT User { id: Number }

FN cheatMain() RETURNS User ->
  MUTABLE score = 10;
  VAR is_valid = score > 5;

  IF is_valid THEN
    VAR bonus = 100;
    SET score = score + bonus;
  ELSE
    SET score = 0;
  END

  print(score); -- Should print 110
  VAR u = %User{ id: score };
  RETURN u;
END
