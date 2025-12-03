-- ==========================================
-- std
-- ==========================================
STRUCT Error {
  message: String,
  context: String,
  snapshot: Any
}

-- Helper to make raising errors easier
FN make_error(msg, context = "", snapshot = "") ->
  RETURN %Error{ message: msg, context: context, snapshot: snapshot };
END

-- ==========================================
-- MOCK BUSINESS LOGIC
-- ==========================================

FN fetch_user(id) ->
  print("1. Fetching User ID: " + id);

  IF id == 1 THEN
    -- Success: Return a String (simulating a JSON blob)
    RETURN "{name: 'Alice'}";
  ELSE
    print("ELSE");
    -- Failure: Return the Error Struct
    RAISE "404 Not Found";
  END
END

FN parse(str) ->
  RETURN "parsed";
END

FN smooth() ->
  VAR err = 999
    s> fetch_user OR EXIT "Parsing Phase Failed"
    s> parse;
CATCH e
  print(e.message);
END

smooth();
