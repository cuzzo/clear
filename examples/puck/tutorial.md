# So You Want To Build A Programming Language?

Why not start with the easiest one imaginable?

Some well-known languages are *shockingly* easy to implement *partially*:

* Scheme / Lisp
* Forth
* TCL
* SmallTalk

I would not start with trying to build Rust...

### What are the properties that make a language easy to build?

* **Parsing difficulty:** Dependent on grammar and syntax.
* **Annotation / Type difficulty:** You can typically trade static annotation in the parser for dynamic type difficulty in the VM, but not eliminate both.
* **Memory Management:** Easy mode = just leak memory, but RefCounting is nearly as easy.
* **Compilation / Interpretation difficulty:** Can be as simple as a handful of primitives.

So you could build a fully functioning language in **~300 dense lines of code** (not counting comments, whitespace, or end-only lines).

---

### The Comparison Matrix

| Language | Parsing Difficulty | Annotation (Type System) | Memory Management | Interpretation Complexity |
| --- | --- | --- | --- | --- |
| **Scheme** | Trivial. S-expressions do all the heavy lifting. | None. Fully dynamic; types attached to values. | GC / Leaking. Toy versions leak; real ones need GC. | Minimal. The "7 Primitives" (car, cdr, etc.). |
| **Forth** | Non-existent. Whitespace-delimited words. | Zero. No types, only cells on a stack. | Manual. User manages stack; VM stays out of it. | Low. Loop that looks up "words" in a dictionary. |
| **TCL** | Low. "Everything is a string" eliminates complex ASTs. | None. Strings are the only currency. | Buffers. Ref-counting is common; string buffers work. | Moderate. Heavy reliance on a command-dispatch table. |
| **Smalltalk** | Minimal. Postcard-sized grammar based on messages. | Purely Dynamic. Everything is an object; late dispatch. | Heavy. Requires real GC or Image for anything serious. | Elegant. Everything is a message pass. |

 * **Scheme and SmallTalk** typically require a Garbage Collector (GC) to be functional.
 * **TCL** requires a command-dispatch table.
 * **Forth** is truly easy to implement, but can feel alien to use.

What if we wanted something **ALMOST** as easy as Forth to implement, but with a syntax that is much more intuitive and natural (thus easier to understand)?

---

## Oberon to the Rescue

Standard Oberon, much like standard Lisp, is massive and not easy to implement. But what if we stripped it down?

You can implement working versions of Scheme in almost as little code as Forth, but you are still stuck with Lisp's heavily parenthesized notation. **Oberon**, on the other hand, is an **ALGOL descendant**. It reads like a slightly-less ergonomic version of JavaScript or Ruby.

By designing a highly constrained dialect of Oberon, you get the best of both worlds: a language that is trivial to parse and build, but uses a syntax most modern programmers immediately understand.

> **The Trade-off:** The parser will be the largest part of the language, but it is simple and mundane. ALGOL descendants like Oberon trade more parsing logic to make the compiler and VM considerably easier than Lisp / Scheme. It is almost objectively simpler, even if it is ~50-70 dense lines of code longer (20-30%).

### What does Oberon Look Like?

```pascal
PROCEDURE Factorial(n: INTEGER): INTEGER;
  VAR result: INTEGER;
  BEGIN
    IF n <= 1 THEN
      result := 1
    ELSE
      result := n * Factorial(n - 1)
    END;
    RETURN result
  END Factorial;
```

It is less ergonomic than a Ruby one-liner:

```ruby
def factorial(n) n <= 1 ? 1 : n * factorial(n-1) end
```

But such is the price you pay to implement a language in ~250 lines of code instead of ~250,000.

---

## Why Oberon looks this way

### 1. LL(1) Parsing

In plain English, **LL(1)** means your parser reads the text left-to-right and only ever needs to look ahead by **1 single word (token)** to know exactly what to do next. There is no guessing and no backtracking.

This is why we use the `:=` operator for assignment. In high-level languages:

* `x = 1` (Declare and assign)
* `x = 2` (Reassign)

In an LL(1) language, this is ambiguous. In Oberon, we separate them:

* `VAR x: INTEGER;` (Declare)
* `x := 1;` (Assign)

This is also why we use `IF ... THEN` and `END;`. Although not strictly needed, without them, the compiler can't easily tell where one block stops and the next begins.

### 2. Types

Oberon is **statically typed**. While dynamic typing sounds easier, it is a runtime headache. Every time you execute `x + y` in a dynamic C runtime, you must unpack structs, check types, and handle errors. It is slow and requires defensive code - that can become massive with a more complex type system. Implementing a typed language is considerably easier. As a bnous, it allows for a simple **JIT** later.

---

## The Tiny VM Primitives

In 1960, John McCarthy famously proved that you only need seven basic operations (`car`, `cdr`, `cons`, `quote`, `atom`, `eq`, `cond`) to compute literally anything in the universe using Lisp.

But we aren’t building a Lisp interpreter. We are building a statically typed, minimal Oberon.

Our "primitives" aren't list manipulators; they are the fundamental atoms of the CPU. The beauty of compilation is that no matter how complex your high-level language gets, it all eventually boils down to a tiny handful of incredibly dumb operations.

If you look back at our `Factorial` example, it seems like there is a lot of high-level logic happening. But to a CPU, that entire program is just a combination of these primitive instructions:

 * `ALLOC`: Allocate a heap value, like a string, and push the resulting reference onto the stack.
 * `LOAD`: Read a value from memory (like looking up the variable n).
 * `STORE`: Write a value to memory (like the := assignment to result).
 * `MATH`: Perform basic arithmetic (Add, Subtract, Multiply).
 * `COMPARE`: Look at two numbers and set a microscopic flag in the CPU if they are equal, greater, or lesser (e.g., checking n <= 1).
 * `JUMP_IF_FALSE`: The secret sauce of all logic. If the previous COMPARE flag was false, skip the next few lines of code. (This is how an IF statement actually works under the hood).
 * `JUMP`: Unconditionally jump to another line of code. (This is how you skip over the ELSE block after finishing an IF block, or how you loop back to the top of a WHILE loop).
 * `CALL` / `RETURN`: Pause current execution, jump to a new function, and when it hits `RETURN`, magically warp back to exactly where it left off.

---

## The Breakdown

What we will implement:

 * **A parser:** shockingly easy for LL(1) with an extremely minimal grammar, nearly as easy as Lisp or even Forth
 * **A bytecode compiler:** to compile our language down to a tiny bytecode instruction set
 * **A VM:** to run the bytecodes and execute any program computable.

You can also follow through each section with an interacive version of the compiler we build to see *exactly* what it does, which helps immensely if you learn visually or interactively.

## The Language

Our core language consists of 10 constructs:

 * `MODULE` / `BEGIN` / `END`: The outer wrapper of our program.
 * `VAR`: Variable declarations (e.g., `VAR x: INTEGER;`).
 * `PROCEDURE` / `RETURN`: For creating our own reusable functions.
 * `CALL`: Executing those functions (e.g., `Factorial(5)`).
 * `:=` (Assignment): Storing values in memory (e.g., `x := 10;`).
 * `Expressions` (Math & Logic): Handling basic arithmetic (`+`, `-`, `*`) and comparisons (`=`, `<=`).
 * `IF` / `THEN` / `ELSE`: Basic conditional branching.
 * `LOOP` / `EXIT`: The only iteration construct we need. (We skip WHILE and FOR loops—a generic LOOP with an EXIT condition is much easier to parse and can do the exact same things).
 * `SYSCALL`: To do everything we can’t do, like open files, print to the console, read sockets, etc
 * `MACRO`: To expand our language within our own language, to make it surprisingly user-friendly
    * This allows a ~600 LOC language to feel almost as user-friendly as ~250,000 LOC language, in a way Lisp/Scheme cannot really achieve - the syntax is what it is.
    * **Note**: This will not be in the initial implementation, as building a text-expansion engine makes the parsing almost 2x as hard!

This is all you need to build a *shockingly* usable language.

---

## The Scope

The tutorial builds the language up across **eleven versions**:

* **V1-V6** bring up the Ruby prototype: tokenizer, parser, bytecode compiler, stack-machine VM, conditionals, loops, refcounted strings, and `MODULE` plus a small standard library. ~325 dense lines by V6.
* **V7** adds `MACRO` to the parser. It roughly doubles the parser size but turns the language into something quite usable - `WHILE`, `FOR`, struct-like records all become library-level macros instead of new keywords.
* **V8-V9** finish the value model: `VAR` pass-by-reference, general arrays, then collapsing strings into arrays-of-codepoints. After V9 the Ruby VM is done.
* **V10** rewrites the VM in C. Same bytecode, ~100-200x faster.
* **V11** adds a minimal x86_64 JIT (~380 lines) on top of V10. Another ~120x on int-heavy code.

You can probably follow V1-V9 in an evening or two; V10 adds another day; V11 another two. Each version is a single focused change with its own directory and README.

The first versions will be slow, but very understandable.

 * We will re-implement the VM in C.
 * That will take our Ruby VM from ~75 lines of code to ~400 lines of C, and nearly double the project size, but speed up runtimes by 100x.
 * Then ~380 more lines of C in V11 adds a JIT that gets another ~120x on tight integer-arithmetic loops.
 * In this process you'll learn how and why things can be slow, a lot about how computers actually work, and - trust me - it'll be more fun than it sounds.

### What's not in Scope

Our language will not do a number of things:

 * Have nice, helpful errors
 * Optimize aggressively beyond the V11 JIT (no register allocator, no inline caches, no tiering)
 * Support concurrency
 * Prevent memory leaks (RefCounting can easily leak in graphs)


## The Pipeline

### 0. Source Code

The raw text the programmer writes: 
```pascal
IF n <= 1 THEN ... END;
```

### 1. Tokenizer

Breaks the raw string into a flat list of categorized words (tokens), throwing away spaces and formatting:

```
[IF, SYMBOL:n, OPERATOR:<=, INTEGER:1, THEN, ..., END]
```

### 2. Parser

Reads the tokens left-to-right and groups them into our 9 language constructs, in an Abstract Syntax Tree (AST):

```
IfStatement(
   condition: LessThanOrEqual( Variable(n), Integer(1) ),
   body: [ ... ]
)
```

### 3. Compiler

Flattens that tree down into our primitive machine instructions (Bytecode):

```
001: LOAD n
002: LOAD 1
003: COMPARE_LTE
004: JUMP_IF_FALSE 089 # (Skip to line 89 if n is not <= 1)
```

### 4. The VM
The loop that actually reads those instructions one by one and executes them on your physical CPU.

---

## Roadmap: The Eleven Versions

1. **V1:** Minimal tokenizer, parser, compiler, VM. Prints "42" (~80 dense lines).
2. **V2:** Define and call a function. Split into four files (~160 dense lines).
3. **V3:** Add conditionals, print selectively (~230 dense lines).
4. **V4:** Add loops, all math, FizzBuzz (~260 dense lines).
5. **V5:** Add strings as heap refs, and refcounting (~280 dense lines).
6. **V6:** Add `MODULE` for a standard library (~325 dense lines).
7. **V7:** Add `MACRO` for records and advanced surface syntax (~400 dense lines).
8. **V8:** Add `VAR` pass-by-reference plus generalized arrays.
9. **V9:** Strings *are* arrays of codepoints; real SYSCALLs (stdin/file/time/exit/argv). Ruby VM is done. Self-hosted `compiler.puck` ships alongside.
10. **V10:** Same bytecode reimplemented in C. ~100-200x faster (~400 lines of C).
11. **V11:** A minimal x86_64 JIT on top of V10. ~380 lines, ~120x more on `fib(35)`.

---

You can jump to [V1](v1/README.md) to get started, and see how you can make a *very* minimal programming language in ~80 lines of code.
