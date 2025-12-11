STRUCT User {
  id: Int64,
  score: Int64,
  name: %String[]
}

-- TODO: %User should work
FN cheatMain() RETURNS User ->
  VAR temp_score = 100;

  MUTABLE list : User[] = %[];

  MUTABLE i: Int64 = 0;
  WHILE i < 0 DO
    VAR stack_user = User{ id: i, score: temp_score + 1, name: %"OK" };
    SET i = i + 1;
    list.append(stack_user);
  END

  VAR heap_name = %"Brian";
  VAR heap_user = %User{ id: 999, score: 999, name: heap_name };

  RETURN heap_user;
END
