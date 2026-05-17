# OPINIONS

1. Boiler Plate is bad.
2. Understandable code is king.
   * The easier it is to *UNDERSTAND* code, the more likely it is to arrive at a correct state.
   * Understanding what a function is *supposed* to do should not be bogged down by it's error handling logic.
     * Like test code, error handling code should be separate as much as possible.
     * Read it as an addendum IFF you care.
   * Implicit behavior / magic *can* make things *harder* to understand.
3. You should be able to test anything, and it should be EASY.
   * There should be ZERO test code in production code.
     * Java @visibleForTesting is nice, but it shouldn't be necessary at all.
   * The easier it is to write tests, the more likely you are to actually arrive at working code.
4. Handling Errors should "just work".
   * You should not always have to `checkOk`.
     * We can *assume* okay, and look to the bottom to see what happens when not okay, if we ever care.
   * The easier it is to handle errors, the more likely you are to handle them correctly!
5. If your code compiles in `STRICT` mode, it will not produce a Run-time Error unless the system explicitly encounters a resource boundary, or the program executes an operation whose inputs are logically impossible to resolve correctly.
   * TODO: Investigate Type Coercion Failure claims.
     * Currently not implemented, but on the roadmap.
   * TODO: Investigate claims of all errors being handled *somewhere*.
6. Compiler errors should tell you *exactly* what's wrong, how to fix it, and be easy to understand.
7. Types should be your friend, helping you write working code *faster*, not an enemy that is constantly slowing you down.
8. 90% of your time should be spent writing the code you need, and 10% debugging, handling errors, fighting compilers - not the other way around.
9. Writing efficient code should be the default, and the default should be easy.
   * Writing ineffiecent code should be *obviously* wrong.
10. Anything that *can* be 1-line *should* be!
    * Readability and understandability beat cleverness -- unless direly critical to performance.
    * The constructs and syntax of a language should lend itself to one-liners, as they are often easier to *UNDERSTAND*.
11. Code should be as declaractive as possible.
    * Every function should look like a clean chain of exactly what it *should* be doing.
      * It should not look like a nested mess of *how* it's handling errors and undesirable states.
        * Though it *MUST* have the capability to do that.
12. You should not need to worry about memory management OR a garbage collector.
    * Unless you're a rocket scientist, the right compiler can figure it out better than you can.
    * A good SQL engine beats all but the absolute most elite programmers.
    * A good compiler can also take an easy language and beat all but the most elite programmers (see LuaJIT).
    * CLEAR *does* ask you think about *WHERE* an object lives.
      * Cache locality is literally 100x faster. If you wrote something cache-locality optimized in Ruby, it would crush a pointer cache miss in C.
      * Therefore, CLEAR is designed around making it as easy as possible to ensure you DON'T cache miss unless you absolutely must.
        * This means you do need to think about if you want something on the STACK (default, fast) or the HEAP (slow, but sometimes required).
13. You should not need to worry about a Global-Interpreter-Lock (GIL).
    * Code *should* be able to run in parallel or concurrently *EFFICIENTLY* by default.
14. Code should be as left-sided as possible.
    * How many hours have *YOU* spent tracking down paren-syntax errors, figuring out which condition you're in, etc???
    * Time spent figuring out *WHERE* you even are logically, is time wasted, that could be spent getting things done.
15. Someone who doesn't know *CLEAR* should be able to look at *CLEAR* code and intuit what it does.
16. Publicly-Exported APIs *SHOULD* have style-enforcements.
    * At a minimum, if you're making a library, anyone should be able to understand the API.
    * All `PUBLIC` functions *MUST* either *explicitly* `RAISE` an error OR handle all errors.
      * All `PUBLIC` structs *MUST* either have a suitable default or `!!` suffix.
        * All `PUBLIC` Union Types *MUST* be projectable for ease of use.
17. Internal-code can be *Chill*-Correct.
    * No interpretting errors because you have an unnused variable.
    * No forbidding your code to run for a test because you didn't follow a covention, etc.
    * Your code can fail because of `your` problems, but not becuase of your dependencies problems.
      * `STRICT` mode compilation eliminates *Chill*-Correct and can guarantee you won't encounter virtually all preventable run-time errors.


