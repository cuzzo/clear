STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  VAR filename = "test.csv";

  IF filename.endsWith(".csv") THEN
    print("Found CSV:", filename);
  END

  IF filename.startsWith("test") THEN
    print("Test File detected");
  END

  VAR str = "  100  ";
  VAR num = str.trim().toFloat(); -- Chains trim and toInt

  VAR val = max(num, 50); -- 100
  print(val);

  VAR u = %User{ id: val };
  RETURN u;
END
