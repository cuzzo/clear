### Handling Array Access
```
x = getMyVector();
y = x[10]; -- compiler error!
y = x[10] OR ELSE 0; -- OKAY!


x: Int[10] = getMyVector();
y = x[9];                                -- OK
z = x[10];                               -- COMPILER ERROR: Out of Bounds
zz = x[10] OR ELSE 0;                    -- OK - with a strong *WARNING* (compiler error in STRICT mode)

FN myVectorGetterDoer(v) ->
  -- preferred to use a GUARD clause
  z = GUARD v.size >= 56 OR ELSE CAST(v AS Int(56)); -- TODO: Is this too hard for the compiler to know?

  x = v[10]; -- OKAY, proven >10
  y = v[23]; -- OKAY, proven >23
  z = v[55]; -- OKAY, proven >55
  RETURN x + y - z + 5;
END


FN myVectorGetterDoer(v) ->
  x = v[10];
  y = v[23];
  z = v[55];
  RETURN x + y - z + 5;
CATCH
  RETURN 0;                                    -- OK: caught here, returning a value
END

FN myVectorGetterAdder(v) ->
  x = v[10] OR RETURN 5;                   -- OK: IFF you return a value, not the error.
  x = v[10] OR RETURN v[0];                -- COMPILER ERROR: OBVIOUSLY!
  RETURN x + 5;
END

-- here v is a DYNAMIC Vector.
FN myVectorGetterWhichTakesADynamicArrayAndResizes(v) ->
  -- ... do a bunch of stuff

  x: Int[10] = v;                           -- COMPILER ERROR!
  xx: Int[10] = TRUNCATE(v);                -- OK: acknolwedge you *could* be losing data.

  y = xx[9];                                -- OK: it will be 0 by default, if v was < 10 items.

  -- ... do a bunch of stuff
  RETURN x + 5;
END

-- here v is a FIXED Vector of size 1.
FN myVectorGetterWhichTakesADynamicArrayAndResizes(v) ->
  -- ... do a bunch of stuff

  x: Int[10] = v;                           -- OK: perhaps surprisingly, you're allowed to upsize, no harm no foul
  y = x[9];                                 -- OK: it will be 0 by default, if v was < 10 items.

  -- ... do a bunch of stuff
  RETURN x + 5;
END
```

### Handling Division by Zero

```
FN myDivider(x, y) ->
  y = GAURD y != 0 OR ELSE 1; -- OKAY, if y is MUTABLE
  RETURN x / y;
end

-- this is fine in a function

FN typicalFunc(myObj) ->
  health = GUARD myObj.health != 0 OR ELSE 1;
  -- Do a bunch of stuff
  RETURN myObj.strength / myObj.health;
end

-- Say you had a complex formula with lots of division
-- You might not want to have

FN typicalFunc(myObj) ->
  health = GUARD myObj.health != 0 OR ELSE 1;
  -- 10 more guards, needing to use local variables below
  -- Do a bunch of stuff
  -- RETURN <your equation with a bunch of division>
end

-- Instead you can do:

FN typicalFunc(myObj) ->
  -- RETURN <your equation with a bunch of division>
CATCH
  RETURN -1;
end

-- HOWEVER - there is no such option for code outside of a function.
-- You can do:

FN main()
  -- Good design, no code execution outside of main
  -- In here, you do do all kind of division
CATCH
  -- Handle however you want, except with code that raises an uncaught error
END

-- If you just have a script like:

x = readSomeFileGetSomeNumber();
y = 10;
callSomeFunc(y / x);

-- You'll get a DivisionByZero error, so you must do:


x = GUARD readSomeFileGetSomeNumber() != 0 OR ELSE 1;
y = 10
callSomeFunc(y / x);
```


### ASYNC/AWAIT/COLLECT

```
listOfUsers
  s> FILTER %.isActive
  s> COLLECT                 -- Converts Stream<User> to List<User>
  s> map(%(x) -> x.size > 5); -- Operates on the List<User> object

-- Did not prefix with AWAIT -> *assumes* intentend ASYNC -> immediately starts next step

file_paths
  s> concurrentRead
  s> COLLECT             -- Wait for ALL files to be fetched/materialized.
  s> aggregate;          -- Start aggregation only on the complete set.


-- Did not prefix with AWAIT -> *assumes* intentend ASYNC -> immediately starts next step

file_paths
  s> concurrentRead
  s> COLLECT             -- Wait for ALL files to be fetched/materialized.
  s> aggregate
  s> COLLECT;            -- waits until THIS finishes to resume (which may happen before the other two finish)

-- The above is *nearly* equivalent to:

AWAIT file_paths
  s> concurrentRead
  s> COLLECT             -- Wait for ALL files to be fetched/materialized.
  s> aggregate;

-- This is preferred, but not enforced.
-- Ending in COLLECT will convert from Stream<T> to List<T> -> even if it's not assigned to anything.
```

### MUTABILITY vs IMMUTABILITY

```
user = %{ name: "Alice", active: false }
user.active = true; -- Error!
user = %{ name: "Alice", active: true} -- Error!!

user = %{ name: "Alice", active: false }
upDatedUser = user MUTATE { active: true } -- No error!

x = 5;
x += 10; -- ERROR!

MUTABLE x = 5;
x += 10;
```

Example compiler errors:
```
Error: Cannot set field 'active' on 'user' to true.
     : This is a READ-ONLY VIEW of memory owned by 'DatabaseQueryResult'.
     : To modify, use:
     :
     : newUser = user MUTATE { active: true };
     :
     : Or, if you want to modify it later, you might want it to be MUTABLE, use:
     :
     : MUTABLE newUser = DEEP_COPY(user_data);
     : newUser.active = true;
     :
     : You can set fields on MUTABLE data.


Error: Cannot assign to 'x': it is immutable.
     : x is IMMUTABLE.
     :
     : You can create a new binding:
     :
     : newX = x + 5;
     :
     : Or, if you want to modify it later, declare it mutable:
     :
     : MUTABLE newX = x;
     : newX = 5;
```



## THE CONFUSING TYPES

### Errors

* You don't need to check for errors by default or specify them in your return types.
* The Compiler and the SMOOTH operator takes care of this for you.

```
FN myCarelessFn %(myList) ->
  myList
   s> fetchData -- this could return an error!
   s> parseData -- this could return an error!
   s> renderPage; -- this could return an error!

-- It's fine to not catch any of them here!
-- You're allowed to pass on the problem to your end user!
END

FN mySomewhatCarefullFn %(myList) ->
  myList
   s> fetchData -- this could return an error!
   s> parseData -- this could return an error!
   s> renderPage; -- this could return an error!

CATCH -- anything
  -- No matter what I want my users to get the default page.
  RETURN makeDefaultPage();
END

FN myMoreCarefullFn %(myList) ->
  myList
   s> fetchData -- doesn't ever throw an error!
   s> parseData -- doesn't ever throw an error!
   s> renderPage; -- doesn't ever throw an error!

CATCH -- anything
  -- This is still allowed, since no matter what you can OOM
  RETURN makeDefaultPage();
END

FN myQuiteCarefullFn %(myList) ->
  myList
   s> fetchData OR SKIP -- SKIP any error
   s> OTHERWISE(fetchFromBackup) -- OTHERWISE only happens if an error happend, and this may raise error, it's fine!
   s> parseData -- this could return an error!
   s> renderPage; -- this could return an error!

CATCH -- anything EXCEPT fetchData error -> It was already handled inline
  RETURN makeDefaultPage();
END

FN myReallyCarefullFn %(myList) ->
  myList
   s> fetchData OR SKIP -- SKIP any error
   s> OTHERWISE(fetchFromBackup) OR RETURN  -- Don't proceed any further, bubble this right up to the user
   s> parseData -- this could return an error!
   s> renderPage; -- this could return an error!

CATCH -- anything
  -- EXCEPT fetchData error -> It was already handled inline
  -- EXCEPT fetchFromBackup -> It was already handled inline
  RETURN makeDefaultPage();
END

FN myVeryCarefullFn %(myList) ->
  myList
   s> fetchData OR SKIP -- SKIP any error
   s> OTHERWISE(fetchFromBackup) OR RETURN  -- Don't proceed any further, bubble this right up to the user
   s> parseData OR EXIT -- Don't proceed any further, but try to pass this to a catch block below
   s> renderPage; -- this could return an error!

CATCH -- anything
  -- EXCEPT fetchData error -> It was already handled inline
  -- EXCEPT fetchFromBackup -> It was already handled inline
  -- DOES CATCH parseData (and renderPage) errors
  RETURN makeDefaultPage();
END

FN myExtremelyCarefullFn %(myList) ->
  myList
   s> fetchData OR SKIP -- SKIP any error
   s> OTHERWISE(fetchFromBackup) OR RETURN  -- Don't proceed any further, bubble this right up to the user
   s> parseData OR GOTO_RECOVER -- Don't proceed any further, JUMP to the first RECOVER down the chain
   s> renderPage -- this could return an error!
   s> RECOVER(makeDefaultPage());

CATCH -- anything
  -- EXCEPT fetchData error -> It was already handled inline
  -- EXCEPT fetchFromBackup -> It was already handled inline
  -- DOES CATCH parseData (and renderPage) errors
  RETURN makeDefaultPage();
END


FN myMostCarefulFn %(myList) ->
  myList
   s> fetchData OR SKIP -- SKIP any error
   s> OTHERWISE(fetchFromBackup) OR RETURN  -- Don't proceed any further, bubble this right up to the user
   s> parseData OR GOTO_RECOVER -- Don't proceed any further, JUMP to the first RECOVER down the chain
   s> renderPage OR EXIT "RenderPage failed"
   s> RECOVER(makeDefaultPage()) OR EXIT "RenderBackupPageFailed";

CATCH -- anything
  -- Here, there might be two RenderPage errors
  -- Down here, we might want to do two different things based on the same Error (with the context string from above)
  -- In both cases, we have acccess to the Error object `%e`
  -- With %e.message and %e.snapshot (whatever went into the pipe) set.
  --
  -- WARNING: To operate on %e.snapshot, you must cast it from Any to Whatever it is.
  -- This is dangerous, as it could itself raise an error.
  -- If this something like this is not acceptable, CHEAT is not for you.
  --
  -- You CAN log it without issue (with a default limit to how big the string is)
  -- Though, that could contain PII, so unless you control the parent, and can ensure it's safe for logging
  -- Do so at your own risk

  RETURN makeDefaultPage();
END

-- Testing Error handling is easy!
TEST "MyFn handles errors gracefully" ->
   result = ERROR("Boom") s> myFn;
   ASSERT result == defaultPage; -- Success!
END
```


### Strings Vs Bytes
String by default.

```
s = "😊";                     -- String (Immutable)
MUTABLE s = "😊";                 -- String (Mutable, enforces UTF-8 on write)
s: String[10] = "😊";         -- String (Immutable, fixed size UTF-8 buffer, very uncommon use case -> mainly for cache locality, not beginner need)
MUTABLE s: String[10] = "😊";     -- String (Mutable, fixed size UTF-8 buffer, more common use case, but not beginner)

b: UInt8[*] = %[0, 10, 255];  -- Buffer (Immutable -> common / default use case for non-beginners)
MUTABLE b: UInt8[] = %[0, 10];    -- Buffer (Mutable, Dynamic -> common use case)
b: UInt8[10] = ...;           -- Buffer (Immutable, Fixed Size -> you might want for cache locality)
MUTABLE b: UInt8[10] = ...;       -- Buffer (Mutable, Fixed Size -> common use case)
```

### Lists vs Streams

```
users = db.all s> filter; -- LIST, default
users = db.all s> filter s> COLLECT; -- LIST, default, superfluous
users = AWAIT db.all s> filter; -- LIST, default, superfluous

userCursor: Stream = db.all s> filter; -- STREAM, not-default due to EXPLICIT type
userCursor = db.all s> filter s> ITER; -- STREAM, not-default due to EXPLICIT ITER
userCursor = ASYNC db.all s> filter;   -- STREAM, not-default due to EXPLICIT ASYNC
```

### Streams are handles, not data

* A stream is an *immutable* pointer to a *mutable* partition data (the stream / flow where x is `COLLECT`ing).
* However, you can have an *mutable* pointer.

Therefore:

```
MUTABLE source: Stream = primary_db.users; -- OKAY

TRY
  source.peek(); -- Check connection
CATCH
  -- I need to reassign the variable to the backup stream!
  source = backup_db.users;
END

source s> map...

-- ...

MUTABLE s: Stream = db.all s> ... ; -- OKAY
MUTABLE s: Stream(10) = db.all s> ... ; -- Compiler error, `... returns a single Stream, not a Vector of Streams`.
```
