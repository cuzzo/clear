# CHEAT

## PROPAGANDA

*Cheating is all you need.*

* Software should be performant, robust, AND resilient. 
* It should also be effortless to write and understand.
* It should be able to run anywhere, optimized for distributed parallelism and concurrency.

They told you "Pick one." They lied.

You can have it all, if you're willing to CHEAT.

**Commands like SQL. Pipelines like Bash. Speed like C.**

Being a genius like *antirez* isn't scalable. It's not something everyone can do. 

Everyone else can CHEAT.

## OPINIONS

1. Boiler Plate is bad.
2. Understandable code is king.
   * The easier it is to *UNDERSTAND* code, the more likely it is to arrive at a correct state.
   * Understanding what a function is *supposed* to do should not be bogged down by it's error handling logic.
     * Like test code, error handling code should be separate as much as possible.
     * Read it as an addendum IFF you care.
3. You should be able to test anything, and it should be EASY.
   * There should be ZERO test code in production code.
     * Java @visibleForTesting is nice, but it shouldn't be necessary at all.
   * The easier it is to write tests, the more likely you are to actually arrive at working code.
4. Handling Errors should "just work".
   * You should not always have to `checkOk`.
     * We can *assume* okay, and look to the bottom to see what happens when not okay, if we ever care.
   * The easier it is to handle errors, the more likely you are to handle them correctly!
5. If your code compiles, you should never have a run-time error (EXCEPT OOM, Infinite loops).
6. Compiler errors should tell you *exactly* what's wrong, how to fix it, and be easy to understand.
7. Types should be your friend, helping you write working code *faster*, not an enemy that is constantly slowing you down.
8. 90% of your time should be spent writing the code you need, and 10% debugging, handling errors, fighting compilers - not the other way around.
9. Writing efficient code should be *incredibly* easy.
   * Writing ineffiecent code should be *obviously* wrong.
10. Anything that *can* be 1-line *should* be!
    * Readability beats cleverness -- unless diretly critical to performance.
    * The constructs and syntax of a language should lend itself to one-liners, as it is easier to *UNDERSTAND*.
11. Code should be as declaractive as possible.
    * Every function should look like a clean chain of exactly what it *should* be doing.
      * It should not look like a nested mess of *how* it's handling errors and undesirable conditions.
12. You should not need to worry about memory management OR a garbage collector.
    * Unless you're a rocket scientist, the right compiler can figure it out better than you can.
    * A good SQL engine beats all but the absolute most elite programmers.
    * A good compiler can also take an easy language and beat all but the most elite programmers (see LuaJIT).
13. You should not need to worry about a Global-Interpreter-Lock (GIL).
    * Code *should* be able to run in parallel or concurrently *EFFICIENTLY* by default.
14. Code should be as left-sided as possible.
    * How many hours have *YOU* spent tracking down paren-syntax errors, figuring out which condition you're in, etc???
    * Time spent figuring out *WHERE* you even are logically, is time wasted, that could be spent getting things done.
15. Someone who doesn't know *CHEAT* should be able to look at *CHEAT* code and intuit what it does.
16. Publicly-Exported APIs *SHOULD* have style-enforcements.
    * At a minimum, if you're making a library, anyone should be able to understand the API...
17. Internal-code should be much more relaxed and lenient.
    * No interpretting errors because you have an unnused variable.
    * No forbidding your code to run for a test because you didn't follow a covention, etc.
    * Be permissive internally, but strict externally.

## Architecture

**1. Arena-Based Memory & Isolation**
  * CHEAT uses Arena-based memory management instead of a global Garbage Collector.
  * Each function scope or spawned process gets its own memory arena. When the scope ends, the memory is freed instantly. 
  * *The Result:* Memory safety and high performance *WITHOUT* the unpredictable "Stop-the-World" jitter of Java or Go.

**2. Implicit "Railway" Error Handling**
  * CHEAT treats errors as data, but handles them via control flow. 
  * The `SMOOTH` operator `s>` (aka the `PIPE` or `|>` in Elixir, etc) acts as a guard.
    * It automatically bubbles errors down the chain, to be handled elsewhere.
  * This ensures code reads top-to-bottom & is left-sided (the "Happy Path") -- while errors are handled explicitly at the boundaries.
  * *The Result:* No if [err != nil]() boilerplate. No [Pyramid of Doom](). No [checkOk]() clutter.

**3. Register-Based Virtual Machine**
  * CHEAT runs on a custom Register-Based VM *OR* transpiles to Zig and runs natively.
  * This reduces instruction churn compared to traditional stack machines (Java/Python/Ruby/etc) which maps efficiently to hardware.
  * *The Result:* Rapid development, with real-time debugging as easy as Ruby, with guarantees your code won't crash in run-time.

**4. Bi-Modal Type System**
  * CHEAT is dynamic by default (using NaN-boxed values for ease of use) but supports optional "Systems Types" (`u8`, `u64`) and Struct definitions. 
  * *The Result:* You can write scripts fast, then optimize hot paths into raw machine instructions, bridging the gap between Python/Ruby and Zig/C.

**5. Shared-Nothing Concurrency**
  * Parallelism is achieved via `SPAWN`, which creates isolated execution contexts. 
  * `SPAWN`ing a process creates a lightweight, isolated memory arena. 
  * Because memory is not shared between threads, CHEAT code is lock-free and thread-safe by default.

**6. A Type system that *just works***
  * CHEAT is easy to write for beginners. The Type system is implicit, staying out-of-the-way by powerful Type inference. 
  * The compiler takes care of the confusing parts of the type system for you.
  * *The Result:* If you can write code in JavaScript, Lua, Python, or Ruby - you can write blazing fast CHEAT code.

**7. True parallelism**
   * CHEAT can Auto-Squish your structs (Structure-of-Arrays transformation).
   * This allows efficient processing on GPUs in parallel (if compiling to a target).
   * If your struct can't be auto-squished given the code as currently written, you get a compiler error.
   * *The Result:* Either decorate it with @SLOW, or re-write so the data can be squished and screaming fast.


## CONTROVERSIAL CHOICES

### The *SMOOTH* operator

**1. Ergonomics are King**
  * The standard pipe `|>` is an ergonomic nightmare. 
    * It requires awkward pinky-stretches and holding Shift for two distinct keystrokes.
  * `s>` is designed for speed. 
     * It rolls across the keyboard (Left hand `s` -> Right hand `>`). 
     * It is a literal "Cheat code" for typing pipes faster.

**2. Different Behavior = Different Syntax**
  * In other languages, `|>` is a "dumb pipe." It passes data blindly.
  * In CHEAT, the pipe is a logic gate. It unwraps results, checks for errors, and manages control flow.
  * Using `|>` would be a lie. It would imply standard behavior where there is none.
  * `s>` signals intent: This is a **S**afe, **S**mooth, **S**mart pipe.


### DIVISION by 0
  * In order to guarantee your code will not crash at run-time, you *MUST* guarantee you don't divide by zero.
    * CHEAT did not invent the laws of Math.
  * CHEAT makes this as easy and intuitive as possible, using `GUARD` like the common convention for [guard clauses]().


### Frictionless Error Handling
  * **The Problem:** In most languages, you may spend equal or more time guarding against the 0.1% of cases where things break.
  * **The Solution:** CHEAT inverts this. The "Happy Path" is the default. Errors flow downstream automatically—skipping logic that can't handle them—until they hit a `CATCH` or `RECOVER` block.
  * **The Tradeoff:**
      * **Strictness vs. Velocity:** We trade static type checks for **Runtime Velocity**. CHEAT guarantees your program won't crash on an error, WITHOUT forcing you to manually unwrap every single variable.
  * **The Defense:**
      * **Telemetry over Taxonomy:** If you have to create or deal with 50 custom Error classes to use a function, you'll probably have MORE bugs, not less, then if you had one-simple error to handle. 
        * CHEAT provides one robust Error object that captures the **Context**, the **Kind**, and the **Data Snapshot** automatically.
      * **Focus on Value:** CHEAT isn't for writing kernel drivers or flight controllers; It's for everything else. 
        * CHEAT allows you to write business logic fast, knowing the safety net is baked into the language semantics.


### The "53-Bit" Lie (NaN Boxing)
  * **The Controversy:** By default, every number in CHEAT is a 64-bit Float (Double).
    * This means generic Integers are limited to 53 bits of precision (safe range up to ~9 quadrillion).
  * **The Trade-off:** If you need a raw `Int64` or `u64` for bitwise pointer math, you have to explicitly ask for it (and it's slower in the interpreter because it has to be "boxed" or allocated).
  * **The Defense:** 
      * **99% Case:** You are counting loops, array indices, or database IDs. 53 bits handles this effortlessly. 
      * **The 1% Case:** If you are doing Cryptography or matrix multiplication, you shouldn't be doing it in a hot loop in a dynamic language anyway. 
      * **The Cheat Code:** CHEAT assumes that if you need high-performance math, you will use a `Vector` (SIMD optimized) or a specialized Struct. We prioritize the speed of dynamic typing over the purity of 64-bit integers.


### Death to the Garbage Collector
   * **The Controversy:** CHEAT does not have a general-purpose Garbage Collector. It uses Arena Allocation.
   * **The Trade-off:** You cannot create an object that lives "forever" without thinking about where it lives.
   * **The Defense:**
       * Garbage Collectors are the enemy of consistent frame rates and latency.
       * CHEAT isolates memory by Process (Spawn) or Function Scope. When the task is done, the memory is nuked instantly.
       * Global objects are generally considered an anti-pattern anyway. Good riddance.
       * **The Result:** Your code runs at a predictable speed. There is no "Stop the World" pause while the VM cleans up your mess.


### Explicit State Mutation (`VAR` vs `SET`)
  * **The Controversy:** You cannot re-assign a variable declared with `VAR`. You must use the `SET` keyword.
  * **The Trade-off:** It requires three extra keystrokes to update a variable.
  * **The Defense:** Re-assignment is the root of 50% of debugging time.
      * By forcing you to type `SET`, CHEAT makes mutation visible.
      * If you see a block of code with no `SET`, you know immediately that the state is stable.
      * *The Result:* At code-time the editor knows this and can highlight functions that mutate to the user.


### IMMUTABILITY BY DEFAULT
  * **The Controvery:** It's tricky for beginners. You assign a variable, want to update it later, get a scary compiler error.
  * **The Trade-off:** This is the default for a reason. It's what you want most of the time.


### Different IMPLICIT default `collect` behavior at the end of stream chains
  * **The Controversy:** If you assign a stream to a variable, the compiler *assumes* you want to do it sync and wait til finished to collect
 * **The Catch:** The same statment *WITHOUT* an assignment, will immediately execute the next line without finishing.
 * **The Defense:** CHEAT is supposed to be intuitive, if you assign `VAR x = myList s> reduce( ... )` on the next line, you assume x to be a val, not a stream.
   * If you DON'T explicitly assign, it assumes it can be run in the background.
   * You must either use `AWAIT` at the beginning or ` s> collect` at the end.
   * In the majority of cases, it will either be a background task OR have a callback.
   * A pipeline that ends in ` s> callback(myFn)` should almost always be async.
   * The compiler will *WARN* but not reject if you don't prefix with ASYNC or AWAIT when not assigning
   * If you want to assign to a stream and/or `RETURN` the stream later, you simply prefix with `ASYNC`


## EXAMPLES

**The *SMOOTH* operator**
```
VAR bill = users AS @u
  s> UNNEST %.orders
  s> SELECT %.price * @u.discount
  s> reduce(0, %(acc, x) -> acc + x )

-- The above is equal to the below

VAR bill = users AS @u
  s> flatmap( %(x) -> x.orders )
  s> map( %(x) -> x.price * @u.discount )
  s> reduce(0, %(acc, x) -> acc + x )
```

**Handling Division by Zero**
```
FN myDivider(x, y) ->
  GAURD y != 0 OR ELSE 1;
  RETURN x / y;
end

-- this is fine in a function

FN typicalFunc(myObj) ->
  VAR health = GUARD myObj.health != 0 OR ELSE 1;
  -- Do a bunch of stuff
  RETURN myObj.strength / myObj.health;
end

-- Say you had a complex formula with lots of division
-- You might not want to have 

FN typicalFunc(myObj) ->
  VAR health = GUARD myObj.health != 0 OR ELSE 1;
  -- 10 more guards, needing to use local variables below
  -- Do a bunch of stuff
  -- RETURN <your equation with a bunch of division>
end

-- Instead you can do:

FN typicalFunc(myObj) ->
  -- RETURN <your equation with a bunch of division>
CATCH DivisionBy0
  RETURN -1;
end

-- HOWEVER - there is no such option for code outside of a function.
-- You can do:

FN main()
  -- Good design, no code execution outside of main
  -- In here, you do you do all kind of division
CATCH DivisionBy0
  -- Handle however you want
END

-- If you just have a script like:

VAR x = readSomeFileGetSomeNumber();
VAR y = 10;
callSomeFunc(y / x);

-- You'll get a DivisionByZero error, so you must do:


VAR x = GUARD readSomeFileGetSomeNumber() != 0 OR ELSE 1; 
VAR y = 10
callSomeFunc(y / x);
```


** ASYNC/AWAIT/COLLECT **
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

** MUTABILITY vs IMMUTABILITY **
```
VAR user = %{ name: "Alice", active: false }
SET user.active = true; -- Error!
SET user = %{ name: "Alice", active: true} -- Error!!

VAR user = %{ name: "Alice", active: false }
VAR upDatedUser = user MUTATE { active: true } -- No error!

VAR x = 5;
SET x += 10; -- ERROR!

MUTABLE VAR x = 5;
SET x += 10;
```

Example compiler errors:
```
Error: Cannot SET field 'active' on 'user' to true. 
     : This is a READ-ONLY VIEW of memory owned by 'DatabaseQueryResult'. 
     : To modify, use: 
     :
     : VAR newUser = user MUTATE { active: true };
     :
     : Or, if you want to modify it later, you might want it to be MUTABLE, use:
     :
     : MUTABLE VAR newUser = DEEP_COPY(user_data);
     : SET newUser.active = true;
     :
     : You can SET fields on MUTABLE data.


Error: Cannot SET 'x' to 5. 
     : x is IMMUTABLE.
     :
     : You can create a new variable:
     :
     : VAR newX = x + 5;
     :
     : Or, if you want to modify it later, you might want it to be MUTABLE, use:
     :
     : MUTABLE VAR newX = x;
     : SET newX = 5;
```



## THE CONFUSING TYPES

**Errors**

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
   VAR result = ERROR("Boom") s> myFn;
   ASSERT result == defaultPage; -- Success!
END
```


**Strings Vs Bytes**
String by default.

```
VAR s = "😊";                     -- String (Immutable)
MUTABLE VAR s = "😊";             -- String (Mutable, enforces UTF-8 on write)
VAR s: String(10) = "😊";         -- String (Immutable, fixed size UTF-8 buffer, very uncommon use case -> mainly for cache locality, not beginner need)
MUTABLE VAR s: String(10) = "😊"; -- String (Mutable, fixed size UTF-8 buffer, more common use case, but not beginner)

VAR b: Bytes = %[0, 10, 255];     -- Buffer (Immutable -> common / default use case for non-beginners)
MUTABLE VAR b: Bytes = %[0, 10];  -- Buffer (Mutable, Dynamic -> common use case)
VAR Bytes b: Bytes(10) = ...;     -- Buffer (Immutable, Fixed Size -> you might want for cache locality)
MUTABLE VAR b: Bytes(10) = ...;   -- Buffer (Mutable, Fixed Size -> common use case)
```

**Lists vs Streams**

```
VAR users = db.all s> filter; -- LIST, default
VAR users = db.all s> filter s> COLLECT; -- LIST, default, superfluous
VAR users = AWAIT db.all s> filter; -- LIST, default, superfluous

VAR userCursor: Stream = db.all s> filter; -- STREAM, not-default due to EXPLICIT type 
VAR userCursor = db.all s> filter s> ITER; -- STREAM, not-default due to EXPLICIT ITER
VAR userCursor = ASYNC db.all s> filter;   -- STREAM, not-default due to EXPLICIT ASYNC
```

**Streams are handles, not data**

* A stream is an *immutable* pointer to a *mutable* partition data (the stream / flow where x is `COLLECT`ing).
* However, you can have an *mutable* pointer.

Therefore:

```
MUTABLE VAR source: Stream = primary_db.users; -- OKAY

TRY
  source.peek(); -- Check connection
CATCH
  -- I need to reassign the variable to the backup stream!
  source = backup_db.users; 
END

source s> map...

-- ...

MUTABLE VAR s: Stream = db.all s> ... ; -- OKAY
MUTABLE VAR s: Stream(10) = db.all s> ... ; -- Compiler error, `... returns a single Stream, not a Vector of Streams`.
```



