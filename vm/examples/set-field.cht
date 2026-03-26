-- TODO: TO IMPLEMENT!
STRUCT Point { x: Number, y: Number = 5 }

VAR p = %Point{ x: 10 };

-- Test 1: Simple SETFIELD
SET p.x = 20;
print(p.x); -- Should print 20.0

-- Test 2: SETFIELD with calculated value
SET p.y = p.x + 5;
print(p.y); -- Should print 25.0

-- Test 3: Hash Mutation
VAR config = %{ "host": "localhost", "port": 8080 };
SET config.host = "127.0.0.1";
print(config.host); -- Should print 127.0.0.1

RETURN 0;
