# CHEAT

## PROPAGANDA

*Cheating is all you need.*

* Software should be performant, robust, AND resilient. 
* It should also be effortless to write and understand.
* It should be able to run anywhere, optimized for distributed paralellism and concurrency.

They told you "Pick one." They lied.

You can have it all, if you're willing to CHEAT.

**Commands like SQL. Pipelines like Bash. Speed like C.**

Being a genius like *antirez* isn't scalable. It's not something everyone can do. 

Everyone else can CHEAT.

## OPINIONS

1. Boiler Plate is bad.
2. Understanding what a function does 99.9% of the time, should not be bogged down by the 0.1% of error cases.
   * That should be read/written below, as an addendum IFF you ever encounter such cases.
3. Handling Errors should "just work"
   * You should not always have to `checkOk`
     * We can *ASSUME* okay, and look to the bottom to see what happens when not okay, if we ever care
4. You should be able to test anything, and it should be EASY
   * There should be ZERO test code in production code
     * Java @visibleForTesting is nice, but it shouldn't be necessary at all
5. If your code compiles, you should never have a run-time error (EXCEPT OOM, Infinite loops)
6. Compile errors should be *EXTREMLY* easy to read, understand, and fix.
7. Types should be your friend, not an enemy - constantly getting in the way.
8. Writing efficient code should be *INCREDIBLY* easy.
   * Writing iniffiecent code should be *OBVIOUSLY* bad.
9. Anything that *can* be 1-line *SHOULD* be!
10. You should not need to worry about memory management OR a garbage collector.
11. You should not need to worry about a Global-Interpreter-Lock (GIL).
    * Code *should* be able to run in parellel or concurrently *EFFICIENTLY* by default.
12. Code should be as left-sided as possible.
    * How many errors have *YOU* spent tracking down where paren-syntax errors, figuring out which block you're in, etc???
    * Time spent figuring out *WHERE* you even are logically, is time wasted, that could be spent getting things done.
13. Someone who doesn't know *CHEAT* should be able to look at *CHEAT* code and intuit what it does.
14. Publicly-Exported APIs *SHOULD* have style-enforcements.
    * If you're making a library, anyone should be able to understand the API at the least.
15. Internal-code should be much more relaxed and lenient.
    * No interpretting errors because you have an unnused variable.
    * No forbidding your code to run for a test because you didn't follow a covention, etc.

## Architecture

**1. Arena-Based Memory & Isolation**
  * CHEAT uses Arena-based memory management instead of a global Garbage Collector.
  * Each function scope or spawned process gets its own memory arena. When the scope ends, the memory is freed instantly. 
  * *The Result:* Memory safety and high performance *WITHOUT* the unpredictable "Stop-the-World" jitter of Java or Go.

**2. Implicit "Railway" Error Handling**
  * CHEAT treats errors as data, but handles them via control flow. 
  * The `SMOOTH` operator `s>` (aka the `PIPE` or `|>` in Elixir, etc) acts as a guard
    * It automatically bubbls errors down the chain, to be handled elsewhere.
  * This ensures code reads top-to-bottom (the "Happy Path") while errors are handled explicitly at the boundaries.
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

**3. The "Smooth Operator"**
  * It aligns with the language branding. We don't just pipe data; we smooth it through.
  * It stands out visually, making the "Happy Path" of your code instantly recognizable against the "Error Path" (OR/CATCH).

**DIVISION by 0**
  * In order to guarantee your code will not crash at run-time, you *MUST* guarantee you don't divide by zero.
    * CHEAT did not invent the laws of Math.
  * CHEAT makes this as easy and intuitive as possible, using `GUARD` like the common convention for [guard clauses]().


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
  * **The Defense:** * Re-assignment is the root of 50% of debugging time.
      * By forcing you to type `SET`, CHEAT makes mutation visible.
      * If you see a block of code with no `SET`, you know immediately that the state is stable.
      * *The Result:* At code-time the editor knows this and can highlight functions that mutate to the user.


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
