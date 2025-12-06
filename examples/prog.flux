STRUCT Config { debug: Number }

-- TODO: WHAT TYPE IS VOID and NULL?
-- TODO: RETURNS Bool
FN main(s=5) RETURNS Number[3] ->
  VAR json = %{ debug: 1 };

  VAR multiple = 100;

  FN test() USE(multiple) RETURNS String[] ->
    --
    -- SET multiple = 1;
    RETURN %"HI";
  END

  print(multiple);
  print(test());
  print(s);

  -- This should work now:
  VAR raw = CAST(json AS Config);

  -- This is a heap list, returned as a STACK list
  -- inefficient, it should just be created on the STACK
  -- but prooves it is possible.
  VAR list = [1, 2, 3];
  list
    .map( %(x) USE(multiple) -> x * multiple )
     s> print;

  RETURN list;
END

print(main());
