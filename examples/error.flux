-- ==========================================
-- std
-- ==========================================
STRUCT Error { message: String }

-- Helper to make raising errors easier
FN make_error %(msg) ->
  RETURN %Error{ message: msg };
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
    RETURN make_error("404 Not Found");
  END
END

FN parse_json %(json) ->
  -- This print proves this function is running
  print("2. Parsing JSON..."); 
  RETURN "UserObject(" + json + ")";
END

FN enrich_data %(user) ->
  print("3. Enriching Data...");
  RETURN user + " + [Permissions]";
END

-- ==========================================
-- TEST 1: THE HAPPY PATH
-- ==========================================
print("=== STARTING HAPPY PATH ===");

-- fetch_user(1) returns string, so pipe continues
VAR happy_result = fetch_user(1) 
                   |> parse_json() 
                   |> enrich_data();

print("FINAL RESULT: " + happy_result);
ASSERT happy_result == "UserObject({name: 'Alice'}) + [Permissions]", "Happy Path Failed";


-- ==========================================
-- TEST 2: THE ERROR PATH (RAILWAY LOGIC)
-- ==========================================
print(""); 
print("=== STARTING ERROR PATH ===");

-- fetch_user(999) returns %Error.
-- The VM sees the Error and should JUMP over parse_json and enrich_data.
-- You should NOT see "Parsing JSON" or "Enriching Data" in the logs.

VAR error_result = fetch_user(999)
                   |> parse_json()
                   |> enrich_data();

-- Check the result
print("FINAL RESULT TYPE: " + CAST(error_result AS String));

-- Verify we actually got an error
-- (Note: Accessing fields on dynamic structs requires the struct to be cast or generic access)
VAR err = CAST(error_result AS Error);
print("ERROR MSG: " + err.msg);

ASSERT err.msg == "404 Not Found", "Error Message Incorrect";

print("");
print("ALL TESTS PASSED.");
