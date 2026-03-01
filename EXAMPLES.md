# CLEAR EXAMPLES

## Example Grammar

```CLEAR
FN processUsers(users: User[]) ->
  -- Pipelines with SMOOTH operator 's>'
  VAR result = users AS @u
    s> UNNEST _.orders
    s> SELECT _.price * @u.discount
    s> REDUCE(0, (acc, x) -> acc + x );

  VAR info;
  IF result > 1000 THEN
    -- No % sigil for collections
    SET info = { "sum": [10, 9], "status": "high" };
  ELSE
    SET info = { "sum": [1, 0], "status": "low" };
  END

  RETURN info["sum"][0];
END

-- Lambda with % sigil
VAR myLambda = %(x: Number) ->
  doIt();
  RETURN TRUE;
END
```

### SIGILS

| Sigil | Meaning | Example |
|-------|---------|---------|
| `%(...)` | Lambda parameters | `%(x, y) -> x + y` |
| `@` | Pipeline binding / Directives | `users AS @u` |
| `!!` | Explicit panic | `list.get(i)!!` |
| `_` | Pipeline placeholder | `s> SELECT _.name` |
| `s>` | SMOOTH operator | `data s> process` |

### STRUCTS

```CLEAR
STRUCT Point {
  name: String,
  x: Number DEFAULT 10,
  y: Number DEFAULT 20
}

-- Recursive structure with 'indirect'
STRUCT Node {
  value: Int64,
  left: indirect Node,
  right: indirect Node
}

FN Point::distance(self: Point, other: Point) -> Number
  -- ...
END

VAR myPoint = Point{ x: 10, y: 20 };
VAR oPoint = Point{ x: 10, y: 10 };

-- Method call syntax (UFCS)
VAR d = myPoint.distance(oPoint);
```

### CONTROL FLOW

```CLEAR
-- WHILE Loop
WHILE x > 0 DO
  ...
  IF ... THEN BREAK END
END

-- IF/ELSE
IF x == 1 THEN
  do1();
ELSE_IF x == 2 THEN
  do2();
ELSE
  doElse();
END

-- WITH Capability Block
WITH sharedAccount AS acc {
  acc.balance += 100;
}
```

### ERROR HANDLING

```CLEAR
FN myFunc(a, b, c) ->
  -- OR RAISE bubbles up the error
  val = fetchData(a, b, c) OR RAISE
   s> parseHeader OR EXIT "Invalid Header"
   s> parseBody OR EXIT "Invalid Body"
   s> fetchUser
      s> RECOVER(DefaultUser())

CATCH ParseError WITH("Invalid Header")
  logInvalidHeader(%e.snapshot);
  RETURN defaultPage();
DEFAULT
  logUnknownError(%e);
  RAISE %e;
END
```
