# CLEAR EXAMPLES

## Example Grammar

```CLEAR
FN processUsers(users: User[]) ->
  -- Pipelines with SMOOTH operator 's>'
  result = users AS @u
    s> UNNEST _.orders
    s> SELECT _.price * @u.discount
    s> REDUCE(0, (acc, x) -> acc + x );

  -- Default to "high"; override if result is low
  MUTABLE info = { "sum": [10, 9], "status": "high" };
  IF result <= 1000 THEN
    info = { "sum": [1, 0], "status": "low" };
  END

  RETURN info["sum"][0];
END

-- Lambda with % sigil
myLambda = %(x: Number) ->
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

myPoint = Point{ x: 10, y: 20 };
oPoint = Point{ x: 10, y: 10 };

-- Method call syntax (UFCS)
d = myPoint.distance(oPoint);
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
  -- OR_ELSE RAISE bubbles up the error
  val = fetchData(a, b, c) OR_ELSE RAISE
   s> parseHeader OR_ELSE EXIT "Invalid Header"
   s> parseBody OR_ELSE EXIT "Invalid Body"
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
