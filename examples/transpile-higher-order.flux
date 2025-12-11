STRUCT User { id: Int64 }

FN cheatMain() RETURNS User ->
  VAR raw = %"apple,banana,cherry";

  -- PROJECT multiple fields
  -- We create a new HashMap for every item in the list
  VAR projections = raw s> split(%",") s> SELECT _.length();

  -- Access the result
  VAR first_item = projections[0];

  print("Name:", first_item); -- "apple"
  print("Len:",  first_item);  -- 5

  VAR u = %User{ id: first_item };
  RETURN u;
END
