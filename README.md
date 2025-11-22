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
1. list & struct access
2. IF/ELSE/WHILE
3. Boolean short-circuit logic -> Same as IF/ELSE
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
