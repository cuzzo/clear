## Example Grammar

```
FN myFn %(x:Vector![Number]) USE(a,b) RETURNS Number ->
  x
    .map(%(x) USE(a) -> x ** a ;)
    .reduce(0, %(acc:Number, y:Number) -> acc + ((y + a.y) * b.y) ;)
    |> print ;

  -- IS THIS AN OUT OF SCOPE PROBLEM?
  VAR info ;
  IF total > 10 THEN
    SET info = %{ "sum": %[10, 9], "status": "high" } ;
  ELSE
    SET info = %{ "sum": %[1, 0], "status": "low" } ;
  END

  RETURN info["sum"][0] ;
END

VAR myLambda = %(x:Number) RETURNS Bool ->
  doIt() ;
  RETURN true ;
END
```

### SIGILS

```
%() -> Creates a parameter list
%{} -> Creates a hash
%[] -> Creates a list

@c_ -> concurrent higher-order array function
@p_ -> parallel higher-order array function
@d_ -> distributed higher-order array function
```

### STRUCTS

```
STRUCT Point {
  INCLUDES(OtherStruct); -- NOT IN V0.1

  name: String
  x: Number DEFAULT 10,
  y: Number DEFAULT 20
}

FN Point::distance %(self: Point, other: Point) RETURNS Number ->
  -- ...
END

VAR myPoint = %Point{ x: 10, y: 20 };
VAR oPoint = %Point{ x: 10, y: 10 };

VAR distance = myPoint.distance(myPoint, oPoint);
  -- compiler transforms to Point::distance(myPoint, oPoint);
```

### BLOCKING

```
-- WHILE/DO/BREAK/END

WHILE x > 0 DO
  ...
  IF ... THEN BREAK END
END

-- IF/ELSE_IF/ELSE/END

IF x == 1 THEN
  do1() ;
ELSE_IF x == 2 THEN
  do2() ;
ELSE
  doElse() ;
END

-- CASE/OF/=>/DEFAULT/END
CASE x OF
  1 => foo() ;
  2 => bar() ;
  DEFAULT => baz() ;
END

-- TRY/CATCH/FINALLY/END

FN myRiskyFn() ->
  doSomethingWithPotentialError() ;
CATCH Error1
  handleTheError() ;
FINALLY
  myFailsafeFunc() ;
END
```

### RANGE

```
RANGE(1 TO 10)
RANGE(1 TO_EXCLUDING 10)
```

### TYPES
```
VAR vector = %[1, 2, 3] ;
VAR hash = %{ "name": "foo", "hp": 100 } ;
```

### KEYWORDS AND OPERATORS
```
NULL: ??
BOOLS: TRUE, FALSE
LOGICAL: && || !
COMPARISON: < > <= >= == !=
BINARY LOGIC: ^ | & ~ >> <<
ARITHMETIC: + - * / MOD **

CAST(... AS ...)
```

### TODO
0. POWER, MOD operator
1. `!` unary
2. list & struct access
3. Boolean short-circuit logic -> Same as IF/ELSE -> IMPLEMENT JUMP_TRUE
4. Native Bridge (way to register ruby funcs)
5. RANGE(1 TO n)
6. REPL
7. Runtime Line Numbers
8. String Interning -> Arena-based Memory where it counts
9. Co-routines & fibers -> yield/generators, async/await
10. Execution tracing / debugger hooks
11. Tail call recursion? -> LOW priority

### DESIGN TODO
1. Allow trailing commas everywhere, simplifies parsing
2. Enforce type definitions on all Structs and functions (EXCEPT Lambdas as an
   argument inside a function, because it's superfluous)
3. Empty variables and lists MUST have a type.
4. See if I can eliminate precedence at first. LINT on anything non-associative
5. For a register VM, do not allow more than 500 variables in local scope.

### GOTCHAS

```
-- Compiler cannot allow this
VAR x = IF condition THEN
   10
ELSE
   "Hello"
END
```


```
VAR x = json::load("some-file.json") ;
VAR y = x["test"] ; -- COMPILER ERROR -> MUST SPECIFY TYPE
```

### Control Flow

```
IF x > 100 THEN
  doBigXThing();
ELSE
  doSmallXThing();
END

tax = calculate_base()
  |> IF %% > 100
     THEN %% * 0.2
     ELSE %% * 0.1;


MATCH age START
  0 -> doNewbornThing(),
  1 -> doBabyThing(),
  2 -> doToddlerThing(),
  %% > 13 -> doTeenageThing(),
  %% > 21 -> doAdultThing(),
  DEFAULT -> doImpossibleThing()
END

type Resp = Integer | String | Vector<Number> | User

MATCH resp START
  Intger: %% > 5 -> handleIntResp(%%), -- OK
  String: %%.len() > 5 -> handleStr(%%), -- OK

  -- Pattern:
  --  -x: Capture index 0
  --  -y: Capture index 1
  [x, y]: x == y -> handleArrayOfTwoEqualValues(%%), -- OK

  -- Pattern:
  --  -_: Capture index 0, but I don't need it
  [_, y]: y == 5 -> handleArrayOfTwoValuesWhere2ndIs5(%%), -- OK

  -- Pattern:
  --  -*: can splat up to the end of the list
  [_, _, *] -> handleArrayOf3OrMoreValues(%%), -- OK

  -- Pattern:
  --  -*: can splat in the middle of the list
  [*, x, _]: x == 5 -> handleArrayOf3OrMoreValuesWhere2ndToLastIs5(%%), -- OK

  -- Destructing
  User { role: r }: &&.id > 0 -> UserIdIsZero(r), -- OK 
  User { address: { city: c } }: c == "Chicago" -> TaxForChicago(%%), -- OK
 
  DEFAULT -> doDefaultThigns()
END
```

### Error Handling

```
FN myFunc %(a, b, c) ->
  -- ? suffix means the function can return an Error
  -- Despite that, I want to proceed down the pipe if NOT an Error
  val = fetchData(a, b, c) ?
   |> parseHeader ? "Invalid Header" -- ? after PIPE means set Error Context
   |> parseBody ? "Invalid Body"
   |> fetchUser 
      |> RECOVER(DefaultUser()) -- handle error in place, and continue 
   |> saveToDb(a, b, c, %%)

CATCH ParseError WITH("Invalid Header")
  -- CATCH sets %e to the as a local Error variable e
  -- All errors have a context ("Invalid Header") set above
  -- All errors also have a `snapshot`
  -- That contains the value piped into the function that caused the error.
  logInvalidHeader(%e.snapshot.header());
  RETURN defaultPage(); 
CATCH ParseError WITH("Invalid Body")
  -- Since we want to handle the same Error `ParseError` in 2 different ways
  -- That is way we set the context above (after the `?` operator)
  --
  -- If we wanted to handle both errors the same
  -- We wouldn't need to set a context
  raise %e -- We EXPLICITLY bubble this up to the user
DEFAULT 
  logUnknownError(%e)
  raise %e  
END
```

* Major Decision: Do I require a `?` suffix sigil on functions that return an error to proceed through the pipe.
* In compilation, `|>` *could* handle this by default, but issues...
* Requiring a `?` sigil in the name is an anti-pattern IFF forced removal
  * Can allow `?` on functions that don't return an error, just warn
  * Can allow `RECOVER()` for non-results, just warn
  * Cannot allow MATCH on an Error that no longer exists, compile error
    * It seems fine to need to remove ErrorHandling logic that doesn't need to happen anymore...

* TODO: Evaluate `||` vs `|> RECOVER`

### Runtime safety guarantee

1. Must handle division by 0

```
FN myDividerFunction(x, y) ->
  y = GUARD y != 0 ELSE 1
  RETURN x / y
END

-- The above func would be a compiler error if not proving that y != 0
```

2. Array Indexing (Index Out of Bounds)
   - list[i] is dangerous
   - must use list.at(i) -> returns Item | Nil


```
-- COMPILER ERROR: list[i] returns Option, cannot assign to Integer
val = my_list[10]

val = my_list[0] OR ELSE 0 -- OK has a default

var = my_list[0] !! "Index OOB" -- OK, raises explicit panic

FN nestedListFn %(nestedList) ->
  name = nestedList[0] OR EXIT -- EXPLICIT, handle later

  nestedList[100, 10, 0] OR ELSE "DEFAULT"
    |> fetchData
CATCH IndexOutOfBounds ->
  RETURN 0
END
```

```
FN sync_user %(id) ->
  fetch_user(id) OR RETURN        -- Explicit: Return error to the user
    |> parse_user OR GOTO_RECOVER -- Explicit: "Do this OR ghost to RECOVER"
    |> enrich_data OR EXIT        -- Explicit Ejection (to CATCH below)
    |> save_to_db OR ELSE 0       -- Explicit Recovery
       |> RECOVER(DefaultSync);
CATCH EnrichError
  log(%e.snapshot)
  RETURN Something();
END
```

* If `GOTO_RECOVER` w/o a `RECOVER` in pipe:

```
Compile Error: Pipeline uses OR GOTO_RECOVER at line 2, but no RECOVER() step was found. Fix: Add |> RECOVER(...) at the end of the chain, or change OR GOTO_RECOVER to OR EXIT.
```

* Important -> Function names, variables, structs cannot end or contain `?`
  * Therefore `?` can occur at the end of an identifier, and we know it's a function in a PIPE

3. Forced Unwrapping: option `!!` 
   - Any function that panics
   - `!!` Explicit panic operator
   - if you don't see `!!` anywhere in the code, you'll have no runtime errors

4. Stack Overflow: Infinite Recursion

```
FN unsafe_fib %(n) ->
  # ... standard recursive math ...
  unsafe_fib(n-1) + unsafe_fib(n-2)
END

FN main %() ->
  # Run with a stack limit of 1000 frames.
  # Returns Result<Int, StackOverflow>
  result = RUN_WITH_LIMIT(1000, %() -> unsafe_fib(100)) OR ELSE 0
  RETURN result; 
END
```

We can allow the user to OOM and consider the program safe.

1. Implement tail-call recursion
2. Implement `RUN_WITH_LIMIT` to ensure there's a limit
3. Allow `RUN_WITH_LIMIT` even for non-recursive functions
