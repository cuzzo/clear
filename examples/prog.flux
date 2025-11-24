STRUCT Config { debug: Number }

-- TODO: WHAT TYPE IS VOID and NULL?
-- TODO: RETURNS Bool
FN main %(args) RETURNS Number ->
  VAR json = %{ "debug": 1 };

  VAR multiple = 100;

  FN test %() USE(multiple) RETURNS String ->
    --
    -- SET multiple = 1;
    RETURN "HI";
  END

  print(multiple);

  -- This should work now:
  VAR raw = CAST(json AS Config);

  VAR list = %[1, 2, 3,];
  list.map( %(x) USE(multiple) -> x * multiple; )
      |> print();

  RETURN 1;
END

