MUTABLE x = 1;
WHILE x < 10 DO
  print(x);
  SET x = x + 1;
END

MUTABLE i = 1;
WHILE i < 10 DO
  IF i == 7 THEN BREAK; END
  IF i MOD 3 == 0 THEN SET i = i + 1; CONTINUE; END
  print(i);
  SET i = i + 1;
END
