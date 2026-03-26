STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  MUTABLE list : Int64[] = %[];
  list.append(10);
  list.append(20);

  -- Access index 1
  VAR val = list[1];

  VAR u = %User{ id: val };
  RETURN u;
END
