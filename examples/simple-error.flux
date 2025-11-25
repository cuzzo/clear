-- ==========================================
-- std
-- ==========================================
STRUCT Error { 
  message: String,
  context: String,
  snapshot: Any
}

-- Helper to make raising errors easier
FN make_error %(msg) ->
  RETURN %Error{ message: msg, context: NIL, snapshot: NIL };
END

-- ==========================================
-- MOCK BUSINESS LOGIC
-- ==========================================

FN fetch_user %(id) ->
  print("1. Fetching User ID: " + id);
  
  IF id == 1 THEN
    -- Success: Return a String (simulating a JSON blob)
    RETURN "{name: 'Alice'}";
  ELSE
    -- Failure: Return the Error Struct
    RAISE "404 Not Found";
  END
END

FN parse %(str) ->
  RETURN "parsed";
END

VAR err = 999 |> fetch_user(999) OR EXIT "Parsing Phase Failed" |> parse() ;
print(err);
